# PITFALLS - Errores activos

Regla estricta: un error a la vez. No avanzar al siguiente hasta resolver y verificar el actual.

---

## AUDITORIA PROTECCIONES RUNTIME (2026-11-13, build 60278837 / 43.10)

Analisis estatico del binario `/Applications/Fortnite.app/Wrapper/FortniteClient-IOS-Shipping.app/FortniteClient-IOS-Shipping` (308MB, ARM64, sha256=91f9e4fd).

### Jailbreak / Sideloading

Mecanismo detectado por strings:
- `isJailbrokenWithSkipAdvancedJailbreakValidation:` -> metodo ObjC de JailbreakDetection
- Rutas Cydia presentes: `/Applications/Cydia.app`, `/Library/MobileSubstrate/DynamicLibraries/LiveClock.plist`, `/private/var/lib/cydia`, `/System/Library/LaunchDaemons/com.saurik.Cydia.Startup.plist`

Mecanismo de fallo: dos funciones vtable en sideload/JIT validator devuelven reason=10 (sideload) y reason=6 (JIT). Si retornan != 1 -> kick.

**BYPASS activo (solucion Jaded = ValidationPatch):**
- vtable1 offset 0xce5ad38 -> fn1 offset 0x7571028 -> reemplazado con validation_pass_stub (retorna 1)
- vtable2 offset 0xce5acd8 -> fn2 offset 0x75710ac -> reemplazado con validation_pass_stub
- Verificado en runtime PID 78872: `[ValidationPatch] slot1(r=10)=ok slot2(r=6)=ok`

### Anti-tamper / Hash checks

Strings en binario:
- `Consistency Failure: Backing store page-in failed hash check!` -> integridad PAK de assets UE5 (renderizado)
- `FVerifier: Hash check failed for %ls` -> verificacion de assets
- Estos son checks de integridad de ASSETS (PAK files), no del binario ejecutable. No afectan kicks.

No hay firma de binario verificada en runtime (AMFI la gestiona el kernel, no el proceso).

### BroadcastNetworkFailure (ConnectionLost/ConnectionTimeout)

Cadena confirmada en binario:
- `ENetworkFailure::ConnectionLost` / `ENetworkFailure::ConnectionTimeout` (enum indexado 3 y 4)
- `UEngine::BroadcastNetworkFailure: FailureType = %ls, ErrorString = %ls` -> log UE5 del path de fallo
- Funcion BNF en file offset 0x56c999c, prologue: `ff 03 02 d1` = `SUB SP, SP, #0x80` (ARM64 ✓)

**REGLA ARQUITECTURA INNEGOCIABLE: ZERO disk patching. El binario en disco no se toca jamas.**

**AMFI CONSTRAINT (critico):** MSHookFunction/vm_protect(VM_PROT_COPY) en __TEXT del ejecutable principal
es bloqueado por AMFI -> EXC_BAD_ACCESS SIGKILL, Namespace CODESIGNING Code 2.
Esto aplica SOLO al ejecutable principal; dylibs externos (EOSSDK, etc.) se pueden hookear con MSHookFunction.
vm_protect en __DATA_CONST funciona sin restriccion AMFI (usado por KickBypass, ValidationPatch y BNF).
Llamar a __TEXT via function pointer (execute/read) es siempre seguro; solo la ESCRITURA esta bloqueada.

**BYPASS activo (VTable swap en __DATA_CONST, V23.7.8):**
- Scan de __DATA_CONST para todos los slots apuntando a `base + 0x56c999c`
- vm_protect(RW) en pagina 16KB (Apple Silicon) -> escritura -> vm_protect(R) + dmb ish
- g_orig_bnf = puntero directo a bnf_va en __TEXT (llamarlo desde stub es AMFI-safe: execute, no write)
- bnf_bypass_stub: suprime ConnectionLost dentro de ventana kick; synthetic CT a t+25s via dispatch_after

### ClientWasKicked (kick RPC)

Confirmado en binario:
- Strings: `ClientWasKicked Reason: %ls` en 0xb3fb7aa, `ClientWasKicked %ls.` en 0xb2e3ac5
- Funcion ClientWasKicked_Implementation en file offset 0x865a2b8, prologue: `ff 43 01 d1` = `SUB SP, SP, #0x50` (ARM64 ✓)
- 18 entradas vtable en __DATA_CONST (kKickedEntries_4310[]), apuntando a 0x865a2b8 on-disk (chained fixup encoding)

