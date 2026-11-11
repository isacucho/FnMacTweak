#import "network/EacHooks.hpp"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <cstdint>
#include <mutex>
#include <string>
#include <dlfcn.h>
#include <dispatch/dispatch.h>
#include <mach-o/dyld.h>
#include <CommonCrypto/CommonCrypto.h>
#include "core/Logger.hpp"
#include "core/DiagLog.hpp"

static NSString*        gVerifyMatchData = nil;
static dispatch_queue_t gVerifyQueue     = NULL;

static std::mutex  g_aid_mutex;
static std::string g_account_id;

static const char* cstr(NSString* s) { return s ? [s UTF8String] : "(nil)"; }

static void capture_account_id(NSData* body) {
    NSDictionary* obj = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return;
    NSString* aid = obj[@"account_id"];
    if (!aid || aid.length == 0) return;
    {
        std::lock_guard<std::mutex> lk(g_aid_mutex);
        g_account_id = [aid UTF8String];
    }
    fndiag::log_line("[Auth] account_id captured: %s", [aid UTF8String]);
}

std::string fndiag_get_logged_account_id() {
    std::lock_guard<std::mutex> lk(g_aid_mutex);
    return g_account_id;
}

static int httpStatus(NSURLSessionTask* task) {
    NSURLResponse* r = task.response;
    if ([r isKindOfClass:[NSHTTPURLResponse class]]) return (int)((NSHTTPURLResponse*)r).statusCode;
    return -1;
}

static bool ownsMethod(Class cls, SEL sel) {
    unsigned int n = 0;
    Method* list = class_copyMethodList(cls, &n);
    bool found = false;
    for (Method* p = list; p < list + n; ++p)
        if (sel_isEqual(method_getName(*p), sel)) { found = true; break; }
    free(list);
    return found;
}

typedef void (*FinishFn)(id, SEL, NSURLSession*, NSURLSessionDownloadTask*, NSURL*);
typedef void (*CompleteFn)(id, SEL, NSURLSession*, NSURLSessionTask*, NSError*);
typedef void (*DataFn)(id, SEL, NSURLSession*, NSURLSessionDataTask*, NSData*);

#ifndef PRODUCTION
static void dumpPayload(NSURLSessionTask* task, NSURL* fileURL) {
    @autoreleasepool {
        NSError* err = nil;
        NSData* data = [NSData dataWithContentsOfURL:fileURL options:NSDataReadingMappedIfSafe error:&err];
        if (!data) { LOG_W("Payload", "id=%lu read failed: %s", (unsigned long)task.taskIdentifier, cstr([err description])); return; }
        NSUInteger len = data.length;
        const uint8_t* bytes = (const uint8_t*)data.bytes;
        NSHTTPURLResponse* http = [task.response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse*)task.response : nil;
        NSString* ctype = http ? http.allHeaderFields[@"Content-Type"] : nil;
        LOG_W("Payload", "id=%lu url=%s len=%lu ctype=%s",
              (unsigned long)task.taskIdentifier, cstr(task.originalRequest.URL.absoluteString),
              (unsigned long)len, cstr(ctype));
        if (len == 0) return;
        bool text = !(len >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b);
        NSUInteger probe = len < 256 ? len : 256;
        for (NSUInteger i = 0; i < probe; i++) {
            uint8_t b = bytes[i];
            if (b == 0 || (b < 0x09) || (b > 0x0d && b < 0x20)) { text = false; break; }
        }
        NSUInteger dumpLen = len < 1024 ? len : 1024;
        if (text) {
            NSString* s = [[NSString alloc] initWithBytes:bytes length:dumpLen encoding:NSUTF8StringEncoding];
            if (s) LOG_W("Payload", "id=%lu text[%lu]=%s", (unsigned long)task.taskIdentifier, (unsigned long)dumpLen, cstr(s));
        } else {
            LOG_W("Payload", "id=%lu hex=%s", (unsigned long)task.taskIdentifier,
                  cstr([NSString stringWithFormat:@"%@", [NSData dataWithBytes:bytes length:dumpLen]]));
        }
    }
}
#endif

