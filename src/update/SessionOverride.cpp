#include "core/Config.hpp"
#include "core/DiagLog.hpp"
#include "hooks/ObjcUtil.hpp"
#include "update/UpdateHooks.hpp"

#include <CoreFoundation/CoreFoundation.h>
#include <cstdlib>
#include <string>

namespace fndiag {
namespace {

using objc::send;
using objc::sel;

std::string container_tag() {
    const char* home = getenv("HOME");
    if (!home) return "";
    std::string h(home);
    size_t data = h.rfind("/Data");
    if (data == std::string::npos || data == 0) return "";
    size_t slash = h.rfind('/', data - 1);
    if (slash == std::string::npos) return "";
    return h.substr(slash + 1, data - slash - 1);
}

IMP g_orig_bg        = nullptr;
IMP g_orig_bg_legacy = nullptr;

id hook_background_config(id self, SEL cmd, id identifier) {
    log_line("background session requested: identifier=%s", objc::to_string(identifier).c_str());
    if (config().foreground_sessions) {
        log_line("  -> configuracion efimera en proceso");
        return send<id>(self, sel("ephemeralSessionConfiguration"));
    }
    IMP orig = (cmd == sel("backgroundSessionConfigurationWithIdentifier:")) ? g_orig_bg : g_orig_bg_legacy;
    auto call = reinterpret_cast<id (*)(id, SEL, id)>(orig);

    static const std::string tag = container_tag();
    std::string base = objc::to_string(identifier);
    if (config().isolate_sessions && identifier && !tag.empty() && base.find(tag) == std::string::npos) {
        std::string isolated = base + "." + tag;
        CFStringRef str = CFStringCreateWithCString(nullptr, isolated.c_str(), kCFStringEncodingUTF8);
        log_line("  -> identificador aislado: %s", isolated.c_str());
        id cfg = call(self, cmd, reinterpret_cast<id>(const_cast<__CFString*>(str)));
        CFRelease(str);
        return cfg;
    }
    return call(self, cmd, identifier);
}

} // namespace

void install_session_override() {
    const char* cls = "NSURLSessionConfiguration";
    if (objc::replace_class_method(cls, "backgroundSessionConfigurationWithIdentifier:",
                                   reinterpret_cast<IMP>(hook_background_config), &g_orig_bg))
        log_line("hook: +[%s backgroundSessionConfigurationWithIdentifier:]", cls);
    else
        log_line("AVISO: no se pudo enganchar backgroundSessionConfigurationWithIdentifier:");

    if (objc::replace_class_method(cls, "backgroundSessionConfiguration:",
                                   reinterpret_cast<IMP>(hook_background_config), &g_orig_bg_legacy))
        log_line("hook: +[%s backgroundSessionConfiguration:]", cls);
}

} // namespace fndiag
