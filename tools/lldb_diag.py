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

    Two-pass scan:
    1. Full image scan for the C-string "HandleCustomizationFailed".
    2. Full __TEXT scan for ADRP instructions whose resolved page == string page.
       Checks ADD Xd, Xd, #pgoff on the next instruction for exact hits.
    3. Walks backwards from each ADRP to find the function prologue.
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

    # --- image base ---
    img_base = 0
    for i in range(target.GetNumModules()):
        m = target.GetModuleAtIndex(i)
        name = m.GetFileSpec().GetFilename()
        if "FortniteClient" in name or i == 0:
            img_base = m.GetObjectFileHeaderAddress().GetLoadAddress(target)
            if img_base and img_base != lldb.LLDB_INVALID_ADDRESS:
                print(f"[lcf_find] img_base=0x{img_base:x} ({name})")
                break

    if not img_base or img_base == lldb.LLDB_INVALID_ADDRESS:
        print("[lcf_find] FAIL: cannot determine image base")
        if was_running: process.Continue()
        return

    # Fixed layout offsets from base 0x100000000 (otool):
    #   __text start offset = 0x4000, end = 0xC70D06C
    #   __TEXT total vmsize = 0xDD80000
    IMG_SIZE   = 0xDD80000   # scan range for string
    CODE_END   = 0xC70D06C   # __text section end (from img_base)

    TARGET_STR = b"HandleCustomizationFailed\x00"
    CHUNK      = 0x800000    # 8 MB chunks

    # --- pass 1: find string VA ---
    string_vas = []
    print(f"[lcf_find] pass 1: scanning {IMG_SIZE//(1024*1024)} MB for string ...")
    chunk_va = img_base
    end_va   = img_base + IMG_SIZE
    while chunk_va < end_va and len(string_vas) < 5:
        read_size = min(CHUNK, end_va - chunk_va)
        mem = process.ReadMemory(chunk_va, read_size, err)
        if not err.Fail() and mem:
            pos = 0
            while True:
                idx = mem.find(TARGET_STR, pos)
                if idx < 0: break
                string_vas.append(chunk_va + idx)
                pos = idx + 1
        chunk_va += CHUNK

    if not string_vas:
        print("[lcf_find] FAIL: string not found in image")
        if was_running: process.Continue()
        return

    str_va    = string_vas[0]
    str_page  = str_va & ~0xFFF
    str_pgoff = str_va & 0xFFF
    print(f"[lcf_find] string VA=0x{str_va:x}  page=0x{str_page:x}  pgoff=0x{str_pgoff:x}")

    # --- pass 2: scan __TEXT for ADRP refs to str_page ---
    # ADRP Xd, label: (insn & 0x9F000000) == 0x90000000
    # resolved = (PC & ~0xFFF) + sign_extend(immhi:immlo, 21) << 12
    # We want resolved == str_page.
    adrp_exact  = []   # (va, rd) where ADRP+ADD matches exactly
    adrp_partial= []   # (va, rd) where only ADRP matches

    print(f"[lcf_find] pass 2: scanning __TEXT (0x{CODE_END//1024//1024} MB) for ADRP refs ...")
    code_end_va = img_base + CODE_END
    chunk_va = img_base
    while chunk_va < code_end_va:
        read_size = min(CHUNK, code_end_va - chunk_va)
        if read_size < 4: break
        mem = process.ReadMemory(chunk_va, read_size, err)
        if err.Fail() or not mem:
            chunk_va += CHUNK
            continue
        for off in range(0, len(mem) - 4, 4):
            insn, = struct.unpack_from('<I', mem, off)
            if (insn & 0x9F000000) != 0x90000000:
                continue
            pc      = chunk_va + off
            pc_page = pc & ~0xFFF
            immlo   = (insn >> 29) & 0x3
            immhi   = (insn >> 5)  & 0x7FFFF
            imm21   = (immhi << 2) | immlo
            if imm21 & (1 << 20):
                imm21 -= (1 << 21)
            resolved = (pc_page + (imm21 << 12)) & 0xFFFFFFFFFFFFFFFF
            if resolved != str_page:
                continue
            rd = insn & 0x1F
            # check ADD Xd, Xd/Xn, #str_pgoff
            if off + 4 < len(mem):
                nxt, = struct.unpack_from('<I', mem, off + 4)
                if (nxt & 0xFF800000) == 0x91000000:
                    if ((nxt >> 10) & 0xFFF) == str_pgoff:
                        adrp_exact.append((pc, rd))
                        continue
            adrp_partial.append((pc, rd))
        chunk_va += CHUNK

    print(f"[lcf_find] ADRP refs: {len(adrp_exact)} exact (ADRP+ADD)  {len(adrp_partial)} partial")
    candidates = adrp_exact if adrp_exact else adrp_partial
    if not candidates:
        print("[lcf_find] FAIL: no ADRP references found — string may be unreferenced via ADRP")
        if was_running: process.Continue()
        return

    # --- pass 3: find function prologue for each candidate ---
    fn_addr = 0
    for adrp_va, rd in candidates[:10]:
        # Walk backwards up to 8 KB looking for prologue
        back = min(adrp_va - img_base, 0x2000)
        code2 = process.ReadMemory(adrp_va - back, back, err)
        if err.Fail() or not code2:
            continue
        for off2 in range(len(code2) - 4, -1, -4):
            insn2, = struct.unpack_from('<I', code2, off2)
            # STP X29, X30, [SP, #imm]  (any form: pre-index, signed-offset, etc.)
            # Fixed bytes: byte3=0xA9, bytes[1:0]=0x7BFD
            # mask: 0xFF00FFFF  value: 0xA9007BFD
            if (insn2 & 0xFF00FFFF) == 0xA9007BFD:
                fn_addr = adrp_va - back + off2
                break
            # SUB SP, SP, #imm12  (alternative frame setup)
            # Fixed bits: byte3=0xD1, bits[9:0]=0x3FF (Rn=SP Rd=SP)
            # mask: 0xFF0003FF  value: 0xD10003FF
            if (insn2 & 0xFF0003FF) == 0xD10003FF:
                fn_addr = adrp_va - back + off2
                break
        if fn_addr:
            print(f"[lcf_find] prologue found at 0x{fn_addr:x} (ADRP was at 0x{adrp_va:x})")
            break

    if not fn_addr:
        # Fallback: use first candidate ADRP address
        fn_addr = candidates[0][0]
        print(f"[lcf_find] WARN: prologue not found; using ADRP addr 0x{fn_addr:x} as approximation")

    fn_offset = fn_addr - img_base
    print(f"\n[lcf_find] *** HandleCustomizationFailed ***")
    print(f"[lcf_find]   fn_addr   = 0x{fn_addr:x}")
    print(f"[lcf_find]   fn_offset = 0x{fn_offset:x}  <-- copy this value")
    print(f"[lcf_find]   img_base  = 0x{img_base:x}")
    print(f"\n[lcf_find] In include/update/CustomizationPatcher.hpp:")
    print(f"[lcf_find]   static constexpr uint64_t kHandleCustomizationFailedOff = 0x{fn_offset:x}ULL;")

    if was_running: process.Continue()
    result.SetStatus(lldb.eReturnStatusSuccessFinishResult)


