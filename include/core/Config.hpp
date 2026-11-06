#pragma once

namespace fndiag {

// Valores en tiempo de carga. Orden de prioridad (menor a mayor):
//   FnDiag.conf junto a la dylib, $HOME/Documents/FnDiag.conf, variables de entorno FNDIAG_*.
struct Config {
    // Sustituye sesiones background por efimeras en proceso (sin nsurlsessiond).
    bool foreground_sessions = false;
    // Añade el UUID del contenedor al identificador de cada sesion background.
    bool isolate_sessions = true;
    // Crea el directorio padre cuando el motor mueve una descarga a BackgroundHttp/<build>/.
    bool create_dirs = true;
    // GetDownloadResult devuelve la ruta del temporal relativa a Documents/.
    bool relative_paths = true;
    // Corrige el 201 que devuelve FBackgroundNSURLSession::GetDownloadResult a 200.
    bool patch_status = true;
#ifdef PRODUCTION
    bool verbose     = false;
    bool trace_files = false;
    bool mirror_log  = false;
#else
    bool mirror_log  = true;
    bool verbose     = true;
    bool trace_files = true;
#endif
    // Sonda GameController (teclado, raton, mandos). Apagada por defecto: v0.5.4 crasheaba
    // con NSInternalInconsistencyException en UIKitMacHelper ("Called off the main thread").
    bool probe_input = false;
    // Escribe Saved/Config/IOS/Input.ini con ajustes de raton de UInputSettings.
    bool input_ini = false;
    // Comprueba si el binario lleva el parche del predicado KBM.
    bool native_kbm = false;
    // Fuerza fps_target en CADisplayLink / MTKView / UIScreen.maximumFramesPerSecond.
    bool unlock_fps = false;
    int  fps_target = 120;
    // Comprueba GitHub Releases y deja la dylib nueva para el siguiente arranque.
    bool autoupdate = false;
};

const Config& config();

} // namespace fndiag
