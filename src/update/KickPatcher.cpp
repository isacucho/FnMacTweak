#include "update/KickPatcher.hpp"
#include "core/DiagLog.hpp"

#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <dispatch/dispatch.h>
#include <cstdint>
#include <atomic>
#include <time.h>

namespace fndiag {

std::atomic<uint64_t> g_last_kick_suppressed_ns{0};
std::atomic<bool>     g_rejoin_attempted{false};

// File offset (from IMAGE_BASE=0x100000000) of ClientWasKicked_Implementation.
// EFortKickReason in x1: 0=NotKicked 1=GenericKick 2=WasBanned
//   3=EncryptionRequired 4=CrossPlayRestriction 5=ClientIdRestriction
// PITFALL: patching the __TEXT body of this function causes "Network Connection Lost"
//   at ~40s (prior kick). Vtable bypass is the safe path: we only redirect vtable dispatch.
static constexpr uintptr_t kKickedFnOffset   = 0x858cf18ULL;

// UFortRejoinCheck vtable entries in __DATA_CONST,__const.
// At runtime dyld resolves chained fixups to IMAGE_BASE + kXxxFnOff.
//
// Vtable layout (confirmed via chained fixup decode, 2026-11-10):
//   kInitializeVtableOff  (idx-2 from kRejoinVtableOff): Initialize(FSubsystemCollectionBase&)
//   idx-1:                                                unknown (0x805b900)
//   kRejoinVtableOff      (idx 0):                       RejoinViaSessionInternal
//
// Hook strategy: intercept Initialize to capture UFortRejoinCheck* at object creation.
// On reason=144 kick, dispatch RejoinViaSessionInternal(cached_obj) on main thread.
// No heap scan required.
static constexpr uintptr_t kInitializeFnOff   = 0x805c820ULL;  // Initialize body (for verification)
static constexpr uintptr_t kInitializeVtableOff = 0xd4a4e60ULL; // vtable entry for Initialize
static constexpr uintptr_t kRejoinFnOff        = 0x805be18ULL;
static constexpr uintptr_t kRejoinVtableOff    = 0xd4a4e70ULL;

// File offset of the disk island for BeginSpectating (written by patch_binary.py).
// BeginSpectating_Implementation (file 0x81848fc) is a non-virtual UE RPC; its first
// instruction is replaced by B to this island in __TEXT.__const zero-padding.
// First magic word: 0xb00395b0 (ADRP X16, spectate_slot_page).
// island+20 = execute_original: STP X29,X30,[SP,-N]! + B BeginSpectating+4.
static constexpr uintptr_t kSpectateIslandOff  = 0xb945b84ULL;

// __bss slot offset (from Mach-O base) for begin_spectating_stub address.
// The island reads this at runtime; we write it here during install.
// 0x12bfa888 = DATA_SLOT_BSS_OFF(BNF=0x12bfa880) + 8.
static constexpr uintptr_t kSpectateSlotOff    = 0x12bfa888ULL;

// Magic: first word of the island when patch_binary.py has applied the BeginSpectating patch.
static constexpr uint32_t kSpectateIslandMagic = 0xb00395b0U; // ADRP X16

// 18 vtable entries for ClientWasKicked (file offsets from IMAGE_BASE) in __DATA_CONST.
static const uintptr_t kVtableOffsets[] = {
    0xcd553e0ULL, 0xcf20578ULL, 0xd4ec278ULL, 0xd4f0bd0ULL, 0xd4f39d0ULL,
    0xd4f94c0ULL, 0xd4fc0f0ULL, 0xd4ff218ULL, 0xd504140ULL, 0xd50ae40ULL,
    0xd5796f8ULL, 0xd5f6018ULL, 0xd5f91b8ULL, 0xd5fc458ULL, 0xd5ff6c8ULL,
    0xd63c980ULL, 0xd6bea90ULL, 0xd6e4808ULL,
};
static constexpr int kVtableCount = static_cast<int>(sizeof(kVtableOffsets) / sizeof(kVtableOffsets[0]));

using KickedFn     = void (*)(void* self, int32_t reason);
using SpectatingFn = void (*)(void* self, void* arg1);
using RejoinFn     = void (*)(void* self);
using InitFn       = void (*)(void* self, void* collection);

static KickedFn     g_orig_kicked   = nullptr;
static SpectatingFn g_orig_spectate = nullptr;
static RejoinFn     g_orig_rejoin   = nullptr;
static InitFn       g_orig_init     = nullptr;

// Cached UFortRejoinCheck* captured in init_hook_stub when the subsystem initialises.
// Atomic so kick_bypass_stub (may be on any thread) can read it safely.
// Cleared to 0 when the match ends (not yet implemented; safe to leave stale since
// RejoinViaSessionInternal is idempotent and the object lives as long as the game session).
static std::atomic<uintptr_t> g_rejoin_check_instance{0};

// Re-entrancy guard: kept for safety.
static std::atomic<bool> g_kick_in_orig{false};

// Called when UFortRejoinCheck::Initialize(FSubsystemCollectionBase&) is dispatched
// through the vtable. Captures `self` for use in kick_bypass_stub without any heap scan.
static void init_hook_stub(void* self, void* collection) {
    g_rejoin_check_instance.store(reinterpret_cast<uintptr_t>(self),
                                   std::memory_order_release);
    log_line("[Reconnect] Initialize captured UFortRejoinCheck* %p", self);
    if (g_orig_init) g_orig_init(self, collection);
}

static void rejoin_bypass_stub(void* self) {
    // bCanRejoinSession at [UFortRejoinCheck + 0x2a] is false after a server kick.
    // Guard is at RejoinViaSessionInternal+0x2c: LDRB W8,[X0,#0x2a]; CMP W8,#1; B.NE exit.
    // Force it here so the reconnect path proceeds.
    if (__builtin_expect(self != nullptr, 1)) {
        *reinterpret_cast<volatile uint8_t*>(reinterpret_cast<uintptr_t>(self) + 0x2a) = 1;
    }
    log_line("[Reconnect] RejoinViaSessionInternal called self=%p, bCanRejoinSession forced", self);
    if (g_orig_rejoin) g_orig_rejoin(self);
}

static void begin_spectating_stub(void* self, void* arg1) {
    uint64_t now  = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    uint64_t last = g_last_kick_suppressed_ns.load(std::memory_order_relaxed);
    uint64_t dk   = (last != 0) ? (now - last) : 0;
    // Always forward to orig: BeginSpectating is the return-to-lobby trigger.
    // Suppressing it entirely leaves the game stuck with no exit path.
    // BNF hook already blocks the NCL screen; the ~20-30s spectate timer
    // runs and exits cleanly to lobby.
    log_line("[KickBypass] BeginSpectating forwarded dk=%llums",
             (unsigned long long)(dk / 1000000ULL));
    if (g_orig_spectate) g_orig_spectate(self, arg1);
}

static void kick_bypass_stub(void* self, int32_t reason) {
    // Mask to 8 bits: EFortKickReason is uint8; upper bits can be garbage from vtable ABI.
    int32_t r = reason & 0xFF;
    log_line("[KickBypass] ClientWasKicked reason=%d (raw=0x%x) "
             "(0=None 1=Generic 2=Banned 3=Encrypt 4=CrossPlay 5=ClientId)", r, (unsigned)reason);
    // Allow legitimate kicks (banned, cross-play) to run original cleanup
    if (r == 2 || r == 4) {
        if (g_orig_kicked) g_orig_kicked(self, reason);
        return;
    }
    // Do NOT call g_orig_kicked for non-standard reason codes (e.g. 144):
    // ClientWasKicked_Implementation crashes on unknown reasons, and the only
    // side effect we need (lobby return) is handled by begin_spectating_stub below.
    if (g_kick_in_orig.exchange(true, std::memory_order_acq_rel)) {
        log_line("[KickBypass] suppressed reason=%d (reentrant)", r);
        g_kick_in_orig.store(false, std::memory_order_release);
        return;
    }
    g_last_kick_suppressed_ns.store(
        clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW), std::memory_order_relaxed);
    g_rejoin_attempted.store(false, std::memory_order_release);

