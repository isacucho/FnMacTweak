#include "core/Config.hpp"
#include "core/DiagLog.hpp"
#include "input/InputHooks.hpp"

#include <sys/stat.h>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <string>

namespace fndiag {
namespace {

const char* kMarker = "; FnMacKickFix input_ini";

bool mkdirs(const std::string& path) {
    for (size_t i = 1; i <= path.size(); i++) {
        if (i == path.size() || path[i] == '/') {
            std::string sub = path.substr(0, i);
            if (mkdir(sub.c_str(), 0755) != 0 && errno != EEXIST) return false;
        }
    }
    return true;
}

bool file_ok_to_write(const std::string& path) {
    FILE* f = fopen(path.c_str(), "r");
    if (!f) return true;
    char line[256];
    bool ours = fgets(line, sizeof line, f) && !strncmp(line, kMarker, strlen(kMarker));
    fclose(f);
    return ours;
}

} // namespace

void install_input_ini(const std::string& container) {
    std::string dir  = container + "/Documents/FortniteGame/Saved/Config/IOS";
    std::string path = dir + "/Input.ini";

    if (!config().input_ini) {
        FILE* f = fopen(path.c_str(), "r");
        if (!f) return;
        fclose(f);
        if (file_ok_to_write(path) && remove(path.c_str()) == 0)
            log_line("[INPUT] input_ini apagado: quitado %s", path.c_str());
        return;
    }
    if (!mkdirs(dir)) { log_line("[INPUT] no se pudo crear %s (errno %d)", dir.c_str(), errno); return; }
    if (!file_ok_to_write(path)) { log_line("[INPUT] %s existe y no es nuestro: no se toca", path.c_str()); return; }
    FILE* f = fopen(path.c_str(), "w");
    if (!f) { log_line("[INPUT] no se pudo escribir %s (errno %d)", path.c_str(), errno); return; }
    fprintf(f,
            "%s\n[/Script/Engine.InputSettings]\n"
            "bUseMouseForTouch=False\n"
            "bCaptureMouseOnLaunch=True\n"
            "bEnableMouseSmoothing=False\n"
            "DefaultViewportMouseCaptureMode=CapturePermanently\n"
            "DefaultViewportMouseLockMode=LockOnCapture\n",
            kMarker);
    fclose(f);
    log_line("[INPUT] escrito %s", path.c_str());
}

} // namespace fndiag
