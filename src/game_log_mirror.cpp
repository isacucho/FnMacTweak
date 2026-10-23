#include "fndiag/log.hpp"

#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <deque>
#include <string>
#include <thread>
#include <vector>

// Espejo de diagnostico: el contenedor de la app esta protegido por TCC para el resto del
// sistema, pero el propio juego puede leerlo. Desde aqui se reenvian al os_log (subsystem
// fndiag) el estado de PersistentDownloadDir y las lineas relevantes de FortniteGame.log.

namespace fndiag {
namespace {

const char *const kPatterns[] = {"InstallBundle", "Journal", "BuildPatch", "IoStore", "LogIas", "ChunkHash", "ChunkMissing",
                                 "orrupt",        "PersistentDownloadDir", "ESP-",    "errors.com", "UnsafeEnvironment", "erify",
                                 // FPS y configuracion: que ficheros .ini carga el motor y que limita los frames
                                 "FramePac",      "FrameRate",   "MaxFPS",   "Engine.ini", "GameUserSettings", "SystemSettings",
                                 "FrontendFrame", "LogConfig: Applying", "ConsoleVariable", "CVar", "DynamicRes",
                                 // entrada: dispositivos y metodo de entrada que decide el juego
                                 "InputMethod",   "LogInput",    "KBM",      "Mouse",      "Keyboard",       "GameController"};
const char *const kNoise[] = {"\tState ", "Bundle Request Stats", "------", "BackgroundHttpRequest: Display: Download Complete"};

// Lineas que marcan el momento del error: al verlas se vuelca el contexto previo completo.
const char *const kTriggers[] = {"UnsafeEnvironment", "errors.com.epicgames.common", "ChunkHash", "ChunkMissing", "Kick",
                                 "kicked",            "RemovedFromMatch",             "Disconnected", "NetworkFailure", "ConnectionLost"};

bool is_trigger(const char *line) {
    for (const char *t : kTriggers)
        if (strstr(line, t))
            return true;
    return false;
}

// Ultimas lineas del log (todas, sin filtrar) para dar contexto a un disparador.
std::deque<std::string> g_ring;
constexpr size_t kRing = 120;
int g_cooldown = 0; // lineas restantes en las que se siguen volcando tras un disparo

bool interesting(const char *line) {
    for (const char *n : kNoise)
        if (strstr(line, n))
            return false;
    for (const char *p : kPatterns)
        if (strstr(line, p))
            return true;
    return false;
}

// Reenvia las lineas completas e interesantes de `path` a partir de `offset`. Devuelve el
// nuevo offset (al final de la ultima linea completa leida).
long forward_lines(const std::string &path, long offset, const char *tag, size_t &budget, bool ring = false) {
    FILE *f = fopen(path.c_str(), "r");
    if (!f)
        return offset;
    fseek(f, offset, SEEK_SET);
    char line[2048];
    while (budget && fgets(line, sizeof line, f)) {
        size_t n = strlen(line);
        if (n && line[n - 1] != '\n' && !feof(f)) {
            // linea mas larga que el buffer: se registra truncada y se salta el resto
            int c;
            while ((c = fgetc(f)) != EOF && c != '\n') {
            }
        } else if (n && line[n - 1] != '\n') {
            break; // linea a medio escribir: se relee en la siguiente pasada
        }
        offset = ftell(f);
        line[strcspn(line, "\r\n")] = '\0';
        if (ring) {
            if (is_trigger(line) && g_cooldown == 0) {
                log_line("[Ctx] ---- disparador: %.200s ----", line);
                for (const std::string &c : g_ring)
                    log_line("[Ctx] %s", c.c_str());
                g_ring.clear();
                g_cooldown = 60;
            }
            if (g_cooldown > 0) {
                log_line("[Ctx] %.300s", line);
                --g_cooldown;
            } else {
                g_ring.emplace_back(line, std::min<size_t>(strlen(line), 300));
                if (g_ring.size() > kRing)
                    g_ring.pop_front();
            }
        }
        if (interesting(line)) {
            log_line("[%s] %s", tag, line);
            --budget;
        }
    }
    fclose(f);
    return offset;
}

struct DirStats {
    long files = 0;
    long long bytes = 0;
};

void walk(const std::string &dir, int depth, DirStats &st, std::vector<std::string> &special) {
    DIR *d = opendir(dir.c_str());
    if (!d)
        return;
    while (dirent *e = readdir(d)) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
            continue;
        std::string p = dir + "/" + e->d_name;
        struct stat s{};
        if (lstat(p.c_str(), &s) != 0)
            continue;
        if (S_ISDIR(s.st_mode)) {
            if (depth < 12)
                walk(p, depth + 1, st, special);
            continue;
        }
        ++st.files;
        st.bytes += s.st_size;
        const char *n = e->d_name;
        if ((strcasestr(n, "journal") || strcasestr(n, "manifest") || strcasestr(n, "install") || strstr(n, ".ini") ||
             strstr(n, ".json")) &&
            special.size() < 150) {
            char buf[64];
            strftime(buf, sizeof buf, "%m-%d %H:%M:%S", localtime(&s.st_mtime));
            special.push_back(p + " size=" + std::to_string(s.st_size) + " mtime=" + buf);
        }
    }
    closedir(d);
}

void dump_install_state(const std::string &root) {
    std::string pdd = root + "/PersistentDownloadDir";
    log_line("[InstallState] %s", pdd.c_str());
    DIR *d = opendir(pdd.c_str());
    if (!d) {
        log_line("[InstallState] no se puede abrir PersistentDownloadDir");
        return;
    }
    std::vector<std::string> special;
    while (dirent *e = readdir(d)) {
        if (e->d_name[0] == '.')
            continue;
        std::string p = pdd + "/" + e->d_name;
        DirStats st;
        struct stat s{};
        if (lstat(p.c_str(), &s) == 0 && S_ISDIR(s.st_mode)) {
            walk(p, 1, st, special);
            log_line("[InstallState] dir %s ficheros=%ld bytes=%lld", e->d_name, st.files, st.bytes);
            if (!strcmp(e->d_name, "ChunkDownload")) {
                // desglose por tag
                DIR *cd = opendir(p.c_str());
                while (cd && (e = readdir(cd))) {
                    if (e->d_name[0] == '.')
                        continue;
                    DirStats t;
                    std::vector<std::string> ignore;
                    walk(p + "/" + e->d_name, 1, t, ignore);
                    log_line("[InstallState]   ChunkDownload/%s ficheros=%ld bytes=%lld", e->d_name, t.files, t.bytes);
                }
                if (cd)
                    closedir(cd);
            }
        } else {
            log_line("[InstallState] file %s size=%lld", e->d_name, static_cast<long long>(s.st_size));
        }
    }
    closedir(d);
    for (const std::string &s : special)
        log_line("[InstallState] especial %s", s.c_str() + pdd.size() + 1);
}

// Log mas reciente del arranque anterior (FortniteGame-backup-*.log).
std::string newest_backup(const std::string &logs) {
    DIR *d = opendir(logs.c_str());
    if (!d)
        return "";
    std::string best;
    time_t best_t = 0;
    while (dirent *e = readdir(d)) {
        if (strncmp(e->d_name, "FortniteGame-backup-", 20) != 0)
            continue;
        std::string p = logs + "/" + e->d_name;
        struct stat s{};
        if (stat(p.c_str(), &s) == 0 && s.st_mtime > best_t) {
            best_t = s.st_mtime;
            best = p;
        }
    }
    closedir(d);
    return best;
}

void mirror_main(std::string root) {
    std::string logs = root + "/Saved/Logs";
    std::string current = logs + "/FortniteGame.log";

    dump_install_state(root);

    size_t backup_budget = 3000;
    std::string backup = newest_backup(logs);
    if (!backup.empty()) {
        log_line("[GameLog] arranque anterior: %s", backup.c_str() + logs.size() + 1);
        forward_lines(backup, 0, "PrevLog", backup_budget);
    }

    // Sigue FortniteGame.log del arranque actual. Si el motor lo recrea (otro inodo) se
    // vuelve a leer desde el principio.
    long offset = 0;
    ino_t inode = 0;
    size_t budget = 20000;
    for (;;) {
        struct stat s{};
        if (stat(current.c_str(), &s) == 0) {
            if (s.st_ino != inode || s.st_size < offset) {
                inode = s.st_ino;
                offset = 0;
            }
            if (s.st_size > offset)
                offset = forward_lines(current, offset, "GameLog", budget, true);
        }
        sleep(1);
    }
}

} // namespace

void start_game_log_mirror(const std::string &container) {
    std::string root = container + "/Documents/FortniteGame";
    log_line("[GameLog] espejo activo sobre %s", root.c_str());
    std::thread(mirror_main, root).detach();
}

} // namespace fndiag
