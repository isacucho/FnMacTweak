# Errores ya cometidos

- Un grep de `ESP` casa con `Response` en el log del juego: usar `ESP-CON` o excluir
  `LogBackgroundHttpRequest`.
- No asumir que el Assistant mata nsurlsessiond durante los fallos: el pid llevaba vivo
  desde antes. Mirar `ps` antes de culpar al Assistant.
- En C++ puro un bloque no convierte a `id`: hace falta `reinterpret_cast<id>` para
  `imp_implementationWithBlock`.
- Hookear un método heredado con una tabla orig por clase da recursión con `super`:
  cada bloque debe capturar su propio IMP original.
- `Upadter.hpp` (typo) no coincidía con `#import "Updater.hpp"`.
- El contenedor de la app está protegido por TCC: sin Acceso total al disco el terminal
  recibe "Operation not permitted".
