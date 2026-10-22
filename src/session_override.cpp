#include "fndiag/config.hpp"
#include "fndiag/hooks.hpp"
#include "fndiag/log.hpp"
#include "fndiag/objc_util.hpp"

namespace fndiag {
namespace {

using objc::send;
using objc::sel;

IMP g_orig_bg = nullptr;        // +backgroundSessionConfigurationWithIdentifier:
IMP g_orig_bg_legacy = nullptr; // +backgroundSessionConfiguration:

id hook_background_config(id self, SEL cmd, id identifier) {
    log_line("background session requested: identifier=%s", objc::to_string(identifier).c_str());
    if (config().foreground_sessions) {
        log_line("  -> devolviendo configuracion efimera en proceso");
        return send<id>(self, sel("ephemeralSessionConfiguration"));
    }
    IMP orig = (cmd == sel("backgroundSessionConfigurationWithIdentifier:")) ? g_orig_bg : g_orig_bg_legacy;
    return reinterpret_cast<id (*)(id, SEL, id)>(orig)(self, cmd, identifier);
}

} // namespace

void install_session_override() {
    const char *cls = "NSURLSessionConfiguration";
    if (objc::replace_class_method(cls, "backgroundSessionConfigurationWithIdentifier:",
                                   reinterpret_cast<IMP>(hook_background_config), &g_orig_bg))
        log_line("hook: +[%s backgroundSessionConfigurationWithIdentifier:]", cls);
    else
        log_line("AVISO: no se pudo enganchar backgroundSessionConfigurationWithIdentifier:");

    // API obsoleta; puede no existir en el SDK, no es un error.
    if (objc::replace_class_method(cls, "backgroundSessionConfiguration:",
                                   reinterpret_cast<IMP>(hook_background_config), &g_orig_bg_legacy))
        log_line("hook: +[%s backgroundSessionConfiguration:]", cls);
}

} // namespace fndiag
