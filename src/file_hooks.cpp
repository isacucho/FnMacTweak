#include "fndiag/config.hpp"
#include "fndiag/hooks.hpp"
#include "fndiag/log.hpp"
#include "fndiag/objc_util.hpp"

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <string>

namespace fndiag {
namespace {

using objc::send;
using objc::sel;
using objc::to_string;

// Los temporales de NSURLSession se llaman CFNetworkDownload_*.tmp.
constexpr const char *kMarker = "CFNetworkDownload";

IMP g_move_url = nullptr;
IMP g_move_path = nullptr;
IMP g_copy_url = nullptr;
IMP g_copy_path = nullptr;

std::string url_path(id url) { return url ? to_string(send<id>(url, sel("path"))) : "(nil)"; }

bool interesting(const std::string &path) { return path.find(kMarker) != std::string::npos; }

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
    bool ok = reinterpret_cast<bool (*)(id, SEL, id, id, id *)>(g_move_url)(self, cmd, src, dst, err);
    std::string s = url_path(src);
    if (interesting(s))
        log_result("moveItemAtURL", s, url_path(dst), ok, err ? *err : nullptr);
    return ok;
}

bool hook_move_path(id self, SEL cmd, id src, id dst, id *err) {
    bool ok = reinterpret_cast<bool (*)(id, SEL, id, id, id *)>(g_move_path)(self, cmd, src, dst, err);
    std::string s = to_string(src);
    if (interesting(s))
        log_result("moveItemAtPath", s, to_string(dst), ok, err ? *err : nullptr);
    return ok;
}

bool hook_copy_url(id self, SEL cmd, id src, id dst, id *err) {
    bool ok = reinterpret_cast<bool (*)(id, SEL, id, id, id *)>(g_copy_url)(self, cmd, src, dst, err);
    std::string s = url_path(src);
    if (interesting(s))
        log_result("copyItemAtURL", s, url_path(dst), ok, err ? *err : nullptr);
    return ok;
}

bool hook_copy_path(id self, SEL cmd, id src, id dst, id *err) {
    bool ok = reinterpret_cast<bool (*)(id, SEL, id, id, id *)>(g_copy_path)(self, cmd, src, dst, err);
    std::string s = to_string(src);
    if (interesting(s))
        log_result("copyItemAtPath", s, to_string(dst), ok, err ? *err : nullptr);
    return ok;
}

} // namespace

// rename() se interpone con dyld: no pasa por NSFileManager (lo usa el codigo C++ del motor).
extern "C" int fndiag_rename(const char *from, const char *to) {
    int rc = rename(from, to);
    int saved = errno;
    if (config().trace_files && from && strstr(from, kMarker))
        log_line("rename %s -> %s rc=%d errno=%d (%s)", from, to ? to : "(null)", rc, rc ? saved : 0, rc ? strerror(saved) : "ok");
    errno = saved;
    return rc;
}

struct Interpose {
    const void *replacement;
    const void *original;
};
__attribute__((used, section("__DATA,__interpose"))) static const Interpose g_interpose[] = {
    {reinterpret_cast<const void *>(fndiag_rename), reinterpret_cast<const void *>(rename)},
};

void install_file_hooks() {
    if (!config().trace_files)
        return;
    const char *cls = "NSFileManager";
    bool a = objc::replace_instance_method(cls, "moveItemAtURL:toURL:error:", reinterpret_cast<IMP>(hook_move_url), &g_move_url);
    bool b = objc::replace_instance_method(cls, "moveItemAtPath:toPath:error:", reinterpret_cast<IMP>(hook_move_path), &g_move_path);
    bool c = objc::replace_instance_method(cls, "copyItemAtURL:toURL:error:", reinterpret_cast<IMP>(hook_copy_url), &g_copy_url);
    bool d = objc::replace_instance_method(cls, "copyItemAtPath:toPath:error:", reinterpret_cast<IMP>(hook_copy_path), &g_copy_path);
    log_line("file hooks: moveURL=%d movePath=%d copyURL=%d copyPath=%d rename=interpose", a, b, c, d);
}

} // namespace fndiag
