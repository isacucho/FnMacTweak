#pragma once
#include <cstdint>

namespace fndiag {

// Disk island patch for execHandleCustomizationFailed (UE4 UFunction wrapper).
// The function's first instruction on-disk is replaced with B to an island in
// __TEXT.__const padding (patch_binary.py --apply). The island checks a __bss
// slot: if zero (dylib not installed), it falls through to the original insn;
// if nonzero, it tail-calls our no-op stub so the game never increments
// NumLoadCustomizationFailed and the server never sends reason=144.
//
// Function entry: file offset 0xa30b698 (STP X28,X27,[SP,#-0x50]!), called via
// UE4 UFunction dispatch (void return, no call-site null-check issues).
// Island:         file offset 0xb945ba0 (__TEXT.__const zero-padding).
// __bss slot:     image_base + 0x12bfa890 (written at runtime by install_customization_patch).

static constexpr uintptr_t kCustomFnOff     = 0xa30b698ULL;
static constexpr uintptr_t kCustomIslandOff = 0xb945ba0ULL;
static constexpr uintptr_t kCustomSlotOff   = 0x12bfa890ULL;

// First 4 bytes of the island (LDR word at island+4) used to verify the patch is applied.
static constexpr uint32_t  kCustomIslandLdr = 0xF9444A10U; // LDR X16,[X16,#0x890]

void install_customization_patch();

} // namespace fndiag
