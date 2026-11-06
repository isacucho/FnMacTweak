#include "hooks/ObjcUtil.hpp"
#include <CoreFoundation/CoreFoundation.h>

namespace fndiag::objc {

std::string to_string(id nsstring) {
    if (!nsstring) return "(nil)";
    CFTypeRef ref = reinterpret_cast<CFTypeRef>(nsstring);
    if (CFGetTypeID(ref) != CFStringGetTypeID()) return "(?)";
    CFStringRef str = static_cast<CFStringRef>(ref);
    CFIndex max = CFStringGetMaximumSizeForEncoding(CFStringGetLength(str), kCFStringEncodingUTF8) + 1;
    std::string out(static_cast<size_t>(max), '\0');
    if (!CFStringGetCString(str, out.data(), max, kCFStringEncodingUTF8)) return "(?)";
    out.resize(out.find('\0'));
    return out;
}

std::string describe(id obj) {
    if (!obj) return "(nil)";
    return to_string(send<id>(obj, sel("description")));
}

bool responds(id obj, const char* selector) {
    return obj && send<signed char>(obj, sel("respondsToSelector:"), sel(selector));
}

bool replace_class_method(const char* class_name, const char* selector, IMP imp, IMP* orig) {
    Class cls = objc_getClass(class_name);
    if (!cls) return false;
    Method m = class_getClassMethod(cls, sel(selector));
    if (!m) return false;
    *orig = method_setImplementation(m, imp);
    return true;
}

bool replace_instance_method(const char* class_name, const char* selector, IMP imp, IMP* orig) {
    Class cls = objc_getClass(class_name);
    if (!cls) return false;
    Method m = class_getInstanceMethod(cls, sel(selector));
    if (!m) return false;
    *orig = method_setImplementation(m, imp);
    return true;
}

} // namespace fndiag::objc
