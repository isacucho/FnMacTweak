# PITFALLS - Issue log

One issue at a time. Do not advance to the next until the current one is resolved and verified in-game.

---

## RUNTIME PROTECTION AUDIT (2026-11-13, build 60278837 / 43.10)

Static analysis of `/Applications/Fortnite.app/Wrapper/FortniteClient-IOS-Shipping.app/FortniteClient-IOS-Shipping`
(308MB, ARM64, sha256=91f9e4fd).

### Jailbreak / Sideloading

Mechanism detected via strings:
- `isJailbrokenWithSkipAdvancedJailbreakValidation:` -> ObjC method in JailbreakDetection
- Cydia paths present: `/Applications/Cydia.app`, `/Library/MobileSubstrate/DynamicLibraries/LiveClock.plist`,
  `/private/var/lib/cydia`, `/System/Library/LaunchDaemons/com.saurik.Cydia.Startup.plist`

Failure mechanism: two vtable functions in sideload/JIT validator return reason=10 (sideload)
and reason=6 (JIT). If they return != 1 -> kick.

**Active bypass (CompatReport, JadedFix port):**
- 33-instruction fingerprint scan locates the compat report function at runtime
- Suppresses type=10 (sideload/JIT validation) and all flag=1 failure reports
- Replaces ValidationPatch (which broke EAC registration by patching the same vtable function)

### Anti-tamper / Hash checks

Strings in binary:
- `Consistency Failure: Backing store page-in failed hash check!` -> UE5 PAK asset integrity
- `FVerifier: Hash check failed for %ls` -> asset verification
- These are ASSET integrity checks (PAK files), not binary executable checks. Do not cause kicks.

No runtime binary signature verification (AMFI handles that at kernel level).

### BroadcastNetworkFailure (ConnectionLost/ConnectionTimeout)

Chain confirmed in binary:
- `ENetworkFailure::ConnectionLost` / `ENetworkFailure::ConnectionTimeout` (enum index 3 and 4)
- `UEngine::BroadcastNetworkFailure: FailureType = %ls, ErrorString = %ls` -> UE5 failure log
- BNF function at file offset 0x56c999c, prologue: `ff 03 02 d1` = `SUB SP, SP, #0x80` (ARM64)

**ARCHITECTURE RULE (non-negotiable): ZERO disk patching. The game binary on disk is never modified.**

**AMFI CONSTRAINT (critical):** MSHookFunction/vm_protect(VM_PROT_COPY) on __TEXT of the main
executable is blocked by AMFI -> EXC_BAD_ACCESS SIGKILL, Namespace CODESIGNING Code 2.
This applies ONLY to the main executable; external dylibs (EOSSDK, etc.) can be hooked with MSHookFunction.
vm_protect on __DATA_CONST works without AMFI restriction (used by KickBypass and CompatReport).
Calling __TEXT via function pointer (read/execute) is always safe; only WRITING is blocked.

**BNF REMOVED (V23.7.9):**
NetFailurePatcher.cpp, NetworkHooks.mm, ContentPatch.mm and EacHooks.mm removed from build.
Reason: hooking NSURLSession (hook_session_factory injected FnContentLinkProtocol into ALL sessions,
installNetHooks hooks delegates + NSMutableURLRequest) interferes with the game connection
and causes "Network Connection Lost" / errors.com.epicgames.common.processing.
Do not touch anything network-related. Only subsystem hooks (vtable swaps in __DATA_CONST).

### ClientWasKicked (kick RPC)

Confirmed in binary:
- Strings: `ClientWasKicked Reason: %ls` at 0xb3fb7aa, `ClientWasKicked %ls.` at 0xb2e3ac5
- ClientWasKicked_Implementation at file offset 0x865a2b8, prologue: `ff 43 01 d1` = `SUB SP, SP, #0x50` (ARM64)
- 18 vtable entries in __DATA_CONST (kKickedEntries_4310[]), pointing to 0x865a2b8 on-disk (chained fixup encoding)

