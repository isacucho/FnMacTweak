# FnMacUpdateFix - Project context

## Description

Dylib injected via `DYLD_INSERT_LIBRARIES` into `FortniteClient-IOS-Shipping` (ARM64 Catalyst)
to run Fortnite iOS on macOS. Active version: **V23.8.1**.

Target: `FortniteClient-IOS-Shipping`, build 60278837 (Fortnite 43.10).
ASLR slide `0x46c000`, base `0x10046c000`.

## Hook architecture

### KickBypass (`include/update/KickPatcher.hpp`)
- Patches 18 vtable entries in `__DATA_CONST` pointing to `ClientWasKicked_Implementation`
- The stub suppresses all kick reasons and logs a timestamp to `g_last_kick_suppressed_at`
- 43.10: 18/18 entries patched, fn_offset=0x865a2b8
- Installed via `install_kick_bypass()` in Core.mm

### NmtPatcher (`include/update/NmtPatcher.hpp`)
- Chain-patch in `__DATA_CONST` at offset `0x10c73ff10`
- Disables platform/netmode check that rejects the macOS client
- 43.10: chain_patched=1, segs=1

### CompatReport (`src/eos/CompatReport.cpp`)
- Hooks the compat report vtable function via 33-instruction fingerprint scan
- Suppresses type=10 (sideload/JIT validation) and all flag=1 failure reports
- Replaces ValidationPatch entirely; covers the same vtable function without breaking EAC

### EosHooks (`src/eos/EosHooks.cpp`)
- DYLD_INTERPOSE over exported C symbols of EOSSDK.framework
- `EOS_GetSystemRequirementStatus`: forces return 0 (EOS_Success) so macOS is not rejected
- 8 symbols interposed

### DeviceSpoof (`src/metadata/DeviceSpoof.mm`)
- User-Agent: `Fortnite/43.00.0 (iPad14,3; iPhone OS 17.5; Scale/3.00)`
- Hides jailbreak paths (Cydia, MobileSubstrate, /var/jb, ...)
- Removes DYLD_INSERT_LIBRARIES and DYLD_LIBRARY_PATH from environment

### ContentPatch (`src/update/ContentPatch.mm`)
- Session swizzle to suppress CL (content link) errors

### CustomizationPatcher (`src/update/CustomizationPatcher.cpp`)
- Patches NumLoadCustomizationFailed path

### StatusCodeFix (`src/network/StatusCodeFix.mm`)
- Patches HTTP 201 -> 200 in FBackgroundNSURLSession::GetDownloadResult

### OsLogInterceptor / EngineHooks
- OsLog subsystem mirroring and engine-level hooks

## Log subsystems

- `com.alexgrdev.fnmackickfix` (OSLog): KickBypass, CompatReport, NmtPatcher
- `FnDiag.log` (file): all modules via DiagLog

## Architecture rule

ZERO disk patching: the game binary on disk is never touched or modified.
Only vtable swaps in __DATA_CONST via vm_protect(RW) on 16KB pages.

AMFI constraint: vm_protect(VM_PROT_COPY) on __TEXT of the main executable is blocked
by AMFI (EXC_BAD_ACCESS SIGKILL, Namespace CODESIGNING Code 2). Only __DATA_CONST writes
are safe. Dylib __TEXT pages are not subject to this restriction.
