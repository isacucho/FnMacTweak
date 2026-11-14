import lldb, re, os

LOG_PATH = os.path.expanduser(
    "~/Library/Containers/0F16E856-1C80-4448-9C65-ED3A8E8DA5E9"
    "/Data/Documents/FnDiag.log"
)

def _read_log_for_pid(pid):
    lines = []
    try:
        with open(LOG_PATH) as f:
            for line in f:
                if f" [{pid}] " in line:
                    lines.append(line.rstrip())
    except OSError:
        pass
    return lines

def audit(debugger, command, result, internal_dict):
    target = debugger.GetSelectedTarget()
    process = target.GetProcess()
    pid = process.GetProcessID()
    result.AppendMessage(f"=== LLDB AUDIT PID={pid} ===")

    # Slide from image list
    slide = None
    ret = lldb.SBCommandReturnObject()
    debugger.GetCommandInterpreter().HandleCommand(
        "image list -o -f FortniteClient-IOS-Shipping", ret
    )
    if ret.Succeeded():
        m = re.search(r'\[\s*\d+\s*\]\s+0x([0-9a-fA-F]+)', ret.GetOutput())
        if m:
            slide = int(m.group(1), 16)
    if slide is None:
        result.AppendMessage("ERROR: could not read slide from image list")
        return
    base = 0x100000000 + slide
    result.AppendMessage(f"slide=0x{slide:x}  base=0x{base:x}")

    log_lines = _read_log_for_pid(pid)
    result.AppendMessage(f"Log lines for PID {pid}: {len(log_lines)}")

    # 1. BNF slot from log
    error = lldb.SBError()
    slot_va = None
    for line in log_lines:
        m = re.search(r'slot=(0x[0-9a-fA-F]+)', line)
        if m:
            slot_va = int(m.group(1), 16)
    if slot_va:
        slot_val = process.ReadUnsignedFromMemory(slot_va, 8, error)
        if error.Success():
            armed = slot_val != 0
            result.AppendMessage(f"BNF slot @ 0x{slot_va:x} = 0x{slot_val:x}  -> {'ARMED OK' if armed else 'NOT ARMED!'}")
        else:
            result.AppendMessage(f"BNF slot read error: {error}")
    else:
        result.AppendMessage("BNF slot: not in log yet (island not fired; expect after first ConnectionLost)")

    # 2. BL caller -> island (verify 6 callers at runtime)
    result.AppendMessage("\nBL callers (file offset -> VA at runtime):")
    BL_PATCHES = [
        (0x00f2f6d4, bytes.fromhex('bb4cc397')),
        (0x01187b28, bytes.fromhex('a6ebb997')),
        (0x01644d28, bytes.fromhex('26f7a697')),
        (0x0554dad4, bytes.fromhex('bbd3aa96')),
        (0x055512f0, bytes.fromhex('b4c5aa96')),
        (0x05c2d0c0, bytes.fromhex('40568f96')),
    ]
    island_va = base + 0x29c0
    ok_count = 0
    for fo, expected_bl in BL_PATCHES:
        va = base + fo
        val = process.ReadUnsignedFromMemory(va, 4, error)
        if error.Success():
            cur = val.to_bytes(4, 'little')
            if cur == expected_bl:
                ok_count += 1
                result.AppendMessage(f"  0x{fo:08x}: {cur.hex()} OK (->island 0x{island_va:x})")
            else:
                result.AppendMessage(f"  0x{fo:08x}: {cur.hex()} FAIL (expected {expected_bl.hex()})")
        else:
            result.AppendMessage(f"  0x{fo:08x}: read error")
    result.AppendMessage(f"BL callers patched: {ok_count}/6")

    # 3. ValidationPatch vtable entries (43.10)
    for name, off in [("vtable1_r10", 0xce5ad38), ("vtable2_r6", 0xce5acd8)]:
        va = base + off
        val = process.ReadUnsignedFromMemory(va, 8, error)
        if error.Success():
            in_dylib = val > 0x110000000
            result.AppendMessage(f"ValidationPatch {name} @ 0x{va:x} -> 0x{val:x}  {'OK' if in_dylib else 'UNEXPECTED'}")
        else:
            result.AppendMessage(f"ValidationPatch {name}: read error")

    # 4. KickBypass first entry (43.10)
    va = base + 0xce7d390
    val = process.ReadUnsignedFromMemory(va, 8, error)
    if error.Success():
        in_dylib = val > 0x110000000
        result.AppendMessage(f"KickBypass vtable[0] @ 0x{va:x} -> 0x{val:x}  {'OK' if in_dylib else 'UNEXPECTED'}")
    else:
        result.AppendMessage(f"KickBypass: read error")

    # 5. EAC interceptor
    interceptor = next((l for l in log_lines if "(interceptor installed)" in l), None)
    result.AppendMessage(f"EAC interceptor: {'ACTIVE' if interceptor else 'NOT FOUND (EAC hook not firing)'}")

    # 6. Recent kick/BNF events
    kick_lines = [l for l in log_lines if any(k in l for k in
        ["KickBypass", "NetFailurePatch", "ConnectionLost", "ConnectionTimeout", "synthetic"])]
    result.AppendMessage(f"\nRecent kick/BNF events ({len(kick_lines)} total):")
    for l in kick_lines[-15:]:
        result.AppendMessage("  " + l.split("] ", 2)[-1])

    result.AppendMessage(f"\n{'='*20}")
    result.AppendMessage(f"SUMMARY: BL callers {ok_count}/6 | BNF slot {'armed' if slot_va else 'pending'} | EAC {'OK' if interceptor else 'missing'}")
    result.AppendMessage("=== AUDIT DONE ===")


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand('command script add -f lldb_audit.audit audit_fn')
    debugger.HandleCommand('audit_fn')
