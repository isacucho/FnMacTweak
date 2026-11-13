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

} // namespace

void log_init(const std::string& path) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_file) return;
    g_file = fopen(path.c_str(), "a");
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
    if (!g_os) g_os = os_log_create("com.alexgrdev.fnmacbypass", "diag");
    os_log(g_os, "%{public}s", msg);
    if (g_file) {
        fprintf(g_file, "%s.%03d [%d] %s\n",
                stamp, static_cast<int>(tv.tv_usec / 1000), getpid(), msg);
        fflush(g_file);
    }
}

} // namespace fndiag
