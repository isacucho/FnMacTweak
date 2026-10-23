# Errores ya cometidos

- Un grep de `ESP` casa con `Response` en el log del juego: usar `ESP-CON` o excluir
  `LogBackgroundHttpRequest`.
- No asumir que el Assistant mata nsurlsessiond durante los fallos: el pid llevaba vivo
  desde antes. Mirar `ps` antes de culpar al Assistant.
- Antes de dar una dylib por buena, comprobar que el juego sigue arrancando con ella: la sonda de
  GameController (v0.5.4) lo cerraba en cada arranque. Mirar `Terminating app due to uncaught
  exception` en el log del sistema.
- `cat` esta redefinido en la terminal del usuario (cabecera con color): `"$(cat f)"` mete esa
  cabecera en el fichero. Usar `command cat` o no leer el fichero.
- En C++ puro un bloque no convierte a `id`: hace falta `reinterpret_cast<id>` para
  `imp_implementationWithBlock`.
- Hookear un método heredado con una tabla orig por clase da recursión con `super`:
  cada bloque debe capturar su propio IMP original.
- `Upadter.hpp` (typo) no coincidía con `#import "Updater.hpp"`.
- El contenedor de la app está protegido por TCC: sin Acceso total al disco el terminal
  recibe "Operation not permitted".
- Interponer stat/open con dyld: no reservar memoria ni llamar a config() antes de comprobar la
  ruta (se invocan antes de que libc++ esté inicializado). Con ASan en el host de pruebas
  crashea al arrancar porque ASan llama a stat dentro del inicializador de libSystem.
- Cada reinstalación con Sideloadly cambia el UUID del contenedor. nsurlsessiond recuerda las
  sesiones background por identificador y sigue entregando al contenedor viejo. Al leer
  trazas, comprobar qué contenedor existe (`ls -ld ~/Library/Containers/<UUID>`).
- En un proceso macOS sin sandbox `NSHomeDirectory()` ignora `HOME`: los hosts de prueba deben usar
  `getenv("HOME")` o escriben en el home real (pasó en las pruebas de v0.2.0, v0.3.0 y v0.3.2: dejaron ~/Documents/moved.bin,
  ~/Documents/BackgroundHttpTemp y ~/Documents/FortniteGame; se borraron).
- Antes de comparar arranques, comprobar el contenedor de cada pid (rutas `Containers/<UUID>` en
  las trazas): una reinstalación entre medias explica una descarga completa.
