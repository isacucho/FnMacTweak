#include "update/TerrainPatcher.hpp"
#include "core/DiagLog.hpp"

#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>
#include <string>
#include <vector>
#include <cstdint>

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

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static int sys_open(const char* p, int f, int m) { return (int)syscall(SYS_open, p, f, m); }
static int sys_unlink(const char* p)              { return (int)syscall(SYS_unlink, p); }
static int sys_rmdir(const char* p)               { return (int)syscall(SYS_rmdir, p); }
#pragma clang diagnostic pop

// -----------------------------------------------------------------------
// IoStore UTOC helpers
// -----------------------------------------------------------------------

// UE5 FIoStoreTocHeader magic ("-==--==--==--==-")
static const uint8_t k_utoc_magic[16] = {
    0x2D,0x3D,0x3D,0x2D,0x2D,0x3D,0x3D,0x2D,
    0x2D,0x3D,0x3D,0x2D,0x2D,0x3D,0x3D,0x2D
};

// Read 5 little-endian bytes as uint64_t (FIoOffsetAndLength packing).
static uint64_t read_u40_le(const uint8_t* p) {
    return (uint64_t)p[0] | ((uint64_t)p[1] << 8) | ((uint64_t)p[2] << 16) |
           ((uint64_t)p[3] << 24) | ((uint64_t)p[4] << 32);
}

// Returns the minimum required size of the companion .ucas file by scanning
// every FIoOffsetAndLength entry in the UTOC and finding max(offset + length).
// Returns 0 on parse error or if the UTOC has no entries.
static uint64_t utoc_min_ucas_size(const char* utoc_path) {
    int fd = sys_open(utoc_path, O_RDONLY, 0);
    if (fd < 0) return 0;

    // Read first 256 bytes (standard FIoStoreTocHeader size).
    uint8_t hdr[256] = {};
    if (read(fd, hdr, sizeof(hdr)) < (ssize_t)sizeof(hdr)) { close(fd); return 0; }

    if (memcmp(hdr, k_utoc_magic, 16) != 0) { close(fd); return 0; }

    uint32_t header_size = 0, entry_count = 0;
    memcpy(&header_size, hdr + 20, 4);  // TocHeaderSize
    memcpy(&entry_count, hdr + 24, 4);  // TocEntryCount
    if (header_size < 32 || entry_count == 0 || entry_count > 1000000) { close(fd); return 0; }

    // Seek past header and ChunkId table (12 bytes per entry) to FIoOffsetAndLength table.
    off_t offset_table = (off_t)header_size + (off_t)entry_count * 12;
    if (lseek(fd, offset_table, SEEK_SET) < 0) { close(fd); return 0; }

    const size_t entry_sz = 10;  // FIoOffsetAndLength: 5 bytes offset + 5 bytes length
    std::vector<uint8_t> table(entry_count * entry_sz);
    if (read(fd, table.data(), table.size()) < (ssize_t)table.size()) { close(fd); return 0; }
    close(fd);

    uint64_t max_end = 0;
    for (uint32_t i = 0; i < entry_count; ++i) {
        const uint8_t* e = table.data() + i * entry_sz;
        uint64_t off = read_u40_le(e);
        uint64_t len = read_u40_le(e + 5);
        uint64_t end = off + len;
        if (end > max_end) max_end = end;
    }
    return max_end;
}

// Recursively delete all files under dir, then rmdir it.
// Only descends two levels (bundle/subdir/file) which is sufficient for pak bundles.
static void rmdir_bundle(const std::string& dir) {
    DIR* d = opendir(dir.c_str());
    if (!d) { sys_rmdir(dir.c_str()); return; }
    struct dirent* ent;
    while ((ent = readdir(d)) != nullptr) {
        if (ent->d_name[0] == '.') continue;
        std::string child = dir + "/" + ent->d_name;
        struct stat st{};
        if (stat(child.c_str(), &st) != 0) continue;
        if (S_ISDIR(st.st_mode)) {
            // One more level deep.
            DIR* d2 = opendir(child.c_str());
            if (d2) {
                struct dirent* e2;
                while ((e2 = readdir(d2)) != nullptr) {
                    if (e2->d_name[0] == '.') continue;
                    sys_unlink((child + "/" + e2->d_name).c_str());
                }
                closedir(d2);
                sys_rmdir(child.c_str());
            }
        } else {
            sys_unlink(child.c_str());
        }
    }
    closedir(d);
    sys_rmdir(dir.c_str());
}

