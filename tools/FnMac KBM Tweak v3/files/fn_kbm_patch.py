#!/usr/bin/env python3
"""Patches your own copy of the Fortnite 43.10 game file for keyboard and mouse.

The changes are listed in game-43.10.diff, next to this script: for each one the
file offset, the bytes the original 43.10 game file has there, and the new bytes.
The list was taken from the tested build of 16 Nov (bundle9). Every change is
checked before anything is written, so any other game version is refused.

What the changes do:
- Mouse and keyboard: the iOS checks that hide the Mouse and Keyboard and the
  Keyboard Controls settings pages pass, the input system reports mouse and
  keyboard support, and the game cannot fall back to touch controls.
- Frame rate: the PC "Frame Rate Limit" row is shown and the engine follows it,
  also in menus. The iPad quality caps tied to 120 fps mode no longer apply.
- Graphics: five hidden PC rows are shown in Video settings, real 16x texture
  filtering, and a hook that asks the tweak before the game applies a setting by
  name (the tweak keeps about 50 built-in values that the iPad profile lowers).
  Optional high-resolution texture bundles are registered.
- Mouse wheel: steps reach menus before the first match, and go to the place
  under the pointer. Short mouse key names (MWU, MWD, MMB, M4, M5).
- The game accepts three larger download cache quotas on its command line;
  make-ipa adds them to uecommandline.txt.

The result must be re-signed (Sideloadly).

Usage:
  fn_kbm_patch.py check <ipa-or-binary>
  fn_kbm_patch.py patch <input.ipa> <output.ipa>
  fn_kbm_patch.py patch-binary <in-binary> <out-binary>
"""
import hashlib, os, shutil, subprocess, sys, tempfile, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
DIFF = os.path.join(HERE, "game-43.10.diff")
CMDLINE_ADD = ["-Iad.FileCache.DiskQuota=6442450944", "-Iad.MMapCache.DiskQuota=3221225472", "-Iad.GfpCache.DiskQuota=2147483648"]


def changes():
    out = []
    for line in open(DIFF):
        if line.startswith("#") or not line.strip():
            continue
        off, old, new = line.split()
        out.append((int(off, 16), bytes.fromhex(old), bytes.fromhex(new)))
    return out


def state(d):
    """'unpatched', 'patched', or a reason the file cannot be used."""
    old = new = 0
    for off, a, b in changes():
        got = d[off:off + len(a)]
        if got == a: old += 1
        elif got == b: new += 1
        else: return f"not the Fortnite 43.10 game file (differs at file offset {off:#x})"
    if new == 0: return "unpatched"
    if old == 0: return "patched"
    return f"partly patched ({new} of {old + new} changes): start again from the original IPA"


def patch_bytes(d):
    s = state(d)
    if s == "patched": return bytes(d), "patched"
    if s != "unpatched": raise SystemExit("STOP: " + s)
    d = bytearray(d)
    for off, a, b in changes():
        d[off:off + len(b)] = b
    assert state(d) == "patched"
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
        s = state(d)
        print(f"game file sha1 {hashlib.sha1(d).hexdigest()}: {s}")
        return 0 if s in ("patched", "unpatched") else 1
    if mode == "patch-binary":
        d, s = patch_bytes(open(src, "rb").read())
        open(argv[3], "wb").write(d); print(s); return 0
    if mode == "patch":
        out = argv[3]
        assert os.path.abspath(out) != os.path.abspath(src)
        with zipfile.ZipFile(src) as z:
            name = binary_in_ipa(z)
            d, s = patch_bytes(z.read(name))
            cname = os.path.dirname(name) + "/uecommandline.txt"
            cmd = z.read(cname).decode("utf-8") if cname in z.namelist() else None
        print(s, "- game file sha1", hashlib.sha1(d).hexdigest())
        shutil.copyfile(src, out)
        with tempfile.TemporaryDirectory() as t:
            p = os.path.join(t, name)
            os.makedirs(os.path.dirname(p))
            open(p, "wb").write(d)
            members = [name]
            if cmd is not None:
                line = cmd.strip()
                for opt in CMDLINE_ADD:
                    if opt.split("=")[0] not in line: line += " " + opt
                open(os.path.join(t, cname), "w").write(line)
                members.append(cname)
            subprocess.run(["zip", "-q", os.path.abspath(out)] + members, cwd=t, check=True)
        with zipfile.ZipFile(out) as z:
            assert state(z.read(name)) == "patched"
        print("wrote", out)
        return 0
    print(__doc__); return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
