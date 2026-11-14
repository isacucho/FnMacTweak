#include "core/Config.hpp"
#include <dlfcn.h>
#include <strings.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace fndiag {
namespace {

bool parse_bool(const char* v, bool fallback) {
    if (!v) return fallback;
    if (!strcmp(v, "1") || !strcasecmp(v, "true") || !strcasecmp(v, "on"))  return true;
    if (!strcmp(v, "0") || !strcasecmp(v, "false") || !strcasecmp(v, "off")) return false;
    return fallback;
}

void apply(const char* key, const char* value, Config& c) {
    if      (!strcmp(key, "relative_paths")) c.relative_paths = parse_bool(value, c.relative_paths);
    else if (!strcmp(key, "patch_status"))   c.patch_status   = parse_bool(value, c.patch_status);
    else if (!strcmp(key, "probe_input"))    c.probe_input    = parse_bool(value, c.probe_input);
    else if (!strcmp(key, "input_ini"))      c.input_ini      = parse_bool(value, c.input_ini);
    else if (!strcmp(key, "native_kbm"))     c.native_kbm     = parse_bool(value, c.native_kbm);
    else if (!strcmp(key, "unlock_fps"))     c.unlock_fps     = parse_bool(value, c.unlock_fps);
    else if (!strcmp(key, "fps_target") && value) {
        int v = atoi(value);
        if (v >= 30 && v <= 240) c.fps_target = v;
    }
    else if (!strcmp(key, "mirror_log"))     c.mirror_log     = parse_bool(value, c.mirror_log);
    else if (!strcmp(key, "autoupdate"))     c.autoupdate     = parse_bool(value, c.autoupdate);
    else if (!strcmp(key, "net_inspect"))    c.net_inspect    = parse_bool(value, c.net_inspect);
}

void load_file(Config& c, const std::string& path) {
    FILE* f = fopen(path.c_str(), "r");
    if (!f) return;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        char* eq = strchr(line, '=');
        if (line[0] == '#' || !eq) continue;
        *eq = '\0';
        char* val = eq + 1;
        val[strcspn(val, "\r\n")] = '\0';
        apply(line, val, c);
    }
    fclose(f);
}

std::string dylib_dir() {
    Dl_info info;
    if (!dladdr(reinterpret_cast<const void*>(&dylib_dir), &info) || !info.dli_fname)
        return "";
    std::string p = info.dli_fname;
    size_t slash = p.rfind('/');
    return slash == std::string::npos ? "" : p.substr(0, slash);
}

Config load() {
    Config c;
    std::string dir = dylib_dir();
    if (!dir.empty()) load_file(c, dir + "/FnDiag.conf");
    if (const char* home = getenv("HOME"))
        load_file(c, std::string(home) + "/Documents/FnDiag.conf");
    apply("relative_paths", getenv("FNDIAG_RELATIVE_PATHS"), c);
    apply("patch_status",   getenv("FNDIAG_PATCH_STATUS"),   c);
    apply("probe_input",    getenv("FNDIAG_PROBE_INPUT"),    c);
    apply("input_ini",      getenv("FNDIAG_INPUT_INI"),      c);
    apply("native_kbm",     getenv("FNDIAG_NATIVE_KBM"),     c);
    apply("unlock_fps",     getenv("FNDIAG_UNLOCK_FPS"),     c);
    apply("fps_target",     getenv("FNDIAG_FPS_TARGET"),     c);
    apply("mirror_log",     getenv("FNDIAG_MIRROR_LOG"),     c);
    apply("autoupdate",     getenv("FNDIAG_AUTOUPDATE"),     c);
    apply("net_inspect",    getenv("FNDIAG_NET_INSPECT"),    c);
    return c;
}

} // namespace

const Config& config() {
    static const Config c = load();
    return c;
}

} // namespace fndiag
