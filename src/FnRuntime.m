// Menu shortcuts and optional cursor confinement. Game input is never synthesized.
#import "globals.h"
#import "FnGraphics.h"
#import "FnCursorState.h"
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import "FnOverlayWindow.h"
#import "views/popupViewController.h"
#import "../lib/fishhook.h"
#import "PerformanceGuard.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <mach-o/loader.h>
#import <pthread.h>
#import <stdatomic.h>

static __weak UIWindow *previousKeyWindow;
static _Atomic bool realActive = true;
static BOOL cursorHidden = NO;
static FnCursorState cursorState = {false, true, true, false, -1};
static NSUInteger cursorGeneration;
static dispatch_source_t cursorLogTimer;
static id keyMonitor;
static BOOL consumedKeys[128];
static NSUInteger const shortcutModifiers = 0x1e0000UL;

static UIWindowScene *activeScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive)
            return (UIWindowScene *)scene;
    return nil;
}

static void refreshPointerLock(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            SEL sel = NSSelectorFromString(@"setNeedsUpdateOfPrefersPointerLocked");
            UIViewController *root = window.rootViewController;
            if ([root respondsToSelector:sel]) ((void (*)(id, SEL))objc_msgSend)(root, sel);
        }
    }
}

static void applyCursorState(BOOL forceShow) {
    BOOL locked = fnCursorWantsLock(&cursorState);
    BOOL changed = locked != isMouseLocked;
    if (changed) {
        fnReleaseGameMouseButtons();
        if (locked) { fnCancelMouseTouches(); fnGraphicsCursorIntoGame(); }
    }
    isMouseLocked = locked;
    static int (*associate)(bool);
    if (!associate) associate = (int (*)(bool))dlsym(RTLD_DEFAULT, "CGAssociateMouseAndMouseCursorPosition");
    // Always re-associate when showing the cursor, including when the engine
    // hid it before the tweak had a chance to record its own lock state.
    if (associate && (changed || (!locked && forceShow))) associate(!locked);
    Class cursor = NSClassFromString(@"NSCursor");
    if (cursor && (cursorHidden != locked || (!locked && forceShow))) {
        ((void (*)(id, SEL))objc_msgSend)(cursor, NSSelectorFromString(locked ? @"hide" : @"unhide"));
        cursorHidden = locked;
    }
    refreshPointerLock();
}

void fnSetCursorLocked(BOOL locked) {
    if (locked && (!realActive || isPopupVisible || !fnCursorShortcut.count)) return;
    cursorGeneration++;
    cursorState.manualLock = locked ? 1 : 0;
    applyCursorState(!locked);
}

void fnFollowGameCursor(void) {
    cursorGeneration++;
    cursorState.manualLock = -1;
    applyCursorState(YES);
}

static void gameCursorChanged(BOOL shown) {
    cursorState.haveGameState = true;
    cursorState.gameCursorShown = shown;
    cursorState.manualLock = -1;
    NSUInteger generation = ++cursorGeneration;
    // Retain the source patch's grace period for transient gameplay cursor flashes.
    if (shown && isMouseLocked && !isPopupVisible && realActive) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (generation == cursorGeneration) applyCursorState(YES);
        });
    } else {
        applyCursorState(shown);
    }
}

