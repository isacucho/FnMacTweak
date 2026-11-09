#include "core/Config.hpp"
#include "core/DiagLog.hpp"
#include "hooks/ObjcUtil.hpp"
#include "update/UpdateHooks.hpp"
#include "update/TerrainPatcher.hpp"

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <cerrno>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace fndiag {
namespace {

using objc::send;
using objc::sel;
using objc::to_string;

IMP g_move_url  = nullptr;
IMP g_move_path = nullptr;
IMP g_copy_url  = nullptr;
IMP g_copy_path = nullptr;
IMP g_exists    = nullptr;

bool g_trace = false;
bool g_dirs  = false;

bool watched(const char* p) { return p && (strstr(p, "CFNetworkDownload") || strstr(p, "BackgroundHttp")); }
bool watched(const std::string& p) { return watched(p.c_str()); }

void ensure_parent(const char* dst) {
    if (!g_dirs || !watched(dst)) return;
    std::string dir(dst);
    size_t slash = dir.rfind('/');
    if (slash == std::string::npos || slash == 0) return;
    dir.resize(slash);
    struct stat st{};
    if (stat(dir.c_str(), &st) == 0) return;
    for (size_t pos = dir.find('/', 1); pos != std::string::npos; pos = dir.find('/', pos + 1))
        mkdir(dir.substr(0, pos).c_str(), 0755);
    int rc = mkdir(dir.c_str(), 0755);
    int saved = errno;
    log_line("mkdir -p %s rc=%d errno=%d", dir.c_str(), rc, rc ? saved : 0);
}

std::string url_path(id url) { return url ? to_string(send<id>(url, sel("path"))) : "(nil)"; }

void log_result(const char* op, const std::string& src, const std::string& dst, bool ok, id error) {
    if (ok) { log_line("%s ok: %s -> %s", op, src.c_str(), dst.c_str()); return; }
    log_line("%s FAILED: %s -> %s domain=%s code=%ld text=%s", op, src.c_str(), dst.c_str(),
             error ? to_string(send<id>(error, sel("domain"))).c_str() : "(nil)",
             error ? send<long>(error, sel("code")) : 0L,
             error ? to_string(send<id>(error, sel("localizedDescription"))).c_str() : "(nil)");
}

bool hook_move_url(id self, SEL cmd, id src, id dst, id* err) {
    ensure_parent(url_path(dst).c_str());
    bool ok = reinterpret_cast<bool (*)(id, SEL, id, id, id*)>(g_move_url)(self, cmd, src, dst, err);
    std::string s = url_path(src), d = url_path(dst);
    if (g_trace && (watched(s) || watched(d))) log_result("moveItemAtURL", s, d, ok, err ? *err : nullptr);
    return ok;
}

bool hook_move_path(id self, SEL cmd, id src, id dst, id* err) {
    ensure_parent(to_string(dst).c_str());
    bool ok = reinterpret_cast<bool (*)(id, SEL, id, id, id*)>(g_move_path)(self, cmd, src, dst, err);
    std::string s = to_string(src), d = to_string(dst);
    if (g_trace && (watched(s) || watched(d))) log_result("moveItemAtPath", s, d, ok, err ? *err : nullptr);
    return ok;
}

bool hook_copy_url(id self, SEL cmd, id src, id dst, id* err) {
    bool ok = reinterpret_cast<bool (*)(id, SEL, id, id, id*)>(g_copy_url)(self, cmd, src, dst, err);
    std::string s = url_path(src), d = url_path(dst);
    if (g_trace && (watched(s) || watched(d))) log_result("copyItemAtURL", s, d, ok, err ? *err : nullptr);
    return ok;
}

bool hook_copy_path(id self, SEL cmd, id src, id dst, id* err) {
    bool ok = reinterpret_cast<bool (*)(id, SEL, id, id, id*)>(g_copy_path)(self, cmd, src, dst, err);
    std::string s = to_string(src), d = to_string(dst);
    if (g_trace && (watched(s) || watched(d))) log_result("copyItemAtPath", s, d, ok, err ? *err : nullptr);
    return ok;
}

bool hook_exists(id self, SEL cmd, id path) {
    bool r = reinterpret_cast<bool (*)(id, SEL, id)>(g_exists)(self, cmd, path);
    std::string p = to_string(path);
    if (watched(p)) log_line("fileExistsAtPath exists=%d path=%s", r, p.c_str());
    return r;
}

void trace_posix(const char* op, const char* path, int rc, int saved, const char* extra = "") {
    if (!g_trace || !watched(path)) return;
    log_line("%s rc=%d errno=%d (%s) %s path=%s", op, rc, rc < 0 ? saved : 0, rc < 0 ? strerror(saved) : "ok", extra, path);
}

// fd tracking: when fndiag_open sees a .utoc opened O_RDONLY, it registers the fd
// so the read/pread/mmap hooks know to patch the returned bytes in-memory.
static constexpr int kMaxTrackedFd = 4096;
static volatile bool g_utoc_fd[kMaxTrackedFd]; // zero-initialized (BSS)

static inline void  utoc_fd_set(int fd)  { if (fd >= 0 && fd < kMaxTrackedFd) g_utoc_fd[fd] = true; }
static inline void  utoc_fd_clear(int fd){ if (fd >= 0 && fd < kMaxTrackedFd) g_utoc_fd[fd] = false; }
static inline bool  utoc_fd_is(int fd)   { return fd >= 0 && fd < kMaxTrackedFd && g_utoc_fd[fd]; }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
inline int     raw_stat(const char* p, struct stat* st)                        { return (int)syscall(SYS_stat64, p, st); }
inline int     raw_lstat(const char* p, struct stat* st)                       { return (int)syscall(SYS_lstat64, p, st); }
inline int     raw_access(const char* p, int mode)                             { return (int)syscall(SYS_access, p, mode); }
inline int     raw_open(const char* p, int flags, int mode)                    { return (int)syscall(SYS_open, p, flags, mode); }
inline int     raw_close(int fd)                                               { return (int)syscall(SYS_close, fd); }
inline ssize_t raw_read(int fd, void* buf, size_t n)                           { return (ssize_t)syscall(SYS_read, fd, buf, n); }
inline ssize_t raw_pread(int fd, void* buf, size_t n, off_t off)              { return (ssize_t)syscall(SYS_pread, fd, buf, n, off); }
inline int     raw_unlink(const char* p)                                       { return (int)syscall(SYS_unlink, p); }
inline int     raw_rename(const char* a, const char* b)                        { return (int)syscall(SYS_rename, a, b); }
#pragma clang diagnostic pop

} // namespace

extern "C" {

int fndiag_stat(const char* p, struct stat* st) {
    int rc = raw_stat(p, st), saved = errno;
    trace_posix("stat", p, rc, saved);
    errno = saved; return rc;
}

int fndiag_lstat(const char* p, struct stat* st) {
    int rc = raw_lstat(p, st), saved = errno;
    trace_posix("lstat", p, rc, saved);
    errno = saved; return rc;
}

int fndiag_access(const char* p, int mode) {
    int rc = raw_access(p, mode), saved = errno;
    trace_posix("access", p, rc, saved);
    errno = saved; return rc;
}

int fndiag_open(const char* p, int flags, ...) {
    int mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap); }
    int rc = raw_open(p, flags, mode), saved = errno;
    // Track .utoc fds opened for reading; patching happens in-memory in fndiag_read/pread.
    if (rc >= 0 && p && strstr(p, ".utoc") && (flags & O_ACCMODE) == O_RDONLY)
        utoc_fd_set(rc);
    trace_posix("open", p, rc, saved);
    errno = saved; return rc;
}

