#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include "core/Logger.hpp"

// NSHTTPURLResponse.statusCode swizzle: rewrites 201 -> 200 for Epic CDN download sessions.
//
// Background NSURLSession (com.epicgames.backgrounddownloads.*) on macOS Catalyst reports
// HTTP 201 for successful background download tasks where iOS would report 200.
// Epic's IOSBackgroundDownload rejects statusCode != 200 -> bWasSuccess:0 -> ConnectivityError
// -> ESP-CON-000 before Epic login even attempts.
//
// The CDN itself serves HTTP 200 (confirmed via curl). The discrepancy is at the macOS
// NSURLSession layer. The swizzle is scoped to Epic CDN hosts + code==201 only.

#define TAG "StatusFix"

static NSInteger (*orig_statusCode)(NSHTTPURLResponse*, SEL) = nullptr;

static BOOL isEpicCDNHost(NSString* host) {
    if (!host) return NO;
    return [host hasSuffix:@"epicgamescdn.com"] ||
           [host hasSuffix:@"akamaized.net"]    ||
           [host hasSuffix:@"fastly-edge.com"];
}

static NSInteger patched_statusCode(NSHTTPURLResponse* self, SEL cmd) {
    NSInteger code = orig_statusCode(self, cmd);
    if (code == 201) {
        NSString* host = [self.URL host];
        if (isEpicCDNHost(host)) {
            LOG_I(TAG, "HTTP 201->200 for %s", [host UTF8String]);
            return 200;
        }
    }
    return code;
}

void install_status_code_fix() {
    Class cls = [NSHTTPURLResponse class];
    SEL sel = @selector(statusCode);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { LOG_E(TAG, "NSHTTPURLResponse.statusCode not found"); return; }
    orig_statusCode = (NSInteger(*)(NSHTTPURLResponse*, SEL))method_getImplementation(m);
    method_setImplementation(m, (IMP)patched_statusCode);
    LOG_I(TAG, "installed (201->200 for Epic CDN)");
}
