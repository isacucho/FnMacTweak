#pragma once

namespace fndiag {

// Valores en tiempo de carga. Orden de prioridad: variable de entorno,
// fichero $HOME/Documents/FnDiag.conf (key=value), valor por defecto.
struct Config {
    // Sustituye las sesiones NSURLSession "background" por sesiones efimeras
    // en proceso, para no depender de nsurlsessiond.
    bool foreground_sessions = true;
    // Registra tambien las descargas que terminan sin error.
    bool verbose = true;
    // Registra las operaciones de fichero sobre temporales de descarga.
    bool trace_files = true;
    // Comprueba GitHub Releases al arrancar y deja la dylib nueva lista para
    // el siguiente arranque. Desactivado: sustituir una dylib firmada puede
    // invalidar la firma del bundle.
    bool autoupdate = false;
};

const Config &config();

} // namespace fndiag
