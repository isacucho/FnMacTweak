# Estado de la investigacion

## Estado actual (2026-11-14, V23.7.8)

### V23.7.8: BNF + CustomPatch via vtable swap en __DATA_CONST (2026-11-14)

AMFI bloquea MSHookFunction/vm_protect(COPY) en __TEXT del ejecutable principal.
Reemplazados ambos hooks por scan de __DATA_CONST + vm_protect(RW) en paginas 16KB.
Mismo mecanismo que KickBypass (18 entradas) y ValidationPatch.

6. **BNF via __DATA_CONST vtable swap** (NetFailurePatcher.cpp).
   Scan de __DATA_CONST para todos los slots apuntando a `base + kBnfOffset`.
   g_orig_bnf = puntero directo a bnf_va (execute, no write -> AMFI-safe).
   Si BNF no aparece en vtables (devirtualizado): synthetic CT a t+25s sigue activo.

7. **CustomizationFailed via __DATA_CONST vtable swap** (CustomizationPatcher.cpp).
   Intento 1: fixed offset `kCustomFnOff = 0xa30b698` con prologue check.
   Intento 2: string scan "execHandleCustomizationFailed" en __cstring + ADRP+ADD walkback.
   Si se encuentra fn_va: scan __DATA_CONST y patch slots.
   kCustomFnOff tiene prologue incorrecto en 43.10 -> string scan es el path principal.

8. **tools/patch_binary.py eliminado** (desde V23.7.6).
   Sin disk patching. deploy.sh no lo llama.

### Sin verificar (V23.7.8)
- Partida BR completa con BNF vtable swap activo
- **CRITICO**: verificar en log: "[NetFailurePatch] BNF vtable swap: N slot(s)" con N > 0
  Si N = 0: BNF esta devirtualizado en este build -> CL suppression y synthetic CT inactivos
  -> NCL screen persiste. Siguiente paso: GEngine instance vtable swap en heap.
- Verificar en log: "[CustomPatch] vtable swap: N slot(s)" o "fn via string scan"
- Verificar: ConnectionLost suprimido, lobby return limpio sin NCL a t+25s

### Correcciones aplicadas (2026-11-14, auditoria bugs)

Auditoria exhaustiva del codigo fuente. Bugs encontrados y corregidos:

1. **CRITICO: install_customization_patch() nunca se llamaba** (Core.mm).
   El disk island de HandleCustomizationFailed estaba en disco pero el slot __bss
   siempre era 0 -> stub nunca se ejecutaba -> NumLoadCustomizationFailed no suprimido.
   Fix: llamada añadida en Core.mm tras install_kick_bypass().

2. **MEDIO: mach_timebase_info() en cada BNF call** (NetFailurePatcher.cpp).
   Syscall al kernel en cada ConnectionLost durante el flood (~125/s). Cacheado en
   g_kick_window_ticks, calculado una vez en install_net_failure_patch().

3. **MENOR: dmb ish faltante** (CustomizationPatcher.cpp).
   Barrera de memoria añadida tras escritura del slot __bss.

4. **MENOR: g_original_eac_cb/cd sin atomic** (EosHooks.cpp).
   Formal data race en multithreaded EOS SDK. Convertidos a std::atomic<>.

5. **OBFUSCACION: -g siempre presente en todos los builds** (Makefile).
   -g ahora solo en dev/beta. CHANNEL=public usa -Wl,-x -Wl,-S via STRIP_FLAGS.

Referencia: rt-someone/FnMacTweak es un tweak QoL/input (120FPS, mouse), sin solapamiento
con este repo. No tiene kick bypass, BNF patching ni EOS hooks.

### V23.7.7: fix compatibilidad JadedFix (2026-11-14)

Conflicto confirmado: `kVersionTable` para 43.00 tiene fn1_off=0x74c1334 / vtable1_off=0xcd32e18,
exactamente los offsets hardcodeados en JadedFix/kick_fix.c. Para 43.10, JadedFix usa fnResolve
que escanea __DATA_CONST buscando un puntero al fn1 original. Nuestro patch_vtable_entry
reemplazaba ese puntero por validation_pass_stub ANTES de que JadedFix inicializara, asi
fnResolve encontraba 0 slots y JadedFix no instalaba.

Fix: install_validation_patch() diferida a dispatch_async(main_queue). Los constructores de
dylib (JadedFix incluido) completan antes de que el main queue drene. Cuando nuestro bloque
corre: si JadedFix ya patcho slot1, patch_vtable_entry detecta current!=expected y lo salta.
Si JadedFix no esta presente, slot1 sigue con fn1_va y lo parcheamos nosotros.

