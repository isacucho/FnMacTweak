#pragma once

namespace fndiag {

// Valores en tiempo de carga. Orden de prioridad: variable de entorno,
// fichero $HOME/Documents/FnDiag.conf (key=value), valor por defecto.
struct Config {
    // Sustituye las sesiones NSURLSession "background" por sesiones efimeras
    // en proceso, para no depender de nsurlsessiond.
    // Apagado por defecto: la configuracion que se sabe que funciona usa sesiones
    // background y el parche de codigo (patch_status).
    bool foreground_sessions = false;
    // Añade el UUID del contenedor al identificador de cada sesion background, para que
    // nsurlsessiond no reconecte sesiones de una instalacion anterior.
    bool isolate_sessions = true;
    // Crea el directorio padre cuando el motor mueve una descarga a BackgroundHttp/<build>/
    // y ese directorio no existe (si no, el move falla con ENOENT y la descarga se pierde).
    bool create_dirs = true;
    // GetDownloadResult devuelve la ruta del temporal relativa a Documents/: el motor le
    // antepone su directorio base y con la ruta absoluta no encuentra el fichero.
    bool relative_paths = true;
    // Corrige el 201 que devuelve FBackgroundNSURLSession::GetDownloadResult a 200.
    bool patch_status = true;
#ifdef PRODUCTION
    // public: solo errores. Los arreglos (create_dirs, relative_paths...) siguen activos.
    bool verbose = false;
    bool trace_files = false;
#else
    // Registra tambien las descargas que terminan sin error.
    bool verbose = true;
    // Registra las operaciones de fichero sobre temporales de descarga.
    bool trace_files = true;
#endif
    // Comprueba GitHub Releases al arrancar y deja la dylib nueva lista para
    // el siguiente arranque. Desactivado: sustituir una dylib firmada puede
    // invalidar la firma del bundle.
    bool autoupdate = false;
};

const Config &config();

} // namespace fndiag