static void startCursorLogFollower(void) {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/FortniteGame/Saved/Logs/FortniteGame.log"];
    time_t started = time(NULL);
    dispatch_queue_t queue = dispatch_queue_create("fnmactweak.kbm.cursor", DISPATCH_QUEUE_SERIAL);
    cursorLogTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(cursorLogTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), 50 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
    __block int fd = -1;
    __block ino_t inode = 0;
    __block off_t position = 0;
    NSMutableData *pending = [NSMutableData data];
    dispatch_source_set_event_handler(cursorLogTimer, ^{
        struct stat info;
        if (stat(path.fileSystemRepresentation, &info)) return;
        if (fd < 0 || info.st_ino != inode) {
            // Ignore the previous session's cursor state until this launch writes its log.
            if (info.st_mtimespec.tv_sec < started - 2) return;
            if (fd >= 0) close(fd);
            fd = open(path.fileSystemRepresentation, O_RDONLY);
            if (fd < 0) return;
            inode = info.st_ino;
            position = 0;
            pending.length = 0;
        }
        if (fstat(fd, &info)) return;
        if (info.st_size < position) { position = 0; pending.length = 0; }
        int last = -1;
        char buffer[16384];
        // Bound work per tick if a session starts with a very large log.
        for (int batch = 0; batch < 64 && position < info.st_size; batch++) {
            ssize_t count = pread(fd, buffer, sizeof(buffer), position);
            if (count <= 0) break;
            position += count;
            [pending appendBytes:buffer length:(NSUInteger)count];
            size_t complete = fnCursorCompleteLines(pending.bytes, pending.length);
            if (complete) {
                int state = fnCursorScanLog(pending.bytes, complete);
                if (state >= 0) last = state;
                [pending replaceBytesInRange:NSMakeRange(0, complete) withBytes:NULL length:0];
            }
            if (pending.length > 65536) pending.length = 0;
        }
        if (last >= 0) dispatch_async(dispatch_get_main_queue(), ^{ gameCursorChanged(last == 1); });
    });
    dispatch_resume(cursorLogTimer);
}

void fnShowMenu(BOOL show) {
    UIWindowScene *scene = activeScene();
    if (show && !scene) return;
    if (show == isPopupVisible) return;
    if (show) {
        for (UIWindow *window in scene.windows) if (window.isKeyWindow && window != popupWindow) previousKeyWindow = window;
        cursorGeneration++;
        cursorState.menuOpen = true;
        fnReleaseGameKeys();
        fnReleaseGCKeys();
        fnReleaseGameMouseButtons();
        if (!popupWindow || popupWindow.windowScene != scene) {
            popupWindow = [[FnOverlayWindow alloc] initWithWindowScene:scene];
            popupWindow.windowLevel = UIWindowLevelAlert + 1;
            popupWindow.backgroundColor = UIColor.clearColor;
            popupWindow.rootViewController = fnCreateSettingsPanel(FnPanelSettings);
        }
        if (!popupWindow.rootViewController) popupWindow.rootViewController = fnCreateSettingsPanel(FnPanelSettings);
        popupWindow.frame = scene.effectiveGeometry.coordinateSpace.bounds;
        isPopupVisible = YES;
        [popupWindow makeKeyAndVisible];
    } else {
        fnShortcutCapture = nil;
        isPopupVisible = NO;
        cursorState.menuOpen = false;
        popupWindow.hidden = YES;
        popupWindow.rootViewController = nil;
        UIWindow *gameWindow = previousKeyWindow;
        if (!gameWindow) for (UIWindow *window in popupWindow.windowScene.windows)
            if (window != popupWindow && !window.hidden && window.windowLevel == UIWindowLevelNormal) { gameWindow = window; break; }
        [gameWindow makeKeyWindow];
    }
    applyCursorState(show);
}

void fnShowPanel(FnPanelTab tab) {
    if (!isPopupVisible) fnShowMenu(YES);
    if (isPopupVisible && fnCurrentPanelTab() != tab) fnSelectPanelTab(tab);
}

static void togglePanel(FnPanelTab tab) {
    if (isPopupVisible && fnCurrentPanelTab() == tab) fnShowMenu(NO);
    else fnShowPanel(tab);
}

static BOOL shortcutMatches(NSDictionary *shortcut, unsigned short code, NSUInteger flags) {
    return shortcut.count && [shortcut[@"code"] unsignedShortValue] == code &&
        [shortcut[@"modifiers"] unsignedIntegerValue] == (flags & shortcutModifiers);
}

