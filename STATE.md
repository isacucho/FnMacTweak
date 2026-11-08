# Estado de la investigacion

## Estado actual

**CAUSA RAIZ REAL IDENTIFICADA. v2.0.33 deployada pero kick persiste. v2.0.34 requerida.**

## Timeline del kick - Sesion 1 (v2.0.32, 2026-11-08)

| Timestamp | Linea | Evento |
|---|---|---|
| 17:34:19 | 3-57 | Init OK: 18/18 KickBypass, NmtPatch, todos los hooks |
| 17:34:24 | 11239 | HTTP 429 en `linkIdentity` (rate limit startup, no fatal) |
| 17:34:32 | 16808 | HTTP 400 en `experience_br?platform=ios&major=43` |
| 17:34:50 | 17225 | `CustomKeyMatchCommand_PlayerKick` REGISTRADO (entrada partida) |
| 17:35:30 | 9114 | **ConnectionLost (game time 16.35.30:588)** -> match exit |
| 17:35:30 | 17850+ | LogFortPerformance end-of-zone report (analiticas post-exit) |
| 17:35:33 | 17919 | `CustomKeyMatchCommand_PlayerKick` DESREGISTRADO |

## Timeline del kick - Sesion 2 (v2.0.33, 2026-11-08)

| Timestamp OSLog | Linea | Evento |
|---|---|---|
| 18:05:48 | 9114 | Replay sesion anterior (buffered game log) |
| 18:06:03 | 20960 | **[ContentPatch] experience_br intercepted -> synthetic 200** (HTTP fix OK) |
| 18:06:17 | 21371 | `CustomKeyMatchCommand_PlayerKick` REGISTRADO (game time 17.06.17) |
| 18:06:59.562 | 21867 | **[KickBypass] ClientWasKicked reason=1805386128 -> SUPPRESSED** |
| 18:07:00.020 | 22009 | **ConnectionLost (game time 17.06.59:655, 93ms tras el RPC)** -> match exit |
| 18:07:00 | 22165+ | LogFortPerformance end-of-zone report (analiticas post-exit) |
| 18:07:00 | 22237 | `CustomKeyMatchCommand_PlayerKick` DESREGISTRADO |

Match entry: 17.06.17. ConnectionLost: 17.06.59. Duracion: **42 segundos** (identico ambas sesiones).

## Causa raiz

**Mecanismo double-barrel del servidor:**

1. Servidor envia `ClientWasKicked RPC, reason=1805386128` a ~42s de match entry
2. KickBypass suprime el RPC (correcto, funciona)
3. Servidor detecta que el cliente no se desconecto -> cierra la conexion UDP 93ms despues
4. `BroadcastNetworkFailure: ConnectionLost` en GameNetDriver -> match exit
5. LogFortPerformance end-of-zone analiticas se disparan como parte del exit (incluye NumLoadCustomizationFailed, que siempre aparece al salir, no es causa)

**El reason code 1805386128 (0x6B9C0190)** no esta en el rango documentado (0-5).
Probablemente un kick de plataforma/EAC con reason code extendido.

## Hipotesis descartadas

- **NumLoadCustomizationFailed como causa**: DESCARTADA. Es telemetria de fin de partida.
- **HTTP 400 en experience_br como causa directa del kick**: DESCARTADA. ContentPatch
  corrige el 400 a 200 (confirmado en v2.0.33 linea 20960/20962) pero el kick persiste.
- **EAC heartbeat puro sin ClientWasKicked**: DESCARTADA. KickBypass intercepta un RPC real.

## Patches existentes

### v2.0.33 (deployada, funciona parcialmente)

- ContentPatch: `FnContentLinkProtocol : NSURLProtocol` intercepta `experience_br` -> HTTP 200
- Confirma: HTTP 400 era un problema real (cosmetics), pero no la causa del kick
- KickBypass 18/18 entries funcionando: suprime el RPC correctamente
- **El kick persiste porque el servidor usa ConnectionLost como fallback al RPC suprimido**

## Estado actual: v2.0.35 compilada, pendiente deploy y test

NetFailurePatcher doble path:
1. Vtable scan (__DATA_CONST/__AUTH_CONST): si encuentra punteros a bnf_va, los reemplaza.
   En este build encuentra 0 (funcion devirtualizada).
2. Fallback BL-caller patching: 8 callers directos parchados en __TEXT via trampoline page
   (vm_allocate VM_FLAGS_FIXED cerca de base-0x2000000, dentro de ±128MB de todos los callers).
   BL->trampoline->bnf_bypass_stub. Cada caller validado antes de parcharlo (opcode + target).

g_last_kick_suppressed_ns es el canal entre KickPatcher y NetFailurePatcher (500ms window).

Deploy y verificar con:
```bash
bash tools/resign.sh && bash tools/deploy.sh
log stream --predicate 'subsystem == "com.alexgrdev.fnmackickfix"' --level debug
```

Lineas de log a buscar al inicio:
- `[NetFailurePatch] trampoline page at 0x...` (trampoline asignado)
- `[NetFailurePatch] BL patched 0x... -> tramp 0x...` (8 veces)
- `[NetFailurePatch] done: ... bl_patched=8/8`

Linea a buscar a los ~42s de match entry:
- `[NetFailurePatch] ConnectionLost suppressed (delta=XXms after suppressed kick)`

Callers RVA (IMAGE_BASE=0x100000000):
  0xf21998, 0xf89044, 0x113b89c, 0x117504c, 0x16356dc, 0x54c43c4, 0x54c7db4, 0x5b9fb70
