#pragma once
#include <string>

namespace fndiag {

// Escribe ~/Documents/FnDiag_LogKey.txt con el subsistema os_log y el comando
// de captura listo para ejecutar. Los beta testers lo abren, copian el comando
// y lo pegan en Terminal para capturar logs en tiempo real.
void write_log_key_file(const std::string& container_path);

} // namespace fndiag