**Active bypass (KickBypass):**
- 18 entries patched: vtable[0] @ 0xce7d390, ... (see KickPatcher.cpp kKickedEntries_4310)
- Verified at runtime PID 78872: `[KickBypass] 43.10: patched 18/18`
- kicked_bypass_stub records timestamp in g_last_kick_suppressed_at

### EAC AntiCheatClient (EOS SDK)

Confirmed in load commands:
- `@executable_path/Frameworks/EOSSDK.framework/EOSSDK` -> embedded EAC SDK
- `@executable_path/Frameworks/CydiaSubstrate.framework/CydiaSubstrate` -> Substrate in load commands
  NOTE: the binary loads CydiaSubstrate directly. MSHookFunction in our dylib uses this Substrate.
- `@rpath/FnMacBypass.dylib` (weak) -> our dylib as LC_LOAD_WEAK_DYLIB

**Active bypass (EosHooks.cpp):**
- DYLD_INTERPOSE over 8 EOS SDK exported symbols
- GetSystemRequirementStatus: forces return 0 (EOS_Success)

### KickBypass offsets (43.10, build 60278837)

```
kKickedFn_4310 = 0x865a2b8 (ClientWasKicked_Implementation)
kKickedEntries_4310[18] = {
    0xce7d390, 0xd049c60, 0xd617e00, 0xd61c758, 0xd61f558,
    0xd625048, 0xd627c78, 0xd62ada0, 0xd62fcc8, 0xd6369e8,
    0xd6a70f8, 0xd723c08, 0xd726da8, 0xd72a048, 0xd72d2b8,
    0xd7692d8, 0xd7eb800, 0xd8138f8,
}
```
All verified at runtime (18/18 patched).

---

## AUDIT 2026-11-14: findings and fixes

### CRITICAL BUG (FIXED): install_customization_patch() was never called

`Core.mm` was missing the call to `fndiag::install_customization_patch()`. The disk island for
HandleCustomizationFailed was correctly installed on disk, but the __bss slot was never armed
with the stub address. The island always took the execute_original path (CBZ X16, slot==0 always
true) and the function executed normally, incrementing NumLoadCustomizationFailed without bound.
FIX: added call in Core.mm after install_kick_bypass() with BOOT_PROBE "11_custompatch_done".

### MEDIUM BUG (FIXED): mach_timebase_info() on every bnf_bypass_stub call

During the ConnectionLost flood (~125 calls/s during kick), `bnf_bypass_stub` called
`mach_timebase_info()` on every iteration to convert kKickWindowNs to ticks.
Each call is a kernel trap. Unnecessary: the timebase does not change at runtime.
FIX: g_kick_window_ticks computed once in install_net_failure_patch() and reused.

### MINOR BUG (FIXED): missing dmb ish in CustomizationPatcher

Write to __bss slot in install_customization_patch() lacked a memory barrier.
Without dmb ish, another CPU executing the island could see the slot as 0 (old value)
even after the dylib had written the stub address.
FIX: added `__asm__ volatile("dmb ish")` immediately after the slot write.

### MINOR BUG (FIXED): g_original_eac_cb/cd without atomic protection

`eac_msg_to_server_interceptor` and `my_AddNotifyMsgToServer` can execute on different EOS SDK threads.
Global variables `g_original_eac_cb` and `g_original_eac_cd` were read/written without atomics (formal data race).
FIX: converted to `std::atomic<uintptr_t>` and `std::atomic<void*>` with acquire/release.

### OBFUSCATION (FIXED): -g always present in all builds

The Makefile included `-g` unconditionally, embedding __DWARF sections in the dylib
even in public builds (function names, source paths, line numbers). This completely
negates the effect of -fvisibility=hidden for internal symbols.
FIX: `-g` only passed for CHANNEL=dev and CHANNEL=beta via DEBUG_FLAGS.
Also added STRIP_FLAGS=-Wl,-x -Wl,-S for CHANNEL=public.
RULE: `make PRODUCTION=1` (public) produces dylib without DWARF; `make DEV=1` keeps -g.

### CRITICAL BUG (FIXED): ValidationPatch breaks EAC registration

