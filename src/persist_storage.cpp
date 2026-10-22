#include "fndiag/config.hpp"
#include "fndiag/hooks.hpp"
#include "fndiag/log.hpp"

#include <dirent.h>
#include <pwd.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

// Prueba: sacar PersistentDownloadDir del contenedor. Cada reinstalacion con Sideloadly crea un
// contenedor nuevo y borra el anterior con todo lo descargado. Si el sandbox deja escribir fuera
// del contenedor, PersistentDownloadDir pasa a ser un enlace simbolico a una carpeta fija que
// sobrevive a reinstalar.

namespace fndiag {
namespace {

bool mkdir_p(const std::string &path) {
    for (size_t pos = path.find('/', 1); pos != std::string::npos; pos = path.find('/', pos + 1))
        mkdir(path.substr(0, pos).c_str(), 0755); // EEXIST en los que ya existen
    return (mkdir(path.c_str(), 0755) == 0 || errno == EEXIST);
}

// Crea, escribe, lee y borra un fichero: mkdir solo no prueba que el sandbox deje escribir.
bool probe_dir(const std::string &dir) {
    if (!mkdir_p(dir)) {
        log_line("persist: mkdir %s FALLA errno=%d (%s)", dir.c_str(), errno, strerror(errno));
        return false;
    }
    std::string file = dir + "/.fnfix-probe";
    FILE *f = fopen(file.c_str(), "w");
    if (!f) {
        log_line("persist: escribir en %s FALLA errno=%d (%s)", dir.c_str(), errno, strerror(errno));
        return false;
    }
    bool ok = fputs("ok", f) >= 0;
    fclose(f);
    char buf[4] = {};
    f = fopen(file.c_str(), "r");
    ok = ok && f && fgets(buf, sizeof buf, f) && !strcmp(buf, "ok");
    if (f)
        fclose(f);
    unlink(file.c_str());
    log_line("persist: probe %s %s", dir.c_str(), ok ? "OK" : "FALLA lectura");
    return ok;
}

bool is_empty_dir(const std::string &dir) {
    DIR *d = opendir(dir.c_str());
    if (!d)
        return true;
    bool empty = true;
    while (dirent *e = readdir(d)) {
        if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) {
            empty = false;
            break;
        }
    }
    closedir(d);
    return empty;
}

// HOME dentro del sandbox es el contenedor; el home real sale de la base de usuarios.
std::string real_home() {
    passwd *pw = getpwuid(getuid());
    return (pw && pw->pw_dir) ? pw->pw_dir : "";
}

} // namespace

void install_persistent_storage(const std::string &container) {
    const std::string fg = container + "/Documents/FortniteGame";
    const std::string pdd = fg + "/PersistentDownloadDir";

#ifdef PRODUCTION
    if (!config().persist_downloads)
        return; // public: sin efectos secundarios si la opcion esta apagada
#endif
    std::vector<std::string> candidates;
    if (const char *forced = getenv("FNDIAG_PERSIST_BASE")) {
        candidates.push_back(forced); // pruebas
    } else {
        std::string home = real_home();
        if (!home.empty())
            candidates.push_back(home + "/Library/Application Support/FnMacUpdateFix");
        candidates.push_back("/Users/Shared/FnMacUpdateFix");
    }

    std::string base;
    for (const std::string &c : candidates) {
        if (probe_dir(c)) {
            base = c;
            break;
        }
    }
    if (base.empty()) {
        log_line("persist: ninguna ruta fuera del contenedor es escribible; PersistentDownloadDir se queda dentro");
        return;
    }
    if (!config().persist_downloads) {
        log_line("persist: ruta usable %s, persist_downloads=0: no se toca PersistentDownloadDir", base.c_str());
        return;
    }

    const std::string target = base + "/PersistentDownloadDir";
    struct stat st{};
    if (lstat(pdd.c_str(), &st) == 0 && S_ISLNK(st.st_mode)) {
        char cur[1024] = {};
        ssize_t n = readlink(pdd.c_str(), cur, sizeof cur - 1);
        log_line("persist: ya es un enlace -> %s (%s)", n > 0 ? cur : "?", (n > 0 && target == cur) ? "correcto" : "OTRO destino, no se toca");
        return;
    }

    mkdir_p(target);
    if (lstat(pdd.c_str(), &st) == 0) {
        if (!S_ISDIR(st.st_mode)) {
            log_line("persist: %s existe y no es directorio: no se toca", pdd.c_str());
            return;
        }
        if (is_empty_dir(pdd)) {
            if (rmdir(pdd.c_str()) != 0) {
                log_line("persist: rmdir %s FALLA errno=%d (%s)", pdd.c_str(), errno, strerror(errno));
                return;
            }
        } else if (is_empty_dir(target)) {
            // Contenido local y almacen vacio: se mueve (rename, mismo volumen).
            if (rmdir(target.c_str()) != 0 || rename(pdd.c_str(), target.c_str()) != 0) {
                log_line("persist: mover %s -> %s FALLA errno=%d (%s)", pdd.c_str(), target.c_str(), errno, strerror(errno));
                mkdir_p(target);
                return;
            }
            log_line("persist: contenido local movido a %s", target.c_str());
        } else {
            // Los dos tienen datos: no se decide por el usuario.
            log_line("persist: CONFLICTO, hay datos en %s y en %s: no se toca nada", pdd.c_str(), target.c_str());
            return;
        }
    } else {
        mkdir_p(fg);
    }

    if (symlink(target.c_str(), pdd.c_str()) != 0) {
        log_line("persist: symlink %s -> %s FALLA errno=%d (%s)", pdd.c_str(), target.c_str(), errno, strerror(errno));
        mkdir_p(pdd); // el juego necesita el directorio, aunque sea local
        return;
    }
    log_line("persist: %s -> %s (contenido previo en el almacen: %s)", pdd.c_str(), target.c_str(), is_empty_dir(target) ? "no" : "SI");
}

} // namespace fndiag
