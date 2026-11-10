# PITFALLS - Errores activos

Regla estricta: un error a la vez. No avanzar al siguiente hasta resolver y verificar el actual.

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
