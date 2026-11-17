// FnMacTweak-kbm: platform compatibility and window presentation only.
#import "globals.h"
#import "../lib/fishhook.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <dlfcn.h>
#import <pthread.h>
#import <mach-o/dyld.h>
#import <stdarg.h>
static BOOL isSystemCaller(void *retAddr) {
    Dl_info info;
    if (dladdr(retAddr, &info) && info.dli_fname) {
        const char *path = info.dli_fname;
        if (strstr(path, "/System/Library/") != NULL ||
            strstr(path, "/usr/lib/") != NULL ||
            strstr(path, "/System/iOSSupport/") != NULL) {
            return YES;
        }
    }
    return NO;
}

static void swizzleIsiOSAppOnMac(Class cls) {
    if (!cls) return;
    SEL sel = @selector(isiOSAppOnMac);
    Method method = class_getInstanceMethod(cls, sel);
    if (method) {
        IMP origImp = method_getImplementation(method);
        class_replaceMethod(cls, sel, imp_implementationWithBlock(^BOOL(id self) {
            void *retAddr = __builtin_return_address(0);
            if (isSystemCaller(retAddr)) {
                typedef BOOL (*OrigFunc)(id, SEL);
                return ((OrigFunc)origImp)(self, sel);
            }
            return NO; // Return NO to the game and tracking libraries
        }), method_getTypeEncoding(method));
    } else {
        class_addMethod(cls, sel, imp_implementationWithBlock(^BOOL(id self) {
            void *retAddr = __builtin_return_address(0);
            if (isSystemCaller(retAddr)) {
                return YES;
            }
            return NO;
        }), "B@:");
    }
}

static void swizzleIsiOSAppOnMic(Class cls) {
    if (!cls) return;
    SEL sel = @selector(isiOSAppOnMic);
    Method method = class_getInstanceMethod(cls, sel);
    if (method) {
        class_replaceMethod(cls, sel, imp_implementationWithBlock(^BOOL(id self) {
            return NO;
        }), method_getTypeEncoding(method));
    } else {
        class_addMethod(cls, sel, imp_implementationWithBlock(^BOOL(id self) {
            return NO;
        }), "B@:");
    }
}

static void swizzleIsMacCatalystApp(Class cls) {
    if (!cls) return;
    SEL sel = @selector(isMacCatalystApp);
    Method method = class_getInstanceMethod(cls, sel);
    if (method) {
        IMP origImp = method_getImplementation(method);
        class_replaceMethod(cls, sel, imp_implementationWithBlock(^BOOL(id self) {
            void *retAddr = __builtin_return_address(0);
            if (isSystemCaller(retAddr)) {
                typedef BOOL (*OrigFunc)(id, SEL);
                return ((OrigFunc)origImp)(self, sel);
            }
            return NO;
        }), method_getTypeEncoding(method));
    } else {
        class_addMethod(cls, sel, imp_implementationWithBlock(^BOOL(id self) {
            void *retAddr = __builtin_return_address(0);
            if (isSystemCaller(retAddr)) {
                return NO;
            }
            return NO;
        }), "B@:");
    }
}

#import <mach-o/dyld.h>

// Dynamic Linker Hiding / Stealth
static const struct mach_header *g_our_header = NULL;

static uint32_t (*orig_dyld_image_count)(void) = NULL;
static const char *(*orig_dyld_get_image_name)(uint32_t image_index) = NULL;
static const struct mach_header *(*orig_dyld_get_image_header)(uint32_t image_index) = NULL;
static intptr_t (*orig_dyld_get_image_vmaddr_slide)(uint32_t image_index) = NULL;
static void (*orig_dyld_register_func_for_add_image)(void (*func)(const struct mach_header* mh, intptr_t vmaddr_slide)) = NULL;
static void (*orig_dyld_register_func_for_remove_image)(void (*func)(const struct mach_header* mh, intptr_t vmaddr_slide)) = NULL;
static int (*orig_dladdr)(const void *addr, Dl_info *info) = NULL;

static uint32_t hooked_dyld_image_count(void) {
    if (!g_our_header) return orig_dyld_image_count();
    uint32_t count = orig_dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        if (orig_dyld_get_image_header(i) == g_our_header) {
            return count - 1;
        }
    }
    return count;
}

static uint32_t get_mapped_image_index(uint32_t idx) {
    if (!g_our_header) return idx;
    uint32_t count = orig_dyld_image_count();
    uint32_t current_virtual_idx = 0;
    for (uint32_t i = 0; i < count; i++) {
        const struct mach_header *mh = orig_dyld_get_image_header(i);
        if (mh == g_our_header) {
            continue;
        }
        if (current_virtual_idx == idx) {
            return i;
        }
        current_virtual_idx++;
    }
    return idx;
}

