#!/usr/bin/env python3
"""
patch_binary.py -- on-disk binary patch for FnMacUpdateFix v2.1.13

Patches 3 direct BL-to-BnfFn call sites in __TEXT to route via a 20-byte
trampoline island placed in __TEXT alignment padding. The island does:

    ADRP X16, <slot_page>   ; load page of __bss slot (0x112BFA000)
    LDR  X16, [X16, #0x880] ; dereference: slot holds bnf_bypass_stub addr
    CBZ  X16, #8            ; if slot==0 (dylib not ready), skip BR -> RET
    BR   X16                ; tail-call (LR from BL is preserved)
    RET                     ; safe fallback: return to caller (slot was 0)

DATA slot is in __bss (VA 0x112BFA880, offset 0x12BFA880 from base).
__bss has no file backing (offset=0 in section header); OS zero-fills at
load time. The game never writes to this address -> safe from stomps.

The dylib writes bnf_bypass_stub to the DATA slot at load time
(install_net_failure_patch detects the island and sets up the slot).
Until then, any BNF call returns immediately (safe, no crash).

IMPORTANT: island placed at 0x29c0 (first byte after load commands end at
0x29c0 = 32+sizeofcmds=32+0x29a0). Do NOT place at 0x29bc: install_name_tool
rewrites the binary when updating LC_LOAD_DYLIB and restores the last 4 bytes
of load commands (0x29bc-0x29bf), destroying the ADRP instruction silently.

Usage:
  python3 tools/patch_binary.py --verify   # default: check state
  python3 tools/patch_binary.py --apply    # patch the binary (migrates old island)
  sudo python3 tools/patch_binary.py --apply  # may need root
"""
import struct
import sys
import os
import shutil
import argparse
import subprocess

BIN = '/Applications/Fortnite.app/Wrapper/FortniteClient-IOS-Shipping.app/FortniteClient-IOS-Shipping'

# Island: 20 bytes at file offset 0x29c0 (VA=0x1000029c0).
# 0x29c0 = 32 + sizeofcmds = first byte AFTER load commands (true padding start).
# DO NOT use 0x29bc: that overlaps the last 4 bytes of load commands and
# install_name_tool restores those bytes when updating LC_LOAD_DYLIB, silently
# overwriting the ADRP with load-command data (observed: 30c10900 instead of d05f0990).
ISLAND_FILE_OFF = 0x29c0
ISLAND_BYTES    = bytes.fromhex(
    'd05f0990'  # ADRP X16, #0x12BF8  (loads page 0x112BFA000 into X16)
    '104244f9'  # LDR  X16, [X16, #0x880]  (reads *0x112BFA880, __bss DATA slot)
    '500000b4'  # CBZ  X16, +8  (if slot==0 jump over BR to RET; dylib not ready)
    '00021fd6'  # BR   X16  (tail-call bypass stub with LR intact)
    'c0035fd6'  # RET  (safe fallback: slot was 0, return to original caller)
)
# ADRP is identical for VA=0x1000029bc and VA=0x1000029c0: both are in page
# 0x100002000, so the PC-relative page offset to __bss is the same (0x12BF8 pages).

# Old island detection (previous slot in __DATA at 0xEAA7338, game stomps it).
ISLAND_BYTES_OLD = bytes.fromhex('305507b0' '109e41f9' '00021fd6')

# DATA slot is in __bss (VA 0x112BFA880, offset 0x12BFA880 from Mach-O base).
# __bss has offset=0 in the section header -> no physical file backing.
# The OS zero-fills it at load time; there is no byte in the binary to verify.
# The dylib writes stub_va here at runtime via kDataSlotOff = 0x12BFA880.
DATA_SLOT_BSS_OFF = 0x12bfa880  # runtime offset only, NOT a file offset

# BL patches: (file_offset, new_bytes, original_bytes)
# Each entry changes BL BnfFn -> BL <island at 0x29c0>
# new_bytes = old_new_bytes + 1 in imm26 (target moved +4 bytes, same 4KB page)
BNF_OFFSET = 0x5642c74  # file offset of BnfFn (kBnfOffset in NetFailurePatcher.cpp)

