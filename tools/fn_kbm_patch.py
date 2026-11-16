#!/usr/bin/env python3
"""Unlock Fortnite iOS's native mouse support on Mac.

The iOS build compiles its "platform supports mouse" check as a stub that
jumps to a shared `mov w0,#0; ret`. This script finds that stub through the
"Platform does not support mouse settings" message that follows it, and
retargets the stub's jump to the shared `mov w0,#1; ret` so the check reads
true. A second four-byte change makes the mouse-and-keyboard settings edit
condition, which always fails on iOS, take its sibling's pass exit instead.
A third change makes the two "is this settings tab shown" functions that
always answer no on iOS (Mouse and Keyboard, Keyboard Bindings) follow the
Game UI tab's console variable instead.
A fifth makes the settings screen's display conditions for the "Mouse and
Keyboard" and "Keyboard Controls" tabs, hard-wired to false on iOS, follow the
Game UI tab's condition.
A sixth makes the edit condition the Mouse and Keyboard page hangs on
(WhenProductSupportsHybridMouseControls, always failing on iOS) pass.
A fourth makes the input platform settings report mouse-and-keyboard support,
so the input subsystem can switch into mouse-and-keyboard mode.
A seventh raises the engine's own frame limit: UEngine::GetMaxTickRate returns
the t.MaxFPS setting when it is above zero, and the iOS game never sets that
above 120. Patched, it returns 1000 in that case (no limit set stays no limit).
The result must be re-signed (Sideloadly).

Usage:
  fn_kbm_patch.py check <ipa-or-binary>
  fn_kbm_patch.py patch <input.ipa> <output.ipa>
  fn_kbm_patch.py patch-binary <in-binary> <out-binary>
"""
import os, shutil, struct, subprocess, sys, tempfile, zipfile

LIT = "Platform does not support mouse settings".encode("utf-16-le")
LIT_MKB = "UFortSettingEditCondition_WhenPlatformSupportsMouseAndKeyboard".encode("utf-16-le")
# Prologue shared by the settings edit-condition functions:
#   sub sp,sp,#0x30 ; stp x20,x19,[sp,#0x10] ; stp x29,x30,[sp,#0x20] ; add x29,sp,#0x20 ; mov x19,x3
# UCommonInputPlatformSettings::SupportsInputType(type) switches over the enum
# and reads bSupportsMouseAndKeyboard (+0x41), bSupportsGamepad (+0x43) or
# bSupportsTouch (+0x42). UCommonInputSubsystem::PlatformSupportsInputType has
# the same switch on w19. In both, the mouse-and-keyboard load becomes mov w8,#1.
SUPPORT_SIGS = [
    # cmp w1,#2 ; b.eq ; cmp w1,#1 ; b.eq ; cbnz w1 ; ldrb w8,[x0,#0x41] ; b ; ldrb w8,[x0,#0x43] ; b ; ldrb w8,[x0,#0x42]
    bytes.fromhex("3f080071000100543f04007180000054e1000035080441390600001408 0c413904000014".replace(" ", "")),
    # cmp w19,#2 ; b.eq ; cmp w19,#1 ; b.eq ; cbnz w19 ; ldrb w8,[x0,#0x41]
    bytes.fromhex("7f0a0071a00200547f06007180000054530a003508044139"),
]
SUPPORT_LDRB_OFF = 0x14
MOV_W8_1 = bytes.fromhex("28008052")  # mov w8,#1


def locate_support(d):
    """Return ([fileoff of the ldrb/mov], state) for the two input-support switches."""
    secs = sections(d)
    ta, ts, tf = secs["__text"]
    text = d[tf:tf + ts]
    offs, states = [], set()
    for sig in SUPPORT_SIGS:
        patched = sig[:SUPPORT_LDRB_OFF] + MOV_W8_1 + sig[SUPPORT_LDRB_OFF + 4:]
        a = [m for m in range(0, 1) for m in [text.find(sig)] if m >= 0]
        b = [m for m in range(0, 1) for m in [text.find(patched)] if m >= 0]
        assert len(a) + len(b) == 1, "input-support switch not found exactly once"
        assert text.find(sig, (a or b)[0] + 4) < 0 and text.find(patched, (a or b)[0] + 4) < 0, "signature not unique"
        offs.append(tf + (a or b)[0] + SUPPORT_LDRB_OFF)
        states.add("unpatched" if a else "patched")
    assert len(states) == 1, "support switches in mixed state"
    return offs, states.pop()