static const char *hooked_dyld_get_image_name(uint32_t image_index) {
    return orig_dyld_get_image_name(get_mapped_image_index(image_index));
}

static const struct mach_header *hooked_dyld_get_image_header(uint32_t image_index) {
    return orig_dyld_get_image_header(get_mapped_image_index(image_index));
}

static intptr_t hooked_dyld_get_image_vmaddr_slide(uint32_t image_index) {
    return orig_dyld_get_image_vmaddr_slide(get_mapped_image_index(image_index));
}

#define MAX_DYLD_CALLBACKS 64
static void (*g_add_image_callbacks[MAX_DYLD_CALLBACKS])(const struct mach_header* mh, intptr_t vmaddr_slide) = {NULL};
static int g_add_image_callbacks_count = 0;
static pthread_mutex_t g_callbacks_mutex = PTHREAD_MUTEX_INITIALIZER;

static void wrapped_add_image_callback(const struct mach_header* mh, intptr_t vmaddr_slide) {
    if (mh == g_our_header) {
        return; // Filter out our dylib
    }
    
    pthread_mutex_lock(&g_callbacks_mutex);
    int count = g_add_image_callbacks_count;
    void (*callbacks[MAX_DYLD_CALLBACKS])(const struct mach_header*, intptr_t);
    for (int i = 0; i < count; i++) {
        callbacks[i] = g_add_image_callbacks[i];
    }
    pthread_mutex_unlock(&g_callbacks_mutex);
    
    for (int i = 0; i < count; i++) {
        if (callbacks[i]) {
            callbacks[i](mh, vmaddr_slide);
        }
    }
}

static void hooked_dyld_register_func_for_add_image(void (*func)(const struct mach_header* mh, intptr_t vmaddr_slide)) {
    if (!func) return;
    
    pthread_mutex_lock(&g_callbacks_mutex);
    BOOL exists = NO;
    for (int i = 0; i < g_add_image_callbacks_count; i++) {
        if (g_add_image_callbacks[i] == func) {
            exists = YES;
            break;
        }
    }
    if (!exists && g_add_image_callbacks_count < MAX_DYLD_CALLBACKS) {
        g_add_image_callbacks[g_add_image_callbacks_count++] = func;
    }
    pthread_mutex_unlock(&g_callbacks_mutex);
    
    static BOOL registered_wrapper = NO;
    if (!registered_wrapper) {
        registered_wrapper = YES;
        orig_dyld_register_func_for_add_image(wrapped_add_image_callback);
    } else {
        // Emulate dyld behavior by calling it immediately for already-loaded images
        uint32_t count = orig_dyld_image_count();
        for (uint32_t i = 0; i < count; i++) {
            const struct mach_header *mh = orig_dyld_get_image_header(i);
            intptr_t slide = orig_dyld_get_image_vmaddr_slide(i);
            if (mh != g_our_header) {
                func(mh, slide);
            }
        }
    }
}

static void (*g_remove_image_callbacks[MAX_DYLD_CALLBACKS])(const struct mach_header* mh, intptr_t vmaddr_slide) = {NULL};
static int g_remove_image_callbacks_count = 0;
static pthread_mutex_t g_remove_callbacks_mutex = PTHREAD_MUTEX_INITIALIZER;

static void wrapped_remove_image_callback(const struct mach_header* mh, intptr_t vmaddr_slide) {
    if (mh == g_our_header) {
        return;
    }
    
    pthread_mutex_lock(&g_remove_callbacks_mutex);
    int count = g_remove_image_callbacks_count;
    void (*callbacks[MAX_DYLD_CALLBACKS])(const struct mach_header*, intptr_t);
    for (int i = 0; i < count; i++) {
        callbacks[i] = g_remove_image_callbacks[i];
    }
    pthread_mutex_unlock(&g_remove_callbacks_mutex);
    
    for (int i = 0; i < count; i++) {
        if (callbacks[i]) {
            callbacks[i](mh, vmaddr_slide);
        }
    }
}

static void hooked_dyld_register_func_for_remove_image(void (*func)(const struct mach_header* mh, intptr_t vmaddr_slide)) {
    if (!func) return;
    
    pthread_mutex_lock(&g_remove_callbacks_mutex);
    BOOL exists = NO;
    for (int i = 0; i < g_remove_image_callbacks_count; i++) {
        if (g_remove_image_callbacks[i] == func) {
            exists = YES;
            break;
        }
    }
    if (!exists && g_remove_image_callbacks_count < MAX_DYLD_CALLBACKS) {
        g_remove_image_callbacks[g_remove_image_callbacks_count++] = func;
    }
    pthread_mutex_unlock(&g_remove_callbacks_mutex);
    
    static BOOL registered_remove_wrapper = NO;
    if (!registered_remove_wrapper) {
        registered_remove_wrapper = YES;
        orig_dyld_register_func_for_remove_image(wrapped_remove_image_callback);
    }
}

