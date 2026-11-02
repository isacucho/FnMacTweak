# Pitfalls conocidos

## POSIX recursion (crash critico)

**Sintoma:** SIGABRT / stack overflow al usar stat/access/open despues de cargar la dylib.

**Causa:** `dlsym(RTLD_NEXT, "stat")` devuelve el simbolo ya interpuesto por
`__DATA,__interpose`, no el original del sistema. La funcion interpuesta llama
a dlsym(RTLD_NEXT, "stat") -> se llama a si misma -> recursion infinita.

**Solucion:** Usar `syscall(SYS_stat64, ...)` directamente en las funciones interposadas.
El kernel no pasa por la tabla de interposicion de dyld.
Implementado en src/update/FileHooks.cpp (funciones `raw_stat`, `raw_lstat`, etc.).

**Nunca hacer:**
```cpp
// MAL: dlsym(RTLD_NEXT) devuelve el hook ya instalado
static auto orig_stat = (int(*)(const char*, struct stat*))dlsym(RTLD_NEXT, "stat");
int my_stat(const char* p, struct stat* st) {
    return orig_stat(p, st);  // -> llama a my_stat -> stack overflow
}
```

**Correcto:**
```cpp
inline int raw_stat(const char* p, struct stat* st) {
    return (int)syscall(SYS_stat64, p, st);
}
```

## Doble hook en fileExistsAtPath (orden obligatorio)

`fileExistsAtPath:` esta hookeado por dos modulos:
- Metadata (DeviceSpoof.mm): oculta rutas JB
- Update (FileHooks.cpp): traza accesos BackgroundHttp

Metadata DEBE instalarse antes que Update para que la cadena sea:
`Metadata -> Update -> original`

Si Update se instala primero, la cadena inversa hace que trace vea antes las rutas JB
que se intentan ocultar, filtrando informacion que no debe aparecer en logs.

## Doble hook en setHTTPBody

`setHTTPBody:` esta hookeado por dos modulos:
- EacHooks.mm: log de payload EAC (verify/, matchmaking, oauth/token)
- EacHooks.mm og_installNetHooks: log CFURLRequestSetHTTPRequestBody (CFNetwork, solo dev)

Ambos hooks son del mismo modulo (Network) y hacen cosas distintas. La cadena
es intencional y no produce crashes.

## ARC en bloques de Objective-C con capturas

Los bloques en ObjcUtil.cpp (wrap_method) capturan `orig` (IMP) y `s` (SEL) por valor.
No capturan objetos ObjC -> no hay retain cycles.

En EacHooks.mm, los bloques de hookReceiveData capturan `gVerifyMatchData` por
referencia via `gVerifyQueue` (dispatch_sync). gVerifyMatchData es un NSString* static.
Riesgo de retain cycle es bajo porque los bloques son de corta vida y se ejecutan en
el queue serie dedicado.

## MSHookFunction no disponible

Si Substrate / ElleKit no esta presente, `MSHookFunction` sera NULL y los hooks de
hardware spoof (sysctlbyname, sysctl, uname, etc.) no se instalaran.
El codigo lo maneja: comprueba `if (MSHookFunction)` antes de instalar.
Los hooks ObjC (swizzle) no dependen de MSHookFunction y siempre se instalan.

## getenv("HOME") puede ser nil

En contextos de inyeccion, `getenv("HOME")` puede devolver NULL si el proceso no
tiene el entorno completo. Core.mm y EngineHooks.mm hacen fallback a
`[NSHomeDirectory() UTF8String]`. Siempre usar el patron:
```cpp
const char* home = getenv("HOME");
std::string container = home ? home : [NSHomeDirectory() UTF8String];
```

## CFStringRef y const_cast en SessionOverride

`hook_background_config` crea un `CFStringRef` con `CFStringCreateWithCString` y lo
convierte a `id` via `reinterpret_cast<id>(const_cast<__CFString*>(str))`. Esto es
correcto en Objective-C donde `NSString*` y `CFStringRef` son toll-free bridged.
`CFRelease(str)` se llama despues del uso para no filtrar memoria.

## FBackgroundNSURLSession puede no existir

Si el binario de Fortnite cambia de version, `objc_getClass("FBackgroundNSURLSession")`
puede devolver nil. install_engine_hooks() lo comprueba y logea un aviso sin crashear.

## Makefile: -Wl,-undefined,dynamic_lookup

MSHookFunction/Substrate puede no estar presente en tiempo de enlace. Sin este flag,
el enlazador fallaria al no encontrar el simbolo. Con el flag, la resolucion se difiere
a tiempo de carga. Si el simbolo tampoco esta en tiempo de carga, MSHookFunction = NULL
y el codigo lo maneja (ver "MSHookFunction no disponible" mas arriba).

## Makefile: -Wl,-w

El juego tiene clases ObjC que el enlazador ve como "no registradas" al linkear la dylib.
Este flag suprime esas advertencias del enlazador que no afectan al funcionamiento.