    uintptr_t cached = g_rejoin_check_instance.load(std::memory_order_acquire);
    if (cached && g_orig_rejoin) {
        g_rejoin_attempted.store(true, std::memory_order_release);
        log_line("[KickBypass] suppressed reason=%d self=%p - dispatching RejoinViaSessionInternal obj=0x%lx",
                 r, self, (long)cached);
        // RejoinViaSessionInternal must run on the game thread (= main thread on iOS).
        dispatch_async(dispatch_get_main_queue(), ^{
            void* obj = reinterpret_cast<void*>(cached);
            log_line("[Reconnect] RejoinViaSessionInternal firing on main thread obj=%p", obj);
            // Force bCanRejoinSession flag before the guard check at RejoinViaSessionInternal+0x2c.
            *reinterpret_cast<volatile uint8_t*>(cached + 0x2a) = 1;
            __asm__ volatile("dmb ish" ::: "memory");
            g_orig_rejoin(obj);
        });
    } else {
        log_line("[KickBypass] suppressed reason=%d self=%p - UFortRejoinCheck not cached (match not started?)",
                 r, self);
    }

    g_kick_in_orig.store(false, std::memory_order_release);
}

static bool patch_vtable_entry(mach_vm_address_t va, uintptr_t expected, uintptr_t replacement) {
    uintptr_t current = *reinterpret_cast<volatile uintptr_t*>(va);
    if (current != expected) {
        log_line("[KickBypass]   skip vtable[0x%lx]: val=0x%lx != expected=0x%lx",
                 (long)va, (long)current, (long)expected);
        return false;
    }

    // 16KB page on Apple Silicon
    mach_vm_address_t page = va & ~((mach_vm_address_t)0x3FFF);
    // vm_protect is in the iOS SDK; mach_vm_protect is macOS-only in headers.
    kern_return_t kr = vm_protect(mach_task_self(),
                                  static_cast<vm_address_t>(page), 0x4000, false,
                                  VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        log_line("[KickBypass]   vm_protect(rw) FAIL kr=%d va=0x%lx", kr, (long)va);
        return false;
    }

    *reinterpret_cast<volatile uintptr_t*>(va) = replacement;
    __asm__ volatile("dmb ish" ::: "memory");

    vm_protect(mach_task_self(), static_cast<vm_address_t>(page), 0x4000, false, VM_PROT_READ);
    return true;
}