static int hooked_dladdr(const void *addr, Dl_info *info) {
    int ret = orig_dladdr(addr, info);
    if (ret && info && info->dli_fbase == g_our_header) {
        memset(info, 0, sizeof(Dl_info));
        return 0; // Pretend it failed to hide our dylib from dladdr calls
    }
    return ret;
}

void updateBorderlessMode() {

    @try {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        
        Class nsAppClass = NSClassFromString(@"NSApplication");
        if (!nsAppClass) { return; }
        
        id sharedApp = [nsAppClass performSelector:NSSelectorFromString(@"sharedApplication")];
        NSArray *windows = [sharedApp performSelector:NSSelectorFromString(@"windows")];
        Class nsWindowClass = NSClassFromString(@"NSWindow");

        for (id window in windows) {
            // Safety: Only touch actual NSWindow instances
            if (!nsWindowClass || ![window isKindOfClass:nsWindowClass]) continue;
            
            // 1. Style Mask (NSWindowStyleMaskFullSizeContentView = 1 << 15)
            NSUInteger currentMask = [[window valueForKey:@"styleMask"] unsignedIntegerValue];
            NSUInteger fullSizeMask = (1ULL << 15);
            NSUInteger newMask = isBorderlessModeEnabled ? (currentMask | fullSizeMask) : (currentMask & ~fullSizeMask);
            
            if (currentMask != newMask) {
                [window setValue:@(newMask) forKey:@"styleMask"];
            }

            // 2. Title Bar Transparency & Visibility
            if ([window respondsToSelector:NSSelectorFromString(@"setTitlebarAppearsTransparent:")]) {
                [window setValue:@(isBorderlessModeEnabled) forKey:@"titlebarAppearsTransparent"];
            }
            if ([window respondsToSelector:NSSelectorFromString(@"setTitleVisibility:")]) {
                [window setValue:@(isBorderlessModeEnabled ? 1 : 0) forKey:@"titleVisibility"];
            }
            
            // 3. Traffic Lights (Explicit Button Hiding)
            SEL buttonSel = NSSelectorFromString(@"standardWindowButton:");
            if ([window respondsToSelector:buttonSel]) {
                for (NSInteger i = 0; i <= 2; i++) { // 0=Close, 1=Min, 2=Zoom
                    // Use objc_msgSend for the specific type (NSWindowButton is NSInteger)
                    typedef id (*ButtonFunc)(id, SEL, NSInteger);
                    ButtonFunc getButton = (ButtonFunc)objc_msgSend;
                    id btn = getButton(window, buttonSel, i);

                    if (btn && [btn respondsToSelector:NSSelectorFromString(@"setHidden:")]) {
                        [btn setValue:@(isBorderlessModeEnabled) forKey:@"hidden"];
                    }
                }

                // Titlebar Container (Super-view of close button)
                typedef id (*ButtonFunc)(id, SEL, NSInteger);
                id closeBtn = ((ButtonFunc)objc_msgSend)(window, buttonSel, 0);
                if (closeBtn) {
                    id container = [closeBtn valueForKey:@"superview"];
                    if (container && [container respondsToSelector:NSSelectorFromString(@"setHidden:")]) {
                        [container setValue:@(isBorderlessModeEnabled) forKey:@"hidden"];
                    }
                }
            }

            // 4. Positioning
                if (isBorderlessModeEnabled) {
                    // Borderless: Manual center using visibleFrame (excludes macOS menu bar).
                    // [NSWindow center] uses the full screen frame which causes a vertical
                    // offset because macOS has a bottom-left origin and the menu bar eats
                    // into the top. We also wait 100ms (up from 50ms) so the title bar
                    // hide animation fully settles before we read the window's final size.
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        id screen = [window valueForKey:@"screen"];
                        if (screen) {
                            NSValue *visibleFrameVal = [screen valueForKey:@"visibleFrame"];
                            CGRect visibleFrame = visibleFrameVal ? [visibleFrameVal CGRectValue] : CGRectZero;
                            CGRect windowFrame = [[window valueForKey:@"frame"] CGRectValue];

                            if (!CGRectIsEmpty(visibleFrame) && !CGRectIsEmpty(windowFrame)) {
                                CGRect targetFrame = windowFrame;
                                targetFrame.origin.x = visibleFrame.origin.x + (visibleFrame.size.width  - windowFrame.size.width)  / 2.0;
                                targetFrame.origin.y = visibleFrame.origin.y + (visibleFrame.size.height - windowFrame.size.height) / 2.0;

                                NSMethodSignature *sig = [window methodSignatureForSelector:NSSelectorFromString(@"setFrame:display:")];
                                if (sig) {
                                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                                    [inv setSelector:NSSelectorFromString(@"setFrame:display:")];
                                    [inv setTarget:window];
                                    [inv setArgument:&targetFrame atIndex:2];
                                    BOOL display = YES;
                                    [inv setArgument:&display atIndex:3];
                                    [inv invoke];
                                }
                            }
                        }
                    });
                } else {
                    // Bordered: Top-Aligned Centering
                    id screen = [window valueForKey:@"screen"];
                    if (screen) {
                        CGRect screenFrame = [[screen valueForKey:@"frame"] CGRectValue];
                        CGRect windowFrame = [[window valueForKey:@"frame"] CGRectValue];
                        
                        CGRect targetFrame = windowFrame;
                        targetFrame.origin.x = screenFrame.origin.x + (screenFrame.size.width - windowFrame.size.width) / 2.0;
                        targetFrame.origin.y = screenFrame.origin.y + screenFrame.size.height - windowFrame.size.height;

                        NSMethodSignature *sig = [window methodSignatureForSelector:NSSelectorFromString(@"setFrame:display:")];
                        if (sig) {
                            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                            [inv setSelector:NSSelectorFromString(@"setFrame:display:")];
                            [inv setTarget:window];
                            [inv setArgument:&targetFrame atIndex:2];
                            BOOL display = YES;
                            [inv setArgument:&display atIndex:3];
                            [inv invoke];
                        }
                    }
                }

            if ([window respondsToSelector:NSSelectorFromString(@"setMovableByWindowBackground:")]) {
                [window setValue:@YES forKey:@"movableByWindowBackground"];
            }
        }
        
        // UIKit Override: Kill safe areas
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (UIWindow *uiWin in [[UIApplication sharedApplication] windows]) {
        #pragma clang diagnostic pop
            UIView *rootView = uiWin.rootViewController.view;
            if (rootView && [rootView respondsToSelector:@selector(setInsetsLayoutMarginsFromSafeArea:)]) {
                typedef void (*SetInsetsFunc)(id, SEL, BOOL);
                ((SetInsetsFunc)objc_msgSend)(rootView, @selector(setInsetsLayoutMarginsFromSafeArea:), !isBorderlessModeEnabled);
            }
        }
        #pragma clang diagnostic pop
    } @catch (NSException *exception) {
    }
}

