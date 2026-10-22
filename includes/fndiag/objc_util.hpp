#pragma once

#include <objc/message.h>
#include <objc/runtime.h>

#include <string>

namespace fndiag::objc {

// objc_msgSend con la firma correcta para cada llamada.
template <typename R, typename... Args>
inline R send(id obj, SEL sel, Args... args) {
    return reinterpret_cast<R (*)(id, SEL, Args...)>(objc_msgSend)(obj, sel, args...);
}

inline SEL sel(const char *name) { return sel_registerName(name); }

// NSString -> UTF-8. "(nil)" si es nil, "(?)" si no es un NSString.
std::string to_string(id nsstring);

// -[obj description] como std::string.
std::string describe(id obj);

// true si obj responde al selector.
bool responds(id obj, const char *selector);

// Sustituye un metodo de clase. Devuelve false si la clase o el metodo no
// existen; en caso contrario guarda la implementacion anterior en *orig.
bool replace_class_method(const char *class_name, const char *selector, IMP imp, IMP *orig);

// Igual, para un metodo de instancia.
bool replace_instance_method(const char *class_name, const char *selector, IMP imp, IMP *orig);

} // namespace fndiag::objc
