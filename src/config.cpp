#include "fndiag/config.hpp"

#include <strings.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace fndiag {
namespace {

bool parse_bool(const char *value, bool fallback) {
    if (!value)
        return fallback;
    if (!strcmp(value, "1") || !strcasecmp(value, "true") || !strcasecmp(value, "on"))
        return true;
    if (!strcmp(value, "0") || !strcasecmp(value, "false") || !strcasecmp(value, "off"))
        return false;
    return fallback;
}

void apply(const char *key, const char *value, Config &c) {
    if (!strcmp(key, "foreground"))
        c.foreground_sessions = parse_bool(value, c.foreground_sessions);
    else if (!strcmp(key, "isolate_sessions"))
        c.isolate_sessions = parse_bool(value, c.isolate_sessions);
    else if (!strcmp(key, "create_dirs"))
        c.create_dirs = parse_bool(value, c.create_dirs);
    else if (!strcmp(key, "patch_status"))
        c.patch_status = parse_bool(value, c.patch_status);
    else if (!strcmp(key, "verbose"))
        c.verbose = parse_bool(value, c.verbose);
    else if (!strcmp(key, "trace_files"))
        c.trace_files = parse_bool(value, c.trace_files);
    else if (!strcmp(key, "autoupdate"))
        c.autoupdate = parse_bool(value, c.autoupdate);
}

void load_file(Config &c) {
    const char *home = getenv("HOME");
    if (!home)
        return;
    std::string path = std::string(home) + "/Documents/FnDiag.conf";
    FILE *f = fopen(path.c_str(), "r");
    if (!f)
        return;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        char *eq = strchr(line, '=');
        if (line[0] == '#' || !eq)
            continue;
        *eq = '\0';
        char *value = eq + 1;
        value[strcspn(value, "\r\n")] = '\0';
        apply(line, value, c);
    }
    fclose(f);
}

Config load() {
    Config c;
    load_file(c);
    apply("foreground", getenv("FNDIAG_FOREGROUND"), c);
    apply("isolate_sessions", getenv("FNDIAG_ISOLATE_SESSIONS"), c);
    apply("create_dirs", getenv("FNDIAG_CREATE_DIRS"), c);
    apply("patch_status", getenv("FNDIAG_PATCH_STATUS"), c);
    apply("verbose", getenv("FNDIAG_VERBOSE"), c);
    apply("trace_files", getenv("FNDIAG_TRACE_FILES"), c);
    apply("autoupdate", getenv("FNDIAG_AUTOUPDATE"), c);
    return c;
}

} // namespace

const Config &config() {
    static const Config c = load();
    return c;
}

} // namespace fndiag