ValidationPatch (vtable1 @ 0xce5ad38, vtable2 @ 0xce5acd8) patches the same vtable function
that CompatReport hooks via fingerprint scan. The EAC registration handshake calls this function;
replacing it with an always-return-1 stub breaks the handshake -> "Client failed to register with server".
FIX: removed ValidationPatch entirely. CompatReport's compat_hook already handles type=10 (sideload/JIT)
and all flag=1 failures, covering full ValidationPatch scope without touching EAC registration.

---

## RESOLVED (2026-11-13): IPA with macOS wrapper structure rejected by Sideloadly

Sideloadly requires `Payload/<App>.app/Info.plist` directly. The macOS wrapper for Fortnite
is `Fortnite.app/Wrapper/FortniteClient-IOS-Shipping.app/` and packaging from
`/Applications/Fortnite.app/` as `Payload/Fortnite.app/` causes Sideloadly to fail with:
"There is no item named 'Payload/Fortnite.app/Info.plist' in the archive".
Correct: package from `Wrapper/FortniteClient-IOS-Shipping.app/` as
`Payload/FortniteClient-IOS-Shipping.app/`.

## RESOLVED (2026-11-13): MarketplaceKitWrapper SIGSEGV at startup (pc=0x0, 1s after boot)

`AppDistributorWrapper.getCurrent` in MarketplaceKitWrapper calls the Swift stub of
`MarketplaceKit.framework` (linked as LC_LOAD_WEAK_DYLIB). On this macOS the framework
does not exist, the stub resolves to NULL, the closure calls it -> SIGSEGV.
Fix: remove `Frameworks/MarketplaceKitWrapper.framework/` from the installed bundle before
resigning. Incorporated in resign.sh permanently.
Do NOT patch the main binary: removing the framework from the bundle is sufficient.

## PITFALL: disk island missing if IPA is built before deploy.sh

deploy.sh applies `patch_binary.py --apply` to the installed binary in
`/Applications/Fortnite.app/Wrapper/...`. If the IPA is built from that binary
WITHOUT running deploy.sh first, the disk island will not be in the IPA.
Sideloadly installs the clean binary and the disk island is lost.
Correct order: deploy.sh -> resign.sh -> (if IPA needed) build it now.

## CRITICAL BUG FIXED (2026-11-13): BL callers NOT patched even when island is present

### Symptom
FnDiag.log shows `disk-island found` and `slot armed` but `ConnectionLost suppressed`
and `synthetic ConnectionTimeout firing` never appear. bnf_bypass_stub never executes.
Kicks take 90s (UNetConnection timeout) instead of 25s.

### Cause
`patch_binary.py apply_patch()` had a bug in the `state=='patched'` branch:
when the island already existed at 0x29c0, the script assumed BL callers were already
redirected and skipped them entirely. Result: island installed but all 6 callers
still pointing to BNF directly.
Verified with BL scan: 6 BL->BNF (orig_bl), 0 BL->island (new_bl).

### Fix
`state=='patched'` branch now iterates BL_PATCHES and patches callers with orig_bl:
```python
for fo, new_bl, orig_bl in BL_PATCHES:
    if bytes(data[fo:fo+4]) == orig_bl:
        data[fo:fo+4] = new_bl  # redirect to island
```
After fix: `python3 tools/patch_binary.py --verify` shows 6/6 `[OK]`.

---

## RESOLVED: V2.5.0 heap scan crashes the process (SIGBUS + wrong thread)

**V2.5.1:** `vm_read_overwrite` eliminated SIGBUS in the scan. Not the real cause.
**V2.5.2:** dispatch_async(main_queue) for RejoinViaSessionInternal. Eliminated silent crash
caused by UE5 GameThread assertions when called from pthread.
**V2.6.0:** heap scan removed entirely. Hook on UFortRejoinCheck::Initialize
(kInitializeVtableOff=0xd4a4e60) captures self in g_rejoin_check_instance on match entry.
On kick: direct dispatch without scan.

