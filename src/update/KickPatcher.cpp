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

using SpectatingFn = void (*)(void* self, void* arg1);
using RejoinFn    = void (*)(void* self);  // UFortRejoinCheck::RejoinViaSessionInternal

static SpectatingFn g_orig_spectate    = nullptr;
static RejoinFn     g_orig_rejoin      = nullptr;

// vtable VA for UFortRejoinCheck, computed in install_kick_bypass.
static uintptr_t g_rejoin_vtable_va = 0;
// Mach-O base address (IMAGE_BASE + slide), set in install_kick_bypass.
static uintptr_t g_image_base       = 0;

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
    g_image_base    = base;

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

// ============================================================
// Validation Patch
// The virtual function at kValidationFnOff (vtable slot kValidationVtableOff)
// checks performance counters and, on failure, calls kick dispatch at 0x1074b7bcc
// with reason codes 10 and 6. Replacing the vtable entries with validation_pass_stub
// makes the validator always "pass" before any kick dispatch is reached.
// kValidation2* covers the companion slot that fires reason=6.
// ============================================================

static constexpr uintptr_t kValidationVtableOff  = 0xcd32e18ULL;
static constexpr uintptr_t kValidationFnOff      = 0x74c1334ULL;
static constexpr uintptr_t kValidation2VtableOff = 0xcd32df8ULL;
static constexpr uintptr_t kValidation2FnOff     = 0x74c13b8ULL;

static uintptr_t validation_pass_stub(void* /*self*/, uintptr_t, uintptr_t, uintptr_t) {
    return 0;
}

void install_validation_patch() {
    const mach_header* mh = _dyld_get_image_header(0);
    if (!mh) { log_line("[ValidationPatch] no image header"); return; }
    uintptr_t base     = reinterpret_cast<uintptr_t>(mh);
    uintptr_t stub_va  = reinterpret_cast<uintptr_t>(validation_pass_stub);

    uintptr_t orig1 = base + kValidationFnOff;
    bool ok1 = patch_vtable_entry(base + kValidationVtableOff, orig1, stub_va);

    uintptr_t orig2 = base + kValidation2FnOff;
    bool ok2 = patch_vtable_entry(base + kValidation2VtableOff, orig2, stub_va);

    log_line("[ValidationPatch] slot1(r=10)=%s slot2(r=6)=%s stub=0x%lx orig1=0x%lx orig2=0x%lx",
             ok1 ? "ok" : "FAIL", ok2 ? "ok" : "FAIL",
             (long)stub_va, (long)orig1, (long)orig2);
}

} // namespace fndiag