// --------- macOS 26.4 CRASH FIX ---------
// Fortnite v40.00.1 has a Swift @available(iOS 17.4, *) check that, on
// macOS 26.4 via Catalyst, takes a code path with a NULL async continuation
// causing an immediate SIGSEGV on launch.  Hook _availability_version_check
// (via fishhook / GOT patching — data pages only, no code-signing issues)
// so the check returns false for iOS 17.4, forcing the safe fallback path.

typedef struct {
    uint32_t platform;
    uint32_t version;       /* major<<16 | minor<<8 | patch */
} dyld_build_version_t;

#define PLATFORM_IOS       2
#define PACK_VER(M,m,p)    (((uint32_t)(M)<<16)|((uint32_t)(m)<<8)|(uint32_t)(p))
#define BLOCKED_VERSION    PACK_VER(17, 4, 0)

static bool (*orig_availability_version_check)(uint32_t, dyld_build_version_t []);

static bool hooked_availability_version_check(uint32_t count,
                                               dyld_build_version_t versions[]) {
    for (uint32_t i = 0; i < count; i++) {
        if (versions[i].platform == PLATFORM_IOS &&
            versions[i].version  == BLOCKED_VERSION) {
            return false;
        }
    }
    return orig_availability_version_check(count, versions);
}

static int (*orig_open)(const char *path, int oflag, ...) = NULL;
static int (*orig_close)(int fd) = NULL;
static FILE *(*orig_fopen)(const char *path, const char *mode) = NULL;
static int (*orig_fclose)(FILE *stream) = NULL;

#define MAX_MONITORED_FDS 32
struct MonitoredFile {
    int fd;
    char path[1024];
};
static struct MonitoredFile g_monitoredFds[MAX_MONITORED_FDS];