Error observado (errors.com.epicgames.common.processing): consecuencia de JadedFix no instalado,
el backend rechaza la sesion por los tipos {5,19,23,49} sin bypass.

### Sin verificar en esta sesion
- Partida completa con fix JadedFix activo (V23.7.7)
- Verificar en log: "[ValidationPatch] skip vtable" para slot1 cuando JadedFix activo
- EAC interceptor tipo 0x01 en log real post-fix

---

## Estado (2026-11-13, V23.7.5 - fix BNF window 2000ms->5000ms)

**Build activo: 43.10 (60278837). IPA reconstruido desde FortniteClient-IOS-Shipping.app. Instalado con Sideloadly.**

### Parches activos confirmados en log (PID 78872)
- ValidationPatch: slot1(r=10)=ok slot2(r=6)=ok
- EOS hooks: 8/8 OK
- MkwBypass: 3/3 OK
- KickBypass 43.10: 18/18 parchadas

### Disk island: APLICADO y BL callers PARCHADOS (2026-11-13)
patch_binary.py actualizado para 43.10: BNF_OFFSET=0x56c999c, 6 BL callers, ISLAND_BYTES
con ADRP #0x12d7d (slot 0x112d7f9c0 = __bss inicio 43.10).
BUG CORREGIDO: branch state=='patched' no parchaba BL callers. Fix aplicado.
6/6 call sites OK (island presente + callers redirigidos -> island).
IPA v5: `/Users/alexg/Documents/Dev/Fortnite/Fortnite-43.10-fnpatch-v5.ipa`
Instalar con Sideloadly. Verificar `[NetFailurePatch] ConnectionLost suppressed` en log.

Nota: SPEC y CUSTOM islands NO parchados en 43.10 (sus fn offsets cambiaron).
BeginSpectating y CustomizationFailed sin bypass de disco. Pendiente scan para 43.10.

### Fix aplicado esta sesion: MarketplaceKitWrapper crash (SIGSEGV al arrancar)
El closure `AppDistributorWrapper.getCurrent` llama al stub de `MarketplaceKit.framework`
(LC_LOAD_WEAK_DYLIB, no disponible en este macOS) -> puntero NULL -> pc=0x0 -> SIGSEGV 1s
tras arranque. Fix: `rm -rf MarketplaceKitWrapper.framework` del bundle. Incorporado en
resign.sh permanentemente (linea despues del xattr -cr).

### Fixes en V23.7.6 (IPA v9, 2026-11-13)
- kKickWindowNs 5000ms -> 30000ms: el flood del servidor es INDEFINIDO (~8ms/evento mientras no se desconecte).
  PID 80434: kick=09:55:25.551, flood hasta 09:55:30.575 (5024ms). Ventana 5s expiraba 24ms antes. 3 escaparon.
  Fix: 30s cubre el CT sintetico a t+25s. Tras lobby return, flood para naturalmente.
- IPA v9: /Users/alexg/Documents/Dev/Fortnite/Fortnite-43.10-fnpatch-v9.ipa

### Fixes en V23.7.5 (IPA v8, 2026-11-13)
- kKickWindowNs 2000ms -> 5000ms: en PID 76831, kick=09:39:31.988, BNF flood hasta 09:39:34.020 (2032ms).
- IPA v8: /Users/alexg/Documents/Dev/Fortnite/Fortnite-43.10-fnpatch-v8.ipa

### Fixes en V23.7.4 (/Applications, 2026-11-13)
- VERSION: 23.7.4, ARM64 iOS17.0, compilado y firmado (VersionPlatform=2, CDHash=f096996e)
- EAC AddNotifyMessageToServer: interceptor activo - suprime tipo 0x01 (platform reports) al servidor
- bnf_bypass_stub: suprime ConnectionLost dentro de 500ms tras kick; despacha synthetic CT a 25s
- kicked_bypass_stub: registra timestamp g_last_kick_suppressed_at para coordinacion BNF
- Containers: nullfs de /Applications/Wrapper - no hace falta reinstalar Sideloadly

### Sin verificar en esta sesion
- Partida BR completa sin kicks (requiere gameplay activo)
- EAC interceptor tipo 0x01 en log real (nunca aparecio "(interceptor installed)")
- Ghost mode / zero damage bug (requiere partida)
- LLDB audit en proceso activo (nunca exitoso, SyntaxError corregido en tools/lldb_run_audit.sh)
- KickBypass efectivo en partida real

---

## Estado anterior (V2.6.6, pre-43.10 rebuild)

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