static void hookFinish(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    FinishFn orig = (FinishFn)method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(id self_, NSURLSession* session, NSURLSessionDownloadTask* task, NSURL* loc) {
        @autoreleasepool {
#ifndef PRODUCTION
            NSDictionary* attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:loc.path error:nil];
            LOG_W("NetHook", "didFinish id=%lu http=%d fileSize=%llu loc=%s",
                  (unsigned long)task.taskIdentifier, httpStatus(task),
                  (unsigned long long)[attrs fileSize], cstr(loc.path));
            dumpPayload(task, loc);
#endif
        }
        if (orig) orig(self_, sel, session, task, loc);
    }));
}

static void hookComplete(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    CompleteFn orig = (CompleteFn)method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(id self_, NSURLSession* session, NSURLSessionTask* task, NSError* error) {
#ifndef PRODUCTION
        NSString* complUrl = task.originalRequest.URL.absoluteString;
        LOG_W("NetHook", "didComplete id=%lu http=%d error=%s url=%s",
              (unsigned long)task.taskIdentifier, httpStatus(task),
              error ? cstr([error description]) : "none",
              cstr(complUrl));
#endif
        if (orig) orig(self_, sel, session, task, error);
    }));
}

static NSData* spoof_eac_response(NSData* data, NSURLSessionDataTask* task, NSString* url) {
    NSString* json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!json) return data;

    NSString* endpoint = [url lastPathComponent];
    int http = httpStatus(task);

    fndiag::log_line("[EAC-HTTP] %s http=%d body=%s",
                     [endpoint UTF8String], http,
                     [[json substringToIndex:MIN(200u, (unsigned)json.length)] UTF8String]);

    bool rejected = (http == 403) || (http == 400) || (http >= 500) ||
                    [json containsString:@"\"allow\":false"] ||
                    [json containsString:@"\"allow\" : false"] ||
                    [json containsString:@"\"success\":false"] ||
                    [json containsString:@"\"success\" : false"] ||
                    [json containsString:@"\"status\":\"error\""] ||
                    [json containsString:@"\"status\": \"error\""];
    if (!rejected) return data;

    NSString* spoofed = json;
    spoofed = [spoofed stringByReplacingOccurrencesOfString:@"\"allow\":false"   withString:@"\"allow\":true"];
    spoofed = [spoofed stringByReplacingOccurrencesOfString:@"\"allow\" : false" withString:@"\"allow\" : true"];
    spoofed = [spoofed stringByReplacingOccurrencesOfString:@"\"success\":false"   withString:@"\"success\":true"];
    spoofed = [spoofed stringByReplacingOccurrencesOfString:@"\"success\" : false" withString:@"\"success\" : true"];
    if ([spoofed isEqualToString:json]) {
        spoofed = @"{\"allow\":true,\"success\":true}";
    }
    fndiag::log_line("[EAC-SPOOF] %s: forced success (http=%d was: %s)",
                     [endpoint UTF8String], http,
                     [[json substringToIndex:MIN(100u, (unsigned)json.length)] UTF8String]);
    return [spoofed dataUsingEncoding:NSUTF8StringEncoding];
}

