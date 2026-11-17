// Graphics implementation and panel ported from FnMac KBM Tweak v3 (MIT).
#import "globals.h"
#import "FnGraphics.h"
#import "FnAppearance.h"
#import "views/popupViewController.h"
#import "../lib/fishhook.h"
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/loader.h>
#import <os/log.h>
#import <math.h>
#import <mach/mach_time.h>
#import <unistd.h>
typedef CFTypeRef CGEventRef;
#define KLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[FnMacTweak-kbm] " fmt, ##__VA_ARGS__)
static __weak id g_fnkbmLayer;
static void fnkbmGfxPanelDisplaysChanged(void);
static void fnkbmCheckPictureFits(const char *why);
static void fnInstallFrameRecovery(void);
static void fnkbmCloseGraphicsPanel(void) { fnShowMenu(NO); }
// ── Displays ─────────────────────────────────────────────────────────────
// The Mac's displays, read through CoreGraphics (resolved at run time, these
// calls are not in the iOS SDK) and AppKit through the runtime. They give the
// resolution list, the content scale answer, the display Fortnite starts on and
// the cursor warps. If a needed CoreGraphics call is missing the list is empty
// and everything behaves as it did on the built-in display.
// CGDisplayPixelsWide is not used: it answers in points, not pixels.
typedef struct { CGFloat top, left, bottom, right; } FnkbmEdgeInsets;
static struct {
    BOOL ok;
    int32_t (*activeList)(uint32_t, uint32_t *, uint32_t *);
    CGRect (*bounds)(uint32_t);
    uint32_t (*mainID)(void);
    int (*isBuiltin)(uint32_t);
    uint32_t (*mirrors)(uint32_t);
    void *(*copyMode)(uint32_t);
    CFArrayRef (*copyAllModes)(uint32_t, CFDictionaryRef);
    size_t (*pixelW)(void *), (*pixelH)(void *), (*pointW)(void *);
    uint32_t (*ioFlags)(void *);
    double (*refresh)(void *);
    void (*releaseMode)(void *);
    CFUUIDRef (*uuid)(uint32_t);
    uint32_t (*vendor)(uint32_t), (*model)(uint32_t), (*serial)(uint32_t);
    int32_t (*registerCallback)(void (*)(uint32_t, uint32_t, void *), void *);
    CFStringRef *duplicateModesKey;
} g_fnkbmCG;

static BOOL fnkbmCGLoad(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW);
        if (!cg) { KLOG("displays: CoreGraphics not loaded, display features off"); return; }
#define FNKBM_CG(field, name) *(void **)&g_fnkbmCG.field = dlsym(cg, name)
        FNKBM_CG(activeList, "CGGetActiveDisplayList");
        FNKBM_CG(bounds, "CGDisplayBounds");
        FNKBM_CG(mainID, "CGMainDisplayID");
        FNKBM_CG(isBuiltin, "CGDisplayIsBuiltin");
        FNKBM_CG(mirrors, "CGDisplayMirrorsDisplay");
        FNKBM_CG(copyMode, "CGDisplayCopyDisplayMode");
        FNKBM_CG(copyAllModes, "CGDisplayCopyAllDisplayModes");
        FNKBM_CG(pixelW, "CGDisplayModeGetPixelWidth");
        FNKBM_CG(pixelH, "CGDisplayModeGetPixelHeight");
        FNKBM_CG(pointW, "CGDisplayModeGetWidth");
        FNKBM_CG(ioFlags, "CGDisplayModeGetIOFlags");
        FNKBM_CG(refresh, "CGDisplayModeGetRefreshRate");
        FNKBM_CG(releaseMode, "CGDisplayModeRelease");
        FNKBM_CG(uuid, "CGDisplayCreateUUIDFromDisplayID");
        FNKBM_CG(vendor, "CGDisplayVendorNumber");
        FNKBM_CG(model, "CGDisplayModelNumber");
        FNKBM_CG(serial, "CGDisplaySerialNumber");
        FNKBM_CG(registerCallback, "CGDisplayRegisterReconfigurationCallback");
        FNKBM_CG(duplicateModesKey, "kCGDisplayShowDuplicateLowResolutionModes");
#undef FNKBM_CG
        g_fnkbmCG.ok = g_fnkbmCG.activeList && g_fnkbmCG.bounds && g_fnkbmCG.mainID && g_fnkbmCG.copyMode && g_fnkbmCG.copyAllModes
                    && g_fnkbmCG.pixelW && g_fnkbmCG.pixelH && g_fnkbmCG.pointW && g_fnkbmCG.ioFlags && g_fnkbmCG.releaseMode;
        if (!g_fnkbmCG.ok) KLOG("displays: a CoreGraphics display call is missing, display features off");
    });
    return g_fnkbmCG.ok;
}

// AppKit, main thread only.
static id fnkbmNSApp(void) {
    Class c = NSClassFromString(@"NSApplication");
    return c ? ((id (*)(Class, SEL))objc_msgSend)(c, NSSelectorFromString(@"sharedApplication")) : nil;
}
static NSArray *fnkbmNSScreens(void) {
    Class c = NSClassFromString(@"NSScreen");
    return c ? ((NSArray *(*)(Class, SEL))objc_msgSend)(c, NSSelectorFromString(@"screens")) : nil;
}
static uint32_t fnkbmScreenID(id screen) {
    if (!screen) return 0;
    NSDictionary *desc = ((NSDictionary *(*)(id, SEL))objc_msgSend)(screen, NSSelectorFromString(@"deviceDescription"));
    return [desc[@"NSScreenNumber"] unsignedIntValue];
}
static id fnkbmScreenForID(uint32_t did) {
    for (id s in fnkbmNSScreens()) if (fnkbmScreenID(s) == did) return s;
    return nil;
}
static CGRect fnkbmRectOf(id obj, NSString *sel) { return ((CGRect (*)(id, SEL))objc_msgSend)(obj, NSSelectorFromString(sel)); }
// The game's window: the main window, else the largest window.
static id fnkbmGameNSWindow(void) {
    id app = fnkbmNSApp();
    if (!app) return nil;
    id win = ((id (*)(id, SEL))objc_msgSend)(app, NSSelectorFromString(@"mainWindow"));
    if (win) return win;
    Class winClass = NSClassFromString(@"NSWindow");
    CGFloat best = 0;
    for (id w in ((NSArray *(*)(id, SEL))objc_msgSend)(app, NSSelectorFromString(@"windows"))) {
        if (winClass && ![w isKindOfClass:winClass]) continue;
        CGRect f = fnkbmRectOf(w, @"frame");
        if (f.size.width * f.size.height > best) { best = f.size.width * f.size.height; win = w; }
    }
    return win;
}
static uint32_t fnkbmWindowDisplay(id win) {
    return win ? fnkbmScreenID(((id (*)(id, SEL))objc_msgSend)(win, NSSelectorFromString(@"screen"))) : 0;
}

// One record per display: id (changes between connections, never saved), key
// (saved), name, ptsW/ptsH, nativeW/nativeH (panel pixels), hz, builtin, safeTop.
// Native size: the mode macOS flags as native (kDisplayModeNativeFlag), else the
// largest 1x mode (no larger than the current mode), else the current mode, else
// points times the backing scale. The largest mode is not used: on the built-in
// display it is a scaled 3600 x 2250 mode, above the 3024 x 1964 panel.
// Names come from NSScreen and are only read on the main thread.
static NSDictionary *fnkbmDisplayRecord(uint32_t did, BOOL appkit) {
    CGRect b = g_fnkbmCG.bounds(did);
    if (b.size.width <= 0 || b.size.height <= 0) return nil;
    size_t curW = 0, curH = 0; double hz = 0;
    void *cur = g_fnkbmCG.copyMode(did);
    if (cur) {
        curW = g_fnkbmCG.pixelW(cur); curH = g_fnkbmCG.pixelH(cur);
        if (g_fnkbmCG.refresh) hz = g_fnkbmCG.refresh(cur);
        g_fnkbmCG.releaseMode(cur);
    }
    size_t natW = 0, natH = 0, oneW = 0, oneH = 0;
    const char *source = "native flag";
    NSString *dupKey = g_fnkbmCG.duplicateModesKey ? (__bridge NSString *)*g_fnkbmCG.duplicateModesKey : @"kCGDisplayShowDuplicateLowResolutionModes";
    CFArrayRef modes = g_fnkbmCG.copyAllModes(did, (__bridge CFDictionaryRef)@{dupKey: @YES});
    if (modes) {
        for (CFIndex i = 0, n = CFArrayGetCount(modes); i < n; i++) {
            void *m = (void *)CFArrayGetValueAtIndex(modes, i);
            size_t pw = g_fnkbmCG.pixelW(m), ph = g_fnkbmCG.pixelH(m);
            if ((g_fnkbmCG.ioFlags(m) & 0x02000000) && pw > natW) { natW = pw; natH = ph; }
            if (pw == g_fnkbmCG.pointW(m) && pw > oneW) { oneW = pw; oneH = ph; }
        }
        CFRelease(modes);
    }
    if (!natW && oneW) {
        source = "largest 1x mode"; natW = oneW; natH = oneH;
        if (curW && natW > curW) { natW = curW; natH = curH; }
    }
    if (!natW && curW) { source = "current mode"; natW = curW; natH = curH; }
    id screen = appkit ? fnkbmScreenForID(did) : nil;
    if (!natW) {
        CGFloat backing = screen ? ((CGFloat (*)(id, SEL))objc_msgSend)(screen, NSSelectorFromString(@"backingScaleFactor")) : 1;
        source = "points";
        natW = (size_t)lround(b.size.width * backing); natH = (size_t)lround(b.size.height * backing);
    }
    BOOL builtin = g_fnkbmCG.isBuiltin ? g_fnkbmCG.isBuiltin(did) != 0 : did == g_fnkbmCG.mainID();
    NSString *key = nil;
    CFUUIDRef u = g_fnkbmCG.uuid ? g_fnkbmCG.uuid(did) : NULL;
    if (u) { key = CFBridgingRelease(CFUUIDCreateString(NULL, u)); CFRelease(u); }
    if (!key.length && g_fnkbmCG.vendor && g_fnkbmCG.model && g_fnkbmCG.serial)
        key = [NSString stringWithFormat:@"v%u-m%u-s%u", g_fnkbmCG.vendor(did), g_fnkbmCG.model(did), g_fnkbmCG.serial(did)];
    if (!key.length) key = [NSString stringWithFormat:@"id%u", did];
    NSString *name = nil;
    CGFloat safeTop = 0;
    if (screen) {
        if ([screen respondsToSelector:NSSelectorFromString(@"localizedName")]) name = ((NSString *(*)(id, SEL))objc_msgSend)(screen, NSSelectorFromString(@"localizedName"));
        if ([screen respondsToSelector:NSSelectorFromString(@"safeAreaInsets")]) safeTop = ((FnkbmEdgeInsets (*)(id, SEL))objc_msgSend)(screen, NSSelectorFromString(@"safeAreaInsets")).top;
    }
    if (!name.length) name = builtin ? @"Built-in display" : [NSString stringWithFormat:@"Display %zu x %zu", natW, natH];
    return @{@"id": @(did), @"key": key, @"name": name, @"ptsW": @(b.size.width), @"ptsH": @(b.size.height),
             @"nativeW": @(natW), @"nativeH": @(natH), @"hz": @(hz), @"builtin": @(builtin), @"safeTop": @(safeTop),
             @"source": @(source)};
}
// Connected displays, mirror copies left out. Empty when CoreGraphics is missing.
static NSArray<NSDictionary *> *fnkbmDisplays(void) {
    NSMutableArray *out = [NSMutableArray array];
    if (!fnkbmCGLoad()) return out;
    uint32_t ids[16], count = 0;
    if (g_fnkbmCG.activeList(16, ids, &count) != 0) return out;
    BOOL appkit = [NSThread isMainThread];
    for (uint32_t i = 0; i < count && i < 16; i++) {
        if (g_fnkbmCG.mirrors && g_fnkbmCG.mirrors(ids[i]) != 0) continue;
        NSDictionary *d = fnkbmDisplayRecord(ids[i], appkit);
        if (d) [out addObject:d];
    }
    return out;
}
static NSDictionary *fnkbmDisplayWithID(NSArray *ds, uint32_t did) {
    for (NSDictionary *d in ds) if ([d[@"id"] unsignedIntValue] == did) return d;
    return nil;
}
static NSDictionary *fnkbmDisplayWithKey(NSArray *ds, NSString *key) {
    for (NSDictionary *d in ds) if (key.length && [d[@"key"] isEqualToString:key]) return d;
    return nil;
}
static void fnkbmLogDisplays(NSArray *ds, const char *why) {
    KLOG("displays (%{public}s): %lu", why, (unsigned long)ds.count);
    for (NSDictionary *d in ds)
        KLOG("display %u %{public}@ \"%{public}@\" builtin=%d points %.0fx%.0f native %{public}@x%{public}@ pixels (%{public}@) %.0f Hz",
             [d[@"id"] unsignedIntValue], d[@"key"], d[@"name"], [d[@"builtin"] boolValue], [d[@"ptsW"] doubleValue], [d[@"ptsH"] doubleValue],
             d[@"nativeW"], d[@"nativeH"], d[@"source"], [d[@"hz"] doubleValue]);
}