// Scan InstalledBundles/Encrypted* directories: for every .ucas file, read its
// companion .utoc to get the minimum expected size. If the .ucas is shorter,
// the bundle is stale/incomplete — delete it so the game re-downloads.
static void purge_stale_encrypted_bundles(const std::string& container_root) {
    std::string bundles = container_root
        + "/Documents/FortniteGame/PersistentDownloadDir/InstalledBundles";

    DIR* d = opendir(bundles.c_str());
    if (!d) return;

    struct dirent* ent;
    while ((ent = readdir(d)) != nullptr) {
        if (ent->d_name[0] == '.') continue;
        if (strncmp(ent->d_name, "Encrypted", 9) != 0) continue;

        std::string bundle_dir = bundles + "/" + ent->d_name;
        std::string paks_dir   = bundle_dir + "/fortnitegame/content/paks";

        DIR* pd = opendir(paks_dir.c_str());
        if (!pd) {
            // No paks subdirectory at all — bundle dir is empty placeholder, purge it.
            log_line("[TerrainPatcher] no paks dir, purging empty bundle: %s", bundle_dir.c_str());
            rmdir_bundle(bundle_dir);
            continue;
        }

        bool has_ucas = false;
        bool stale    = false;
        struct dirent* pent;
        while ((pent = readdir(pd)) != nullptr) {
            if (pent->d_name[0] == '.') continue;
            const char* name = pent->d_name;
            size_t nlen = strlen(name);
            if (nlen < 5 || strcmp(name + nlen - 5, ".ucas") != 0) continue;

            has_ucas = true;
            std::string ucas = paks_dir + "/" + name;
            std::string utoc = ucas.substr(0, ucas.size() - 5) + ".utoc";

            struct stat st{};
            if (stat(ucas.c_str(), &st) != 0) continue;
            off_t ucas_size = st.st_size;

            uint64_t needed = utoc_min_ucas_size(utoc.c_str());
            if (needed == 0) continue;  // couldn't parse UTOC, skip

            if ((uint64_t)ucas_size < needed) {
                log_line("[TerrainPatcher] stale ucas: size=%lld needed=%llu path=%s",
                         (long long)ucas_size, (unsigned long long)needed, ucas.c_str());
                stale = true;
                break;
            }
        }
        closedir(pd);

        if (!has_ucas) {
            // Paks dir exists but no .ucas files — bundle incomplete, purge it.
            log_line("[TerrainPatcher] empty paks dir, purging incomplete bundle: %s", bundle_dir.c_str());
            rmdir_bundle(bundle_dir);
        } else if (stale) {
            log_line("[TerrainPatcher] deleting stale bundle: %s", bundle_dir.c_str());
            rmdir_bundle(bundle_dir);
        }
    }
    closedir(d);
}