**BYPASS activo (KickBypass):**
- 18 entries parcheadas: vtable[0] @ 0xce7d390, ... (ver KickPatcher.cpp kKickedEntries_4310)
- Verificado en runtime PID 78872: `[KickBypass] 43.10: patched 18/18`
- kicked_bypass_stub registra timestamp en g_last_kick_suppressed_at para coordinacion BNF

### EAC AntiCheatClient (EOS SDK)

Confirmado en load commands:
- `@executable_path/Frameworks/EOSSDK.framework/EOSSDK` -> EAC SDK embebido ✓
- `@executable_path/Frameworks/CydiaSubstrate.framework/CydiaSubstrate` -> Substrate en load commands ✓
  NOTA: el binario carga CydiaSubstrate directamente. MSHookFunction en nuestro dylib usa este Substrate.
- `@rpath/FnMacBypass.dylib` (weak) -> nuestro dylib como LC_LOAD_WEAK_DYLIB ✓

**BYPASS instalado (EosHooks.cpp v23.7.4):**
- 8 EOS hooks via MSHookFunction en constructor
- AddNotifyMessageToServer: interceptor reemplaza NotificationFn con eac_msg_to_server_interceptor
- Suprime tipo 0x01 (platform integrity reports) para prevenir ghost mode
- PENDIENTE VERIFICACION: `(interceptor installed)` aun no ha aparecido en log de nueva sesion

### Resumen offsets Michau (43.10, build 60278837)

Los "offsets de Michau" referenciados en el stop hook son los 18 entradas KickBypass dispersas:
```
kKickedFn_4310 = 0x865a2b8 (ClientWasKicked_Implementation)
kKickedEntries_4310[18] = {
    0xce7d390, 0xd049c60, 0xd617e00, 0xd61c758, 0xd61f558,
    0xd625048, 0xd627c78, 0xd62ada0, 0xd62fcc8, 0xd6369e8,
    0xd6a70f8, 0xd723c08, 0xd726da8, 0xd72a048, 0xd72d2b8,
    0xd7692d8, 0xd7eb800, 0xd8138f8,
}
```
Todos verificados en runtime (18/18 parcheados). Origen externo (posiblemente proporcionados
por contacto "Michau" via Discord u otro canal externo al repo).

---

## AUDITORIA 2026-11-14: hallazgos y correcciones

### BUG CRITICO (CORREGIDO): install_customization_patch() nunca se llamaba

`Core.mm` omitia la llamada a `fndiag::install_customization_patch()`. El disk island de
HandleCustomizationFailed estaba correctamente instalado en disco (patch_binary.py --apply),
pero el slot __bss nunca se armaba con la direccion del stub. La isla siempre tomaba el
path execute_original (CBZ X16, slot==0 siempre cierto) y la funcion ejecutaba normalmente,
incrementando NumLoadCustomizationFailed sin restriccion.
FIX: añadida llamada en Core.mm despues de install_kick_bypass() con BOOT_PROBE "11_custompatch_done".

### BUG MEDIO (CORREGIDO): mach_timebase_info() en cada llamada a bnf_bypass_stub

Durante el flood de ConnectionLost (~125 llamadas/s mientras dura el kick), `bnf_bypass_stub`
llamaba `mach_timebase_info()` en cada iteracion para convertir kKickWindowNs a ticks.
Cada llamada es un trap al kernel. Innecesario: el timebase no cambia en runtime.
FIX: g_kick_window_ticks calculado una vez en install_net_failure_patch() y reutilizado.

### BUG MENOR (CORREGIDO): dmb ish faltante en CustomizationPatcher

Escritura del slot __bss en install_customization_patch() carecia de barrera de memoria.
Sin dmb ish, otro CPU ejecutando la isla podria ver el slot a 0 (valor anterior) aunque
el dylib ya hubiera escrito el stub address. El slot se escribe en el constructor, antes de
que el game thread pueda disparar la funcion, pero la barrera es semanticamente correcta.
FIX: añadido __asm__ volatile("dmb ish") inmediatamente despues de la escritura del slot.

### BUG MENOR (CORREGIDO): g_original_eac_cb/cd sin proteccion atomica