// Where the game window is. Kept up to date on the main thread, so the cursor
// warps (some run off the main thread) can turn window points into global
// display coordinates, which CGWarpMouseCursorPosition takes.
static uint32_t g_fnkbmGameDisplay = 0;      // display that holds the game window, 0 = not known yet
static CGPoint g_fnkbmWinOrigin;             // top left of the game's content, global coordinates (top left origin)
static CGSize g_fnkbmWinSize;                // size of the game's content in points
static void fnkbmRefreshGameWindow(void) {
    if (![NSThread isMainThread]) return;
    id win = fnkbmGameNSWindow();
    if (!win) return;
    CGRect frame = fnkbmRectOf(win, @"frame");
    CGRect content = ((CGRect (*)(id, SEL, CGRect))objc_msgSend)(win, NSSelectorFromString(@"contentRectForFrameRect:"), frame);
    id primary = fnkbmNSScreens().firstObject;
    if (!primary || content.size.width <= 0) return;
    CGFloat primaryH = fnkbmRectOf(primary, @"frame").size.height;
    g_fnkbmWinOrigin = CGPointMake(content.origin.x, primaryH - content.origin.y - content.size.height);
    g_fnkbmWinSize = content.size;
    uint32_t did = fnkbmWindowDisplay(win);
    if (did) g_fnkbmGameDisplay = did;
}
// The cursor's place in global display coordinates (top left origin).
static BOOL fnkbmCursorLocation(CGPoint *out) {
    static CGEventRef (*create)(void *) = NULL;
    static CGPoint (*location)(CGEventRef) = NULL;
    if (!create) {
        create = (CGEventRef (*)(void *))dlsym(RTLD_DEFAULT, "CGEventCreate");
        location = (CGPoint (*)(CGEventRef))dlsym(RTLD_DEFAULT, "CGEventGetLocation");
    }
    if (!create || !location) return NO;
    CGEventRef e = create(NULL);
    if (!e) return NO;
    *out = location(e);
    CFRelease(e);
    return YES;
}
// A locked cursor is hidden and stays where it was. Back from another app it can sit
// outside the game (on the other display, or on the edge that shows the menu bar or
// the Dock), so it is moved to the middle of the game. Returns YES when it was moved.
static BOOL fnkbmCursorIntoGame(const char *why) {
    if (g_fnkbmWinSize.width <= 0) return NO;
    CGPoint c;
    if (!fnkbmCursorLocation(&c)) return NO;
    CGRect game = CGRectMake(g_fnkbmWinOrigin.x, g_fnkbmWinOrigin.y, g_fnkbmWinSize.width, g_fnkbmWinSize.height);
    if (CGRectContainsPoint(CGRectInset(game, 8, 8), c)) return NO;
    static CGError (*warp)(CGPoint) = NULL;
    if (!warp) warp = (CGError (*)(CGPoint))dlsym(RTLD_DEFAULT, "CGWarpMouseCursorPosition");
    if (!warp) return NO;
    warp(CGPointMake(CGRectGetMidX(game), CGRectGetMidY(game)));
    KLOG("cursor (%{public}s): was at %.0f,%.0f, outside the game at %.0f,%.0f %.0fx%.0f; moved to its middle",
         why, c.x, c.y, game.origin.x, game.origin.y, game.size.width, game.size.height);
    return YES;
}

// The display Fortnite starts on: "fnkbm.display" holds its key, empty means
// Automatic: the macOS main display (the one with the menu bar, set in System
// Settings > Displays), so a monitor made the main display gets the game. A chosen
// display that is not connected falls back to the built-in display, without a message.
#define FNKBM_DISPLAY_KEY @"fnkbm.display"
#define FNKBM_DISPLAY_NAME_KEY @"fnkbm.displayName"
static NSDictionary *fnkbmStartTarget(NSArray *ds) {
    NSString *key = [[NSUserDefaults standardUserDefaults] stringForKey:FNKBM_DISPLAY_KEY];
    if (!key.length) return g_fnkbmCG.ok ? fnkbmDisplayWithID(ds, g_fnkbmCG.mainID()) : nil;
    NSDictionary *d = fnkbmDisplayWithKey(ds, key);
    if (d) return d;
    for (NSDictionary *b in ds) if ([b[@"builtin"] boolValue]) return b;
    return nil;
}

// Moves the game window to the start display. It is only done when that display is
// connected and is not the one the window is on. A window in macOS full screen on
// another display leaves full screen, moves, and enters full screen on the start
// display (once per start). Run before the window is shown, when it becomes key, and
// when it enters full screen in the first 30 s (macOS restores full screen late).
static int g_fnkbmMoveState = 0;             // 0 nothing done, 1 window moved (or being moved) to the start display, 2 not moved
static uint32_t g_fnkbmMoveTarget = 0;
static BOOL g_fnkbmFullScreenMove = NO;      // the full-screen move was started
static void fnkbmCheckMove(id win, uint32_t tid, NSString *name, double after) {
    __weak id weakWin = win;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(after * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id w = weakWin;
        fnkbmRefreshGameWindow();
        if (w && fnkbmWindowDisplay(w) != tid) {
            KLOG("display: could not move the window to %{public}@, it is on display %u", name, fnkbmWindowDisplay(w));
            g_fnkbmMoveState = 2;
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((after + 4) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ fnkbmCheckPictureFits("start display move"); });
}
static void fnkbmMoveFullScreen(id win, uint32_t cur, uint32_t tid, NSString *name, const char *when) {
    if (g_fnkbmFullScreenMove) return;
    g_fnkbmFullScreenMove = YES;
    g_fnkbmMoveState = 1;   // the content scale is measured on the start display from now on
    KLOG("display: Fortnite is in macOS full screen on display %u (%{public}s); it leaves full screen, moves to %{public}@ and enters full screen there", cur, when, name);
    __block id obs = nil;
    __weak id weakWin = win;
    obs = [[NSNotificationCenter defaultCenter] addObserverForName:@"NSWindowDidExitFullScreenNotification" object:win queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [[NSNotificationCenter defaultCenter] removeObserver:obs];
        obs = nil;
        id w = weakWin;
        if (!w) return;
        id screen = fnkbmScreenForID(tid);
        if (screen) {
            CGRect target = fnkbmRectOf(screen, @"visibleFrame");
            ((void (*)(id, SEL, CGRect, BOOL))objc_msgSend)(w, NSSelectorFromString(@"setFrame:display:"), target, YES);
            KLOG("display: window placed on %{public}@ (%.0f,%.0f %.0fx%.0f), entering full screen there", name, target.origin.x, target.origin.y, target.size.width, target.size.height);
        } else {
            KLOG("display: no screen object for %{public}@, full screen entered again where it was", name);
            g_fnkbmMoveState = 2;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            id w2 = weakWin;
            if (w2) ((void (*)(id, SEL, id))objc_msgSend)(w2, NSSelectorFromString(@"toggleFullScreen:"), nil);
        });
        if (screen) fnkbmCheckMove(w, tid, name, 3.0);
    }];
    ((void (*)(id, SEL, id))objc_msgSend)(win, NSSelectorFromString(@"toggleFullScreen:"), nil);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!obs) return;
        [[NSNotificationCenter defaultCenter] removeObserver:obs];
        obs = nil;
        KLOG("display: full screen was not left within 5 s, window not moved");
        g_fnkbmMoveState = 2;
    });
}
static void fnkbmPlaceOnStartDisplay(id win, const char *when) {
    if (!win || g_fnkbmMoveState == 2) return;
    NSArray *ds = fnkbmDisplays();
    NSDictionary *t = fnkbmStartTarget(ds);
    uint32_t cur = fnkbmWindowDisplay(win);
    NSUInteger mask = ((NSUInteger (*)(id, SEL))objc_msgSend)(win, NSSelectorFromString(@"styleMask"));
    CGRect frame = fnkbmRectOf(win, @"frame");
    KLOG("display (%{public}s): window %{public}s style 0x%lx on display %u, frame %.0f,%.0f %.0fx%.0f, start display %{public}@",
         when, class_getName([win class]), (unsigned long)mask, cur, frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
         t ? t[@"name"] : @"automatic");
    if (!t) return;
    uint32_t tid = [t[@"id"] unsignedIntValue];
    g_fnkbmMoveTarget = tid;
    if (cur == tid) return;
    if (mask & (1UL << 14)) { fnkbmMoveFullScreen(win, cur, tid, t[@"name"], when); return; }
    if (g_fnkbmFullScreenMove) return;   // the full-screen move is under way
    id screen = fnkbmScreenForID(tid);
    if (!screen) { KLOG("display: no screen object for %{public}@, window not moved", t[@"name"]); g_fnkbmMoveState = 2; return; }
    CGRect target = fnkbmRectOf(screen, @"visibleFrame");
    ((void (*)(id, SEL, CGRect, BOOL))objc_msgSend)(win, NSSelectorFromString(@"setFrame:display:"), target, YES);
    g_fnkbmMoveState = 1;
    KLOG("display: window placed on %{public}@ (%.0f,%.0f %.0fx%.0f) %{public}s", t[@"name"], target.origin.x, target.origin.y, target.size.width, target.size.height, when);
    fnkbmCheckMove(win, tid, t[@"name"], 1.0);
}

// The display the game plays on: the start display if the window was moved there,
// else the display that holds the window, else the main display.
static NSDictionary *fnkbmPlayDisplay(NSArray *ds) {
    NSDictionary *d = (g_fnkbmMoveState == 1) ? fnkbmDisplayWithID(ds, g_fnkbmMoveTarget) : nil;
    if (d) return d;
    if ([NSThread isMainThread]) fnkbmRefreshGameWindow();
    d = fnkbmDisplayWithID(ds, g_fnkbmGameDisplay);
    if (d) return d;
    if (g_fnkbmCG.ok) d = fnkbmDisplayWithID(ds, g_fnkbmCG.mainID());
    return d ?: ds.firstObject;
}

