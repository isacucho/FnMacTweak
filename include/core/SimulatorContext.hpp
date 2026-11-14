#pragma once
#include <cerrno>
#include <cstring>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include "core/Logger.hpp"

// Replica la estructura de directorios de un contenedor iOS bajo `baseContainerPath`
// (tipicamente $HOME del proceso en macOS sideloaded). El motor espera encontrar
// Documents/, Library/Caches/ y la jerarquia PersistentDownloadDir/BackgroundHttp/.
class iOSSimulatorContext {
public:
    static iOSSimulatorContext& getInstance() {
        static iOSSimulatorContext instance;
        return instance;
    }

    bool emulateiOSDirectories(const std::string& base) {
        LOG_I("iOSSim", "Replicando contenedor iOS en: %s", base.c_str());

        std::string docs    = base + "/Documents";
        std::string lib     = base + "/Library";
        std::string cache   = lib  + "/Caches";
        std::string game    = docs + "/FortniteGame";
        std::string pdd     = game + "/PersistentDownloadDir";
        std::string chunk   = pdd  + "/ChunkDownload";
        std::string bghttp  = pdd  + "/BackgroundHttp";
        std::string ver     = bghttp + "/++Fortnite+Release-43.10";

        bool ok = true;
        ok &= mkDir(docs);
        ok &= mkDir(lib);
        ok &= mkDir(cache);
        ok &= mkDir(game);
        ok &= mkDir(pdd);
        ok &= mkDir(chunk);
        ok &= mkDir(bghttp);
        ok &= mkDir(ver);

        if (ok) LOG_I("iOSSim", "Estructura de directorios ok.");
        else    LOG_E("iOSSim", "Algunos directorios no se pudieron crear.");
        return ok;
    }

private:
    iOSSimulatorContext() = default;

    bool mkDir(const std::string& path) {
        struct stat st = {};
        if (stat(path.c_str(), &st) == 0)
            return S_ISDIR(st.st_mode);
        if (mkdir(path.c_str(), 0755) == 0) {
            LOG_D("iOSSim", "Creado: %s", path.c_str());
            return true;
        }
        LOG_E("iOSSim", "mkdir(%s): %s", path.c_str(), strerror(errno));
        return false;
    }
};
