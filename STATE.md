# Estado de la investigacion

## Estado actual

**V2.6.0 compilada. Pendiente deploy+resign.**

### V2.6.0 - mecanismo implementado

- Heap scan eliminado por completo (era fragil: scan de 5GB, threading, stale ptrs).
- Dos nuevos hooks en vtable de UFortRejoinCheck (__DATA_CONST):
  - kInitializeVtableOff=0xd4a4e60: init_hook_stub captura UFortRejoinCheck* en
    g_rejoin_check_instance cuando el subsistema se inicializa al entrar en partida.
  - kRejoinVtableOff=0xd4a4e70: rejoin_bypass_stub sigue presente (fuerza bCanRejoinSession
    si alguien llama RejoinViaSessionInternal a traves del vtable).
- En kick reason=144: dispatch_async(main_queue) con g_rejoin_check_instance directamente.
  O(1), sin pthread, sin scan.
- Chained fixups confirmados: kInitializeFnOff=0x805c820 (Initialize body),
  ambos entries en mismo vtable a 2 slots de distancia (confirmado 2026-11-10).

### Para deployar V2.6.0

```bash
sudo bash tools/deploy.sh && bash tools/resign.sh
```

Log esperado al entrar en partida (init hook):
```
[Reconnect] Initialize vtable patched: orig=0x... stub=0x... entry=0x...
[Reconnect] Initialize captured UFortRejoinCheck* 0x...
```

Log esperado en kick reason=144:
```
[KickBypass] suppressed reason=144 - dispatching RejoinViaSessionInternal obj=0x...
[Reconnect] RejoinViaSessionInternal firing on main thread obj=0x...
[NetFailurePatch] synthetic CT skipped (rejoin in progress)
```

Si Initialize patch FAILED en startup: el offset kInitializeFnOff es incorrecto
(actualizar desde binary), la partida habra terminado con "not cached".

### Mecanismo confirmado (V2.1.24 FnDiag.log + V2.1.25 NCL session)

Tras un kick reason=144:

1. `[KickBypass] ClientWasKicked reason=144` -> suprimido, BeginSpectating llamado con self
2. Servidor sigue enviando ConnectionLost cada ~8ms indefinidamente
3. Nuestro hook suprime todos los ConnectionLost (flooding indefinido)
4. BeginSpectating con `self` como ViewTarget dispara `Warning: BeginSpectating: Attempting to spectate self!` (UE rechaza PlayerController como ViewTarget de si mismo); spectate mode NO se activa
5. A t=90s: `UNetConnection::Tick: Connection TIMED OUT. Elapsed: 90.00, Threshold: 90.00` -> ConnectionTimeout -> BroadcastNetworkFailure type=? (integer desconocido, NOT suprimido por nuestro hook) -> `Location=ReturningToFrontEnd` -> lobby limpio sin NCL

**FREEZE = 90s entre kick y ConnectionTimeout.** No hay NCL screen.

## Historia de versiones relevante

| Version | Comportamiento | Resultado |
|---|---|---|
| V2.1.23 | BeginSpectating con nullptr ViewTarget | Crash en spectate tick a t=17-18s |
| V2.1.24 | BeginSpectating con self ViewTarget | 90s freeze, lobby limpio (no NCL). A veces 22s (inconsistente) |
| V2.1.25 | Igual + flood-cap 25s | NCL screen a t=25s (BeginSpectating falla, ConnectionLost pasa sin spectate activo) |
| V2.1.26 | Revert flood-cap, supr. indefinida + log BNF types | 90s freeze, lobby limpio. BNF type= nunca aparecio (ConnectionTimeout bypasa nuestro BL site) |
| V2.1.27 | Synthetic ConnectionTimeout via dispatch_after(25s) | VERIFICADO 2026-11-10: lobby limpio a 25s |
| V2.2.0 | vtable patch RejoinViaSessionInternal, bCanRejoinSession bypass | Hook instalado OK, RejoinViaSessionInternal nunca llamado por ConnectionTimeout path. Falta trigger explicito. |

## V2.1.27 - que cambia

- kConnectionTimeout = 4 (confirmado: ENetworkFailure strings block en binario, orden: 3=ConnectionLost 4=ConnectionTimeout)
- ConnectionTimeout no pasa por nuestro hook (distinto BL site en UNetConnection::Tick, no parchado por patch_binary.py)
- Mecanismo: en la primera supresion de ConnectionLost post-kick, guardar params (self/world/driver) y dispatch_after(25s, main_queue) que llama g_orig_bnf con kConnectionTimeout
- Resultado esperado: lobby return limpio a t=25s en lugar de t=90s
- Flood de ConnectionLost sigue suprimido despues del synthetic (g_last_kick_suppressed_ns no se borra)
- Real ConnectionTimeout a t=90s deberia no dispararse (UNetConnection destruida a t=25s por el lobby return)

## Deploy V2.1.26

```bash
bash tools/deploy.sh && bash tools/resign.sh
```

(deploy.sh tiene sudo interno para codesign --remove-signature)
(resign.sh NO llevar sudo externo: usa el keychain del usuario para Apple Development cert)

## Offsets v2.0.32 (slide 0x46c000, base 0x10046c000)

| Simbolo | Offset desde base | Notas |
|---|---|---|
| KickBypass vtable | kKickedFnOffset = 0x858cf18 | 18 entradas parchadas |
| BNF disk island | kBnfOffset = 0x5642c74 | kBnfPrologue = 0xd10203ff |
| BeginSpectating island | kSpectateIslandOff = 0xb945b84 | magic 0xb00395b0 |
| BeginSpectating slot | kSpectateSlotOff = 0x12bfa888 | __bss slot |
