#pragma once
#include <cstddef>

namespace fndiag {

// Patches the missing package ID bytes (332A476D80318A3E -> FFFFFFFFFFFFFFFF)
// in an already-mapped/read UTOC buffer. Called from read/pread interpose hooks.
// Returns the number of patches applied.
int patch_utoc_mapping(void* ptr, size_t len, const char* path);

} // namespace fndiag