PROLOGUE = bytes.fromhex("ff c3 00 d1 f4 4f 01 a9 fd 7b 02 a9 fd 83 00 91 f3 03 03 aa".replace(" ", ""))
RET_FALSE = bytes.fromhex("00008052c0035fd6")  # mov w0,#0 ; ret
RET_TRUE = bytes.fromhex("20008052c0035fd6")   # mov w0,#1 ; ret


def sections(d):
    assert struct.unpack_from("<I", d, 0)[0] == 0xFEEDFACF, "not a 64-bit Mach-O"
    ncmds = struct.unpack_from("<I", d, 16)[0]
    off, out = 32, {}
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", d, off)
        if cmd == 0x19:
            nsects = struct.unpack_from("<I", d, off + 64)[0]
            so = off + 72
            for _ in range(nsects):
                name = d[so:so + 16].rstrip(b"\0").decode()
                addr, size, foff = struct.unpack_from("<QQI", d, so + 32)
                out[name] = (addr, size, foff)
                so += 80
        off += sz
    return out


def b_target(word, pc):
    if word & 0xFC000000 not in (0x14000000, 0x94000000):
        return None
    imm = word & 0x3FFFFFF
    if imm & (1 << 25):
        imm -= 1 << 26
    return pc + imm * 4


def enc_b(pc, target):
    imm = (target - pc) // 4
    assert -(1 << 25) <= imm < (1 << 25)
    return struct.pack("<I", 0x14000000 | (imm & 0x3FFFFFF))


def literal_sites(d, lit_bytes):
    """Code sites (adrp pc) that take the address of a __ustring literal."""
    secs = sections(d)
    ta, ts, tf = secs["__text"]
    ua, us, uf = secs["__ustring"]
    i = d.find(lit_bytes, uf, uf + us)
    assert i >= 0, "message literal not found; different build"
    lit = ua + (i - uf)
    page, lo = lit & ~0xFFF, lit & 0xFFF
    text = d[tf:tf + ts]
    sites = []
    for k in range(0, ts - 4, 4):
        w = struct.unpack_from("<I", text, k)[0]
        if (w & 0x9F000000) != 0x90000000:
            continue
        imm = (((w >> 5) & 0x7FFFF) << 2) | ((w >> 29) & 3)
        if imm & (1 << 20):
            imm -= 1 << 21
        pc = ta + k
        if (pc & ~0xFFF) + (imm << 12) != page:
            continue
        w2 = struct.unpack_from("<I", text, k + 4)[0]
        if (w2 & 0xFF800000) == 0x91000000 and ((w2 >> 10) & 0xFFF) == lo:
            sites.append(pc)
    return sites, ta, tf, text


def locate(d):
    """Return (stub_fileoff, stub_vmaddr, true_stub_vmaddr, state)."""
    sites, ta, tf, text = literal_sites(d, LIT)
    assert len(sites) == 1, f"expected one message site, found {len(sites)}"
    site = sites[0]
    # Expected shape:  bl <check> ; tbnz w0,#0,skip ; adrp ; add ; (log error)
    tbnz = struct.unpack_from("<I", text, site - ta - 4)[0]
    bl = struct.unpack_from("<I", text, site - ta - 8)[0]
    assert (tbnz & 0xFF00001F) == 0x37000000, "no tbnz w0 before message"
    check = b_target(bl, site - 8)
    assert check and (bl & 0xFC000000) == 0x94000000, "no bl before tbnz"
    cw = struct.unpack_from("<I", text, check - ta)[0]
    tgt = b_target(cw, check)
    assert tgt and (cw & 0xFC000000) == 0x14000000, "check is not a one-jump stub"
    stub_bytes = d[tf + (tgt - ta):tf + (tgt - ta) + 8]
    if stub_bytes == RET_FALSE:
        state = "unpatched"
    elif stub_bytes == RET_TRUE:
        state = "patched"
    else:
        raise AssertionError("stub jumps to unknown code")
    j = text.find(RET_TRUE)
    while j != -1 and j % 4:
        j = text.find(RET_TRUE, j + 1)
    assert j != -1, "no mov w0,#1; ret in __text"
    return tf + (check - ta), check, ta + j, state


