#include "update/CustomizationPatcher.hpp"
#include "core/DiagLog.hpp"

#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <cstdint>
#include <cstring>

namespace fndiag {
namespace {

// ARM64 RET instruction (unconditional return).
static const uint32_t kRetInsn = 0xD65F03C0U;

// No-op stub: installed as the first instruction of HandleCustomizationFailed.
// The original function increments NumLoadCustomizationFailed, which the server
// uses to decide whether to send reason=144. With this stub the counter stays
// at 0 for the entire match.
static void __attribute__((naked, noinline, used)) customization_failed_stub() {
    __asm__ volatile("ret");
}

static bool write_u32(uintptr_t addr, uint32_t val) {
    vm_address_t page   = addr & ~(vm_size_t)(PAGE_SIZE - 1);
    vm_size_t    pgsz   = PAGE_SIZE;
    kern_return_t kr;

    kr = vm_protect(mach_task_self(), page, pgsz, false,
                    VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        log_line("[CustomPatch] vm_protect rw kr=%d addr=0x%lx", kr, (unsigned long)addr);
        return false;
    }
    *reinterpret_cast<volatile uint32_t*>(addr) = val;
    __asm__ volatile("dsb ish; isb" ::: "memory");
    kr = vm_protect(mach_task_self(), page, pgsz, false,
                    VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        log_line("[CustomPatch] vm_protect rx kr=%d addr=0x%lx", kr, (unsigned long)addr);
        return false;
    }
    return true;
}

} // namespace

void install_customization_patch() {
    if (kHandleCustomizationFailedOff == 0) {
        log_line("[CustomPatch] offset not set - run lcf_find in LLDB to discover");
        log_line("[CustomPatch]   attach: lldb -p $(pgrep FortniteClient-IOS)");
        log_line("[CustomPatch]   then:   command script import tools/lldb_diag.py");
        log_line("[CustomPatch]   then:   lcf_find");
        log_line("[CustomPatch]   fill in kHandleCustomizationFailedOff and rebuild");
        return;
    }

    // Resolve image base.
    uintptr_t img_base = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        const char* name = _dyld_get_image_name(i);
        if (name && (strstr(name, "FortniteClient") || i == 0)) {
            img_base = (uintptr_t)_dyld_get_image_header(i)
                       + _dyld_get_image_vmaddr_slide(i);
            if (img_base) break;
        }
    }
    if (!img_base) {
        log_line("[CustomPatch] FAIL: could not resolve image base");
        return;
    }

    uintptr_t fn_addr = img_base + kHandleCustomizationFailedOff;
    log_line("[CustomPatch] patching HandleCustomizationFailed at 0x%lx (offset=0x%llx)",
             (unsigned long)fn_addr, (unsigned long long)kHandleCustomizationFailedOff);

    // Overwrite first instruction with RET.
    if (write_u32(fn_addr, kRetInsn)) {
        log_line("[CustomPatch] patch ok - NumLoadCustomizationFailed suppressed");
    } else {
        log_line("[CustomPatch] FAIL: write_u32 failed");
    }
}

} // namespace fndiag