`eac_msg_to_server_interceptor` y `my_AddNotifyMsgToServer` pueden ejecutar en hilos
distintos del EOS SDK. Las variables globales `g_original_eac_cb` y `g_original_eac_cd`
se leian/escribian sin atomics (formal data race).
FIX: convertidas a std::atomic<uintptr_t> y std::atomic<void*> con acquire/release.

### OBFUSCACION (CORREGIDO): -g siempre presente en todos los builds

El Makefile incluia `-g` incondicionalmente, incrustando secciones __DWARF en la dylib
incluso en builds public (nombres de funcion, rutas de fuente, numero de linea). Esto
anula completamente el efecto de -fvisibility=hidden para simbolos internos.
FIX: `-g` solo se pasa en CHANNEL=dev y CHANNEL=beta via DEBUG_FLAGS.
Tambien anadido STRIP_FLAGS=-Wl,-x -Wl,-S para CHANNEL=public.
REGLA: `make PRODUCTION=1` (public) produce dylib sin DWARF; `make DEV=1` mantiene -g.

### rt-someone/FnMacTweak - sin solapamiento con este repo

El repo referenciado es un tweak QoL/input para Theos (120FPS, mouse lock, device spoof via
fishhook/sysctl). No implementa kick bypass, BNF patching, vtable patching, EOS hooks ni
atomic-slot patching. No hay patrones de concurrencia a adoptar ni conflictos posibles.
Los offsets del JadedFix (ValidationPatch vtable) y los nuestros tienen mutual exclusion:
el check `if (current != expected) return false` en ambos impide double-patch.

### 7 dias de re-firma (plan gratuito) - estrategias

Opciones sin pagar $99/año:
1. AltStore + AltServer (wifi pairing en la misma red): AltServer re-firma en background
   cuando el iPhone esta en la misma red. Configurar en Ajustes > AltStore > Background Refresh.
2. SideStore + SideServer (via WireGuard): re-firma remota sin necesidad de proximidad fisica.
   SideStore expone un OTA URL; desde el Mac, `sideserver` hace push de la re-firma.
3. Script launchd local: detectar expiry proxima con `codesign -d --verbose dist/FnMacBypass.dylib`
   y ejecutar resign.sh automaticamente. Fortnite debe estar cerrado durante la re-firma.
   Esqueleto del plist (editar dates y paths):
   ~/Library/LaunchAgents/com.alexgrdev.fnresign.plist con ProgramArguments=[resign.sh] y
   StartCalendarInterval cada 6 dias a las 03:00.
4. Paid tier ($99/year): certificados de 1 año, elimina el problema.
La opcion 1 (AltStore) es la mas sencilla para un free account con dispositivo fisico.
Para IPA reconstruidos, resign.sh ya maneja la firma ad-hoc; la automatizacion AltStore se
aplica al IPA instalado con Sideloadly, no al binario en /Applications.

---

## RESUELTO (2026-11-13): IPA con estructura macOS wrapper - Sideloadly rechaza

Sideloadly exige `Payload/<App>.app/Info.plist` directamente. El wrapper macOS de Fortnite
es `Fortnite.app/Wrapper/FortniteClient-IOS-Shipping.app/` y si se empaqueta desde
`/Applications/Fortnite.app/` como `Payload/Fortnite.app/`, Sideloadly falla con:
"There is no item named 'Payload/Fortnite.app/Info.plist' in the archive".
Correcto: empaquetar desde `Wrapper/FortniteClient-IOS-Shipping.app/` como
`Payload/FortniteClient-IOS-Shipping.app/`.

## RESUELTO (2026-11-13): MarketplaceKitWrapper SIGSEGV al arrancar (pc=0x0, 1s tras boot)

`AppDistributorWrapper.getCurrent` en MarketplaceKitWrapper llama al stub Swift de
`MarketplaceKit.framework` (enlazado como LC_LOAD_WEAK_DYLIB). En este macOS el framework
no existe, el stub resuelve a NULL, el closure lo llama -> SIGSEGV. El ejecutable principal
enlaza MarketplaceKitWrapper.framework tambien como LC_LOAD_WEAK_DYLIB.
Fix: eliminar `Frameworks/MarketplaceKitWrapper.framework/` del bundle instalado antes de
resignar. Incorporado en resign.sh permanentemente.
NO parchear el binario principal: basta con que el framework no este en el bundle.

