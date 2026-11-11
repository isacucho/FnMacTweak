#pragma once
#include <cstdint>

namespace fndiag {

// Trampoline hook for HandleCustomizationFailed (UFortCustomizationAssetLoader).
// When the game calls this delegate, the failure counter that drives reason=144
// kicks would be incremented. The hook replaces the function body with a no-op
// ret so the counter stays at zero and the server never sees load failures.
//
// kHandleCustomizationFailedOff: offset from image base to the first instruction
// of HandleCustomizationFailed. Filled in after LLDB discovery (lcf_find command
// in tools/lldb_diag.py). Zero = patch disabled.
//
// To discover: run Fortnite with LLDB attached, execute:
//   (lldb) command script import tools/lldb_diag.py
//   (lldb) lcf_find
// The command logs "lcf_find: fn_offset=0x<hex>" to stdout - copy that value here.

static constexpr uint64_t kHandleCustomizationFailedOff = 0x0ULL;  // FILL IN

void install_customization_patch();

} // namespace fndiag