// Connect, disconnect, mode and arrangement changes. Several notices come for one
// change, so the work runs 0.5 s after the last. The window is never moved back
// and the scale is not changed live (a live change does not resize the picture).
static void fnkbmDisplaysChanged(void) {
    uint32_t before = g_fnkbmGameDisplay;
    fnkbmRefreshGameWindow();
    fnkbmLogDisplays(fnkbmDisplays(), "changed");
    if (before && g_fnkbmGameDisplay != before) {
        KLOG("display changed: game now on display %u, %.0fx%.0f points; the window is left where macOS put it", g_fnkbmGameDisplay, g_fnkbmWinSize.width, g_fnkbmWinSize.height);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ fnkbmCheckPictureFits("display change"); });
    }
    fnkbmGfxPanelDisplaysChanged();
}
static void fnkbmScheduleDisplaysChanged(void) {
    static int gen = 0;
    int mine = ++gen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ if (mine == gen) fnkbmDisplaysChanged(); });
}
static void fnkbmCGReconfigured(uint32_t did, uint32_t flags, void *ctx) {
    if (flags & 1) return;   // kCGDisplayBeginConfigurationFlag: the change has not happened yet
    dispatch_async(dispatch_get_main_queue(), ^{ fnkbmScheduleDisplaysChanged(); });
}
static void fnkbmInstallDisplayWatch(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    NSOperationQueue *mq = [NSOperationQueue mainQueue];
    [nc addObserverForName:@"NSApplicationDidChangeScreenParametersNotification" object:nil queue:mq
                usingBlock:^(NSNotification *note) { fnkbmScheduleDisplaysChanged(); }];
    if (fnkbmCGLoad() && g_fnkbmCG.registerCallback) {
        int32_t err = g_fnkbmCG.registerCallback(fnkbmCGReconfigured, NULL);
        if (err != 0) KLOG("displays: reconfiguration callback not registered (%d)", err);
    }
    for (NSString *name in @[@"NSWindowDidMoveNotification", @"NSWindowDidResizeNotification", @"NSWindowDidChangeScreenNotification", @"NSWindowDidBecomeKeyNotification"])
        [nc addObserverForName:name object:nil queue:mq usingBlock:^(NSNotification *note) { fnkbmRefreshGameWindow(); }];
    // Second chance for the start display, in case the window was not ready before it was shown.
    id __block observer = [nc addObserverForName:@"NSWindowDidBecomeKeyNotification" object:nil queue:mq usingBlock:^(NSNotification *note) {
        if (fnkbmRectOf(note.object, @"frame").size.width < 400) return;   // not the game window: wait for it
        [[NSNotificationCenter defaultCenter] removeObserver:observer];
        observer = nil;
        id win = note.object;
        fnkbmPlaceOnStartDisplay(win, "became key");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ fnkbmPlaceOnStartDisplay(win, "became key +0.3 s"); });
    }];
    // macOS can restore full screen after that, on the display the game was on last time.
    id fsObserver = [nc addObserverForName:@"NSWindowDidEnterFullScreenNotification" object:nil queue:mq usingBlock:^(NSNotification *note) {
        if (fnkbmRectOf(note.object, @"frame").size.width >= 400) fnkbmPlaceOnStartDisplay(note.object, "entered full screen");
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [[NSNotificationCenter defaultCenter] removeObserver:fsObserver]; });
    dispatch_async(dispatch_get_main_queue(), ^{ fnkbmRefreshGameWindow(); fnkbmLogDisplays(fnkbmDisplays(), "start"); });
}
// ---- Hidden graphics settings -------------------------------------------------
// The patched game asks before it applies a setting by name (device profile,
// quality level, ini): its OnSetCVarFromIniEntry calls access(name, MAGIC), the
// name being the engine's UTF-16 text. Answer 1 and the game leaves that setting
// at its built-in value, which for the plain names below is higher than what an
// iPad profile or the iOS quality levels would set. A name written "name=value"
// is applied instead, with the value given here (see fnkbm_access_impl). Each
// group is a switch in the in-game panel, read once at start; a group marked
// always has no switch and is on whatever was stored for it before. Without this
// tweak the call is a failed file check and the game behaves as usual.
#define FNKBM_CVAR_MAGIC 0x464B4758
typedef struct { const char *ident, *title, *detail, *names; bool always; } FnkbmGfxOption;
static const FnkbmGfxOption kFnkbmGfx[] = {
    {"shadows",  "Shadow detail",            "Larger shadow maps, longer range, more objects cast shadows",
     "r.shadow.maxresolution r.shadow.maxcsmresolution r.shadow.radiusthreshold r.shadow.distancescale wp.runtime.hlod.forcedisableshadows grass.disabledynamicshadows", false},
    {"foliage",  "Grass and foliage",        "Full density and draw distance, top detail level",
     "foliage.densityscale grass.densityscale foliage.culldistancescale grass.culldistancescale foliage.minlod", false},
    // The two loading ranges are given a value instead of being kept: keeping
    // fort.wp.loadingrange would leave the built-in 275 m (the iPad profile's push
    // would set 225 m), while letting that push through with 35000 gives 350 m at
    // the profile's own priority. Every set of these names gets the same value.
    {"detail",   "Detail at distance",       "Characters, landscape, small objects; world loaded to 350 m, terrain to 384 m",
     "r.skeletalmeshlodradiusscale r.landscapeloddistributionscale r.minscreenboundsradius.experimental r.minscreenboundssphereradiuscutoff.experimental r.minscreenboundsignoredistance.experimental lobby.othersquads.forcedlod r.streaming.poolsizeformeshes fort.wp.loadingrange=35000 fort.wp.terrain.loadingrange=38400", false},
    {"water",    "Water",                    "Full water mesh, refraction at full resolution",
     "r.water.watermesh.lodcountbias r.water.watermesh.tessfactorbias r.water.watermesh.lodscalebias r.water.singlelayer.refractiondownsamplefactor r.refractionquality", false},
    {"light",    "Bloom, light shafts, post effects", "Bloom and light shafts (off on iOS), default depth of field and exposure quality",
     "r.bloomquality r.lightshaftquality r.depthoffieldquality r.eyeadaptationquality", false},
    {"sky",      "Sky and haze",             "More samples, larger sky tables, sharper sky reflections",
     "r.skyatmosphere.aerialperspectivelut.depthresolution r.skyatmosphere.aerialperspectivelut.samplecountmaxperslice r.skyatmosphere.fastskylut.samplecountmax r.skyatmosphere.fastskylut.width r.skyatmosphere.fastskylut.height r.skylight.realtimereflectioncapture.resolutionoverride", false},
    {"wind",     "Wind",                     "Wind on foliage, capes and hair",
     "fort.wind p.animdynamicswind", false},
    // Also switches the sampler hook (fnkbmInstallSharp). Boost 2 streams one more
    // texture level where the files have it; the two kept limits let textures load faster.
    {"sharp",    "Sharper textures at distance", "Sharper texture filtering, one more texture level loaded, faster texture loading",
     "r.streaming.boost=2 r.streaming.maxnumtexturestostreamperframe r.streaming.maxtempmemoryallowed", false},
    {"skins",    "Other players' cosmetics", "Higher limits, so more skins, gliders and pickaxes load",
     "fort.cosmeticmanager.maxcharacterparts fort.cosmeticmanager.maxgliders fort.cosmeticmanager.maxpickaxes fort.cosmeticmanager.maxpettypes fort.cosmeticmanager.maxitemwraptypes fort.cosmeticmanager.reducedcosmeticbudgetmultiplier", true},
    {"textures", "Texture pool",             "No fixed 400 MB texture pool",
     "r.streaming.poolsize", true},
    // The iPad profile draws menu text with a half-resolution approximation (built-in:
    // full bitmap glyphs), the shop renders its tiles at 512 x 512 (built-in 2048 x 2048),
    // and the lobby's texture pool is 500 MB, so locker and shop icons stay at lower
    // levels. Menu images get no extra level bias, their top level forced, and news and
    // island images are fetched undivided.
    {"menus",    "Sharp menus and shop",     "Full-resolution text and menu images, 2048 x 2048 shop tiles, 1000 MB texture pool in the lobby",
     "ui.slatesdftext.resolutionlevel ui.slatesdftext.rasterizationmode store.offertileresolution fort.streaming.frontendpoolsize=1000 "
     "r.uitexturelodbias=0 r.forcehighestmiponuitextures=1 cms.imageresdivisor=1 creative.linkdatamanager.linkimageresdivisor=1", true},
    {"ui",       "Menu background blur",     "Normal quality blur behind menus",
     "slate.forcebackgroundblurlowqualityoverride", false},
    // 43.10 marks every Metal resource it releases as purgeable first (this cvar's
    // built-in value is 1). The Mac driver refuses that and logs each refusal: about
    // 33,000 lines a second at 230 fps, which costs time on the render thread and
    // makes macOS stop keeping the app's log after about a minute.
    {"purge",    "No purge of released Metal resources", "The Mac driver refuses it and logs every refusal",
     "rhi.metal.resourcepurgeondelete=0", true},
    // Fortnite's top texture levels are optional downloads. Its SupportsHighResMips
    // (0x107c94374) reads [AssetManager] SupportsHighResMips(_<platform>) unless
    // Fort.EnableHighResMips (built-in -1) is 0 or 1; without it the log says
    // "Skipping Optional Bundles as bShouldDownloadHighResMips is false".
    // r.Streaming.UseAllMips makes the texture streamer use every level a texture has
    // in the files, ignoring the size limits and level bias of its texture group (menu
    // art showed several levels below the screen size at 2560 x 1440).
    {"hdtex",    "High-resolution textures", "Every texture level in the files is used, and Fortnite may download its top levels, as on PC (more memory and disk use; switch off if skins stop loading)",
     "fort.enablehighresmips=1 r.streaming.useallmips=1", false},
    // The iOS device profile turns on dynamic resolution (down to 50%) and caps each
    // frame rate mode: at 120 fps the 3D picture is held to 50% and quality to Medium
    // (Fort.Mobile.120FPS.MaxResQuality 50, MaxQuality 1). Menus stay sharp because
    // they are drawn after the 3D picture is scaled up, so lobby skins and pass art blur.
    // The saved Temporal Super Resolution choice is "Recommended" with no 3D resolution
    // of its own (PotentiallyUpscaledResolutionQuality -1), which renders below the
    // display and upscales; r.ScreenPercentage 100 holds the 3D picture at full size.
    {"res3d",    "Full 3D resolution",       "No upscaling, no automatic resolution drop and no quality cap in high frame rate modes (lower frame rate in heavy scenes)",
     "r.screenpercentage=100 fort.dynamicres.targetscreenpercentage=100 "
     "r.dynamicres.operationmode=0 fort.mobile.maxresquality=100 fort.mobile.45fps.maxresquality=100 fort.mobile.60fps.maxresquality=100 "
     "fort.mobile.90fps.maxresquality=100 fort.mobile.120fps.maxresquality=100 fort.mobile.45fps.maxquality=3 fort.mobile.60fps.maxquality=3 "
     "fort.mobile.90fps.maxquality=3 fort.mobile.120fps.maxquality=3", false},
};
#define FNKBM_GFX_COUNT ((int)(sizeof(kFnkbmGfx) / sizeof(kFnkbmGfx[0])))
static NSString *fnkbmGfxKey(int i) { return [NSString stringWithFormat:@"fnkbm.gfx.%s", kFnkbmGfx[i].ident]; }
static BOOL fnkbmGfxOn(int i) {                       // a switch never touched is on
    if (kFnkbmGfx[i].always) return YES;
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:fnkbmGfxKey(i)];
    return v ? [v boolValue] : YES;
}
// Fortnite's own "download high-resolution textures" setting (shown on PC only) is
// saved as bAllowDownloadHighResMips, False here. With the High-resolution textures
// switch on it is set to True in the saved settings before the game reads them.
static void fnkbmAllowHighResDownload(void) {
    for (int i = 0; i < FNKBM_GFX_COUNT; i++)
        if (!strcmp(kFnkbmGfx[i].ident, "hdtex") && !fnkbmGfxOn(i)) return;
    NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/FortniteGame/Saved/Config/IOS/GameUserSettings.ini"];
    NSStringEncoding enc = NSUTF8StringEncoding;
    NSString *s = [NSString stringWithContentsOfFile:p usedEncoding:&enc error:nil];
    if (![s containsString:@"bAllowDownloadHighResMips=False"]) return;
    NSError *err = nil;
    BOOL ok = [[s stringByReplacingOccurrencesOfString:@"bAllowDownloadHighResMips=False" withString:@"bAllowDownloadHighResMips=True"]
                  writeToFile:p atomically:YES encoding:enc error:&err];
    KLOG("saved settings: bAllowDownloadHighResMips set to True: %{public}s", ok ? "done" : err.localizedDescription.UTF8String);
}
static char g_fnkbmGfxKept[96][64];
static char g_fnkbmGfxValueText[96][16];             // value given instead; empty = keep the built-in value
static uint16_t g_fnkbmGfxValue[96][16];             // the same as UTF-16 text for the game
static _Atomic bool g_fnkbmGfxSaid[96];
static int g_fnkbmGfxKeptN = 0;
static void fnkbmGfxLoad(void) {
    int given = 0;
    for (int i = 0; i < FNKBM_GFX_COUNT; i++) {
        if (!fnkbmGfxOn(i)) continue;
        const char *p = kFnkbmGfx[i].names;
        while (*p && g_fnkbmGfxKeptN < 96) {
            int n = 0;
            while (p[n] && p[n] != ' ' && p[n] != '=' && n < 63) n++;
            memcpy(g_fnkbmGfxKept[g_fnkbmGfxKeptN], p, n); g_fnkbmGfxKept[g_fnkbmGfxKeptN][n] = 0;
            p += n;
            if (*p == '=') {
                int v = 0;
                for (p++; *p && *p != ' '; p++) if (v < 15) { g_fnkbmGfxValueText[g_fnkbmGfxKeptN][v] = *p; g_fnkbmGfxValue[g_fnkbmGfxKeptN][v] = (uint8_t)*p; v++; }
                given++;
            }
            g_fnkbmGfxKeptN++;
            while (*p == ' ') p++;
        }
    }
    KLOG("graphics: %d setting names handled, %d of them given a value, the rest kept at the built-in value", g_fnkbmGfxKeptN, given);
}
static int (*orig_access)(const char *, int) = NULL;
// Names given a value are also set once by the tweak itself, so they apply where the
// game never sets them. That is done through the game's own OnSetCVarFromIniEntry
// (IniFile, Key, Value, SetBy, bAllowCheating, bNoLogging, Tag; its entry is the
// patched branch to the cave, x0 unused), at the first setting from a plugin or
// device profile: by then the game's modules are loaded, and a name not registered
// yet is kept by the engine until it is ("IAmNoRealVariable"). Priority 0x7000000
// is the highest the game itself was seen to use, so its own pushes cannot undo
// these, and pushes through this hook get the same value anyway.
#define FNKBM_SETCVAR_OFFSET 0x691448UL       // OnSetCVarFromIniEntry, from the start of the game file
#define FNKBM_CAVE_RETURN_OFFSET 0x1185410UL  // where access returns to in the cave
#define FNKBM_INJECT_SETBY 0x7000000U
static __thread BOOL g_fnkbmGfxInjecting = NO; // set on the thread inside fnkbmGfxInject
static void fnkbmGfxInject(uintptr_t ra) {
    Dl_info di;
    if (!dladdr((const void *)ra, &di) || !di.dli_fbase || ((const struct mach_header_64 *)di.dli_fbase)->filetype != MH_EXECUTE
        || ra - (uintptr_t)di.dli_fbase != FNKBM_CAVE_RETURN_OFFSET) {
        KLOG("graphics: the game's settings function was not found, values apply only where the game sets them");
        return;
    }
    typedef void (*SetFromIni)(const uint16_t *, const uint16_t *, const uint16_t *, uint32_t, bool, bool, uint64_t);
    SetFromIni set = (SetFromIni)((uintptr_t)di.dli_fbase + FNKBM_SETCVAR_OFFSET);
    static const uint16_t none[1] = {0};
    int n = 0;
    g_fnkbmGfxInjecting = YES;
    for (int i = 0; i < g_fnkbmGfxKeptN; i++) {
        if (!g_fnkbmGfxValue[i][0]) continue;
        uint16_t key[64]; int k = 0;
        for (; k < 63 && g_fnkbmGfxKept[i][k]; k++) key[k] = (uint8_t)g_fnkbmGfxKept[i][k];
        key[k] = 0;
        set(none, key, g_fnkbmGfxValue[i], FNKBM_INJECT_SETBY, false, false, 0);
        n++;
    }
    g_fnkbmGfxInjecting = NO;
    KLOG("graphics: %d values set by the tweak (priority %#x)", n, FNKBM_INJECT_SETBY);
}
static void fnkbmUTF16Text(const uint16_t *s, char *out, int size) {
    int w = 0;
    for (; s && w < size - 1 && s[w]; w++) out[w] = s[w] < 128 ? (char)s[w] : '?';
    out[w] = 0;
}
// Called with the game's (Key, MAGIC, Value, SetBy) still in x0-x3, and frame =
// the stack pointer at the call. The patched game calls access from 17
// instructions at 0x1011853f0 (panel.bin): stp x6,x30,[sp,#-0x40]!, then x0/x1
// at sp+0x10, x2/x3 at sp+0x20, x4/x5 at sp+0x30; bl to the access thunk
// 0x107c0f794 (b to the stub 0x10ac52cac: adrp/ldr/br x16, sp untouched); after
// the call it reloads x2 (Value) from sp+0x20. So writing a pointer to our own
// UTF-16 text into frame[4] and answering 0 makes the game apply that value,
// with the original priority. The game's own text is never written to.
extern "C" __attribute__((used, visibility("hidden"))) int fnkbm_access_impl(const char *path, int mode, const uint16_t *value, uint32_t setBy, void **frame) {
    if (mode != FNKBM_CVAR_MAGIC) return orig_access ? orig_access(path, mode) : -1;

    static _Atomic bool injected = false;
    if ((setBy & 0xFF000000U) >= 0x5000000U && !g_fnkbmGfxInjecting && !atomic_exchange(&injected, true))
        fnkbmGfxInject((uintptr_t)__builtin_return_address(0));
    const uint16_t *k = (const uint16_t *)path;
    char name[64]; int n = 0;
    if (!k) return 0;
    for (; n < 63 && k[n]; n++) { uint16_t c = k[n]; if (c > 127) return 0; name[n] = (char)((c >= 'A' && c <= 'Z') ? c + 32 : c); }
    if (k[n]) return 0;                               // longer than any name in the table
    name[n] = 0;
    char was[24];
    for (int i = 0; i < g_fnkbmGfxKeptN; i++) {
        if (strcmp(name, g_fnkbmGfxKept[i]) != 0) continue;
        BOOL give = g_fnkbmGfxValue[i][0] != 0;
        if (g_fnkbmGfxInjecting) KLOG("graphics: %{public}s set to %{public}s by the tweak", name, g_fnkbmGfxValueText[i]);
        else if (!atomic_exchange(&g_fnkbmGfxSaid[i], true)) {   // once per name
            fnkbmUTF16Text(value, was, sizeof(was));
            if (give) KLOG("graphics: %{public}s set to %{public}s instead of %{public}s (set by %#x)", name, g_fnkbmGfxValueText[i], was, setBy);
            else KLOG("graphics: kept built-in value of %{public}s, not %{public}s (set by %#x)", name, was, setBy);
        }
        if (!give) return 1;
        frame[4] = (void *)g_fnkbmGfxValue[i];          // the saved Value at sp+0x20
        return 0;
    }
    // Other menu and texture settings the game sets, for finding the next one to change.
    static _Atomic int seen = 0;
    if ((!strncmp(name, "ui.", 3) || !strncmp(name, "slate.", 6) || !strncmp(name, "store.", 6) || !strncmp(name, "cms.", 4)
         || strstr(name, "texture") || strstr(name, "mip") || strstr(name, "image") || strstr(name, "icon") || strstr(name, "frontend")
         || strstr(name, "lobby") || strstr(name, "screenpercentage") || strstr(name, "resolution") || strstr(name, "dynamicres")
         || !strncmp(name, "fort.mobile.", 12)) && atomic_fetch_add(&seen, 1) < 80) {
        fnkbmUTF16Text(value, was, sizeof(was));
        KLOG("graphics (game's own): %{public}s = %{public}s (set by %#x)", name, was, setBy);
    }
    return 0;
}
// access itself: hands the stack pointer on in x4, which access does not use.
__attribute__((naked)) static int hooked_access(const char *path, int mode) {
    __asm__ volatile("mov x4, sp\n\tb _fnkbm_access_impl");
}