static void installShortcuts(void) {
    Class events = NSClassFromString(@"NSEvent");
    SEL install = NSSelectorFromString(@"addLocalMonitorForEventsMatchingMask:handler:");
    if (![events respondsToSelector:install]) return;
    keyMonitor = ((id (*)(id, SEL, unsigned long long, id))objc_msgSend)(events, install, (1ULL << 10) | (1ULL << 11), ^id(id event) {
        NSUInteger type = ((NSUInteger (*)(id, SEL))objc_msgSend)(event, NSSelectorFromString(@"type"));
        unsigned short code = ((unsigned short (*)(id, SEL))objc_msgSend)(event, NSSelectorFromString(@"keyCode"));
        NSUInteger flags = ((NSUInteger (*)(id, SEL))objc_msgSend)(event, NSSelectorFromString(@"modifierFlags"));
        if (code >= 128) return event;
        if (type == 11) {
            if (consumedKeys[code]) { consumedKeys[code] = NO; return nil; }
            return event;
        }
        if (!realActive) return event;
        if (consumedKeys[code]) return nil;
        if (((BOOL (*)(id, SEL))objc_msgSend)(event, NSSelectorFromString(@"isARepeat"))) return event;
        if (fnShortcutCapture) {
            consumedKeys[code] = YES;
            void (^capture)(NSDictionary *) = fnShortcutCapture;
            fnShortcutCapture = nil;
            if (code == 53) { capture(nil); return nil; }
            NSString *label = ((id (*)(id, SEL))objc_msgSend)(event, NSSelectorFromString(@"charactersIgnoringModifiers"));
            NSDictionary *names = @{@36: @"Return", @48: @"Tab", @49: @"Space", @51: @"Delete", @53: @"Escape",
                @123: @"←", @124: @"→", @125: @"↓", @126: @"↑", @122: @"F1", @120: @"F2", @99: @"F3",
                @118: @"F4", @96: @"F5", @97: @"F6", @98: @"F7", @100: @"F8", @101: @"F9",
                @109: @"F10", @103: @"F11", @111: @"F12"};
            label = names[@(code)] ?: label.uppercaseString;
            if (!label.length) label = [NSString stringWithFormat:@"Key %hu", code];
            capture(@{@"code": @(code), @"modifiers": @(flags & shortcutModifiers), @"label": label});
            return nil;
        }
        if (shortcutMatches(fnMenuShortcut, code, flags)) {
            consumedKeys[code] = YES;
            togglePanel(FnPanelSettings);
            return nil;
        }
        if (shortcutMatches(fnGraphicsShortcut, code, flags)) {
            consumedKeys[code] = YES;
            togglePanel(FnPanelGraphics);
            return nil;
        }
        if (!isPopupVisible && shortcutMatches(fnCursorShortcut, code, flags)) {
            consumedKeys[code] = YES;
            fnSetCursorLocked(!isMouseLocked);
            return nil;
        }
        if (isPopupVisible && code == 53) { consumedKeys[code] = YES; fnShowMenu(NO); return nil; }
        return event;
    });
}

// Keep the engine running in the background without hiding real focus from our UI.
static BOOL withheld[2][2];
static void realFocusChanged(BOOL active) {
    if (realActive == active) return;
    realActive = active;
    fnMouseInputActive = active;
    if (!active) { fnReleaseGameMouseButtons(); fnReleaseGameKeys(); fnReleaseGCKeys(); }
    cursorState.active = active;
    cursorGeneration++;
    if (!active) {
        fnShowMenu(NO);
        cursorState.manualLock = -1;
        fnShortcutCapture = nil;
        memset(consumedKeys, 0, sizeof(consumedKeys));
    }
    applyCursorState(!active || cursorState.gameCursorShown);
}

