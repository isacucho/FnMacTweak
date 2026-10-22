# Estado

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

- Flags: `-Wall -Wextra -Werror` siempre. `make sanitize` (macOS, -O0, ASan+UBSan,
  `-fno-sanitize-recover=all`, salida en builds/mac-san/) pasa sin errores en el host
  de prueba, incluido el camino de error 404 del Updater (repo privado).

## Sin verificar
- Que la dylib cargue dentro de Fortnite.app tras inyectarla y re-firmar.
- Que `foreground=1` elimine el ESP-CON-000. Si no, el NSError de FnDiag.log dice el motivo.
- El Updater de extremo a extremo (apagado por defecto; sustituir una dylib firmada
  puede invalidar la firma del bundle).

## Pendiente
- Decidir si `Documents/FnDiag.log` basta o hace falta más información del juego.
