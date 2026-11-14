#include "update/TerrainPatcher.hpp"

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <cerrno>
#include <cstdarg>
#include <cstddef>
#include <cstdio>
#include <cstring>

namespace fndiag {
namespace {

// fd tracking: when fndiag_open sees a .utoc opened O_RDONLY, it registers the fd
// so the read/pread hooks know to patch the returned bytes in-memory.
static constexpr int kMaxTrackedFd = 4096;
static volatile bool g_utoc_fd[kMaxTrackedFd]; // zero-initialized (BSS)

static inline void  utoc_fd_set(int fd)  { if (fd >= 0 && fd < kMaxTrackedFd) g_utoc_fd[fd] = true; }
static inline void  utoc_fd_clear(int fd){ if (fd >= 0 && fd < kMaxTrackedFd) g_utoc_fd[fd] = false; }
static inline bool  utoc_fd_is(int fd)   { return fd >= 0 && fd < kMaxTrackedFd && g_utoc_fd[fd]; }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
inline int     raw_stat(const char* p, struct stat* st)       { return (int)syscall(SYS_stat64, p, st); }
inline int     raw_lstat(const char* p, struct stat* st)      { return (int)syscall(SYS_lstat64, p, st); }
inline int     raw_access(const char* p, int mode)            { return (int)syscall(SYS_access, p, mode); }
inline int     raw_open(const char* p, int flags, int mode)   { return (int)syscall(SYS_open, p, flags, mode); }
inline int     raw_close(int fd)                              { return (int)syscall(SYS_close, fd); }
inline ssize_t raw_read(int fd, void* buf, size_t n)          { return (ssize_t)syscall(SYS_read, fd, buf, n); }
inline ssize_t raw_pread(int fd, void* buf, size_t n, off_t o){ return (ssize_t)syscall(SYS_pread, fd, buf, n, o); }
inline int     raw_unlink(const char* p)                      { return (int)syscall(SYS_unlink, p); }
inline int     raw_rename(const char* a, const char* b)       { return (int)syscall(SYS_rename, a, b); }
#pragma clang diagnostic pop

} // namespace

extern "C" {

int fndiag_stat(const char* p, struct stat* st) { return raw_stat(p, st); }
int fndiag_lstat(const char* p, struct stat* st){ return raw_lstat(p, st); }
int fndiag_access(const char* p, int mode)      { return raw_access(p, mode); }
int fndiag_unlink(const char* p)                { return raw_unlink(p); }
int fndiag_rename(const char* a, const char* b) { return raw_rename(a, b); }

int fndiag_open(const char* p, int flags, ...) {
    int mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap); }
    int rc = raw_open(p, flags, mode);
    if (rc >= 0 && p && strstr(p, ".utoc") && (flags & O_ACCMODE) == O_RDONLY)
        utoc_fd_set(rc);
    return rc;
}

int fndiag_close(int fd) {
    utoc_fd_clear(fd);
    return raw_close(fd);
}

ssize_t fndiag_read(int fd, void* buf, size_t nbytes) {
    ssize_t nr = raw_read(fd, buf, nbytes);
    if (nr > 0 && utoc_fd_is(fd))
        patch_utoc_mapping(buf, (size_t)nr, "read");
    return nr;
}

ssize_t fndiag_pread(int fd, void* buf, size_t nbytes, off_t offset) {
    ssize_t nr = raw_pread(fd, buf, nbytes, offset);
    if (nr > 0 && utoc_fd_is(fd))
        patch_utoc_mapping(buf, (size_t)nr, "pread");
    return nr;
}

// _availability_version_check is an iOS libc function absent from macOS libSystem.
// The game binary imports it as a required symbol; exporting it here satisfies DYLD.
__attribute__((visibility("default")))
bool availability_version_check(uint32_t, void*) { return false; }

} // extern "C"

struct Interpose { const void* replacement; const void* original; };
#define FNDIAG_INTERPOSE(fn, orig) {reinterpret_cast<const void*>(fn), reinterpret_cast<const void*>(orig)}
__attribute__((used, section("__DATA,__interpose"))) static const Interpose g_interpose[] = {
    FNDIAG_INTERPOSE(fndiag_stat,   stat),
    FNDIAG_INTERPOSE(fndiag_lstat,  lstat),
    FNDIAG_INTERPOSE(fndiag_access, access),
    FNDIAG_INTERPOSE(fndiag_open,   open),
    FNDIAG_INTERPOSE(fndiag_close,  close),
    FNDIAG_INTERPOSE(fndiag_read,   read),
    FNDIAG_INTERPOSE(fndiag_pread,  pread),
    FNDIAG_INTERPOSE(fndiag_unlink, unlink),
    FNDIAG_INTERPOSE(fndiag_rename, rename),
};

} // namespace fndiag
