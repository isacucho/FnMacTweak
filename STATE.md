# Estado del proyecto

## Cerrado: V23.8.1 — build 60278837 (Fortnite 43.10)

Proyecto cerrado 2026-11-15. Build estable y probado sobre Mac16,8 (M4 Pro), macOS 27.3.

### Parches activos confirmados

| Modulo | Estado |
|---|---|
| DeviceSpoof | OK — spoof iOS device + bundle + JB env, unsetenv DYLD vars |
| EosHooks | OK — 8/8 symbols DYLD_INTERPOSE (GetSystemRequirementStatus forzado a 0) |
| CompatReport | OK — vtable swap unico, type=10 y flag=1 suprimidos |
| KickBypass | OK — 18/18 entradas vtable ClientWasKicked parchadas (43.10) |
| NmtPatcher | OK — chain-patch en __DATA_CONST |
| ContentPatch | OK — session swizzle para suprimir CL |
| CustomizationPatcher | OK |
| StatusCodeFix | OK — 201->200 FBackgroundNSURLSession |
| OsLogInterceptor | OK |
| EngineHooks | OK |

### Eliminados en V23.8.1

- `ValidationPatch`: redundante, CompatReport ya cubre type=10 y flag=1.
  Parchaba la misma funcion vtable que CompatReport, rompiendo el handshake EAC.
- `EacHooks.mm` / `MkwBypass.cpp`: no referenciados en el build.
- `IAdapter.hpp` / `DebugCanvas.hpp`: interfaces sin implementacion activa.
- Codigo 43.00 (build 59596594) de KickBypass: version no soportada.
- `tools/`: scripts lldb/deploy/resign sin mantenimiento.

### Regla de arquitectura

ZERO disk patching: el binario del juego en disco no se toca ni modifica jamas.
Solo vtable swaps en __DATA_CONST via vm_protect(RW) en paginas 16KB.

### Log de diagnostico

```bash
tail -f ~/Library/Containers/0F16E856-1C80-4448-9C65-ED3A8E8DA5E9/Data/Documents/FnDiag.log
```
