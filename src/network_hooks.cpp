#include "fndiag/config.hpp"
#include "fndiag/hooks.hpp"
#include "fndiag/log.hpp"
#include "fndiag/objc_util.hpp"

#include <sys/stat.h>

#include <cstring>
#include <mutex>
#include <set>
#include <string>

namespace fndiag {
namespace {

using objc::describe;
using objc::send;
using objc::sel;
using objc::to_string;

constexpr size_t kMaxUserInfo = 600;

std::mutex g_mutex;
std::set<Class> g_instrumented; // clases delegadas ya enganchadas
std::set<IMP> g_ours;           // IMPs creadas por nosotros (evita doble enganche por herencia)
IMP g_orig_factory = nullptr;   // +[NSURLSession sessionWithConfiguration:delegate:delegateQueue:]

std::string task_url(id task) {
    id request = send<id>(task, sel("originalRequest"));
    if (!request)
        return "(nil)";
    id url = send<id>(request, sel("URL"));
    return url ? to_string(send<id>(url, sel("absoluteString"))) : "(nil)";
}

void log_completion(id task, id error) {
    if (!error && !config().verbose)
        return;

    id response = send<id>(task, sel("response"));
    long status = (response && objc::responds(response, "statusCode")) ? send<long>(response, sel("statusCode")) : -1;

    log_line("task #%lu %s completed: %s", send<unsigned long>(task, sel("taskIdentifier")), class_getName(object_getClass(task)),
        error ? "ERROR" : "ok");
    log_line("  desc=%s", to_string(send<id>(task, sel("taskDescription"))).c_str());
    log_line("  url=%s", task_url(task).c_str());
    log_line("  http_status=%ld bytes=%lld/%lld", status, send<long long>(task, sel("countOfBytesReceived")),
        send<long long>(task, sel("countOfBytesExpectedToReceive")));
    if (error) {
        std::string info = describe(send<id>(error, sel("userInfo")));
        if (info.size() > kMaxUserInfo)
            info.resize(kMaxUserInfo);
        for (char &ch : info)
            if (ch == '\n')
                ch = ' '; // una linea de log por campo
        log_line("  error domain=%s code=%ld", to_string(send<id>(error, sel("domain"))).c_str(), send<long>(error, sel("code")));
        log_line("  error text=%s", to_string(send<id>(error, sel("localizedDescription"))).c_str());
        log_line("  error userInfo=%s", info.c_str());
    }
}

void log_download_finished(id task, id location) {
    if (!config().verbose)
        return;
    std::string path = location ? to_string(send<id>(location, sel("path"))) : "(nil)";
    struct stat st{};
    bool exists = location && stat(path.c_str(), &st) == 0;
    id response = send<id>(task, sel("response"));
    long status = (response && objc::responds(response, "statusCode")) ? send<long>(response, sel("statusCode")) : -1;
    log_line("download finished: task #%lu http=%ld path=%s exists=%d size=%lld", send<unsigned long>(task, sel("taskIdentifier")),
             status, path.c_str(), exists, exists ? static_cast<long long>(st.st_size) : -1LL);
}

// Tras volver el delegado: si el temporal sigue ahi, el juego no lo movio.
void log_after_delegate(id task, id location) {
    if (!config().verbose)
        return;
    std::string path = location ? to_string(send<id>(location, sel("path"))) : "(nil)";
    struct stat st{};
    bool exists = location && stat(path.c_str(), &st) == 0;
    log_line("after delegate: task #%lu temp still exists=%d", send<unsigned long>(task, sel("taskIdentifier")), exists);
}

// En C++ puro un bloque no convierte implicitamente a `id`.
template <typename B>
IMP imp_from_block(B block) {
    return imp_implementationWithBlock(reinterpret_cast<id>(block));
}

// Sustituye el metodo `selector` de `cls` por el IMP que devuelve `make_imp`
// (un bloque que registra y luego llama a la implementacion original de esa
// clase). Cada bloque captura su propio `orig`, asi no hay recursion con super.
template <typename Block>
bool wrap_method(Class cls, const char *selector, Block make_imp) {
    SEL s = sel(selector);
    Method m = class_getInstanceMethod(cls, s);
    if (!m)
        return false;
    IMP orig = method_getImplementation(m);
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (g_ours.count(orig))
            return true; // ya enganchado en una superclase
    }
    IMP imp = make_imp(orig, s);
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_ours.insert(imp);
    }
    class_replaceMethod(cls, s, imp, method_getTypeEncoding(m));
    return true;
}

void instrument(id delegate) {
    if (!delegate)
        return;
    Class cls = object_getClass(delegate);
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (!g_instrumented.insert(cls).second)
            return;
    }

    bool a = wrap_method(cls, "URLSession:task:didCompleteWithError:", [](IMP orig, SEL s) {
        return imp_from_block(^(id self, id session, id task, id error) {
            log_completion(task, error);
            reinterpret_cast<void (*)(id, SEL, id, id, id)>(orig)(self, s, session, task, error);
        });
    });
    bool b = wrap_method(cls, "URLSession:downloadTask:didFinishDownloadingToURL:", [](IMP orig, SEL s) {
        return imp_from_block(^(id self, id session, id task, id location) {
            log_download_finished(task, location); // antes: el fichero temporal solo existe durante esta llamada
            reinterpret_cast<void (*)(id, SEL, id, id, id)>(orig)(self, s, session, task, location);
            log_after_delegate(task, location);
        });
    });
    log_line("delegate class %s: didCompleteWithError=%d didFinishDownloading=%d", class_getName(cls), a, b);
}

id hook_session_factory(id self, SEL cmd, id config_obj, id delegate, id queue) {
    id identifier = config_obj ? send<id>(config_obj, sel("identifier")) : nullptr;
    log_line("session created: delegate=%s config.identifier=%s", delegate ? class_getName(object_getClass(delegate)) : "(nil)",
        to_string(identifier).c_str());
    instrument(delegate);
    return reinterpret_cast<id (*)(id, SEL, id, id, id)>(g_orig_factory)(self, cmd, config_obj, delegate, queue);
}

} // namespace

void install_network_hooks() {
    if (objc::replace_class_method("NSURLSession", "sessionWithConfiguration:delegate:delegateQueue:",
                                   reinterpret_cast<IMP>(hook_session_factory), &g_orig_factory))
        log_line("hook: +[NSURLSession sessionWithConfiguration:delegate:delegateQueue:]");
    else
        log_line("AVISO: no se pudo enganchar sessionWithConfiguration:delegate:delegateQueue:");
}

} // namespace fndiag