static int patch_utoc(const char* path) {
    // Try read-only first to diagnose contents even if write fails
    int rfd = sys_open(path, O_RDONLY, 0);
    if (rfd < 0) {
        log_line("[TerrainPatcher] open RDONLY failed errno=%d (%s): %s",
                 errno, strerror(errno), path);
        return -1;
    }

    struct stat st{};
    fstat(rfd, &st);
    off_t sz = st.st_size;

    if (sz < 8) { close(rfd); return 0; }

    std::vector<uint8_t> buf(static_cast<size_t>(sz));
    ssize_t nr = read(rfd, buf.data(), static_cast<size_t>(sz));
    close(rfd);

    if (nr != sz) {
        log_line("[TerrainPatcher] read failed (%zd/%lld): %s", nr, (long long)sz, path);
        return -1;
    }

    // Count occurrences before attempting any write
    int patches = 0;
    for (size_t i = 0; i + 8 <= buf.size(); ++i) {
        if (memcmp(buf.data() + i, k_missing, 8) == 0) {
            memcpy(buf.data() + i, k_invalid, 8);
            ++patches;
            i += 7;
        }
    }

    log_line("[TerrainPatcher] scan %s sz=%lld found=%d", path, (long long)sz, patches);

    if (patches == 0) return 0;

    // Write patched buffer back
    int wfd = sys_open(path, O_WRONLY, 0);
    if (wfd < 0) {
        log_line("[TerrainPatcher] open WRONLY failed errno=%d (%s): %s",
                 errno, strerror(errno), path);
        // Write to a temp file as fallback (game will not pick it up, but useful for
        // confirming the bytes ARE there if the write path is truly blocked)
        return -1;
    }

    ssize_t nw = write(wfd, buf.data(), static_cast<size_t>(sz));
    close(wfd);

    if (nw != sz) {
        log_line("[TerrainPatcher] partial write (%zd/%lld): %s", nw, (long long)sz, path);
        return -1;
    }

    log_line("[TerrainPatcher] patched %d occurrence(s) in %s", patches, path);
    return patches;
}

// Scan a directory for *.utoc files and patch each one.
static int patch_utoc_dir(const std::string& paks_dir) {
    DIR* d = opendir(paks_dir.c_str());
    if (!d) return 0;

    int total = 0;
    struct dirent* ent;
    while ((ent = readdir(d)) != nullptr) {
        if (ent->d_name[0] == '.') continue;
        const char* name = ent->d_name;
        size_t nlen = strlen(name);
        if (nlen < 5 || strcmp(name + nlen - 5, ".utoc") != 0) continue;

        std::string utoc = paks_dir + "/" + name;
        int n = patch_utoc(utoc.c_str());
        if (n > 0) total += n;
    }
    closedir(d);
    return total;
}

} // namespace

int patch_utoc_at_path(const char* path) {
    return patch_utoc(path);
}

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

void install_terrain_patch(const std::string& container_root) {
    // Purge stale Encrypted bundles before anything else so the game re-downloads clean.
    purge_stale_encrypted_bundles(container_root);

    std::string base = container_root
        + "/Documents/FortniteGame/PersistentDownloadDir";

    // 1. GameCustom/InstalledBundles — legacy terrain bundles (*/plugin.utoc)
    {
        std::string bundles = base + "/GameCustom/InstalledBundles";
        log_line("[TerrainPatcher] scanning GameCustom: %s", bundles.c_str());
        DIR* d = opendir(bundles.c_str());
        if (d) {
            int total = 0;
            struct dirent* ent;
            while ((ent = readdir(d)) != nullptr) {
                if (ent->d_name[0] == '.') continue;
                std::string utoc = bundles + "/" + ent->d_name + "/plugin.utoc";
                struct stat st{};
                if (stat(utoc.c_str(), &st) != 0) continue;
                int n = patch_utoc(utoc.c_str());
                if (n > 0) total += n;
            }
            closedir(d);
            log_line("[TerrainPatcher] GameCustom done patches=%d", total);
        } else {
            log_line("[TerrainPatcher] GameCustom opendir failed errno=%d", errno);
        }
    }

    // 2. InstalledBundles/Encrypted* — pakchunk1009-1012/1035/1037
    //    Layout: Encrypted<n>/fortnitegame/content/paks/*.utoc
    {
        std::string bundles = base + "/InstalledBundles";
        log_line("[TerrainPatcher] scanning Encrypted: %s", bundles.c_str());
        DIR* d = opendir(bundles.c_str());
        if (d) {
            int total = 0;
            struct dirent* ent;
            while ((ent = readdir(d)) != nullptr) {
                if (ent->d_name[0] == '.') continue;
                if (strncmp(ent->d_name, "Encrypted", 9) != 0) continue;
                std::string paks = bundles + "/" + ent->d_name
                                   + "/fortnitegame/content/paks";
                total += patch_utoc_dir(paks);
            }
            closedir(d);
            log_line("[TerrainPatcher] Encrypted done patches=%d", total);
        } else {
            log_line("[TerrainPatcher] Encrypted opendir failed errno=%d", errno);
        }
    }
}

} // namespace fndiag
