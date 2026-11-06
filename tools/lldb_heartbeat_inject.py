"""
LLDB fault injection: latencia artificial en el heartbeat de matchmaking.

Uso:
    lldb -n FortniteClient-IOS-Shipping
    (lldb) command script import /path/to/lldb_heartbeat_inject.py
    (lldb) heartbeat_inject --delay 5000    # 5s de latencia en el siguiente heartbeat
    (lldb) heartbeat_inject --drop          # simula timeout total (no enviar)

Tecnica: breakpoint en CFURLRequestSetHTTPRequestBody. Cuando la URL del request
contiene "/heartbeat", el script inyecta un sleep en el hilo de red antes de
continuar la ejecucion, simulando latencia de red sin desconectar fisicamente.

Para inyectar en send() directamente (nivel socket):
    heartbeat_inject --socket-delay 3000
Esto hace breakpoint en sendto() de libsystem_kernel y filtra por fd.
"""

import lldb
import re
import time

TARGET_URL_PATTERN = re.compile(r"/heartbeat|/ticket/.+/heartbeat|sdk/v1/product")
DELAY_MS = 3000
DROP_MODE = False

def heartbeat_inject_cmd(debugger, command, result, internal_dict):
    global DELAY_MS, DROP_MODE
    args = command.strip().split()
    for i, a in enumerate(args):
        if a == "--delay" and i + 1 < len(args):
            DELAY_MS = int(args[i + 1])
        if a == "--drop":
            DROP_MODE = True
        if a == "--socket-delay" and i + 1 < len(args):
            DELAY_MS = int(args[i + 1])
            _install_socket_breakpoint(debugger)
            return

    _install_cfurl_breakpoint(debugger)
    result.AppendMessage(f"Heartbeat injection activa: delay={DELAY_MS}ms drop={DROP_MODE}")


def _install_cfurl_breakpoint(debugger):
    target = debugger.GetSelectedTarget()
    bp = target.BreakpointCreateByName("CFURLRequestSetHTTPRequestBody")
    if not bp.IsValid():
        print("[lldb_inject] CFURLRequestSetHTTPRequestBody no encontrado. Prueba el socket breakpoint.")
        return
    bp.SetScriptCallbackFunction("lldb_heartbeat_inject._cfurl_callback")
    print(f"[lldb_inject] Breakpoint #{bp.GetID()} en CFURLRequestSetHTTPRequestBody")


def _install_socket_breakpoint(debugger):
    """
    Alternativa: breakpoint en send()/sendto() filtrado por socket fd.
    Requiere identificar el fd del socket de heartbeat con lsof primero:
        lsof -p <pid> | grep ESTABLISHED | grep 443
    Luego setear HEARTBEAT_FD abajo.
    """
    HEARTBEAT_FD = -1  # completar con el fd real
    target = debugger.GetSelectedTarget()
    bp = target.BreakpointCreateByName("sendto", "libsystem_kernel.dylib")
    if not bp.IsValid():
        print("[lldb_inject] sendto no encontrado")
        return
    bp.SetCondition(f"$arg1 == {HEARTBEAT_FD}" if HEARTBEAT_FD != -1 else "1")
    bp.SetScriptCallbackFunction("lldb_heartbeat_inject._sendto_callback")
    print(f"[lldb_inject] Breakpoint #{bp.GetID()} en sendto (fd={HEARTBEAT_FD})")


def _cfurl_callback(frame, bp_loc, extra_args, internal_dict):
    """
    Callback en CFURLRequestSetHTTPRequestBody.
    x0 = CFURLRequestRef, x1 = CFDataRef (body)
    Leemos la URL del request para filtrar solo heartbeat calls.
    """
    thread = frame.GetThread()
    process = thread.GetProcess()

    req_ptr = frame.FindRegister("x0").GetValueAsUnsigned()
    if req_ptr == 0:
        return False

    # Llamar CFURLRequestCopyURL para obtener la URL del request
    target = process.GetTarget()
    expr_result = frame.EvaluateExpression(
        f"(CFStringRef)CFURLGetString((CFURLRef)CFURLRequestCopyURL((CFURLRequestRef){req_ptr:#x}))"
    )
    if not expr_result.IsValid():
        return False

    url_ptr = expr_result.GetValueAsUnsigned()
    url_str = _cfstring_to_python(frame, url_ptr)

    if not url_str or not TARGET_URL_PATTERN.search(url_str):
        return False

    print(f"[lldb_inject] Heartbeat interceptado: {url_str}")

    if DROP_MODE:
        # Reemplaza el body con datos vacios para simular drop
        frame.EvaluateExpression(
            f"(void)CFURLRequestSetHTTPRequestBody((CFURLRequestRef){req_ptr:#x}, NULL)"
        )
        print("[lldb_inject] Body ELIMINADO (drop mode)")
    else:
        # Inyecta latencia: sleep en el hilo de red
        print(f"[lldb_inject] Inyectando {DELAY_MS}ms de latencia...")
        frame.EvaluateExpression(f"(void)usleep({DELAY_MS * 1000})")
        print("[lldb_inject] Latencia inyectada, continuando")

    return False  # no detener, continuar ejecucion


def _sendto_callback(frame, bp_loc, extra_args, internal_dict):
    """
    Callback en sendto(). Inyecta latencia antes de cada send del heartbeat fd.
    x0 = sockfd, x1 = buf, x2 = len, ...
    """
    print(f"[lldb_inject] sendto interceptado, inyectando {DELAY_MS}ms...")
    frame.EvaluateExpression(f"(void)usleep({DELAY_MS * 1000})")
    return False


def _cfstring_to_python(frame, cfstring_ptr):
    if cfstring_ptr == 0:
        return None
    result = frame.EvaluateExpression(
        f'(const char *)CFStringGetCStringPtr((CFStringRef){cfstring_ptr:#x}, 0x08000100)'
    )
    if result.IsValid() and result.GetValueAsUnsigned() != 0:
        err = lldb.SBError()
        process = frame.GetThread().GetProcess()
        cstr = process.ReadCStringFromMemory(result.GetValueAsUnsigned(), 4096, err)
        if err.Success():
            return cstr
    return None


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand(
        "command script add -f lldb_heartbeat_inject.heartbeat_inject_cmd heartbeat_inject"
    )
    print("[lldb_inject] Cargado. Uso: heartbeat_inject [--delay <ms>] [--drop] [--socket-delay <ms>]")