static void hookReceiveData(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    DataFn orig = (DataFn)method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(id self_, NSURLSession* session, NSURLSessionDataTask* task, NSData* data) {
        NSData* outData = data;
        @autoreleasepool {
            NSString* url = task.originalRequest.URL.absoluteString;

            if (url && ([url containsString:@"verify/match"] ||
                        [url containsString:@"verify/event"] ||
                        [url containsString:@"verify/session"] ||
                        [url containsString:@"anticheat"])) {
                outData = spoof_eac_response(data, task, url);
            }

            if (url && [url containsString:@"oauth/token"]) {
                capture_account_id(data);
            }

#ifndef PRODUCTION
            NSHTTPURLResponse* http = [task.response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse*)task.response : nil;
            NSString* ctype = http ? http.allHeaderFields[@"Content-Type"] : nil;

            if (url && [url containsString:@"verify/match"]) {
                NSString* json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if (json) {
                    LOG_W("EAC-RawRx", "SERVER -> CLIENT [verify/match] http=%d len=%lu body=%s",
                          httpStatus(task), (unsigned long)data.length, cstr(json));
                    NSDictionary* obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    if ([obj isKindOfClass:[NSDictionary class]]) {
                        NSString* d = obj[@"data"];
                        if (d && gVerifyQueue) {
                            dispatch_sync(gVerifyQueue, ^{ gVerifyMatchData = [d copy]; });
                            LOG_W("EAC-RawRx", "guardado data=%s", cstr(d));
                        }
                    }
                } else {
                    LOG_W("EAC-RawRx", "SERVER -> CLIENT [verify/match] http=%d len=%lu <bin>",
                          httpStatus(task), (unsigned long)data.length);
                }
            }
            if (url && [url containsString:@"verify/event"]) {
                NSString* json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if (json)
                    LOG_W("EAC-RawRx", "SERVER -> CLIENT [verify/event] http=%d len=%lu body=%s",
                          httpStatus(task), (unsigned long)data.length, cstr(json));
                else
                    LOG_W("EAC-RawRx", "SERVER -> CLIENT [verify/event] http=%d len=%lu <bin>",
                          httpStatus(task), (unsigned long)data.length);
            }
            if (url && [url containsString:@"sdk/v1/product"]) {
                NSString* json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                LOG_W("EAC-ProdCfg", "EOS product config http=%d len=%lu body=%s",
                      httpStatus(task), (unsigned long)data.length, json ? cstr(json) : "<bin>");
            }
            LOG_W("NetHook", "didReceiveData id=%lu chunk=%lu url=%s ctype=%s",
                  (unsigned long)task.taskIdentifier, (unsigned long)data.length, cstr(url), cstr(ctype));
#endif
        }
        if (orig) orig(self_, sel, session, task, outData);
    }));
}

typedef BOOL (*MoveURLFn)(id, SEL, NSURL*, NSURL*, NSError**);

static void hookFileManager() {
    Class cls = [NSFileManager class];
    SEL selMove = @selector(moveItemAtURL:toURL:error:);
    Method mm = class_getInstanceMethod(cls, selMove);
    if (mm) {
        MoveURLFn origMove = (MoveURLFn)method_getImplementation(mm);
        method_setImplementation(mm, imp_implementationWithBlock(^BOOL(id self_, NSURL* src, NSURL* dst, NSError** err) {
#ifndef PRODUCTION
            BOOL ok = origMove ? origMove(self_, selMove, src, dst, err) : NO;
            if (src.path && [src.path containsString:@"BackgroundHttp"])
                LOG_W("FMHook", "move ok=%d src=%s dst=%s", ok, cstr(src.path), cstr(dst.path));
            return ok;
#else
            return origMove ? origMove(self_, selMove, src, dst, err) : NO;
#endif
        }));
    }
}

static id (*orig_dataTaskWithRequest)(id, SEL, NSURLRequest*) = NULL;
static id h_dataTaskWithRequest(id self, SEL _cmd, NSURLRequest* request) {
    if (request && [request isKindOfClass:[NSURLRequest class]]) {
        NSString* urlStr = [[request URL] absoluteString];
        if (urlStr && ([urlStr containsString:@"epicgames.com"] || [urlStr containsString:@"epicgames.dev"])) {
            NSMutableURLRequest* mutableReq = [request mutableCopy];
            [mutableReq setValue:@"Fortnite/43.00.0 (iPad14,3; iPhone OS 17.5; Scale/3.00)" forHTTPHeaderField:@"User-Agent"];
            request = mutableReq;
        }
    }
    return orig_dataTaskWithRequest ? orig_dataTaskWithRequest(self, _cmd, request) : nil;
}

