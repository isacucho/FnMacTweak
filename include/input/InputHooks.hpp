#pragma once
#include <string>

namespace fndiag {

// Sonda de entrada (Config::probe_input): registra que teclado, raton y mandos
// ve el juego por GameController. Solo observa. Ver src/input/InputProbe.mm.
void install_input_probe();

// Desbloqueo de FPS (Config::unlock_fps): intercepta CADisplayLink, MTKView y
// UIScreen.maximumFramesPerSecond y fuerza Config::fps_target. Ver src/input/FpsUnlock.cpp.
void install_fps_hooks();

// Comprueba si el binario del juego lleva el parche del predicado
// FortSettingEditCondition_WhenPlatformSupportsMouseAndKeyboard.
// NO parchea en memoria (SIGKILL por codesigning). Ver src/input/NativeKbm.cpp.
void install_native_kbm();

// Escribe Saved/Config/IOS/Input.ini con ajustes de raton de UInputSettings
// (Config::input_ini). Si el fichero existe y no es nuestro, no se toca.
// `container` = $HOME de la app. Ver src/input/InputIni.cpp.
void install_input_ini(const std::string& container);

} // namespace fndiag
