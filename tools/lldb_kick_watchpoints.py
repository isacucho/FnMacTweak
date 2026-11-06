"""
LLDB kick-path watchpoint analysis.

Monitoriza sin breakpoints:
  WP1 (READ,  8B @ vtable[0])  — dispara cuando ClientWasKicked se despacha por vtable,
                                  captura la cadena de llamada completa y los args.
  WP2 (WRITE, 4B @ s_count)    — dispara en cada mensaje EAC del servidor
                                  (solo muestra hits 1-3 y luego cada 100).

Uso (con el juego corriendo como PID <X>):
    lldb -p <X> -o 'command script import /path/to/lldb_kick_watchpoints.py'

Nota: las direcciones son especificas de la sesion actual (slide 0x4a3c000).
Recalcular si el juego se reinicia.
"""

import lldb
import datetime
import struct

LOG_PATH = "/private/tmp/claude-501/-Users-alexg-Documents-Dev-Fortnite-FnMac/0743900d-a8c4-4826-8b64-7138da102dee/scratchpad/kick_analysis.log"

# vtable entry [0] = game_base(0x104a3c000) + 0xcd553e0 = 0x1117913E0
# El valor almacenado debe ser kick_bypass_stub (0x11846E06C) — verificado.
VTABLE_KICK_VA = 0x1117913E0

# s_count en fndiag_receive_msg_from_server (dylib __DATA)
# adrp x8,29 desde 0x11847b944 → x8=0x118498000, ldr w9,[x8,#0xd78]
SCNT_VA = 0x118498D78


def _log(msg):
    ts = datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]
    line = f"[{ts}] {msg}"
    with open(LOG_PATH, 'a') as f:
        f.write(line + '\n')
    print(line)


def _read_u32(process, addr):
    err = lldb.SBError()
    data = process.ReadMemory(addr, 4, err)
    if err.Success() and len(data) == 4:
        return struct.unpack('<I', data)[0]
    return None


def wp1_vtable_kick(frame, wp_loc, internal_dict):
    """READ watchpoint: vtable dispatch para ClientWasKicked_Implementation."""
    t = frame.GetThread()
    tid = t.GetThreadID()
    tname = t.GetName() or "?"

    _log(f"=== WP1 vtable_ClientWasKicked  tid={tid:#x} ({tname}) ===")

    # Registros en el momento de la lectura del vtable: x0=this, x1=reason
    regs_of_interest = {}
    for rs in t.frames[0].GetRegisters():
        for r in rs:
            if r.GetName() in ('x0', 'x1', 'x2', 'x3', 'x8', 'lr'):
                regs_of_interest[r.GetName()] = r.GetValue()

    for name in ('x0', 'x1', 'x2', 'x3', 'x8', 'lr'):
        if name in regs_of_interest:
            label = " (this)" if name == 'x0' else " (reason=EFortKickReason)" if name == 'x1' else ""
            _log(f"  {name} = {regs_of_interest[name]}{label}")

    _log("  backtrace:")
    for i, fr in enumerate(t.frames[:40]):
        _log(f"    #{i:2d}: {fr}")

    return False  # auto-continue


def wp2_scnt(frame, wp_loc, internal_dict):
    """WRITE watchpoint: s_count++ en fndiag_receive_msg_from_server."""
    process = frame.GetThread().GetProcess()
    cnt = _read_u32(process, SCNT_VA)
    if cnt is None:
        return False

    # Solo muestrar hits 1,2,3 y luego cada 100
    if cnt > 3 and cnt % 100 != 0:
        return False

    t = frame.GetThread()
    _log(f"--- WP2 EAC_ReceiveMsg  s_count={cnt} tid={t.GetThreadID():#x} ({t.GetName() or '?'}) ---")
    for i, fr in enumerate(t.frames[:20]):
        _log(f"    #{i:2d}: {fr}")

    return False  # auto-continue


def __lldb_init_module(debugger, internal_dict):
    target = debugger.GetSelectedTarget()
    process = target.GetProcess()
    pid = process.GetProcessID()

    with open(LOG_PATH, 'w') as f:
        f.write(f"# kick_analysis log — pid={pid} — {datetime.datetime.now().isoformat()}\n")

    _log(f"kick_analysis loaded  pid={pid}")

    try:
        # Introspect WatchAddress signature to handle LLDB version differences
        import inspect
        sig = str(inspect.signature(target.WatchAddress)) if hasattr(inspect, 'signature') else '?'
        _log(f"WatchAddress sig: {sig}")

        # WP1: lectura del vtable entry de ClientWasKicked (8 bytes, READ)
        err = lldb.SBError()
        wp1 = target.WatchAddress(VTABLE_KICK_VA, 8, True, False, err)
        if wp1 and wp1.IsValid():
            wp1.SetScriptCallbackFunction('lldb_kick_watchpoints.wp1_vtable_kick')
            _log(f"WP1 OK  addr={VTABLE_KICK_VA:#x}  id={wp1.GetID()}")
        else:
            _log(f"WP1 FAILED: {err.GetCString() if err else 'no error obj'}")

        # WP2: escritura de s_count (4 bytes, WRITE)
        err2 = lldb.SBError()
        wp2 = target.WatchAddress(SCNT_VA, 4, False, True, err2)
        if wp2 and wp2.IsValid():
            wp2.SetScriptCallbackFunction('lldb_kick_watchpoints.wp2_scnt')
            _log(f"WP2 OK  addr={SCNT_VA:#x}  id={wp2.GetID()}")
        else:
            _log(f"WP2 FAILED: {err2.GetCString() if err2 else 'no error obj'}")

    except Exception as e:
        import traceback
        _log(f"EXCEPTION in WatchAddress setup: {e}")
        _log(traceback.format_exc())

    _log("continuing process...")
    debugger.HandleCommand('continue')
    _log(f"watching — log: {LOG_PATH}")