#define MAX_MONITORED_FILES 32
struct MonitoredFileStream {
    FILE *stream;
    char path[1024];
};
static struct MonitoredFileStream g_monitoredStreams[MAX_MONITORED_FILES];

static pthread_mutex_t g_monitoredMutex = PTHREAD_MUTEX_INITIALIZER;

// Only alter the frame-rate entries; retain all unrelated game settings.
static void force120FPSInFile(const char *path) {
    if (!path) return;
    fnReadGameFrameLimit(path);
    if (!fnUnlockFrameRate) return;
    @autoreleasepool {
        NSString *file = [NSString stringWithUTF8String:path];
        NSError *error = nil;
        NSString *text = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:&error];
        if (!text) return;
        NSMutableString *updated = [text mutableCopy];
        [updated replaceOccurrencesOfString:@"b120FpsMode=False" withString:@"b120FpsMode=True" options:0 range:NSMakeRange(0, updated.length)];
        for (NSNumber *fps in @[@30, @45, @60, @90]) {
            NSString *from = [NSString stringWithFormat:@"MobileFPSMode=Mode_%@Fps", fps];
            [updated replaceOccurrencesOfString:from withString:@"MobileFPSMode=Mode_120Fps" options:0 range:NSMakeRange(0, updated.length)];
        }
        if (![updated isEqualToString:text]) [updated writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:&error];
        if (error) NSLog(@"[FnMacTweak-kbm] FPS settings: %@", error.localizedDescription);
    }
}

static int hooked_open(const char *path, int oflag, ...) {
    mode_t mode = 0;
    if (oflag & O_CREAT) {
        va_list args;
        va_start(args, oflag);
        mode = va_arg(args, int);
        va_end(args);
    }
    
    int fd;
    if (orig_open) {
        fd = orig_open(path, oflag, mode);
    } else {
        fd = open(path, oflag, mode);
    }
    
    if (fd >= 0 && path && strstr(path, "GameUserSettings.ini") != NULL) {
        if ((oflag & O_WRONLY) || (oflag & O_RDWR)) {
            pthread_mutex_lock(&g_monitoredMutex);
            for (int i = 0; i < MAX_MONITORED_FDS; i++) {
                if (g_monitoredFds[i].fd == -1) {
                    g_monitoredFds[i].fd = fd;
                    strncpy(g_monitoredFds[i].path, path, sizeof(g_monitoredFds[i].path) - 1);
                    g_monitoredFds[i].path[sizeof(g_monitoredFds[i].path) - 1] = '\0';
                    NSLog(@"[FnMacTweak] Monitoring GameUserSettings.ini write (fd: %d, path: %s)", fd, path);
                    break;
                }
            }
            pthread_mutex_unlock(&g_monitoredMutex);
        }
    }
    
    return fd;
}

static int hooked_close(int fd) {
    char pathBuf[1024];
    pathBuf[0] = '\0';
    BOOL wasMonitored = NO;
    
    pthread_mutex_lock(&g_monitoredMutex);
    for (int i = 0; i < MAX_MONITORED_FDS; i++) {
        if (g_monitoredFds[i].fd == fd) {
            strncpy(pathBuf, g_monitoredFds[i].path, sizeof(pathBuf) - 1);
            pathBuf[sizeof(pathBuf) - 1] = '\0';
            g_monitoredFds[i].fd = -1;
            g_monitoredFds[i].path[0] = '\0';
            wasMonitored = YES;
            break;
        }
    }
    pthread_mutex_unlock(&g_monitoredMutex);
    
    int ret;
    if (orig_close) {
        ret = orig_close(fd);
    } else {
        ret = close(fd);
    }
    
    if (wasMonitored && pathBuf[0] != '\0') {
        NSLog(@"[FnMacTweak] GameUserSettings.ini closed. Scanning for auto-correction...");
        force120FPSInFile(pathBuf);
    }
    
    return ret;
}

static FILE *hooked_fopen(const char *path, const char *mode) {
    FILE *stream = NULL;
    if (orig_fopen) {
        stream = orig_fopen(path, mode);
    } else {
        stream = fopen(path, mode);
    }
    
    if (stream && path && strstr(path, "GameUserSettings.ini") != NULL) {
        if (strchr(mode, 'w') || strchr(mode, 'a') || strchr(mode, '+')) {
            pthread_mutex_lock(&g_monitoredMutex);
            for (int i = 0; i < MAX_MONITORED_FILES; i++) {
                if (g_monitoredStreams[i].stream == NULL) {
                    g_monitoredStreams[i].stream = stream;
                    strncpy(g_monitoredStreams[i].path, path, sizeof(g_monitoredStreams[i].path) - 1);
                    g_monitoredStreams[i].path[sizeof(g_monitoredStreams[i].path) - 1] = '\0';
                    NSLog(@"[FnMacTweak] Monitoring GameUserSettings.ini fopen (stream: %p, path: %s)", stream, path);
                    break;
                }
            }
            pthread_mutex_unlock(&g_monitoredMutex);
        }
    }
    
    return stream;
}

