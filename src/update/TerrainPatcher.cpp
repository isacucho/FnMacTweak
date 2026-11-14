#include "update/TerrainPatcher.hpp"
#include "core/DiagLog.hpp"

#include <cstdint>
#include <cstring>

namespace fndiag {
namespace {

// PackageId 0x332A476D80318A3E as little-endian bytes.
// Missing from all mounted IoStore containers since the Nov-2 update removed
// pakchunks 1015/1018/1019/1021/1026. Replacing with FPackageId::Invalid()
// (0xFFFFFFFFFFFFFFFF) makes FAsyncPackage2::ImportPackagesRecursively skip the
// prerequisite check, preventing LoadErrors -> KickPlayerPakFileViolation.
static constexpr uint8_t k_missing[8] = {
    0x3E, 0x8A, 0x31, 0x80, 0x6D, 0x47, 0x2A, 0x33
};
static constexpr uint8_t k_invalid[8] = {
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
};

} // namespace

int patch_utoc_mapping(void* ptr, size_t len, const char* path) {
    if (!ptr || len < 8) return 0;
    uint8_t* buf = static_cast<uint8_t*>(ptr);
    int patches = 0;
    for (size_t i = 0; i + 8 <= len; ++i) {
        if (memcmp(buf + i, k_missing, 8) == 0) {
            memcpy(buf + i, k_invalid, 8);
            ++patches;
            i += 7;
        }
    }
    if (patches)
        log_line("[TerrainPatcher] mmap-patched %d occurrence(s) in %s (len=%zu)",
                 patches, path, len);
    return patches;
}

} // namespace fndiag