static void lifecycleCall(id self, SEL cmd, id arg, IMP original) {
    const char *name = sel_getName(cmd);
    int who = !strncmp(name, "scene", 5);
    BOOL inactive = strstr(name, "WillResignActive") != NULL;
    BOOL background = strstr(name, "DidEnterBackground") != NULL;
    BOOL active = strstr(name, "DidBecomeActive") != NULL;
    BOOL foreground = strstr(name, "WillEnterForeground") != NULL;
    if (inactive) realFocusChanged(NO);
    if (active) realFocusChanged(YES);
    if (fnStayActive && (inactive || background)) { withheld[who][background ? 1 : 0] = YES; return; }
    if (active && withheld[who][0]) { withheld[who][0] = NO; return; }
    if (foreground && withheld[who][1]) { withheld[who][1] = NO; return; }
    ((void (*)(id, SEL, id))original)(self, cmd, arg);
}

static void installLifecycle(void) {
    const char *selectors[] = {"applicationWillResignActive:", "applicationDidEnterBackground:", "applicationWillEnterForeground:", "applicationDidBecomeActive:",
        "sceneWillResignActive:", "sceneDidEnterBackground:", "sceneWillEnterForeground:", "sceneDidBecomeActive:"};
    unsigned int count = 0;
    const char **names = objc_copyClassNamesForImage(NSBundle.mainBundle.executablePath.fileSystemRepresentation, &count);
    for (unsigned int i = 0; names && i < count; i++) {
        Class cls = objc_getClass(names[i]);
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int j = 0; j < methodCount; j++) {
            const char *name = sel_getName(method_getName(methods[j]));
            for (int k = 0; k < 8; k++) if (!strcmp(name, selectors[k])) {
                SEL selector = method_getName(methods[j]);
                IMP original = method_getImplementation(methods[j]);
                IMP replacement = imp_implementationWithBlock(^(id object, id argument) {
                    lifecycleCall(object, selector, argument, original);
                });
                method_setImplementation(methods[j], replacement);
            }
        }
        free(methods);
    }
    free(names);
    // AppKit notifications remain reliable even when the game withholds UIKit notifications.
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSString *name in @[@"NSApplicationWillResignActiveNotification", UIApplicationWillResignActiveNotification])
        [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { realFocusChanged(NO); }];
    for (NSString *name in @[@"NSApplicationDidBecomeActiveNotification", UIApplicationDidBecomeActiveNotification])
        [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { realFocusChanged(YES); }];
}

// Frame-rate unlock: retain the branch's Metal and Unreal frame-pacer fixes.
static void (*originalDisplaySync)(id, SEL, BOOL);
static id (*originalNextDrawable)(id, SEL);
static void (*originalPacerSignal)(id, SEL, id);
static void (*originalPresent)(id, SEL);
static void (*originalPresentAfter)(id, SEL, CFTimeInterval);
static void (*originalPresentAt)(id, SEL, CFTimeInterval);
static __weak id frameLayer;
static id framePacer, pacerArgument;
static SEL pacerSelector;
static BOOL requestedDisplaySync = YES;
static pthread_mutex_t pacerMutex = PTHREAD_MUTEX_INITIALIZER;
static dispatch_source_t boostTimer, stallTimer;