**Status:** V2.6.0 discarded. V2.6.1: silent crash (UE5 RequestExit). Cause: dispatch_async
introduced ~3ms latency; EOS state reached >= 5 (Ending) before our block executed,
triggering checkf in RejoinViaSessionInternal+0x3c (LDRB [X8+0xd68]; CMP W8,#5).
V2.6.2: synchronous scan on game thread + direct call, no pthread or dispatch_async.
Pending deploy and in-game verification.

---

## Issue #1 [HISTORICAL]: Kick via ConnectionLost after ClientWasKicked suppressed

### Symptom

Player is kicked from the match approximately 42-43 seconds after joining.
Final mechanism: `LogNet: Error: UEngine::BroadcastNetworkFailure: FailureType = ConnectionLost`.
Present in BOTH sessions (v2.0.32 lines 9114-9116, v2.0.33 lines 22009-22011).

### Prior analysis (incorrect)

Initial investigation identified `NumLoadCustomizationFailed >= 3` as the root cause.
**This hypothesis was wrong.** `NumLoadCustomizationFailed` appears in the end-of-match
analytics block (`LogFortPerformance: Athena Client End of zone performance report`)
which always runs on match exit, regardless of the exit cause.
The performance trigger is a telemetry report, not the kick mechanism.

v2.0.33 (ContentPatch) confirmed this: HTTP 400 on experience_br fixed to 200,
but the kick continues with the same ~43 second timing.

### Actual causality chain

```
~42-43s after joining:
  Server sends ClientWasKicked RPC, reason=1805386128 (0x6B9C0190)
    -> KickBypass suppresses it (OK, hook works)
      -> Server detects client did not disconnect after kick
        -> Server closes UDP connection (GameNetDriver IpNetDriver_2147482644)
          -> BroadcastNetworkFailure: ConnectionLost (93ms after RPC)
            -> LogGlobalStatus: Browse Started -> Frontend (match exit)
              -> LogFortPerformance end-of-zone report (analytics, includes NumLoadCustomizationFailed)
                -> CustomKeyMatchCommand_PlayerKick unregistered (kick confirmed)
```

### Why KickBypass is not enough

KickBypass suppresses the `ClientWasKicked` RPC correctly. But the server has a fallback:
if the client does not disconnect after the kick, the server forcibly closes the network session.
The UDP connection (IpNetDriver) is terminated from the server side, generating `ConnectionLost`
on the client. This path does not go through `ClientWasKicked_Implementation`; KickBypass does not see it.

### Resolution history

- [x] Root cause v1 (NumLoadCustomizationFailed) identified as SYMPTOM, not cause
- [x] ContentPatch (v2.0.33): HTTP 400 -> 200 on experience_br (partially useful)
- [x] Real root cause identified: ConnectionLost after suppressed ClientWasKicked
- [x] Reason code documented: 1805386128 (0x6B9C0190), suppressed by KickBypass
- [x] BroadcastNetworkFailure located: RVA 0x5642c74, prologue 0xd10203ff
- [x] NetFailurePatcher implemented: runtime scan __DATA_CONST/__AUTH_CONST, suppresses
      ConnectionLost within 500ms of suppressed kick via g_last_kick_suppressed_ns
- [x] v2.0.34: vtable scan finds 0 entries (function devirtualized in this build)
- [x] v2.0.35: BL-caller patching as fallback; trampoline page via vm_allocate(VM_FLAGS_FIXED)
      near base-0x2000000; patch_text_bl with vm_protect(R+W)->BL->clear_cache->vm_protect(R+X)
- [x] v2.1.0: do NOT interpose mmap via DYLD_INTERPOSE. iOS SDK declares syscall() as
      returning int (32 bits); mmap returns a 64-bit pointer. Interposing via syscall
      truncates the return address -> crash in __malloc_init during DYLD init.
      Solution: only interpose read/pread/close (all return int or ssize_t, safe).
- [x] v2.1.10: trigger_silent_lobby_return() CRASH: EXC_BAD_ACCESS in g_orig_kicked(stale_self, 0).
      The self saved at t=0 has partially destroyed internal members at t=3s.
      SOLUTION (v2.1.11): remove trigger_silent, let ONE through the cap (V2.1.9).
- [x] v2.1.11: no allow-jit in entitlements (only get-task-allow) + BNF devirtualized
      -> disk patch still needed for BNF hooking without AMFI kill.
      No pure in-memory path: BNF has no vtable entries, vm_protect(COPY) on __TEXT
      creates unsigned COW pages -> AMFI SIGKILL.
- [x] v2.1.11 CRASH: EXC_BAD_ACCESS SIGKILL, Namespace CODESIGNING Code 2 "Invalid Page".
      Cause: old dylib V2.1.4 still loaded (LC_LOAD_DYLIB not updated because deploy.sh
      was not run). V2.1.4 used vm_protect(VM_PROT_COPY) on __TEXT to write trampoline
      at RVA 0x5B9D630. Page 0x109dac000 became COW (SM=COW r-x/rwx). AMFI kills
      the process with SIGKILL when GameThread tries to execute from that page.
      RULE: vm_protect(COPY) on __TEXT is AMFI-fatal even with get-task-allow. Only safe on DATA.
- [x] v2.1.12: game crashes silently ~30s. Cause: island at 0x29bc overlaps the last 4 bytes
      of the load commands area. install_name_tool rewrites the binary and restores original
      bytes at 0x29bc-0x29bf, destroying the ADRP X16 of the island.
      FIX (v2.1.13): island moved to 0x29c0 (first real padding byte after load commands end).
      RULE: ISLAND_FILE_OFF MUST be >= 32 + sizeofcmds.
- [x] V2.1.24: BNF hook + KickBypass working. ConnectionLost suppressed indefinitely.
      Lobby return via ConnectionTimeout at t=90s. BeginSpectating with self ViewTarget
      triggers "Attempting to spectate self!" warning but does not crash.
- [x] V2.1.25 NCL SCREEN: 25s flood-cap lets one ConnectionLost through at t=25s.
      Spectator not active (BeginSpectating fails with self ViewTarget).
      ConnectionLost without spectate = "Network Connection Lost" screen.
      RULE: do NOT let ConnectionLost through if BeginSpectating has not succeeded.
- [x] V2.1.26: indefinite suppression restored. ConnectionTimeout bypasses our hook
      (different BL site in UNetConnection::Tick).
- [x] V23.7.6 BNF FLOOD INDEFINITELY: server sends CL every ~8ms without time limit
      while client does not disconnect. kKickWindowNs of 5s expired before synthetic CT (25s).
      FIX: kKickWindowNs = 30s.
      RULE: kKickWindowNs must be > kSyntheticCtDelayS * 1000 (currently 25s -> minimum 25001ms).
- [x] V2.1.27: synthetic ConnectionTimeout via dispatch_after(25s, main_queue). VERIFIED
      2026-11-10: "[NetFailurePatch] synthetic ConnectionTimeout firing (25s early)" at exactly dk=25s.
      Clean lobby return without NCL screen. SUCCESS.
- [x] V2.2.0: RejoinViaSessionInternal vtable patch installed and verified at startup.
      CONFIRMED 2026-11-10: "[Reconnect] RejoinViaSessionInternal called" NEVER appears.
      The ConnectionTimeout -> ReturningToFrontEnd path goes directly to lobby, NOT through
      RejoinViaSessionInternal. The vtable hook exists but has no trigger.
- [x] V2.6.x: RejoinViaSessionInternal UNCALLABLE after reason=144 kick.
      CONFIRMED 2026-11-10 with vm_read_overwrite probe in V2.6.4:
      The chain [base+0xc25a468] -> slot1 -> slot2 -> [slot2+0xd68] returns KERN_INVALID_ADDRESS
      (kr=1) when reading slot2+0xd68. The EOS session object (slot2) was freed by EOS SDK threads
      BEFORE ClientWasKicked_Implementation executes on the game thread.
      Any call to g_orig_rejoin(obj) crashes in RejoinViaSessionInternal+0x3c.
      V2.6.4 detects kr=1 and skips the call. The 25s freeze (V2.1.27) remains active.
      CONCLUSION: the RejoinViaSessionInternal path is not viable for post-kick reconnection.
