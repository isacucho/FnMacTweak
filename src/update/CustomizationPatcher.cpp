#include "update/CustomizationPatcher.hpp"
#include "core/DiagLog.hpp"

#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <cstdint>
#include <cstring>

namespace fndiag {
namespace {

// Stub returned to the game in place of HandleCustomizationFailed.
// The original increments NumLoadCustomizationFailed; with this the counter
// stays at 0 so the server never sends reason=144.
static void __attribute__((noinline, used)) customization_failed_stub() {}

// Write an 8-byte pointer into __DATA_CONST.  The segment is mapped r/o
// after dyld resolves chained fixups, so vm_protect(COPY) is needed.
// Unlike __TEXT, __DATA_CONST pages carry no code-signing hash, so the
// kernel does NOT enforce CS_KILL on the write -- same mechanic used by
// KickPatcher for ClientWasKicked.
static bool write_ptr(uintptr_t addr, uintptr_t val) {
    vm_address_t page = addr & ~(vm_size_t)(PAGE_SIZE - 1);
    kern_return_t kr;

    kr = vm_protect(mach_task_self(), page, PAGE_SIZE, false,
                    VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        log_line("[CustomPatch] vm_protect rw kr=%d addr=0x%lx", kr, (unsigned long)addr);
        return false;
    }
    *reinterpret_cast<volatile uintptr_t*>(addr) = val;
    __asm__ volatile("dsb ish" ::: "memory");
    kr = vm_protect(mach_task_self(), page, PAGE_SIZE, false, VM_PROT_READ);
    if (kr != KERN_SUCCESS) {
        log_line("[CustomPatch] vm_protect r kr=%d addr=0x%lx", kr, (unsigned long)addr);
        return false;
    }
    return true;
}

} // namespace

void install_customization_patch() {
    if (kHandleCustomizationFailedVtableOff == 0) {
        log_line("[CustomPatch] vtable offset not set - run lcf_find_ptr in LLDB:");
        log_line("[CustomPatch]   lldb -p $(pgrep FortniteClient-IOS)");
        log_line("[CustomPatch]   command script import tools/lldb_diag.py");
        log_line("[CustomPatch]   lcf_find_ptr");
        log_line("[CustomPatch]   fill kHandleCustomizationFailedVtableOff and rebuild");
        return;
    }

    uintptr_t img_base = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        const char* name = _dyld_get_image_name(i);
        if (name && (strstr(name, "FortniteClient") || i == 0)) {
            img_base = (uintptr_t)_dyld_get_image_header(i);
            if (img_base) break;
        }
    }
    if (!img_base) {
        log_line("[CustomPatch] FAIL: could not resolve image base");
        return;
    }

    uintptr_t vtable_slot_addr = img_base + kHandleCustomizationFailedVtableOff;
    uintptr_t stub_addr = (uintptr_t)&customization_failed_stub;

    log_line("[CustomPatch] patching vtable slot 0x%lx (offset=0x%llx) -> stub 0x%lx",
             (unsigned long)vtable_slot_addr,
             (unsigned long long)kHandleCustomizationFailedVtableOff,
             (unsigned long)stub_addr);

    if (write_ptr(vtable_slot_addr, stub_addr)) {
        log_line("[CustomPatch] patch ok - NumLoadCustomizationFailed suppressed");
    } else {
        log_line("[CustomPatch] FAIL: write_ptr failed");
    }
}

} // namespace fndiag
