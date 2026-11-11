"""
lldb_diag.py - Diagnóstico del crash silencioso a ~2s post-kick.

Uso (desde terminal, sin sudo):
  lldb -n FortniteClient-IOS-Shipping \
       --source /Users/alexg/Documents/Dev/Fortnite/FnMac/FnMacUpdateFix/tools/diag.lldb

O dentro de LLDB ya adjunto:
  (lldb) command script import tools/lldb_diag.py
  (lldb) diag_start
"""

import lldb
import time

# Callback: 3 params (frame, bp_loc, internal_dict) - API LLDB correcta
def on_bp_hit(frame, bp_loc, internal_dict):
    thread = frame.GetThread()
    process = thread.GetProcess()
    pid    = process.GetProcessID()
    ts     = time.strftime('%H:%M:%S')
    bp_id  = bp_loc.GetBreakpoint().GetID() if bp_loc else "?"

    print(f"\n=== [lldb_diag] STOP ts={ts} pid={pid} bp={bp_id} ===")
    print(f"Thread #{thread.GetIndexID()} stop_reason: {thread.GetStopDescription(512)}")

    # Backtrace del hilo que disparó el BP
    for i, fr in enumerate(thread):
        print(f"  #{i:2d} {fr}")

    # Registros del frame 0 del hilo parado
    regs = frame.GetRegisters()
    for reg_set in regs:
        if "General" in reg_set.GetName():
            print(f"\nRegisters ({reg_set.GetName()}):")
            for reg in reg_set:
                v = reg.GetValue()
                if v:
                    print(f"  {reg.GetName():8s} = {v}")
            break

    # Hilo extra si es crash
    stop_reason = thread.GetStopReason()
    if stop_reason in (lldb.eStopReasonSignal, lldb.eStopReasonException):
        print("\n--- All threads ---")
        for t in process:
            if t.GetIndexID() == thread.GetIndexID():
                continue
            print(f"  Thread #{t.GetIndexID()} {t.GetName()}")
            for i, fr in enumerate(t):
                if i >= 8:
                    print(f"    ... (+{len(t)-8} frames)")
                    break
                print(f"    #{i:2d} {fr}")

    return False  # no parar (continua el proceso), salvo señal grave


def diag_start(debugger, command, result, internal_dict):
    target  = debugger.GetSelectedTarget()
    process = target.GetProcess()

    print("[lldb_diag] Setting up signal intercepts and breakpoints...")

    # Interceptar señales capturables (SIGKILL=9 NO es interceptable)
    for sig in ("SIGSEGV", "SIGBUS", "SIGABRT", "SIGILL", "SIGTERM"):
        debugger.HandleCommand(f"process handle {sig} -s true -n true -p false")

    # BP1: abort() - el juego lo llamó internamente
    bp1 = target.BreakpointCreateByName("abort")
    bp1.SetScriptCallbackFunction("lldb_diag.on_bp_hit")
    bp1.SetEnabled(True)
    print(f"[lldb_diag] BP1 abort: id={bp1.GetID()} locations={bp1.GetNumLocations()}")

    # BP2: trigger_silent_lobby_return (sólo se llama si el cap de 3s dispara)
    bp2 = target.BreakpointCreateByName(
        "_ZN6fndiag27trigger_silent_lobby_returnEv")
    bp2.SetScriptCallbackFunction("lldb_diag.on_bp_hit")
    bp2.SetEnabled(True)
    print(f"[lldb_diag] BP2 trigger_silent: id={bp2.GetID()} locations={bp2.GetNumLocations()}")

    # BP3: bnf_bypass_stub - salta los primeros 100 hits (~800ms),
    #      vuelca el 101 (ya en la zona crítica ~800ms) y se autodestruye
    bp3 = target.BreakpointCreateByName(
        "_ZN6fndiagL14bnf_bypass_stubEPvS0_S0_iS0_")
    bp3.SetScriptCallbackFunction("lldb_diag.on_bp_hit")
    bp3.SetIgnoreCount(100)
    bp3.SetOneShot(True)
    bp3.SetEnabled(True)
    print(f"[lldb_diag] BP3 bnf_bypass @hit#101: id={bp3.GetID()} locations={bp3.GetNumLocations()}")

    # BP4: kick_bypass_stub - queremos ver el self y reason al disparar
    bp4 = target.BreakpointCreateByName(
        "_ZN6fndiagL16kick_bypass_stubEPvi")
    bp4.SetScriptCallbackFunction("lldb_diag.on_bp_hit")
    bp4.SetOneShot(True)
    bp4.SetEnabled(True)
    print(f"[lldb_diag] BP4 kick_bypass (1 hit): id={bp4.GetID()} locations={bp4.GetNumLocations()}")

    print("[lldb_diag] NOTE: si el proceso desaparece sin stop = SIGKILL externo (EAC/AMFI).")
    print("[lldb_diag] Continuando proceso...")
    error = process.Continue()
    if error.Fail():
        print(f"[lldb_diag] Continue error: {error}")
    result.SetStatus(lldb.eReturnStatusSuccessFinishResult)