void install_kick_bypass() {
    const mach_header* mh = _dyld_get_image_header(0);
    if (!mh) { log_line("[KickBypass] no image header"); return; }
    uintptr_t base  = reinterpret_cast<uintptr_t>(mh);
    intptr_t  slide = static_cast<intptr_t>(base) - static_cast<intptr_t>(0x100000000ULL);

    uintptr_t orig_va = base + kKickedFnOffset;
    g_orig_kicked = reinterpret_cast<KickedFn>(orig_va);

    uintptr_t stub_va = reinterpret_cast<uintptr_t>(kick_bypass_stub);

    int patched = 0;
    for (int i = 0; i < kVtableCount; ++i) {
        mach_vm_address_t entry_va = static_cast<mach_vm_address_t>(base + kVtableOffsets[i]);
        if (patch_vtable_entry(entry_va, orig_va, stub_va)) ++patched;
    }

    log_line("[KickBypass] vtable patch: %d/%d entries patched slide=0x%lx orig=0x%lx stub=0x%lx",
             patched, kVtableCount, (long)slide, (long)orig_va, (long)stub_va);

    // --- UFortRejoinCheck::Initialize vtable hook ---
    // Intercepts the first call to Initialize when the subsystem enters a match.
    // Captures `self` (UFortRejoinCheck*) in g_rejoin_check_instance so kick_bypass_stub
    // can call RejoinViaSessionInternal directly without any heap scan.
    uintptr_t init_orig_va = base + kInitializeFnOff;
    uintptr_t init_stub_va = reinterpret_cast<uintptr_t>(init_hook_stub);
    mach_vm_address_t init_entry = static_cast<mach_vm_address_t>(base + kInitializeVtableOff);
    g_orig_init = reinterpret_cast<InitFn>(init_orig_va);
    if (patch_vtable_entry(init_entry, init_orig_va, init_stub_va)) {
        log_line("[Reconnect] Initialize vtable patched: orig=0x%lx stub=0x%lx entry=0x%lx",
                 (long)init_orig_va, (long)init_stub_va, (long)init_entry);
    } else {
        log_line("[Reconnect] Initialize vtable patch FAILED (entry=0x%lx val=0x%lx expected=0x%lx)",
                 (long)init_entry,
                 (long)*reinterpret_cast<volatile uintptr_t*>(init_entry),
                 (long)init_orig_va);
    }

    // --- RejoinViaSessionInternal vtable hook ---
    // UFortRejoinCheck::RejoinViaSessionInternal has 1 vtable entry.
    // At runtime dyld resolves the chained fixup to IMAGE_BASE + kRejoinFnOff.
    // Our stub forces bCanRejoinSession=true before the guard check.
    uintptr_t rejoin_orig_va   = base + kRejoinFnOff;
    uintptr_t rejoin_stub_va   = reinterpret_cast<uintptr_t>(rejoin_bypass_stub);
    mach_vm_address_t rejoin_entry = static_cast<mach_vm_address_t>(base + kRejoinVtableOff);
    g_orig_rejoin = reinterpret_cast<RejoinFn>(rejoin_orig_va);
    if (patch_vtable_entry(rejoin_entry, rejoin_orig_va, rejoin_stub_va)) {
        log_line("[Reconnect] RejoinViaSessionInternal vtable patched: orig=0x%lx stub=0x%lx entry=0x%lx",
                 (long)rejoin_orig_va, (long)rejoin_stub_va, (long)rejoin_entry);
    } else {
        log_line("[Reconnect] RejoinViaSessionInternal vtable patch FAILED");
    }

    // --- BeginSpectating disk island hook ---
    // BeginSpectating_Implementation is a non-virtual UE RPC (no C++ vtable entries).
    // patch_binary.py places a 28-byte island in __TEXT.__const zero-padding and
    // replaces the first instruction of the function with a B to the island.
    // The island checks the __bss slot; if zero (dylib not installed), it falls through
    // to execute_original (island+20) which runs the saved first instruction and
    // branches back to fn+4. If nonzero, it tail-calls begin_spectating_stub.
    uintptr_t island_va = base + kSpectateIslandOff;
    uint32_t  island_magic = *reinterpret_cast<volatile uint32_t*>(island_va);
    if (island_magic == kSpectateIslandMagic) {
        // Island is in place: write stub address to __bss slot and set g_orig_spectate.
        auto* slot = reinterpret_cast<volatile uintptr_t*>(base + kSpectateSlotOff);
        *slot = reinterpret_cast<uintptr_t>(begin_spectating_stub);
        __asm__ volatile("dmb ish" ::: "memory");
        g_orig_spectate = reinterpret_cast<SpectatingFn>(island_va + 20);
        log_line("[KickBypass] BeginSpectating island armed: slot=0x%lx orig=0x%lx",
                 (long)(base + kSpectateSlotOff), (long)g_orig_spectate);
    } else {
        log_line("[KickBypass] BeginSpectating island NOT found (magic=0x%x) - run deploy.sh",
                 island_magic);
    }
}

} // namespace fndiag
