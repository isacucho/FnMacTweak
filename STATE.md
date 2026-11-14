# Project state

## Closed: V23.8.1 -- build 60278837 (Fortnite 43.10)

Project closed 2026-11-15. Stable build tested on Mac16,8 (M4 Pro), macOS 27.3.

### Active patches (confirmed)

| Module | Status |
|---|---|
| DeviceSpoof | OK -- iOS device + bundle spoof, JB env hide, unsetenv DYLD vars |
| EosHooks | OK -- 8/8 symbols DYLD_INTERPOSE (GetSystemRequirementStatus forced to 0) |
| CompatReport | OK -- single vtable swap, type=10 and flag=1 suppressed |
| KickBypass | OK -- 18/18 ClientWasKicked vtable entries patched (43.10) |
| NmtPatcher | OK -- chain-patch in __DATA_CONST |
| ContentPatch | OK -- session swizzle to suppress CL |
| CustomizationPatcher | OK |
| StatusCodeFix | OK -- 201->200 FBackgroundNSURLSession |
| OsLogInterceptor | OK |
| EngineHooks | OK |

### Removed in V23.8.1

- `ValidationPatch`: redundant, CompatReport already covers type=10 and flag=1.
  Was patching the same vtable function as CompatReport, breaking the EAC handshake.
- `EacHooks.mm` / `MkwBypass.cpp`: no references in the build.
- `IAdapter.hpp` / `DebugCanvas.hpp`: interfaces with no active implementation.
- Fortnite 43.00 (build 59596594) code from KickBypass: unsupported version.
- `tools/`: unmaintained lldb/deploy/resign scripts.

### Architecture rule

ZERO disk patching: the game binary on disk is never touched or modified.
Only vtable swaps in __DATA_CONST via vm_protect(RW) on 16KB pages.

### Diagnostic log

```bash
tail -f ~/Library/Containers/0F16E856-1C80-4448-9C65-ED3A8E8DA5E9/Data/Documents/FnDiag.log
```
