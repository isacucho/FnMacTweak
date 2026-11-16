#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <Metal/Metal.h>
#import <mach-o/dyld.h>
#include <dlfcn.h>
#include "core/Logger.hpp"
#include "gpu/MetalPurge.hpp"

#define TAG "MetalPurge"

// On Mac Catalyst (iOS app on Apple Silicon), MTLResource subclasses backed by
// GPU-private or tile-memory allocations don't support purgeable state.
// The IOGPU driver logs "setPurgeableState not supported for resource" and
// returns without updating state, leaving the game in an inconsistent memory-
// management path that causes GPU resource stalls and visual artifacts.
//
// Fix: for each concrete MTLResource class, replace setPurgeableState: with a
// wrapper that short-circuits the call for Private/Memoryless resources, returning
// MTLPurgeableStateNonVolatile so callers see "resource is available" without
// hitting the broken driver path.

namespace {

static void patch_class(Class cls) {
    SEL sel = @selector(setPurgeableState:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    // Skip purely inherited impls — patch only the class that owns the method.
    Class super = class_getSuperclass(cls);
    if (super && class_getInstanceMethod(super, sel) == m) return;

    typedef MTLPurgeableState (*Imp)(id, SEL, MTLPurgeableState);
    Imp orig = (Imp)method_getImplementation(m);
    const char *name = class_getName(cls);

    method_setImplementation(m, imp_implementationWithBlock(^MTLPurgeableState(id self_, MTLPurgeableState state) {
        // Private (GPU-only) and Memoryless (tile) resources do not support
        // purgeable state on Mac Catalyst. Return NonVolatile immediately to
        // avoid the IOGPU error log and the stall it causes.
        MTLStorageMode mode = [(id<MTLResource>)self_ storageMode];
        if (mode == MTLStorageModePrivate || mode == MTLStorageModeMemoryless) {
            return MTLPurgeableStateNonVolatile;
        }
        return orig(self_, sel, state);
    }));

    LOG_I(TAG, "patched %s", name);
}

static void scan_and_patch(void) {
    int total = objc_getClassList(NULL, 0);
    if (total <= 0) return;

    Class *all = (Class *)malloc((size_t)total * sizeof(Class));
    if (!all) return;
    objc_getClassList(all, total);

    Protocol *mtlResource = objc_getProtocol("MTLResource");
    SEL purgeSel = @selector(setPurgeableState:);
    int patched = 0;

    for (int i = 0; i < total; i++) {
        Class cls = all[i];
        // Only concrete MTLResource-conforming classes that implement the method.
        if (mtlResource && !class_conformsToProtocol(cls, mtlResource)) continue;
        if (!class_getInstanceMethod(cls, purgeSel)) continue;
        patch_class(cls);
        patched++;
    }

    free(all);
    if (patched > 0) {
        LOG_I(TAG, "%d class(es) patched for setPurgeableState", patched);
    } else {
        LOG_W(TAG, "no MTLResource classes found yet — Metal may not be loaded");
    }
}

static void dyld_image_added(const struct mach_header *mh, intptr_t /*slide*/) {
    Dl_info info;
    if (!dladdr((const void *)mh, &info) || !info.dli_fname) return;
    if (!strstr(info.dli_fname, "/Metal.framework/")) return;
    // Metal just loaded (or was already loaded when we registered): patch now.
    scan_and_patch();
}

} // namespace

namespace fndiag {

void install_metal_purge() {
    // Metal is always loaded before our dylib constructor runs, so scan
    // immediately. The dyld callback is registered as a fallback for the
    // hypothetical case where a Metal variant loads later, but on Mac Catalyst
    // the callback's dladdr() returns the shared-cache path rather than the
    // framework path, so the strstr filter would fail — the direct call is
    // what actually patches the classes.
    scan_and_patch();
    _dyld_register_func_for_add_image(dyld_image_added);
}

} // namespace fndiag