## PITFALL: disk island ausente si IPA se construye antes de deploy.sh

deploy.sh aplica `patch_binary.py --apply` sobre el binario instalado en
`/Applications/Fortnite.app/Wrapper/...`. Si se reconstruye el IPA desde ese binario
SIN haber ejecutado deploy.sh primero, el disco island no estara en el IPA.
Sideloadly instala el binario limpio y el disk island se pierde.
Orden correcto: deploy.sh -> resign.sh -> (si necesitas IPA) construirlo ahora.

## BUG CRITICO CORREGIDO (2026-11-13): BL callers NO parchados aunque island presente

### Sintoma
FnDiag.log muestra `disk-island found` y `slot armed` pero NUNCA aparece
`ConnectionLost suppressed` ni `synthetic ConnectionTimeout firing`. bnf_bypass_stub
nunca se ejecuta. Los kicks tardan 90s (UNetConnection timeout) en lugar de 25s.

### Causa
`patch_binary.py apply_patch()` tenia un bug en el branch `state=='patched'`:
cuando el island ya existia en 0x29c0, el script asumia que los BL callers ya
estaban redirigidos y los saltaba completamente. Resultado: island instalado pero
los 6 callers siguen apuntando a BNF directamente.

Verificado con BL scan: 6 BL->BNF (orig_bl), 0 BL->island (new_bl).

### Fix
Branch `state=='patched'` ahora itera BL_PATCHES y parchea callers con orig_bl:
```python
for fo, new_bl, orig_bl in BL_PATCHES:
    if bytes(data[fo:fo+4]) == orig_bl:
        data[fo:fo+4] = new_bl  # redirect to island
```
Despues del fix: `python3 tools/patch_binary.py --verify` muestra 6/6 `[OK]`.

### IPA con callers parchados
`Fortnite-43.10-fnpatch-v5.ipa` - verificado: island OK + 6/6 callers->island.
Instalar con Sideloadly antes de probar BNF.

---

## RESUELTO: V2.5.0 heap scan crashea el proceso (SIGBUS + wrong thread)

**V2.5.1:** `vm_read_overwrite` elimino SIGBUS en el scan. No era la causa real.
**V2.5.2:** dispatch_async(main_queue) para RejoinViaSessionInternal. Elimino crash
silencioso por UE5 GameThread assertions al llamar desde pthread.
**V2.6.0:** heap scan eliminado completamente. Hook en UFortRejoinCheck::Initialize
(kInitializeVtableOff=0xd4a4e60) captura self en g_rejoin_check_instance al entrar
en partida. En kick: dispatch directo sin scan.