// ---- Sharper textures at distance (group "sharp") ---------------------------
// The engine's Metal sampler code never passes a mip bias, and gives anisotropy
// only to some filter modes. With the switch on, samplers that repeat their
// texture (world materials; menus, post effects and shadow maps clamp), do no
// depth compare and filter linearly get a mip bias of -0.5 (where the system has
// it, macOS 26 and later). Their anisotropy is left as the engine set it. The engine keeps the samplers it
// made, so the hook goes on the device class as soon as the device exists: the
// game's MTLCreateSystemDefaultDevice is rebound at start, only with the switch on.
// void * keeps ARC away from objects returned retained (create, new).
static void *(*orig_MTLCreateSystemDefaultDevice)(void) = NULL;
static void *(*g_origNewSampler)(id, SEL, id) = NULL;
static _Atomic long g_fnkbmSamplersSeen = 0, g_fnkbmSamplersChanged = 0;
static void *fnkbmNewSampler(id self, SEL _cmd, id desc) {
    long seen = atomic_fetch_add(&g_fnkbmSamplersSeen, 1) + 1;
    MTLSamplerDescriptor *d = desc;
    BOOL wrap = d.sAddressMode == MTLSamplerAddressModeRepeat || d.sAddressMode == MTLSamplerAddressModeMirrorRepeat;
    if (d && wrap && d.compareFunction == MTLCompareFunctionNever && d.minFilter == MTLSamplerMinMagFilterLinear) {
        MTLSamplerDescriptor *c = [d copy];
        SEL bias = sel_registerName("setLodBias:");
        BOOL biased = [c respondsToSelector:bias];
        if (biased) ((void (*)(id, SEL, float))objc_msgSend)(c, bias, -0.5f);
        long changed = atomic_fetch_add(&g_fnkbmSamplersChanged, 1) + 1;
        if (changed <= 3 || changed == 25 || changed == 100 || changed == 400)
            KLOG("sharper textures: %ld of %ld samplers changed (mip bias %{public}s)", changed, seen, biased ? "-0.5" : "not available");
        return g_origNewSampler(self, _cmd, c);
    }
    return g_origNewSampler(self, _cmd, desc);
}
static void *hooked_MTLCreateSystemDefaultDevice(void) {
    void *dev = orig_MTLCreateSystemDefaultDevice ? orig_MTLCreateSystemDefaultDevice() : NULL;
    static dispatch_once_t once;
    if (dev) dispatch_once(&once, ^{
        Class cls = object_getClass((__bridge id)dev);
        Method m = class_getInstanceMethod(cls, sel_registerName("newSamplerStateWithDescriptor:"));
        if (!m) { KLOG("sharper textures: %{public}s has no sampler method", class_getName(cls)); return; }
        g_origNewSampler = (void *(*)(id, SEL, id))method_getImplementation(m);
        method_setImplementation(m, (IMP)fnkbmNewSampler);
        KLOG("sharper textures: sampler hook on %{public}s", class_getName(cls));
    });
    return dev;
}
static void fnkbmInstallSharp(void) {
    int i = 0;
    while (i < FNKBM_GFX_COUNT && strcmp(kFnkbmGfx[i].ident, "sharp") != 0) i++;
    if (i == FNKBM_GFX_COUNT || !fnkbmGfxOn(i)) { KLOG("sharper textures off"); return; }
    struct rebinding r[] = {{"MTLCreateSystemDefaultDevice", (void *)hooked_MTLCreateSystemDefaultDevice, (void **)&orig_MTLCreateSystemDefaultDevice}};
    rebind_symbols(r, sizeof(r) / sizeof(r[0]));
    KLOG("sharper textures on: waiting for the Metal device");
}

// Output size. On iOS the engine sizes its picture with one number, the content scale
// factor (r.MobileContentScaleFactor, 2.0 in this device profile: 1512 points -> 3024
// pixels). The view, the frame layer, touches and the mouse all use it, and the game's
// app delegate hands it out. The answer here is the scale that gives the chosen width
// across the window, never more than the native scale of the display the game plays
// on (its panel pixels over its points: 2.0 on the built-in display, 1.0 on a 1x
// monitor), so nothing is ever supersampled. The width is chosen per display in the
// graphics panel, saved, and used from the next start.
// (An earlier try answered RequestedResX instead: the picture stayed 3024 wide and
// clicks missed.)
#define FNKBM_WIDTH_KEY @"fnkbm.outputWidth"
static float g_fnkbmGameScale = 0;      // the game's own content scale
static CGSize g_fnkbmWindowPts;         // window size in points when the game last asked
static float g_fnkbmAnswered = 0;       // the scale the tweak answered

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static CGSize fnkbmWindowPoints(void) {
    CGSize pts = [UIScreen mainScreen].bounds.size;
    UIWindow *win = [UIApplication sharedApplication].windows.firstObject;
    if (win && win.bounds.size.width > 0) pts = win.bounds.size;
    return pts;
}
#pragma clang diagnostic pop

// The width is saved per display, 0 = native. The built-in display also reads the
// width saved before widths were kept per display.
static NSString *fnkbmWidthKey(NSDictionary *d) {
    NSString *key = d[@"key"];
    return key.length ? [FNKBM_WIDTH_KEY stringByAppendingFormat:@".%@", key] : FNKBM_WIDTH_KEY;
}
static NSInteger fnkbmSavedWidth(NSDictionary *d) {
    NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
    id v = [u objectForKey:fnkbmWidthKey(d)];
    if (v) return [v integerValue];
    return (!d || [d[@"builtin"] boolValue]) ? [u integerForKey:FNKBM_WIDTH_KEY] : 0;
}
// Without CoreGraphics: one display made from the window and the game's own scale.
static NSDictionary *fnkbmFallbackDisplay(void) {
    CGSize pts = g_fnkbmWindowPts.width > 0 ? g_fnkbmWindowPts : fnkbmWindowPoints();
    CGFloat w = MAX(pts.width, pts.height), h = MIN(pts.width, pts.height);
    float s = g_fnkbmGameScale;
    return @{@"name": @"This display", @"ptsW": @(w), @"ptsH": @(h), @"builtin": @YES,
             @"nativeW": @(s > 0 ? lround(w * s) : 0), @"nativeH": @(s > 0 ? lround(h * s) : 0)};
}

// Native first, then the standard widths below native; at most 10 rows, so the
// smallest widths are dropped on a large display. A saved width that is not in
// the list gets its own row. Heights are labels only: the engine derives them.
static NSArray *fnkbmResolutionChoices(NSDictionary *d) {   // @[title, detail, @(width)], width 0 = native
    NSInteger native = [d[@"nativeW"] integerValue];
    CGFloat ratio = 0;
    if (d[@"id"] && [d[@"id"] unsignedIntValue] == g_fnkbmGameDisplay && g_fnkbmWinSize.width > 0) ratio = g_fnkbmWinSize.height / g_fnkbmWinSize.width;
    else if ([d[@"ptsW"] doubleValue] > 0) ratio = ([d[@"ptsH"] doubleValue] - [d[@"safeTop"] doubleValue]) / [d[@"ptsW"] doubleValue];
    NSString *(^label)(NSInteger) = ^NSString *(NSInteger w) {
        return ratio > 0 ? [NSString stringWithFormat:@"%ld x %ld", (long)w, (long)lround(w * ratio)] : [NSString stringWithFormat:@"%ld wide", (long)w];
    };
    NSMutableArray *widths = [NSMutableArray array];
    static const NSInteger standard[] = {3840, 3440, 3200, 2880, 2560, 2240, 1920, 1680, 1600, 1440, 1280};
    for (size_t i = 0; i < sizeof(standard) / sizeof(standard[0]) && widths.count < 9; i++)
        if (native > 0 && standard[i] < native) [widths addObject:@(standard[i])];
    NSInteger saved = fnkbmSavedWidth(d);
    if (saved > 0 && native > 0 && saved < native && ![widths containsObject:@(saved)]) {
        [widths addObject:@(saved)];
        [widths sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) { return [b compare:a]; }];
    }
    NSMutableArray *out = [NSMutableArray arrayWithObject:@[@"Native", native > 0 ? label(native) : @"", @0]];
    for (NSNumber *w in widths) [out addObject:@[label(w.integerValue), @"", w]];
    return out;
}