# ---- BeginSpectating island (V2.1.17) ----
# BeginSpectating_Implementation at file offset 0x81848fc.
# Non-virtual UE RPC — no vtable entries, so we patch its first instruction in-place
# with a B to an island in the __TEXT.__const zero-padding (file 0xb945b84, 123KB free).
#
# Island layout (28 bytes):
#   +0:  ADRP X16, slot_page         (page of __bss slot for begin_spectating_stub)
#   +4:  LDR  X16, [X16, #0x888]     (dereference: 0=dylib not ready, nonzero=stub addr)
#   +8:  CBNZ X16, +12               (slot nonzero → call stub at +12; zero → execute_original at +20)
#   +12: BR   X16                    (tail-call stub, LR intact)
#   +16: RET                         (unreachable safety)
#   +20: STP  X29, X30, [SP, #-N]!   (original insn0 of BeginSpectating)
#   +24: B    BeginSpectating+4       (continue from insn1 — insns 1+ are intact in fn)
#
# g_orig_spectate in dylib points to island+20 (execute_original path).
SPEC_FN_OFF     = 0x81848fc   # BeginSpectating_Implementation
SPEC_ISLAND_OFF = 0xb945b84   # island in __TEXT.__const zero-padding
SPEC_SLOT_OFF   = 0x12bfa888  # __bss DATA slot for begin_spectating_stub

SPEC_ISLAND_BYTES = bytes.fromhex(
    'b09503b0'  # ADRP X16, page(0x112BFA000) -> word 0xB00395B0 in LE bytes
    '104644f9'  # LDR  X16, [X16, #0x888]  → reads *0x112BFA888 (__bss slot)
    '700000b5'  # CBNZ X16, +12  (slot==0 → skip BR, go to execute_original at +20)
    '00021fd6'  # BR   X16  (tail-call begin_spectating_stub)
    'c0035fd6'  # RET  (unreachable safety)
    'fd7b03a9'  # STP  X29, X30, [SP, #-N]!  (original insn0 of BeginSpectating)
    '59fb2017'  # B    BeginSpectating+4
)
SPEC_ORIG_INSN = bytes.fromhex('fd7b03a9')   # original first instruction of BeginSpectating
SPEC_B_INSN    = bytes.fromhex('a204df14')   # B island (replacement for first instruction)

BL_PATCHES = [
    # FUNC1 ConnectionLost caller, BL at 0x100f21998
    (0x0f21998, bytes.fromhex('0a84c397'), bytes.fromhex('b7841c95')),
    # FUNC2 ConnectionLost caller, BL at 0x1016356dc
    (0x16356dc, bytes.fromhex('b934a797'), bytes.fromhex('66350095')),
    # FUNC3 ConnectionLost caller, BL at 0x105b9fb70
    (0x05b9fb70, bytes.fromhex('948b9196'), bytes.fromhex('418cea97')),
]

# BL bytes from previous patch that pointed to old island at 0x29bc.
# Used by check_state to detect "needs migration" state.
BL_PATCHES_OLD_ISLAND = [
    (0x0f21998, bytes.fromhex('0984c397')),
    (0x16356dc, bytes.fromhex('b834a797')),
    (0x05b9fb70, bytes.fromhex('938b9196')),
]
OLD_ISLAND_FILE_OFF = 0x29bc  # previous island position (overlapped load commands)

def read_bin():
    with open(BIN, 'rb') as f:
        return bytearray(f.read())

def _check_spec_state(data):
    """Returns 'patched', 'unpatched', or 'unknown' for the BeginSpectating island."""
    island_cur = bytes(data[SPEC_ISLAND_OFF:SPEC_ISLAND_OFF+len(SPEC_ISLAND_BYTES)])
    fn_cur     = bytes(data[SPEC_FN_OFF:SPEC_FN_OFF+4])
    if island_cur == SPEC_ISLAND_BYTES and fn_cur == SPEC_B_INSN:
        return 'patched'
    if fn_cur == SPEC_ORIG_INSN:
        return 'unpatched'
    # fn already branches to the island but island bytes are stale/wrong
    # (e.g. a prior deploy wrote a bad ADRP). Rewrite island in place.
    if fn_cur == SPEC_B_INSN and island_cur != SPEC_ISLAND_BYTES:
        return 'repair'
    return f'unknown (fn={fn_cur.hex()})'


