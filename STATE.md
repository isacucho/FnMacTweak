# Estado de la investigacion

## Estado actual (2026-11-14, V23.8.0)

Build activo: **43.10 (60278837)**. IPA instalado con Sideloadly.

### Parches activos confirmados en log (V23.7.x)

- ValidationPatch: slot1(r=10)=ok slot2(r=6)=ok
- EOS hooks: 8/8 OK
- MkwBypass: 3/3 OK
- KickBypass 43.10: 18/18 parchadas
- CustomizationPatcher: activo (cabreado en V23.7.9, cableado en V23.7.12)
- StatusCodeFix: 201->200 para FBackgroundNSURLSession (EngineHooks)
- GameUpdater: informa build soportado al arranque (V23.8.0)

### Sin verificar en sesion actual (V23.8.0)

- Partida BR completa con OtaUpdater/GameUpdater activos
- Verificar en log: "[GameUpdater] build 60278837 (43.10) — soportado"
- Verificar que CL (errors.com.epicgames.common.processing) no aparece
  (causa eliminada: Updater con sharedSession a 30s sustituido por OtaUpdater
   con sesion efimera + autoupdate=false por defecto)

### Regla de arquitectura innegociable

ZERO disk patching: el binario del juego en disco no se toca ni se modifica jamas.
Solo se permiten vtable swaps en __DATA_CONST via vm_protect(RW) en paginas 16KB.

---

## Historial de versiones reciente

| Version | Cambio |
|---|---|
| V23.8.0 | Reemplaza Updater por OtaUpdater + GameUpdater. Elimina CL por sharedSession. |
| V23.7.12 | Cablea CustomizationPatcher; actualiza string para build 43.10. |
| V23.7.11 | Hook SetApplicationStatus para evitar desconexion por BackgroundSuspended. |
| V23.7.10 | Cablea StatusCodeFix y EngineHooks; parchea 201->200 FatCosmo. |
| V23.7.9 | Elimina codigo muerto: SessionOverride, NetworkHooks, ContentPatch, NetFailurePatcher. |
| V23.7.8 | BNF + CustomPatch via vtable swap en __DATA_CONST. |

---

## Offsets v2.0.32 (slide 0x46c000, base 0x10046c000)

| Simbolo | Offset desde base | Notas |
|---|---|---|
| KickBypass vtable | 0x1089f8f18 (orig) | 18 entradas parchadas |
| KickBypass stub | 0x113da5720 | Reemplaza las 18 entradas |
| NmtPatch chain | 0x10c73ff10 | seg __DATA_CONST |

Recalcular con slide actual desde log de inicio:
`[KickBypass] vtable patch: 18/18 entries patched slide=0x46c000`

## Log de diagnostico

```bash
tail -f ~/Library/Containers/0F16E856-1C80-4448-9C65-ED3A8E8DA5E9/Data/Documents/FnDiag.log | grep -E "GameUpdater|OtaUpdater|KickBypass|BNF|slot|armed"
```

Subsistema OSLog (NetHook, EAC-Auth):
```bash
log stream --predicate 'subsystem == "com.alexgrdev.fnmackickfix"' --level debug
```
