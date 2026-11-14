# Configuration

FnMacUpdateFix loads its configuration in precedence order (last wins):

1. `<dylib_directory>/FnDiag.conf`
2. `$HOME/Documents/FnDiag.conf`
3. Environment variables `FNDIAG_*`

## Config file format

```
# comment
key=value
```

Boolean values: `1`, `true`, `on` / `0`, `false`, `off` (case-insensitive).

## Flags

| Key              | Env var                    | Type    | Default | Description |
|------------------|----------------------------|---------|---------|-------------|
| foreground       | FNDIAG_FOREGROUND          | bool    | false   | Replace background sessions with ephemeral (in-process) |
| isolate_sessions | FNDIAG_ISOLATE_SESSIONS    | bool    | false   | Append container UUID to background session identifier |
| create_dirs      | FNDIAG_CREATE_DIRS         | bool    | false   | Create parent directories on file move operations |
| relative_paths   | FNDIAG_RELATIVE_PATHS      | bool    | false   | Convert FBackgroundNSURLSession absolute paths to relative |
| patch_status     | FNDIAG_PATCH_STATUS        | bool    | false   | Patch HTTP 201 -> 200 in GetDownloadResult |
| verbose          | FNDIAG_VERBOSE             | bool    | false   | Detailed log of all NSURLSession downloads |
| trace_files      | FNDIAG_TRACE_FILES         | bool    | false   | Trace file operations (stat, open, move, copy) in BackgroundHttp |
| probe_input      | FNDIAG_PROBE_INPUT         | bool    | false   | Detect keyboard/mouse/gamepads at startup and on connect/disconnect |
| input_ini        | FNDIAG_INPUT_INI           | bool    | false   | Write Input.ini with mouse configuration for Fortnite |
| native_kbm       | FNDIAG_NATIVE_KBM          | bool    | false   | Scan __TEXT/__text for the engine KBM predicate |
| unlock_fps       | FNDIAG_UNLOCK_FPS          | bool    | false   | Force frame rate to fps_target value |
| fps_target       | FNDIAG_FPS_TARGET          | int     | 60      | Target FPS for unlock_fps (range: 30-240) |
| mirror_log       | FNDIAG_MIRROR_LOG          | bool    | false   | Mirror FortniteGame.log to FnDiag.log with key event filtering |
| autoupdate       | FNDIAG_AUTOUPDATE          | bool    | false   | Check and download updates from GitHub Releases |

## Development config example

```
# FnDiag.conf -- development
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

## Normal use config example

```
# FnDiag.conf -- production
relative_paths=true
patch_status=true
create_dirs=true
```

## Build channels and compile flags

| Channel | CHANNEL= | Optimization | PRODUCTION | Output         |
|---------|----------|--------------|------------|----------------|
| dev     | dev      | -O0          | no         | builds/dev/    |
| beta    | beta     | -O2          | no         | builds/beta/   |
| rc      | rc       | -O3          | yes        | builds/rc/     |
| public  | public   | -O3          | yes        | builds/public/ |

With `PRODUCTION` defined:
- Logger silences LOG_D and LOG_I (only LOG_W and LOG_E active)
- dumpPayload in EacHooks does not compile
- og_installNetHooks (CFURLRequest hook) does not compile
