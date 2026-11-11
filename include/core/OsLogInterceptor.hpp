#pragma once

namespace fndiag {

// Hooks _os_log_impl y NSLogv para escribir mensajes del juego en FnDiag.log
// sin restriccion <private>. Llama antes de cualquier otro hook.
void install_oslog_interceptor();

} // namespace fndiag