static void applyDisplaySync(void) {
    id layer = frameLayer;
    if (layer && originalDisplaySync) originalDisplaySync(layer, NSSelectorFromString(@"setDisplaySyncEnabled:"), fnUnlockFrameRate ? NO : requestedDisplaySync);
}
static void displaySync(id self, SEL cmd, BOOL enabled) {
    requestedDisplaySync = enabled;
    originalDisplaySync(self, cmd, fnUnlockFrameRate ? NO : enabled);
}
static id nextDrawable(id self, SEL cmd) {
    if (frameLayer != self) { frameLayer = self; applyDisplaySync(); fnGraphicsFrameLayer(self); }
    uint64_t start = fnGraphicsBeginFrame();
    id drawable = originalNextDrawable(self, cmd);
    fnGraphicsEndFrame(start);
    return drawable;
}
static void pacerSignal(id self, SEL cmd, id arg) {
    fnGraphicsPacerTick();
    pthread_mutex_lock(&pacerMutex);
    framePacer = self; pacerArgument = arg; pacerSelector = cmd;
    originalPacerSignal(self, cmd, arg);
    pthread_mutex_unlock(&pacerMutex);
}
// Metal present methods can call one another; only redirect the outer call.
static __thread int presentDepth;
static void presentPlain(id self, SEL cmd) {
    presentDepth++;
    originalPresent(self, cmd);
    presentDepth--;
}
static void presentAfter(id self, SEL cmd, CFTimeInterval duration) {
    BOOL outer = presentDepth++ == 0;
    if (outer && fnUnlockFrameRate) {
        double limit = fnUserFrameLimit;
        if (limit > 0) originalPresentAfter(self, cmd, 1.0 / limit);
        else originalPresent(self, NSSelectorFromString(@"present"));
    } else originalPresentAfter(self, cmd, duration);
    presentDepth--;
}
static void presentAt(id self, SEL cmd, CFTimeInterval time) {
    BOOL outer = presentDepth++ == 0;
    if (outer && fnUnlockFrameRate) originalPresent(self, NSSelectorFromString(@"present"));
    else originalPresentAt(self, cmd, time);
    presentDepth--;
}

// Fortnite 43.10 renderer stall workaround. Match the executable call site exactly.
#define FRAME_WAIT_OFFSET 0x20dc494UL
static intptr_t (*originalSemaphoreWait)(dispatch_semaphore_t, dispatch_time_t);
static intptr_t (*originalSemaphoreSignal)(dispatch_semaphore_t);
static pthread_mutex_t frameWaitMutex = PTHREAD_MUTEX_INITIALIZER;
static dispatch_semaphore_t frameSemaphore;
static uint64_t frameWaitStart;
static BOOL frameWaitReleased;
static _Atomic uintptr_t frameWaitSite;
static mach_timebase_info_data_t timebase;

static intptr_t semaphoreWait(dispatch_semaphore_t sem, dispatch_time_t timeout) {
    uintptr_t address = (uintptr_t)__builtin_return_address(0);
    if (timeout == DISPATCH_TIME_FOREVER && !atomic_load(&frameWaitSite) &&
        (address & 0x3fff) == (FRAME_WAIT_OFFSET & 0x3fff)) {
        Dl_info info;
        if (dladdr((void *)address, &info) && info.dli_fbase &&
            ((const struct mach_header_64 *)info.dli_fbase)->filetype == MH_EXECUTE &&
            address - (uintptr_t)info.dli_fbase == FRAME_WAIT_OFFSET) atomic_store(&frameWaitSite, address);
    }
    if (timeout != DISPATCH_TIME_FOREVER || !address || address != atomic_load(&frameWaitSite)) return originalSemaphoreWait(sem, timeout);
    pthread_mutex_lock(&frameWaitMutex);
    frameSemaphore = sem;
    frameWaitStart = mach_absolute_time();
    frameWaitReleased = NO;
    pthread_mutex_unlock(&frameWaitMutex);
    intptr_t result = originalSemaphoreWait(sem, timeout);
    pthread_mutex_lock(&frameWaitMutex);
    frameSemaphore = nil;
    frameWaitStart = 0;
    pthread_mutex_unlock(&frameWaitMutex);
    return result;
}

