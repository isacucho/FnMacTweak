# FnMacUpdateFix architecture

Dylib injected via `DYLD_INSERT_LIBRARIES` into `FortniteClient-IOS-Shipping` (ARM64 Catalyst)
to run Fortnite iOS on macOS Apple Silicon. Does not require jailbreak or modification of
the game binary on disk.

## Modules

```
Core        src/core/           Config, DiagLog, GameLogMirror, OsLogInterceptor, LogSpoofer
Hooks       src/hooks/          ObjcUtil: swizzle, replace_*_method, wrap_method
Metadata    src/metadata/       DeviceSpoof: spoof hardware/bundle, JB hide, env cleanup
EOS         src/eos/            EosHooks (DYLD_INTERPOSE), CompatReport (vtable fingerprint)
Update      src/update/         KickPatcher, NmtPatcher, ContentPatch, EngineHooks,
                                CustomizationPatcher, FileHooks, TerrainPatcher,
                                OtaUpdater, GameUpdater
Input       src/input/          FpsUnlock, InputIni, InputProbe, NativeKbm
Network     src/network/        StatusCodeFix, NetInspect
```

## Initialization order (Core.mm: fncompat_init)

Order matters because hooks chain. Changing the order can break the chain.

```
1. log_init                  opens FnDiag.log for writing
2. install_oslog_interceptor mirrors OSLog to FnDiag.log
3. installSpoofHooks         FIRST: installs external fileExistsAtPath hook + env cleanup
4. install_eos_hooks         DYLD_INTERPOSE over EOSSDK symbols
5. install_engine_hooks      patches FBackgroundNSURLSession (201->200, relative paths)
6. install_content_patch     session swizzle to suppress CL
7. install_customization_patch patches NumLoadCustomizationFailed path
8. install_status_code_fix   201->200 in FBackgroundNSURLSession
9. install_compat_report     vtable fingerprint scan, type=10 and flag=1 suppressed
```

Note: `install_kick_bypass()` and `install_nmt_patch()` are defined but not currently called
from Core.mm. They require a 3s GCD delay to avoid interfering with EAC registration.

## Module dependencies

```
Core       <- none
Hooks      <- Core (DiagLog)
Metadata   <- Core, Hooks
EOS        <- Core
Update     <- Core, Hooks
Input      <- Core, Hooks
Network    <- Core, Hooks
```

No circular dependencies.

## ARC vs MRC

All .mm files compile with `-fobjc-arc`. .cpp files compile as plain C++ without ARC.

## DYLD_INTERPOSE vs MSHookFunction

EosHooks.cpp uses `__DATA,__interpose` section (DYLD_INTERPOSE) for exported C symbols of EOSSDK.
DeviceSpoof.mm uses MSHookFunction via dlsym for ObjC method hooks.

DYLD_INTERPOSE applies to code loaded after the dylib but NOT to the dylib itself.

## vtable patching via vm_protect

KickBypass and CompatReport patch vtable entries in `__DATA_CONST`:
1. `vm_protect(mach_task_self(), page, 0x4000, false, VM_PROT_READ|VM_PROT_WRITE)` (page = 16KB aligned)
2. Write new function pointer
3. `dmb ish` memory barrier
4. `vm_protect(mach_task_self(), page, 0x4000, false, VM_PROT_READ)` restore

AMFI allows vm_protect on __DATA_CONST without restriction.
vm_protect(VM_PROT_COPY) on __TEXT of the main executable is AMFI-fatal (SIGKILL, Namespace CODESIGNING Code 2).

## EngineHooks: 201 -> 200 patch

`FBackgroundNSURLSession::GetDownloadResult` returns code 201 when the temp file is complete
but the engine treats it as an error. The patch (cfg.patch_status):
- Checks that the temp file exists and has size > 0
- Changes outCode from 201 to 200 only in that case

The function also returns absolute paths for the temp file. The engine prepends its own base
(Documents/), so the absolute path is not found. The patch (cfg.relative_paths) converts it
to a relative path by stripping the `$HOME/Documents/` prefix.

## Obfuscation (rc/public builds)

- `-O3`: full optimization, dead code folded
- `-Wl,-x`: strip local symbols
- `-Wl,-S`: strip DWARF debug info
- `-Wl,-dead_strip`: remove unreferenced sections
- `-fvisibility=hidden`: all symbols hidden by default
- `-fvisibility-inlines-hidden`: inline functions also hidden
- `-g` only in dev/beta builds
