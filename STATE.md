# Estado

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