def locate_mkb(d):
    """The mouse-and-keyboard settings edit condition always fails on iOS: its
    body builds the failure text right after the prologue. Return
    (adrp_fileoff, adrp_pc, pass_epilogue_pc, state). The pass epilogue is the
    tbnz target of the sibling mouse-settings condition, same frame layout."""
    sites, ta, tf, text = literal_sites(d, LIT)
    assert len(sites) == 1
    tbnz = struct.unpack_from("<I", text, sites[0] - ta - 4)[0]
    imm14 = (tbnz >> 5) & 0x3FFF
    if imm14 & (1 << 13):
        imm14 -= 1 << 14
    epilogue = sites[0] - 4 + imm14 * 4
    ep = text[epilogue - ta:epilogue - ta + 8]
    assert ep[:4] == bytes.fromhex("fd7b42a9"), "pass epilogue is not ldp x29,x30,[sp,#0x20]"
    assert (struct.unpack_from("<I", ep, 4)[0] & 0xFC000000) == 0x14000000, "pass epilogue does not tail-jump"
    assert text[sites[0] - ta - 0x1C:sites[0] - ta - 8] == PROLOGUE, "mouse condition prologue differs"
    msites, _, _, _ = literal_sites(d, LIT_MKB)
    if not msites:
        # Already patched: the adrp became a jump to the epilogue. Find it by
        # the prologue before it and the untouched `add x1,x1,#lo` after it.
        secs = sections(d)
        ua, us, uf = secs["__ustring"]
        lo = (ua + (d.find(LIT_MKB, uf, uf + us) - uf)) & 0xFFF
        add = 0x91000021 | (lo << 10)
        for k in range(0x14, len(text) - 8, 4):
            w = struct.unpack_from("<I", text, k)[0]
            if (w & 0xFC000000) == 0x14000000 and b_target(w, ta + k) == epilogue \
                    and struct.unpack_from("<I", text, k + 4)[0] == add \
                    and text[k - 0x14:k] == PROLOGUE:
                return tf + k, ta + k, epilogue, "patched"
        raise AssertionError("keyboard condition site not found")
    assert len(msites) == 1, f"expected one keyboard-condition site, found {len(msites)}"
    site = msites[0]
    k = site - ta
    w = struct.unpack_from("<I", text, k)[0]
    assert text[k - 0x14:k] == PROLOGUE, "keyboard condition prologue differs"
    assert (w & 0x9F000000) == 0x90000000, "keyboard condition site is not adrp"
    return tf + k, site, epilogue, "unpatched"


TAG_GAMEUI = "OptionsMenu.DisplayTabs.AllowGameUITab".encode("utf-16-le")
MOV_X0_X30 = bytes.fromhex("e0031eaa")
MOV_X30_X0 = bytes.fromhex("fe0300aa")
STRB_WZR_X2 = bytes.fromhex("5f000039")
RET = bytes.fromhex("c0035fd6")


def gameui_cvar_addr(d):
    """Address of the bool behind the OptionsMenu.DisplayTabs.AllowGameUITab
    console variable, read from its registration: adrp/add x2 <name> ...
    add x3, x20, #k, with x20 set by an earlier adrp/add."""
    sites, ta, tf, text = literal_sites(d, TAG_GAMEUI)
    assert len(sites) == 1, f"expected one AllowGameUITab site, found {len(sites)}"
    i = (sites[0] - ta) // 4
    k = None
    for j in range(i, i + 6):
        w = struct.unpack_from("<I", text, j * 4)[0]
        if (w & 0xFFC003FF) == 0x91000283:  # add x3, x20, #imm
            k = (w >> 10) & 0xFFF
            break
        if w == 0xAA1403E3:  # mov x3, x20
            k = 0
            break
    assert k is not None, "no add x3,x20 after AllowGameUITab"
    for j in range(i, max(i - 200, 0), -1):
        w = struct.unpack_from("<I", text, j * 4)[0]
        if (w & 0x9F00001F) == 0x90000014:  # adrp x20
            imm = (((w >> 5) & 0x7FFFF) << 2) | ((w >> 29) & 3)
            if imm & (1 << 20):
                imm -= 1 << 21
            w2 = struct.unpack_from("<I", text, j * 4 + 4)[0]
            assert (w2 & 0xFFC003FF) == 0x91000294, "adrp x20 not followed by add x20"
            return ((ta + j * 4) & ~0xFFF) + (imm << 12) + ((w2 >> 10) & 0xFFF) + k
    raise AssertionError("no adrp x20 before AllowGameUITab")


