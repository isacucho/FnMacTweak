#include "update/KickPatcher.hpp"
#include "core/DiagLog.hpp"

#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach-o/dyld.h>
#include <cstdint>

namespace fndiag {

// ============================================================
// Validation Patch (solución Jaded)
// Suprime la validación sideload/JIT en los slots vtable
// 0xcd32e18 (reason=10) y 0xcd32df8 (reason=6).
// El stub devuelve 0 sin llegar al dispatch de kick en 0x1074b7bcc.
// ============================================================

static constexpr uintptr_t kValidationVtableOff  = 0xcd32e18ULL;
static constexpr uintptr_t kValidationFnOff      = 0x74c1334ULL;
static constexpr uintptr_t kValidation2VtableOff = 0xcd32df8ULL;
static constexpr uintptr_t kValidation2FnOff     = 0x74c13b8ULL;

static uintptr_t validation_pass_stub(void* /*self*/, uintptr_t, uintptr_t, uintptr_t) {
    return 0;
}

static bool patch_vtable_entry(mach_vm_address_t va, uintptr_t expected, uintptr_t replacement) {
    uintptr_t current = *reinterpret_cast<volatile uintptr_t*>(va);
    if (current != expected) {
        log_line("[ValidationPatch]   skip vtable[0x%lx]: val=0x%lx != expected=0x%lx",
                 (long)va, (long)current, (long)expected);
        return false;
    }

    // 16KB page on Apple Silicon
    mach_vm_address_t page = va & ~((mach_vm_address_t)0x3FFF);
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