static void hookURLRequest() {
    Class reqClass = NSClassFromString(@"NSMutableURLRequest");

    SEL setBodySel = @selector(setHTTPBody:);
    Method setBodyMethod = class_getInstanceMethod(reqClass, setBodySel);
    if (setBodyMethod) {
        typedef void (*SetBodyFn)(id, SEL, NSData*);
        SetBodyFn origSetBody = (SetBodyFn)method_getImplementation(setBodyMethod);
        method_setImplementation(setBodyMethod, imp_implementationWithBlock(^(id self_, NSData* body) {
            NSString* urlStr = [self_ URL].absoluteString;
            NSData* outBody = body;
            if (urlStr) {
                if ([urlStr containsString:@"verify/"] || [urlStr containsString:@"matchmaking"]) {
                    if (body && body.length > 0) {
                        NSMutableString* hex = [NSMutableString string];
                        const uint8_t* bytes = (const uint8_t*)body.bytes;
                        NSUInteger dumpLen = body.length < 256 ? body.length : 256;
                        for (NSUInteger i = 0; i < dumpLen; i++)
                            [hex appendFormat:@"%02x", bytes[i]];
                        LOG_W("EAC-RawTx", "CLIENT -> SERVER [%s] body=[HEX] %s", cstr(urlStr), cstr(hex));
                    } else {
                        LOG_W("EAC-RawTx", "CLIENT -> SERVER [%s] body=(empty)", cstr(urlStr));
                    }
                    if (gVerifyQueue) {
                        dispatch_sync(gVerifyQueue, ^{
                            if (gVerifyMatchData && body) {
                                NSString* bodyStr = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
                                if (bodyStr && [bodyStr containsString:gVerifyMatchData])
                                    LOG_W("EAC-Echo", "CLIENT reenvia data EXACTO del server a %s", cstr(urlStr));
                            }
                        });
                    }

                }
                if ([urlStr containsString:@"oauth/token"]) {
                    NSString* bodyStr = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
                    if (bodyStr && [bodyStr containsString:@"refresh_token"]) {
                        LOG_W("EAC-Refresh", "CLIENT PIDE REFRESH TOKEN a %s", cstr(urlStr));
                        LOG_W("EAC-Refresh", "BODY: %s", cstr(bodyStr));
                    }
                }
            }
            if (origSetBody) origSetBody(self_, setBodySel, outBody);
        }));
    }

    SEL setURLSel = @selector(setURL:);
    Method setURLMethod = class_getInstanceMethod(reqClass, setURLSel);
    if (setURLMethod) {
        typedef void (*SetURLFn)(id, SEL, NSURL*);
        SetURLFn origSetURL = (SetURLFn)method_getImplementation(setURLMethod);
        method_setImplementation(setURLMethod, imp_implementationWithBlock(^(id self_, NSURL* url) {
            NSString* urlStr = url.absoluteString;
            if (urlStr && [urlStr containsString:@"verify/match"]) {
                NSString* query = [url query];
                LOG_W("EAC-RawTx", "CLIENT -> SERVER [verify/match] method=GET query=%s",
                      query ? cstr(query) : "(none)");
            }
            if (origSetURL) origSetURL(self_, setURLSel, url);
        }));
    }

    SEL setHeaderSel = @selector(setValue:forHTTPHeaderField:);
    Method setHeaderMethod = class_getInstanceMethod(reqClass, setHeaderSel);
    if (setHeaderMethod) {
        typedef void (*SetHeaderFn)(id, SEL, NSString*, NSString*);
        SetHeaderFn origSetHeader = (SetHeaderFn)method_getImplementation(setHeaderMethod);
        method_setImplementation(setHeaderMethod, imp_implementationWithBlock(^(id self_, NSString* value, NSString* field) {
            NSString* urlStr = [[self_ URL] absoluteString];
            if (urlStr && ([urlStr containsString:@"epicgames.com"] || [urlStr containsString:@"epicgames.dev"])) {
                if ([field caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame) {
                    value = @"Fortnite/43.00.0 (iPad14,3; iPhone OS 17.5; Scale/3.00)";
                }
                LOG_W("EAC-Auth", "CLIENT HEADER [%s]: %s = %s", cstr(urlStr), cstr(field), cstr(value));
            }
            if (origSetHeader) origSetHeader(self_, setHeaderSel, value, field);
        }));
    }

    SEL initSel = @selector(initWithURL:cachePolicy:timeoutInterval:);
    Method initMethod = class_getInstanceMethod(reqClass, initSel);
    if (initMethod) {
        typedef id (*InitFn)(id, SEL, NSURL*, NSURLRequestCachePolicy, NSTimeInterval);
        InitFn origInit = (InitFn)method_getImplementation(initMethod);
        method_setImplementation(initMethod, imp_implementationWithBlock(^id(id self_, NSURL* url, NSURLRequestCachePolicy policy, NSTimeInterval interval) {
            self_ = origInit ? origInit(self_, initSel, url, policy, interval) : self_;
            if (self_ && url) {
                NSString* urlStr = [url absoluteString];
                if ([urlStr containsString:@"epicgames.com"] || [urlStr containsString:@"epicgames.dev"]) {
                    [self_ setValue:@"Fortnite/43.00.0 (iPad14,3; iPhone OS 17.5; Scale/3.00)" forHTTPHeaderField:@"User-Agent"];
                }
            }
            return self_;
        }));
    }

    Class urlSessionCls = NSClassFromString(@"NSURLSession");
    if (urlSessionCls) {
        Method m = class_getInstanceMethod(urlSessionCls, @selector(dataTaskWithRequest:));
        if (m) {
            orig_dataTaskWithRequest = (id(*)(id, SEL, NSURLRequest*))method_getImplementation(m);
            method_setImplementation(m, (IMP)h_dataTaskWithRequest);
        }
    }
}

typedef void (*MSHookFunction_eac_t)(void*, void*, void**);

#ifndef PRODUCTION
static bool og_shouldSkipURL(NSString* url) {
    if (url.length == 0) return true;
    return [url containsString:@"datarouter"] || [url containsString:@"appsflyer"] || [url containsString:@"cdn"];
}

static NSString* og_hexDump(NSData* data, NSUInteger maxBytes) {
    if (!data) return @"";
    NSUInteger len = data.length;
    NSUInteger dump = len < maxBytes ? len : maxBytes;
    const uint8_t* bytes = (const uint8_t*)data.bytes;
    NSMutableString* hex = [NSMutableString stringWithCapacity:dump * 3];
    for (NSUInteger i = 0; i < dump; i++) [hex appendFormat:@"%02x ", bytes[i]];
    return hex;
}

typedef void (*CFSetBodyFn)(CFTypeRef, CFDataRef);
static CFSetBodyFn orig_CFSetBody = NULL;
static void h_CFSetBody(CFTypeRef req, CFDataRef body) {
    if (body && req) {
        CFIndex len = CFDataGetLength(body);
        if (len > 0) {
            NSMutableURLRequest* urlReq = (__bridge NSMutableURLRequest*)req;
            NSString* url = [urlReq URL].absoluteString;
            if (url && !og_shouldSkipURL(url)) {
                const UInt8* bytes = CFDataGetBytePtr(body);
                NSData* data = [NSData dataWithBytes:bytes length:len];
                LOG_W("CFNet-Tx", "[CFNetwork REQ] url=%s len=%lu HEX=%s",
                      cstr(url), (unsigned long)len, cstr(og_hexDump(data, 512)));
            }
        }
    }
    if (orig_CFSetBody) orig_CFSetBody(req, body);
}
#endif

#ifndef PRODUCTION
static IMP o_b64Enc = NULL;
static NSString* h_b64Enc(NSData* self, SEL _cmd, NSUInteger options) {
    if (!o_b64Enc) return nil;
    @autoreleasepool {
        NSUInteger len = self.length;
        if (len >= 200 && len <= 400) {
            NSData* copy = [self copy];
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                @autoreleasepool {
                    LOG_W("EAC-B64Pre", "pre-base64 (%lu bytes): %s",
                          (unsigned long)copy.length, cstr(og_hexDump(copy, 400)));
                }
            });
        }
    }
    return ((NSString* (*)(id, SEL, NSUInteger))o_b64Enc)(self, _cmd, options);
}
#endif

