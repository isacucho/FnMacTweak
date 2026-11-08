#include "core/Config.hpp"
#include "core/DiagLog.hpp"
#include "hooks/ObjcUtil.hpp"
#include "update/UpdateHooks.hpp"
#include "network/EacHooks.hpp"

#include <sys/stat.h>
#include <cstring>
#include <mutex>
#include <set>
#include <string>
#import <Foundation/Foundation.h>

namespace fndiag {
namespace {

using objc::describe;
using objc::send;
using objc::sel;
using objc::to_string;

constexpr size_t kMaxUserInfo = 600;

std::mutex g_mutex;
std::set<Class> g_instrumented;
std::set<IMP>   g_ours;
IMP g_orig_factory = nullptr;
IMP g_orig_dataTaskWithRequest = nullptr;
IMP g_orig_dataTaskWithRequestCompletion = nullptr;

std::string task_url(id task) {
    id request = send<id>(task, sel("originalRequest"));
    if (!request) return "(nil)";
    id url = send<id>(request, sel("URL"));
    return url ? to_string(send<id>(url, sel("absoluteString"))) : "(nil)";
}

void log_completion(id task, id error) {
    if (!error && !config().verbose) return;
    id response = send<id>(task, sel("response"));
    long status = (response && objc::responds(response, "statusCode")) ? send<long>(response, sel("statusCode")) : -1;
    log_line("task #%lu %s completed: %s",
             send<unsigned long>(task, sel("taskIdentifier")), class_getName(object_getClass(task)),
             error ? "ERROR" : "ok");
    log_line("  url=%s", task_url(task).c_str());
    log_line("  http_status=%ld bytes=%lld/%lld", status,
             send<long long>(task, sel("countOfBytesReceived")),
             send<long long>(task, sel("countOfBytesExpectedToReceive")));
    if (error) {
        std::string info = describe(send<id>(error, sel("userInfo")));
        if (info.size() > kMaxUserInfo) info.resize(kMaxUserInfo);
        for (char& ch : info) if (ch == '\n') ch = ' ';
        log_line("  error domain=%s code=%ld", to_string(send<id>(error, sel("domain"))).c_str(), send<long>(error, sel("code")));
        log_line("  error text=%s", to_string(send<id>(error, sel("localizedDescription"))).c_str());
        log_line("  error userInfo=%s", info.c_str());
    }
}

void log_download_finished(id task, id location) {
    if (!config().verbose) return;
    std::string path = location ? to_string(send<id>(location, sel("path"))) : "(nil)";
    struct stat st{};
    bool exists = location && stat(path.c_str(), &st) == 0;
    id response = send<id>(task, sel("response"));
    long status = (response && objc::responds(response, "statusCode")) ? send<long>(response, sel("statusCode")) : -1;
    log_line("download finished: task #%lu http=%ld path=%s exists=%d size=%lld",
             send<unsigned long>(task, sel("taskIdentifier")), status, path.c_str(), exists,
             exists ? static_cast<long long>(st.st_size) : -1LL);
}

void log_after_delegate(id task, id location) {
    if (!config().verbose) return;
    std::string path = location ? to_string(send<id>(location, sel("path"))) : "(nil)";
    struct stat st{};
    bool exists = location && stat(path.c_str(), &st) == 0;
    log_line("after delegate: task #%lu temp still exists=%d", send<unsigned long>(task, sel("taskIdentifier")), exists);
}

// Funció auxiliar per pegar el canvi a qualsevol NSURLRequest que vagi a verify/event
id patch_request_if_needed(id request) {
    if (!request) return nil;
    NSURL *url = [request URL];
    NSString *urlString = [url absoluteString];
    
    if (urlString && [urlString containsString:@"/api/verify/event"]) {
        std::string aid_str = fndiag_get_logged_account_id();
        if (aid_str.empty()) {
            log_line("[NetHook] verify/event: account_id no disponible aun, omitiendo inyeccion");
            return request;
        }
        NSString *aid = [NSString stringWithUTF8String:aid_str.c_str()];
        log_line("[NetHook] verify/event -> inyectando account_id: %s", aid_str.c_str());
        NSMutableURLRequest *mutableReq = [request mutableCopy];

        [mutableReq setValue:aid forHTTPHeaderField:@"X-Epic-AccountId"];
        [mutableReq setValue:aid forHTTPHeaderField:@"AccountID"];

        NSData *body = [mutableReq HTTPBody];
        if (body) {
            NSError *jsonError = nil;
            id JSONObject = [NSJSONSerialization JSONObjectWithData:body options:NSJSONReadingMutableContainers error:&jsonError];
            if ([JSONObject isKindOfClass:[NSMutableDictionary class]] && !jsonError) {
                NSMutableDictionary *jsonDict = (NSMutableDictionary *)JSONObject;
                if (!jsonDict[@"accountId"] && !jsonDict[@"AccountID"]) {
                    jsonDict[@"accountId"] = aid;
                    NSData *newBody = [NSJSONSerialization dataWithJSONObject:jsonDict options:0 error:nil];
                    if (newBody) {
                        [mutableReq setHTTPBody:newBody];
                        log_line("[NetHook] account_id inyectado en JSON body de verify/event");
                    }
                }
            }
        } else {
            NSDictionary *dict = @{@"accountId": aid};
            NSData *newBody = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
            if (newBody) {
                [mutableReq setHTTPBody:newBody];
                [mutableReq setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
                log_line("[NetHook] body creado con account_id para verify/event");
            }
        }
        return mutableReq;
    }
    return request;
}

// Hooks segurs per a dataTaskWithRequest:
id hook_dataTaskWithRequest(id self, SEL cmd, id request) {
    id patchedRequest = patch_request_if_needed(request);
    auto orig = reinterpret_cast<id (*)(id, SEL, id)>(g_orig_dataTaskWithRequest);
    return orig ? orig(self, cmd, patchedRequest) : nil;
}

id hook_dataTaskWithRequestCompletion(id self, SEL cmd, id request, id completionHandler) {
    id patchedRequest = patch_request_if_needed(request);
    auto orig = reinterpret_cast<id (*)(id, SEL, id, id)>(g_orig_dataTaskWithRequestCompletion);
    return orig ? orig(self, cmd, patchedRequest, completionHandler) : nil;
}

template <typename B>
IMP imp_from_block(B block) {
    void* block_ptr = (__bridge void*)block;
    return imp_implementationWithBlock((__bridge id)block_ptr);
}

template <typename Block>
bool wrap_method(Class cls, const char* selector, Block make_imp) {
    SEL s = sel(selector);
    Method m = class_getInstanceMethod(cls, s);
    if (!m) return false;
    IMP orig = method_getImplementation(m);
    { std::lock_guard<std::mutex> lock(g_mutex); if (g_ours.count(orig)) return true; }
    IMP imp = make_imp(orig, s);
    { std::lock_guard<std::mutex> lock(g_mutex); g_ours.insert(imp); }
    class_replaceMethod(cls, s, imp, method_getTypeEncoding(m));
    return true;
}

void instrument(id delegate) {
    if (!delegate) return;
    Class cls = object_getClass(delegate);
    { std::lock_guard<std::mutex> lock(g_mutex); if (!g_instrumented.insert(cls).second) return; }

    bool a = wrap_method(cls, "URLSession:task:didCompleteWithError:", [](IMP orig, SEL s) {
        return imp_from_block(^(id self, id session, id task, id error) {
            log_completion(task, error);
            reinterpret_cast<void (*)(id, SEL, id, id, id)>(orig)(self, s, session, task, error);
        });
    });
    bool b = wrap_method(cls, "URLSession:downloadTask:didFinishDownloadingToURL:", [](IMP orig, SEL s) {
        return imp_from_block(^(id self, id session, id task, id location) {
            log_download_finished(task, location);
            reinterpret_cast<void (*)(id, SEL, id, id, id)>(orig)(self, s, session, task, location);
            log_after_delegate(task, location);
        });
    });
    log_line("delegate class %s: didCompleteWithError=%d didFinishDownloading=%d", class_getName(cls), a, b);
}

id hook_session_factory(id self, SEL cmd, id config_obj, id delegate, id queue) {
    // Inyectar FnContentLinkProtocol en la config de cada sesion para que el NSURLProtocol
    // custom intercepte las requests a experience_br (fix NumLoadCustomizationFailed >= 3).
    if (config_obj) {
        NSURLSessionConfiguration *cfg = (NSURLSessionConfiguration *)config_obj;
        Class patchClass = NSClassFromString(@"FnContentLinkProtocol");
        if (patchClass) {
            NSMutableArray *protocols = [NSMutableArray arrayWithArray:cfg.protocolClasses ?: @[]];
            if (![protocols containsObject:patchClass]) {
                [protocols insertObject:patchClass atIndex:0];
                cfg.protocolClasses = protocols;
            }
        }
    }

    id identifier = config_obj ? send<id>(config_obj, sel("identifier")) : nullptr;
    log_line("session created: delegate=%s config.identifier=%s",
             delegate ? class_getName(object_getClass(delegate)) : "(nil)",
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

    Class sessionClass = objc_getClass("NSURLSession");

    // Hook per a dataTaskWithRequest:
    Method m1 = class_getInstanceMethod(sessionClass, sel("dataTaskWithRequest:"));
    if (m1) {
        g_orig_dataTaskWithRequest = method_getImplementation(m1);
        method_setImplementation(m1, reinterpret_cast<IMP>(hook_dataTaskWithRequest));
        log_line("hook: -[NSURLSession dataTaskWithRequest:] instal·lat");
    }

    // Hook per a dataTaskWithRequest:completionHandler:
    Method m2 = class_getInstanceMethod(sessionClass, sel("dataTaskWithRequest:completionHandler:"));
    if (m2) {
        g_orig_dataTaskWithRequestCompletion = method_getImplementation(m2);
        method_setImplementation(m2, reinterpret_cast<IMP>(hook_dataTaskWithRequestCompletion));
        log_line("hook: -[NSURLSession dataTaskWithRequest:completionHandler:] instal·lat");
    }
}

} // namespace fndiag