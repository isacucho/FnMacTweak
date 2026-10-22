# FnFixUpdate

Dylib (C++/ObjC++) para el Fortnite iOS sideloaded que corre en Apple Silicon con
FnMacAssistant. Objetivo: diagnosticar y evitar el ESP-CON-000 ("An error occurred
while connecting to Epic servers") que aparece al abrir el juego tras actualizar.

Software real (no ejercicio académico): arquitectura modular permitida.

## Qué se sabe del error
- La red y TLS funcionan. La CDN responde (HTTP 206 a un chunk concreto).
- El juego baja chunks con NSURLSession background (LogIOSBackgroundDownload) y
  acaban en `didCompleteWithError` -> `ConnectivityError` en InstallBundleSourceBPS.
- El log del juego no imprime el NSError. De ahí que la dylib lo registre.
- Hipótesis sin confirmar: las sesiones background (nsurlsessiond) de una app iOS
  sideloaded en Mac no entregan bien el fichero (ResponseTempLocation vacío).

## Estructura
- `includes/fndiag/`: API del módulo de diagnóstico (log, hooks, config, objc_util).
- `includes/Logger.hpp`, `iOSSimulatorContext.hpp`, `Updater.hpp`: código propio de Alex.
- `src/`: implementación. `MainModule.mm` es el constructor de la dylib.
- `builds/`: salida (`ios/`, `mac/`, `release/`), no se versiona salvo su Makefile.
- Cada carpeta tiene Makefile; el de la raíz delega. Ver `make` en la raíz.

## Comportamiento
- Siempre: registra NSError y fichero temporal de cada descarga en
  `$HOME/Documents/FnDiag.log` (HOME = contenedor de la app).
- `foreground=1` (por defecto): `backgroundSessionConfigurationWithIdentifier:` devuelve
  una configuración efímera en proceso. Se apaga con `foreground=0`.
- Config: variables `FNDIAG_*` o `Documents/FnDiag.conf` (`foreground`, `verbose`, `autoupdate`).
- `autoupdate` (apagado): descarga manifest.json de GitHub Releases, verifica SHA-256 y
  deja la dylib nueva para el siguiente arranque, con `.bak` de la anterior.

## Releases y rollback
Cada versión es una Release con `FnFix.dylib` y `manifest.json`. Para volver atrás:
descargar la dylib de la Release anterior y reinyectarla con Sideloadly.
