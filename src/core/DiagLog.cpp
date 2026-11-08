#include "core/DiagLog.hpp"
#include <os/log.h>
#include <sys/time.h>
#include <unistd.h>
#include <cstdarg>
#include <cstdio>
#include <ctime>
#include <cstring>
#include <mutex>
#include <dlfcn.h>

namespace fndiag {
namespace {

std::mutex g_mutex;
FILE*      g_file = nullptr;
os_log_t   g_os   = nullptr;
#ifndef PRODUCTION
FILE*      g_tmpfile = nullptr;
#endif

#ifndef PRODUCTION
// Returns the directory containing this dylib, e.g. /private/var/folders/.../T/
static std::string dylib_dir_for_log() {
    Dl_info info;
    if (!dladdr(reinterpret_cast<const void*>(&dylib_dir_for_log), &info) || !info.dli_fname)
        return "";
    std::string p = info.dli_fname;
    size_t slash = p.rfind('/');
    return slash == std::string::npos ? "" : p.substr(0, slash);
}
#endif

} // namespace

void log_init(const std::string& path) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_file) return;
    g_file = fopen(path.c_str(), "a");
#ifndef PRODUCTION
    // Try dylib directory first (always writable since fn_watcher.sh puts us there)
    std::string dylib_log = dylib_dir_for_log() + "/FnDiag.log";
    g_tmpfile = fopen(dylib_log.c_str(), "a");
    // Fallback paths if dylib dir fails
    if (!g_tmpfile) g_tmpfile = fopen("/private/tmp/FnDiag.log", "a");
    if (!g_tmpfile) g_tmpfile = fopen("/tmp/FnDiag.log", "a");
#endif
}

void log_line(const char* fmt, ...) {
    char msg[4096];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);

    timeval tv;
    gettimeofday(&tv, nullptr);
    tm local;
    localtime_r(&tv.tv_sec, &local);
    char stamp[32];
    strftime(stamp, sizeof stamp, "%Y-%m-%d %H:%M:%S", &local);

    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_os) g_os = os_log_create("com.fnmaccompat", "diag");
    os_log(g_os, "%{public}s", msg);
    if (g_file) {
        fprintf(g_file, "%s.%03d [%d] %s\n",
                stamp, static_cast<int>(tv.tv_usec / 1000), getpid(), msg);
        fflush(g_file);
    }
#ifndef PRODUCTION
    if (g_tmpfile) {
        fprintf(g_tmpfile, "%s.%03d [%d] %s\n",
                stamp, static_cast<int>(tv.tv_usec / 1000), getpid(), msg);
        fflush(g_tmpfile);
    }
#endif
}

} // namespace fndiag