def eos_watch_callback(frame, wp_loc, internal_dict):
    """Watchpoint callback: EOS session state byte changed. Dump full bt."""
    thread  = frame.GetThread()
    process = thread.GetProcess()
    ts      = time.strftime('%H:%M:%S')

    # Read new value
    target = process.GetTarget()
    wp     = wp_loc.GetWatchpoint() if wp_loc else None
    wp_addr = wp.GetWatchAddress() if wp else 0
    err    = lldb.SBError()
    new_val = process.ReadMemory(wp_addr, 1, err) if wp_addr else b'\xff'
    state  = new_val[0] if (not err.Fail() and new_val) else 0xFF

    print(f"\n=== [eos_watch] EOS state changed ts={ts} addr=0x{wp_addr:x} new_state={state} ===")
    print(f"Thread #{thread.GetIndexID()} name='{thread.GetName()}' stop: {thread.GetStopDescription(512)}")

    # Full backtrace for all threads
    for t in process:
        is_trigger = (t.GetIndexID() == thread.GetIndexID())
        marker = " *** TRIGGER ***" if is_trigger else ""
        print(f"\n--- Thread #{t.GetIndexID()} '{t.GetName()}'{marker} ---")
        for i, fr in enumerate(t):
            if i >= 20:
                print(f"    ... (+{len(t)-20} frames)")
                break
            print(f"  #{i:2d} {fr}")

    print("\n[eos_watch] Continuing process (watchpoint remains)...")
    return False  # don't stop


def eos_watch(debugger, command, result, internal_dict):
    """
    eos_watch: watchpoint en el byte de estado EOS (global estatico).

    El estado EOS NO es un objeto heap: es un global directo en el binario.
    Descubierto via disassembly de RejoinViaSessionInternal+check:
      adrp x8, 66454; ldrb w8, [x8, #0xd68]; cmp w8, #0x5
    → state_byte = *(img_base + 0x13072d68)

    Funciona desde lobby o partida. Cuando EOS cambia estado (4->5+), bt all.

    Usage: (lldb) eos_watch
    """
    # Offset del global de estado EOS desde image base (calculado de RejoinViaSessionInternal)
    EOS_STATE_OFF = 0x13072d68

    target  = debugger.GetSelectedTarget()
    process = target.GetProcess()
    err     = lldb.SBError()

    # --- auto-stop si esta corriendo ---
    was_running = (process.GetState() == lldb.eStateRunning)
    if was_running:
        process.Stop()
        import time as _time
        for _ in range(20):
            if process.GetState() != lldb.eStateRunning:
                break
            _time.sleep(0.1)
        if process.GetState() == lldb.eStateRunning:
            print("[eos_watch] FAIL: could not stop process")
            return
        print("[eos_watch] Process stopped for memory read")

    # --- image base ---
    img_base = 0
    for i in range(target.GetNumModules()):
        m = target.GetModuleAtIndex(i)
        name = m.GetFileSpec().GetFilename()
        if "FortniteClient" in name or i == 0:
            img_base = m.GetObjectFileHeaderAddress().GetLoadAddress(target)
            if img_base and img_base != lldb.LLDB_INVALID_ADDRESS:
                print(f"[eos_watch] img_base=0x{img_base:x} ({name})")
                break

    if not img_base or img_base == lldb.LLDB_INVALID_ADDRESS:
        print("[eos_watch] FAIL: cannot determine image base")
        if was_running: process.Continue()
        return

    state_addr = img_base + EOS_STATE_OFF
    print(f"[eos_watch] EOS state global: 0x{state_addr:x} (offset 0x{EOS_STATE_OFF:x})")

    # --- leer estado actual ---
    val = process.ReadMemory(state_addr, 1, err)
    if err.Fail() or not val:
        print(f"[eos_watch] FAIL: state read at 0x{state_addr:x}: {err}")
        if was_running: process.Continue()
        return
    cur_state = val[0]
    state_names = {0:'Unknown',1:'Creating',2:'Pending',3:'Starting',
                   4:'InProgress',5:'Ending',6:'Ended',7:'Destroying'}
    print(f"[eos_watch] current state={cur_state} ({state_names.get(cur_state,'?')})")

    # --- watchpoint de escritura ---
    wp = target.WatchAddress(state_addr, 1, False, True, err)
    if err.Fail() or not wp or not wp.IsValid():
        print(f"[eos_watch] FAIL to set watchpoint: {err}")
        if was_running: process.Continue()
        return
    wp.SetEnabled(True)
    wp_id = wp.GetID()

    cmds = [
        "script import time; print('\\n=== [eos_watch] FIRED', time.strftime('%H:%M:%S'), '===')",
        "thread backtrace all",
        "continue",
    ]
    for c in cmds:
        debugger.HandleCommand(f'watchpoint command add {wp_id} -o "{c}"')

    print(f"[eos_watch] Watchpoint #{wp_id} armed at 0x{state_addr:x}")
    print("[eos_watch] Resuming. bt all fires on any EOS state change.")
    process.Continue()
    result.SetStatus(lldb.eReturnStatusSuccessFinishResult)


