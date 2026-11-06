#pragma once
#include <string>

namespace fndiag {

// Abre el fichero de log (Documents/FnDiag.log del contenedor). Idempotente.
void log_init(const std::string& path);

// Una linea con timestamp al fichero y al os_log. Seguro desde cualquier hilo.
void log_line(const char* fmt, ...) __attribute__((format(printf, 1, 2)));

// Hilo de diagnostico: espeja PersistentDownloadDir y las lineas relevantes de
// FortniteGame.log al subsistema os_log "fndiag". `container` = HOME de la app.
void start_game_log_mirror(const std::string& container);

} // namespace fndiag
