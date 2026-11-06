"""
LLDB diagnostic for V2.0.15 — EndSession + ReceiveMessageFromServer monitoring.

Verifica si EOS_AntiCheatClient_EndSession se llama durante la partida activa
(confirma hipotesis: servidor EAC enviando kick via ReceiveMessageFromServer).

Uso:
    lldb -p $(pgrep -n FortniteClient-IOS-Shipping)
    (lldb) command script import /path/to/lldb_v2015_diagnostic.py

Interpreta los resultados:
  [EAC-END] durante partida (<60s) → hipotesis correcta, EndSession no-op funciona.
  [EAC-END] solo al salir de partida → EndSession no es la causa; buscar otra causa.
  [EAC-RX] type=0xXXYY → captura los tipos de mensajes del servidor EAC.
"""

import lldb, datetime, struct, os

LOG_PATH = "/private/tmp/FnDiag_v2015.log"

# File offsets en FnMacKickFix-V2.0.15-dev.dylib
_OFF_END_SESSION    = 0x23a78  # fndiag_end_session
_OFF_RX_MSG         = 0x23930  # fndiag_receive_msg_from_server
# s_count static var (en __DATA), s_es static var
_OFF_SCOUNT         = 0x40d88  # s_count (ReceiveMessageFromServer)
_OFF_SES            = 0x40d8c  # s_es    (EndSession)


def _log(msg):
    ts = datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]
    line = f"[{ts}] {msg}"
    with open(LOG_PATH, 'a') as f:
        f.write(line + '\n')
    print(line)


def _read_u32(process, addr):
    err = lldb.SBError()
    data = process.ReadMemory(addr, 4, err)
    return struct.unpack('<I', data)[0] if err.Success() and len(data) == 4 else None


def _read_u8(process, addr):
    err = lldb.SBError()
    data = process.ReadMemory(addr, 1, err)
    return data[0] if err.Success() and len(data) == 1 else None


def bp_end_session(frame, bp_loc, internal_dict):
    """Breakpoint en fndiag_end_session — confirma si EndSession se llama en partida."""
    t = frame.GetThread()
    process = t.GetProcess()
    s_es = _read_u32(process, internal_dict.get('va_ses', 0)) or '?'
    _log(f"=== [EAC-END] EndSession called! call#{s_es} thread={t.GetThreadID():#x} ===")
    # Dump backtrace (5 frames)
    for i in range(min(5, t.GetNumFrames())):
        f = t.GetFrameAtIndex(i)
        _log(f"  frame#{i} {f.GetFunctionName() or '?'} pc={f.GetPC():#x}")
    return False  # no detener ejecucion


def bp_rx_msg(frame, bp_loc, internal_dict):
    """Breakpoint en fndiag_receive_msg_from_server — captura tipo de mensaje."""
    t = frame.GetThread()
    process = t.GetProcess()
    # opts = x1 (segundo argumento, handle=x0)
    regs = frame.GetRegisters()
    opts_va = None
    for regset in regs:
        if 'general' in regset.GetName().lower():
            for reg in regset:
                if reg.GetName() == 'x1':
                    opts_va = reg.GetValueAsUnsigned()
                    break
    b0 = b1 = 0
    if opts_va:
        # EAC_RxOpts: int32(4) + uint32(4) + ptr(8) = 16 bytes
        # Data ptr is at offset 8
        err = lldb.SBError()
        raw = process.ReadMemory(opts_va, 16, err)
        if err.Success() and len(raw) == 16:
            dlen = struct.unpack_from('<I', raw, 4)[0]
            data_ptr = struct.unpack_from('<Q', raw, 8)[0]
            if data_ptr and dlen >= 2:
                b0 = _read_u8(process, data_ptr) or 0
                b1 = _read_u8(process, data_ptr + 1) or 0
    s_cnt = _read_u32(process, internal_dict.get('va_scnt', 0)) or '?'
    _log(f"[EAC-RX] ReceiveMsg #{s_cnt} type=0x{b0:02x}{b1:02x}")
    return False


def __lldb_init_module(debugger, internal_dict):
    target = debugger.GetSelectedTarget()
    if not target:
        print("[FnDiag] No target selected")
        return

    # Find dylib base
    dylib_base = None
    for m in target.module_iter():
        name = m.GetFileSpec().GetFilename()
        if 'FnMacKickFix-V2.0.15' in name:
            dylib_base = m.GetObjectFileHeaderAddress().GetLoadAddress(target)
            print(f"[FnDiag] Found dylib '{name}' base={dylib_base:#x}")
            break

    if not dylib_base or dylib_base == lldb.LLDB_INVALID_ADDRESS:
        print("[FnDiag] Could not find FnMacKickFix-V2.0.15 in loaded modules. Is the game running?")
        return

    va_end  = dylib_base + _OFF_END_SESSION
    va_rx   = dylib_base + _OFF_RX_MSG
    va_scnt = dylib_base + _OFF_SCOUNT
    va_ses  = dylib_base + _OFF_SES

    internal_dict['va_scnt'] = va_scnt
    internal_dict['va_ses']  = va_ses

    # Set breakpoints
    bp1 = target.BreakpointCreateByAddress(va_end)
    bp1.SetScriptCallbackFunction("lldb_v2015_diagnostic.bp_end_session")
    bp1.SetAutoContinue(True)

    bp2 = target.BreakpointCreateByAddress(va_rx)
    bp2.SetScriptCallbackFunction("lldb_v2015_diagnostic.bp_rx_msg")
    bp2.SetAutoContinue(True)

    _log(f"[FnDiag] V2.0.15 diagnostic loaded. dylib_base={dylib_base:#x}")
    _log(f"[FnDiag] BP1=EndSession @ {va_end:#x}  BP2=RxMsg @ {va_rx:#x}")
    _log(f"[FnDiag] Logging to {LOG_PATH}")
    print(f"[FnDiag] Breakpoints set. Log: {LOG_PATH}")
    print("[FnDiag] Entra en partida y observa [EAC-END] entries.")
    print("[FnDiag] Si [EAC-END] aparece DURANTE la partida (<60s), hipotesis confirmada.")