// ---- Colour blind filter -----------------------------------------------------------
// Fortnite's own Color Blind Mode cannot work in the iOS build: its Settings rows are
// disabled there ("Platform does not support Color Blind Mode") and the renderer never
// uses the shader that draws it (FSlatePostProcessColorDeficiencyPS). So the tweak
// corrects colours the way that shader does on PC (daltonize): simulate the deficiency
// (Machado 2009, full severity), take what is lost and move it into green and blue.
// It is one 3x3 matrix, out = (I + k * D * (I - S)) * in, run by the macOS compositor on
// the game's frame layer (a colorMatrix layer filter), so it changes at once and the
// game renders nothing extra. Every row sums to 1: grey and white stay as they are.
#define FNKBM_CB_MODE_KEY @"fnkbm.colorBlindMode"           // 0 off, 1 deuteranope, 2 protanope, 3 tritanope
#define FNKBM_CB_STRENGTH_KEY @"fnkbm.colorBlindStrength"   // 0 to 10, as in Fortnite
struct CAColorMatrix { float m11, m12, m13, m14, m15, m21, m22, m23, m24, m25, m31, m32, m33, m34, m35, m41, m42, m43, m44, m45; };
static NSInteger fnkbmCBMode(void) {
    NSInteger m = [[NSUserDefaults standardUserDefaults] integerForKey:FNKBM_CB_MODE_KEY];
    return (m >= 0 && m <= 3) ? m : 0;
}
static NSInteger fnkbmCBStrength(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:FNKBM_CB_STRENGTH_KEY];
    return v ? MAX(0, MIN(10, [v integerValue])) : 5;
}
static void fnkbmCBMatrix(NSInteger mode, NSInteger strength, float c[3][3]) {
    static const float sim[3][3][3] = {
        {{0.367322f, 0.860646f, -0.227968f}, {0.280085f, 0.672501f, 0.047413f}, {-0.011820f, 0.042940f, 0.968881f}},   // deuteranope
        {{0.152286f, 1.052583f, -0.204868f}, {0.114503f, 0.786281f, 0.099216f}, {-0.003882f, -0.048116f, 1.051998f}},  // protanope
        {{1.255528f, -0.076749f, -0.178779f}, {-0.078411f, 0.930809f, 0.147602f}, {0.004733f, 0.691367f, 0.303900f}},  // tritanope
    };
    static const float shift[3][3] = {{0, 0, 0}, {0.7f, 1, 0}, {0.7f, 0, 1}};
    float k = strength / 10.0f;
    for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) {
        float e = 0;
        if (mode >= 1 && mode <= 3)
            for (int t = 0; t < 3; t++) e += shift[i][t] * ((t == j ? 1.0f : 0.0f) - sim[mode - 1][t][j]);
        c[i][j] = (i == j ? 1.0f : 0.0f) + k * e;
    }
}
// Main thread. Called when the frame layer first shows up and on every panel change.
static void fnkbmApplyColorFilter(void) {
    id layer = g_fnkbmLayer;
    if (!layer) return;
    NSInteger mode = fnkbmCBMode(), strength = fnkbmCBStrength();
    NSArray *filters = nil;
    if (mode && strength) {
        Class filterClass = NSClassFromString(@"CAFilter");
        SEL make = NSSelectorFromString(@"valueWithCAColorMatrix:");
        if (!filterClass || ![NSValue respondsToSelector:make]) { KLOG("colour blind: the macOS colour filter is missing, nothing applied"); return; }
        float c[3][3];
        fnkbmCBMatrix(mode, strength, c);
        struct CAColorMatrix m = {c[0][0], c[0][1], c[0][2], 0, 0,  c[1][0], c[1][1], c[1][2], 0, 0,
                                  c[2][0], c[2][1], c[2][2], 0, 0,  0, 0, 0, 1, 0};
        id f = ((id (*)(id, SEL, id))objc_msgSend)(filterClass, NSSelectorFromString(@"filterWithType:"), @"colorMatrix");
        [f setValue:((NSValue *(*)(id, SEL, struct CAColorMatrix))objc_msgSend)([NSValue class], make, m) forKey:@"inputColorMatrix"];
        filters = @[f];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [layer setValue:filters forKey:@"filters"];
    [CATransaction commit];
    static const char *names[] = {"off", "deuteranope", "protanope", "tritanope"};
    KLOG("colour blind: %{public}s, strength %ld, layer filters now %lu", names[mode], (long)strength, (unsigned long)[[layer valueForKey:@"filters"] count]);
}

// ---- Graphics panel --------------------------------------------------------------
// A glass card over the game in a window of its own, in the look of Orbit's quick
// menu. Opened from FnMac > Graphics Panel in the Mac menu bar; closed with its
// Close button, Esc, or a click outside the card. Everything in it is saved and used
// from the next start of the game. While it is open isPopupVisible is set too, so the
// cursor stays free and the game gets no keys, clicks or wheel; when it closes, the
// log follower sees the change and locks the cursor again if the game has it hidden.
// Everything fits a 1512 x 949 point window without scrolling (the mouse wheel does
// not scroll UIKit lists here); a smaller window scales the card down.
static BOOL g_fnkbmUseGlass = YES;   // NO: use the dark blur material instead of glass
static UIColor *fnkbmNight(CGFloat a) { return [UIColor colorWithRed:0.05 green:0.06 blue:0.09 alpha:a]; }

// Glass (macOS 26) with a dark tint, so white text reads over a bright picture; a
// dark blur where glass is missing; nothing (an opaque fill) with Reduce Transparency.
static UIVisualEffect *fnkbmCardEffect(void) {
    if (UIAccessibilityIsReduceTransparencyEnabled()) return nil;
    Class glass = g_fnkbmUseGlass ? NSClassFromString(@"UIGlassEffect") : Nil;
    if (glass) {
        UIVisualEffect *g = ((UIVisualEffect *(*)(Class, SEL, NSInteger))objc_msgSend)(glass, NSSelectorFromString(@"effectWithStyle:"), 0);   // regular
        [g setValue:fnkbmNight(UIAccessibilityDarkerSystemColorsEnabled() ? 0.80 : 0.55) forKey:@"tintColor"];
        [g setValue:@NO forKey:@"interactive"];
        if (g) return g;
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark];
}
static UIVisualEffectView *fnkbmGlassCard(CGFloat radius, UIVisualEffect *effect) {
    BOOL contrast = UIAccessibilityDarkerSystemColorsEnabled();
    BOOL blur = [effect isKindOfClass:[UIBlurEffect class]];
    UIVisualEffectView *v = [[UIVisualEffectView alloc] initWithEffect:effect];
    v.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    if (!effect) v.backgroundColor = [UIColor colorWithRed:0.075 green:0.09 blue:0.13 alpha:1];   // Orbit's Deck.card
    if (blur) {
        UIView *tint = [[UIView alloc] initWithFrame:v.bounds];
        tint.backgroundColor = fnkbmNight(contrast ? 0.80 : 0.45);
        tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [v.contentView addSubview:tint];
    }
    v.layer.cornerRadius = radius;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    Class cc = NSClassFromString(@"UICornerConfiguration"), cr = NSClassFromString(@"UICornerRadius");
    SEL setCorner = NSSelectorFromString(@"setCornerConfiguration:");
    if (effect && !blur && cc && cr && [v respondsToSelector:setCorner]) {
        id r = ((id (*)(Class, SEL, CGFloat))objc_msgSend)(cr, NSSelectorFromString(@"fixedRadius:"), radius);
        id c = ((id (*)(Class, SEL, id))objc_msgSend)(cc, NSSelectorFromString(@"configurationWithUniformRadius:"), r);
        ((void (*)(id, SEL, id))objc_msgSend)(v, setCorner, c);
    } else {
        v.clipsToBounds = YES;
    }
    v.layer.borderWidth = 1;
    v.layer.borderColor = [UIColor colorWithWhite:1 alpha:contrast ? 0.30 : 0.12].CGColor;
    return v;
}
static UILabel *fnkbmLabel(NSString *text, CGFloat size, UIFontWeight weight, CGFloat white) {
    UILabel *l = [UILabel new];
    l.text = text;
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = [UIColor colorWithWhite:1 alpha:white];
    return l;
}
// Section header: upper case, 11 semibold, white 0.66 (Orbit uses 0.55; 0.66 keeps
// 4.5:1 over a white picture).
static UILabel *fnkbmHeader(NSString *text, CGRect frame) {
    UILabel *l = fnkbmLabel(nil, 11, UIFontWeightSemibold, 0.66);
    l.attributedText = [[NSAttributedString alloc] initWithString:text.uppercaseString attributes:@{NSKernAttributeName: @1.2}];
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    l.accessibilityTraits = UIAccessibilityTraitHeader;
    l.frame = frame;
    return l;
}
// Inner group: a plain fill on the one glass card (glass is never nested).
static UIView *fnkbmGroup(CGRect frame) {
    UIView *g = [[UIView alloc] initWithFrame:frame];
    g.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
    g.layer.cornerRadius = 16;
    g.layer.cornerCurve = kCACornerCurveContinuous;
    return g;
}

// A row: hover, press and selected fills as in Orbit's settings rows.
@interface FnkbmRow : UIControl
@property (nonatomic, strong) UILabel *title, *detail;
@property (nonatomic, strong) UIImageView *check;   // selectable rows
@property (nonatomic, strong) UISwitch *toggle;     // switch rows
@property (nonatomic, copy) NSString *value;        // display key, for display rows
@property (nonatomic, copy) void (^onHover)(void);
@property (nonatomic) BOOL hovered;
@end
@implementation FnkbmRow
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.layer.cornerRadius = 10;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        [self addGestureRecognizer:[[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(fnkbmHover:)]];
    }
    return self;
}
- (void)fnkbmHover:(UIHoverGestureRecognizer *)g {
    BOOL now = (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged);
    if (now && !self.hovered && self.onHover) self.onHover();
    self.hovered = now;
    [self restyle];
}
- (void)setHighlighted:(BOOL)h { [super setHighlighted:h]; [self restyle]; }
- (void)setSelected:(BOOL)s {
    [super setSelected:s];
    self.check.alpha = s ? 1 : 0;
    if (s) self.accessibilityTraits |= UIAccessibilityTraitSelected;
    else self.accessibilityTraits &= ~UIAccessibilityTraitSelected;
    [self restyle];
}
- (void)restyle {
    CGFloat a = !self.enabled ? 0 : self.highlighted ? 0.24 : self.hovered ? 0.18 : (self.selected && self.check) ? 0.10 : 0;
    void (^apply)(void) = ^{ self.backgroundColor = [UIColor colorWithWhite:1 alpha:a]; };
    if (UIAccessibilityIsReduceMotionEnabled()) apply();
    else [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState animations:apply completion:nil];
}
@end

// Selectable row, 34 high: checkmark in a 14 pt slot, title, detail at the right.
static FnkbmRow *fnkbmChoiceRow(CGFloat width, NSString *title, NSString *detail, BOOL selected) {
    FnkbmRow *r = [[FnkbmRow alloc] initWithFrame:CGRectMake(0, 0, width, 34)];
    UIImageSymbolConfiguration *c = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightBold];
    r.check = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark" withConfiguration:c]];
    r.check.contentMode = UIViewContentModeCenter;
    r.check.frame = CGRectMake(12, 0, 14, 34);
    r.title = fnkbmLabel(title, 13, UIFontWeightSemibold, 1);
    r.title.lineBreakMode = NSLineBreakByTruncatingTail;
    r.detail = fnkbmLabel(detail, 12, UIFontWeightRegular, 0.66);
    r.detail.textAlignment = NSTextAlignmentRight;
    r.detail.lineBreakMode = NSLineBreakByTruncatingMiddle;
    CGFloat dw = detail.length ? MIN(140, ceil([r.detail sizeThatFits:CGSizeMake(300, 34)].width)) : 0;
    r.detail.frame = CGRectMake(width - 12 - dw, 0, dw, 34);
    r.title.frame = CGRectMake(36, 0, width - 36 - 12 - dw - (dw ? 8 : 0), 34);
    [r addSubview:r.check]; [r addSubview:r.title]; [r addSubview:r.detail];
    r.selected = selected;
    r.isAccessibilityElement = YES;
    r.accessibilityTraits |= UIAccessibilityTraitButton;
    r.accessibilityLabel = detail.length ? [NSString stringWithFormat:@"%@, %@", title, detail] : title;
    return r;
}
// Switch row, 40 high. The whole row toggles, not only the switch.
static FnkbmRow *fnkbmSwitchRow(CGFloat width, int index, id target) {
    FnkbmRow *r = [[FnkbmRow alloc] initWithFrame:CGRectMake(0, 0, width, 40)];
    r.tag = index;
    r.toggle = [UISwitch new];
    r.toggle.on = fnkbmGfxOn(index);
    r.toggle.tag = index;
    r.toggle.onTintColor = fnAccentColor();
    CGSize sw = r.toggle.intrinsicContentSize;
    r.toggle.frame = CGRectMake(width - 12 - sw.width, (40 - sw.height) / 2, sw.width, sw.height);
    [r.toggle addTarget:target action:@selector(fnkbmSwitched:) forControlEvents:UIControlEventValueChanged];
    r.title = fnkbmLabel(@(kFnkbmGfx[index].title), 13, UIFontWeightSemibold, 1);
    r.title.frame = CGRectMake(12, 0, CGRectGetMinX(r.toggle.frame) - 24, 40);
    r.title.adjustsFontSizeToFitWidth = YES;
    r.title.minimumScaleFactor = 0.85;
    [r addSubview:r.title]; [r addSubview:r.toggle];
    [r addTarget:target action:@selector(fnkbmRowTapped:) forControlEvents:UIControlEventTouchUpInside];
    r.isAccessibilityElement = NO;   // the switch is the element
    r.toggle.accessibilityLabel = @(kFnkbmGfx[index].title);
    r.toggle.accessibilityHint = @(kFnkbmGfx[index].detail);
    return r;
}
// Close: Orbit's prominent action, a white pill with dark text.
static UIButton *fnkbmCloseButton(id target) {
    UIButtonConfiguration *c = [UIButtonConfiguration filledButtonConfiguration];
    c.title = @"Close";
    c.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    c.baseBackgroundColor = [UIColor colorWithWhite:1 alpha:0.94];
    c.baseForegroundColor = [UIColor colorWithRed:0.04 green:0.05 blue:0.08 alpha:1];
    c.contentInsets = NSDirectionalEdgeInsetsMake(8, 22, 8, 22);
    c.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *a) {
        NSMutableDictionary *m = [a mutableCopy];
        m[NSFontAttributeName] = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        return m;
    };
    UIButton *b = [UIButton buttonWithConfiguration:c primaryAction:nil];
    [b addTarget:target action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    b.accessibilityHint = @"Returns to the game";
    return b;
}