static int hooked_fclose(FILE *stream) {
    char pathBuf[1024];
    pathBuf[0] = '\0';
    BOOL wasMonitored = NO;
    
    pthread_mutex_lock(&g_monitoredMutex);
    for (int i = 0; i < MAX_MONITORED_FILES; i++) {
        if (g_monitoredStreams[i].stream == stream) {
            strncpy(pathBuf, g_monitoredStreams[i].path, sizeof(pathBuf) - 1);
            pathBuf[sizeof(pathBuf) - 1] = '\0';
            g_monitoredStreams[i].stream = NULL;
            g_monitoredStreams[i].path[0] = '\0';
            wasMonitored = YES;
            break;
        }
    }
    pthread_mutex_unlock(&g_monitoredMutex);
    
    int ret;
    if (orig_fclose) {
        ret = orig_fclose(stream);
    } else {
        ret = fclose(stream);
    }
    
    if (wasMonitored && pathBuf[0] != '\0') {
        NSLog(@"[FnMacTweak] GameUserSettings.ini fclose. Scanning for auto-correction...");
        force120FPSInFile(pathBuf);
    }
    
    return ret;
}



// --------- DEVICE SPOOFING ---------
// Intercepts sysctl/sysctlbyname to report DEVICE_MODEL and OEM_ID,
// making Fortnite treat this Mac as a supported iOS device.
static int (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t) = NULL;
static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t) = NULL;

// LEVEL 27: Alternative Marketplace / EU Compatibility Bypass
typedef void (*MKW_GetEligibilityRegionCallback)(bool eligible, const char *regionCode);
static void (*orig_MKW_GetEligibilityRegion)(MKW_GetEligibilityRegionCallback completion) = NULL;

static void hooked_MKW_GetEligibilityRegion(MKW_GetEligibilityRegionCallback completion) {
    NSLog(@"[FnMacTweak] Intercepted MKW_GetEligibilityRegion! Spoofing EU Eligibility region.");
    if (completion) {
        completion(true, "EU");
    }
}

typedef void (*MKW_RequestCTTokenCallback)(bool success, const char *token);
static void (*orig_MKW_RequestCTToken)(MKW_RequestCTTokenCallback completion) = NULL;

static void hooked_MKW_RequestCTToken(MKW_RequestCTTokenCallback completion) {
    NSLog(@"[FnMacTweak] Intercepted MKW_RequestCTToken! Spoofing success token.");
    if (completion) {
        completion(true, "mock_ct_token_mactweak_bypass");
    }
}

// LEVEL 27: Sandbox-Resistant sysctl Virtualization Suite
#define PSEUDO_MIB_KERN_WILLSHUTDOWN            99901
#define PSEUDO_MIB_SECURITY_LOCKDOWN            99902
#define PSEUDO_MIB_KERN_OSREVISION              99903
#define PSEUDO_MIB_KERN_UUID                    99904
#define PSEUDO_MIB_CPU_BRAND_STRING             99905
#define PSEUDO_MIB_PROC_TRANSLATED              99906

static int handle_string_sysctl(void *oldp, size_t *oldlenp, const char *value) {
    size_t len = strlen(value) + 1;
    if (oldlenp) {
        if (oldp == NULL) {
            *oldlenp = len;
            return 0;
        }
        if (*oldlenp < len) {
            *oldlenp = len;
            return ENOMEM;
        }
        strcpy((char *)oldp, value);
        *oldlenp = len;
    }
    return 0;
}

static int handle_int_sysctl(void *oldp, size_t *oldlenp, int value) {
    if (oldlenp) {
        if (oldp == NULL) {
            *oldlenp = sizeof(int);
            return 0;
        }
        if (*oldlenp < sizeof(int)) {
            *oldlenp = sizeof(int);
            return ENOMEM;
        }
        *(int *)oldp = value;
        *oldlenp = sizeof(int);
    }
    return 0;
}

static int (*orig_sysctlnametomib)(const char *name, int *mibp, size_t *sizep) = NULL;

