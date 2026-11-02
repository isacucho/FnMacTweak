# Arquitectura de FnMacCompatLayer

FnMacCompatLayer es una dylib de inyeccion para ejecutar el binario iOS de Fortnite
sobre macOS arm64. Se inyecta via `DYLD_INSERT_LIBRARIES` y no requiere jailbreak ni
modificacion del binario del juego.

## Modulos

```
Core        src/core/           Config, DiagLog, GameLogMirror, Logger, SimulatorContext
Hooks       src/hooks/          ObjcUtil: swizzle, replace_*_method, wrap_method
Metadata    src/metadata/       DeviceSpoof: spoof hardware/bundle, JB hide, SSL bypass
Network     src/network/        EacHooks: delegados NSURLSession, EAC TX/RX, CFURLRequest
Update      src/update/         FileHooks, NetworkHooks, SessionOverride, EngineHooks, Updater
Input       src/input/          FpsUnlock, InputIni, InputProbe, NativeKbm
Adapters    include/adapters/   IAdapter.hpp: interfaz para futuros adaptadores por version
```

## Orden de inicializacion (Core.mm: fncompat_init)

El orden importa porque los hooks encadenan. Cambiar el orden puede romper la cadena.

```
1. Core::emulateiOSDirectories   crea arbol de directorios estilo iOS bajo $HOME
2. Core::log_init                abre FnDiag.log para escritura
3. Metadata::installSpoofHooks   PRIMERO: instala el hook externo de fileExistsAtPath
4. Update::install_input_ini     escribe Input.ini si cfg.input_ini
5. Update::install_file_hooks    instala el hook interno de fileExistsAtPath + POSIX interpose
6. Update::install_network_hooks engancha +[NSURLSession sessionWithConfiguration:...]
7. Update::install_engine_hooks  parchea FBackgroundNSURLSession (201->200, rutas relativas)
8. Update::install_session_override engancha backgroundSessionConfigurationWithIdentifier:
9. Network::installNetHooks      EAC + og_installNetHooks (CFURLRequest, solo dev)
10. Input::install_fps_hooks     CADisplayLink, MTKView, UIScreen
11. Input::install_input_probe   GameController notificaciones
12. Input::install_native_kbm    scan ARM64 en __TEXT/__text
13. Core::start_game_log_mirror  hilo background (si cfg.mirror_log)
14. Core::Updater::checkForUpdates async background (si cfg.autoupdate)
```

### Por que Metadata antes de Update

`fileExistsAtPath:` tiene dos hooks:
- Metadata (exterior): oculta rutas de jailbreak (Cydia, MobileSubstrate, /var/jb, ...)
- Update (interior): traza accesos a BackgroundHttp (solo si cfg.trace_files)

Cadena resultante: `Metadata hook -> Update hook -> original`

Si se invierte el orden de instalacion, la cadena seria `Update -> Metadata -> original`,
lo que hace que el trace de Update vea antes las rutas JB que Metadata intenta ocultar.

## Dependencias entre modulos

```
Core       <- ninguno
Hooks      <- Core (Logger, DiagLog)
Metadata   <- Core, Hooks
Network    <- Core, Hooks
Update     <- Core, Hooks
Input      <- Core, Hooks
Adapters   <- ninguno (interfaz pura)
```

No hay dependencias circulares. El caso historico (Metadata -> Network via og_installNetHooks)
se resolvio moviendo og_installNetHooks a Network/EacHooks.mm. Core orquesta ambos
modulos independientemente.

## ARC vs MRC

Todos los .mm compilan con `-fobjc-arc`. Los .cpp compilan como C++ puro sin ARC.

KickFix original compilaba sin ARC pero su codigo era ARC-compatible (uso de
@autoreleasepool, bloques, sin retain/release manual). Se selecciono ARC para unificar.

## MSHookFunction

DeviceSpoof.mm y EacHooks.mm cargan MSHookFunction de forma independiente via dlsym.
No hay utilidad compartida intencionalmente: si uno falla, el otro sigue funcionando.
El overhead de doble dlopen en init es despreciable.

## POSIX interpose vs dlsym(RTLD_NEXT)

FileHooks.cpp interpone stat/lstat/access/open/unlink/rename via `__DATA,__interpose`.
Las implementaciones interposadas NO usan `dlsym(RTLD_NEXT)` sino `syscall()` directo.
Ver docs/pitfalls.md seccion "POSIX recursion".

La seccion `__DATA,__interpose` aplica al codigo C++ del motor pero NO al codigo de
esta misma dylib (dyld excluye a la dylib de su propia interposicion).

## Doble hook en moveItemAtURL

`moveItemAtURL:toURL:error:` tiene dos hooks:
- FileHooks.cpp: crea directorios padre (cfg.create_dirs) + traza (cfg.trace_files)
- EacHooks.mm: log incondicional de movimientos BackgroundHttp en dev

Cadena: EacHooks -> FileHooks -> original (EacHooks se instala despues en Core.mm).
Los dos hooks hacen cosas distintas y no se interfieren.

## EngineHooks: parche 201 -> 200

`FBackgroundNSURLSession::GetDownloadResult` devuelve codigo 201 cuando el fichero
temporal esta completo pero el motor lo interpreta como error. El parche (cfg.patch_status):
- Comprueba que el fichero temporal existe y tiene tamano > 0
- Cambia outCode de 201 a 200 solo en ese caso

`FBackgroundNSURLSession::GetDownloadResult` tambien devuelve rutas absolutas del
fichero temporal. El motor antepone su propia base (Documents/), por lo que la ruta
absoluta no se encuentra. El parche (cfg.relative_paths) la convierte en relativa
eliminando el prefijo `$HOME/Documents/`.

## SessionOverride: aislamiento de sesiones background

Dos modos de operacion para `backgroundSessionConfigurationWithIdentifier:`:
- `cfg.foreground_sessions = true`: devuelve `ephemeralSessionConfiguration` (en proceso,
  mas fiable en macOS pero pierde persistencia de descarga)
- `cfg.isolate_sessions = true`: anade el UUID del container al identificador para evitar
  colisiones entre instancias del juego

## Testabilidad

Cada modulo expone una funcion de instalacion (`install_*`) sin dependencias globales
externas. Para tests unitarios del modulo Network de forma aislada:
1. Usar `replace_*_method` / `wrap_method` de ObjcUtil con implementaciones stub
2. Inyectar un `Config` personalizado (Config::load() se puede sustituir con env vars:
   `FNDIAG_*` tienen precedencia sobre el fichero de configuracion)
3. Compilar solo el modulo objetivo + Core (Config, DiagLog) sin el resto

El patron `IAdapter` en include/adapters/IAdapter.hpp es el punto de extension para
mocks de version-especificos: implementar `install()` con stubs en lugar de hooks reales.

## Patron Adapter

`IAdapter` define el contrato para adaptadores por version del binario de Fortnite.
Anadir un nuevo adaptador requiere:
1. Crear `src/adapters/FnAdapter_XX.mm` que implemente `IAdapter`
2. Registrarlo en Core.mm si su version coincide

No se rompe la compilacion del resto porque `IAdapter` es una interfaz pura sin
implementacion. Las versiones existentes no necesitan cambiar.
