# CLAUDE.md - Operational instructions for this repo

## Build

Development build (with diagnostics):
```bash
cd /Users/alexg/Documents/Dev/Fortnite/FnMac/FnMacUpdateFix
make DEV=1
# output: builds/dev/FnMacBypass-V<version>-dev.dylib
```

Production build:
```bash
make public
```

Clean and rebuild:
```bash
make clean && make DEV=1
```

## Verify build

```bash
# Check that hook symbols are present
nm -g builds/dev/FnMacBypass-V*.dylib | grep -E "hook_|install_|my_"

# Check __interpose section (DYLD_INTERPOSE from EosHooks)
otool -s __DATA __interpose builds/dev/FnMacBypass-V*.dylib

# Check ARM64 architecture
file builds/dev/FnMacBypass-V*.dylib
```

## Versioning (X.Y.Z)

Scheme aligned with the official Fortnite iOS version:

- X: major version of official Fortnite iOS (e.g. 23 for Fortnite 23.0.0).
  Changes when the Fortnite target is updated (new base IPA).
- Y: new feature in the dylib (new hook, new subsystem, new module).
  Accumulated since base IPA 42.40.1.
- Z: bugfix / behavior adjustment in existing dylib functionality.

IPA: `Fortnite-[X].0.0-V[X].[Y].[Z]-min.ipa`
Dylib: `FnMacBypass-V[X].[Y].[Z].dylib`

Current in VERSION: `23.8.1` (Fortnite 23.0.0, 8 features, 1 patch since 42.40.1)

## Diagnostic log

Log lives at (UUID may change if reinstalled via Sideloadly):
`~/Library/Containers/0F16E856-1C80-4448-9C65-ED3A8E8DA5E9/Data/Documents/FnDiag.log`

If the UUID changes, find it with:
```bash
lsof -p $(pgrep FortniteClient | head -1) 2>/dev/null | grep FnDiag.log | awk '{print $NF}'
```

Real-time follow:
```bash
tail -f ~/Library/Containers/0F16E856-1C80-4448-9C65-ED3A8E8DA5E9/Data/Documents/FnDiag.log | grep -E "KickBypass|CompatReport|NmtPatch|slot|armed"
```

OSLog subsystem: `com.alexgrdev.fnmackickfix`.

Stream in real time:
```bash
log stream --predicate 'subsystem == "com.alexgrdev.fnmackickfix"' --level debug
```

Read current session log:
```bash
log show --predicate 'subsystem == "com.alexgrdev.fnmackickfix"' \
  --start "2026-11-15 00:00:00" --end "2026-11-15 01:00:00" --style compact
```

## Critical LLDB breakpoints

Attach to Fortnite process (variable PID):
```bash
lldb -p $(pgrep FortniteClient-IOS)
```

Useful breakpoints:
```
# ClientWasKicked entry (all reasons, covered by KickBypass)
(lldb) b ClientWasKicked_Implementation

# HTTP response for diagnosing experience_br
(lldb) b -[NSURLSessionTask _didFinishWithResponse:data:error:]
```

Memory dump in patched vtable region:
```bash
(lldb) x/32xg 0x1089f8f18   # orig vtable, adjust for ASLR slide
```

## Offsets v23.8.1 (slide 0x46c000, base 0x10046c000)

| Symbol | Offset from base | Notes |
|---|---|---|
| KickBypass fn | 0x865a2b8 | ClientWasKicked_Implementation |
| KickBypass vtable[0] | 0xce7d390 | First of 18 patched entries |
| NmtPatch chain | 0x10c73ff10 | seg __DATA_CONST |

Recalculate with current slide:
```bash
# Read slide from startup log (~line 47):
# [KickBypass] vtable patch: 18/18 entries patched slide=0x46c000
```

## Key files

| File | Purpose |
|---|---|
| `src/Core.mm` | Dylib constructor, hook installation order |
| `src/eos/EosHooks.cpp` | DYLD_INTERPOSE over EOSSDK, GetSystemRequirementStatus |
| `src/eos/CompatReport.cpp` | Vtable fingerprint scan, type=10 and flag=1 bypass |
| `src/update/KickPatcher.cpp` | Vtable patcher for ClientWasKicked (43.10 only) |
| `include/update/NmtPatcher.hpp` | Chain patcher for NMT in __DATA_CONST |
| `src/core/GameLogMirror.cpp` | LogGameLog mirror |
| `src/metadata/DeviceSpoof.mm` | iPad14,3 / iOS 17.5 User-Agent spoof |

## Editing rules

- Partial change = Edit (specific lines). Full Write only for new files.
- Do not use Write to overwrite an existing file if only one function changes.
- One issue in PITFALLS.md at a time. Do not mark resolved without an in-game session verified.