def locate_tabs(d):
    """Each settings tab has a small native "is this tab shown" function. Most
    return their OptionsMenu.DisplayTabs console variable. Two are compiled to
    return false on iOS (the Mouse and Keyboard tab and the Keyboard Bindings
    tab). They sit right after the Game UI tab's function:
        mov x0,x30 ; bl ; mov x30,x0 ; adrp x8 ; ldrb w8,[x8,#gameui] ; b store   (Game UI)
        b <thunk>
        mov x0,x30 ; bl ; mov x30,x0 ; strb wzr,[x2] ; ret                       (false)
        b <thunk>
        mov x0,x30 ; bl ; mov x30,x0 ; strb wzr,[x2] ; ret                       (false)
    Patched, each `strb wzr,[x2]` is a jump to the Game UI function's adrp, so
    the tab shows whenever the Game UI tab does.
    Return ([(fileoff, pc)], reader_pc, state)."""
    secs = sections(d)
    ta, ts, tf = secs["__text"]
    text = d[tf:tf + ts]
    gameui = gameui_cvar_addr(d)
    found = []
    pos = 0
    while True:
        k = text.find(MOV_X30_X0 + STRB_WZR_X2 + RET, pos)
        if k < 0:
            break
        pos = k + 4
        if k % 4 or text[k - 8:k - 4] != MOV_X0_X30:
            continue
        found.append(k - 8)
    def reader_ok(h):
        r = h - 0x1C
        if text[r:r + 4] != MOV_X0_X30 or text[r + 8:r + 12] != MOV_X30_X0:
            return False
        w = struct.unpack_from("<I", text, r + 12)[0]
        w2 = struct.unpack_from("<I", text, r + 16)[0]
        if (w & 0x9F00001F) != 0x90000008 or (w2 & 0xFFC003FF) != 0x39400108:
            return False
        imm = (((w >> 5) & 0x7FFFF) << 2) | ((w >> 29) & 3)
        if imm & (1 << 20):
            imm -= 1 << 21
        return ((ta + r + 12) & ~0xFFF) + (imm << 12) + ((w2 >> 10) & 0xFFF) == gameui
    pairs = [h for h in found if h + 0x18 in found and reader_ok(h)]
    if pairs:
        assert len(pairs) == 1, f"expected one pair of always-false tab functions, found {len(pairs)}"
        h = pairs[0]
        return [(tf + h + 12, ta + h + 12), (tf + h + 0x18 + 12, ta + h + 0x18 + 12)], ta + h - 0x10, "unpatched"
    # Patched: look for the Game UI reader followed by two functions whose 4th instruction jumps to its adrp.
    for r in range(0, len(text) - 0x50, 4):
        if text[r:r + 4] != MOV_X0_X30 or text[r + 8:r + 12] != MOV_X30_X0:
            continue
        h = r + 0x1C
        if text[h:h + 4] != MOV_X0_X30 or text[h + 8:h + 12] != MOV_X30_X0 or text[h + 16:h + 20] != RET:
            continue
        if not reader_ok(h):
            continue
        tgt = ta + r + 12
        ok = all(b_target(struct.unpack_from("<I", text, x + 12)[0], ta + x + 12) == tgt and
                 (struct.unpack_from("<I", text, x + 12)[0] & 0xFC000000) == 0x14000000 for x in (h, h + 0x18))
        if ok:
            return [(tf + h + 12, ta + h + 12), (tf + h + 0x18 + 12, ta + h + 0x18 + 12)], tgt, "patched"
    raise AssertionError("tab visibility functions not found")


