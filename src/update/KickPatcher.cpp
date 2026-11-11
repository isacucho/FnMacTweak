#include "update/KickPatcher.hpp"
#include "core/DiagLog.hpp"

#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/vm_region.h>
#include <mach-o/dyld.h>
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

// EOS session state: STATIC GLOBAL in the binary, not a heap pointer chain.
// Discovered via disassembly of the check fn called from RejoinViaSessionInternal:
//   adrp x8, 66454; ldrb w8, [x8, #0xd68]; cmp w8, #0x5
// → state_byte = *(img_base + 0x13072d68)
// Values: 4=InProgress 5=Ending 6=Ended. Rejoin requires state < 5.
static constexpr uintptr_t kEosStateGlobalOff = 0x13072d68ULL;

// RejoinViaSessionInternal: vtable entry in __DATA_CONST,__const.
// At runtime dyld resolves to IMAGE_BASE + kRejoinFnOff.
// Intercepting allows forcing bCanRejoinSession=true (guard at fn+0x2c).
static constexpr uintptr_t kRejoinFnOff      = 0x805be18ULL;
static constexpr uintptr_t kRejoinVtableOff  = 0xd4a4e70ULL;

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

using KickedFn    = void (*)(void* self, int32_t reason);
using SpectatingFn = void (*)(void* self, void* arg1);
using RejoinFn    = void (*)(void* self);  // UFortRejoinCheck::RejoinViaSessionInternal

static KickedFn    g_orig_kicked   = nullptr;
static SpectatingFn g_orig_spectate = nullptr;
static RejoinFn    g_orig_rejoin   = nullptr;
// Re-entrancy guard: kept for safety.
static std::atomic<bool> g_kick_in_orig{false};

// vtable VA for UFortRejoinCheck, computed in install_kick_bypass.
// Used by rejoin_scan_thread to search the heap.
static uintptr_t g_rejoin_vtable_va = 0;
// Mach-O base address (IMAGE_BASE + slide), set in install_kick_bypass.
// Used by kick_bypass_stub to probe EOS session state before calling rejoin.
static uintptr_t g_image_base       = 0;
// Guards against launching multiple concurrent scans.
static std::atomic<bool> g_scan_running{false};