def lcf_find_ptr(debugger, command, result, internal_dict):
    """
    lcf_find_ptr: scan __DATA_CONST at runtime for a pointer to
    HandleCustomizationFailed (offset 0xa30b6f4).  If found, reports the
    vtable slot as an offset from img_base so CustomizationPatcher can patch
    it in __DATA_CONST (no __TEXT write, no CS enforcement issue).

    Usage: (lldb) lcf_find_ptr
    """
    import struct, time as _time

    LCF_OFF = 0xa30b6f4   # known offset of HandleCustomizationFailed

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

    # img_base
    img_base = 0
    fn_module = None
    for i in range(target.GetNumModules()):
        m = target.GetModuleAtIndex(i)
        name = m.GetFileSpec().GetFilename()
        if "FortniteClient" in name or i == 0:
            img_base = m.GetObjectFileHeaderAddress().GetLoadAddress(target)
            if img_base and img_base != lldb.LLDB_INVALID_ADDRESS:
                fn_module = m
                print(f"[lcf_find_ptr] img_base=0x{img_base:x} ({name})")
                break

    if not img_base or img_base == lldb.LLDB_INVALID_ADDRESS:
        print("[lcf_find_ptr] FAIL: cannot determine image base")
        if was_running: process.Continue()
        return

    fn_addr = img_base + LCF_OFF
    needle  = struct.pack('<Q', fn_addr)
    print(f"[lcf_find_ptr] searching __DATA_CONST for ptr=0x{fn_addr:x} ...")

    # Collect writable data segments: __DATA_CONST and __DATA
    scan_regions = []
    if fn_module:
        for si in range(fn_module.GetNumSections()):
            seg = fn_module.GetSectionAtIndex(si)
            sname = seg.GetName()
            if sname in ("__DATA_CONST", "__DATA"):
                va   = seg.GetLoadAddress(target)
                size = seg.GetByteSize()
                if va and va != lldb.LLDB_INVALID_ADDRESS and size:
                    scan_regions.append((sname, va, size))
            # subsections
            for ssi in range(seg.GetNumSubSections()):
                sub   = seg.GetSubSectionAtIndex(ssi)
                ssname = sub.GetName()
                if ssname in ("__DATA_CONST", "__DATA"):
                    va   = sub.GetLoadAddress(target)
                    size = sub.GetByteSize()
                    if va and va != lldb.LLDB_INVALID_ADDRESS and size:
                        scan_regions.append((ssname, va, size))

    if not scan_regions:
        # Fallback estimate
        scan_regions = [
            ("__DATA_CONST(est)", img_base + 0xDD80000, 0x6000000),
            ("__DATA(est)",       img_base + 0xE380000, 0x6000000),
        ]
        print("[lcf_find_ptr] WARN: segments not found via API, using estimates")

    for rname, rstart, rsize in scan_regions:
        print(f"[lcf_find_ptr] scanning {rname}: 0x{rstart:x} - 0x{rstart+rsize:x} ({rsize//1024}KB)")

    # Scan all regions
    hits = []
    CHUNK = 0x200000
    for rname, rstart, rsize in scan_regions:
        cur = rstart
        end = rstart + rsize
        while cur < end and len(hits) < 20:
            read_size = min(CHUNK, end - cur)
            mem = process.ReadMemory(cur, read_size, err)
            if err.Fail() or not mem:
                cur += CHUNK
                continue
            pos = 0
            while True:
                idx = mem.find(needle, pos)
                if idx < 0: break
                va  = cur + idx
                off = va - img_base
                hits.append((rname, va, off))
                pos = idx + 1
            cur += CHUNK

    if not hits:
        print("[lcf_find_ptr] No pointer found in __DATA_CONST or __DATA.")
        print("[lcf_find_ptr] Function is called directly (no static pointer to redirect).")
        print(f"[lcf_find_ptr] fn_addr runtime: 0x{fn_addr:x}")
    else:
        print(f"\n[lcf_find_ptr] *** {len(hits)} pointer(s) found ***")
        for rname, va, off in hits:
            print(f"  segment={rname}  ptr_va=0x{va:x}  ptr_offset_from_base=0x{off:x}")
        print()
        print("[lcf_find_ptr] Use ptr_offset_from_base as kHandleCustomizationFailedVtableOff")
        print("[lcf_find_ptr] patch that slot = &customization_failed_stub")

    if was_running: process.Continue()
    result.SetStatus(lldb.eReturnStatusSuccessFinishResult)


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand(
        'command script add -f lldb_diag.diag_start diag_start')
    debugger.HandleCommand(
        'command script add -f lldb_diag.eos_watch eos_watch')
    debugger.HandleCommand(
        'command script add -f lldb_diag.lcf_find lcf_find')
    debugger.HandleCommand(
        'command script add -f lldb_diag.lcf_find_ptr lcf_find_ptr')
    print("[lldb_diag] Loaded. Commands: 'diag_start' | 'eos_watch' | 'lcf_find' | 'lcf_find_ptr'")