def locate_tabconditions(d):
    """The settings screen shows a tab when the tab's display condition says so
    (USettingsTabDisplayCondition_Legacy...TabCondition::IsConditionMet). Most
    of these functions are three instructions that return the tab's console
    variable (Settings.LegacyTabConditions.Allow...Tab):
        adrp x8,<page> ; ldrb w0,[x8,#var] ; ret
    The ones for the Mouse and Keyboard tab and the Keyboard Controls tab are
    instead a single jump to a shared `mov w0,#0 ; ret`, and their variables are
    never read. They sit among the others. Patched, each jumps to the Game UI
    tab's function (the second reader), so the tab shows whenever Game UI does.
    Return ([(fileoff, pc)], target_pc, state)."""
    secs = sections(d)
    ta, ts, tf = secs["__text"]
    text = d[tf:tf + ts]
    def reader(k):          # -> (page, var offset) for a 3-instruction reader at text offset k
        w, w1, w2 = struct.unpack_from("<III", text, k)
        if (w & 0x9F00001F) != 0x90000008 or (w1 & 0xFFC003FF) != 0x39400100 or w2 != 0xD65F03C0:
            return None
        imm = (((w >> 5) & 0x7FFFF) << 2) | ((w >> 29) & 3)
        if imm & (1 << 20):
            imm -= 1 << 21
        return ((ta + k) & ~0xFFF) + (imm << 12), (w1 >> 10) & 0xFFF
    # Candidate clusters: three readers in a row with consecutive variables on one
    # page. Several exist in the game; the right one is followed, within the same
    # group of functions, by exactly two functions that are one jump to "false".
    def sites_after(start):
        target = ta + start + 12                  # Game UI: the second reader
        sites, patched = [], 0
        for k in range(start + 36, start + 0x300, 4):
            w, prev = struct.unpack_from("<I", text, k)[0], struct.unpack_from("<I", text, k - 4)[0]
            if (w & 0xFC000000) != 0x14000000:
                continue
            if prev != 0xD65F03C0 and (prev & 0xFC000000) != 0x14000000:   # first instruction of a function
                continue
            t = b_target(w, ta + k)
            if t == target:
                sites.append(k); patched += 1
            elif ta <= t < ta + ts and text[t - ta:t - ta + 8] == RET_FALSE:
                sites.append(k)
        return target, sites, patched
    found = []
    for k in range(0, ts - 0x340, 4):
        a = reader(k)
        if not a:
            continue
        b, c = reader(k + 12), reader(k + 24)
        if not (b and c and a[0] == b[0] == c[0] and b[1] == a[1] + 1 and c[1] == a[1] + 2):
            continue
        if reader(k - 12):                         # not the start of the run
            continue
        target, sites, patched = sites_after(k)
        if len(sites) == 2 and patched in (0, 2):
            found.append((target, sites, patched))
    assert len(found) == 1, f"expected one tab condition group, found {len(found)}"
    target, sites, patched = found[0]
    return [(tf + k, ta + k) for k in sites], target, "patched" if patched else "unpatched"


LIT_HYBRID = "Product does not support hybrid mouse controls".encode("utf-16-le") + b"\0\0"


def locate_hybrid(d):
    """The whole Mouse and Keyboard settings page hangs on the edit condition
    WhenProductSupportsHybridMouseControls. On iOS its body is unconditional:
    right after the prologue it builds "Product does not support hybrid mouse
    controls" and kills the setting, so the page is empty and its tab is not
    shown. Patched, the first body instruction (the adrp for that text) is a
    jump to the function's own epilogue. Return (fileoff, pc, epilogue_pc, state)."""
    secs = sections(d)
    ta, ts, tf = secs["__text"]
    ua, us, uf = secs["__ustring"]
    text = d[tf:tf + ts]
    i = d.find(LIT_HYBRID, uf, uf + us)
    assert i >= 0, "hybrid mouse message not found; different build"
    lo = (ua + (i - uf)) & 0xFFF
    def epilogue_after(k):
        for j in range(k, k + 0x40, 4):
            if text[j:j + 4] == bytes.fromhex("fd7b42a9") and (struct.unpack_from("<I", text, j + 4)[0] & 0xFC000000) == 0x14000000:
                return j
        raise AssertionError("hybrid condition epilogue not found")
    sites, _, _, _ = literal_sites(d, LIT_HYBRID)
    if sites:
        assert len(sites) == 1, f"expected one hybrid-condition site, found {len(sites)}"
        k = sites[0] - ta
        assert text[k - 0x14:k] == PROLOGUE, "hybrid condition prologue differs"
        return tf + k, ta + k, ta + epilogue_after(k), "unpatched"
    add = 0x91000021 | (lo << 10)
    for k in range(0x14, len(text) - 8, 4):
        w = struct.unpack_from("<I", text, k)[0]
        if (w & 0xFC000000) == 0x14000000 and struct.unpack_from("<I", text, k + 4)[0] == add and text[k - 0x14:k] == PROLOGUE:
            e = epilogue_after(k)
            if b_target(w, ta + k) == ta + e:
                return tf + k, ta + k, ta + e, "patched"
    raise AssertionError("hybrid condition site not found")


