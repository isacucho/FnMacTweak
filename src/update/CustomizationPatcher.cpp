#include "update/CustomizationPatcher.hpp"
#include "core/DiagLog.hpp"

#include <mach-o/dyld.h>
#include <cstdint>

extern "C" void MSHookFunction(void* symbol, void* replace, void** result);

namespace fndiag {
namespace {

// Replacement for execHandleCustomizationFailed. Returns immediately so
// NumLoadCustomizationFailed is never incremented and the server never sends
// reason=144 kicks. Void return, no stack cleanup needed on ARM64.
static void __attribute__((noinline, used)) customization_failed_stub() {}

} // namespace

void install_customization_patch() {
    const mach_header* mh = _dyld_get_image_header(0);
    if (!mh) {
        log_line("[CustomPatch] FAIL: no image header");
        return;
    }
    uintptr_t base   = reinterpret_cast<uintptr_t>(mh);
    uintptr_t fn_va  = base + kCustomFnOff;

    // Sanity-check prologue to catch version mismatch early.
    uint32_t prologue = *reinterpret_cast<const volatile uint32_t*>(fn_va);
    if (prologue != kCustomFnPrologue) {
        log_line("[CustomPatch] prologue mismatch at 0x%lx: got 0x%08x want 0x%08x "
                 "-- kCustomFnOff needs updating for this build",
                 (unsigned long)fn_va, prologue, kCustomFnPrologue);
        return;
    }

    MSHookFunction(reinterpret_cast<void*>(fn_va),
                   reinterpret_cast<void*>(customization_failed_stub),
                   nullptr);

    log_line("[CustomPatch] hooked execHandleCustomizationFailed at 0x%lx via MSHookFunction "
             "- NumLoadCustomizationFailed suppressed", (unsigned long)fn_va);
}

} // namespace fndiag
