#pragma once

namespace fndiag {

// Valores en tiempo de carga. Orden de prioridad (menor a mayor):
//   FnDiag.conf junto a la dylib, $HOME/Documents/FnDiag.conf, variables de entorno FNDIAG_*.
struct Config {
    // GetDownloadResult devuelve la ruta del temporal relativa a Documents/.
    bool relative_paths = true;
    // Corrige el 201 que devuelve FBackgroundNSURLSession::GetDownloadResult a 200.
    bool patch_status = true;
    // Sonda GameController (teclado, raton, mandos). Apagada por defecto: crasheaba
    // con NSInternalInconsistencyException en UIKitMacHelper fuera del main thread.
    bool probe_input = false;
    // Escribe Saved/Config/IOS/Input.ini con ajustes de raton de UInputSettings.
    bool input_ini = false;
    // Comprueba si el binario lleva el parche del predicado KBM.
    bool native_kbm = false;
    // Fuerza fps_target en CADisplayLink / MTKView / UIScreen.maximumFramesPerSecond.
    bool unlock_fps = false;
    int  fps_target = 120;
    // Espeja UE LogGameLog a OSLog subsystem com.alexgrdev.fnmackickfix.
    bool mirror_log  = true;
    // Comprueba GitHub Releases y deja la dylib nueva para el siguiente arranque.
    bool autoupdate = false;
};

const Config& config();

} // namespace fndiag