LIT_PLATFORM_HYBRID = "Hybrid mouse controls are not allowed".encode("utf-16-le") + b"\0\0"


def locate_platform_hybrid(d):
    """WhenPlatformSupportsHybridMouseControls does a runtime check and logs
    'Hybrid mouse controls are not allowed' on failure. The function's structure is
    PROLOGUE + BL check + TBNZ W0,#0,success + ADRP error_string + ... + epilogue.
    The TBNZ branches to the success epilogue when the check passes.
    Patched, the TBNZ becomes an unconditional B to the same target.
    Return (fileoff, tbnz_pc, epilogue_pc, state)."""
    sites, ta, tf, text = literal_sites(d, LIT_PLATFORM_HYBRID)
    assert len(sites) == 1, f"expected one platform-hybrid-condition site, found {len(sites)}"
    site = sites[0]  # VA of ADRP loading the error string
    k = site - ta
    w = struct.unpack_from("<I", text, k - 4)[0]
    if (w & 0xFF000000) == 0x37000000:  # TBNZ
        imm14 = (w >> 5) & 0x3FFF
        if imm14 & (1 << 13):
            imm14 -= 1 << 14
        ep_pc = (site - 4) + imm14 * 4
        return tf + k - 4, site - 4, ep_pc, "unpatched"
    elif (w & 0xFC000000) == 0x14000000:  # B (already patched)
        ep_pc = b_target(w, site - 4)
        return tf + k - 4, site - 4, ep_pc, "patched"
    raise AssertionError(f"unexpected instruction at platform hybrid TBNZ site: {w:#010x}")


EXCL_MSG = b"Excluding input setting"  # UTF-8 C string in __cstring


def locate_keybind_apply(d):
    """The keybinding apply loop filters out input settings that require platform
    traits not present on this platform (e.g. Input.SupportsHybridMouseControls).
    It logs 'Excluding input setting ...' and skips the binding. The filter gate
    is a 'b.hi <apply>' conditional branch: if 'higher' (traits satisfied), jump
    to apply; otherwise fall through to the exclusion log. Patched, the branch
    becomes unconditional so all KBM bindings are applied regardless of traits.
    Return (fileoff, br_pc, apply_pc, state)."""
    secs = sections(d)
    ta, ts, tf = secs["__text"]
    ca, cs, cf = secs["__cstring"]
    text = d[tf:tf + ts]

    i = d.find(EXCL_MSG, cf, cf + cs)
    assert i >= 0, "exclusion-message string not found in __cstring; different build"
    # Walk back to the C string start: ADRP references the start, not a substring.
    j = i - 1
    while j >= cf and d[j] != 0:
        j -= 1
    j += 1
    lit = ca + (j - cf)
    page, lo = lit & ~0xFFF, lit & 0xFFF

    sites = []
    for k in range(0, ts - 4, 4):
        w = struct.unpack_from("<I", text, k)[0]
        if (w & 0x9F000000) != 0x90000000:
            continue
        imm = (((w >> 5) & 0x7FFFF) << 2) | ((w >> 29) & 3)
        if imm & (1 << 20):
            imm -= 1 << 21
        pc = ta + k
        if (pc & ~0xFFF) + (imm << 12) != page:
            continue
        w2 = struct.unpack_from("<I", text, k + 4)[0]
        if (w2 & 0xFF800000) == 0x91000000 and ((w2 >> 10) & 0xFFF) == lo:
            sites.append(k)
    assert len(sites) == 1, f"expected one exclusion-msg site, found {len(sites)}"
    k = sites[0]

    for j in range(k - 4, k - 0x60, -4):
        w = struct.unpack_from("<I", text, j)[0]
        if (w >> 24) == 0x54:  # B.cond
            imm19 = (w >> 5) & 0x7FFFF
            if imm19 & (1 << 18):
                imm19 -= 1 << 19
            ep_pc = ta + j + imm19 * 4
            assert ep_pc > ta + j, "keybind apply branch is not forward"
            return tf + j, ta + j, ep_pc, "unpatched"
        if (w & 0xFC000000) == 0x14000000:  # B (already patched)
            ep_pc = b_target(w, ta + j)
            if ep_pc > ta + j:
                return tf + j, ta + j, ep_pc, "patched"
    raise AssertionError("keybind apply conditional branch not found before exclusion message")


