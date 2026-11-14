#pragma once

namespace fndiag {

// Parchea el reporter de compatibilidad interno de Fortnite via vtable swap
// en __DATA_CONST. Suprime tipos {5,19,23,49} con flag==1 que triggean checks
// de plataforma incompatibles con iOS Catalyst en macOS.
// Logica portada de JadedFix (github.com/jaded/kick-fix).
void install_compat_report();

} // namespace fndiag
