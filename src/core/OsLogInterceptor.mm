// Intercepta _os_log_impl y NSLogv del proceso de Fortnite para escribir
// los mensajes (incluidos los marcados <private>) en FnDiag.log.
//
// Por que: os_log redacta argumentos dinamicos como <private> en log stream/show.
// Nuestro hook corre en el proceso inyectado, por lo que tiene acceso al buffer
// de argumentos antes de que el sistema aplique el filtro de privacidad.
// La decodificacion del buffer os_log_pack implementa los tipos mas comunes
// (entero 32/64, string, puntero). Los tipos desconocidos se muestran como hex.
//
// Para el log del sistema sin restricciones, el usuario aun necesita ejecutar
// (una sola vez en el Mac):
//   sudo log config --mode "private_data:on" --subsystem com.epicgames.fortnite
//
// PRODUCTION: el hook se instala igualmente para diagnosticar en campo.

#import <Foundation/Foundation.h>
#import <os/log.h>
#include <dlfcn.h>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include "core/DiagLog.hpp"
#include "core/OsLogInterceptor.hpp"

namespace fndiag {

// ----------------------------------------------------------------
// Tipos privados del ABI de _os_log_impl
// Fuente: Darwin open source (libdispatch / libtrace).
// ----------------------------------------------------------------
// Os log pack tiene dos formatos posibles segun version. Aqui el layout
// real que usa iOS 17+: el primer byte tras el header son los summary flags.
// Formato simplificado de los bytes de argumento:
//   [1b type] [1b size] [data...]
//   type 0x00 = escalar i32,  size 4
//   type 0x01 = escalar i64,  size 8
//   type 0x20 = string utf8 (con privacy),  size=len+1
//   type 0x21 = string utf8 (public),       size=len+1
//   type 0x40 = pointer,     size 8
// El primer byte del buffer (antes de los argumentos) es un contador de items.

static const char* log_type_str(os_log_type_t t) {
    switch (t) {
        case OS_LOG_TYPE_DEFAULT: return "default";
        case OS_LOG_TYPE_INFO:    return "info";
        case OS_LOG_TYPE_DEBUG:   return "debug";
        case OS_LOG_TYPE_ERROR:   return "error";
        case OS_LOG_TYPE_FAULT:   return "fault";
        default:                  return "?";
    }
}

// Extrae una representacion legible de los argumentos del buffer os_log_pack.
// buf[0] = num_args, luego pares [type_flags, size, data...].
static void decode_pack(const uint8_t* buf, uint32_t size,
                        char* out, size_t out_sz) {
    if (!buf || size < 2 || !out || out_sz == 0) {
        if (out && out_sz > 0) out[0] = '\0';
        return;
    }

    uint8_t num_args = buf[0];
    // byte 1 = flags, skip. Data empieza en buf[2].
    uint32_t off = 2;
    size_t written = 0;
    out[0] = '\0';

    for (uint8_t i = 0; i < num_args && off + 2 <= size && written + 32 < out_sz; i++) {
        uint8_t atype = buf[off];
        uint8_t asz   = buf[off + 1];
        off += 2;
        if (off + asz > size) break;

        char tmp[256];
        switch (atype & 0x3F) {   // bits 0-5 = categoria
            case 0x00:            // escalar (int/bool)
                if (asz == 4) {
                    int32_t v; memcpy(&v, buf + off, 4);
                    snprintf(tmp, sizeof tmp, "%d", (int)v);
                } else if (asz == 8) {
                    int64_t v; memcpy(&v, buf + off, 8);
                    snprintf(tmp, sizeof tmp, "%lld", (long long)v);
                } else {
                    snprintf(tmp, sizeof tmp, "<%ub>", (unsigned)asz);
                }
                break;
            case 0x20:            // string utf8 (may be private)
            case 0x21:            // string utf8 (public)
                if (asz > 0 && buf[off + asz - 1] == 0) {
                    // Null-terminated dentro del buffer
                    size_t slen = strnlen((const char*)(buf + off), asz);
                    size_t copy = slen < sizeof(tmp) - 1 ? slen : sizeof(tmp) - 1;
                    memcpy(tmp, buf + off, copy);
                    tmp[copy] = '\0';
                } else {
                    snprintf(tmp, sizeof tmp, "<%ub>", (unsigned)asz);
                }
                break;
            case 0x40:            // pointer
                if (asz == 8) {
                    uint64_t v; memcpy(&v, buf + off, 8);
                    snprintf(tmp, sizeof tmp, "0x%llx", (unsigned long long)v);
                } else {
                    snprintf(tmp, sizeof tmp, "<%ub>", (unsigned)asz);
                }
                break;
            default:
                snprintf(tmp, sizeof tmp, "[0x%02x:%ub]", (unsigned)atype, (unsigned)asz);
                break;
        }
        int n = snprintf(out + written, out_sz - written, "%s%s", i ? " | " : "", tmp);
        if (n > 0) written += (size_t)n;
        off += asz;
    }
}

// Filtro: solo loguear mensajes que probablemente sean relevantes para EAC/red.
static bool is_relevant(const char* fmt) {
    if (!fmt) return false;
    static const char* kKeys[] = {
        "EAC", "eac", "AntiCheat", "anticheat", "EOS", "eos",
        "register", "Register", "verify", "Verify",
        "session", "Session", "Failed", "failed",
        "account", "Account", "token", "Token",
        "http", "HTTP", "url", "URL", "request", "Request",
        "auth", "Auth", "kick", "Kick",
        nullptr
    };
    for (const char** k = kKeys; *k; k++)
        if (strstr(fmt, *k)) return true;
    return false;
}

// ----------------------------------------------------------------
// Hook de _os_log_impl
// ----------------------------------------------------------------
typedef void (*os_log_impl_fn)(void*, os_log_t, os_log_type_t, const char*, uint8_t*, uint32_t);
static os_log_impl_fn g_orig_os_log_impl = nullptr;

static void h_os_log_impl(void* dso, os_log_t log_obj, os_log_type_t type,
                           const char* format, uint8_t* buf, uint32_t size) {
    if (format && is_relevant(format)) {
        char decoded[1024] = {};
        decode_pack(buf, size, decoded, sizeof decoded);
        log_line("[GameLog:%s] fmt=%s args={%s}", log_type_str(type), format, decoded);
    }
    if (g_orig_os_log_impl)
        g_orig_os_log_impl(dso, log_obj, type, format, buf, size);
}

// ----------------------------------------------------------------
// Hook de NSLogv (NSLog no aplica filtro <private>)
// ----------------------------------------------------------------
static IMP g_orig_NSLogv = nullptr;

static void h_NSLogv(NSString* format, va_list args) {
    if (format) {
        // NSLogv no filtra: podemos capturar el mensaje completo
        char buf[2048];
        NSString* msg = [[NSString alloc] initWithFormat:format arguments:args];
        const char* s = [msg UTF8String];
        if (s && is_relevant(s)) {
            strlcpy(buf, s, sizeof buf);
            // Reemplazar saltos de linea para que el log quede en una sola linea
            for (char* p = buf; *p; p++) if (*p == '\n') *p = '|';
            log_line("[NSLog] %s", buf);
        }
    }
    if (g_orig_NSLogv) ((void (*)(NSString*, va_list))g_orig_NSLogv)(format, args);
}

// ----------------------------------------------------------------
typedef void (*MSHookFunction_t)(void*, void*, void**);

void install_oslog_interceptor() {
    // Cargar MSHookFunction para hookear funciones C
    MSHookFunction_t mshook = nullptr;
    void* handle = dlopen("/usr/lib/libsubstrate.dylib", RTLD_NOW);
    if (!handle) handle = dlopen("/usr/lib/libellekit.dylib", RTLD_NOW);
    if (handle) mshook = (MSHookFunction_t)dlsym(handle, "MSHookFunction");

    if (mshook) {
        void* sym = dlsym(RTLD_DEFAULT, "_os_log_impl");
        if (sym) {
            mshook(sym, (void*)h_os_log_impl, (void**)&g_orig_os_log_impl);
            log_line("[OsLog] _os_log_impl hooked (args decoder activo)");
        } else {
            log_line("[OsLog] WARN: _os_log_impl no encontrado");
        }
    } else {
        log_line("[OsLog] MSHookFunction no disponible - hook de _os_log_impl omitido");
    }

    // Hook NSLogv via method swizzle (NSLog -> NSLogv -> aqui)
    // NSLog no aplica filtro <private>, util para captura adicional
    Class cls = NSClassFromString(@"NSObject");  // placeholder; NSLogv es C, no ObjC
    (void)cls;
    // NSLogv es una funcion C libre, hookear con MSHookFunction igual
    if (mshook) {
        void* sym = dlsym(RTLD_DEFAULT, "NSLogv");
        if (sym) {
            mshook(sym, (void*)h_NSLogv, (void**)&g_orig_NSLogv);
            log_line("[OsLog] NSLogv hooked");
        }
    }

    log_line("[OsLog] NOTA: para ver <private> en log stream del sistema, ejecutar una vez:");
    log_line("[OsLog]   sudo log config --mode \"private_data:on\" --subsystem com.epicgames.fortnite");
}

} // namespace fndiag