FPS_LIMIT = 1000.0
# Tail of UEngine::GetMaxTickRate, unpatched (W = don't care bits):
#   bl GetValue ; fcmp s0,#0.0 ; b.le <no limit> ; adrp x0,CVarMaxFPS ; add x0,.. ; mov w1,#0 ;
#   ldp x29,x30,[sp,#0x20] ; ldp x20,x19,[sp,#0x10] ; ldp d9,d8,[sp],#0x30 ; b GetValue
FPS_FCMP = 0x1E202008
FPS_EPILOGUE = (0xA9427BFD, 0xA9414FF4, 0x6CC323E9)
FPS_RET = 0xD65F03C0


def fps_patch_words():
    bits = struct.unpack("<I", struct.pack("<f", FPS_LIMIT))[0]
    assert bits & 0xFFFF == 0, "limit must be a float whose low 16 bits are zero"
    movz = 0x52A00000 | ((bits >> 16) << 5) | 8          # mov w8,#<float bits>
    fmov = 0x1E270100                                    # fmov s0,w8
    return (movz, fmov) + FPS_EPILOGUE + (FPS_RET,)


def locate_fpslimit(d):
    """Return (fileoff, pc, state) of the six instructions after the b.le."""
    secs = sections(d)
    ta, ts, tf = secs["__text"]
    text = d[tf:tf + ts]
    new = fps_patch_words()
    found = []
    k = text.find(struct.pack("<I", FPS_FCMP))
    while k >= 0:
        if k % 4 == 0 and 0x10 <= k < len(text) - 0x24:
            w = struct.unpack_from("<12I", text, k - 4)   # bl, fcmp, b.le, then seven words
            bl, ble, body = w[0], w[2], w[3:10]
            if (bl & 0xFC000000) == 0x94000000 and (ble & 0xFF00001F) == 0x5400000D:
                callee = b_target(bl, ta + k - 4)
                tail_ok = (body[6] & 0xFC000000) == 0x14000000 and b_target(body[6], ta + k + 0x20) == callee
                if (body[0] & 0x9F00001F) == 0x90000000 and (body[1] & 0xFFC003FF) == 0x91000000 and body[2] == 0x52800001 \
                        and body[3:6] == FPS_EPILOGUE and tail_ok:
                    found.append((k + 8, "unpatched"))
                elif body[:6] == new and tail_ok:
                    found.append((k + 8, "patched"))
        k = text.find(struct.pack("<I", FPS_FCMP), k + 1)
    assert len(found) == 1, f"expected one frame limit site, found {len(found)}"
    k, state = found[0]
    return tf + k, ta + k, state


def patch_bytes(d):
    off, pc, true_stub, state = locate(d)
    off2, pc2, epilogue, state2 = locate_mkb(d)
    tabs, reader, state3 = locate_tabs(d)
    soffs, state4 = locate_support(d)
    conds, ctarget, state5 = locate_tabconditions(d)
    hoff, hpc, hep, state6 = locate_hybrid(d)
    foff, fpc, state7 = locate_fpslimit(d)
    phoff, phppc, phpep, state8 = locate_platform_hybrid(d)
    kaoff, kapc, kaep, state9 = locate_keybind_apply(d)
    if state == "patched" and state2 == "patched" and state3 == "patched" and state4 == "patched" and state5 == "patched" and state6 == "patched" and state7 == "patched" and state8 == "patched" and state9 == "patched":
        return d, "patched"
    d = bytearray(d)
    d[foff:foff + 24] = struct.pack("<6I", *fps_patch_words())
    d[hoff:hoff + 4] = enc_b(hpc, hep)
    d[phoff:phoff + 4] = enc_b(phppc, phpep)
    d[kaoff:kaoff + 4] = enc_b(kapc, kaep)
    for coff, cpc in conds:
        d[coff:coff + 4] = enc_b(cpc, ctarget)
    for so in soffs:
        d[so:so + 4] = MOV_W8_1
    d[off:off + 4] = enc_b(pc, true_stub)
    d[off2:off2 + 4] = enc_b(pc2, epilogue)
    for toff, tpc in tabs:
        d[toff:toff + 4] = enc_b(tpc, reader)
    assert locate(bytes(d))[3] == "patched" and locate_mkb(bytes(d))[3] == "patched" and locate_tabs(bytes(d))[2] == "patched"
    assert locate_support(bytes(d))[1] == "patched" and locate_tabconditions(bytes(d))[2] == "patched"
    assert locate_hybrid(bytes(d))[3] == "patched" and locate_fpslimit(bytes(d))[2] == "patched"
    assert locate_platform_hybrid(bytes(d))[3] == "patched"
    assert locate_keybind_apply(bytes(d))[3] == "patched"
    return bytes(d), "patched now"


