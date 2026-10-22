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

// Hooks sobre FBackgroundNSURLSession (clase del motor): registra SetDownloadResult /
// GetDownloadResult y, con Config::patch_status, corrige el codigo 201 a 200 cuando el
// fichero temporal de la descarga existe y no esta vacio.
void install_engine_hooks();

// Hook que SI cambia comportamiento sobre +backgroundSessionConfigurationWithIdentifier::
// con Config::foreground_sessions devuelve una configuracion efimera en proceso; si no, con
// Config::isolate_sessions añade el UUID del contenedor al identificador.
void install_session_override();

}  // namespace fndiag
