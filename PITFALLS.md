# PITFALLS - Errores activos

Regla estricta: un error a la vez. No avanzar al siguiente hasta resolver y verificar el actual.

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
- [ ] Verificar en sesion de juego: log "[NetFailurePatch] BL patched 0x... -> tramp 0x..." (x8) al inicio,
      "[NetFailurePatch] ConnectionLost suppressed" a los ~42s