def binary_in_ipa(z):
    names = [n for n in z.namelist() if n.endswith("/FortniteClient-IOS-Shipping") and n.count("/") == 2]
    assert len(names) == 1, names
    return names[0]


def main(argv):
    if len(argv) < 3:
        print(__doc__); return 2
    mode, src = argv[1], argv[2]
    if mode == "check":
        if src.endswith(".ipa"):
            with zipfile.ZipFile(src) as z:
                d = z.read(binary_in_ipa(z))
        else:
            d = open(src, "rb").read()
        off, pc, ts, state = locate(d)
        print(f"mouse check stub at {pc:#x} (file {off:#x}), true stub {ts:#x}: {state}")
        off2, pc2, ep, state2 = locate_mkb(d)
        print(f"keyboard settings condition at {pc2:#x} (file {off2:#x}), pass epilogue {ep:#x}: {state2}")
        tabs, reader, state3 = locate_tabs(d)
        print(f"tab visibility functions at {[hex(t[1]) for t in tabs]}, follow Game UI tab at {reader:#x}: {state3}")
        conds, ctarget, state5 = locate_tabconditions(d)
        print(f"tab display conditions at {[hex(c[1]) for c in conds]}, follow Game UI condition at {ctarget:#x}: {state5}")
        hoff, hpc, hep, state6 = locate_hybrid(d)
        print(f"mouse page condition at {hpc:#x}, pass epilogue {hep:#x}: {state6}")
        phoff, phppc, phpep, state8 = locate_platform_hybrid(d)
        print(f"platform hybrid condition at {phppc:#x} (file {phoff:#x}), epilogue {phpep:#x}: {state8}")
        soffs, state4 = locate_support(d)
        print(f"input-support switches at file {[hex(o) for o in soffs]}: {state4}")
        foff, fpc, state7 = locate_fpslimit(d)
        print(f"engine frame limit at {fpc:#x} (file {foff:#x}), raised to {FPS_LIMIT:g}: {state7}")
        kaoff, kapc, kaep, state9 = locate_keybind_apply(d)
        print(f"keybind apply filter at {kapc:#x} (file {kaoff:#x}), apply target {kaep:#x}: {state9}")
        return 0
    if mode == "patch-binary":
        d, state = patch_bytes(open(src, "rb").read())
        open(argv[3], "wb").write(d); print(state); return 0
    if mode == "patch":
        out = argv[3]
        assert os.path.abspath(out) != os.path.abspath(src)
        with zipfile.ZipFile(src) as z:
            name = binary_in_ipa(z)
            d, state = patch_bytes(z.read(name))
        print(state)
        shutil.copyfile(src, out)
        with tempfile.TemporaryDirectory() as t:
            p = os.path.join(t, name)
            os.makedirs(os.path.dirname(p))
            open(p, "wb").write(d)
            subprocess.run(["zip", "-q", os.path.abspath(out), name], cwd=t, check=True)
        with zipfile.ZipFile(out) as z:
            b = z.read(name)
            assert locate(b)[3] == "patched" and locate_mkb(b)[3] == "patched" and locate_tabs(b)[2] == "patched" and locate_support(b)[1] == "patched"
            assert locate_tabconditions(b)[2] == "patched" and locate_hybrid(b)[3] == "patched" and locate_fpslimit(b)[2] == "patched"
            assert locate_platform_hybrid(b)[3] == "patched" and locate_keybind_apply(b)[3] == "patched"
        print("wrote", out)
        return 0
    print(__doc__); return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