int fndiag_unlink(const char* p) {
    int rc = raw_unlink(p), saved = errno;
    trace_posix("unlink", p, rc, saved);
    errno = saved; return rc;
}

int fndiag_rename(const char* from, const char* to) {
    ensure_parent(to);
    int rc = raw_rename(from, to), saved = errno;
    if (watched(to))   trace_posix("rename(dst)", to, rc, saved, from ? from : "(null)");
    else               trace_posix("rename", from, rc, saved, to ? to : "(null)");
    // No disk patch here; the game will open the renamed .utoc for reading and
    // fndiag_open will register the fd so read/pread hooks patch in-memory.
    errno = saved; return rc;
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
// visibility("default") overrides -fvisibility=hidden so DYLD adds it to flat namespace.
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

void install_file_hooks() {
    g_trace = config().trace_files;
    g_dirs  = config().create_dirs;
    if (!g_trace && !g_dirs) return;
    const char* cls = "NSFileManager";
    bool a = objc::replace_instance_method(cls, "moveItemAtURL:toURL:error:",   reinterpret_cast<IMP>(hook_move_url),  &g_move_url);
    bool b = objc::replace_instance_method(cls, "moveItemAtPath:toPath:error:", reinterpret_cast<IMP>(hook_move_path), &g_move_path);
    bool c = false, d = false, e = false;
    if (g_trace) {
        c = objc::replace_instance_method(cls, "copyItemAtURL:toURL:error:",   reinterpret_cast<IMP>(hook_copy_url),  &g_copy_url);
        d = objc::replace_instance_method(cls, "copyItemAtPath:toPath:error:", reinterpret_cast<IMP>(hook_copy_path), &g_copy_path);
        e = objc::replace_instance_method(cls, "fileExistsAtPath:",            reinterpret_cast<IMP>(hook_exists),    &g_exists);
    }
    log_line("file hooks: trace=%d create_dirs=%d moveURL=%d movePath=%d copyURL=%d copyPath=%d exists=%d",
             g_trace, g_dirs, a, b, c, d, e);
}

} // namespace fndiag
