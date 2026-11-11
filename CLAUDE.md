# CLAUDE.md - Instrucciones operativas para este repo

## Compilacion

Build de desarrollo (con diagnosticos):
```bash
cd /Users/alexg/Documents/Dev/Fortnite/FnMac/FnMacUpdateFix
make DEV=1
# salida: builds/dev/FnMacKickFix-V<version>-dev.dylib
```

Build de produccion:
```bash
make PRODUCTION=1
```

Limpiar y recompilar:
```bash
make clean && make DEV=1
```

Resign y deploy (scripts no trackeados):
```bash
bash tools/resign.sh   # firma ad-hoc la dylib
bash tools/deploy.sh   # copia y reinicia Fortnite con DYLD_INSERT_LIBRARIES
```

## Verificar build

```bash
# Comprobar que los simbolos de hook estan presentes
nm -g builds/dev/FnMacKickFix-V*.dylib | grep -E "hook_|install_|my_"

# Comprobar seccion __interpose (DYLD_INTERPOSE de EosHooks)
otool -s __DATA __interpose builds/dev/FnMacKickFix-V*.dylib

# Comprobar arquitectura ARM64
file builds/dev/FnMacKickFix-V*.dylib
```

## Versionado (X.Y.Z)

- X: cambio breaking (reestructura de hooks, ABI roto)
- Y: nueva feature (hook nuevo, nuevo subsistema)
- Z: bugfix / ajuste de comportamiento existente

Proxima: pendiente test en partida con V2.6.8 (EOS state probe, scan UFortRejoinCheck, rejoin en diagnostic mode).

Actual en VERSION: `2.6.8`

## Log de diagnostico

El log vive en (UUID puede cambiar si se reinstala via Sideloadly):
`~/Library/Containers/0F16E856-1C80-4448-9C65-ED3A8E8DA5E9/Data/Documents/FnDiag.log`

Si cambia el UUID, encontrarlo con:
```bash
lsof -p $(pgrep FortniteClient | head -1) 2>/dev/null | grep FnDiag.log | awk '{print $NF}'
```

Seguimiento en tiempo real:
```bash
tail -f ~/Library/Containers/0F16E856-1C80-4448-9C65-ED3A8E8DA5E9/Data/Documents/FnDiag.log | grep -E "NetFailurePatch|KickBypass|KickPatch|BNF|slot|armed"
```

Subsistema OSLog (NetHook, EAC-Auth): `com.alexgrdev.fnmackickfix`.

Filtrar en tiempo real:
```bash
log stream --predicate 'subsystem == "com.alexgrdev.fnmackickfix"' --level debug
```

Leer log de sesion actual:
```bash
log show --predicate 'subsystem == "com.alexgrdev.fnmackickfix"' \
  --start "2026-11-08 17:34:00" --end "2026-11-08 17:37:00" --style compact
```

## Puntos de ruptura LLDB criticos

Adjuntar al proceso Fortnite (PID variable):
```bash
lldb -p $(pgrep FortniteClient-IOS)
```

Breakpoints utiles:
```
# Trigger de performance que causa el kick
(lldb) rb LogFortPerformance.*NumLoadCustomizationFailed

# Entrada/salida de ClientWasKicked (cubre reasons 1/3/5 ya parcheados)
(lldb) b ClientWasKicked_Implementation

# Respuesta HTTP para diagnosticar el 400 en experience_br
(lldb) b -[NSURLSessionTask _didFinishWithResponse:data:error:]
```

Dump de memoria en la region de vtable parchada:
```bash
(lldb) x/32xg 0x1089f8f18   # orig vtable, ajustar con ASLR slide
```

## Offsets v2.0.32 (slide 0x46c000, base 0x10046c000)

| Simbolo | Offset desde base | Notas |
|---|---|---|
| KickBypass vtable | 0x1089f8f18 (orig) | 18 entradas parchadas |
| KickBypass stub | 0x113da5720 | Reemplaza las 18 entradas |
| NmtPatch chain | 0x10c73ff10 | seg __DATA_CONST |

Recalcular con slide actual:
```bash
# Leer slide del log de inicio (linea ~47):
# [KickBypass] vtable patch: 18/18 entries patched slide=0x46c000
```

## Archivos clave

| Archivo | Proposito |
|---|---|
| `src/Core.mm` | Constructor dylib, orden de instalacion de hooks |
| `src/update/NetworkHooks.mm` | NSURLSession hooks, verify/event injection |
| `src/eos/EosHooks.cpp` | DYLD_INTERPOSE sobre EOSSDK, GetSystemRequirementStatus |
| `include/update/KickPatcher.hpp` | Vtable patcher para ClientWasKicked |
| `include/update/NmtPatcher.hpp` | Chain patcher para NMT en __DATA_CONST |
| `include/network/EacHooks.hpp` | EAC auth header logging |
| `src/core/GameLogMirror.cpp` | Espejo de LogGameLog |
| `src/metadata/DeviceSpoof.mm` | iPad14,3 / iOS 17.5 User-Agent spoof |

## Reglas de edicion

- Cambio parcial = Edit (lineas concretas). Write completo solo para archivos nuevos.
- No usar Write para sobrescribir un archivo existente si solo cambia una funcion.
- Un error en PITFALLS.md a la vez. No marcar resuelto sin sesion de juego verificada.