// Iterate all anonymous RW leaf regions and search for a 64-bit value.
// Uses vm_read_overwrite to copy into a local buffer - avoids SIGBUS/SIGSEGV
// if a region is unmapped between vm_region_recurse_64 and our read.
// Returns the heap address of the first match, or nullptr.
static void* scan_heap_for_vtable(uintptr_t vtable_va) {
    static const vm_size_t kChunk = 0x100000; // 1 MB per read call
    static uint8_t s_buf[kChunk];              // BSS; scan is serialized via g_scan_running

    vm_address_t addr = 0;
    vm_size_t    size = 0;
    while (addr < 0x700000000000ULL) {
        natural_t depth = 100;
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        kern_return_t kr = vm_region_recurse_64(
            mach_task_self(), &addr, &size, &depth,
            (vm_region_recurse_info_t)&info, &count);
        if (kr != KERN_SUCCESS || size == 0) break;

        bool is_rw = (info.protection & VM_PROT_READ) && (info.protection & VM_PROT_WRITE);
        if (!info.is_submap && is_rw && !info.external_pager && size >= 8) {
            vm_size_t off = 0;
            while (off < size) {
                vm_size_t chunk = (size - off < kChunk) ? (size - off) : kChunk;
                vm_size_t nread = chunk;
                kr = vm_read_overwrite(mach_task_self(),
                                       addr + off, chunk,
                                       reinterpret_cast<vm_address_t>(s_buf), &nread);
                if (kr == KERN_SUCCESS && nread >= 8) {
                    const uint8_t* p   = s_buf;
                    const uint8_t* end = s_buf + nread - 7;
                    while (p < end) {
                        if (*reinterpret_cast<const uintptr_t*>(p) == vtable_va) {
                            return reinterpret_cast<void*>(addr + off + (p - s_buf));
                        }
                        p += 8;
                    }
                }
                off += chunk;
            }
        }
        addr += size;
    }
    return nullptr;
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

    // Vtable health check: if any of our 18 entries was reset by game code, we lose coverage.
    if (g_image_base) {
        uintptr_t e0 = *reinterpret_cast<volatile uintptr_t*>(g_image_base + kVtableOffsets[0]);
        uintptr_t stub = reinterpret_cast<uintptr_t>(kick_bypass_stub);
        if (e0 != stub)
            log_line("[KickBypass] WARN vtable[0]=0x%lx != stub=0x%lx (vtable reset?)", (long)e0, (long)stub);
    }

    log_line("[KickBypass] suppressed reason=%d self=%p - scanning for UFortRejoinCheck*", r, self);
    // Scan synchronously on the game thread (we ARE here on the game thread via vtable dispatch).
    // The EOS session state at [global+0x468+0x0+0xd68] is still < 5 (InProgress) right now.
    // Using a background thread + dispatch_async introduces ~3ms of latency that lets the
    // session reach state >= 5 (Ending/Ended), triggering checkf at RejoinViaSessionInternal+0x3c
    // -> RequestExit(false) -> silent clean UE5 exit (no IPS generated).
    // 3ms of scan on game thread is a one-frame stutter at most and avoids the race entirely.
    if (g_orig_rejoin && g_rejoin_vtable_va &&
        !g_scan_running.exchange(true, std::memory_order_acq_rel)) {
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        void* obj = scan_heap_for_vtable(g_rejoin_vtable_va);
        uint64_t dt_ms = (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - t0) / 1000000ULL;
        if (!obj) {
            log_line("[Reconnect] scan done (%llums) - UFortRejoinCheck NOT FOUND", (unsigned long long)dt_ms);
        } else {
            *reinterpret_cast<volatile uint8_t*>(reinterpret_cast<uintptr_t>(obj) + 0x2a) = 1;
            __asm__ volatile("dmb ish" ::: "memory");
            log_line("[Reconnect] scan done (%llums) obj=%p bCanRejoinSession forced",
                     (unsigned long long)dt_ms, obj);
            // g_rejoin_attempted is set to true ONLY if RejoinViaSessionInternal is actually called.
            // Setting it here (before the EOS probe) caused the synthetic CT to be skipped even
            // when the probe failed (kr=1), resulting in a 90s freeze instead of 25s.
            // Probe EOS session state before calling RejoinViaSessionInternal.
            // State is a STATIC GLOBAL at g_image_base + kEosStateGlobalOff (not a heap chain).
            // State must be < 5 (InProgress); >= 5 (Ending/Ended) triggers checkf -> RequestExit.
            bool eos_state_ok = false;
            if (g_image_base) {
                auto* state_ptr = reinterpret_cast<volatile uint8_t*>(g_image_base + kEosStateGlobalOff);
                uint8_t eos_state = *state_ptr;
                log_line("[Reconnect] EOS session state=%d (must be <5 for rejoin)", (int)eos_state);
                if (eos_state < 5) {
                    eos_state_ok = true;
                } else {
                    log_line("[Reconnect] EOS state >= 5 - rejoin blocked to avoid RequestExit");
                }
            }
            // Rejoin disabled: diagnostic only. Calling RejoinViaSessionInternal
            // crashes silently even when state < 5 (EOS handle at slot2 is likely
            // freed/invalid by kick time). Log state and fall through to synthetic CT.
            if (eos_state_ok) {
                log_line("[Reconnect] EOS state ok but rejoin skipped (diagnostic mode)");
            }
        }
        g_scan_running.store(false, std::memory_order_release);
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
    g_image_base    = base;

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

    // --- RejoinViaSessionInternal vtable hook ---
    // UFortRejoinCheck::RejoinViaSessionInternal has 1 vtable entry.
    // At runtime dyld resolves the chained fixup to IMAGE_BASE + kRejoinFnOff.
    // Our stub forces bCanRejoinSession=true before the guard check.
    uintptr_t rejoin_orig_va   = base + kRejoinFnOff;
    uintptr_t rejoin_stub_va   = reinterpret_cast<uintptr_t>(rejoin_bypass_stub);
    mach_vm_address_t rejoin_entry = static_cast<mach_vm_address_t>(base + kRejoinVtableOff);
    g_orig_rejoin        = reinterpret_cast<RejoinFn>(rejoin_orig_va);
    g_rejoin_vtable_va   = base + kRejoinVtableOff; // heap scan target: objects holding this VA
    if (patch_vtable_entry(rejoin_entry, rejoin_orig_va, rejoin_stub_va)) {
        log_line("[Reconnect] vtable patched: orig=0x%lx stub=0x%lx entry=0x%lx",
                 (long)rejoin_orig_va, (long)rejoin_stub_va, (long)rejoin_entry);
    } else {
        log_line("[Reconnect] vtable patch FAILED for RejoinViaSessionInternal");
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