// What the next start is made from: start display, resolution per display and the
// graphics switches, as "title|which" -> value. Only the panel changes them, so their
// state when the panel first opens is what this run started with.
static NSDictionary *fnkbmNextStartState(void) {
    NSMutableDictionary *s = [NSMutableDictionary dictionary];
    s[@"Start display|"] = [[NSUserDefaults standardUserDefaults] stringForKey:FNKBM_DISPLAY_KEY] ?: @"";
    for (NSDictionary *d in fnkbmDisplays()) s[[@"Resolution|" stringByAppendingString:d[@"key"] ?: @""]] = @(fnkbmSavedWidth(d));
    for (int i = 0; i < FNKBM_GFX_COUNT; i++) if (!kFnkbmGfx[i].always) s[[NSString stringWithFormat:@"%s|", kFnkbmGfx[i].title]] = @(fnkbmGfxOn(i));
    return s;
}
// Titles of the settings changed since this run started, or nil: they wait for a restart.
static NSString *fnkbmRestartNeeded(void) {
    static NSDictionary *start = nil;
    NSDictionary *now = fnkbmNextStartState();
    if (!start) start = now;
    NSMutableOrderedSet *titles = [NSMutableOrderedSet orderedSet];
    for (NSString *k in [now.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        id was = start[k];                            // a display connected since has nothing to compare
        if (was && ![was isEqual:now[k]]) [titles addObject:[k componentsSeparatedByString:@"|"].firstObject];
    }
    return titles.count ? [titles.array componentsJoinedByString:@", "] : nil;
}

@interface FnkbmGraphicsPanel : UIViewController
@property (nonatomic, strong) UILabel *restartNote;
@property (nonatomic, strong) UIImageView *restartIcon;
@property (nonatomic, copy) NSString *restartSaid;
@property (nonatomic, strong) UIControl *scrim;
@property (nonatomic, strong) UIVisualEffectView *card;
@property (nonatomic, strong) UIVisualEffect *cardEffect;
@property (nonatomic, strong) UIView *body;
@property (nonatomic, strong) UILabel *hint;
@property (nonatomic, strong) NSArray *displays;
@property (nonatomic, strong) NSDictionary *shown;          // display whose resolutions are listed
@property (nonatomic, strong) NSMutableArray *resolutionRows;
@property (nonatomic, strong) NSMutableArray *cbRows;
@property (nonatomic, strong) UISlider *cbSlider;
@property (nonatomic, strong) UILabel *cbValue;
@property (nonatomic) BOOL animateIn;
@property (nonatomic, strong) NSMutableArray *appearanceObservers;
@property (nonatomic) NSInteger selectedTab;
@property (nonatomic, strong) popupViewController *settings;
- (void)rebuild;
@end
@implementation FnkbmGraphicsPanel
- (void)viewDidLoad {
    [super viewDidLoad];
    self.appearanceObservers = [NSMutableArray array];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = UIColor.clearColor;
    // Clicks outside the card land here: they close the panel and never reach the game.
    self.scrim = [[UIControl alloc] initWithFrame:self.view.bounds];
    self.scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scrim.backgroundColor = [UIColor colorWithRed:0.04 green:0.05 blue:0.08 alpha:0.35];
    [self.scrim addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    self.scrim.accessibilityLabel = @"Close graphics panel";
    [self.view addSubview:self.scrim];
    self.cardEffect = fnkbmCardEffect();
    self.card = fnkbmGlassCard(26, self.cardEffect);
    self.card.layer.shadowColor = UIColor.blackColor.CGColor;   // only shows where the card does not clip (glass)
    self.card.layer.shadowOpacity = 0.45;
    self.card.layer.shadowRadius = 30;
    self.card.layer.shadowOffset = CGSizeMake(0, 14);
    [self.view addSubview:self.card];
    self.body = [UIView new];
    [self.card.contentView addSubview:self.body];
    // Opening: the material comes in from nothing (alpha on an effect view breaks it).
    self.animateIn = self.cardEffect && !UIAccessibilityIsReduceMotionEnabled();
    if (self.animateIn) { self.card.effect = nil; self.body.alpha = 0; self.scrim.alpha = 0; }
    [self rebuild];
    __weak typeof(self) weakSelf = self;
    for (NSString *name in @[@"NSSystemColorsDidChangeNotification", @"NSApplicationDidBecomeActiveNotification"]) {
        id observer = [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *note) {
                typeof(self) panel = weakSelf;
                if (panel.isViewLoaded) fnApplyAccentColor(panel.view);
            }];
        [self.appearanceObservers addObject:observer];
    }
}
- (void)dealloc {
    for (id observer in self.appearanceObservers) [NSNotificationCenter.defaultCenter removeObserver:observer];
}
- (void)rebuild {
    fnShortcutCapture = nil;
    [self.settings willMoveToParentViewController:nil];
    [self.settings.view removeFromSuperview];
    [self.settings removeFromParentViewController];
    self.settings = nil;
    for (UIView *v in [self.body.subviews copy]) [v removeFromSuperview];
    NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
    NSArray *ds = fnkbmDisplays();
    self.displays = ds;
    fnkbmRefreshGameWindow();
    NSString *savedKey = [u stringForKey:FNKBM_DISPLAY_KEY] ?: @"";
    NSDictionary *saved = fnkbmDisplayWithKey(ds, savedKey);
    NSDictionary *game = fnkbmDisplayWithID(ds, g_fnkbmGameDisplay);
    if (!game && g_fnkbmCG.ok) game = fnkbmDisplayWithID(ds, g_fnkbmCG.mainID());
    self.shown = fnkbmStartTarget(ds) ?: game ?: ds.firstObject ?: fnkbmFallbackDisplay();

    const CGFloat pad = 20, leftW = 300, gap = 20, rightW = 400, cardW = pad * 2 + leftW + gap + rightW;
    UILabel *title = fnkbmLabel(@"FnMacTweak-KBM", 20, UIFontWeightBold, 1);
    title.accessibilityTraits = UIAccessibilityTraitHeader;
    title.frame = CGRectMake(pad, pad, cardW - pad * 2 - 140, 36);
    [self.body addSubview:title];
    UIButton *close = fnkbmCloseButton(self);
    CGFloat cw = MAX(96, ceil([close sizeThatFits:CGSizeMake(200, 36)].width));
    close.frame = CGRectMake(cardW - pad - cw, pad, cw, 36);
    [self.body addSubview:close];
    UISegmentedControl *tabs = [[UISegmentedControl alloc] initWithItems:@[@"Graphics", @"Settings"]];
    tabs.frame = CGRectMake(pad, pad + 36 + 12, cardW - pad * 2, 32);
    tabs.selectedSegmentIndex = self.selectedTab;
    tabs.accessibilityLabel = @"Settings section";
    [tabs addTarget:self action:@selector(tabChanged:) forControlEvents:UIControlEventValueChanged];
    [self.body addSubview:tabs];
    const CGFloat top = pad + 36 + 12 + 32 + 16;
    // Left column: display, then resolution.
    CGFloat x = pad, y = top;
    if (ds.count > 1) {
        [self.body addSubview:fnkbmHeader(@"Start on display", CGRectMake(x + 12, y, leftW - 24, 14))];
        y += 20;
        NSMutableArray *rows = [NSMutableArray array];
        NSDictionary *mainD = g_fnkbmCG.ok ? fnkbmDisplayWithID(ds, g_fnkbmCG.mainID()) : nil;
        FnkbmRow *automatic = fnkbmChoiceRow(leftW - 12, @"Main display", mainD ? mainD[@"name"] : @"automatic", savedKey.length == 0);
        automatic.accessibilityHint = @"Follows the main display set in System Settings, Displays";
        automatic.value = @"";
        [rows addObject:automatic];
        for (NSDictionary *d in ds) {
            FnkbmRow *r = fnkbmChoiceRow(leftW - 12, d[@"name"], [NSString stringWithFormat:@"%@ x %@", d[@"nativeW"], d[@"nativeH"]], d == saved);
            r.value = d[@"key"];
            [rows addObject:r];
        }
        if (savedKey.length && !saved) {   // chosen before, not connected now: kept, starts on the built-in display
            NSString *name = [u stringForKey:FNKBM_DISPLAY_NAME_KEY] ?: @"Chosen display";
            FnkbmRow *r = fnkbmChoiceRow(leftW - 12, name, @"not connected", YES);
            r.enabled = NO;
            r.alpha = 0.55;
            [rows addObject:r];
        }
        for (FnkbmRow *r in rows) if (r.enabled) [r addTarget:self action:@selector(fnkbmDisplayTapped:) forControlEvents:UIControlEventTouchUpInside];
        y += [self addGroupWithRows:rows at:CGPointMake(x, y) width:leftW rowHeight:34 dividers:NO] + 16;
    }
    NSString *resTitle = ds.count > 1 ? [NSString stringWithFormat:@"Resolution on %@", self.shown[@"name"]] : @"Resolution";
    [self.body addSubview:fnkbmHeader(resTitle, CGRectMake(x + 12, y, leftW - 24, 14))];
    y += 20;
    NSInteger native = [self.shown[@"nativeW"] integerValue];
    NSInteger current = fnkbmSavedWidth(self.shown);
    if (current < 0 || (native > 0 && current >= native)) current = 0;   // at or above native is native
    self.resolutionRows = [NSMutableArray array];
    for (NSArray *c in fnkbmResolutionChoices(self.shown)) {
        FnkbmRow *r = fnkbmChoiceRow(leftW - 12, c[0], c[1], [c[2] integerValue] == current);
        r.tag = [c[2] integerValue];
        [r addTarget:self action:@selector(fnkbmResolutionTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.resolutionRows addObject:r];
    }
    y += [self addGroupWithRows:self.resolutionRows at:CGPointMake(x, y) width:leftW rowHeight:34 dividers:NO];
    CGFloat leftBottom = y;

    // Right column: a switch for every group that is not always on.
    x = pad + leftW + gap; y = top;
    [self.body addSubview:fnkbmHeader(@"Graphics", CGRectMake(x + 12, y, rightW - 24, 14))];
    y += 20;
    self.hint = fnkbmLabel(@"", 11.5, UIFontWeightRegular, 0.66);
    self.hint.numberOfLines = 2;
    NSMutableArray *switches = [NSMutableArray array];
    __weak FnkbmGraphicsPanel *weakSelf = self;
    for (int i = 0; i < FNKBM_GFX_COUNT; i++) {
        if (kFnkbmGfx[i].always) continue;
        FnkbmRow *r = fnkbmSwitchRow(rightW - 12, i, self);
        NSString *detail = @(kFnkbmGfx[i].detail);
        r.onHover = ^{ weakSelf.hint.text = detail; };
        [switches addObject:r];
    }
    y += [self addGroupWithRows:switches at:CGPointMake(x, y) width:rightW rowHeight:40 dividers:YES] + 8;
    self.hint.frame = CGRectMake(x + 12, y, rightW - 24, 30);
    [self.body addSubview:self.hint];
    y += 30 + 16;

    // Colour blind mode: the same choices as Fortnite's own setting on PC, applied at once.
    [self.body addSubview:fnkbmHeader(@"Colour blind mode", CGRectMake(x + 12, y, rightW - 24, 14))];
    y += 20;
    NSInteger mode = fnkbmCBMode();
    NSArray *modes = @[@[@"Off", @""], @[@"Deuteranope", @"green weak"], @[@"Protanope", @"red weak"], @[@"Tritanope", @"blue weak"]];
    self.cbRows = [NSMutableArray array];
    for (NSUInteger i = 0; i < modes.count; i++) {
        FnkbmRow *r = fnkbmChoiceRow(rightW - 12, modes[i][0], modes[i][1], (NSInteger)i == mode);
        r.tag = i;
        [r addTarget:self action:@selector(fnkbmCBTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.cbRows addObject:r];
    }
    y += [self addGroupWithRows:self.cbRows at:CGPointMake(x, y) width:rightW rowHeight:34 dividers:NO] + 8;
    UIView *strength = [[UIView alloc] initWithFrame:CGRectMake(0, 0, rightW - 12, 40)];
    UILabel *sl = fnkbmLabel(@"Strength", 13, UIFontWeightSemibold, 1);
    sl.frame = CGRectMake(12, 0, 80, 40);
    self.cbValue = fnkbmLabel([NSString stringWithFormat:@"%ld", (long)fnkbmCBStrength()], 12, UIFontWeightRegular, 0.66);
    self.cbValue.textAlignment = NSTextAlignmentRight;
    self.cbValue.frame = CGRectMake(rightW - 12 - 12 - 24, 0, 24, 40);
    self.cbSlider = [[UISlider alloc] initWithFrame:CGRectMake(96, 0, rightW - 12 - 96 - 12 - 24 - 10, 40)];
    self.cbSlider.minimumValue = 0;
    self.cbSlider.maximumValue = 10;
    self.cbSlider.value = fnkbmCBStrength();
    self.cbSlider.accessibilityLabel = @"Colour blind strength";
    [self.cbSlider addTarget:self action:@selector(fnkbmCBStrengthChanged:) forControlEvents:UIControlEventValueChanged];
    self.cbSlider.enabled = mode != 0;
    [strength addSubview:sl]; [strength addSubview:self.cbSlider]; [strength addSubview:self.cbValue];
    y += [self addGroupWithRows:@[strength] at:CGPointMake(x, y) width:rightW rowHeight:40 dividers:NO];

    // Footer: the one rule that covers everything here, or what waits for a restart.
    y = MAX(leftBottom, y) + 16;
    self.restartIcon = [UIImageView new];
    self.restartIcon.contentMode = UIViewContentModeCenter;
    self.restartIcon.frame = CGRectMake(pad + 12, y, 16, 18);
    [self.body addSubview:self.restartIcon];
    self.restartNote = fnkbmLabel(@"", 12, UIFontWeightRegular, 0.7);
    self.restartNote.numberOfLines = 2;
    self.restartNote.frame = CGRectMake(pad + 34, y, cardW - pad * 2 - 34, 34);
    [self.body addSubview:self.restartNote];
    [self updateRestartNote];
    y += 34 + pad;

    CGAffineTransform t = self.card.transform;
    self.card.transform = CGAffineTransformIdentity;
    self.card.bounds = CGRectMake(0, 0, cardW, y);
    self.card.transform = t;
    self.body.frame = CGRectMake(0, 0, cardW, y);
    // Both tabs use the graphics layout's complete card size. Attach the child
    // after sizing the body; its default autoresizing used to stretch its frame
    // on first opening and shrink it on subsequent tab switches.
    if (self.selectedTab == FnPanelSettings) {
        for (UIView *view in self.body.subviews)
            view.hidden = view != title && view != close && view != tabs;
        self.settings = [popupViewController new];
        [self addChildViewController:self.settings];
        UIView *content = self.settings.view;
        content.autoresizingMask = UIViewAutoresizingNone;
        content.translatesAutoresizingMaskIntoConstraints = NO;
        [self.body addSubview:content];
        [NSLayoutConstraint activateConstraints:@[
            [content.leadingAnchor constraintEqualToAnchor:self.body.leadingAnchor constant:pad],
            [content.trailingAnchor constraintEqualToAnchor:self.body.trailingAnchor constant:-pad],
            [content.topAnchor constraintEqualToAnchor:self.body.topAnchor constant:top],
            [content.bottomAnchor constraintEqualToAnchor:self.body.bottomAnchor constant:-pad]
        ]];
        [self.settings didMoveToParentViewController:self];
    }
    fnApplyAccentColor(self.view);
    [self.body layoutIfNeeded];
    [self.view setNeedsLayout];
}
// The footer says which changed settings need Fortnite to be started again.
- (void)updateRestartNote {
    NSString *changed = fnkbmRestartNeeded();
    UIColor *c = changed ? [UIColor colorWithRed:1.0 green:0.80 blue:0.38 alpha:1] : [UIColor colorWithWhite:1 alpha:0.7];
    self.restartNote.text = changed
        ? [NSString stringWithFormat:@"Restart Fortnite to apply: %@. Colour blind mode changes at once.", changed]
        : @"Colour blind mode changes at once. Everything else applies the next time Fortnite starts.";
    self.restartNote.textColor = c;
    self.restartNote.font = [UIFont systemFontOfSize:12 weight:changed ? UIFontWeightSemibold : UIFontWeightRegular];
    self.restartIcon.image = [UIImage systemImageNamed:changed ? @"arrow.clockwise.circle.fill" : @"info.circle"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightRegular]];
    self.restartIcon.tintColor = c;
    CGRect f = self.restartNote.frame;   // first line level with the icon
    f.size.height = MIN(34, ceil([self.restartNote sizeThatFits:CGSizeMake(f.size.width, 100)].height));
    self.restartNote.frame = f;
    if (changed && ![changed isEqualToString:self.restartSaid]) {
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, self.restartNote.text);
        KLOG("panel: restart needed for %{public}@", changed);
    }
    self.restartSaid = changed;
}
// Adds a group with the rows stacked in it; returns its height.
- (CGFloat)addGroupWithRows:(NSArray *)rows at:(CGPoint)origin width:(CGFloat)width rowHeight:(CGFloat)rowH dividers:(BOOL)dividers {
    CGFloat step = dividers ? rowH : rowH + 2;
    CGFloat h = rows.count ? 12 + step * rows.count - (dividers ? 0 : 2) : 0;
    UIView *g = fnkbmGroup(CGRectMake(origin.x, origin.y, width, h));
    for (NSUInteger i = 0; i < rows.count; i++) {
        UIView *r = rows[i];
        r.frame = CGRectMake(6, 6 + step * i, width - 12, rowH);
        [g addSubview:r];
        if (dividers && i > 0) {
            UIView *line = [[UIView alloc] initWithFrame:CGRectMake(18, 6 + step * i, width - 36, 1.0 / 2)];
            line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
            line.userInteractionEnabled = NO;
            [g addSubview:line];
        }
    }
    [self.body addSubview:g];
    return h;
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize win = self.view.bounds.size, card = self.card.bounds.size;
    if (card.width <= 0 || card.height <= 0) return;
    CGFloat s = MIN(1, MIN((win.width - 48) / card.width, (win.height - 48) / card.height));
    self.card.transform = CGAffineTransformMakeScale(s, s);
    self.card.center = CGPointMake(win.width / 2, win.height / 2);
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self becomeFirstResponder];
    if (!self.animateIn) return;
    self.animateIn = NO;
    CGAffineTransform fit = self.card.transform;
    self.card.transform = CGAffineTransformScale(fit, 0.97, 0.97);
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.card.effect = self.cardEffect;
        self.card.transform = fit;
        self.body.alpha = 1;
        self.scrim.alpha = 1;
    } completion:nil];
}
- (void)tabChanged:(UISegmentedControl *)sender {
    self.selectedTab = sender.selectedSegmentIndex;
    [self rebuild];
}
- (BOOL)prefersPointerLocked { return NO; }
- (BOOL)canBecomeFirstResponder { return YES; }
// Esc for the times the key reaches UIKit (typing mode passes keys through).
- (NSArray<UIKeyCommand *> *)keyCommands {
    UIKeyCommand *esc = [UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:0 action:@selector(close)];
    esc.wantsPriorityOverSystemBehavior = YES;
    return @[esc];
}
- (BOOL)accessibilityPerformEscape { [self close]; return YES; }
- (void)close { fnkbmCloseGraphicsPanel(); }
- (void)fnkbmDisplayTapped:(FnkbmRow *)r {
    NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
    NSDictionary *d = fnkbmDisplayWithKey(self.displays, r.value);
    [u setObject:r.value ?: @"" forKey:FNKBM_DISPLAY_KEY];
    if (d) [u setObject:d[@"name"] forKey:FNKBM_DISPLAY_NAME_KEY];
    else [u removeObjectForKey:FNKBM_DISPLAY_NAME_KEY];
    KLOG("start display chosen: %{public}@ (next start)", d ? d[@"name"] : @"automatic");
    [self rebuild];
}
- (void)fnkbmResolutionTapped:(FnkbmRow *)r {
    NSInteger width = r.tag;
    [[NSUserDefaults standardUserDefaults] setInteger:width forKey:fnkbmWidthKey(self.shown)];
    for (FnkbmRow *o in self.resolutionRows) o.selected = (o == r);
    KLOG("resolution chosen for %{public}@: width %ld (0 = native, next start)", self.shown[@"name"], (long)width);
    [self updateRestartNote];
}
- (void)fnkbmCBTapped:(FnkbmRow *)r {
    [[NSUserDefaults standardUserDefaults] setInteger:r.tag forKey:FNKBM_CB_MODE_KEY];
    for (FnkbmRow *o in self.cbRows) o.selected = (o == r);
    self.cbSlider.enabled = r.tag != 0;
    fnkbmApplyColorFilter();
}
- (void)fnkbmCBStrengthChanged:(UISlider *)s {
    NSInteger v = lround(s.value);
    if (v == fnkbmCBStrength() && [[NSUserDefaults standardUserDefaults] objectForKey:FNKBM_CB_STRENGTH_KEY]) return;
    [[NSUserDefaults standardUserDefaults] setInteger:v forKey:FNKBM_CB_STRENGTH_KEY];
    self.cbValue.text = [NSString stringWithFormat:@"%ld", (long)v];
    fnkbmApplyColorFilter();
}
- (void)fnkbmRowTapped:(FnkbmRow *)r {
    [r.toggle setOn:!r.toggle.on animated:YES];   // setOn: sends no action
    [self fnkbmSwitched:r.toggle];
}
- (void)fnkbmSwitched:(UISwitch *)sw {
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:fnkbmGfxKey((int)sw.tag)];
    self.hint.text = @(kFnkbmGfx[sw.tag].detail);
    KLOG("graphics switch %{public}s = %d (next start)", kFnkbmGfx[sw.tag].ident, sw.on);
    [self updateRestartNote];
}
@end