static int hooked_sysctlnametomib(const char *name, int *mibp, size_t *sizep) {
    if (name) {
        if (strcmp(name, "kern.willshutdown") == 0) {
            if (mibp && sizep && *sizep >= 1) {
                mibp[0] = PSEUDO_MIB_KERN_WILLSHUTDOWN;
                *sizep = 1;
                return 0;
            }
            return ENOMEM;
        }
        if (strcmp(name, "security.mac.lockdown_mode_state") == 0) {
            if (mibp && sizep && *sizep >= 1) {
                mibp[0] = PSEUDO_MIB_SECURITY_LOCKDOWN;
                *sizep = 1;
                return 0;
            }
            return ENOMEM;
        }
        if (strcmp(name, "kern.osrevision") == 0) {
            if (mibp && sizep && *sizep >= 1) {
                mibp[0] = PSEUDO_MIB_KERN_OSREVISION;
                *sizep = 1;
                return 0;
            }
            return ENOMEM;
        }
        if (strcmp(name, "kern.uuid") == 0) {
            if (mibp && sizep && *sizep >= 1) {
                mibp[0] = PSEUDO_MIB_KERN_UUID;
                *sizep = 1;
                return 0;
            }
            return ENOMEM;
        }
        if (strcmp(name, "machdep.cpu.brand_string") == 0) {
            if (mibp && sizep && *sizep >= 1) {
                mibp[0] = PSEUDO_MIB_CPU_BRAND_STRING;
                *sizep = 1;
                return 0;
            }
            return ENOMEM;
        }
        if (strcmp(name, "sysctl.proc_translated") == 0) {
            if (mibp && sizep && *sizep >= 1) {
                mibp[0] = PSEUDO_MIB_PROC_TRANSLATED;
                *sizep = 1;
                return 0;
            }
            return ENOMEM;
        }
    }
    return orig_sysctlnametomib(name, mibp, sizep);
}

static int pt_sysctl(int *name, u_int namelen, void *buf, size_t *size, void *arg0, size_t arg1) {
    if (name && namelen >= 1) {
        if (name[0] == PSEUDO_MIB_KERN_WILLSHUTDOWN) {
            return handle_int_sysctl(buf, size, 0);
        }
        if (name[0] == PSEUDO_MIB_SECURITY_LOCKDOWN) {
            return handle_int_sysctl(buf, size, 0);
        }
        if (name[0] == PSEUDO_MIB_KERN_OSREVISION) {
            return handle_int_sysctl(buf, size, 199001);
        }
        if (name[0] == PSEUDO_MIB_KERN_UUID) {
            return handle_string_sysctl(buf, size, "00000000-0000-0000-0000-000000000000");
        }
        if (name[0] == PSEUDO_MIB_CPU_BRAND_STRING) {
            return handle_string_sysctl(buf, size, "Apple M1");
        }
        if (name[0] == PSEUDO_MIB_PROC_TRANSLATED) {
            return handle_int_sysctl(buf, size, 0);
        }
        
    }
    if (name && namelen >= 2 && name[0] == CTL_HW) {
        if (name[1] == HW_MACHINE || name[1] == HW_PRODUCT) return handle_string_sysctl(buf, size, DEVICE_MODEL);
        if (name[1] == HW_TARGET) return handle_string_sysctl(buf, size, OEM_ID);
    }
    return orig_sysctl(name, namelen, buf, size, arg0, arg1);
}

static int pt_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (name) {
        if (strcmp(name, "kern.willshutdown") == 0) {
            return handle_int_sysctl(oldp, oldlenp, 0);
        }
        if (strcmp(name, "security.mac.lockdown_mode_state") == 0) {
            return handle_int_sysctl(oldp, oldlenp, 0);
        }
        if (strcmp(name, "kern.osrevision") == 0) {
            return handle_int_sysctl(oldp, oldlenp, 199001);
        }
        if (strcmp(name, "kern.uuid") == 0) {
            return handle_string_sysctl(oldp, oldlenp, "00000000-0000-0000-0000-000000000000");
        }
        if (strcmp(name, "machdep.cpu.brand_string") == 0) {
            return handle_string_sysctl(oldp, oldlenp, "Apple M1");
        }
        if (strcmp(name, "sysctl.proc_translated") == 0) {
            return handle_int_sysctl(oldp, oldlenp, 0);
        }
        
        if (!strcmp(name, "hw.machine") || !strcmp(name, "hw.product") || !strcmp(name, "hw.model")) return handle_string_sysctl(oldp, oldlenp, DEVICE_MODEL);
        if (!strcmp(name, "hw.target")) return handle_string_sysctl(oldp, oldlenp, OEM_ID);
    }
    return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

static BOOL fnPerformResponderChangeOnMain(BOOL (^change)(void)) {
    if ([NSThread isMainThread]) return change();
    __block BOOL result = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{ result = change(); });
    return result;
}

