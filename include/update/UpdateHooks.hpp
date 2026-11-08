#pragma once
#include <string>

namespace fndiag {

// Observa las sesiones NSURLSession que crea el juego e instrumenta sus delegados.
// Solo registra (no modifica comportamiento). Ver src/update/NetworkHooks.cpp.
void install_network_hooks();

// Hooks sobre NSFileManager (move/copy/exists) y POSIX (stat/access/open/rename/unlink)
// para operaciones sobre temporales de CFNetwork y BackgroundHttp. Con create_dirs,
// crea el directorio padre antes de cada rename/move si no existe. Ver src/update/FileHooks.cpp.
//
// IMPORTANTE: debe instalarse despues de installSpoofHooks() para que el hook de
// fileExistsAtPath encadene correctamente (Metadata outer -> Update inner -> original).
void install_file_hooks();

// Hooks sobre FBackgroundNSURLSession (clase del motor): registra SetDownloadResult /
// GetDownloadResult y con Config::patch_status corrige 201 -> 200. Ver src/update/EngineHooks.mm.
void install_engine_hooks();

// Hook sobre +[NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:]:
// con foreground_sessions devuelve configuracion efimera; con isolate_sessions añade
// el UUID del contenedor al identificador. Ver src/update/SessionOverride.cpp.
void install_session_override();

// Registra FnContentLinkProtocol; la inyeccion en cada NSURLSession se hace en
// hook_session_factory (NetworkHooks.mm). Debe llamarse antes de install_network_hooks().
// Ver src/update/ContentPatch.mm para la raiz: HTTP 400 en experience_br causa
// NumLoadCustomizationFailed >= 3 que expulsa al jugador del juego (v2.0.32 bug).
void install_content_patch();

} // namespace fndiag