def lcf_find(debugger, command, result, internal_dict):
    """
    lcf_find: locate HandleCustomizationFailed at runtime and report its offset
    from image base.  Copy the printed offset into
    include/update/CustomizationPatcher.hpp → kHandleCustomizationFailedOff,
    then rebuild.

    Usage: (lldb) lcf_find

    How it works:
    1. Scans FortniteClient image memory for the C-string
       "HandleCustomizationFailed".
    2. For each occurrence it searches backwards through the preceding 512 KB
       of __TEXT for ADRP instructions whose resolved page equals the string's
       4K-aligned VA.  The closest ADRP to the string is in the referencing
       function.
    3. From that ADRP walks backwards to find the function prologue (STP X29
       or SUB SP pattern), giving the function start address.
    4. Logs "lcf_find: fn_offset=0x<hex>" — that value goes into the header.
    """
    import struct, time as _time

    target  = debugger.GetSelectedTarget()
    process = target.GetProcess()
    err     = lldb.SBError()

    was_running = (process.GetState() == lldb.eStateRunning)
    if was_running:
        process.Stop()
        for _ in range(30):
            if process.GetState() != lldb.eStateRunning:
                break
            _time.sleep(0.1)

    # --- find image base ---
    img_base = 0
    img_size = 0
    for i in range(target.GetNumModules()):
        m = target.GetModuleAtIndex(i)
        name = m.GetFileSpec().GetFilename()
        if "FortniteClient" in name or i == 0:
            img_base = m.GetObjectFileHeaderAddress().GetLoadAddress(target)
            # estimate size from last segment
            for j in range(m.GetNumSections()):
                s = m.GetSectionAtIndex(j)
                end = s.GetLoadAddress(target) + s.GetByteSize()
                if end > img_base + img_size:
                    img_size = end - img_base
            if img_base and img_base != lldb.LLDB_INVALID_ADDRESS:
                print(f"[lcf_find] img_base=0x{img_base:x}  img_size=0x{img_size:x} ({name})")
                break

    if not img_base or img_base == lldb.LLDB_INVALID_ADDRESS:
        print("[lcf_find] FAIL: cannot determine image base")
        if was_running: process.Continue()
        return

    TARGET_STR = b"HandleCustomizationFailed\x00"

    # Read the full __TEXT segment in chunks to avoid huge single reads
    CHUNK = 0x800000  # 8 MB chunks
    chunk_va = img_base
    end_va   = img_base + img_size

    string_vas = []
    print(f"[lcf_find] scanning {img_size // (1024*1024)} MB image for target string ...")

    while chunk_va < end_va and len(string_vas) < 10:
        read_size = min(CHUNK, end_va - chunk_va)
        mem = process.ReadMemory(chunk_va, read_size, err)
        if err.Fail() or not mem:
            chunk_va += CHUNK
            continue
        offset = 0
        while True:
            idx = mem.find(TARGET_STR, offset)
            if idx < 0:
                break
            string_vas.append(chunk_va + idx)
            offset = idx + 1
        chunk_va += CHUNK

    if not string_vas:
        print("[lcf_find] string 'HandleCustomizationFailed' not found in image")
        if was_running: process.Continue()
        return

    print(f"[lcf_find] found string at {len(string_vas)} location(s): "
          + ", ".join(f"0x{v:x}" for v in string_vas[:5]))

    fn_addr = 0
    for str_va in string_vas[:3]:
        str_page = str_va & ~0xFFF
        str_pgoff = str_va & 0xFFF  # offset within page (for ADD match)

        # Search backwards from str_va - 4 to str_va - 512KB for ADRP refs
        search_start = max(img_base, str_va - 0x80000)
        search_end   = str_va

        # Read the code range
        code = process.ReadMemory(search_start, search_end - search_start, err)
        if err.Fail() or not code:
            continue

        # Walk backwards in 4-byte steps looking for ADRP + ADD pair
        best_adrp_off = -1
        for off in range(len(code) - 4, -1, -4):
            insn, = struct.unpack_from('<I', code, off)
            pc = search_start + off

            # ADRP: bits[31:24]=1_x0_10000 → (insn & 0x9F000000) == 0x90000000
            if (insn & 0x9F000000) != 0x90000000:
                continue

            # Decode ADRP: immhi[23:5], immlo[30:29], Rd[4:0]
            immlo = (insn >> 29) & 0x3
            immhi = (insn >> 5) & 0x7FFFF
            imm21 = (immhi << 2) | immlo
            # sign extend 21 bits
            if imm21 & (1 << 20):
                imm21 |= ~((1 << 21) - 1)
            pc_page = pc & ~0xFFF
            resolved_page = (pc_page + (imm21 << 12)) & 0xFFFFFFFFFFFFFFFF
            if resolved_page != str_page:
                continue

            # Found ADRP that resolves to our string's page. Check the next
            # instruction for ADD Xd, Xd, #str_pgoff (or LDRB/LDR with offset).
            if off + 4 < len(code):
                next_insn, = struct.unpack_from('<I', code, off + 4)
                rd = insn & 0x1F
                # ADD Xd, Xd, #imm12  or  ADD Xd, Xn, #imm12
                if (next_insn & 0xFF800000) == 0x91000000:
                    imm12 = (next_insn >> 10) & 0xFFF
                    rn    = (next_insn >> 5) & 0x1F
                    if imm12 == str_pgoff:
                        best_adrp_off = off
                        break  # exact match - take this one
            # Accept ADRP alone as a weaker hit; keep searching for a better one
            if best_adrp_off < 0:
                best_adrp_off = off

        if best_adrp_off < 0:
            continue

        adrp_va = search_start + best_adrp_off
        print(f"[lcf_find] ADRP ref at 0x{adrp_va:x} (offset from base: 0x{adrp_va - img_base:x})")

        # Walk backwards from ADRP to find function prologue: STP X29, X30 or SUB SP
        # Limit search to 4 KB back (functions are rarely longer without a prolog)
        prolog_start = max(img_base, adrp_va - 0x1000)
        code2 = process.ReadMemory(prolog_start, adrp_va - prolog_start, err)
        if err.Fail() or not code2:
            fn_addr = adrp_va
            break

        for off2 in range(len(code2) - 4, -1, -4):
            insn2, = struct.unpack_from('<I', code2, off2)
            # STP X29, X30, [SP, #...] = 0xA9BF7BFD & mask or similar
            # encoding: opc=10 100111 1x xxxxxx xxxxxxx 11111 (SP) xxxxx
            # STP (pre-indexed): [31:30]=10 [29:27]=101 [26]=0 [25:24]=11 [23]=1 [22]=1
            # simplified: (insn & 0xFFC07FFF) == 0xA9007BFD checks for STP X29,X30,[SP]
            if (insn2 & 0xFFC07FFF) == 0xA9007BFD:  # STP X29, X30
                fn_addr = prolog_start + off2
                break
            # SUB SP, SP, #imm: (insn & 0xFFFFFC1F) == 0xD10003FF
            if (insn2 & 0xFFFFFC1F) == 0xD10003FF:
                fn_addr = prolog_start + off2
                break

        if fn_addr:
            break

    if not fn_addr:
        print("[lcf_find] could not locate function prologue")
        if was_running: process.Continue()
        return

    fn_offset = fn_addr - img_base
    print(f"\n[lcf_find] *** HandleCustomizationFailed ***")
    print(f"[lcf_find]   fn_addr   = 0x{fn_addr:x}")
    print(f"[lcf_find]   fn_offset = 0x{fn_offset:x}  ← put this in kHandleCustomizationFailedOff")
    print(f"[lcf_find]   img_base  = 0x{img_base:x}")
    print(f"\n[lcf_find] Edit include/update/CustomizationPatcher.hpp:")
    print(f"[lcf_find]   static constexpr uint64_t kHandleCustomizationFailedOff = 0x{fn_offset:x}ULL;")

    if was_running: process.Continue()
    result.SetStatus(lldb.eReturnStatusSuccessFinishResult)


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand(
        'command script add -f lldb_diag.diag_start diag_start')
    debugger.HandleCommand(
        'command script add -f lldb_diag.eos_watch eos_watch')
    debugger.HandleCommand(
        'command script add -f lldb_diag.lcf_find lcf_find')
    print("[lldb_diag] Loaded. Commands: 'diag_start' | 'eos_watch' | 'lcf_find'")
