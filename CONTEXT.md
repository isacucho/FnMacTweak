# FnMacUpdateFix

Dylib (C++/ObjC++) para el Fortnite iOS sideloaded que corre en Apple Silicon con
FnMacAssistant. Objetivo: diagnosticar y evitar el ESP-CON-000 ("An error occurred
while connecting to Epic servers") que aparece al abrir el juego tras actualizar.

Software real (no ejercicio académico): arquitectura modular permitida.

## Qué se sabe del error
- La red y TLS funcionan. La CDN responde (HTTP 206 a un chunk concreto).
- El juego baja chunks con NSURLSession background (LogIOSBackgroundDownload) y
  acaban en `didCompleteWithError` -> `ConnectivityError` en InstallBundleSourceBPS.
- El log del juego no imprime el NSError. De ahí que la dylib lo registre.
- Causa (v0.3.0): tras reinstalar, nsurlsessiond reconecta las sesiones background del mismo
  identificador y entrega los ficheros en el contenedor anterior, que ya no existe.

## Estructura
- `includes/fndiag/`: API del módulo de diagnóstico (log, hooks, config, objc_util).
- `includes/Logger.hpp`, `iOSSimulatorContext.hpp`, `Updater.hpp`: código propio de Alex.
- `src/`: implementación. `MainModule.mm` es el constructor de la dylib.
- `builds/`: solo `dev/`, `beta/`, `public/` y `release/` (todo generado) y su Makefile.
  Dylib `FnMacUpdateFix-V<version>[-dev|-beta].dylib`, nombre calculado en `common.mk`.
  `make` = dev (-O0), `make beta` (-O2), `make public` (-O2, PRODUCTION),
  `make package` = public firmada ad-hoc + manifest.json en `release/`. Solo iOS arm64.
- Cada carpeta tiene Makefile; el de la raíz delega. Ver `make` en la raíz.

## Comportamiento
- Hooks de observación (siempre): NSError, HTTP y fichero temporal de cada descarga
  (`network_hooks.cpp`); move/copy/exists de NSFileManager y stat/lstat/access/open/unlink/rename
  interpuestos con dyld sobre rutas `CFNetworkDownload` o `BackgroundHttp` (`file_hooks.cpp`);
  `SetDownloadResult`/`GetDownloadResult` de `FBackgroundNSURLSession` (`engine_hooks.mm`).
  Salen por os_log (subsystem `fndiag`) y por `$HOME/Documents/FnDiag.log`.
- `patch_status=1` (por defecto): `GetDownloadResult` devuelve 200 en vez de 201 si el temporal
  existe y no está vacío. Es la configuración que se sabe que funcionaba (NetHook.mm original).
- `persist_downloads` (beta/dev: 1, public: 0): `PersistentDownloadDir` pasa a enlace a
  ~/Library/Application Support/FnMacUpdateFix para sobrevivir a reinstalar (prueba, v0.5.0).
- `relative_paths=1` (por defecto): `GetDownloadResult` devuelve la ruta del temporal relativa a
  `Documents/`; con la absoluta el motor la duplica y no encuentra la descarga (bucle).
- `create_dirs=1` (por defecto): crea `PersistentDownloadDir/BackgroundHttp/<build>/` si falta
  antes de que el motor mueva ahí una descarga (causa directa del ESP-CON-000).
- `isolate_sessions=1` (por defecto): el identificador de cada sesión background lleva el UUID
  del contenedor, para que nsurlsessiond no reconecte sesiones de una instalación anterior
  (causa del ESP-CON-000 tras reinstalar con Sideloadly).
- `isolate_sessions=1` (por defecto): identificador de sesión background + `.<UUID contenedor>`.
- `foreground=0` (por defecto): sesiones background (con `isolate_sessions`). `foreground=1` las cambia por
  efímeras en proceso (probado en v0.1.0: no bastó por sí solo).
- Config: variables `FNDIAG_*` o `Documents/FnDiag.conf` con `foreground`, `isolate_sessions`, `create_dirs`, `relative_paths`, `patch_status`,
  `verbose`, `trace_files`, `autoupdate`.
- `autoupdate` (apagado): descarga manifest.json de GitHub Releases, verifica SHA-256 y
  deja la dylib nueva para el siguiente arranque, con `.bak` de la anterior. Sustituye el
  fichero en su misma ruta, así que conserva el nombre de la versión que estaba inyectada.

## Releases y rollback
Cada versión es una Release con `FnMacUpdateFix-V<version>.dylib` y `manifest.json` en
https://github.com/AlexGRDev/FnMacUpdateFix. Hasta v0.3.2 el proyecto se llamó FnFixUpdate y
sus assets conservan ese nombre (v0.1.0 y v0.2.0 tienen install_name interno `FnFix.dylib`). Para volver atrás:
descargar la dylib de la Release anterior y reinyectarla con Sideloadly.
