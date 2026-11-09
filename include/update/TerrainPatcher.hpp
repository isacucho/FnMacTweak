#pragma once
#include <string>

namespace fndiag {
// Purges stale bundles and pre-scans UTOCs for logging. Actual patching
// happens in-memory via the read/pread/mmap interpose hooks in FileHooks.cpp.
void install_terrain_patch(const std::string& container_root);

// Patches the missing package ID bytes (332A476D80318A3E -> FFFFFFFFFFFFFFFF)
// in an already-mapped/read UTOC buffer. Called from read, pread and mmap
// interpose hooks in FileHooks.cpp. path is used for logging only.
// Returns the number of patches applied.
int patch_utoc_mapping(void* ptr, size_t len, const char* path);
} // namespace fndiag