#ifndef PRODUCTION
static void og_installNetHooks(void) {
    MSHookFunction_eac_t mshook = NULL;
    void* handle = dlopen("/usr/lib/libsubstrate.dylib", RTLD_NOW);
    if (!handle) handle = dlopen("/usr/lib/libellekit.dylib", RTLD_NOW);
    if (handle) mshook = (MSHookFunction_eac_t)dlsym(handle, "MSHookFunction");

    void* cf_handle = dlopen("/System/Library/Frameworks/CFNetwork.framework/CFNetwork", RTLD_NOW);
    if (cf_handle) {
        void* sym = dlsym(cf_handle, "CFURLRequestSetHTTPRequestBody");
        if (sym && mshook) mshook(sym, (void*)h_CFSetBody, (void**)&orig_CFSetBody);
    }

    Class dataCls = NSClassFromString(@"NSData");
    if (dataCls && !o_b64Enc) {
        Method m = class_getInstanceMethod(dataCls, @selector(base64EncodedStringWithOptions:));
        if (m) { o_b64Enc = method_getImplementation(m); method_setImplementation(m, (IMP)h_b64Enc); }
    }
}
#endif

static const uintptr_t kPatchFileOff    = 0x24a8258;
static const uint8_t   kOrigBytes[4]    = {0xff, 0x03, 0x06, 0xd1};
static uintptr_t       s_patch_va       = 0;

