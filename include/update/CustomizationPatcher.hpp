#pragma once
#include <cstdint>

namespace fndiag {

// MSHookFunction hook for execHandleCustomizationFailed (UE4 UFunction wrapper).
// Replaces the function at runtime so it never increments NumLoadCustomizationFailed
// and the server never sends reason=144 kicks.
//
// Function entry: file offset 0xa30b698
//   STP X28,X27,[SP,#-0x50]! = 0xA9F66FFC (43.10 build 60278837)
// No disk patch or __bss slot needed; Substrate handles the __TEXT hook.

// Known file offsets for execHandleCustomizationFailed
// 43.10 (build 60278837): 0xa30b698
static constexpr uintptr_t kCustomFnOff      = 0xa30b698ULL;
static constexpr uint32_t  kCustomFnPrologue = 0xA9F66FFCU; // STP X28,X27,[SP,#-0x50]!

void install_customization_patch();

} // namespace fndiag
