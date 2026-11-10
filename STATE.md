# Estado de la investigacion

## Estado actual

**V2.6.6 deployada. Fix regression V2.6.4: g_rejoin_attempted se seteaba antes del EOS probe, bloqueando el synthetic CT. Freeze 25s (V2.1.27) restaurado. Pendiente verificacion en partida.**

### V2.6.4 - CONCLUSION: RejoinViaSessionInternal incallable

Probe con vm_read_overwrite confirmo: al momento de ClientWasKicked (reason=144),
el objeto EOS session referenciado por [base+0xc25a468]->slot2 ya esta liberado.
vm_read_overwrite de slot2+0xd68 retorna kr=1 (KERN_INVALID_ADDRESS).

Cadena de punteros (con slide=0x22f0000):
  [base+0xc25a468] -> slot1 (valid)
  *slot1 -> slot2 (non-null)
  vm_read(slot2+0xd68) -> KERN_INVALID_ADDRESS (objeto liberado)

El EOS SDK libera el session object en sus propios hilos antes de que el game thread
ejecute ClientWasKicked_Implementation. Cualquier llamada a RejoinViaSessionInternal
crashea en fn+0x3c con acceso a memoria no mapeada -> RequestExit(false) = silent exit.

V2.6.4 bloquea la llamada cuando kr != KERN_SUCCESS. El freeze 25s de V2.1.27 sigue activo.

Comportamiento actual verificado: kick reason=144 -> 25s freeze -> lobby limpio.
No hay crash silencioso. El rejoin via EOS session no es viable.

### V2.6.2 - fix crash silencioso en RejoinViaSessionInternal (INSUFFICIENTE)

- V2.6.1 crasheaba con salida limpia UE5 (sin IPS). Causa identificada por analisis binario:
  RejoinViaSessionInternal+0x3c llama una funcion que lee un byte de estado EOS en
  [global+0x468+0x0+0xd68] y comprueba que sea < 5 (InProgress). Si >= 5 (Ending/Ended),
  checkf("Attempting to rejoin last session.") dispara -> RequestExit(false) = salida silenciosa.
  El pthread + dispatch_async de V2.6.1 introducian ~3ms de latencia suficientes para que
  el game thread procesara el kick y la sesion EOS llegara a estado >= 5 antes de que
  nuestro bloque se ejecutara en la main queue.
- V2.6.2: scan sincronico en el game thread (ya estamos en el durante ClientWasKicked) + llamada
  directa a g_orig_rejoin sin dispatch_async. El estado EOS sigue < 5 en ese momento.
  Eliminado rejoin_scan_thread y el include de pthread.h.
- kRejoinVtableOff=0xd4a4e70: sigue parcheado.

### Para deployar V2.6.2

```bash
sudo bash tools/deploy.sh && bash tools/resign.sh
```

Log esperado en kick reason=144:
```
[KickBypass] suppressed reason=144 self=0x... - scanning for UFortRejoinCheck*
[Reconnect] scan done (Xms) obj=0x... bCanRejoinSession forced -> calling RejoinViaSessionInternal
[Reconnect] RejoinViaSessionInternal returned
```

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
