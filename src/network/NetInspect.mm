/*
 * NetInspect.mm - bypass de SSL certificate pinning para inspeccion de trafico.
 *
 * Con FNDIAG_NET_INSPECT=1 (o net_inspect=1 en FnDiag.conf):
 *   - hookea SecTrustEvaluateWithError via MSHookFunction para aceptar
 *     cualquier cert, incluido el de un proxy MITM (mitmproxy, Charles).
 *   - loguea el subject summary de cada cert bypasseado a FnDiag.log.
 *
 * Para capturar trafico:
 *   1. FNDIAG_NET_INSPECT=1 en el entorno de lanzamiento
 *   2. Sistema > Ajustes > Red > Proxies: HTTP/HTTPS -> 127.0.0.1:8080
 *   3. mitmproxy --mode regular --listen-port 8080
 *
 * El hook cubre NSURLSession + EOSSDK (ambos pasan por Security.framework).
 * El trafico de EAC (protocolo binario sobre UDP) NO pasa por TLS y no
 * requiere bypass adicional para su inspeccion.
 */

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <dlfcn.h>
#include "network/NetInspect.hpp"
#include "core/DiagLog.hpp"
#include "core/Config.hpp"

extern "C" void MSHookFunction(void* symbol, void* replace, void** result);

namespace {

typedef OSStatus (*SecTrustEvalFn)(SecTrustRef, CFErrorRef*);
static SecTrustEvalFn g_orig_trust = nullptr;
static bool g_logged_proxy_hint = false;

static OSStatus my_SecTrustEvaluateWithError(SecTrustRef trust, CFErrorRef* error) {
    if (error) *error = nullptr;

    if (trust && fndiag::config().net_inspect) {
        CFArrayRef chain = SecTrustCopyCertificateChain(trust);
        if (chain && CFArrayGetCount(chain) > 0) {
            auto cert = static_cast<SecCertificateRef>(
                const_cast<void*>(CFArrayGetValueAtIndex(chain, 0)));
            CFStringRef summary = SecCertificateCopySubjectSummary(cert);
            if (summary) {
                char buf[256] = {};
                CFStringGetCString(summary, buf, sizeof(buf), kCFStringEncodingUTF8);
                fndiag::log_line("[NetInspect] SSL trust bypassed: %s", buf);
                CFRelease(summary);
            }
        }
        if (chain) CFRelease(chain);
        if (!g_logged_proxy_hint) {
            g_logged_proxy_hint = true;
            fndiag::log_line("[NetInspect] proxy hint: System Settings > Network > Proxies"
                             " -> HTTP/HTTPS 127.0.0.1:8080 (mitmproxy/Charles)");
        }
    }
    return errSecSuccess;
}

} // namespace

namespace fndiag {

void install_net_inspect() {
    if (!config().net_inspect) return;

    void* fn = dlsym(RTLD_DEFAULT, "SecTrustEvaluateWithError");
    if (!fn) {
        log_line("[NetInspect] SecTrustEvaluateWithError no encontrado");
        return;
    }
    MSHookFunction(fn, reinterpret_cast<void*>(my_SecTrustEvaluateWithError),
                   reinterpret_cast<void**>(&g_orig_trust));
    log_line("[NetInspect] SSL trust bypass instalado (SecTrustEvaluateWithError hookeado)");
}

} // namespace fndiag
