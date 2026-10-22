#pragma once

namespace fndiag {

// Instala los swizzles de observacion sobre NSURLSession. No modifica el
// comportamiento de ninguna llamada: solo registra (NSError real de cada
// tarea, fichero temporal de cada descarga) y reenvia al original.
void install_network_hooks();

// Unico hook que SI cambia comportamiento: cuando Config::foreground_sessions
// esta activo, +backgroundSessionConfigurationWithIdentifier: devuelve una
// configuracion efimera en proceso en lugar de una sesion de nsurlsessiond.
void install_session_override();

}  // namespace fndiag
