#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <sys/stat.h>
#include <cstdlib>
#include <string>
#include "core/Logger.hpp"
#include "core/Config.hpp"
#include "hooks/ObjcUtil.hpp"
#include "update/UpdateHooks.hpp"

namespace {

typedef void (*SetResultFn)(id, SEL, long long, BOOL, id, id);
typedef id (*GetResultFn)(id, SEL, unsigned long long, BOOL*, long long*);

NSString* documentsPrefix() {
    static NSString* prefix = [NSString stringWithFormat:@"%s/Documents/",
        getenv("HOME") ? getenv("HOME") : [NSHomeDirectory() UTF8String]];
    return prefix;
}

} // namespace

namespace fndiag {

void install_engine_hooks() {
    Class cls = objc_getClass("FBackgroundNSURLSession");
    if (!cls) {
        LOG_W("EngHook", "FBackgroundNSURLSession no encontrada");
        return;
    }

    SEL selSet = NSSelectorFromString(@"SetDownloadResult:IsDiskSpaceError:WithTempFile:ForDownload:");
    Method ms = class_getInstanceMethod(cls, selSet);
    if (ms) {
        SetResultFn origSet = (SetResultFn)method_getImplementation(ms);
        method_setImplementation(ms, imp_implementationWithBlock(^(id self_, long long result, BOOL disk, id temp, id dl) {
            @autoreleasepool {
                LOG_W("EngHook", "SetDownloadResult result=%lld disk=%d temp=%s dl=%s",
                      result, disk, fndiag::objc::describe(temp).c_str(), fndiag::objc::describe(dl).c_str());
            }
            origSet(self_, selSet, result, disk, temp, dl);
        }));
        LOG_W("EngHook", "hook SetDownloadResult ok");
    } else {
        LOG_W("EngHook", "SetDownloadResult no encontrado");
    }

    SEL selGet = NSSelectorFromString(@"GetDownloadResult:OutStatus:OutStatusCode:");
    Method mg = class_getInstanceMethod(cls, selGet);
    if (mg) {
        GetResultFn origGet = (GetResultFn)method_getImplementation(mg);
        method_setImplementation(mg, imp_implementationWithBlock(^id(id self_, unsigned long long dlId, BOOL* outStatus, long long* outCode) {
            id r = origGet(self_, selGet, dlId, outStatus, outCode);
            if (config().patch_status && r && outStatus && *outStatus && outCode && *outCode == 201 &&
                [r isKindOfClass:[NSString class]]) {
                struct stat st = {};
                if (stat([(NSString*)r UTF8String], &st) == 0 && st.st_size > 0) {
                    *outCode = 200;
                    LOG_W("EngHook", "PATCH id=%llu 201->200 size=%lld", dlId, (long long)st.st_size);
                }
            }
            if (config().relative_paths && [r isKindOfClass:[NSString class]] &&
                [(NSString*)r hasPrefix:documentsPrefix()]) {
                r = [(NSString*)r substringFromIndex:[documentsPrefix() length]];
                LOG_W("EngHook", "REL id=%llu -> %s", dlId, [(NSString*)r UTF8String]);
            }
            if (outStatus && *outStatus) @autoreleasepool {
                LOG_W("EngHook", "GetDownloadResult id=%llu status=%d code=%lld ret=%s",
                      dlId, outStatus ? *outStatus : -1, outCode ? *outCode : -1LL, fndiag::objc::describe(r).c_str());
            }
            return r;
        }));
        LOG_W("EngHook", "hook GetDownloadResult ok");
    } else {
        LOG_W("EngHook", "GetDownloadResult no encontrado");
    }
}

} // namespace fndiag
