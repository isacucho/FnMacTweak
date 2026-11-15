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
#include "core/Config.hpp"

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

// On iOS the sandbox pre-creates BackgroundHttp/<build>/ as part of container setup.
// On macOS Catalyst the container is empty; NSURLSessionDownloadTask completions fail
// to move their temp file (parent missing) and all chunks return bWasSuccess=0.
static void create_missing_sandbox_dirs() {
    NSString* bgHttp = [NSHomeDirectory() stringByAppendingPathComponent:
        @"Documents/FortniteGame/PersistentDownloadDir/BackgroundHttp/++Fortnite+Release-43.10"];
    NSError* err = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:bgHttp
                                  withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:&err];
    if (!err)
        fndiag::log_line("[ContentPatch] sandbox dir ready: BackgroundHttp/++Fortnite+Release-43.10");
    else
        fndiag::log_line("[ContentPatch] sandbox dir warn: %s", [[err localizedDescription] UTF8String]);
}

// Known background session identifiers Fortnite creates. We purge any stale tasks
// from nsurlsessiond at startup so the game starts with a clean slate even after
// container deletion.
static const char* const kBgSessionIds[] = {
    "com.epicgames.backgrounddownloads",
    "com.epicgames.backgrounddownloads.1",
    "com.epicgames.backgrounddownloads.2",
    "com.epicgames.backgrounddownloads.3",
    "com.epicgames.backgrounddownloads.4",
    "com.epicgames.backgrounddownloads.5",
    "com.unrealengine.backgroundhttpsession",
    nullptr
};

static void purge_stale_bg_tasks() {
    dispatch_group_t group = dispatch_group_create();
    for (int i = 0; kBgSessionIds[i]; ++i) {
        dispatch_group_enter(group);
        const char* sid = kBgSessionIds[i];
        NSURLSessionConfiguration* cfg =
            [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:@(sid)];
        NSURLSession* s = [NSURLSession sessionWithConfiguration:cfg delegate:nil delegateQueue:nil];
        [s getAllTasksWithCompletionHandler:^(NSArray<__kindof NSURLSessionTask*>* tasks) {
            for (NSURLSessionTask* t in tasks) [t cancel];
            if (tasks.count > 0)
                fndiag::log_line("[ContentPatch] purged %lu stale task(s) from '%s'",
                                 (unsigned long)tasks.count, sid);
            [s invalidateAndCancel];
            dispatch_group_leave(group);
        }];
    }
    dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    fndiag::log_line("[ContentPatch] stale BG task purge complete");
}

typedef NSURLSession* (*SessionFactoryFn)(Class, SEL, NSURLSessionConfiguration*, id, NSOperationQueue*);
static SessionFactoryFn g_orig_session_factory = nullptr;

static NSURLSession* swizzled_session_factory(Class self_, SEL cmd,
                                               NSURLSessionConfiguration* cfg,
                                               id delegate, NSOperationQueue* queue) {
    @autoreleasepool {
        if (cfg) {
            // Background sessions persist task state in nsurlsessiond across container
            // deletions. On next launch those stale tasks come back with bWasSuccess=0
            // and cause the ESP-CON-000 retry loop. Downgrade to default (in-process).
            if (cfg.identifier && fndiag::config().foreground_sessions) {
                NSURLSessionConfiguration* fgCfg = [NSURLSessionConfiguration defaultSessionConfiguration];
                fgCfg.timeoutIntervalForRequest  = cfg.timeoutIntervalForRequest;
                fgCfg.timeoutIntervalForResource = cfg.timeoutIntervalForResource;
                fndiag::log_line("[ContentPatch] BG session '%s' -> default (foreground_sessions)",
                                 [cfg.identifier UTF8String]);
                cfg = fgCfg;
            }
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
    create_missing_sandbox_dirs();
    purge_stale_bg_tasks();

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