static void fnkbmGfxPanelDisplaysChanged(void) {
    if (!isPopupVisible) return;
    FnkbmGraphicsPanel *panel = (FnkbmGraphicsPanel *)popupWindow.rootViewController;
    if ([panel isKindOfClass:FnkbmGraphicsPanel.class]) [panel rebuild];
}
// The picture size is fixed once the game has asked for the scale. After the window
// changed display, compare the frame layer with what the window now needs.
static void fnkbmCheckPictureFits(const char *why) {
    id layer = g_fnkbmLayer;
    fnkbmRefreshGameWindow();
    if (!layer || g_fnkbmAnswered <= 0 || g_fnkbmWinSize.width <= 0) { KLOG("picture check (%{public}s): nothing to compare yet", why); return; }
    CGSize size = ((CGSize (*)(id, SEL))objc_msgSend)(layer, NSSelectorFromString(@"drawableSize"));
    CGFloat want = round(MAX(g_fnkbmWinSize.width, g_fnkbmWinSize.height) * g_fnkbmAnswered), have = MAX(size.width, size.height);
    if (want > 0 && fabs(have - want) / want > 0.02)
        KLOG("picture check (%{public}s): frame layer is %.0f pixels wide, the window needs %.0f; restart Fortnite once to fit the picture", why, have, want);
    else
        KLOG("picture check (%{public}s): frame layer %.0f pixels wide fits the window", why, have);
}

%hook IOSAppDelegate

- (float)MobileContentScaleFactor {
    static int said = 0;
    float game = %orig;
    CGSize pts = fnkbmWindowPoints();
    CGFloat w = MAX(pts.width, pts.height);
    NSDictionary *d = fnkbmPlayDisplay(fnkbmDisplays());
    NSInteger want = fnkbmSavedWidth(d);
    float nativeScale = 0, mine = game;
    if (d) {
        // A window that is not yet on the display it was moved to is measured by that display.
        if ([d[@"id"] unsignedIntValue] != g_fnkbmGameDisplay || w <= 0) w = [d[@"ptsW"] doubleValue];
        nativeScale = (float)([d[@"nativeW"] doubleValue] / [d[@"ptsW"] doubleValue]);
    }
    if (nativeScale >= 0.5f && nativeScale <= 3.0f) {
        // Nothing chosen for this display: its own native resolution, whatever monitor it is.
        if (want > 0 && w > 0) mine = MIN((float)(want / w), nativeScale);
        else mine = nativeScale;
    } else if (want > 0 && w > 0) {
        // No display data: the game's own scale stands in for native.
        mine = game > 0 ? MIN((float)(want / w), game) : (float)(want / w);
    }
    BOOL first = (g_fnkbmGameScale == 0);
    g_fnkbmGameScale = game; g_fnkbmWindowPts = pts; g_fnkbmAnswered = mine;
    if (first) dispatch_async(dispatch_get_main_queue(), ^{ [[UIMenuSystem mainSystem] setNeedsRebuild]; });
    if (said < 4) {
        said++;
        KLOG("content scale asked: game says %.3f, window %.0fx%.0f points, display %{public}@ (%.0f points wide, native scale %.3f), chosen width %ld, tweak answers %.3f",
             game, pts.width, pts.height, d ? d[@"name"] : @"unknown", w, nativeScale, (long)want, mine);
    }
    return mine;
}

- (void)buildMenuWithBuilder:(id<UIMenuBuilder>)builder {
    %orig;
    if (builder.system != [UIMenuSystem mainSystem]) return;
    UIAction *open = [UIAction actionWithTitle:@"Graphics Panel" image:nil identifier:nil handler:^(UIAction *x) { fnShowPanel(FnPanelGraphics); }];
    UIAction *settings = [UIAction actionWithTitle:@"Settings" image:nil identifier:nil handler:^(UIAction *x) { fnShowPanel(FnPanelSettings); }];
    if ([builder menuForIdentifier:@"fnkbm.menu"]) [builder removeMenuForIdentifier:@"fnkbm.menu"];
    UIMenu *menu = [UIMenu menuWithTitle:@"FnMac" image:nil identifier:@"fnkbm.menu" options:0 children:@[open, settings]];
    if ([builder menuForIdentifier:UIMenuView]) [builder insertSiblingMenu:menu afterMenuForIdentifier:UIMenuView];
    else [builder insertChildMenu:menu atEndOfMenuForIdentifier:UIMenuRoot];
    KLOG("FnMac menu built");
}

%end

UIViewController *fnCreateSettingsPanel(FnPanelTab tab) {
    FnkbmGraphicsPanel *panel = [FnkbmGraphicsPanel new];
    panel.selectedTab = tab;
    return panel;
}
FnPanelTab fnCurrentPanelTab(void) {
    FnkbmGraphicsPanel *panel = (FnkbmGraphicsPanel *)popupWindow.rootViewController;
    return [panel isKindOfClass:FnkbmGraphicsPanel.class] ? (FnPanelTab)panel.selectedTab : FnPanelSettings;
}
void fnSelectPanelTab(FnPanelTab tab) {
    FnkbmGraphicsPanel *panel = (FnkbmGraphicsPanel *)popupWindow.rootViewController;
    if ([panel isKindOfClass:FnkbmGraphicsPanel.class]) { panel.selectedTab = tab; [panel rebuild]; }
}
void fnGraphicsFrameLayer(id layer) {
    if (g_fnkbmLayer == layer) return;
    g_fnkbmLayer = layer;
    dispatch_async(dispatch_get_main_queue(), ^{ fnkbmApplyColorFilter(); });
}
void fnGraphicsCursorIntoGame(void) {
    fnkbmRefreshGameWindow();
    fnkbmCursorIntoGame("captured");
}
void fnInstallGraphics(void) {
    fnInstallFrameRecovery();
    fnkbmInstallDisplayWatch();
    fnkbmRefreshGameWindow();
    fnkbmPlaceOnStartDisplay(fnkbmGameNSWindow(), "runtime start");
    (void)fnkbmRestartNeeded();
    [[UIMenuSystem mainSystem] setNeedsRebuild];
}
%hook NSWindow
- (void)makeKeyAndOrderFront:(id)sender {
    if ([NSThread isMainThread]) fnkbmPlaceOnStartDisplay(self, "before show");
    %orig;
}
%end
%ctor {
    fnkbmGfxLoad();
    fnkbmAllowHighResDownload();
    struct rebinding bindings[] = {{"access", (void *)hooked_access, (void **)&orig_access}};
    rebind_symbols(bindings, 1);
    fnkbmInstallSharp();
}

