#pragma once
#include <string>

namespace fndiag {
// Patches GameCustom and Encrypted bundle UTOCs to remove the missing package
// dependency 332A476D80318A3E (absent since the Nov-2 game update).
// Must be called after log_init() and before the game mounts any IoStore container.
void install_terrain_patch(const std::string& container_root);

// Patches a single UTOC file in-place if it contains the missing package ID.
// Returns the number of occurrences patched (0 = not needed, -1 = error).
// Safe to call from any thread; intended for use in the rename hook so the
// UTOC is patched the moment the download system moves it to its final path.
int patch_utoc_at_path(const char* path);

// Patches the missing package ID bytes in an already-mmap'd UTOC region.
// path is used for logging only. Returns the number of patches applied.
// Called from the mmap interpose hook after IoStore maps a .utoc file.
int patch_utoc_mapping(void* ptr, size_t len, const char* path);
} // namespace fndiag