def check_state(data):
    """Returns 'patched', 'patched_old', 'migrate', 'unpatched', or 'unknown (<hex>)'."""
    island12 = bytes(data[ISLAND_FILE_OFF:ISLAND_FILE_OFF+12])
    if island12 == ISLAND_BYTES[:12]:          # new stable island at 0x29c0
        return 'patched'
    if island12 == ISLAND_BYTES_OLD:              # old 12-byte island (vulnerable)
        return 'patched_old'

    # Island not present at new location - check BL sites for context.
    all_orig = all(
        bytes(data[fo:fo+4]) == orig_bl
        for fo, _, orig_bl in BL_PATCHES
    )
    all_old_new = all(
        bytes(data[fo:fo+4]) == old_bl
        for fo, old_bl in BL_PATCHES_OLD_ISLAND
    )

    # Migration detection: BL sites point to old island at 0x29bc regardless of
    # what is at the new location (old island bytes spill past 0x29c0, so new
    # location is NOT zeros even when the binary has the old layout).
    if all_old_new:
        return 'migrate'

    if island12 == bytes(12):
        return 'unpatched'

    # Island zone has unexpected content.
    if all_orig:
        return 'unpatched'
    return f'unknown ({island12[:4].hex()})'

def verify(data):
    state = check_state(data)
    print(f"Binary: {BIN}")
    print(f"Island at 0x{ISLAND_FILE_OFF:x}: {state}")

    if state == 'migrate':
        print("\nIsland estaba en 0x29bc (sobrepone load commands).")
        print("install_name_tool corrompió el ADRP. Run with --apply to migrate to 0x29c0.")

    elif state == 'unpatched':
        print("\nCall sites (should point to BnfFn 0x1{:07x}):".format(BNF_OFFSET))
        all_ok = True
        for fo, new_bl, orig_bl in BL_PATCHES:
            cur = bytes(data[fo:fo+4])
            status = 'ORIG' if cur == orig_bl else ('PATCHED' if cur == new_bl else f'UNEXPECTED({cur.hex()})')
            print(f"  0x{fo:08x}: {cur.hex()}  [{status}]")
            if cur != orig_bl:
                all_ok = False
        if all_ok:
            print("\nReady to patch. Run with --apply.")
        else:
            print("\nWARNING: some call sites have unexpected content.")

    elif state == 'patched_old':
        print("\nOLD island (12 bytes, no CBZ guard) - UNSAFE, may crash on early BNF call.")
        print("Run with --apply to upgrade to stable 20-byte island.")
        print("\nCall sites (should point to island 0x1{:07x}):".format(ISLAND_FILE_OFF))
        for fo, new_bl, orig_bl in BL_PATCHES:
            cur = bytes(data[fo:fo+4])
            status = 'OK' if cur == new_bl else f'UNEXPECTED({cur.hex()})'
            print(f"  0x{fo:08x}: {cur.hex()}  [{status}]")

    elif state == 'patched':
        print("\nStable island (20 bytes, CBZ null-guard) - safe.")
        print("\nCall sites (should point to island 0x1{:07x}):".format(ISLAND_FILE_OFF))
        for fo, new_bl, orig_bl in BL_PATCHES:
            cur = bytes(data[fo:fo+4])
            status = 'OK' if cur == new_bl else f'UNEXPECTED({cur.hex()})'
            print(f"  0x{fo:08x}: {cur.hex()}  [{status}]")
        print(f"\nDATA slot 0x{DATA_SLOT_BSS_OFF:x}: in __bss (no file backing, OS zero-fills, written at runtime by dylib)")
        print("\nPatch is applied. Run resign.sh after deploy.")

    spec_state = _check_spec_state(data)
    print(f"\nBeginSpectating island at 0x{SPEC_ISLAND_OFF:x}: {spec_state}")
    if spec_state == 'patched':
        print(f"  DATA slot 0x{SPEC_SLOT_OFF:x}: in __bss (written at runtime by dylib)")
    elif spec_state == 'unpatched':
        print(f"  Run with --apply to patch BeginSpectating island.")

    return state

