#pragma once

namespace fndiag {

// Instala los swizzles de observacion sobre NSURLSession. No modifica el
// comportamiento de ninguna llamada: solo registra (NSError real de cada
// tarea, fichero temporal de cada descarga) y reenvia al original.
void install_network_hooks();

// Registra los movimientos/copias (NSFileManager y rename) cuyo origen es un
// fichero temporal de CFNetwork: muestra dónde deja el juego lo que baja y si
// la operación falla. Solo observa.
void install_file_hooks();

// Unico hook que SI cambia comportamiento: cuando Config::foreground_sessions
// esta activo, +backgroundSessionConfigurationWithIdentifier: devuelve una
// configuracion efimera en proceso en lugar de una sesion de nsurlsessiond.
void install_session_override();

}  // namespace fndiag
