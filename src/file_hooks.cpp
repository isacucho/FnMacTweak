#include "fndiag/config.hpp"
#include "fndiag/hooks.hpp"
#include "fndiag/log.hpp"
#include "fndiag/objc_util.hpp"

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cerrno>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <string>

namespace fndiag {
namespace {

using objc::send;
using objc::sel;
using objc::to_string;

IMP g_move_url = nullptr;
IMP g_move_path = nullptr;
IMP g_copy_url = nullptr;
IMP g_copy_path = nullptr;
IMP g_exists = nullptr;

// Temporales de NSURLSession (CFNetworkDownload_*.tmp) y carpeta de descargas en segundo
// plano del motor (BackgroundHttp).
bool watched(const char *p) { return p && (strstr(p, "CFNetworkDownload") || strstr(p, "BackgroundHttp")); }
bool watched(const std::string &p) { return watched(p.c_str()); }

// El motor mueve cada descarga a PersistentDownloadDir/BackgroundHttp/<build>/<id>.tmp sin
// crear antes <build>/: si falta, el rename falla con ENOENT y la descarga se da por perdida
// (SetDownloadResult 500). Con create_dirs se crea el directorio padre antes de mover.
void ensure_parent(const char *dst) {
    if (!watched(dst) || !config().create_dirs)
        return;
    std::string dir(dst);
    size_t slash = dir.rfind('/');
    if (slash == std::string::npos || slash == 0)
        return;
    dir.resize(slash);
    struct stat st{};
    if (stat(dir.c_str(), &st) == 0)
        return;
    for (size_t pos = dir.find('/', 1); pos != std::string::npos; pos = dir.find('/', pos + 1))
        mkdir(dir.substr(0, pos).c_str(), 0755); // EEXIST en los que ya existen
    int rc = mkdir(dir.c_str(), 0755);
    int saved = errno;
    log_line("mkdir -p %s rc=%d errno=%d", dir.c_str(), rc, rc ? saved : 0);
}

std::string url_path(id url) { return url ? to_string(send<id>(url, sel("path"))) : "(nil)"; }

void log_result(const char *op, const std::string &src, const std::string &dst, bool ok, id error) {
    if (ok) {
        log_line("%s ok: %s -> %s", op, src.c_str(), dst.c_str());
        return;
    }
    log_line("%s FAILED: %s -> %s domain=%s code=%ld text=%s", op, src.c_str(), dst.c_str(),
             error ? to_string(send<id>(error, sel("domain"))).c_str() : "(nil)", error ? send<long>(error, sel("code")) : 0L,
             error ? to_string(send<id>(error, sel("localizedDescription"))).c_str() : "(nil)");
}

bool hook_move_url(id self, SEL cmd, id src, id dst, id *err) {
    ensure_parent(url_path(dst).c_str());
    bool ok = reinterpret_cast<bool (*)(id, SEL, id, id, id *)>(g_move_url)(self, cmd, src, dst, err);
    std::string s = url_path(src), d = url_path(dst);
    if (watched(s) || watched(d))
        log_result("moveItemAtURL", s, d, ok, err ? *err : nullptr);
    return ok;
}

bool hook_move_path(id self, SEL cmd, id src, id dst, id *err) {
    ensure_parent(to_string(dst).c_str());
    bool ok = reinterpret_cast<bool (*)(id, SEL, id, id, id *)>(g_move_path)(self, cmd, src, dst, err);
    std::string s = to_string(src), d = to_string(dst);
    if (watched(s) || watched(d))
        log_result("moveItemAtPath", s, d, ok, err ? *err : nullptr);
    return ok;
}

bool hook_copy_url(id self, SEL cmd, id src, id dst, id *err) {
    bool ok = reinterpret_cast<bool (*)(id, SEL, id, id, id *)>(g_copy_url)(self, cmd, src, dst, err);
    std::string s = url_path(src), d = url_path(dst);
    if (watched(s) || watched(d))
        log_result("copyItemAtURL", s, d, ok, err ? *err : nullptr);
    return ok;
}

bool hook_copy_path(id self, SEL cmd, id src, id dst, id *err) {
    bool ok = reinterpret_cast<bool (*)(id, SEL, id, id, id *)>(g_copy_path)(self, cmd, src, dst, err);
    std::string s = to_string(src), d = to_string(dst);
    if (watched(s) || watched(d))
        log_result("copyItemAtPath", s, d, ok, err ? *err : nullptr);
    return ok;
}

bool hook_exists(id self, SEL cmd, id path) {
    bool r = reinterpret_cast<bool (*)(id, SEL, id)>(g_exists)(self, cmd, path);
    std::string p = to_string(path);
    if (watched(p))
        log_line("fileExistsAtPath exists=%d path=%s", r, p.c_str());
    return r;
}

// Registra una llamada POSIX sobre una ruta vigilada conservando errno.
void trace(const char *op, const char *path, int rc, int saved, const char *extra = "") {
    // watched() primero: no reserva memoria, y estas funciones pueden llamarse antes de que
    // libc++ y config() esten inicializados.
    if (!watched(path) || !config().trace_files)
        return;
    log_line("%s rc=%d errno=%d (%s) %s path=%s", op, rc, rc < 0 ? saved : 0, rc < 0 ? strerror(saved) : "ok", extra, path);
}

} // namespace

// Las funciones POSIX se interponen con dyld: no pasan por NSFileManager (las usa el codigo
// C++ del motor). No se interponen las llamadas de esta misma dylib.
extern "C" {

int fndiag_stat(const char *p, struct stat *st) {
    int rc = stat(p, st), saved = errno;
    trace("stat", p, rc, saved);
    errno = saved;
    return rc;
}

int fndiag_lstat(const char *p, struct stat *st) {
    int rc = lstat(p, st), saved = errno;
    trace("lstat", p, rc, saved);
    errno = saved;
    return rc;
}

int fndiag_access(const char *p, int mode) {
    int rc = access(p, mode), saved = errno;
    trace("access", p, rc, saved);
    errno = saved;
    return rc;
}

int fndiag_open(const char *p, int flags, ...) {
    int mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, int);
        va_end(ap);
    }
    int rc = open(p, flags, mode), saved = errno;
    trace("open", p, rc, saved);
    errno = saved;
    return rc;
}

