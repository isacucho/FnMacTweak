#pragma once
#include <cstdint>

namespace fndiag {

// Vtable pointer patch for HandleCustomizationFailed (UFortCustomizationAssetLoader).
// Redirects the vtable slot in __DATA_CONST to our no-op stub so the game never
// increments NumLoadCustomizationFailed and the server never sends reason=144.
//
// Patching __DATA_CONST (not __TEXT) avoids the CS_KILL enforcement that fires
// when a modified __TEXT page is executed on this iOS-platform binary.
//
// kHandleCustomizationFailedVtableOff: offset from image base to the vtable slot
// (8-byte pointer) that holds HandleCustomizationFailed's address at runtime.
// Zero = patch disabled.
//
// To discover: run Fortnite with LLDB attached, then:
//   (lldb) command script import tools/lldb_diag.py
//   (lldb) lcf_find_ptr
// The command prints "ptr_offset_from_base=0x<hex>" - copy that here.
// (Also run lcf_find to get the function offset for reference.)

static constexpr uint64_t kHandleCustomizationFailedVtableOff = 0ULL; // fill after lcf_find_ptr

void install_customization_patch();

} // namespace fndiag
