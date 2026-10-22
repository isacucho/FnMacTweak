# Estado

## v0.1.0
- Compila para iOS arm64 (minos 17.0) y para macOS (pruebas). Sin warnings.
- Probado en un host macOS con DYLD_INSERT_LIBRARIES: el hook de sesiones devuelve
  configuración efímera, se registran NSError (-999, -1003) y la descarga correcta
  (fichero temporal, tamaño, HTTP 200).

## Sin verificar
- Que la dylib cargue dentro de Fortnite.app tras inyectarla y re-firmar.
- Que `foreground=1` elimine el ESP-CON-000. Si no, el NSError de FnDiag.log dice el motivo.
- El Updater de extremo a extremo (apagado por defecto; sustituir una dylib firmada
  puede invalidar la firma del bundle).

## Pendiente
- Decidir si `Documents/FnDiag.log` basta o hace falta más información del juego.
