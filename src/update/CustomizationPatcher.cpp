#include "update/CustomizationPatcher.hpp"
#include "core/DiagLog.hpp"

#include <mach-o/dyld.h>
#include <cstdint>

namespace fndiag {
namespace {

// Stub tail-called by the island in place of execHandleCustomizationFailed.
// Because HandleCustomizationFailed is a void UFunction, the stub just returns.
// The counter NumLoadCustomizationFailed is never incremented -> server cannot
// send reason=144 kicks.
static void __attribute__((noinline, used)) customization_failed_stub() {}

} // namespace

void install_customization_patch() {
    const mach_header* mh = _dyld_get_image_header(0);
    if (!mh) {
        log_line("[CustomPatch] FAIL: no image header");
        return;
    }
    uintptr_t base = (uintptr_t)mh;

    // Verify the disk island is in place (patch_binary.py --apply must have run).
    // Check the LDR word at island+4: LDR X16,[X16,#0x890] = 0xF9444A10.
    auto* island = reinterpret_cast<const uint32_t*>(base + kCustomIslandOff);
    if (island[1] != kCustomIslandLdr) {
        log_line("[CustomPatch] island not found at 0x%lx (got 0x%08x, want 0x%08x)",
                 (unsigned long)(base + kCustomIslandOff), island[1], kCustomIslandLdr);
        log_line("[CustomPatch]   run: python3 tools/patch_binary.py --apply && bash tools/resign.sh");
        return;
    }

    // Write stub address to __bss slot. The island reads this at dispatch time:
    // nonzero -> tail-call our stub; zero -> execute original function.
    auto* slot = reinterpret_cast<volatile uintptr_t*>(base + kCustomSlotOff);
    *slot = reinterpret_cast<uintptr_t>(&customization_failed_stub);

    log_line("[CustomPatch] armed: slot=0x%lx stub=0x%lx - NumLoadCustomizationFailed suppressed",
             (unsigned long)(base + kCustomSlotOff),
             (unsigned long)*slot);
}

} // namespace fndiag
