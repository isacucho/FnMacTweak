#include "update/KickPatcher.hpp"
#include "core/DiagLog.hpp"

#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach-o/dyld.h>
#include <cstdint>
#include <atomic>
#include <mach/mach_time.h>

namespace fndiag {

std::atomic<uint64_t> g_last_kick_suppressed_at{0};

static bool patch_vtable_entry(mach_vm_address_t va, uintptr_t expected, uintptr_t replacement) {
    uintptr_t current = *reinterpret_cast<volatile uintptr_t*>(va);
    if (current != expected) {
        log_line("[KickBypass]   skip vtable[0x%lx]: val=0x%lx != expected=0x%lx",
                 (long)va, (long)current, (long)expected);
        return false;
    }
    mach_vm_address_t page = va & ~(mach_vm_address_t)0x3FFF;
    kern_return_t kr = vm_protect(mach_task_self(),
                                  static_cast<vm_address_t>(page), 0x4000, false,
                                  VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        log_line("[ValidationPatch]   vm_protect(rw) FAIL kr=%d va=0x%lx", kr, (long)va);
        return false;
    }
    *reinterpret_cast<volatile uintptr_t*>(va) = replacement;
    __asm__ volatile("dmb ish" ::: "memory");
    vm_protect(mach_task_self(), static_cast<vm_address_t>(page), 0x4000, false, VM_PROT_READ);
    return true;
}

// ============================================================
// KickBypass: patches vtable entries that point to
// ClientWasKicked_Implementation, replacing them with a stub
// that logs and suppresses the kick.
//
// 43.10 (build 60278837): 18 entries scattered across __DATA_CONST
//   Function VA 0x10865a2b8 (file off 0x865a2b8), "ClientWasKicked Reason:"
// ============================================================

// build 60278837 (Fortnite 43.10)
static constexpr uintptr_t kKickedFn_4310 = 0x865a2b8;
static const uintptr_t kKickedEntries_4310[] = {
    0xce7d390, 0xd049c60, 0xd617e00, 0xd61c758, 0xd61f558,
    0xd625048, 0xd627c78, 0xd62ada0, 0xd62fcc8, 0xd6369e8,
    0xd6a70f8, 0xd723c08, 0xd726da8, 0xd72a048, 0xd72d2b8,
    0xd7692d8, 0xd7eb800, 0xd8138f8,
};
static constexpr size_t kKickedEntries_4310_count =
    sizeof(kKickedEntries_4310) / sizeof(kKickedEntries_4310[0]);

static void kicked_bypass_stub(void*, void*) {
    g_last_kick_suppressed_at.store(mach_absolute_time(), std::memory_order_release);
    log_line("[KickBypass] ClientWasKicked suppressed");
}

void install_kick_bypass() {
    const mach_header* mh = _dyld_get_image_header(0);
    if (!mh) { log_line("[KickBypass] no image header"); return; }
    uintptr_t base = reinterpret_cast<uintptr_t>(mh);
    uintptr_t fn_va = base + kKickedFn_4310;
    uintptr_t stub_va = reinterpret_cast<uintptr_t>(kicked_bypass_stub);
    int ok = 0;
    for (size_t i = 0; i < kKickedEntries_4310_count; ++i) {
        uintptr_t slot_va = base + kKickedEntries_4310[i];
        if (patch_vtable_entry(slot_va, fn_va, stub_va)) ++ok;
    }
    log_line("[KickBypass] patched %d/%zu", ok, kKickedEntries_4310_count);
}

} // namespace fndiag
