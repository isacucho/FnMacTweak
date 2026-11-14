/*
 * ContentPatch.mm - intercept experience_br para suprimir NumLoadCustomizationFailed.
 *
 * El endpoint cooked-content-package/link/experience_br devuelve HTTP 400 cuando
 * el servidor rechaza platform=ios + major=43. Eso causa que el motor incremente
 * NumLoadCustomizationFailed; a partir de 3 LogFortPerformance dispara un
 * performance exit que NO pasa por ClientWasKicked (KickBypass no lo cubre).
 * Resultado: CL screen con errors.com.epicgames.common.processing.
 *
 * Solucion: NSURLProtocol subclass que detecta la URL y devuelve HTTP 200 {}
 * antes de que la request llegue al servidor. Se inyecta en cada NSURLSession
 * hokeando +[NSURLSession sessionWithConfiguration:delegate:delegateQueue:] para
 * insertarla al principio de protocolClasses. No escribe en disco ni en __TEXT.
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include "core/DiagLog.hpp"

// ---------------------------------------------------------------------------
// NSURLProtocol subclass
// ---------------------------------------------------------------------------

@interface FnContentLinkProtocol : NSURLProtocol
@end

@implementation FnContentLinkProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest*)req {
    NSString* url = [[req URL] absoluteString];
    return url && [url containsString:@"cooked-content-package/link/experience_br"];
}

+ (NSURLRequest*)canonicalRequestForRequest:(NSURLRequest*)req { return req; }
+ (BOOL)requestIsCacheEquivalent:(NSURLRequest*)a toRequest:(NSURLRequest*)b { return NO; }

- (void)startLoading {
    NSString* url = [[[self request] URL] absoluteString];
    fndiag::log_line("[ContentPatch] experience_br intercepted -> synthetic 200 (%s)",
                     url ? [url UTF8String] : "(nil)");

    NSHTTPURLResponse* resp = [[NSHTTPURLResponse alloc]
        initWithURL:[[self request] URL]
        statusCode:200
        HTTPVersion:@"HTTP/1.1"
        headerFields:@{@"Content-Type": @"application/json; charset=utf-8"}];
    NSData* body = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];

    [[self client] URLProtocol:self didReceiveResponse:resp
            cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [[self client] URLProtocol:self didLoadData:body];
    [[self client] URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {}

@end

// ---------------------------------------------------------------------------
// Session factory swizzle: inject FnContentLinkProtocol into every session
// ---------------------------------------------------------------------------

namespace {

typedef NSURLSession* (*SessionFactoryFn)(Class, SEL, NSURLSessionConfiguration*, id, NSOperationQueue*);
static SessionFactoryFn g_orig_session_factory = nullptr;

static NSURLSession* swizzled_session_factory(Class self_, SEL cmd,
                                               NSURLSessionConfiguration* cfg,
                                               id delegate, NSOperationQueue* queue) {
    @autoreleasepool {
        if (cfg) {
            NSMutableArray* protocols = cfg.protocolClasses
                ? [cfg.protocolClasses mutableCopy]
                : [NSMutableArray array];
            if (![protocols containsObject:[FnContentLinkProtocol class]]) {
                [protocols insertObject:[FnContentLinkProtocol class] atIndex:0];
                cfg.protocolClasses = protocols;
            }
        }
    }
    return g_orig_session_factory(self_, cmd, cfg, delegate, queue);
}

} // namespace

namespace fndiag {

void install_content_patch() {
    // Global registration covers default-config sessions.
    [NSURLProtocol registerClass:[FnContentLinkProtocol class]];

    // Swizzle +sessionWithConfiguration:delegate:delegateQueue: to inject the
    // protocol class into sessions created with custom/ephemeral configurations.
    SEL sel = @selector(sessionWithConfiguration:delegate:delegateQueue:);
    Method m = class_getClassMethod([NSURLSession class], sel);
    if (!m) {
        log_line("[ContentPatch] session factory method not found — global registration only");
        return;
    }
    g_orig_session_factory = reinterpret_cast<SessionFactoryFn>(method_getImplementation(m));
    method_setImplementation(m, reinterpret_cast<IMP>(swizzled_session_factory));
    log_line("[ContentPatch] session factory hooked + protocol registered");
}

} // namespace fndiag