static void init_patch_va() {
    if (s_patch_va) return;
    const struct mach_header* mh = _dyld_get_image_header(0);
    if (mh) s_patch_va = (uintptr_t)mh + kPatchFileOff;
}

extern "C" unsigned char* CC_SHA256(const void* data, CC_LONG len, unsigned char* md);

extern "C" unsigned char* fndiag_CC_SHA256(const void* data, CC_LONG len, unsigned char* md) {
    init_patch_va();
    uintptr_t buf = (uintptr_t)data;
    if (s_patch_va && buf <= s_patch_va && s_patch_va + 4 <= buf + (uintptr_t)len) {
        void* copy = malloc(len);
        if (copy) {
            memcpy(copy, data, len);
            memcpy((uint8_t*)copy + (s_patch_va - buf), kOrigBytes, 4);
            fndiag::log_line("[SHA256-SHADOW] patching hash at off=0x%zx len=%u",
                             (size_t)(s_patch_va - buf), (unsigned)len);
            unsigned char* r = CC_SHA256(copy, len, md);
            free(copy);
            return r;
        }
    }
    return CC_SHA256(data, len, md);
}

struct EAC_RxOpts { int32_t ApiVersion; uint32_t DataLengthBytes; const void* Data; };

extern "C" {
    uint64_t EOS_AntiCheatClient_AddNotifyClientIntegrityViolated(
        void* handle, const void* opts, void* cdata, void (*fn)(const void*));
    uint64_t EOS_AntiCheatClient_AddNotifyPeerActionRequired(
        void* handle, const void* opts, void* cdata, void (*fn)(const void*));
    int32_t  EOS_AntiCheatClient_PollStatus(void* handle, const void* opts, void* out_info);
    int32_t  EOS_AntiCheatClient_ReceiveMessageFromServer(void* handle, const void* opts);
    int32_t  EOS_AntiCheatClient_EndSession(void* handle, const void* opts);
    int32_t  EOS_AntiCheatClient_BeginSession(void* handle, const void* opts);
}

static void noop_eac_violation(const void*) {}