float fnGraphicsMenuWheelPlace(void) {
    uint32_t bits = 0;
    fnkbmRefreshGameWindow();
    id layer = g_fnkbmLayer;
    CGSize size = layer ? ((CGSize (*)(id, SEL))objc_msgSend)(layer, NSSelectorFromString(@"drawableSize")) : CGSizeZero;
    CGPoint c;
    if (g_fnkbmWinSize.width > 0 && g_fnkbmWinSize.height > 0 && size.width >= 1 && size.height >= 1 && fnkbmCursorLocation(&c)) {
        double fx = fmin(fmax((c.x - g_fnkbmWinOrigin.x) / g_fnkbmWinSize.width, 0.0), 1.0);
        double fy = fmin(fmax((c.y - g_fnkbmWinOrigin.y) / g_fnkbmWinSize.height, 0.0), 1.0);
        long x = lround(fx * (size.width - 1)), y = lround(fy * (size.height - 1));
        if (x < 16384 && y < 16384) {
            bits = 0x10000000u | ((uint32_t)x << 14) | (uint32_t)y;

        }
    }
    float f;
    memcpy(&f, &bits, sizeof f);
    return f;
}

// v3 compositor recovery. Count real display ticks separately from boost ticks.
static _Atomic long g_dgNdIn = 0, fnRealTicks = 0, fnWaitTicks = 0;
static _Atomic uint64_t g_fnkbmPauseUntil = 0;
static CFTimeInterval fnPlayResumedAt;
static NSMutableArray *g_fnkbmHiddenOver = nil;   // windows hidden by the tweak (main thread)

static void fnkbmRestoreOver(const char *why) {
    if (!g_fnkbmHiddenOver.count) return;
    for (UIWindow *w in g_fnkbmHiddenOver) w.hidden = NO;
    KLOG("blended frames: %lu window(s) over the game shown again (%{public}s)", (unsigned long)g_fnkbmHiddenOver.count, why);
    [g_fnkbmHiddenOver removeAllObjects];
}
static BOOL fnkbmHoldsFrames(UIWindow *w) {
    for (CALayer *p = (CALayer *)g_fnkbmLayer; p; p = p.superlayer) if (p == w.layer) return YES;
    return NO;
}

static void fnkbmLogViews(UIView *v, int depth, int *left) {
    for (UIView *s in v.subviews) {
        if (*left <= 0) return;
        if (s.hidden || s.alpha <= 0.01 || s.bounds.size.width < 1 || s.bounds.size.height < 1) continue;
        (*left)--;
        KLOG("  view %{public}s depth %d at %.0f,%.0f %.0fx%.0f alpha %.2f, layer %{public}s%{public}s", object_getClassName(s), depth, s.frame.origin.x,
             s.frame.origin.y, s.bounds.size.width, s.bounds.size.height, s.alpha, object_getClassName(s.layer), s.layer.contents ? ", has contents" : "");
        fnkbmLogViews(s, depth + 1, left);
    }
}
// This app's visible windows; for the ones over the game, their visible views.
static void fnkbmLogAppWindows(const char *tag) {
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w.hidden || w.alpha <= 0) continue;
            BOOL holds = fnkbmHoldsFrames(w);
            KLOG("%{public}s: app window %{public}s level %.0f alpha %.2f, %lu subviews%{public}s", tag, object_getClassName(w), (double)w.windowLevel,
                 w.alpha, (unsigned long)w.subviews.count, holds ? " (holds the game frames)" : "");
            if (!holds) { int left = 20; fnkbmLogViews(w, 0, &left); }
        }
    }
}
// Hides cands[i] for 1.5 s and counts frames; keeps it hidden if that helped.
static void fnkbmTryHiding(NSArray *cands, NSUInteger i, double hz, int n) {
    if (!fnUnlockFrameRate || !fnMouseInputActive || isPopupVisible) return;
    if (i >= cands.count) { KLOG("blended frames %d: hiding this app's windows did not help", n); return; }
    UIWindow *w = cands[i];
    if (w.hidden || !isMouseLocked || !fnMouseInputActive) { fnkbmTryHiding(cands, i + 1, hz, n); return; }
    w.hidden = YES;
    long f0 = atomic_load(&g_dgNdIn);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        double fps = (double)(atomic_load(&g_dgNdIn) - f0) / 1.5;
        if (fps > hz * 1.3 && isMouseLocked && fnMouseInputActive && !isPopupVisible && fnUnlockFrameRate) {
            if (!g_fnkbmHiddenOver) g_fnkbmHiddenOver = [NSMutableArray array];
            [g_fnkbmHiddenOver addObject:w];
            KLOG("blended frames %d: with %{public}s hidden: %.0f fps; kept hidden until the cursor is freed", n, object_getClassName(w), fps);
        } else {
            w.hidden = NO;
            KLOG("blended frames %d: with %{public}s hidden: %.0f fps; shown again", n, object_getClassName(w), fps);
            fnkbmTryHiding(cands, i + 1, hz, n);
        }
    });
}
// Seconds between two pauses. A pause that brings the frame rate back resets it to 3.
// If no pause up to 500 ms helps, it becomes 60, so a scene that really runs at the
// refresh rate is not paused again and again. A focus return or a cursor lock after
// the last episode ends that wait: in the 13:48 run a failed episode (a notification
// banner was over the game) held off the next one for 25 s after the player came back.
static CFTimeInterval g_fnkbmBlendGap = 3.0;
static CFTimeInterval g_fnkbmBlendLast = 0;   // when the last episode began (main thread)
static double g_fnkbmPauseMs = 80.0;   // the pause that worked last time
static BOOL g_fnkbmPausing = NO;        // a pause and its count are under way (main thread)
// Holds the next frame for ms, then counts frames for 0.6 s. If that did not bring the
// frame rate back, the pause is doubled (up to 500 ms) and tried again at once.
static void fnkbmPauseTry(int n, double hz, double ms) {
    if (!fnUnlockFrameRate || !fnMouseInputActive || isPopupVisible) { g_fnkbmPausing = NO; return; }
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    atomic_store(&g_fnkbmPauseUntil, mach_absolute_time() + (uint64_t)(ms * 1e6 * tb.denom / tb.numer));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((ms + 100.0) * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        long f0 = atomic_load(&g_dgNdIn);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (!fnUnlockFrameRate || !fnMouseInputActive || isPopupVisible) { g_fnkbmPausing = NO; return; }
            double after = (double)(atomic_load(&g_dgNdIn) - f0) / 0.6;
            BOOL helped = after > hz * 1.3;
            KLOG("blended frames %d: after a %.0f ms pause in frames: %.0f fps%{public}s", n, ms, after, helped ? " (direct again)" : "");
            if (helped) { g_fnkbmPauseMs = ms; g_fnkbmBlendGap = 3.0; g_fnkbmPausing = NO; return; }
            if (ms < 500.0) { fnkbmPauseTry(n, hz, MIN(ms * 2.0, 500.0)); return; }
            g_fnkbmBlendGap = 60.0;
            g_fnkbmPausing = NO;
            if (!isMouseLocked) return;   // menus: Epic's pages and text input may be in use
            NSMutableArray *cands = [NSMutableArray array];
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)sc).windows)
                    if (!w.hidden && w != popupWindow && !w.isKeyWindow && !fnkbmHoldsFrames(w) &&
                        ([NSStringFromClass(w.class) containsString:@"EOSOverlay"] || [NSStringFromClass(w.class) containsString:@"UITextEffects"])) [cands addObject:w];   // the tweak's panels are closed (hidden) here
            }
            fnkbmTryHiding(cands, 0, hz, n);
        });
    });
}
static void fnkbmFramesBlended(double fps, double hz, double waitMs) {
    static int tries = 0;
    CFTimeInterval now = CACurrentMediaTime();
    BOOL resumed = fnPlayResumedAt > g_fnkbmBlendLast;
    if (g_fnkbmPausing || (now - g_fnkbmBlendLast < g_fnkbmBlendGap && !resumed)) return;
    g_fnkbmBlendLast = now;
    int n = ++tries;

    BOOL say = n <= 3;   // the window survey is logged the first three times only, to keep the log small
    KLOG("blended frames %d: %.0f fps at a %.0f Hz refresh, %.1f ms wait for each drawable, cursor locked=%d", n, fps, hz, waitMs, isMouseLocked);
    int others = 0;
    {
    fnkbmRefreshGameWindow();
    CGRect game = CGRectMake(g_fnkbmWinOrigin.x, g_fnkbmWinOrigin.y, g_fnkbmWinSize.width, g_fnkbmWinSize.height);
    // Other apps' windows that overlap the game, front to back, down to the game's own.
    static CFArrayRef (*windowList)(uint32_t, uint32_t) = NULL;
    if (!windowList) windowList = (CFArrayRef (*)(uint32_t, uint32_t))dlsym(RTLD_DEFAULT, "CGWindowListCopyWindowInfo");
    NSArray *wins = windowList ? CFBridgingRelease(windowList(1 /* on screen only */, 0)) : nil;
    for (NSDictionary *w in wins) {
        NSDictionary *b = w[@"kCGWindowBounds"];
        CGRect r = CGRectMake([b[@"X"] doubleValue], [b[@"Y"] doubleValue], [b[@"Width"] doubleValue], [b[@"Height"] doubleValue]);
        if (!CGRectIntersectsRect(r, game)) continue;
        BOOL mine = [w[@"kCGWindowOwnerPID"] intValue] == getpid();
        if (mine && r.size.width >= game.size.width - 1 && r.size.height >= game.size.height - 1) break;   // the game: the rest are behind it
        if (!mine) others++;
        if (say) KLOG("blended frames %d: other window over the game: %{public}@, level %d, alpha %.2f, at %.0f,%.0f %.0fx%.0f", n, w[@"kCGWindowOwnerName"],
             [w[@"kCGWindowLayer"] intValue], [w[@"kCGWindowAlpha"] doubleValue], r.origin.x, r.origin.y, r.size.width, r.size.height);
    }
    if (say) fnkbmLogAppWindows("blended frames");
    }
    // Another app's window over the game (in the 13:48 run a notification banner,
    // "Notification Centre" at level 23): a pause in frames cannot help while it is
    // there, and four failed pauses cost a second of held frames. Look again in 2 s.
    if (others) {
        g_fnkbmBlendGap = 2.0;
        KLOG("blended frames %d: %d other app window(s) over the game; no pause, looking again in 2 s", n, others);
        return;
    }
    // In the 09:09 run frames went direct again right after the game presented
    // nothing for 2 s (a loading step). So first: no new frame for 0.5 s, then count.
    // In the 13:03 run this ended all three episodes (125, 144, 150 fps after it).
    // A 0.5 s pause was a visible stutter, so the shortest pause that worked last time
    // is tried first (80 ms at the start: three queued frames last 50 ms at 60 Hz).
    g_fnkbmPausing = YES;
    fnkbmPauseTry(n, hz, g_fnkbmPauseMs);
}

uint64_t fnGraphicsBeginFrame(void) {
    uint64_t until = atomic_exchange(&g_fnkbmPauseUntil, 0);
    if (until > mach_absolute_time()) mach_wait_until(until);
    return mach_absolute_time();
}
void fnGraphicsEndFrame(uint64_t start) {
    atomic_fetch_add(&g_dgNdIn, 1);
    atomic_fetch_add(&fnWaitTicks, (long)(mach_absolute_time() - start));
}
void fnGraphicsPacerTick(void) { atomic_fetch_add(&fnRealTicks, 1); }
static void fnInstallFrameRecovery(void) {
    static dispatch_source_t timer;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC / 2, NSEC_PER_SEC / 50);
    __block long lastFrames = 0, lastReal = 0, lastWait = 0;
    __block BOOL wasPlaying = NO;
    __block int hits = 0;
    dispatch_source_set_event_handler(timer, ^{
        BOOL playing = fnMouseInputActive && isMouseLocked && !isPopupVisible;
        if (playing && !wasPlaying) fnPlayResumedAt = CACurrentMediaTime();
        wasPlaying = playing;
        if (!playing || !fnUnlockFrameRate) fnkbmRestoreOver("panel, focus or cursor changed");
        long frames = atomic_load(&g_dgNdIn), ticks = atomic_load(&fnRealTicks), wait = atomic_load(&fnWaitTicks);
        double count = frames - lastFrames, fps = count * 2, hz = (ticks - lastReal) * 2;
        mach_timebase_info_data_t tb; mach_timebase_info(&tb);
        double waitMs = count > 0 ? (double)(wait - lastWait) * tb.numer / tb.denom / 1e6 / count : 0;
        lastFrames = frames; lastReal = ticks; lastWait = wait;
        double limit = fnUserFrameLimit;
        BOOL blended = fnUnlockFrameRate && playing && hz >= 30 && fabs(fps - hz) <= 2 && waitMs >= 600 / hz
                       && (limit <= 0 || limit > hz * 1.2);
        hits = blended ? hits + 1 : 0;
        double since = CACurrentMediaTime() - fnPlayResumedAt;
        int need = since >= 0.5 && since < 5 ? 1 : 2;
        if (hits >= need) { hits = 0; fnkbmFramesBlended(fps, hz, waitMs); }
    });
    dispatch_resume(timer);
}
