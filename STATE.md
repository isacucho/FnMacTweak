# Estado

- Proyecto y dylib renombrados a FnMacUpdateFix (antes FnFixUpdate) a partir de v0.3.3.

## v0.4.1
- Corrección: NO hay re-descarga por arranque. El arranque de las 11:54 (pid 66361) usó un
  contenedor nuevo (9DCDBCEF, creado 11:54:16 al reinstalar), así que descargar todo era lo
  esperado. El arranque de las 12:09 (pid 70027) en ese mismo contenedor no descargó nada.
  Cada reinstalación con Sideloadly implica una descarga completa (~4,75 GB).
- El terminal no puede leer el contenedor (TCC). Nuevo espejo de
  diagnóstico (`mirror_log`, beta/dev): desde dentro del juego vuelca el estado de
  PersistentDownloadDir y reenvía al os_log las líneas relevantes de FortniteGame.log y del
  log del arranque anterior ([InstallState], [GameLog], [PrevLog]). Apagado en public.

## v0.4.0
- v0.3.3 confirmada en Fortnite: sin ESP-CON-000, descarga completa y se llega al lobby.
- Optimización de la dylib: GetDownloadResult ya no registra el sondeo del motor
  (~50 llamadas/s con status=0: 23.761 de 28.067 líneas en 8,5 min); Logger deja de
  escribir a std::cout; las funciones POSIX interpuestas usan flags cacheados en vez de
  config(); copy/exists de NSFileManager solo se enganchan con trazas. En public
  (PRODUCTION) verbose y trace_files van apagados por defecto; los arreglos siguen activos.
- Descargas medidas (nsurlsessiond, h3): 166/176 tareas ok. Una conexión QUIC se quedó a
  0 kbps 62 s; el motor canceló sus tareas y reintentó ~1 min después. Tras relanzar el
  juego se volvieron a bajar los mismos chunks (~3,5 GB por arranque). Pendiente.

## v0.3.3
- Trazas de v0.3.2 en Fortnite: las descargas ya se mueven bien (21/21) y el parche 201->200
  actúa, pero el motor antepone su directorio base a la ruta absoluta que devuelve
  GetDownloadResult y busca `<C>/Library//Users/.../Documents/...tmp` y `<C>/Documents//Users/...`.
  No encuentra el fichero, la descarga se da por fallida, a los 30 s borra el temporal y repite:
  bucle de descarga con ESP-CON-000.
- Fix: `relative_paths` (activo) devuelve la ruta relativa a Documents/ (`FortniteGame/...`), que
  el motor resuelve bien (así resuelve también las rutas del URLMap). Probado en host macOS con
  la clase del motor simulada; sin verificar en Fortnite.

## v0.3.2
- Trazas de v0.3.1 en Fortnite (contenedor B4254A96, sesiones ya aisladas): la descarga llega
  (lstat rc=0, http 200) pero el motor la mueve a
  Documents/FortniteGame/PersistentDownloadDir/BackgroundHttp/++Fortnite+Release-42.40/<id>.tmp
  y ese directorio no existe: rename ENOENT, moveItemAtURL NSCocoaErrorDomain 4,
  SetDownloadResult 500 temp=(nil). Esta es la causa directa del ESP-CON-000.
- Fix: `create_dirs` (activo) crea el directorio padre antes del move/rename hacia BackgroundHttp.
  Reproducido en host macOS: sin fix falla igual (code 4), con fix el move funciona.
  Sin verificar en Fortnite.

## v0.3.1
- Causa encontrada con las trazas de v0.3.0 en Fortnite: Sideloadly crea un contenedor nuevo
  en cada reinstalación (22A48156 -> 9914379E). nsurlsessiond reconecta las sesiones background
  por identificador (com.epicgames.backgrounddownloads[.N]) y entrega los ficheros en
  Library/Caches/com.apple.nsurlsessiond/Downloads del contenedor VIEJO, que ya no existe.
  El motor no encuentra el temporal: SetDownloadResult result=500 temp=(nil),
  NSPOSIXErrorDomain 2, ConnectivityError, ESP-CON-000. Nunca llegó un 201 (PATCH=0).
- Fix: `isolate_sessions` (activo) añade el UUID del contenedor al identificador de sesión.
  Probado en host macOS; sin verificar en Fortnite.

## v0.3.1
- Causa encontrada con las trazas de v0.3.0 en Fortnite: cada reinstalación con Sideloadly crea
  un contenedor nuevo, pero nsurlsessiond reconecta las sesiones background con el mismo
  identificador y entrega los ficheros en el contenedor anterior (ya borrado). El motor no
  encuentra el temporal: `SetDownloadResult result=500 temp=(nil)` y NSPOSIXErrorDomain 2.
- Fix: `isolate_sessions` (activo) añade el UUID del contenedor al identificador de cada sesión
  background. Probado en host macOS; sin verificar en Fortnite.app.

## v0.3.0
- Integrado el parche de motor de NetHook.mm (engine_hooks.mm) y los hooks POSIX de ese fichero
  (file_hooks.cpp). `patch_status` activo y `foreground` apagado por defecto.
- Probado en un host macOS con una clase FBackgroundNSURLSession simulada: 201 con fichero
  no vacío pasa a 200; 404 y 201 sin parche no se tocan; las trazas POSIX/NSFileManager salen.
- Sin verificar en Fortnite.app. No se añadió DebugCanvas.hpp (no está en el repo) ni el
  constructor de MainModule.cpp (duplicaba el de MainModule.mm).

## v0.2.0
- Probado en Fortnite (v0.1.0): la dylib carga, las sesiones pasan a efimeras y los chunks
  se entregan completos (tamaño exacto), sin NSError. Aun asi el juego los marca como
  "Failed to download Chunk ... ConnectivityError" y sigue el ESP-CON-000.
- v0.2.0 añade trazas: HTTP y existencia del temporal tras el delegado, y los
  move/copy/rename sobre CFNetworkDownload_*.tmp con su errno/NSError (`trace_files`).
  `verbose` pasa a true por defecto. Las trazas salen por os_log (subsystem `fndiag`),
  legibles con `log show --predicate 'subsystem == "fndiag"'` sin acceso al contenedor.

## v0.1.0
- Compila para iOS arm64 (minos 17.0) y para macOS (pruebas). Sin warnings.
- Probado en un host macOS con DYLD_INSERT_LIBRARIES: el hook de sesiones devuelve
  configuración efímera, se registran NSError (-999, -1003) y la descarga correcta
  (fichero temporal, tamaño, HTTP 200).

- Flags: `-Wall -Wextra -Werror` siempre. Hasta v0.2.1 hubo `make sanitize` (macOS, ASan+UBSan);
  se eliminó (ASan no puede ir en la dylib iOS). En esa versión pasó sin errores en el host
  de prueba, incluido el camino de error 404 del Updater (repo privado).

## Sin verificar
- Que la dylib cargue dentro de Fortnite.app tras inyectarla y re-firmar.
- Que `foreground=1` elimine el ESP-CON-000. Si no, el NSError de FnDiag.log dice el motivo.
- El Updater de extremo a extremo (apagado por defecto; sustituir una dylib firmada
  puede invalidar la firma del bundle).

## Pendiente
- Decidir si `Documents/FnDiag.log` basta o hace falta más información del juego.