extern "C" {
uint64_t fndiag_add_notify_integrity(void* h, const void* o, void* /*c*/, void (* /*fn*/)(const void*)) {
    fndiag::log_line("[EAC-BYPASS] AddNotifyClientIntegrityViolated intercepted - no-op registered");
    return EOS_AntiCheatClient_AddNotifyClientIntegrityViolated(h, o, nullptr, noop_eac_violation);
}
uint64_t fndiag_add_notify_peer(void* h, const void* o, void* /*c*/, void (* /*fn*/)(const void*)) {
    fndiag::log_line("[EAC-BYPASS] AddNotifyPeerActionRequired intercepted - no-op registered");
    return EOS_AntiCheatClient_AddNotifyPeerActionRequired(h, o, nullptr, noop_eac_violation);
}
int32_t fndiag_poll_status(void* /*h*/, const void* /*o*/, void* /*out*/) {
    return 0;
}
int32_t fndiag_receive_msg_from_server(void* h, const void* opts) {
    static int s_count = 0;
    ++s_count;
    const EAC_RxOpts* o = static_cast<const EAC_RxOpts*>(opts);
    uint8_t b0 = 0, b1 = 0;
    if (o && o->Data && o->DataLengthBytes >= 2) {
        b0 = static_cast<const uint8_t*>(o->Data)[0];
        b1 = static_cast<const uint8_t*>(o->Data)[1];
    }

    // Sugerencia del companero: suprimir los tipos de informe 5, 19, 23, 49
    // cuando el indicador (b0) == 1. Estos mensajes EAC triggean el error
    // "Client failed to register with server" (errors.com.epicgames.common.processing).
    if (b0 == 1) {
        static const uint8_t kSuppressTypes[] = {5, 19, 23, 49};
        for (uint8_t t : kSuppressTypes) {
            if (b1 == t) {
                fndiag::log_line("[EAC-RX] SUPPRESSED indicator=%d type=%d (len=%u) #%d",
                                 (int)b0, (int)b1, o ? o->DataLengthBytes : 0u, s_count);
                return 0;
            }
        }
    }

    if (s_count <= 20 || (s_count % 50) == 0)
        fndiag::log_line("[EAC-RX] ReceiveMessageFromServer #%d len=%u b0=0x%02x b1=0x%02x",
                         s_count, o ? o->DataLengthBytes : 0, b0, b1);
    return EOS_AntiCheatClient_ReceiveMessageFromServer(h, opts);
}
int32_t fndiag_end_session(void* /*h*/, const void* /*opts*/) {
    static int s_es = 0;
    ++s_es;
    fndiag::log_line("[EAC-ENDSESSION] EndSession call #%d SUPPRESSED", s_es);
    return 0;
}

int32_t fndiag_begin_session(void* h, const void* opts) {
    // Loguear y reenviar. Si devuelve != 0, el SDK no se ha registrado.
    int32_t r = EOS_AntiCheatClient_BeginSession(h, opts);
    fndiag::log_line("[EAC-BEGIN] BeginSession result=%d (0=ok)", r);
    return r;
}

}

struct EacInterpose { const void* replacement; const void* original; };
#define EAC_INTERPOSE(fn, orig) {reinterpret_cast<const void*>(fn), reinterpret_cast<const void*>(orig)}
__attribute__((used, section("__DATA,__interpose"))) static const EacInterpose g_eac_interpose[] = {
    EAC_INTERPOSE(fndiag_add_notify_integrity,    EOS_AntiCheatClient_AddNotifyClientIntegrityViolated),
    EAC_INTERPOSE(fndiag_add_notify_peer,         EOS_AntiCheatClient_AddNotifyPeerActionRequired),
    EAC_INTERPOSE(fndiag_poll_status,             EOS_AntiCheatClient_PollStatus),
    EAC_INTERPOSE(fndiag_receive_msg_from_server, EOS_AntiCheatClient_ReceiveMessageFromServer),
    EAC_INTERPOSE(fndiag_end_session,             EOS_AntiCheatClient_EndSession),
    EAC_INTERPOSE(fndiag_begin_session,           EOS_AntiCheatClient_BeginSession),
    EAC_INTERPOSE(fndiag_CC_SHA256,               CC_SHA256),
};

// ----------------------------------------------------------------
// MSHookFunction-based EAC hooks.
// DYLD_INTERPOSE es inutil para EOS_AntiCheatClient_* porque el binario
// del juego no tiene stubs PLT para esas funciones (el UE5 plugin usa
// vtable interna en EOSSDK). MSHookFunction parchea el prologo directamente.
// ----------------------------------------------------------------
static int32_t (*g_orig_receive_msg)(void*, const void*) = nullptr;
static int32_t (*g_orig_begin_session)(void*, const void*) = nullptr;