int fndiag_unlink(const char *p) {
    int rc = unlink(p), saved = errno;
    trace("unlink", p, rc, saved);
    errno = saved;
    return rc;
}

int fndiag_rename(const char *from, const char *to) {
    fndiag::ensure_parent(to);
    int rc = rename(from, to), saved = errno;
    if (watched(to))
        trace("rename(dst)", to, rc, saved, from ? from : "(null)");
    else
        trace("rename", from, rc, saved, to ? to : "(null)");
    errno = saved;
    return rc;
}

} // extern "C"

struct Interpose {
    const void *replacement;
    const void *original;
};
#define FNDIAG_INTERPOSE(fn, orig) {reinterpret_cast<const void *>(fn), reinterpret_cast<const void *>(orig)}
__attribute__((used, section("__DATA,__interpose"))) static const Interpose g_interpose[] = {
    FNDIAG_INTERPOSE(fndiag_stat, stat),   FNDIAG_INTERPOSE(fndiag_lstat, lstat),   FNDIAG_INTERPOSE(fndiag_access, access),
    FNDIAG_INTERPOSE(fndiag_open, open),   FNDIAG_INTERPOSE(fndiag_unlink, unlink), FNDIAG_INTERPOSE(fndiag_rename, rename),
};

void install_file_hooks() {
    if (!config().trace_files && !config().create_dirs)
        return;
    const char *cls = "NSFileManager";
    bool a = objc::replace_instance_method(cls, "moveItemAtURL:toURL:error:", reinterpret_cast<IMP>(hook_move_url), &g_move_url);
    bool b = objc::replace_instance_method(cls, "moveItemAtPath:toPath:error:", reinterpret_cast<IMP>(hook_move_path), &g_move_path);
    bool c = objc::replace_instance_method(cls, "copyItemAtURL:toURL:error:", reinterpret_cast<IMP>(hook_copy_url), &g_copy_url);
    bool d = objc::replace_instance_method(cls, "copyItemAtPath:toPath:error:", reinterpret_cast<IMP>(hook_copy_path), &g_copy_path);
    bool e = objc::replace_instance_method(cls, "fileExistsAtPath:", reinterpret_cast<IMP>(hook_exists), &g_exists);
    log_line("file hooks: moveURL=%d movePath=%d copyURL=%d copyPath=%d exists=%d posix=interpose", a, b, c, d, e);
}

} // namespace fndiag
