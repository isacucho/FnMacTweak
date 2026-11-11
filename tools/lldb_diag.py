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


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand(
        'command script add -f lldb_diag.diag_start diag_start')
    debugger.HandleCommand(
        'command script add -f lldb_diag.eos_watch eos_watch')
    print("[lldb_diag] Loaded. Commands: 'diag_start' | 'eos_watch'")
