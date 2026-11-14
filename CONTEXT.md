# FnMacUpdateFix - Contexto del proyecto

## Descripcion

Dylib inyectada via `DYLD_INSERT_LIBRARIES` en `FortniteClient-IOS-Shipping` (ARM64 Catalyst)
que permite ejecutar Fortnite iOS en macOS. Version activa: **V23.8.0**.

Target: `FortniteClient-IOS-Shipping`, ASLR slide `0x46c000`, base `0x10046c000`.

## Arquitectura de hooks

### KickBypass (`include/update/KickPatcher.hpp`)
- Parchea 18 entradas del vtable en `__DATA_CONST` apuntando a `ClientWasKicked_Implementation`
- El stub suprime reasons 1/3/5 (GenericKick / EncryptionRequired / ClientIdRestriction = ValidationFailed / EAC)
- Solo pasa a la implementacion original los reasons 2/4 (WasBanned / CrossPlayRestriction)
- v2.0.32: 18/18 entries patched, slide=0x46c000, orig=0x1089f8f18, stub=0x113da5720
- **NO cubre**: client-side performance exits (LogFortPerformance triggers)

### NmtPatch (`include/update/NmtPatcher.hpp`)
- Chain-patch en `__DATA_CONST` a offset `0x10c73ff10` (seg __DATA_CONST)
- Deshabilita la comprobacion de plataforma/netmode que rechazaria el cliente macOS
- v2.0.32: chain_patched=1, segs=1, virt_patched=0

### EosHooks (`src/eos/EosHooks.cpp`)
- DYLD_INTERPOSE sobre simbolos C exportados de EOSSDK.framework
- `EOS_AntiCheatClient_BeginSession`: logging de sesion EAC
- `EOS_AntiCheatClient_GetSystemRequirementStatus`: fuerza retorno 0/0 (EOS_Success) para que macOS no sea rechazado como plataforma no soportada
- `EOS_AntiCheatClient_PollStatus`: logging de violaciones EAC

### OtaUpdater (`src/update/OtaUpdater.mm`)
- Sesion efimera dedicada (ephemeralSessionConfiguration), NUNCA sharedSession
- Gateado por `config().autoupdate` (default false): sin flag, no hace red
- Solo descarga desde `github.com` / `*.githubusercontent.com` (HTTPS forzado)
- Verifica SHA-256 de la dylib descargada antes de aplicar
- Deja el update en `$HOME/Documents/FnMacBypass-update.dylib` para aplicar con deploy.sh

### GameUpdater (`src/update/GameUpdater.mm`)
- Sin red. Lee `CFBundleVersion` del bundle principal al arranque
- Compara contra builds soportados: 59596594 (43.00), 60278837 (43.10)
- Registra en log si el build activo esta soportado o es desconocido

### EacHooks (`include/network/EacHooks.hpp`)
- Logging de CLIENT HEADERs salientes (Content-Length, User-Agent, Transfer-Encoding)
- Intercepta headers EOS SDK para diagnostico de auth

### NetHook (subsistema `:main`)
- `[NetHook] didReceiveData`: log de chunks recibidos
- `[NetHook] didComplete`: log de HTTP status + error para toda NSURLSession

### DeviceSpoof (`src/metadata/DeviceSpoof.mm`)
- User-Agent: `Fortnite/43.00.0 (iPad14,3; iPhone OS 17.5; Scale/3.00)`
- Impersonates iPad14,3 para que los endpoints iOS acepten las requests

### TerrainPatcher (`include/update/TerrainPatcher.hpp`)
- Ucas terrain patch; ruido rutinario de stale ucas ignorado en analisis

### InputHooks
- FPS unlock, input.ini override, native KBM support

### GameLogMirror (`src/core/GameLogMirror.cpp`)
- Espeja `LogGameLog` al subsistema `com.alexgrdev.fnmackickfix:diag`

## Subsistemas de log

- `:diag` - eventos del motor UE (GameLog, Ctx/disparadores)
- `:main` - hooks de red (NetHook, EAC-Auth, EOS)

## Endpoints criticos

| Endpoint | Metodo | Status en v2.0.32 | Impacto |
|---|---|---|---|
| `account/.../linkIdentity` | GET | HTTP 429 (startup) | Rate limit; EOS session continua |
| `cooked-content-package/link/experience_br?platform=ios&major=43` | GET | HTTP 400 | Falla de contenido BR; causa NumLoadCustomizationFailed |
| `datarouter/.../eteventstream` | POST | HTTP 204 | OK |
| `fn-service-habanero.../trackprogress` | GET | HTTP 200 | OK |

## Cuentas/identidades

- `account_id`: `163f1e4f35414184b415f93411ac93a0`
- `device_id`: `E9B20D9D-8BB4-539F-9576-C0486180056C`
- `deployment_id`: `62a9473a2dca46b29ccf17577fcf42d7`
- EOS SDK: v1.19.4300.0-59053925@Fortnite
- Fortnite version: 43.00.0 / CL-59596594