def _apply_spec_island(data):
    """Apply (or skip if already applied) the BeginSpectating island. Returns True if changed."""
    spec_state = _check_spec_state(data)
    if spec_state == 'patched':
        print("BeginSpectating island already patched.")
        return False
    if spec_state == 'repair':
        # fn already branches to island; only the island bytes are stale/wrong.
        # Rewrite the island only (do NOT touch fn, it is already SPEC_B_INSN).
        old = bytes(data[SPEC_ISLAND_OFF:SPEC_ISLAND_OFF+4])
        data[SPEC_ISLAND_OFF:SPEC_ISLAND_OFF+len(SPEC_ISLAND_BYTES)] = SPEC_ISLAND_BYTES
        print(f"BeginSpectating island REPAIRED at 0x{SPEC_ISLAND_OFF:x}: "
              f"ADRP {old.hex()} -> {SPEC_ISLAND_BYTES[:4].hex()}")
        return True
    if spec_state != 'unpatched':
        print(f"WARNING: BeginSpectating island state: {spec_state} - skipping.")
        return False
    cur_fn = bytes(data[SPEC_FN_OFF:SPEC_FN_OFF+4])
    if cur_fn != SPEC_ORIG_INSN:
        print(f"ERROR: BeginSpectating fn at 0x{SPEC_FN_OFF:x} expected {SPEC_ORIG_INSN.hex()} got {cur_fn.hex()}. Skipping.")
        return False
    data[SPEC_ISLAND_OFF:SPEC_ISLAND_OFF+len(SPEC_ISLAND_BYTES)] = SPEC_ISLAND_BYTES
    print(f"BeginSpectating island written at 0x{SPEC_ISLAND_OFF:x}: {SPEC_ISLAND_BYTES.hex()}")
    data[SPEC_FN_OFF:SPEC_FN_OFF+4] = SPEC_B_INSN
    print(f"BeginSpectating fn patched at 0x{SPEC_FN_OFF:x}: {SPEC_ORIG_INSN.hex()} -> {SPEC_B_INSN.hex()}")
    return True


def apply_patch(data):
    state = check_state(data)

    if state == 'patched':
        print("BNF island already stable (CBZ guard).")
        changed = _apply_spec_island(data)
        return changed

    if state == 'patched_old':
        # Upgrade: overwrite old 12-byte island with new 20-byte island.
        # BL call sites already point to the island VA; no need to re-patch them.
        print("Upgrading old island to stable 20-byte island (adds CBZ null-guard)...")
        data[ISLAND_FILE_OFF:ISLAND_FILE_OFF+len(ISLAND_BYTES)] = ISLAND_BYTES
        print(f"Island upgraded at 0x{ISLAND_FILE_OFF:x}: {ISLAND_BYTES.hex()}")
        return True

    if state == 'migrate':
        # Island was at old 0x29bc (overlapping load commands); install_name_tool
        # corrupted its first instruction. Migrate: clear old island, write new island
        # at 0x29c0, update BL sites to point to new location.
        print("Migrando island de 0x29bc -> 0x29c0 (fix install_name_tool overlap)...")
        data[OLD_ISLAND_FILE_OFF:OLD_ISLAND_FILE_OFF+20] = bytes(20)
        data[ISLAND_FILE_OFF:ISLAND_FILE_OFF+len(ISLAND_BYTES)] = ISLAND_BYTES
        print(f"Island escrita en 0x{ISLAND_FILE_OFF:x}: {ISLAND_BYTES.hex()}")
        for fo, new_bl, _ in BL_PATCHES:
            fo_old, old_bl = next((x for x in BL_PATCHES_OLD_ISLAND if x[0] == fo), (fo, None))
            print(f"BL 0x{fo:08x}: {old_bl.hex()} -> {new_bl.hex()}")
            data[fo:fo+4] = new_bl
        return True

    if state.startswith('unknown'):
        # Unknown magic but BL sites already redirected: check if BL sites point to
        # the island VA. If so, just rewrite the island bytes (e.g. ADRP changed
        # between Fortnite builds). If BL sites don't point to island, abort.
        bl_ok = all(bytes(data[fo:fo+4]) == new_bl for fo, new_bl, _ in BL_PATCHES)
        if bl_ok:
            print(f"Unknown island magic ({state}), BL sites already redirected -> upgrading island only...")
            data[ISLAND_FILE_OFF:ISLAND_FILE_OFF+len(ISLAND_BYTES)] = ISLAND_BYTES
            print(f"Island rewritten at 0x{ISLAND_FILE_OFF:x}: {ISLAND_BYTES.hex()}")
            return True
        print(f"ERROR: unknown island state and BL sites not redirected. Manual inspection needed.")
        return False

    if state != 'unpatched':
        print(f"ERROR: unexpected state: {state}. Aborting.")
        return False

    # Fresh patch: verify call sites match originals before touching anything.
    for fo, new_bl, orig_bl in BL_PATCHES:
        cur = bytes(data[fo:fo+4])
        if cur != orig_bl:
            print(f"ERROR: BL at 0x{fo:x} expected {orig_bl.hex()} got {cur.hex()}. Aborting.")
            return False

    # Apply island (20 bytes).
    data[ISLAND_FILE_OFF:ISLAND_FILE_OFF+len(ISLAND_BYTES)] = ISLAND_BYTES
    print(f"Island written at 0x{ISLAND_FILE_OFF:x}: {ISLAND_BYTES.hex()}")

    # Redirect BL call sites to the island.
    for fo, new_bl, orig_bl in BL_PATCHES:
        data[fo:fo+4] = new_bl
        print(f"BL patched at 0x{fo:08x}: {orig_bl.hex()} -> {new_bl.hex()}")

    # DATA slot is in __bss: no file backing, always zero at load time.
    # Nothing to verify or write here; dylib writes stub_va at runtime.

    # Apply BeginSpectating island.
    spec_state = _check_spec_state(data)
    if spec_state == 'unpatched':
        # Verify original first instruction matches expected.
        cur_fn = bytes(data[SPEC_FN_OFF:SPEC_FN_OFF+4])
        if cur_fn != SPEC_ORIG_INSN:
            print(f"ERROR: BeginSpectating fn at 0x{SPEC_FN_OFF:x} expected {SPEC_ORIG_INSN.hex()} got {cur_fn.hex()}. Skipping spec island.")
        else:
            data[SPEC_ISLAND_OFF:SPEC_ISLAND_OFF+len(SPEC_ISLAND_BYTES)] = SPEC_ISLAND_BYTES
            print(f"BeginSpectating island written at 0x{SPEC_ISLAND_OFF:x}: {SPEC_ISLAND_BYTES.hex()}")
            data[SPEC_FN_OFF:SPEC_FN_OFF+4] = SPEC_B_INSN
            print(f"BeginSpectating fn patched at 0x{SPEC_FN_OFF:x}: {SPEC_ORIG_INSN.hex()} -> {SPEC_B_INSN.hex()}")
    elif spec_state == 'patched':
        print("BeginSpectating island already patched.")
    else:
        print(f"WARNING: BeginSpectating island state: {spec_state} - skipping.")

    return True

