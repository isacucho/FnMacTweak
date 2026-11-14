#pragma once

namespace fndiag {

// Bypass de SSL certificate pinning para inspeccion de trafico.
// Gateado por config().net_inspect (FNDIAG_NET_INSPECT=1, default=false).
//
// Con net_inspect=1: hookea SecTrustEvaluateWithError para aceptar cualquier
// certificado (incluido el de un proxy MITM como mitmproxy o Charles).
// El proxy se configura en Sistema > Ajustes > Red > Proxies en el Mac host.
//
// ADVERTENCIA: net_inspect=1 desactiva la validacion TLS de TODO el proceso.
// Usar solo en sesiones de debug, nunca en produccion.
void install_net_inspect();

} // namespace fndiag
