#pragma once

#include <string>

namespace fndiag {

// Abre el fichero de log (Documents/FnDiag.log del contenedor de la app).
// Idempotente. Si falla, el log solo va a os_log.
void log_init(const std::string &path);

// Una linea con timestamp. Seguro desde cualquier hilo.
void log_line(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

}  // namespace fndiag