def main():
    parser = argparse.ArgumentParser(description='FnMac on-disk binary patcher v2.0.43')
    parser.add_argument('--verify',  action='store_true', help='Check patch state (default)')
    parser.add_argument('--apply',   action='store_true', help='Apply patch to binary')
    parser.add_argument('--restore', action='store_true', help='Restore binary from pre-patch backup')
    args = parser.parse_args()

    if not os.path.exists(BIN):
        print(f"ERROR: binary not found: {BIN}")
        sys.exit(1)

    if args.restore:
        backup = BIN + '.pre_fnpatch'
        if not os.path.exists(backup):
            print(f"ERROR: backup not found: {backup}")
            print("Cannot restore - no .pre_fnpatch backup exists.")
            sys.exit(1)
        subprocess.run(['xattr', '-d', 'com.apple.provenance', BIN], capture_output=True)
        subprocess.run(['xattr', '-cr', BIN], capture_output=True)
        with open(backup, 'rb') as fsrc:
            backup_data = fsrc.read()
        with open(BIN, 'wb') as fdst:
            fdst.write(backup_data)
        print(f"Binary restored from {backup}")
        print("Run resign.sh to re-sign after restore.")
        sys.exit(0)

    data = read_bin()

    if args.apply:
        changed = apply_patch(data)
        if not changed:
            sys.exit(0)
        # deploy.sh runs `sudo codesign --remove-signature APP` before calling this script,
        # which lifts com.apple.macl write-protection from the .app directory.
        # Clear any remaining xattrs as a defensive measure.
        app_bundle = os.path.dirname(BIN)
        subprocess.run(['xattr', '-cr', app_bundle], capture_output=True)
        subprocess.run(['xattr', '-cr', BIN], capture_output=True)

        # Write back
        backup = BIN + '.pre_fnpatch'
        if not os.path.exists(backup):
            shutil.copy2(BIN, backup)
            print(f"Backup: {backup}")
        with open(BIN, 'wb') as f:
            f.write(data)
        print(f"\nPatch applied. Next steps:")
        print(f"  sudo bash tools/deploy.sh   # copies dylib")
        print(f"  bash tools/resign.sh         # re-signs binary + dylib")
    else:
        verify(data)

if __name__ == '__main__':
    main()