%hook UIResponder
- (BOOL)becomeFirstResponder {
    return fnPerformResponderChangeOnMain(^BOOL { return %orig; });
}

- (BOOL)resignFirstResponder {
    return fnPerformResponderChangeOnMain(^BOOL { return %orig; });
}
%end


%hook NSWindow
- (void)makeKeyAndOrderFront:(id)sender {
    %orig;
    if (isBorderlessModeEnabled) updateBorderlessMode();
}
%end

// The iOS mouse patch relies on the tweak to release/show the cursor in menus.
%hook IOSViewController
- (BOOL)prefersPointerLocked {
    if (isPopupVisible) return NO;
    return isMouseLocked;
}
%end

%hook UIScreen
- (NSInteger)maximumFramesPerSecond { return fnUnlockFrameRate ? MAX(120, %orig) : %orig; }
%end

%hook CADisplayLink
- (void)setPreferredFramesPerSecond:(NSInteger)fps { %orig(fnUnlockFrameRate ? 120 : fps); }
- (void)setFrameInterval:(NSInteger)interval { %orig(fnUnlockFrameRate ? 1 : interval); }
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    if (fnUnlockFrameRate) range = CAFrameRateRangeMake(120, 120, 120);
    %orig(range);
}
%end

%hook _MTLCommandBuffer
- (void)presentDrawable:(id)drawable afterMinimumDuration:(double)duration {
    if (fnUnlockFrameRate) duration = fnUserFrameLimit > 0 ? 1.0 / fnUserFrameLimit : 0.0;
    %orig(drawable, duration);
}
%end

%ctor {
    fnLoadSettings();
    fnReadGameFrameLimit([NSHomeDirectory() stringByAppendingPathComponent:@"Documents/FortniteGame/Saved/Config/IOS/GameUserSettings.ini"].fileSystemRepresentation);
    for (int i = 0; i < MAX_MONITORED_FDS; i++) g_monitoredFds[i].fd = -1;
    const char *classes[] = {"NSProcessInfo", "_NSSwiftProcessInfo"};
    for (const char *name : classes) {
        Class cls = objc_getClass(name);
        swizzleIsiOSAppOnMac(cls);
        swizzleIsiOSAppOnMic(cls);
        swizzleIsMacCatalystApp(cls);
    }
    Dl_info info;
    if (dladdr((const void *)swizzleIsiOSAppOnMac, &info)) g_our_header = (const struct mach_header *)info.dli_fbase;
    struct rebinding bindings[] = {
        {"sysctl", (void *)pt_sysctl, (void **)&orig_sysctl},
        {"sysctlbyname", (void *)pt_sysctlbyname, (void **)&orig_sysctlbyname},
        {"sysctlnametomib", (void *)hooked_sysctlnametomib, (void **)&orig_sysctlnametomib},
        {"_availability_version_check", (void *)hooked_availability_version_check, (void **)&orig_availability_version_check},
        {"MKW_GetEligibilityRegion", (void *)hooked_MKW_GetEligibilityRegion, (void **)&orig_MKW_GetEligibilityRegion},
        {"MKW_RequestCTToken", (void *)hooked_MKW_RequestCTToken, (void **)&orig_MKW_RequestCTToken},
        {"_dyld_image_count", (void *)hooked_dyld_image_count, (void **)&orig_dyld_image_count},
        {"_dyld_get_image_name", (void *)hooked_dyld_get_image_name, (void **)&orig_dyld_get_image_name},
        {"_dyld_get_image_header", (void *)hooked_dyld_get_image_header, (void **)&orig_dyld_get_image_header},
        {"_dyld_get_image_vmaddr_slide", (void *)hooked_dyld_get_image_vmaddr_slide, (void **)&orig_dyld_get_image_vmaddr_slide},
        {"_dyld_register_func_for_add_image", (void *)hooked_dyld_register_func_for_add_image, (void **)&orig_dyld_register_func_for_add_image},
        {"_dyld_register_func_for_remove_image", (void *)hooked_dyld_register_func_for_remove_image, (void **)&orig_dyld_register_func_for_remove_image},
        {"dladdr", (void *)hooked_dladdr, (void **)&orig_dladdr},
        {"open", (void *)hooked_open, (void **)&orig_open},
        {"close", (void *)hooked_close, (void **)&orig_close},
        {"fopen", (void *)hooked_fopen, (void **)&orig_fopen},
        {"fclose", (void *)hooked_fclose, (void **)&orig_fclose}
    };
    rebind_symbols(bindings, sizeof(bindings) / sizeof(bindings[0]));
    dispatch_async(dispatch_get_main_queue(), ^{ fnInstallRuntime(); });
}
