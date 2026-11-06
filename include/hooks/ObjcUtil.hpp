#pragma once
#include <objc/message.h>
#include <objc/runtime.h>
#include <string>

// Utilidades genericas de enganche ObjC. Agnosticas a la logica de negocio.
namespace fndiag::objc {

// objc_msgSend con la firma correcta para cada llamada.
template <typename R, typename... Args>
inline R send(id obj, SEL sel, Args... args) {
    return reinterpret_cast<R (*)(id, SEL, Args...)>(objc_msgSend)(obj, sel, args...);
}

inline SEL sel(const char* name) { return sel_registerName(name); }

// NSString -> UTF-8. Devuelve "(nil)" o "(?)" si no es NSString.
std::string to_string(id nsstring);

// -[obj description] como std::string.
std::string describe(id obj);

// true si obj responde al selector.
bool responds(id obj, const char* selector);

// Reemplaza un metodo de clase. false si la clase o el metodo no existen.
// Guarda la implementacion anterior en *orig.
bool replace_class_method(const char* class_name, const char* selector, IMP imp, IMP* orig);

// Igual, para un metodo de instancia.
bool replace_instance_method(const char* class_name, const char* selector, IMP imp, IMP* orig);

// Swizzle seguro: sustituye `sel` en `cls` por `newImp` y guarda el original en *orig.
// No hace nada si la clase o el metodo no existen.
inline void swizzle(Class cls, SEL s, IMP newImp, IMP* orig) {
    Method m = cls ? class_getInstanceMethod(cls, s) : nullptr;
    if (!m) return;
    IMP old = method_setImplementation(m, newImp);
    if (orig) *orig = old;
}

} // namespace fndiag::objc
