# Configuracion

FnMacCompatLayer carga su configuracion en orden de precedencia (el ultimo gana):

1. `<directorio_dylib>/FnDiag.conf`
2. `$HOME/Documents/FnDiag.conf`
3. Variables de entorno `FNDIAG_*`

## Formato del fichero de configuracion

```
# comentario
clave=valor
```

Valores booleanos: `1`, `true`, `on` / `0`, `false`, `off` (insensible a mayusculas).

## Flags

| Clave            | Env var                    | Tipo    | Por defecto | Descripcion |
|------------------|----------------------------|---------|-------------|-------------|
| foreground       | FNDIAG_FOREGROUND          | bool    | false       | Sustituye background sessions por ephemeral (en proceso) |
| isolate_sessions | FNDIAG_ISOLATE_SESSIONS    | bool    | false       | Anade UUID del container al identificador de sesion background |
| create_dirs      | FNDIAG_CREATE_DIRS         | bool    | false       | Crea directorios padre de destino en movimientos de fichero |
| relative_paths   | FNDIAG_RELATIVE_PATHS      | bool    | false       | Convierte rutas absolutas de FBackgroundNSURLSession a relativas |
| patch_status     | FNDIAG_PATCH_STATUS        | bool    | false       | Parchea codigo HTTP 201 -> 200 en GetDownloadResult |
| verbose          | FNDIAG_VERBOSE             | bool    | false       | Log detallado de todas las descargas NSURLSession |
| trace_files      | FNDIAG_TRACE_FILES         | bool    | false       | Traza operaciones de fichero (stat, open, move, copy) en BackgroundHttp |
| probe_input      | FNDIAG_PROBE_INPUT         | bool    | false       | Detecta teclado/raton/mandos al inicio y en conexion/desconexion |
| input_ini        | FNDIAG_INPUT_INI           | bool    | false       | Escribe Input.ini con configuracion de raton para Fortnite |
| native_kbm       | FNDIAG_NATIVE_KBM          | bool    | false       | Escanea __TEXT/__text buscando el predicado KBM del motor |
| unlock_fps       | FNDIAG_UNLOCK_FPS          | bool    | false       | Fuerza la tasa de frames al valor de fps_target |
| fps_target       | FNDIAG_FPS_TARGET          | int     | 60          | FPS objetivo para unlock_fps (rango: 30-240) |
| mirror_log       | FNDIAG_MIRROR_LOG          | bool    | false       | Espeja FortniteGame.log en FnDiag.log con filtrado de eventos clave |
| autoupdate       | FNDIAG_AUTOUPDATE          | bool    | false       | Comprueba y descarga actualizaciones desde GitHub Releases |

## Ejemplo de configuracion para desarrollo

```
# FnDiag.conf — entorno de desarrollo
verbose=true
trace_files=true
probe_input=true
create_dirs=true
relative_paths=true
patch_status=true
mirror_log=true
unlock_fps=true
fps_target=120
```

## Ejemplo de configuracion para uso normal

```
# FnDiag.conf — uso en produccion
relative_paths=true
patch_status=true
create_dirs=true
```

## Canales de build y flags de compilacion

| Canal  | CHANNEL=  | Optimizacion | PRODUCTION | Salida          |
|--------|-----------|--------------|------------|-----------------|
| dev    | dev       | -O0          | no         | builds/dev/     |
| beta   | beta      | -O2          | no         | builds/beta/    |
| public | public    | -O2          | si         | builds/public/  |

Con `PRODUCTION` definido:
- Logger silencia LOG_D y LOG_I (solo LOG_W y LOG_E activos)
- dumpPayload en EacHooks no compila
- og_installNetHooks (CFURLRequest hook) no compila
- hookFileManager en EacHooks no hace nada
- DebugCanvas en Core.mm no compila