**Estado:** V2.6.0 descartada. V2.6.1: crash silencioso (UE5 RequestExit). Causa: dispatch_async
introducia ~3ms de latencia; estado EOS llegaba a >= 5 (Ending) antes de que nuestro bloque
se ejecutara, disparando checkf en RejoinViaSessionInternal+0x3c (LDRB [X8+0xd68]; CMP W8,#5).
V2.6.2: scan sincronico en game thread + llamada directa, sin pthread ni dispatch_async.
Pendiente deploy y verificacion en partida.

---

## Error #1 [ABIERTO]: Kick via ConnectionLost tras ClientWasKicked suprimido

### Sintoma

El jugador es expulsado de la partida aproximadamente 42-43 segundos despues de entrar.
Mecanismo final: `LogNet: Error: UEngine::BroadcastNetworkFailure: FailureType = ConnectionLost`.
Presente en AMBAS sesiones (v2.0.32 lineas 9114-9116, v2.0.33 lineas 22009-22011).

### Analisis previo (erroneo)

La investigacion inicial identifico `NumLoadCustomizationFailed >= 3` como causa raiz.
**Esta hipotesis era incorrecta.** `NumLoadCustomizationFailed` aparece en el bloque de
analiticas de fin de partida (`LogFortPerformance: Athena Client End of zone performance report`)
que se ejecuta siempre al salir de partida, independientemente de la causa del exit.
El trigger de performance es un report de telemetria, no el mecanismo de expulsion.

La v2.0.33 (ContentPatch) confirmo esto: HTTP 400 en experience_br corregido a 200,
pero el kick continua con el mismo timing de ~43 segundos.

### Cadena de causalidad real

```
~42-43 s tras entrar en partida:
  Servidor envia ClientWasKicked RPC, reason=1805386128 (0x6B9C0190)
    -> KickBypass lo suprime (OK, hook funciona)
      -> Servidor detecta cliente sin desconectarse del kick
        -> Servidor cierra conexion UDP (GameNetDriver IpNetDriver_2147482644)
          -> BroadcastNetworkFailure: ConnectionLost (93ms despues del RPC)
            -> LogGlobalStatus: Browse Started -> Frontend (match exit)
              -> LogFortPerformance end-of-zone report (analiticas, incluye NumLoadCustomizationFailed)
                -> CustomKeyMatchCommand_PlayerKick desregistrado (kick confirmado)
```

### Evidencia

Sesion v2.0.33, lineas 21867-21868 (OSLog 18:06:59.562):
```
[KickBypass] ClientWasKicked reason=1805386128 (0=None 1=Generic 2=Banned 3=Encrypt 4=CrossPlay 5=ClientId)
[KickBypass] suppressed reason=1805386128
```

Lineas 22009-22011 (OSLog 18:07:00.020, game time 17.06.59:655, 93ms despues):
```
LogNet: Error: UEngine::BroadcastNetworkFailure: FailureType = ConnectionLost,
ErrorString = Your connection to the host has been lost.,
Driver = Name:GameNetDriver Def:GameNetDriver IpNetDriver_2147482644
```

### Causa del reason=1805386128

Codigo desconocido fuera del rango documentado (0-5). Posibilidades:
- Reason code extendido de EAC para plataforma no autorizada
- Valor del enum EKickReason con entries no documentadas en sources publicos
- Lectura de wrong offset si la firma del RPC cambio en v43

### Por que KickBypass no es suficiente

KickBypass suprime el RPC `ClientWasKicked` correctamente. Pero el servidor tiene
un mecanismo de fallback: si el cliente no se desconecta tras el kick, el servidor
cierra la sesion de red forzosamente. La conexion UDP (IpNetDriver) se termina desde
el lado del servidor, generando `ConnectionLost` en el cliente. Este path no pasa por
`ClientWasKicked_Implementation` y KickBypass no lo ve.

### Estrategia de fix (v2.0.34)

Interceptar `BroadcastNetworkFailure` en el motor UE via vtable patch o hook de funcion.
Cuando `FailureType = ConnectionLost` y `Driver.Name = GameNetDriver` y el timestamp
esta dentro de ~500ms de un kick suprimido por KickBypass: suprimir el
`BroadcastNetworkFailure` y forzar reconexion al servidor de juego, o bien suprimir
la UI de error `_NetworkConnectionLost` para evitar el match exit.

Punto de entrada: `UEngine::BroadcastNetworkFailure` en el binario de Fortnite.
Requiere REA para localizar la funcion y patchear el vtable o insertar hook.

### Version de fix

v2.0.34 (Z bump: fix en network failure path).

### Estado

- [x] Causa raiz v1 (NumLoadCustomizationFailed) identificada como SINTOMA, no causa
- [x] ContentPatch (v2.0.33): HTTP 400 -> 200 en experience_br (parcialmente util,
      no resuelve el kick pero mejora assets de cosmetics)
- [x] Causa raiz real identificada: ConnectionLost tras ClientWasKicked suprimido
- [x] Reason code documentado: 1805386128 (0x6B9C0190), suprimido por KickBypass
- [x] BroadcastNetworkFailure localizado: RVA 0x5642c74, prologue 0xd10203ff
- [x] NetFailurePatcher implementado: runtime scan __DATA_CONST/__AUTH_CONST, supprime
      ConnectionLost dentro de 500ms de kick suprimido via g_last_kick_suppressed_ns
- [x] v2.0.34: scan vtable encuentra 0 entradas (funcion devirtualizada en este build)
- [x] v2.0.35: BL-caller patching como fallback; trampoline page via vm_allocate(VM_FLAGS_FIXED)
      cerca de base-0x2000000; patch_text_bl con vm_protect(R+W)->BL->clear_cache->vm_protect(R+X)
- [x] v2.0.35 compilada limpia (ARM64 dylib, simbolos verificados)
- [x] v2.1.0: NO interponer mmap via DYLD_INTERPOSE. El iOS SDK declara syscall() como
      retornando int (32 bits); mmap devuelve un puntero 64 bits. Interponerlo via syscall
      trunca la direccion de retorno -> crash en __malloc_init durante DYLD init (antes de
      que corra ningun codigo del juego). Verificado en crash report v2.1.0 (EXC_BAD_ACCESS
      KERN_INVALID_ADDRESS 0x14778000, stack: libSystem_initializer->__malloc_init).
      Solucion: solo interponer read/pread/close (todos retornan int o ssize_t, seguros).
- [x] v2.1.10: trigger_silent_lobby_return() CRASH: EXC_BAD_ACCESS en g_orig_kicked(stale_self, 0).
      El self guardado a t=0 tiene miembros internos destruidos a t=3s (objeto parcialmente
      desconstructed). reason=0 indexa tabla de func ptr nula -> ldr x0,[x0] con x0=0x0.
      Confirmado por LLDB: frame #2 kKickedFnOffset+40, crasheado por nuestro propio codigo.
      SOLUCION (v2.1.11): eliminar trigger_silent, dejar pasar UNO al cap (V2.1.9).
- [x] v2.1.11: sin allow-jit en entitlements (solo get-task-allow) + BNF devirtualizada
      -> parche en disco sigue siendo necesario para hooking BNF sin AMFI kill.
      No hay ruta pura en memoria: BNF no tiene vtable entries, vm_protect(COPY) en __TEXT
      crea paginas COW no firmadas -> AMFI SIGKILL.
      MEJORA (v2.1.11): deteccion de isla dinamica via scan del padding Mach-O (ADRP+LDR+CBZ+BR).
      Elimina kDiskIslandMagic, kPaddingIslandOff, kDataSlotOff hardcoded del dylib.
      Tras actualizacion de Epic: solo re-ejecutar patch_binary.py, sin recompilar el dylib.
- [x] v2.1.11 CRASH: EXC_BAD_ACCESS SIGKILL, Namespace CODESIGNING Code 2 "Invalid Page".
      Causa: dylib V2.1.4 viejo seguia cargado (LC_LOAD_DYLIB no actualizado porque deploy.sh
      no se ejecuto). V2.1.4 usaba vm_protect(VM_PROT_COPY) en __TEXT para escribir trampoline
      en RVA 0x5B9D630. La pagina 0x109dac000 se convirtio en COW (SM=COW r-x/rwx). AMFI mata
      el proceso con SIGKILL cuando GameThread intenta ejecutar desde esa pagina.
      REGLA: vm_protect(COPY) en __TEXT es AMFI-fatal incluso con get-task-allow. Solo safe en DATA.
      FIX (v2.1.12): eliminado el bloque __TEXT island fallback de NetFailurePatcher.cpp.
      El unico path valido es la isla de disco (patch_binary.py --apply via deploy.sh).
      deploy.sh ya aplica patch_binary.py automaticamente en el paso [0/5].
- [x] v2.1.12 CRASH SILENCIOSO: juego crashea a los ~30s sin IPS. Causa: island en 0x29bc
      sobrepone los ULTIMOS 4 bytes del area de load commands (header_end = 32+sizeofcmds =
      0x29c0). Cuando deploy.sh ejecuta install_name_tool -change para actualizar LC_LOAD_DYLIB,
      install_name_tool reescribe el binario y restaura los bytes originales de los load commands
      en 0x29bc-0x29bf, destruyendo el ADRP X16 de la isla (0xd05f0990 -> 0x0009c130).
      El BL sigue apuntando a la isla, pero la isla ya no carga la direccion correcta en X16.
      CBZ X16, +8 salta sobre el BR (X16 puede ser 0 o basura), la isla hace RET, BNF se
      ejecuta normalmente, ConnectionLost no se suprime, juego kickea a los ~30s. Sin IPS
      porque es un exit limpio (kick normal, no crash de CPU).
      FIX (v2.1.13): island movida a 0x29c0 (primer byte real de padding, despues del fin
      de load commands). ADRP identico (misma pagina 4KB). BL_PATCHES actualizados (+1 en
      imm26 ya que target avanzo 4 bytes). Migracion automatica: patch_binary.py detecta
      estado 'migrate' (BL sites apuntan a 0x29bc) y lo corrige en --apply.
      REGLA: ISLAND_FILE_OFF DEBE ser >= 32 + sizeofcmds. Verificar con:
        python3 -c "import struct; f=open(BIN,'rb'); f.seek(16); n,s=struct.unpack('<II',f.read(8)); print(hex(32+s))"
- [x] V2.1.24: BNF hook + KickBypass funcionan. ConnectionLost suprimido indefinidamente.
      Lobby return limpio a t=90s via ConnectionTimeout (Elapsed=90.00, Threshold=90.00).
      BeginSpectating con self ViewTarget dispara "Attempting to spectate self!" warning
      pero no crashea. Spectate mode no se activa. 90s freeze incomodo pero funcional.
- [x] V2.1.25 NCL SCREEN: flood-cap 25s deja pasar ConnectionLost a t=25s. Espectador no
      activo (BeginSpectating falla con self ViewTarget). ConnectionLost sin spectate =
      pantalla NCL "Network Connection Lost". ConnectionTimeout en cambio hace lobby limpio.
      REGLA: NO dejar pasar ConnectionLost si BeginSpectating no ha tenido exito. El flood-cap
      es incorrecto mientras el ViewTarget de BeginSpectating sea self (PlayerController).
- [x] V2.1.26: supresion indefinida restaurada. BNF type= nunca aparecio en log porque
      ConnectionTimeout bypasa nuestro hook (distinto BL site en UNetConnection::Tick).
      kConnectionTimeout=4 confirmado por inspeccion directa del bloque ENetworkFailure
      strings en el binario (orden: 3=ConnectionLost 4=ConnectionTimeout).
- [x] V23.7.6 BNF FLOOD INDEFINIDO: el servidor manda CL cada ~8ms sin limite de tiempo mientras el cliente
      no se desconecte. kKickWindowNs de 5s expiraba antes que el CT sintetico (25s). PID 80434: 3 eventos
      a +5007ms/+5015ms/+5024ms escaparon -> NCL dialog antes del CT sintetico.
      FIX: kKickWindowNs = 30s. Cubre todo el periodo hasta CT sintetico (25s) + 5s de margen.
      REGLA: kKickWindowNs debe ser > kSyntheticCtDelayS * 1000 (actualmente 25s -> minimo 25001ms).
- [x] V2.1.27: synthetic ConnectionTimeout via dispatch_after(25s, main_queue). VERIFICADO
      2026-11-10: "[NetFailurePatch] synthetic ConnectionTimeout firing (25s early)" aparece
      a exactamente dk=25s. Lobby return limpio sin NCL screen. EXITO.
- [x] V2.2.0: vtable patch de RejoinViaSessionInternal instalado y verificado en startup.
      CONFIRMADO 2026-11-10: "[Reconnect] RejoinViaSessionInternal called" NUNCA aparece.
      El path ConnectionTimeout -> ReturningToFrontEnd es directo al lobby y NO pasa por
      RejoinViaSessionInternal. El vtable hook existe pero no tiene trigger.
      SIGUIENTE PASO: llamar RejoinViaSessionInternal explicitamente desde kick_bypass_stub.
      Requiere encontrar UFortRejoinCheck* desde AFortPlayerControllerAthena (self en kick).
      Buscar con REA: miembro RejoinCheck en PlayerController, offset desde self.
      Alternativa: buscar GEngine->GameInstance->RejoinCheck si no es miembro directo.
- [x] V2.6.x: RejoinViaSessionInternal INCALLABLE tras reason=144 kick.
      CONFIRMADO 2026-11-10 con probe vm_read_overwrite en V2.6.4:
      La cadena [base+0xc25a468] -> slot1 -> slot2 -> [slot2+0xd68] da KERN_INVALID_ADDRESS
      (kr=1) al leer slot2+0xd68. El EOS session object (slot2) fue liberado por los hilos
      del EOS SDK ANTES de que ClientWasKicked_Implementation se ejecute en el game thread.
      Cualquier llamada a g_orig_rejoin(obj) crashea en RejoinViaSessionInternal+0x3c
      (LDRB W8,[X8,#0xd68]; CMP W8,#5) con acceso a memoria no mapeada -> RequestExit(false).
      V2.6.4 detecta kr=1 y salta la llamada. El freeze de 25s (V2.1.27) sigue activo.
      CONCLUSION: el path RejoinViaSessionInternal no es viable para reconexion post-kick.
      Alternativa: hook mas temprano (antes del teardown EOS) o reconexion desde cero.