static int32_t h_msh_receive_msg(void* h, const void* opts) {
    static int s_msh_count = 0;
    ++s_msh_count;
    const EAC_RxOpts* o = static_cast<const EAC_RxOpts*>(opts);
    uint8_t b0 = 0, b1 = 0;
    if (o && o->Data && o->DataLengthBytes >= 2) {
        b0 = static_cast<const uint8_t*>(o->Data)[0];
        b1 = static_cast<const uint8_t*>(o->Data)[1];
    }
    if (b0 == 1) {
        static const uint8_t kSuppress[] = {5, 19, 23, 49};
        for (uint8_t t : kSuppress) {
            if (b1 == t) {
                fndiag::log_line("[EAC-RX] SUPPRESSED indicator=%d type=%d (len=%u) #%d",
                                 (int)b0, (int)b1, o ? o->DataLengthBytes : 0u, s_msh_count);
                return 0;
            }
        }
    }
    if (s_msh_count <= 20 || (s_msh_count % 50) == 0)
        fndiag::log_line("[EAC-RX] ReceiveMsg #%d len=%u b0=0x%02x b1=0x%02x",
                         s_msh_count, o ? o->DataLengthBytes : 0, b0, b1);
    return g_orig_receive_msg ? g_orig_receive_msg(h, opts) : 0;
}

static int32_t h_msh_begin_session(void* h, const void* opts) {
    int32_t r = g_orig_begin_session ? g_orig_begin_session(h, opts) : 0;
    fndiag::log_line("[EAC-BEGIN] BeginSession result=%d (0=ok)", r);
    return r;
}

static void install_eac_mshooks() {
    MSHookFunction_eac_t mshook = (MSHookFunction_eac_t)dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (!mshook) {
        void* h = dlopen("/usr/lib/libsubstrate.dylib", RTLD_NOW);
        if (!h) h = dlopen("/usr/lib/libellekit.dylib", RTLD_NOW);
        if (h) mshook = (MSHookFunction_eac_t)dlsym(h, "MSHookFunction");
    }
    if (!mshook) {
        fndiag::log_line("[EAC-HOOK] MSHookFunction no disponible");
        return;
    }

    void* sym = dlsym(RTLD_DEFAULT, "_EOS_AntiCheatClient_ReceiveMessageFromServer");
    if (!sym) sym = dlsym(RTLD_DEFAULT, "EOS_AntiCheatClient_ReceiveMessageFromServer");
    if (sym) {
        mshook(sym, (void*)h_msh_receive_msg, (void**)&g_orig_receive_msg);
        fndiag::log_line("[EAC-HOOK] ReceiveMessageFromServer hooked @ %p", sym);
    } else {
        fndiag::log_line("[EAC-HOOK] WARN: ReceiveMessageFromServer no encontrado via dlsym");
    }

    void* sym2 = dlsym(RTLD_DEFAULT, "_EOS_AntiCheatClient_BeginSession");
    if (!sym2) sym2 = dlsym(RTLD_DEFAULT, "EOS_AntiCheatClient_BeginSession");
    if (sym2) {
        mshook(sym2, (void*)h_msh_begin_session, (void**)&g_orig_begin_session);
        fndiag::log_line("[EAC-HOOK] BeginSession hooked @ %p", sym2);
    }
}

void installNetHooks(void) {
    if (!gVerifyQueue)
        gVerifyQueue = dispatch_queue_create("fnmac.verify", DISPATCH_QUEUE_SERIAL);

    SEL selFinish   = @selector(URLSession:downloadTask:didFinishDownloadingToURL:);
    SEL selComplete = @selector(URLSession:task:didCompleteWithError:);
    SEL selData     = @selector(URLSession:dataTask:didReceiveData:);

    unsigned int count = 0;
    Class* classes = objc_copyClassList(&count);
    for (Class* p = classes; p < classes + count; ++p) {
        const char* image = class_getImageName(*p);
        if (!image) continue;
        bool isFN  = std::strstr(image, "FortniteClient-IOS-Shipping") != nullptr;
        bool isEOS = std::strstr(image, "EOSSDK") != nullptr || std::strstr(image, "libEOS") != nullptr;
        if (!isFN && !isEOS) continue;
        if (ownsMethod(*p, selFinish))   hookFinish(*p, selFinish);
        if (ownsMethod(*p, selComplete)) hookComplete(*p, selComplete);
        if (ownsMethod(*p, selData))     hookReceiveData(*p, selData);
    }
    free(classes);

    hookFileManager();
    hookURLRequest();

#ifndef PRODUCTION
    og_installNetHooks();
#endif

    install_eac_mshooks();
}