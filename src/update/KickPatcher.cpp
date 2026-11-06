#include "update/KickPatcher.hpp"
#include "core/DiagLog.hpp"

#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach-o/dyld.h>
#include <cstdint>

namespace fndiag {

// File offset (from IMAGE_BASE=0x100000000) of ClientWasKicked_Implementation.
// EFortKickReason in x1: 0=NotKicked 1=GenericKick 2=WasBanned
//   3=EncryptionRequired 4=CrossPlayRestriction 5=ClientIdRestriction
// PITFALL: patching the __TEXT body of this function causes "Network Connection Lost"
//   at ~40s (prior kick). Vtable bypass is the safe path: we only redirect vtable dispatch.
static constexpr uintptr_t kKickedFnOffset = 0x858cf18ULL;

// 18 vtable entries (file offsets from IMAGE_BASE) pointing to kKickedFnOffset.
// Located in __DATA_CONST — readable after dyld fixup, writable via mach_vm_protect.
static const uintptr_t kVtableOffsets[] = {
    0xcd553e0ULL, 0xcf20578ULL, 0xd4ec278ULL, 0xd4f0bd0ULL, 0xd4f39d0ULL,
    0xd4f94c0ULL, 0xd4fc0f0ULL, 0xd4ff218ULL, 0xd504140ULL, 0xd50ae40ULL,
    0xd5796f8ULL, 0xd5f6018ULL, 0xd5f91b8ULL, 0xd5fc458ULL, 0xd5ff6c8ULL,
    0xd63c980ULL, 0xd6bea90ULL, 0xd6e4808ULL,
};
static constexpr int kVtableCount = static_cast<int>(sizeof(kVtableOffsets) / sizeof(kVtableOffsets[0]));

using KickedFn = void (*)(void* self, int32_t reason);
static KickedFn g_orig_kicked = nullptr;

static void kick_bypass_stub(void* self, int32_t reason) {
    log_line("[KickBypass] ClientWasKicked reason=%d "
             "(0=None 1=Generic 2=Banned 3=Encrypt 4=CrossPlay 5=ClientId)", reason);
    // Allow legitimate kicks (banned, cross-play) to run original cleanup
    if (reason == 2 || reason == 4) {
        if (g_orig_kicked) g_orig_kicked(self, reason);
        return;
    }
    // Suppress: GenericKick(1=ValidationFailed), EncryptionRequired(3), ClientIdRestriction(5)
    log_line("[KickBypass] suppressed reason=%d", reason);
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
}

} // namespace fndiag