static void installRendering(void) {
    Class layer = NSClassFromString(@"CAMetalLayer");
    Method sync = class_getInstanceMethod(layer, NSSelectorFromString(@"setDisplaySyncEnabled:"));
    Method next = class_getInstanceMethod(layer, NSSelectorFromString(@"nextDrawable"));
    if (sync) { originalDisplaySync = (void *)method_getImplementation(sync); method_setImplementation(sync, (IMP)displaySync); }
    if (next) { originalNextDrawable = (void *)method_getImplementation(next); method_setImplementation(next, (IMP)nextDrawable); }
    Class pacer = NSClassFromString(@"FIOSFramePacer");
    Method signal = class_getInstanceMethod(pacer, NSSelectorFromString(@"signal:"));
    if (signal) { originalPacerSignal = (void *)method_getImplementation(signal); method_setImplementation(signal, (IMP)pacerSignal); }
    Class drawable = NSClassFromString(@"CAMetalDrawable");
    Method plain = class_getInstanceMethod(drawable, NSSelectorFromString(@"present"));
    Method after = class_getInstanceMethod(drawable, NSSelectorFromString(@"presentAfterMinimumDuration:"));
    Method at = class_getInstanceMethod(drawable, NSSelectorFromString(@"presentAtTime:"));
    if (plain && after && at) {
        originalPresent = (void *)method_getImplementation(plain); method_setImplementation(plain, (IMP)presentPlain);
        originalPresentAfter = (void *)method_getImplementation(after); method_setImplementation(after, (IMP)presentAfter);
        originalPresentAt = (void *)method_getImplementation(at); method_setImplementation(at, (IMP)presentAt);
    }
    boostTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT,
        dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
    dispatch_source_set_timer(boostTimer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), NSEC_PER_MSEC, 0);
    dispatch_source_set_event_handler(boostTimer, ^{
        if (!fnUnlockFrameRate && !(fnStayActive && !realActive)) return;
        pthread_mutex_lock(&pacerMutex);
        if (framePacer && originalPacerSignal) originalPacerSignal(framePacer, pacerSelector, pacerArgument);
        pthread_mutex_unlock(&pacerMutex);
    });
    dispatch_resume(boostTimer);
    struct rebinding bindings[] = {
        {"dispatch_semaphore_wait", (void *)semaphoreWait, (void **)&originalSemaphoreWait}
    };
    // Signal itself needs no interception; only the wait records the stuck frame.
    originalSemaphoreSignal = dispatch_semaphore_signal;
    rebind_symbols(bindings, 1);
    mach_timebase_info(&timebase);
    stallTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    dispatch_source_set_timer(stallTimer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 50 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(stallTimer, ^{
        pthread_mutex_lock(&frameWaitMutex);
        if (frameSemaphore && !frameWaitReleased && frameWaitStart &&
            (double)(mach_absolute_time() - frameWaitStart) * timebase.numer / timebase.denom / 1e6 >= 400) {
            frameWaitReleased = YES;
            originalSemaphoreSignal(frameSemaphore);
            NSLog(@"[FnMacTweak-kbm] Released stalled renderer frame semaphore");
        }
        pthread_mutex_unlock(&frameWaitMutex);
    });
    dispatch_resume(stallTimer);
    [NSNotificationCenter.defaultCenter addObserverForName:FnSettingsChangedNotification object:nil queue:NSOperationQueue.mainQueue
        usingBlock:^(NSNotification *note) { applyDisplaySync(); refreshPointerLock(); }];
}

void fnInstallRuntime(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fnDataFolder();
        [[PerformanceGuard sharedInstance] startHyperPerformanceMode];
        installLifecycle();
        installShortcuts();
        fnInstallPanelInput();
        fnInstallGraphics();
        startCursorLogFollower();
        applyCursorState(YES);
        installRendering();
        [NSNotificationCenter.defaultCenter addObserverForName:@"NSWindowDidBecomeKeyNotification" object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *note) { if (isBorderlessModeEnabled) updateBorderlessMode(); }];
        // Show the actual settings once so the menu remains discoverable without a tutorial.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (![tweakDefaults() boolForKey:@"fnmactweak.lite.menuSeen"] && activeScene()) {
                fnShowMenu(YES);
                [tweakDefaults() setBool:YES forKey:@"fnmactweak.lite.menuSeen"];
            }
        });
    });
}
