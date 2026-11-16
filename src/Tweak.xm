#import "./views/popupViewController.h"
#import "./views/welcomeViewController.h"
#import "./globals.h"
#import "./FnOverlayWindow.h"
#import "./PerformanceGuard.h"
#import <pthread.h>

#import "../lib/fishhook.h"
#import "./ue_reflection.h"
#import <sys/sysctl.h>
#import <sys/resource.h>

#import <GameController/GameController.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/thread_policy.h>
#import <pthread.h>
#import <os/log.h>
#import <notify.h>
#import <sys/stat.h>
#import <errno.h>
#import "./fnkbm_logscan.h"

// FnKbm diagnostics: public log lines readable with `log show`/`log stream`.
#define KLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[FnKbm] " fmt, ##__VA_ARGS__)

#ifdef FNKBM_DEBUG
// Test hooks: the wrapped handlers the game registered, so input can be
// injected from outside (darwin notification "fnkbm.dbg") for testing.
static GCKeyboardValueChangedHandler g_dbgKbWrapper = nil;
static GCMouseMoved g_dbgMouseWrapper = nil;
static GCControllerButtonValueChangedHandler g_dbgBtnPressed[3] = {nil, nil, nil};
static GCControllerButtonValueChangedHandler g_dbgBtnValue[3] = {nil, nil, nil};
static __unsafe_unretained GCControllerButtonInput *g_dbgBtn[3] = {nil, nil, nil};
#endif
static int fnkbmMouseButtonIndex(GCControllerButtonInput *btn);
static void _sendDualKeyEvent(GCKeyCode kc, BOOL pressed);
#import <mach-o/dyld.h>

// ── Bound keys, translated in place ─────────────────────────────────────
// A bound key is not swallowed and re-sent. The game's own key event goes
// through untouched and only the key code it reads is changed. That adds no
// delay, and a release can never be lost because it is the same event pair.
static BOOL g_fnkbmKeysInProcess = NO;      // the game's key methods are hooked
static BOOL g_fnkbmModsInProcess = NO;      // modifier keys were seen arriving the same way
static uint16_t g_fnkbmXlat[512] = {0};     // held key -> key the game sees (0 = itself)
static BOOL g_fnkbmDropped[512] = {NO};     // held key hidden from the game
static BOOL g_fnkbmSynthHeld[512] = {NO};   // key injected by the tweak, never translated
static uint16_t g_fnkbmKeyAsButton[512] = {0}; // held key that is pressing a mouse button
#define FNKBM_CMD_MASK 0x00100000ULL
static _Atomic bool g_fnkbmRealActive = true;   // the app really is in front (not what the game is told)
static BOOL g_fnkbmMenuScroll = NO;             // a wheel step is being passed to the game while the cursor is free

// The handlers the game registered for the real mouse buttons. A bind that
// targets a mouse button (reset edit on a key, for example) presses the
// button through these, so the game sees a genuine mouse button.
static GCControllerButtonValueChangedHandler g_fnkbmGameBtnHandler[3] = {nil, nil, nil};
static __unsafe_unretained GCControllerButtonInput *g_fnkbmGameBtn[3] = {nil, nil, nil};
static BOOL g_fnkbmGameBtnDown[3] = {NO, NO, NO};
static BOOL fnkbmGameMouseButton(int code, BOOL pressed) {
    int i = code == MOUSE_BUTTON_LEFT ? 0 : code == MOUSE_BUTTON_RIGHT ? 1 : code == MOUSE_BUTTON_MIDDLE ? 2 : -1;
    if (i < 0 || !g_fnkbmGameBtnHandler[i]) return NO;
    if (pressed == g_fnkbmGameBtnDown[i]) return YES;
    g_fnkbmGameBtnDown[i] = pressed;
    if (i == 1) rightButtonIsPressed = pressed;
    KLOG("bind pressed game mouse button %d: %d", i, pressed);
    g_fnkbmGameBtnHandler[i](g_fnkbmGameBtn[i], pressed ? 1.0f : 0.0f, pressed);
    return YES;
}

static BOOL fnkbmRemapActive(void) {
    return isMouseLocked && !isTypingModeEnabled && !isPopupVisible && keyCaptureCallback == nil;
}
// What a key is bound to: 0 nothing, -1 hidden from the game, else the key the game should see.
static long fnkbmKeyTarget(long code) {
    if (code <= 0 || code >= 512) return 0;
    GCKeyCode c = keyRemapArray[code];
    if (c == (GCKeyCode)-1) return -1;
    if (c != 0) return (long)c;
    GCKeyCode f = fortniteRemapArray[code];
    if (f != 0) return (long)f;
    if (fortniteBlockedDefaults[code] != 0) return -1;
    return 0;
}
// A key with no separate release (Caps Lock): press the bound key briefly.
static void fnkbmTapKey(GCKeyCode target) {
    KLOG("tap key %ld", (long)target);
    _sendDualKeyEvent(target, YES);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        _sendDualKeyEvent(target, NO);
    });
}

// The bind dialog waits for a key or a mouse button. Mouse buttons are taken
// from GameController here, which sees every press. Left click is left alone
// because it operates the dialog.
static BOOL fnkbmCaptureMouseButton(int code) {
    if (!isPopupVisible || code == MOUSE_BUTTON_LEFT) return NO;
    void (^mb)(int) = mouseButtonCaptureCallback;
    void (^kc)(GCKeyCode) = keyCaptureCallback;
    if (!mb && !kc) return NO;
    mouseButtonCaptureCallback = nil;
    keyCaptureCallback = nil;
    KLOG("bind capture: mouse button code=%d", code);
    if (mb) mb(code); else kc((GCKeyCode)code);
    return YES;
}

// Key a mouse button is bound to (0 if none). Same order the tweak uses elsewhere.
static GCKeyCode fnkbmMouseRemapTarget(int code) {
    GCKeyCode t = 0;
    if (code >= 0 && code < 10200) t = fortniteRemapArray[code];
    int idx = code - MOUSE_BUTTON_MIDDLE;
    if (t == 0 && idx >= 0 && idx < MOUSE_REMAP_COUNT) {
        t = mouseButtonRemapArray[idx];
        if (t == 0) t = mouseFortniteArray[idx];
    }
    // Remaps from a config file are stored folded into the key table.
    if (t == 0 && code >= 10000 && code < 10200) t = keyRemapArray[code % 512];
    return (t == (GCKeyCode)-1) ? 0 : t;
}

// Native mode handling of one mouse button event from GameController.
// Returns YES when the event should go on to the game's own handler.
// - cursor free (menus): presses are dropped, the click is a screen touch.
// - bound button: the bound key is pressed/released instead.
// - otherwise: the game gets the real mouse button.
// A release always follows whatever its press did, so nothing sticks.
#define FNKBM_BTN_SLOTS 64
static BOOL g_fnkbmFwdPressed[FNKBM_BTN_SLOTS] = {NO};
static BOOL g_fnkbmFwdValue[FNKBM_BTN_SLOTS] = {NO};
static GCKeyCode g_fnkbmKeyDown[FNKBM_BTN_SLOTS] = {0};
static BOOL fnkbmNativeButton(int code, BOOL pressed, BOOL *fwd, BOOL sendKeys) {
    int slot = code - MOUSE_BUTTON_MIDDLE;
    if (slot < 0 || slot >= FNKBM_BTN_SLOTS) return YES;
    BOOL native = isMouseLocked && isGCMouseDirectActive && !isPopupVisible;
    // Cursor free, tweak panel closed: the left button stays a screen touch, but
    // the other buttons go to the game, so its own "press a key" prompt can see
    // a right click, a wheel click, or the key a side button is bound to.
    BOOL menu = !native && !isPopupVisible && NATIVE_ALWAYS_ON && !isControllerModeEnabled && code != MOUSE_BUTTON_LEFT;
    if (pressed) {
        if (!native && !menu) return NO;
        GCKeyCode target = fnkbmMouseRemapTarget(code);
        // The game registers its own handlers for the first two extra mouse
        // buttons (it binds them as thumb buttons). They always go to the game;
        // a bind for them saved in the tweak panel is ignored.
        if (code == MOUSE_BUTTON_AUX_BASE || code == MOUSE_BUTTON_AUX_BASE + 1) target = 0;
        if (target != 0) {
            if (sendKeys && g_fnkbmKeyDown[slot] == 0) {
                g_fnkbmKeyDown[slot] = target;
                KLOG("mouse button code=%d bound to key %ld: key down", code, (long)target);
                _sendDualKeyEvent(target, YES);
            }
            return NO;
        }
        fwd[slot] = YES;
        if (code == MOUSE_BUTTON_RIGHT) rightButtonIsPressed = YES;   // aiming multiplier
        return YES;
    }
    if (sendKeys && g_fnkbmKeyDown[slot] != 0) {
        GCKeyCode target = g_fnkbmKeyDown[slot];
        g_fnkbmKeyDown[slot] = 0;
        KLOG("mouse button code=%d bound to key %ld: key up", code, (long)target);
        _sendDualKeyEvent(target, NO);
        return NO;
    }
    if (!fwd[slot]) return NO;
    fwd[slot] = NO;
    if (code == MOUSE_BUTTON_RIGHT) rightButtonIsPressed = NO;
    return YES;
}

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

// Forward declarations for controller helpers
static void _updateVStick(BOOL isRight, BOOL isSync);
static void resetControllerState();
static void dispatchControllerButton(NSInteger idx, BOOL pressed, BOOL isSync);
static void _setVirtualFaceButton(NSString *element, BOOL pressed);
static void _setVirtualNamedButton(SEL propSel, BOOL pressed);

static char kButtonCodeKey;
static UIWindow *stealthCompositorWindow = nil;
static id g_backgroundActivityToken = nil;


static void updateGCMouseDirectState(int code, BOOL pressed) {
    if (code != 0 && (GCKeyCode)code == GCMOUSE_DIRECT_KEY) {
        // Toggle on key-down only. The same physical press can reach this
        // function from more than one input path (GameController, NSEvent,
        // CGEvent) and from key auto-repeat, so a held flag makes one press
        // count once; key-up only clears the flag.
        static BOOL directKeyHeld = NO;
        if (!pressed) { directKeyHeld = NO; return; }
        if (directKeyHeld) return;
        directKeyHeld = YES;
        isGCMouseDirectActive = !isGCMouseDirectActive;
        KLOG("direct key toggled: direct=%d", isGCMouseDirectActive);
        // If we just deactivated, clear accumulators and virtual sticks
        if (!isGCMouseDirectActive) {
            atomic_store(&mouseAccumBufferX[0], 0);
            atomic_store(&mouseAccumBufferX[1], 0);
            atomic_store(&mouseAccumBufferY[0], 0);
            atomic_store(&mouseAccumBufferY[1], 0);
            resetControllerState();
        }
    }
}

// elevateThreadToRealTime moved to globals.h/m for Level 11 Sync

#ifndef kCGHIDEventTap
#define kCGHIDEventTap 0
#endif

typedef uint64_t CGEventFlags;
typedef struct __CGEvent *CGEventRef;

static CGEventRef (*_CGEventCreateKeyboardEvent)(void *source, uint16_t virtualKey, bool keyDown) = NULL;
static void (*_CGEventSetFlags)(CGEventRef event, CGEventFlags flags) = NULL;
static CGEventFlags (*_CGEventGetFlags)(CGEventRef event) = NULL;
static void (*_CGEventPost)(int tap, CGEventRef event) = NULL;
static void (*_CGEventSetType)(CGEventRef event, uint32_t type) = NULL;
static CGEventRef (*_CGEventCreateMouseEvent)(void *source, uint32_t type, CGPoint mouseCursorPosition, int mouseButton) = NULL;
typedef uint64_t CGEventTimestamp;
static CGEventTimestamp (*_CGEventGetTimestamp)(CGEventRef event) = NULL;

typedef uint16_t UniChar;
typedef unsigned long UniCharCount;
static void (*_CGEventKeyboardGetUnicodeString)(CGEventRef event, UniCharCount maxStringLength, UniCharCount *actualStringLength, UniChar unicodeString[]) = NULL;
static void (*_CGEventKeyboardSetUnicodeString)(CGEventRef event, UniCharCount stringLength, const UniChar unicodeString[]) = NULL;

#define kCGEventFlagMaskAlphaShift 0x00010000
#define kCGEventFlagMaskShift      0x00020000
#define kCGMouseEventDeltaX        4
#define kCGMouseEventDeltaY        5

static double (*_CGEventGetDoubleValueField)(CGEventRef event, int field) = NULL;
static void (*_CGEventSetDoubleValueField)(CGEventRef event, int field, double value) = NULL;
static int64_t (*_CGEventGetIntegerValueField)(CGEventRef event, int field) = NULL;
static void (*_CGEventSetIntegerValueField)(CGEventRef event, int field, int64_t value) = NULL;

// CGEventTap Types and Prototypes
typedef uint32_t CGEventTapProxy;
typedef uint32_t CGEventType; 
typedef int CGEventTapPlacement;
typedef int CGEventTapOptions;
typedef CGEventRef (*CGEventTapCallBack)(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon);

static CFMachPortRef (*_CGEventTapCreate)(int tap, CGEventTapPlacement place, CGEventTapOptions options, uint64_t eventsOfInterest, CGEventTapCallBack callback, void *refcon) = NULL;
static void (*_CGEventTapEnable)(CFMachPortRef tap, bool enable) = NULL;

extern "C" {
    #define kCGEventMouseMoved 5
    #define kCGEventLeftMouseDown 1
    #define kCGEventLeftMouseUp 2
    #define kCGEventLeftMouseDragged 6
    #define kCGEventRightMouseDown 3
    #define kCGEventRightMouseUp 4
    #define kCGEventRightMouseDragged 7
    #define kCGEventOtherMouseDown 25
    #define kCGEventOtherMouseUp 26
    #define kCGEventOtherMouseDragged 8
    #define kCGMouseEventButtonNumber 3
    #define kCGHeadInsertEventTap 0
    #define kCGEventTapOptionDefault 0
}

static CGEventRef mouseButtonTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon);
static BOOL _isMouseButtonSuppressed(int code);

#define kCGEventSourceUserData 42

@interface UITouch (Private)
- (void)_setType:(int)type;
- (void)setType:(int)type;
- (void)_setPathIndex:(int)index;
- (void)_setPathIdentity:(int)identity;
- (void)setWindow:(UIWindow *)window;
- (void)_setLocationInWindow:(CGPoint)location resetPrevious:(BOOL)reset;
- (void)setView:(UIView *)view;
- (void)setTapCount:(NSUInteger)count;
- (void)setIsTap:(BOOL)isTap;
- (void)_setIsFirstTouchForView:(BOOL)firstTouch;
- (void)setTimestamp:(NSTimeInterval)timestamp;
- (void)setPhase:(UITouchPhase)phase;
@end

@interface UITouchesEvent : UIEvent
- (id)_init;
- (void)_addTouch:(UITouch *)touch forDelayedDelivery:(BOOL)delayedDelivery;
@property (nonatomic, assign) int singleAllowableExternalTouchPathIndex;
@end

// Pre-calculated sensitivity multipliers (computed once at startup via recalculateSensitivities())
@interface GCPhysicalInputProfile (FnTweak)
- (id)elementForName:(NSString *)name;
@end

// Formula: (BASE_XY_SENSITIVITY / 100) × (Look% / 100) × MACOS_TO_PC_SCALE

// macOS VK → GCKeyCode map (USB HID)
static const uint16_t nsVKToGC[128] = {
    [0]=4,  [1]=22, [2]=7,  [3]=9,  [4]=11, [5]=10, [6]=29, [7]=27,
    [8]=6,  [9]=25, [10]=0, [11]=5, [12]=20,[13]=26,[14]=8, [15]=21,
    [16]=28,[17]=23,
    [18]=30,[19]=31,[20]=32,[21]=33,[22]=35,[23]=34,
    [24]=46,[25]=38,[26]=36,[27]=45,[28]=37,[29]=39,
    [30]=48,[31]=18,[32]=24,[33]=47,[34]=12,[35]=19,
    [36]=40,[37]=15,[38]=13,[39]=52,[40]=14,[41]=51,
    [42]=49,[43]=54,[44]=56,[45]=17,[46]=16,[47]=55,
    [48]=43,[49]=44,[50]=53,[51]=42,[52]=0, [53]=41,
    [54]=231,[55]=227,[56]=225,[57]=57,
    [58]=226,[59]=224,[60]=229,[61]=230,[62]=228,[63]=0,[64]=0,
    [65]=99,[66]=0, [67]=85,[69]=83,[70]=0, [71]=71,[72]=0,
    [75]=84,[76]=88,[77]=0, [78]=87,[79]=79,[80]=80,[81]=81,
    [82]=82,[83]=98,[84]=89,[85]=90,[86]=91,[87]=92,[88]=93,
    [89]=94,[90]=95,[91]=96,[92]=97,[96]=62,[97]=63,[98]=64,
    [99]=65,[100]=66,[101]=67,[102]=68,[103]=69,[104]=70,
    [105]=71,[106]=77,[107]=86,[108]=0, [109]=78,[110]=76,
    [111]=69,[112]=0, [113]=0, [114]=73,[115]=74,[116]=75,
    [117]=76,[118]=61,[119]=77,[120]=59,[121]=78,[122]=58,
    [123]=80,[124]=79,[125]=81,[126]=82,
};
static uint16_t gcToNSVK[256];
static CFMachPortRef fnm_eventTap = NULL;

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

// --------- MOUSE ADS STATE ---------
// g_originalMouseHandler moved to globals.h/m for Level 9 Pulse-Injection
// mouseAccum, wasADS, wasADSInitialized moved to globals.h/m

// --------- FORWARD DECLARATIONS ---------
// Needed by the NSEvent kbMonitor block inside %ctor, which compiles before
// the definitions that appear later in the file.
static BOOL isTriggerHeld        = NO;
static BOOL remappedKeysState[512] = {NO};
static BOOL vctrlKeyState[10240] = {NO};
static BOOL remappedMouseButtonsState[MOUSE_REMAP_COUNT] = {NO};
static void createPopup(void);
static void updateMouseLock(BOOL value, CGPoint warpPos);


@interface FnInputPulse : NSObject
- (void)onDisplayTick:(CADisplayLink *)sender;
@end

static BOOL wasLocked = YES;
static id g_virtualGamepad = nil; // Cached for zero-latency access
static id g_vctrl_cached_ls = nil; // Cached Left Stick
static id g_vctrl_cached_rs = nil; // Cached Right Stick

// Sticky input tracking: remember the intended state of every virtual button
static BOOL g_vctrlButtonTargetStates[FnCtrlButtonCount] = {NO};

@implementation FnInputPulse
- (void)onDisplayTick:(CADisplayLink *)sender {
    // ENFORCE BLUE DOT VISIBILITY: Always hide if settings pane is closed
    if (!isPopupVisible && blueDotIndicator && !blueDotIndicator.hidden) {
        blueDotIndicator.hidden = YES;
    }

    // Only reset if truly idle (unlocked AND not holding Option trigger)
    if ((!isMouseLocked && !isTriggerHeld) || isPopupVisible) {
        // IMPORTANT: Reset gyro velocity and virtual controller state when unlocked
        // so it doesn't keep moving in the last direction forever.
        ue_apply_gyro_velocity(0, 0);
        if (wasLocked) { resetControllerState(); wasLocked = NO; }
        return;
    }
    wasLocked = YES;
}
@end

// inputPulseHelper singleton moved to global scope
static FnInputPulse *g_inputPulseHelper = nil;

// --------- VIRTUAL CONTROLLER DISPATCH ---------
// Uses ue_reflection.h so values propagate into UE's input subsystem.
// ue_reflect_button_press/release: calls _setValue: on GCControllerButtonInput
//   — updates the ivar AND fires valueChangedHandler that UE polls.
// ue_reflect_thumbstick: calls _setValueX:Y: (or per-axis fallback) on the
//   GCControllerDirectionPad — drives the actual extendedGamepad axes UE reads.
// setPosition:forDirectionPadElement: (public API) only updates the virtual
//   controller's internal mirror and never reaches extendedGamepad — that's
//   why the old approach produced no movement.

// Digital stick state arrays
static BOOL dpadState[4]   = {}; // up/down/left/right
static BOOL lstickState[4] = {};
static BOOL rstickState[4] = {};

// All synthesis targets the owned virtual profile. Setters deliver callbacks;
// manual callbacks are only a compatibility fallback when no setter exists.
static void setVirtualButtonValue(GCControllerButtonInput *button, BOOL pressed) {
    if (!button) return;
    float value = pressed ? 1.0f : 0.0f;
    SEL setter = NSSelectorFromString(@"_setValue:");
    if ([button respondsToSelector:setter]) {
        ((void (*)(id, SEL, float))objc_msgSend)(button, setter, value);
    } else {
        if (button.valueChangedHandler) button.valueChangedHandler(button, value, pressed);
        if (button.pressedChangedHandler) button.pressedChangedHandler(button, value, pressed);
    }
}

static void _setVirtualFaceButton(NSString *element, BOOL pressed) {
    if (!isControllerModeEnabled || !g_virtualGamepad) return;
    SEL selector = NULL;
    if ([element isEqualToString:GCInputButtonA]) selector = @selector(buttonA);
    else if ([element isEqualToString:GCInputButtonB]) selector = @selector(buttonB);
    else if ([element isEqualToString:GCInputButtonX]) selector = @selector(buttonX);
    else if ([element isEqualToString:GCInputButtonY]) selector = @selector(buttonY);
    else if ([element isEqualToString:@"Menu"]) selector = @selector(buttonMenu);
    else if ([element isEqualToString:@"Options"]) selector = @selector(buttonOptions);
    else if ([element isEqualToString:@"Home"]) selector = @selector(buttonHome);
    _setVirtualNamedButton(selector, pressed);
}

// Drive only the owned virtual stick from its digital direction state.
static void _updateVStick(BOOL isRight, BOOL isSync) {
    if (!isControllerModeEnabled) return;
    id dpad = isRight ? g_vctrl_cached_rs : g_vctrl_cached_ls;
    if (!dpad) {
        if (g_virtualController) {
            if (!g_virtualGamepad) g_virtualGamepad = ue_get_extended_gamepad(g_virtualController);
            if (g_virtualGamepad) {
                g_vctrl_cached_ls = [g_virtualGamepad leftThumbstick];
                g_vctrl_cached_rs = [g_virtualGamepad rightThumbstick];
                dpad = isRight ? g_vctrl_cached_rs : g_vctrl_cached_ls;
            }
        }
        if (!dpad) return;
    }

    BOOL *state = isRight ? rstickState : lstickState;
    float dx = 0, dy = 0;
    
    // Faster branchless-style calculation for 8 directions
    if (state[0]) dy += 1.0f; // Up
    if (state[1]) dy -= 1.0f; // Down
    if (state[2]) dx -= 1.0f; // Left
    if (state[3]) dx += 1.0f; // Right
    
    // Fast-path for common diagonals (0.707) to avoid sqrtf
    if (dx != 0 && dy != 0) {
        dx *= 0.7071f;
        dy *= 0.7071f;
    }
    
    ue_reflect_thumbstick(dpad, dx, dy);
}

static void resetControllerState() {
    for (int i = 0; i < FnCtrlButtonCount; i++) {
        dispatchControllerButton(i, NO, NO);
    }
    memset(g_vctrlButtonTargetStates, 0, sizeof(g_vctrlButtonTargetStates));
    memset(dpadState, 0, sizeof(dpadState));
    memset(lstickState, 0, sizeof(lstickState));
    memset(rstickState, 0, sizeof(rstickState));
    memset(vctrlKeyState, 0, sizeof(vctrlKeyState));
    ue_reset_gyro_context();
}

static void _setVirtualNamedButton(SEL selector, BOOL pressed) {
    if (!isControllerModeEnabled || !g_virtualGamepad || !selector) return;
    if ([g_virtualGamepad respondsToSelector:selector]) {
        setVirtualButtonValue(((id (*)(id, SEL))objc_msgSend)(g_virtualGamepad, selector), pressed);
    }
}

// Virtual-controller lifecycle. All transitions and notifications run on main.
static BOOL g_controllerLifecycleStarted = NO;
static BOOL g_connectingVirtualController = NO;
static BOOL g_wantsVirtualController = NO;
static BOOL g_hasOtherControllers = NO;
static BOOL g_virtualControllerConnected = NO;
static NSUInteger g_controllerRevision = 0;
static GCController *g_ownedController = nil;
// Notifications describe the transition even when GCController.controllers still
// exposes the previous snapshot. Weak keys preserve that state without retaining
// unplugged devices; pointer identity also allows a new device object on reconnect.
static NSMapTable<GCController *, NSNumber *> *g_controllerConnectionStates = nil;
static __weak GCController *g_pendingPhysicalHandoff = nil;
static NSUInteger g_physicalHandoffRevision = 0;

static void schedulePhysicalControllerHandoff(void) {
    GCController *controller = g_pendingPhysicalHandoff;
    if (!controller || g_connectingVirtualController || g_virtualControllerConnected) return;
    NSUInteger revision = g_physicalHandoffRevision;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (revision != g_physicalHandoffRevision || g_pendingPhysicalHandoff != controller) return;
        if (g_virtualControllerMode != FnVirtualControllerAuto) {
            g_pendingPhysicalHandoff = nil;
            return;
        }
        if (g_connectingVirtualController || g_virtualControllerConnected) return;
        g_pendingPhysicalHandoff = nil;
        if (![[g_controllerConnectionStates objectForKey:controller] boolValue]) return;
        // Fortnite queues connection and current-device events separately. A
        // physical device arriving while virtual input owns player 0 can remain
        // assigned to another player after the virtual device disappears. Send
        // the selection event after the original connect observers have run and
        // virtual teardown has been issued. No physical values/handlers change.
        [[NSNotificationCenter defaultCenter]
            postNotificationName:GCControllerDidBecomeCurrentNotification object:controller];
    });
}

static void setVirtualControllerStatus(NSString *status) {
    if ([g_virtualControllerStatus isEqualToString:status]) return;
    g_virtualControllerStatus = status;
    [[NSNotificationCenter defaultCenter] postNotificationName:FnVirtualControllerStatusDidChangeNotification object:nil];
}

static void clearVirtualControllerCache() {
    isControllerModeEnabled = NO;
    g_virtualGamepad = nil;
    g_vctrl_cached_ls = nil;
    g_vctrl_cached_rs = nil;
    memset(g_vctrlButtonTargetStates, 0, sizeof(g_vctrlButtonTargetStates));
    memset(vctrlKeyState, 0, sizeof(vctrlKeyState));
    memset(dpadState, 0, sizeof(dpadState));
    memset(lstickState, 0, sizeof(lstickState));
    memset(rstickState, 0, sizeof(rstickState));
    ue_reset_gyro_context();
}

BOOL fnShouldSynthesizeMouseMotion(void) {
    // Do not replace device motion while another controller is in use, even in On mode.
    return isControllerModeEnabled && !g_hasOtherControllers && !isTypingModeEnabled &&
        !isPopupVisible && !isGCMouseDirectActive && (isMouseLocked || isTriggerHeld);
}

void fnRefreshVirtualController(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ fnRefreshVirtualController(); });
        return;
    }
    if (!g_controllerLifecycleStarted) return;
    if (@available(iOS 15, *)) {
        GCVirtualController *virtualController = g_virtualController;
        g_hasOtherControllers = NO;
        for (GCController *controller in GCController.controllers) {
            NSNumber *connected = [g_controllerConnectionStates objectForKey:controller];
            if (controller != virtualController.controller && controller != g_ownedController &&
                (!connected || connected.boolValue)) {
                g_hasOtherControllers = YES;
                break;
            }
        }
        // A connect notification can also arrive before enumeration includes it.
        if (!g_hasOtherControllers) {
            for (GCController *controller in g_controllerConnectionStates.keyEnumerator) {
                if (controller != virtualController.controller && controller != g_ownedController &&
                    [[g_controllerConnectionStates objectForKey:controller] boolValue]) {
                    g_hasOtherControllers = YES;
                    break;
                }
            }
        }
        BOOL desired = g_virtualControllerMode == FnVirtualControllerOn ||
            (g_virtualControllerMode == FnVirtualControllerAuto && !g_hasOtherControllers);
        if (desired != g_wantsVirtualController) {
            g_wantsVirtualController = desired;
            ++g_controllerRevision;
        }
        if (!desired) {
            if (isControllerModeEnabled) resetControllerState();
            clearVirtualControllerCache();
            // A pending connect must finish before disconnecting/reconnecting.
            // Its completion checks the revision before exposing any profile.
            if (g_virtualControllerConnected && !g_connectingVirtualController) {
                g_virtualControllerConnected = NO;
                [virtualController disconnect];
            }
            setVirtualControllerStatus(g_virtualControllerMode == FnVirtualControllerOff
                ? @"Off — use physical controller to play" : @"Auto — physical controller connected");
            if (g_virtualControllerMode == FnVirtualControllerAuto) schedulePhysicalControllerHandoff();
            return;
        }
        if (isControllerModeEnabled) {
            setVirtualControllerStatus(g_virtualControllerMode == FnVirtualControllerAuto
                ? @"Auto — virtual controller active" : @"On — virtual controller active");
            return;
        }
        if (g_connectingVirtualController) return;
        if (!virtualController) {
            GCVirtualControllerConfiguration *configuration = [[GCVirtualControllerConfiguration alloc] init];
            configuration.elements = [NSSet setWithObjects:GCInputLeftThumbstick, GCInputRightThumbstick,
                GCInputButtonA, GCInputButtonB, GCInputButtonX, GCInputButtonY,
                // Apple omits the D-pad when a left stick is configured. The
                // dispatcher still supports profiles that expose a D-pad.
                GCInputLeftShoulder, GCInputRightShoulder,
                GCInputLeftTrigger, GCInputRightTrigger, nil];
            configuration.hidden = YES;
            virtualController = [GCVirtualController virtualControllerWithConfiguration:configuration];
            g_virtualController = virtualController;
        }
        if (!virtualController) {
            setVirtualControllerStatus(@"Virtual controller unavailable");
            return;
        }
        g_connectingVirtualController = YES;
        NSUInteger revision = g_controllerRevision;
        setVirtualControllerStatus(@"Connecting virtual controller…");
        [virtualController connectWithReplyHandler:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                g_connectingVirtualController = NO;
                if (revision != g_controllerRevision || !g_wantsVirtualController) {
                    if (virtualController.controller) g_ownedController = virtualController.controller;
                    g_virtualControllerConnected = NO;
                    [virtualController disconnect];
                    clearVirtualControllerCache();
                    fnRefreshVirtualController();
                    return;
                }
                GCController *controller = virtualController.controller;
                if (controller) g_ownedController = controller;
                GCExtendedGamepad *profile = controller.extendedGamepad;
                if (error || !profile) {
                    g_virtualControllerConnected = NO;
                    [virtualController disconnect];
                    clearVirtualControllerCache();
                    setVirtualControllerStatus(error
                        ? [@"Connection failed: " stringByAppendingString:error.localizedDescription]
                        : @"Connection failed: gamepad unavailable");
                    return;
                }
                g_ownedController = controller;
                g_virtualControllerConnected = YES;
                g_virtualGamepad = profile;
                g_vctrl_cached_ls = profile.leftThumbstick;
                g_vctrl_cached_rs = profile.rightThumbstick;
                ue_reset_gyro_context();
                isControllerModeEnabled = YES;
                setVirtualControllerStatus(g_virtualControllerMode == FnVirtualControllerAuto
                    ? @"Auto — virtual controller active" : @"On — virtual controller active");
                // Recheck devices that arrived while connect was pending.
                fnRefreshVirtualController();
            });
        }];
    } else {
        setVirtualControllerStatus(@"Virtual controller requires iOS 15 or later");
    }
}

void fnSetVirtualControllerMode(FnVirtualControllerMode mode) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ fnSetVirtualControllerMode(mode); });
        return;
    }
    if (mode < FnVirtualControllerAuto || mode > FnVirtualControllerOff) mode = FnVirtualControllerAuto;
    if (mode != FnVirtualControllerAuto) {
        g_pendingPhysicalHandoff = nil;
        ++g_physicalHandoffRevision;
    }
    g_virtualControllerMode = mode;
    [tweakDefaults() setInteger:mode forKey:kVirtualControllerModeKey];
    fnRefreshVirtualController();
    [[NSNotificationCenter defaultCenter] postNotificationName:FnVirtualControllerStatusDidChangeNotification object:nil];
}

static void handleControllerNotification(NSNotification *notification) {
    GCVirtualController *virtualController = g_virtualController;
    BOOL owned = notification.object == g_ownedController ||
        notification.object == virtualController.controller;
    if (owned) {
        if ([notification.name isEqualToString:GCControllerDidConnectNotification]) {
            g_ownedController = notification.object;
            return; // The asynchronous connect completion establishes readiness.
        }
        if (!g_virtualControllerConnected) return; // Expected disconnect; do not retry failures.
        g_virtualControllerConnected = NO;
        ++g_controllerRevision;
        clearVirtualControllerCache();
    } else if ([notification.object isKindOfClass:[GCController class]]) {
        if (!g_controllerConnectionStates) {
            g_controllerConnectionStates = [NSMapTable
                mapTableWithKeyOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality
                         valueOptions:NSPointerFunctionsStrongMemory];
        }
        BOOL connected = [notification.name isEqualToString:GCControllerDidConnectNotification];
        BOOL wasConnected = [[g_controllerConnectionStates objectForKey:notification.object] boolValue];
        [g_controllerConnectionStates setObject:@(connected)
                                        forKey:notification.object];
        if (connected && !wasConnected && g_virtualControllerMode == FnVirtualControllerAuto) {
            g_pendingPhysicalHandoff = notification.object;
            ++g_physicalHandoffRevision;
        } else if (!connected && g_pendingPhysicalHandoff == notification.object) {
            g_pendingPhysicalHandoff = nil;
            ++g_physicalHandoffRevision;
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{ fnRefreshVirtualController(); });
}

// Synthesise a keyboard key event through storedKeyboardHandler.
// Attempts to get the actual button object for the target keyCode.
static void _sendKeyEvent(GCKeyCode kc, BOOL pressed) {
    if (!storedKeyboardHandler) return;
    
    // Attempt dynamic retrieval if stored pointer is missing
    if (!storedKeyboardInput) {
        if (@available(iOS 14, *)) {
            GCKeyboard *kb = [GCKeyboard coalescedKeyboard];
            if (kb) storedKeyboardInput = kb.keyboardInput;
        }
    }
    
    if (!storedKeyboardInput) return;

    // Attempt to get the actual button for this key
    GCControllerButtonInput *btn = nil;
    if ([storedKeyboardInput respondsToSelector:@selector(buttonForKeyCode:)]) {
        btn = [storedKeyboardInput buttonForKeyCode:kc];
    }
    
    if (!btn) {
        // Fallback to "Key A" as a dummy carrier if the target button is nil
        btn = [storedKeyboardInput buttonForKeyCode:GCKeyCodeKeyA];
    }
    
    if (btn) {
        storedKeyboardHandler(storedKeyboardInput, btn, kc, pressed);
    }
}

// Mouse Button Injection: System-level (CGEvent)
static void _sendMouseButtonEvent(int code, BOOL pressed) {
    if (!_CGEventCreateMouseEvent || !_CGEventPost) return;

    uint32_t type = 0;
    int button = 0;
    
    if (code == MOUSE_BUTTON_LEFT) {
        type = pressed ? 1 : 2; // kCGEventLeftMouseDown / kCGEventLeftMouseUp
        button = 0; // kCGMouseButtonLeft
    } else if (code == MOUSE_BUTTON_RIGHT) {
        type = pressed ? 3 : 4; // kCGEventRightMouseDown / kCGEventRightMouseUp
        button = 1; // kCGMouseButtonRight
    } else if (code == MOUSE_BUTTON_MIDDLE) {
        type = pressed ? 25 : 26; // kCGEventOtherMouseDown / kCGEventOtherMouseUp
        button = 2; // kCGMouseButtonCenter
    } else if (code >= MOUSE_BUTTON_AUX_BASE) {
        type = pressed ? 25 : 26; // kCGEventOtherMouseDown / kCGEventOtherMouseUp
        button = (int)(code - MOUSE_BUTTON_AUX_BASE + 3);
    } else {
        return;
    }

    CGEventRef ev = _CGEventCreateMouseEvent(NULL, type, CGPointZero, button);
    if (ev) {
        _CGEventSetIntegerValueField(ev, kCGEventSourceUserData, 0x1337);
        _CGEventPost(kCGHIDEventTap, ev);
        CFRelease(ev);
    }
}

// Dual Injection: Framework-level (MFi) + System-level (CGEvent)
static void _sendDualKeyEvent(GCKeyCode kc, BOOL pressed) {
    // 0. Direct Mouse Toggle
    if (kc != 0 && kc == GCMOUSE_DIRECT_KEY) {
        updateGCMouseDirectState((int)kc, pressed);
        // pass through to game
    }

    // 1. Mouse Button Support (Synthesize click if target is a mouse button)
    if ((int)kc >= 10000) {
       static BOOL viaGame[3] = {NO, NO, NO};
       int bi = (int)kc == MOUSE_BUTTON_LEFT ? 0 : (int)kc == MOUSE_BUTTON_RIGHT ? 1 : (int)kc == MOUSE_BUTTON_MIDDLE ? 2 : -1;
       if (bi >= 0) {
           if (pressed && isMouseLocked && isGCMouseDirectActive && fnkbmGameMouseButton((int)kc, YES)) { viaGame[bi] = YES; return; }
           if (!pressed && viaGame[bi]) { viaGame[bi] = NO; fnkbmGameMouseButton((int)kc, NO); return; }
       }
       _sendMouseButtonEvent((int)kc, pressed);
       return;
    }

    // 2. Framework-level injection
    _sendKeyEvent(kc, pressed);
    
    // 3. System-level injection (if it's a standard key or modifier)
    if ((int)kc < 256) {
        uint16_t rv = gcToNSVK[(uint8_t)kc];
        if (rv > 0 || (int)kc == 4) {
            if (_CGEventCreateKeyboardEvent && _CGEventPost) {
                // MODIFIER DETECTION: determine if this target is a modifier to send kCGEventFlagsChanged
                BOOL isModifier = (kc == 225 || kc == 229 || kc == 227 || kc == 231 || kc == 224 || kc == 228 || kc == 226 || kc == 230);
                uint32_t evType = isModifier ? 12 : (pressed ? 10 : 11); // kCGEventFlagsChanged or kCGEventKeyDown/Up
                
                CGEventRef ev = _CGEventCreateKeyboardEvent(NULL, rv, (bool)pressed);
                if (ev) {
                    if (isModifier) {
                        // For FlagsChanged, we need to explicitly set the type
                        _CGEventSetType(ev, evType); 
                    }
                    _CGEventSetIntegerValueField(ev, kCGEventSourceUserData, 0x1337);
                    _CGEventPost(kCGHIDEventTap, ev);
                    CFRelease(ev);
                }
            }
        }
    }
}

// ── L3/R3 Injection Helper ──────────────────────────────────────────────────
static id getInjectedButton(GCExtendedGamepad *gamepad, NSString *key) {
    if (!gamepad || gamepad != ue_get_extended_gamepad(g_virtualController)) return nil;
    static char const * const kInjectedButtonsKey = "kInjectedButtonsKey";
    NSMutableDictionary *dict = objc_getAssociatedObject(gamepad, kInjectedButtonsKey);
    if (!dict) {
        dict = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(gamepad, kInjectedButtonsKey, dict, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    id btn = dict[key];
    if (!btn) {
        // Use the Logos-defined subclass to avoid instantiation crashes
        btn = [[NSClassFromString(@"FnInjectedButton") alloc] init];
        if (btn) dict[key] = btn;
    }
    return btn;
}

// ── Logos Subclass for Safe Mocking ──────────────────────────────────────────
@interface FnInjectedButton : GCControllerButtonInput
- (BOOL)isPressed;
- (BOOL)pressed;
- (float)value;
- (void)_setValue:(float)v;
@end

%subclass FnInjectedButton : GCControllerButtonInput

- (BOOL)isPressed { 
    return [objc_getAssociatedObject(self, @selector(isPressed)) boolValue]; 
}

- (BOOL)pressed { return [self isPressed]; }

- (float)value { 
    return [objc_getAssociatedObject(self, @selector(value)) floatValue]; 
}

- (void)_setValue:(float)v { 
    float previousValue = self.value;
    BOOL previousPressed = self.isPressed;
    BOOL pressed = (v > 0.5);
    if (previousValue == v && previousPressed == pressed) return;
    
    // Performance: Skip KVO (willChangeValueForKey) for absolute 0-delay.
    // Most games use polling or handlers directly.
    objc_setAssociatedObject(self, @selector(value), @(v), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, @selector(isPressed), @(pressed), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    // Trigger ALL possible registered blocks immediately
    if (self.valueChangedHandler)   self.valueChangedHandler(self, v, pressed);
    if (previousPressed != pressed && self.pressedChangedHandler) self.pressedChangedHandler(self, v, pressed);
}
%end

// Master dispatcher — routes FnControllerButton index to the right mechanism
static void dispatchControllerButton(NSInteger idx, BOOL pressed, BOOL isSync) {
    if (![NSThread isMainThread]) {
        NSUInteger revision = g_controllerRevision;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (revision == g_controllerRevision) dispatchControllerButton(idx, pressed, isSync);
        });
        return;
    }
    if (!isControllerModeEnabled || !g_virtualGamepad || idx < 0 || idx >= FnCtrlButtonCount) return;
    if (g_vctrlButtonTargetStates[idx] == pressed) return;
    g_vctrlButtonTargetStates[idx] = pressed;

    // Process Sticks/Dpad state update immediately
    switch (idx) {
        case FnCtrlLeftStickUp:    lstickState[0] = pressed; _updateVStick(NO, YES);  break;
        case FnCtrlLeftStickDown:  lstickState[1] = pressed; _updateVStick(NO, YES);  break;
        case FnCtrlLeftStickLeft:  lstickState[2] = pressed; _updateVStick(NO, YES);  break;
        case FnCtrlLeftStickRight: lstickState[3] = pressed; _updateVStick(NO, YES);  break;

        case FnCtrlRightStickUp:    rstickState[0] = pressed; _updateVStick(YES, YES); break;
        case FnCtrlRightStickDown:  rstickState[1] = pressed; _updateVStick(YES, YES); break;
        case FnCtrlRightStickLeft:  rstickState[2] = pressed; _updateVStick(YES, YES); break;
        case FnCtrlRightStickRight: rstickState[3] = pressed; _updateVStick(YES, YES); break;

        case FnCtrlDpadUp:    dpadState[0] = pressed; break;
        case FnCtrlDpadDown:  dpadState[1] = pressed; break;
        case FnCtrlDpadLeft:  dpadState[2] = pressed; break;
        case FnCtrlDpadRight: dpadState[3] = pressed; break;

        // ── Stick clicks (L3/R3) ──────────────────────────────────────────
        case FnCtrlL3:
        case FnCtrlR3: {
            SEL selector = idx == FnCtrlL3 ? @selector(leftThumbstickButton) : @selector(rightThumbstickButton);
            _setVirtualNamedButton(selector, pressed);
            break;
        }
        case FnCtrlOptions: {
            _setVirtualFaceButton(@"Menu", pressed); break;
        }
        case FnCtrlShare: {
            _setVirtualFaceButton(@"Options", pressed); break;
        }
        case FnCtrlHome: {
            _setVirtualFaceButton(@"Home", pressed); break;
        }
        default: break;
    }

    // Virtual Gamepad Face Buttons and Shoulders
    switch (idx) {
        case FnCtrlButtonA: _setVirtualFaceButton(GCInputButtonA, pressed); break;
        case FnCtrlButtonB: _setVirtualFaceButton(GCInputButtonB, pressed); break;
        case FnCtrlButtonX: _setVirtualFaceButton(GCInputButtonX, pressed); break;
        case FnCtrlButtonY: _setVirtualFaceButton(GCInputButtonY, pressed); break;
        case FnCtrlL1: {
            static SEL s = NULL; if (!s) s = NSSelectorFromString(@"leftShoulder");
            _setVirtualNamedButton(s, pressed); break;
        }
        case FnCtrlR1: {
            static SEL s = NULL; if (!s) s = NSSelectorFromString(@"rightShoulder");
            _setVirtualNamedButton(s, pressed); break;
        }
        case FnCtrlL2: {
            static SEL s = NULL; if (!s) s = NSSelectorFromString(@"leftTrigger");
            _setVirtualNamedButton(s, pressed); break;
        }
        case FnCtrlR2: {
            static SEL s = NULL; if (!s) s = NSSelectorFromString(@"rightTrigger");
            _setVirtualNamedButton(s, pressed); break;
        }
        default: break;
    }

    // D-pad drive
    if (idx >= FnCtrlDpadUp && idx <= FnCtrlDpadRight) {
        float dx = 0, dy = 0;
        if (dpadState[0]) dy += 1.0f;
        if (dpadState[1]) dy -= 1.0f;
        if (dpadState[2]) dx -= 1.0f;
        if (dpadState[3]) dx += 1.0f;
        ue_reflect_thumbstick([g_virtualGamepad dpad], dx, dy);
    }

}

// ── Mapping Helpers ──────────────────────────────────────────────────────────
// (Obsolete functions removed — logic moved to caller loops for multi-bind support)

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

// --------- 120 FPS CONFIG FORCING HOOKS ---------
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>
#import <errno.h>

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

static void force120FPSInFile(const char *path) {
    if (!path) return;
    int fd = -1;
    if (orig_open) {
        fd = orig_open(path, O_RDONLY);
    } else {
        fd = open(path, O_RDONLY);
    }
    if (fd < 0) return;
    
    struct stat st;
    if (fstat(fd, &st) < 0 || st.st_size <= 0) {
        if (orig_close) orig_close(fd); else close(fd);
        return;
    }
    
    char *buf = (char *)malloc(st.st_size + 1);
    if (!buf) {
        if (orig_close) orig_close(fd); else close(fd);
        return;
    }
    
    ssize_t readBytes = read(fd, buf, st.st_size);
    if (orig_close) orig_close(fd); else close(fd);
    
    if (readBytes <= 0) {
        free(buf);
        return;
    }
    buf[readBytes] = '\0';
    
    BOOL modified = NO;
    size_t newBufSize = st.st_size * 2 + 1024;
    char *newBuf = (char *)malloc(newBufSize);
    if (!newBuf) {
        free(buf);
        return;
    }
    
    char *src = buf;
    char *dest = newBuf;
    *dest = '\0';
    
    while (*src) {
        if (strncmp(src, "b120FpsMode=False", 17) == 0) {
            strcpy(dest, "b120FpsMode=True");
            dest += 16;
            src += 17;
            modified = YES;
        } else if (strncmp(src, "MobileFPSMode=Mode_60Fps", 24) == 0) {
            strcpy(dest, "MobileFPSMode=Mode_120Fps");
            dest += 25;
            src += 24;
            modified = YES;
        } else if (strncmp(src, "MobileFPSMode=Mode_30Fps", 24) == 0) {
            strcpy(dest, "MobileFPSMode=Mode_120Fps");
            dest += 25;
            src += 24;
            modified = YES;
        } else if (strncmp(src, "MobileFPSMode=Mode_45Fps", 24) == 0) {
            strcpy(dest, "MobileFPSMode=Mode_120Fps");
            dest += 25;
            src += 24;
            modified = YES;
        } else if (strncmp(src, "MobileFPSMode=Mode_90Fps", 24) == 0) {
            strcpy(dest, "MobileFPSMode=Mode_120Fps");
            dest += 25;
            src += 24;
            modified = YES;
        } else {
            *dest++ = *src++;
            *dest = '\0';
        }
    }
    
    if (modified) {
        NSLog(@"[FnMacTweak] Detected GameUserSettings.ini modification. Rewriting to force 120 FPS...");
        int outFd = -1;
        if (orig_open) {
            outFd = orig_open(path, O_WRONLY | O_CREAT | O_TRUNC, 0666);
        } else {
            outFd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0666);
        }
        if (outFd >= 0) {
            write(outFd, newBuf, strlen(newBuf));
            if (orig_close) orig_close(outFd); else close(outFd);
            NSLog(@"[FnMacTweak] Successfully rewrote GameUserSettings.ini with 120 FPS forced.");
        } else {
            NSLog(@"[FnMacTweak] Failed to open GameUserSettings.ini for writing: %s", path);
        }
    }
    
    free(buf);
    free(newBuf);
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
    
    if (path) {
        size_t plen = strlen(path);
        if (plen > 4 && strcmp(path + plen - 4, ".ini") == 0) {
            KLOG("open ini fd=%d flags=%#x %{public}s", fd, oflag, path);
        }
    }
    if (fd >= 0 && path && strstr(path, "GameUserSettings.ini") != NULL) {
        if ((oflag & O_WRONLY) || (oflag & O_RDWR)) {
            pthread_mutex_lock(&g_monitoredMutex);
            for (int i = 0; i < MAX_MONITORED_FDS; i++) {
                if (g_monitoredFds[i].fd == 0) {
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
            g_monitoredFds[i].fd = 0;
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
    if (namelen >= 1) {
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
        
        if (name[0] == CTL_HW && (name[1] == HW_MACHINE || name[1] == HW_PRODUCT)) {
            if (buf == NULL) {
                *size = strlen(DEVICE_MODEL) + 1;
            } else {
                if (*size > strlen(DEVICE_MODEL)) {
                    strcpy((char *)buf, DEVICE_MODEL);
                } else {
                    return ENOMEM;
                }
            }
            return 0;
        } else if (name[0] == CTL_HW && name[1] == HW_TARGET) {
            if (buf == NULL) {
                *size = strlen(OEM_ID) + 1;
            } else {
                if (*size > strlen(OEM_ID)) {
                    strcpy((char *)buf, OEM_ID);
                } else {
                    return ENOMEM;
                }
            }
            return 0;
        }
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
        
        if ((strcmp(name, "hw.machine") == 0) || (strcmp(name, "hw.product") == 0) || (strcmp(name, "hw.model") == 0)) {
            if (oldp == NULL) {
                int ret = orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
                if (oldlenp && *oldlenp < strlen(DEVICE_MODEL) + 1) {
                    *oldlenp = strlen(DEVICE_MODEL) + 1;
                }
                return ret;
            } else if (oldp != NULL) {
                int ret = orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
                const char *machine = DEVICE_MODEL;
                strncpy((char *)oldp, machine, strlen(machine));
                ((char *)oldp)[strlen(machine)] = '\0';
                if (oldlenp) *oldlenp = strlen(machine) + 1;
                return ret;
            }
        } else if (strcmp(name, "hw.target") == 0) {
            if (oldp == NULL) {
                int ret = orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
                if (oldlenp && *oldlenp < strlen(OEM_ID) + 1) {
                    *oldlenp = strlen(OEM_ID) + 1;
                }
                return ret;
            } else if (oldp != NULL) {
                int ret = orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
                const char *machine = OEM_ID;
                strncpy((char *)oldp, machine, strlen(machine));
                ((char *)oldp)[strlen(machine)] = '\0';
                if (oldlenp) *oldlenp = strlen(machine) + 1;
                return ret;
            }
        }
    }
    return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

// --------- CONSTRUCTOR ---------


// Category to add pan gesture handling to the blue dot indicator
@interface UIView (BlueDotDragging)
- (void)handleBluePan:(UIPanGestureRecognizer *)gesture;
@end

@implementation UIView (BlueDotDragging)
- (void)handleBluePan:(UIPanGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateChanged) {
        CGPoint translation = [gesture translationInView:self.superview];
        CGPoint newCenter = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
        CGRect bounds = self.superview.bounds;
        newCenter.x = MAX(10, MIN(bounds.size.width  - 10, newCenter.x));
        newCenter.y = MAX(10, MIN(bounds.size.height - 10, newCenter.y));
        self.center = newCenter;
        blueDotPosition = newCenter;
        [gesture setTranslation:CGPointZero inView:self.superview];
    } else if (gesture.state == UIGestureRecognizerStateEnded ||
               gesture.state == UIGestureRecognizerStateCancelled) {
        NSDictionary *posDict = @{@"x": @(blueDotPosition.x), @"y": @(blueDotPosition.y)};
        [[NSUserDefaults standardUserDefaults] setObject:posDict forKey:kBlueDotPositionKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}
@end

// ---------------------------------------------------------------------------
// LEVEL 14: IOHID-Prime (Raw Hardware Aim — SDK Independent)
// ---------------------------------------------------------------------------

typedef struct __IOHIDManager * IOHIDManagerRef;
typedef void (*IOHIDReportCallback)(void * context, int32_t result, void * sender, uint32_t type, uint32_t reportID, uint8_t * report, CFIndex reportLength);
typedef IOHIDManagerRef (*IOHIDManagerCreate_t)(CFAllocatorRef allocator, uint32_t options);
typedef void (*IOHIDManagerSetDeviceMatching_t)(IOHIDManagerRef manager, CFDictionaryRef matching);
typedef void (*IOHIDManagerRegisterInputReportCallback_t)(IOHIDManagerRef manager, IOHIDReportCallback callback, void * context);
typedef void (*IOHIDManagerScheduleWithRunLoop_t)(IOHIDManagerRef manager, CFRunLoopRef runLoop, CFStringRef runLoopMode);
typedef int32_t (*IOHIDManagerOpen_t)(IOHIDManagerRef manager, uint32_t options);

static void handleHIDInputReport(void *context, int32_t result, void *sender, uint32_t type, uint32_t reportID, uint8_t *report, CFIndex reportLength) {
    if (reportLength < 3) return;
    
    // LEVEL 20: 16-Bit High-Precision HID Parser
    // Many gaming mice send 16-bit deltas in 5+ byte reports.
    int32_t dx_raw = 0;
    int32_t dy_raw = 0;
    
    if (reportLength >= 5) {
        // 16-bit signed (little endian)
        dx_raw = (int16_t)(report[1] | (report[2] << 8));
        dy_raw = (int16_t)(report[3] | (report[4] << 8));
    } else {
        // Standard 8-bit fallback
        dx_raw = (int8_t)report[1];
        dy_raw = (int8_t)report[2];
    }
    
    // Keep coordinates in their native aim direction (do not manually invert)
    
    // Native mouse mode: the game gets movement from its own mouse handler.
    // Feeding the gyro orientation as well would aim twice and tell the game
    // a motion device is in use, so this path stays idle.
    if ((dx_raw != 0 || dy_raw != 0) && !isGCMouseDirectActive) {
        // 1. Accumulate into the pull-buffer for visual smoothness (legacy fallback)
        int idx = atomic_load(&activeBufferIdx);
        atomic_fetch_add(&mouseAccumBufferX[idx], (double)dx_raw);
        atomic_fetch_add(&mouseAccumBufferY[idx], (double)dy_raw);
        atomic_store(&mouseHardwareTimestamp[idx], mach_absolute_time());

        // 2. LEVEL 27: God-Mode Cache-Aligned Link (Quantum Trajectory)
        // We update the high-precision Euler state for the direct Engine hook.
        // Inverting X and Y axes for native aim feel
        float deltaYaw   = (float)dx_raw * HID_SENSITIVITY_SCALAR;
        float deltaPitch = (float)dy_raw * HID_SENSITIVITY_SCALAR;
        
        static float currentPitch = 0;
        static float currentYaw   = 0;
        
        // Store previous state for the trajectory engine (Quantum Reflex)
        atomic_store(&g_godReflex.lastPitch, currentPitch);
        atomic_store(&g_godReflex.lastYaw,   currentYaw);
        atomic_store(&g_godReflex.lastTimestamp, mach_absolute_time());
        
        currentPitch += deltaPitch;
        currentYaw   += deltaYaw;
        
        // Write fresh state into the L1-Aligned block
        atomic_store(&g_godReflex.pitch, currentPitch);
        atomic_store(&g_godReflex.yaw,   currentYaw);
        atomic_store(&g_godReflex.roll,  0.0f);
    }

    // LEVEL 20: Unified Input Singularity
    // Re-assert virtual controller sticks and buttons on the hardware clock (1000Hz).
    // This removes the 1-2ms "jitter" caused by thread context switching in Level 19.
    if (isMouseLocked && !isPopupVisible && isControllerModeEnabled) {
        _updateVStick(NO, YES); // Left Stick (Sync)
        _updateVStick(YES, YES); // Right Stick (Sync)
    }
}

// ── Mouse movement smoothing ─────────────────────────────────────────────
// See fnkbm_smooth.h. In native mode all movement for the game goes through
// fnkbmMouseFeed, from whichever thread it arrives on.
#include "fnkbm_smooth.h"
#include <os/lock.h>
static FnkbmSmooth g_fnkbmSmooth = {0, 0, 0, 0, 8.0, 0, 0};
static os_unfair_lock g_fnkbmSmoothLock = OS_UNFAIR_LOCK_INIT;
static BOOL g_fnkbmMouseSmooth = YES;
static double g_fnkbmEmitCarryX = 0, g_fnkbmEmitCarryY = 0;   // lock held
static dispatch_source_t g_fnkbmSmoothTimer = nil;
static _Atomic long g_fnkbmFeedDirect = 0, g_fnkbmFeedHeld = 0;

static double fnkbmNowMs(void) {
    static mach_timebase_info_data_t tb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&tb); });
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}
// Passes movement to the game in whole counts and carries the fraction. Lock held.
static void fnkbmMouseEmit(double x, double y) {
    FnGCMouseMovedHandler h = g_originalMouseHandler;
    if (!h) return;
    g_fnkbmEmitCarryX += x; g_fnkbmEmitCarryY += y;
    double ox = round(g_fnkbmEmitCarryX), oy = round(g_fnkbmEmitCarryY);
    g_fnkbmEmitCarryX -= ox; g_fnkbmEmitCarryY -= oy;
    if (ox != 0 || oy != 0) h(g_capturedMouseInput, (float)ox, (float)oy);
}
// Movement for the game, already scaled by the sensitivity settings. Any thread.
static void fnkbmMouseFeed(double dx, double dy) {
    os_unfair_lock_lock(&g_fnkbmSmoothLock);
    double ox = dx, oy = dy;
    if (!g_fnkbmMouseSmooth || fnkbmSmoothAdd(&g_fnkbmSmooth, fnkbmNowMs(), dx, dy, &ox, &oy)) {
        fnkbmMouseEmit(ox, oy);
        atomic_fetch_add(&g_fnkbmFeedDirect, 1);
    } else {
        atomic_fetch_add(&g_fnkbmFeedHeld, 1);
    }
    os_unfair_lock_unlock(&g_fnkbmSmoothLock);
}
static void fnkbmInstallMouseSmooth(void) {
    g_fnkbmMouseSmooth = YES;  // no panel to switch it: always on
    dispatch_queue_t q = dispatch_queue_create("fnkbm.mousesmooth", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    g_fnkbmSmoothTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, q);
    dispatch_source_set_timer(g_fnkbmSmoothTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_MSEC, 0);
    dispatch_source_set_event_handler(g_fnkbmSmoothTimer, ^{
        os_unfair_lock_lock(&g_fnkbmSmoothLock);
        if (g_fnkbmSmooth.pendX != 0 || g_fnkbmSmooth.pendY != 0) {
            if (!isGCMouseDirectActive) {
                g_fnkbmSmooth.pendX = g_fnkbmSmooth.pendY = 0;
            } else {
                double x = 0, y = 0;
                fnkbmSmoothTick(&g_fnkbmSmooth, fnkbmNowMs(), &x, &y);
                fnkbmMouseEmit(x, y);
            }
        }
        os_unfair_lock_unlock(&g_fnkbmSmoothLock);
    });
    dispatch_resume(g_fnkbmSmoothTimer);
    KLOG("mouse smoothing=%d", g_fnkbmMouseSmooth);
}

// ── Mouse movement taken from the device ─────────────────────────────────
// GameController passes mouse movement on in coarse steps, at most about a
// hundred a second. At 120 frames a second that leaves frames with no
// movement and frames with double, which looks like a low frame rate.
// The device itself reports far more often. Its X and Y values are read
// here, on their own thread, and added to the game's mouse total directly.
// Before a device is trusted, its values are compared with what
// GameController reports for the same movement: they must agree closely,
// and the comparison also gives the scale and direction to use. A device
// that does not agree, or that reports no more often than GameController
// passes on, is left on the GameController path.
#define FNKBM_HID_DEVS 6
typedef struct {
    void *dev;
    _Atomic long pendX, pendY, pendN;      // device counts since the last GameController event
    double sxx, hxx, gxx, syy, hyy, gyy;   // comparison sums (main thread)
    long samples, values;
    _Atomic int state;                     // 0 comparing, 1 in use, 2 not usable
    double kx, ky;                         // GameController units per device count, signed
} FnkbmHidDev;
static FnkbmHidDev g_fnkbmHid[FNKBM_HID_DEVS];
static _Atomic int g_fnkbmHidCount = 0;
static _Atomic long g_fnkbmGcEvents = 0, g_fnkbmHidValues = 0, g_fnkbmHidForwarded = 0;
static _Atomic long g_fnkbmHidLastFwdMs = 0;   // when a trusted device last delivered movement

typedef void *(*FnkbmValueGetElement_t)(void *);
typedef uint32_t (*FnkbmElementGetU32_t)(void *);
typedef long (*FnkbmValueGetInteger_t)(void *);
static FnkbmValueGetElement_t fnkbm_ValueGetElement = NULL;
static FnkbmElementGetU32_t fnkbm_ElementGetUsagePage = NULL, fnkbm_ElementGetUsage = NULL;
static FnkbmValueGetInteger_t fnkbm_ValueGetInteger = NULL;

static FnkbmHidDev *fnkbmHidDevice(void *sender) {   // device thread
    int n = atomic_load(&g_fnkbmHidCount);
    for (int i = 0; i < n; i++) if (g_fnkbmHid[i].dev == sender) return &g_fnkbmHid[i];
    if (n >= FNKBM_HID_DEVS) return NULL;
    memset(&g_fnkbmHid[n], 0, sizeof(FnkbmHidDev));
    g_fnkbmHid[n].dev = sender;
    atomic_store(&g_fnkbmHidCount, n + 1);
    return &g_fnkbmHid[n];
}

static void fnkbmHidValue(void *context, int result, void *sender, void *value) {
    if (!value || !fnkbm_ValueGetElement) return;
    void *el = fnkbm_ValueGetElement(value);
    if (!el) return;
    uint32_t page = fnkbm_ElementGetUsagePage(el), usage = fnkbm_ElementGetUsage(el);
    if (page != 0x01 || (usage != 0x30 && usage != 0x31)) return;   // generic desktop X / Y
    long v = fnkbm_ValueGetInteger(value);
    if (v == 0) return;
    atomic_fetch_add(&g_fnkbmHidValues, 1);
    if (!isMouseLocked || !isGCMouseDirectActive || isPopupVisible || !atomic_load(&g_fnkbmRealActive)) return;
    FnkbmHidDev *d = fnkbmHidDevice(sender);
    if (!d) return;
    int st = atomic_load(&d->state);
    if (st == 0) {
        if (usage == 0x30) atomic_fetch_add(&d->pendX, v); else atomic_fetch_add(&d->pendY, v);
        atomic_fetch_add(&d->pendN, 1);
        return;
    }
    if (st != 1) return;
    double ads = rightButtonIsPressed ? (NATIVE_ADS_SENS / 100.0) : 1.0;
    if (usage == 0x30) fnkbmMouseFeed((double)v * d->kx * (NATIVE_SENS_X / 100.0) * ads, 0);
    else fnkbmMouseFeed(0, (double)v * d->ky * (NATIVE_SENS_Y / 100.0) * ads);
    atomic_store(&g_fnkbmHidLastFwdMs, (long)fnkbmNowMs());
    atomic_fetch_add(&g_fnkbmHidForwarded, 1);
}

// Called for each GameController movement event while native mode is on.
// Returns YES when a trusted device already delivered this movement.
static BOOL fnkbmHidOnGCEvent(float gx, float gy) {
    atomic_fetch_add(&g_fnkbmGcEvents, 1);
    // A trusted device delivered within the last 100 ms: this event repeats
    // its movement. Judged by time, because the two paths are not in step.
    BOOL fed = (long)fnkbmNowMs() - atomic_load(&g_fnkbmHidLastFwdMs) < 100;
    FnkbmHidDev *learner = NULL; long lx = 0, ly = 0, ln = 0; int movers = 0;
    int n = atomic_load(&g_fnkbmHidCount);
    for (int i = 0; i < n; i++) {
        FnkbmHidDev *d = &g_fnkbmHid[i];
        if (atomic_load(&d->state) != 0) continue;
        long pn = atomic_exchange(&d->pendN, 0), px = atomic_exchange(&d->pendX, 0), py = atomic_exchange(&d->pendY, 0);
        if (pn > 0) { movers++; learner = d; lx = px; ly = py; ln = pn; }
    }
    if (movers == 1 && !fed) {
        FnkbmHidDev *d = learner;
        d->sxx += (double)lx * gx; d->hxx += (double)lx * lx; d->gxx += (double)gx * gx;
        d->syy += (double)ly * gy; d->hyy += (double)ly * ly; d->gyy += (double)gy * gy;
        d->samples++; d->values += ln;
        if (d->samples >= 200 && d->hxx > 5000 && d->hyy > 5000 && d->gxx > 5000 && d->gyy > 5000) {
            double cx = d->sxx / sqrt(d->hxx * d->gxx), cy = d->syy / sqrt(d->hyy * d->gyy);
            double per = (double)d->values / (double)d->samples;   // one report gives up to two values
            BOOL agrees = fabs(cx) > 0.9 && fabs(cy) > 0.9;
            if (agrees && per > 2.5) {
                d->kx = d->sxx / d->hxx; d->ky = d->syy / d->hyy;
                atomic_store(&d->state, 1);
                KLOG("mouse device %p trusted: agreement x=%.3f y=%.3f, scale x=%.3f y=%.3f, %.1f values per GameController event, after %ld samples", d->dev, cx, cy, d->kx, d->ky, per, d->samples);
            } else if (agrees) {
                atomic_store(&d->state, 2);
                KLOG("mouse device %p agrees (x=%.3f y=%.3f) but reports no more often than GameController passes on (%.1f values per event): staying on GameController", d->dev, cx, cy, per);
            } else if (d->samples >= 1500) {
                atomic_store(&d->state, 2);
                KLOG("mouse device %p not usable: agreement x=%.3f y=%.3f after %ld samples, staying on GameController", d->dev, cx, cy, d->samples);
            }
        }
    }
    return fed;
}

static void setupHIDManager() {
    static IOHIDManagerCreate_t fn_IOHIDManagerCreate = (IOHIDManagerCreate_t)dlsym(RTLD_DEFAULT, "IOHIDManagerCreate");
    static IOHIDManagerSetDeviceMatching_t fn_IOHIDManagerSetDeviceMatching = (IOHIDManagerSetDeviceMatching_t)dlsym(RTLD_DEFAULT, "IOHIDManagerSetDeviceMatching");
    static IOHIDManagerRegisterInputReportCallback_t fn_IOHIDManagerRegisterInputReportCallback = (IOHIDManagerRegisterInputReportCallback_t)dlsym(RTLD_DEFAULT, "IOHIDManagerRegisterInputReportCallback");
    static IOHIDManagerScheduleWithRunLoop_t fn_IOHIDManagerScheduleWithRunLoop = (IOHIDManagerScheduleWithRunLoop_t)dlsym(RTLD_DEFAULT, "IOHIDManagerScheduleWithRunLoop");
    static IOHIDManagerOpen_t fn_IOHIDManagerOpen = (IOHIDManagerOpen_t)dlsym(RTLD_DEFAULT, "IOHIDManagerOpen");
    
    if (!fn_IOHIDManagerCreate) return;
    
    g_hidManager = (void *)fn_IOHIDManagerCreate(kCFAllocatorDefault, 0);
    if (!g_hidManager) return;
    
    NSDictionary *matching = @{
        @"DeviceUsagePage" : @(0x01), // Generic Desktop
        @"DeviceUsage"     : @(0x02)  // Mouse
    };
    
    fn_IOHIDManagerSetDeviceMatching((IOHIDManagerRef)g_hidManager, (__bridge CFDictionaryRef)matching);
    fn_IOHIDManagerRegisterInputReportCallback((IOHIDManagerRef)g_hidManager, handleHIDInputReport, NULL);
    // Per-axis values, decoded by the system from the device's own description.
    typedef void (*FnkbmRegisterValue_t)(void *, void (*)(void *, int, void *, void *), void *);
    FnkbmRegisterValue_t regValue = (FnkbmRegisterValue_t)dlsym(RTLD_DEFAULT, "IOHIDManagerRegisterInputValueCallback");
    fnkbm_ValueGetElement = (FnkbmValueGetElement_t)dlsym(RTLD_DEFAULT, "IOHIDValueGetElement");
    fnkbm_ElementGetUsagePage = (FnkbmElementGetU32_t)dlsym(RTLD_DEFAULT, "IOHIDElementGetUsagePage");
    fnkbm_ElementGetUsage = (FnkbmElementGetU32_t)dlsym(RTLD_DEFAULT, "IOHIDElementGetUsage");
    fnkbm_ValueGetInteger = (FnkbmValueGetInteger_t)dlsym(RTLD_DEFAULT, "IOHIDValueGetIntegerValue");
    BOOL valueOk = regValue && fnkbm_ValueGetElement && fnkbm_ElementGetUsagePage && fnkbm_ElementGetUsage && fnkbm_ValueGetInteger;
    if (valueOk) regValue(g_hidManager, fnkbmHidValue, NULL); else fnkbm_ValueGetElement = NULL;
    KLOG("mouse device reader: %d", valueOk);
    
    // Level 14: Dedicated HID Thread with Mach Real-Time priority
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        elevateThreadToRealTime();
        fn_IOHIDManagerScheduleWithRunLoop((IOHIDManagerRef)g_hidManager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        fn_IOHIDManagerOpen((IOHIDManagerRef)g_hidManager, 0);
        CFRunLoopRun();
    });
}

// 0 left, 1 right, 2 middle, -1 not a mouse button of the current mouse.
static int fnkbmMouseButtonIndex(GCControllerButtonInput *btn) {
    NSNumber *codeNum = objc_getAssociatedObject(btn, &kButtonCodeKey);
    if (codeNum) {
        int c = [codeNum intValue];
        return c == MOUSE_BUTTON_LEFT ? 0 : c == MOUSE_BUTTON_RIGHT ? 1 : c == MOUSE_BUTTON_MIDDLE ? 2 : -1;
    }
    GCMouseInput *mi = GCMouse.current.mouseInput;
    if (!mi) return -1;
    if (btn == mi.leftButton) return 0;
    if (btn == mi.rightButton) return 1;
    if (btn == mi.middleButton) return 2;
    return -1;
}

// Unreal input settings for a real mouse: clicks go to the game view, not to
// a screen touch, and the view keeps the mouse captured. Written as the saved
// Input.ini layer. An existing file that is not ours is left alone.
static NSString *const kFnKbmIniMarker = @"; FnKbm native mouse input";
static void fnkbmWriteInputIni(void) {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/FortniteGame/Saved/Config/IOS"];
    NSString *path = [dir stringByAppendingPathComponent:@"Input.ini"];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL want = [[NSUserDefaults standardUserDefaults] objectForKey:@"fnkbm.inputIni"] ?
        [[NSUserDefaults standardUserDefaults] boolForKey:@"fnkbm.inputIni"] : NO;
    NSString *cur = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    BOOL ours = cur && [cur hasPrefix:kFnKbmIniMarker];
    KLOG("input ini want=%d exists=%d ours=%d path=%{public}s", want, cur != nil, ours, path.UTF8String);
    if (cur && !ours) { KLOG("input ini exists and is not ours, left alone: %{public}s", cur.UTF8String); return; }
    if (!want) { if (ours) { [fm removeItemAtPath:path error:nil]; KLOG("input ini removed"); } return; }
    NSString *body = [kFnKbmIniMarker stringByAppendingString:
        @"\n[/Script/Engine.InputSettings]\n"
        @"bUseMouseForTouch=False\n"
        @"bCaptureMouseOnLaunch=True\n"
        @"bEnableMouseSmoothing=False\n"
        @"DefaultViewportMouseCaptureMode=CapturePermanently\n"
        @"DefaultViewportMouseLockMode=LockOnCapture\n"];
    NSError *err = nil;
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&err];
    BOOL ok = [body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err];
    KLOG("input ini written ok=%d err=%{public}s", ok, err ? err.localizedDescription.UTF8String : "none");
}

// Earlier test builds wrote config files that turned out to have no effect.
// Remove the ones carrying our marker, and their folders if left empty.
static void fnkbmCleanOldConfig(void) {
    NSString *home = NSHomeDirectory();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *marker = @"; FnKbm user config, written by FnMacTweak";
    NSMutableArray<NSString *> *files = [NSMutableArray arrayWithObject:
        [home stringByAppendingPathComponent:@"Documents/FortniteGame/Saved/Config/IOS/Game.ini"]];
    for (NSString *root in @[@"Documents", @"Library/Application Support", @"Library/Preferences", @"Library/Caches"]) {
        NSString *dir = [[home stringByAppendingPathComponent:root] stringByAppendingPathComponent:@"Unreal Engine/Engine/Config"];
        [files addObject:[dir stringByAppendingPathComponent:@"UserGame.ini"]];
        [files addObject:[dir stringByAppendingPathComponent:@"SystemGame.ini"]];
    }
    for (NSString *f in files) {
        NSString *cur = [NSString stringWithContentsOfFile:f encoding:NSUTF8StringEncoding error:nil];
        if (cur && [cur hasPrefix:marker]) {
            BOOL ok = [fm removeItemAtPath:f error:nil];
            KLOG("removed old config ok=%d %{public}s", ok, f.UTF8String);
            NSString *d = [f stringByDeletingLastPathComponent];
            for (int i = 0; i < 3 && [d rangeOfString:@"Unreal Engine"].location != NSNotFound; i++) {
                if (rmdir(d.fileSystemRepresentation) != 0) break;   // only removes empty folders
                d = [d stringByDeletingLastPathComponent];
            }
        }
    }
}

// ── Cursor lock that follows the game ────────────────────────────────────
// The game logs when it shows the cursor (menus) and hides it (gameplay).
// Following that log, the cursor locks for gameplay and frees for menus
// without a key. L still works as a manual override.
static void updateMouseLock(BOOL value, CGPoint warpPos);
static void resetControllerState();
static dispatch_source_t g_fnkbmLogTimer = nil;
static BOOL g_fnkbmHaveGameCursor = NO;
static BOOL g_fnkbmGameCursorShown = YES;

static void fnkbmApplyGameCursor(const char *why) {
    if (!NATIVE_ALWAYS_ON || !g_fnkbmHaveGameCursor) return;
    BOOL wantLock = !g_fnkbmGameCursorShown;
    BOOL active = [UIApplication sharedApplication].applicationState == UIApplicationStateActive;
    KLOG("game cursor shown=%d wantLock=%d locked=%d active=%d popup=%d (%{public}s)", g_fnkbmGameCursorShown, wantLock, isMouseLocked, active, isPopupVisible, why);
    if (wantLock == isMouseLocked || isPopupVisible) return;
    if (wantLock && !active) return;   // applied when the app becomes active again
    // The game often shows its cursor for a fraction of a second during play.
    // Freeing the cursor for that drops held inputs, so wait and see if it lasts.
    static int unlockGen = 0;
    unlockGen++;
    if (!wantLock && strcmp(why, "settled") != 0) {
        int gen = unlockGen;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (gen == unlockGen && g_fnkbmGameCursorShown) fnkbmApplyGameCursor("settled");
        });
        return;
    }
    isMouseLocked = wantLock;
    if (wantLock) {
        updateMouseLock(YES, CGPointZero);
    } else {
        UIWindowScene *sc = (UIWindowScene *)[[UIApplication sharedApplication].connectedScenes anyObject];
        CGRect sb = sc ? sc.screen.bounds : CGRectMake(0, 0, 1920, 1080);
        updateMouseLock(NO, CGPointMake(sb.size.width / 2.0, sb.size.height / 2.0));
        resetControllerState();
    }
}

// Writes the active binds to the log, so a test shows what was saved.
static void fnkbmLogBinds(const char *why) {
    NSMutableString *out = [NSMutableString string];
    for (int i = 0; i < 10200; i++) {
        if (fortniteRemapArray[i]) [out appendFormat:@"%d>%ld ", i, (long)fortniteRemapArray[i]];
        if (i < 512 && keyRemapArray[i]) [out appendFormat:@"%d=>%ld ", i, (long)keyRemapArray[i]];
    }
    for (int i = 0; i < MOUSE_REMAP_COUNT; i++) {
        if (mouseButtonRemapArray[i]) [out appendFormat:@"m%d=>%ld ", MOUSE_BUTTON_MIDDLE + i, (long)mouseButtonRemapArray[i]];
        if (mouseFortniteArray[i]) [out appendFormat:@"m%d>%ld ", MOUSE_BUTTON_MIDDLE + i, (long)mouseFortniteArray[i]];
    }
    KLOG("binds (%{public}s): %{public}s", why, out.length ? out.UTF8String : "none");
}

static void fnkbmStartLogFollower(void) {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/FortniteGame/Saved/Logs/FortniteGame.log"];
    char *cpath = strdup(path.fileSystemRepresentation);
    time_t started = time(NULL);
    dispatch_queue_t q = dispatch_queue_create("fnkbm.logfollow", DISPATCH_QUEUE_SERIAL);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), 50 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
    __block int fd = -1;
    __block ino_t ino = 0;
    __block off_t pos = 0;
    __block unsigned tick = 0;
    NSMutableData *pending = [NSMutableData data];
    dispatch_source_set_event_handler(timer, ^{
        static BOOL panelWasOpen = NO;
        BOOL panelOpen = isPopupVisible;
        if (panelWasOpen && !panelOpen) {
            dispatch_async(dispatch_get_main_queue(), ^{ fnkbmLogBinds("panel closed"); fnkbmApplyGameCursor("panel closed"); });
        }
        panelWasOpen = panelOpen;
        struct stat st;
        static int waitReason = 0;   // logged once per reason
        // Once a second, or while no file is open: is this session's log there?
        if (fd < 0 || (tick++ % 20) == 0) {
            if (stat(cpath, &st) != 0) {
                if (waitReason != 1) { waitReason = 1; KLOG("log follower waiting: stat failed errno=%d", errno); }
                return;
            }
            // The game keeps one log file and rewrites it each launch, so the
            // file is this session's once it has been written since we started.
            if (fd < 0 && st.st_mtimespec.tv_sec < started - 2) {
                if (waitReason != 2) { waitReason = 2; KLOG("log follower waiting: log not written this session yet (age=%lds)", (long)(time(NULL) - st.st_mtimespec.tv_sec)); }
                return;
            }
            if (fd < 0 || st.st_ino != ino) {
                if (fd >= 0) close(fd);
                fd = open(cpath, O_RDONLY);
                ino = st.st_ino; pos = 0; pending.length = 0;
                KLOG("following game log fd=%d size=%lld", fd, (long long)st.st_size);
                if (fd < 0) return;
            }
        }
        if (fstat(fd, &st) != 0) return;
        if (st.st_size < pos) { pos = 0; pending.length = 0; }
        int last = -1;
        char buf[16384];
        while (pos < st.st_size) {
            ssize_t n = pread(fd, buf, sizeof(buf), pos);
            if (n <= 0) break;
            pos += n;
            [pending appendBytes:buf length:(NSUInteger)n];
            size_t done = fnkbmCompleteLinesLength((const char *)pending.bytes, pending.length);
            if (done > 0) {
                int s2 = fnkbmScanCursorState((const char *)pending.bytes, done);
                if (s2 != -1) last = s2;
                [pending replaceBytesInRange:NSMakeRange(0, done) withBytes:NULL length:0];
            }
            if (pending.length > 65536) pending.length = 0;   // one absurdly long line: drop it
        }
        if (last != -1) {
            BOOL shown = (last == 1);
            dispatch_async(dispatch_get_main_queue(), ^{
                g_fnkbmHaveGameCursor = YES;
                g_fnkbmGameCursorShown = shown;
                fnkbmApplyGameCursor("game log");
            });
        }
    });
    dispatch_resume(timer);
    g_fnkbmLogTimer = timer;   // keeps the timer alive
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
        queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) { fnkbmApplyGameCursor("app active"); }];
    KLOG("log follower started for %{public}s", cpath);
}

#ifdef FNKBM_DEBUG
// Command word: op<<56 | a<<32 (16 bit) | b<<16 (signed 16) | c (signed 16)
static void fnkbmDebugCommand(uint64_t w) {
    int op = (int)(w >> 56), a = (int)((w >> 32) & 0xFFFF);
    int b = (int16_t)((w >> 16) & 0xFFFF), c = (int16_t)(w & 0xFFFF);
    KLOG("dbg op=%d a=%d b=%d c=%d", op, a, b, c);
    switch (op) {
        case 1: { // key a, pressed c, through the tweak's keyboard wrapper
            if (!g_dbgKbWrapper || !storedKeyboardInput) { KLOG("dbg: no keyboard handler yet"); break; }
            GCControllerButtonInput *btn = [storedKeyboardInput buttonForKeyCode:(GCKeyCode)a];
            g_dbgKbWrapper(storedKeyboardInput, btn, (GCKeyCode)a, c != 0);
            break; }
        case 2: // mouse move b,c through the tweak's mouse wrapper
            if (!g_dbgMouseWrapper) { KLOG("dbg: no mouse handler yet"); break; }
            g_dbgMouseWrapper(g_capturedMouseInput, (float)b, (float)c);
            break;
        case 3: { // mouse button a (0 left 1 right 2 middle), pressed c
            if (a < 0 || a > 2) break;
            if (a == 1) rightButtonIsPressed = (c != 0);
            if (a == 0) leftButtonIsPressed = (c != 0);
            if (g_dbgBtnPressed[a]) g_dbgBtnPressed[a](g_dbgBtn[a], c ? 1.0f : 0.0f, c != 0);
            if (g_dbgBtnValue[a]) g_dbgBtnValue[a](g_dbgBtn[a], c ? 1.0f : 0.0f, c != 0);
            if (!g_dbgBtnPressed[a] && !g_dbgBtnValue[a]) KLOG("dbg: game registered no handler for button %d", a);
            break; }
        case 4: { // lock c
            isMouseLocked = (c != 0);
            UIWindowScene *sc = (UIWindowScene *)[[UIApplication sharedApplication].connectedScenes anyObject];
            CGRect sb = sc ? sc.screen.bounds : CGRectMake(0, 0, 1920, 1080);
            updateMouseLock(isMouseLocked, isMouseLocked ? CGPointZero : CGPointMake(sb.size.width / 2.0, sb.size.height / 2.0));
            break; }
        case 5: // state
            KLOG("state lock=%d direct=%d ctrl=%d always=%d popup=%d kb=%d mouse=%d btnP=%d%d%d btnV=%d%d%d hid=%d vc=%d",
                 isMouseLocked, isGCMouseDirectActive, isControllerModeEnabled, NATIVE_ALWAYS_ON, isPopupVisible,
                 g_dbgKbWrapper != nil, g_dbgMouseWrapper != nil,
                 g_dbgBtnPressed[0] != nil, g_dbgBtnPressed[1] != nil, g_dbgBtnPressed[2] != nil,
                 g_dbgBtnValue[0] != nil, g_dbgBtnValue[1] != nil, g_dbgBtnValue[2] != nil,
                 g_hidManager != NULL, g_virtualController != nil);
            break;
        case 6: // persist a boolean test switch: a=1 input ini
            if (a == 1) { [[NSUserDefaults standardUserDefaults] setBool:(c != 0) forKey:@"fnkbm.inputIni"]; fnkbmWriteInputIni(); }
            break;
        case 7: // direct mode c
            isGCMouseDirectActive = (c != 0);
            KLOG("dbg direct=%d", isGCMouseDirectActive);
            break;
    }
}
static void fnkbmDebugInstall(void) {
    static int token = 0;
    uint32_t r = notify_register_dispatch("fnkbm.dbg", &token, dispatch_get_main_queue(), ^(int t) {
        uint64_t w = 0; notify_get_state(t, &w); fnkbmDebugCommand(w);
    });
    KLOG("debug channel status=%u", r);
}
#endif

static NSInteger (*g_origUIKeyKeyCode)(id, SEL) = NULL;
static NSString *(*g_origUIKeyCharacters)(id, SEL) = NULL;
static NSMutableDictionary<NSString *, NSValue *> *g_fnkbmPressOrig = nil;
static int g_fnkbmPressDepth = 0;
static BOOL g_fnkbmXlatRead = NO;   // the game read a translated key code

static IMP fnkbmPressOrigFor(id obj, SEL sel) {
    for (Class c = object_getClass(obj); c; c = class_getSuperclass(c)) {
        NSValue *v = g_fnkbmPressOrig[[NSString stringWithFormat:@"%p/%s", (void *)c, sel_getName(sel)]];
        if (v) return (IMP)v.pointerValue;
    }
    return NULL;
}
static long fnkbmPhysicalKey(UIPress *p) {
    id k = [p respondsToSelector:@selector(key)] ? p.key : nil;
    if (!k || !g_origUIKeyKeyCode) return 0;
    long c = (long)g_origUIKeyKeyCode(k, @selector(keyCode));
    return (c > 0 && c < 512) ? c : 0;
}
// Caps Lock: macOS reports it as a switch, on at one press and off at the
// next, so the game would see it held down until pressed again. The game does
// know the key. Each change is therefore given to the game as a short press:
// down now, up 40 ms later. It cannot be held.
static BOOL fnkbmCapsTap(id self, SEL _cmd, NSSet *presses, id event) {
    if (isTypingModeEnabled || presses.count == 0) return NO;
    for (UIPress *p in presses) if (fnkbmPhysicalKey(p) != 57) return NO;
    BOOL change = sel_isEqual(_cmd, @selector(pressesBegan:withEvent:)) || sel_isEqual(_cmd, @selector(pressesEnded:withEvent:));
    if (!change) return YES;                              // changed / cancelled: nothing to tell the game
    IMP down = fnkbmPressOrigFor(self, @selector(pressesBegan:withEvent:)), up = fnkbmPressOrigFor(self, @selector(pressesEnded:withEvent:));
    if (!down || !up) return NO;
    KLOG("caps lock: sent to the game as a short press");
    ((void (*)(id, SEL, NSSet *, id))down)(self, @selector(pressesBegan:withEvent:), presses, event);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, NSSet *, id))up)(self, @selector(pressesEnded:withEvent:), presses, event);
    });
    return YES;
}
static void fnkbmHookedPresses(id self, SEL _cmd, NSSet *presses, id event) {
    if (g_fnkbmPressDepth == 0 && fnkbmCapsTap(self, _cmd, presses, event)) return;
    IMP orig = fnkbmPressOrigFor(self, _cmd);
    BOOL began = sel_isEqual(_cmd, @selector(pressesBegan:withEvent:));
    BOOL ended = sel_isEqual(_cmd, @selector(pressesEnded:withEvent:)) || sel_isEqual(_cmd, @selector(pressesCancelled:withEvent:));
    NSMutableSet *pass = nil;
    for (UIPress *p in presses) {
        long code = fnkbmPhysicalKey(p);
        if (!code) continue;
        if (code >= 224 && code <= 231) g_fnkbmModsInProcess = YES;
        if (began && g_fnkbmPressDepth == 0) {
            long t = 0;
            if (!g_fnkbmSynthHeld[code] && fnkbmRemapActive()) t = fnkbmKeyTarget(code);
            // Command: the game takes the key but its bind screen does not accept it.
            // With no bind of its own in the tweak, Left Command is shown to the game
            // as Insert and Right Command as Home, keys a Mac keyboard does not have.
            if (t == 0 && !g_fnkbmSynthHeld[code] && !isTypingModeEnabled) { if (code == 227) t = 73; else if (code == 231) t = 74; }
            g_fnkbmDropped[code] = (t == -1);
            g_fnkbmXlat[code] = (t > 0 && t < 512) ? (uint16_t)t : 0;
            if (t >= 10000 && t < 10200) {
                // Bound to a mouse button: hide the key and press the button.
                g_fnkbmDropped[code] = YES;
                g_fnkbmKeyAsButton[code] = (uint16_t)t;
                _sendDualKeyEvent((GCKeyCode)t, YES);
            }
            if (t != 0) KLOG("key %ld -> %ld (in place)", code, t);
        }
        if (g_fnkbmDropped[code]) { if (!pass) pass = [presses mutableCopy]; [pass removeObject:p]; }
    }
    NSSet *deliver = pass ?: presses;
    BOOL outermostBegan = began && g_fnkbmPressDepth == 0;
    BOOL translated = NO;
    if (outermostBegan) {
        for (UIPress *p in presses) { long code = fnkbmPhysicalKey(p); if (code && g_fnkbmXlat[code]) translated = YES; }
        g_fnkbmXlatRead = NO;
    }
    g_fnkbmPressDepth++;
    if (orig && deliver.count > 0) ((void (*)(id, SEL, NSSet *, id))orig)(self, _cmd, deliver, event);
    g_fnkbmPressDepth--;
    // Safety net: if the game never reads the translated key code, this way of
    // binding cannot work here, so go back to the old swallow-and-resend path.
    if (outermostBegan && translated) {
        static int unread = 0;
        if (g_fnkbmXlatRead) unread = 0;
        else if (++unread >= 3) {
            g_fnkbmKeysInProcess = NO;
            memset(g_fnkbmXlat, 0, sizeof(g_fnkbmXlat));
            memset(g_fnkbmDropped, 0, sizeof(g_fnkbmDropped));
            KLOG("key translation not read by the game: back to the resend path");
        }
    }
    if (ended && g_fnkbmPressDepth == 0) {
        for (UIPress *p in presses) {
            long code = fnkbmPhysicalKey(p);
            if (code && g_fnkbmKeyAsButton[code]) { _sendDualKeyEvent((GCKeyCode)g_fnkbmKeyAsButton[code], NO); g_fnkbmKeyAsButton[code] = 0; }
            if (code) { g_fnkbmXlat[code] = 0; g_fnkbmDropped[code] = NO; }
        }
    }
}
static NSInteger fnkbmHookedKeyCode(id self, SEL _cmd) {
    NSInteger c = g_origUIKeyKeyCode(self, _cmd);
    if (c > 0 && c < 512) { uint16_t t = g_fnkbmXlat[c]; if (t) { g_fnkbmXlatRead = YES; return t; } }
    return c;
}
static NSString *fnkbmHookedCharacters(id self, SEL _cmd) {
    NSString *orig = g_origUIKeyCharacters(self, _cmd);
    NSInteger c = g_origUIKeyKeyCode ? g_origUIKeyKeyCode(self, @selector(keyCode)) : 0;
    if (c <= 0 || c >= 512 || !g_fnkbmXlat[c]) return orig;
    long k = g_fnkbmXlat[c];
    if (k >= 4 && k <= 29) return [NSString stringWithFormat:@"%c", (char)('a' + (k - 4))];
    if (k >= 30 && k <= 38) return [NSString stringWithFormat:@"%c", (char)('1' + (k - 30))];
    if (k == 39) return @"0";
    if (k == 40) return @"\r";
    if (k == 43) return @"\t";
    if (k == 44) return @" ";
    return @"";
}
static void fnkbmInstallKeyTranslation(void) {
    Class keyClass = objc_getClass("UIKey");
    Method mk = keyClass ? class_getInstanceMethod(keyClass, @selector(keyCode)) : NULL;
    Method mc = keyClass ? class_getInstanceMethod(keyClass, @selector(characters)) : NULL;
    if (!mk) { KLOG("key translation off: no UIKey keyCode"); return; }
    g_fnkbmPressOrig = [NSMutableDictionary dictionary];
    SEL sels[4] = { @selector(pressesBegan:withEvent:), @selector(pressesEnded:withEvent:),
                    @selector(pressesCancelled:withEvent:), @selector(pressesChanged:withEvent:) };
    unsigned int n = 0; int hooked = 0;
    const char **names = objc_copyClassNamesForImage(_dyld_get_image_name(0), &n);
    for (unsigned int i = 0; names && i < n; i++) {
        Class c = objc_getClass(names[i]);
        if (!c) continue;
        unsigned int mcount = 0;
        Method *ml = class_copyMethodList(c, &mcount);
        for (unsigned int j = 0; ml && j < mcount; j++) {
            for (int q = 0; q < 4; q++) {
                if (!sel_isEqual(method_getName(ml[j]), sels[q])) continue;
                g_fnkbmPressOrig[[NSString stringWithFormat:@"%p/%s", (void *)c, sel_getName(sels[q])]] =
                    [NSValue valueWithPointer:(void *)method_getImplementation(ml[j])];
                method_setImplementation(ml[j], (IMP)fnkbmHookedPresses);
                hooked++;
                KLOG("key translation: hooked %{public}s %{public}s", names[i], sel_getName(sels[q]));
            }
        }
        free(ml);
    }
    free(names);
    if (hooked == 0) { KLOG("key translation off: the game has no key press methods"); return; }
    g_origUIKeyKeyCode = (NSInteger (*)(id, SEL))method_getImplementation(mk);
    method_setImplementation(mk, (IMP)fnkbmHookedKeyCode);
    if (mc) { g_origUIKeyCharacters = (NSString *(*)(id, SEL))method_getImplementation(mc); method_setImplementation(mc, (IMP)fnkbmHookedCharacters); }
    g_fnkbmKeysInProcess = YES;
    KLOG("key translation on (%d methods)", hooked);
}

// ── Keep running while another app is in front ──────────────────────────
// On losing focus the game is told it is going inactive and into the
// background, and it pauses itself. With this on, those calls are withheld
// (and the matching "back again" calls with them), so the game keeps running.
// The tweak still follows the real focus state for its own input handling.
static BOOL g_fnkbmStayActive = YES;
static NSMutableDictionary<NSString *, NSValue *> *g_fnkbmLifeOrig = nil;
static BOOL g_fnkbmWithheld[2][2] = {{NO, NO}, {NO, NO}};   // [application|scene][inactive|background]

static IMP fnkbmLifeOrigFor(id obj, SEL sel) {
    for (Class c = object_getClass(obj); c; c = class_getSuperclass(c)) {
        NSValue *v = g_fnkbmLifeOrig[[NSString stringWithFormat:@"%p/%s", (void *)c, sel_getName(sel)]];
        if (v) return (IMP)v.pointerValue;
    }
    return NULL;
}
static void fnkbmRealFocus(BOOL active);
static void fnkbmHookedLifecycle(id self, SEL _cmd, id arg) {
    const char *name = sel_getName(_cmd);
    int who = (strncmp(name, "scene", 5) == 0) ? 1 : 0;
    BOOL goesInactive = strstr(name, "WillResignActive") != NULL, goesBackground = strstr(name, "DidEnterBackground") != NULL;
    BOOL comesActive = strstr(name, "DidBecomeActive") != NULL, comesForeground = strstr(name, "WillEnterForeground") != NULL;
    if (goesInactive) fnkbmRealFocus(NO);
    if (comesActive) fnkbmRealFocus(YES);
    if (g_fnkbmStayActive && (goesInactive || goesBackground)) {
        g_fnkbmWithheld[who][goesBackground ? 1 : 0] = YES;
        KLOG("%{public}s withheld, game keeps running", name);
        return;
    }
    if (comesActive && g_fnkbmWithheld[who][0]) { g_fnkbmWithheld[who][0] = NO; KLOG("%{public}s withheld (it never left)", name); return; }
    if (comesForeground && g_fnkbmWithheld[who][1]) { g_fnkbmWithheld[who][1] = NO; KLOG("%{public}s withheld (it never left)", name); return; }
    IMP orig = fnkbmLifeOrigFor(self, _cmd);
    if (orig) ((void (*)(id, SEL, id))orig)(self, _cmd, arg);
}
// Mouse buttons the game believes are held are let go when focus is really lost.
static void fnkbmReleaseHeldForGame(void) {
    for (int slot = 0; slot < FNKBM_BTN_SLOTS; slot++) {
        int code = slot + MOUSE_BUTTON_MIDDLE;
        int i = code == MOUSE_BUTTON_LEFT ? 0 : code == MOUSE_BUTTON_RIGHT ? 1 : code == MOUSE_BUTTON_MIDDLE ? 2 : -1;
        if (i >= 0 && (g_fnkbmFwdPressed[slot] || g_fnkbmFwdValue[slot]) && g_fnkbmGameBtnHandler[i])
            g_fnkbmGameBtnHandler[i](g_fnkbmGameBtn[i], 0.0f, NO);
        g_fnkbmFwdPressed[slot] = NO; g_fnkbmFwdValue[slot] = NO; g_fnkbmKeyDown[slot] = 0;
    }
    for (int i = 0; i < 3; i++) fnkbmGameMouseButton(i == 0 ? MOUSE_BUTTON_LEFT : i == 1 ? MOUSE_BUTTON_RIGHT : MOUSE_BUTTON_MIDDLE, NO);
    rightButtonIsPressed = NO;
}
// The app really left the front, or came back. Driven by the calls above:
// the app-level notifications never arrive here, and the app always reports
// itself active. On leaving, held buttons are let go and a locked cursor is
// handed back, so the other app gets the mouse. On return the cursor follows
// the game's state again.
static void fnkbmRealFocus(BOOL active) {
    if (atomic_exchange(&g_fnkbmRealActive, (bool)active) == (bool)active) return;
    if (!active) {
        fnkbmReleaseHeldForGame();
        BOOL wasLocked = isMouseLocked;
        if (wasLocked) {
            isMouseLocked = NO;
            updateMouseLock(NO, CGPointZero);
            resetControllerState();
        }
        KLOG("focus lost (stay active=%d, cursor was locked=%d)", g_fnkbmStayActive, wasLocked);
    } else {
        KLOG("focus back");
        fnkbmApplyGameCursor("focus back");
    }
}
static void fnkbmInstallStayActive(void) {
    g_fnkbmStayActive = YES;  // no panel to switch it: always on
    g_fnkbmLifeOrig = [NSMutableDictionary dictionary];
    const char *selNames[8] = { "applicationWillResignActive:", "applicationDidEnterBackground:", "applicationWillEnterForeground:", "applicationDidBecomeActive:",
                                "sceneWillResignActive:", "sceneDidEnterBackground:", "sceneWillEnterForeground:", "sceneDidBecomeActive:" };
    unsigned int n = 0; int hooked = 0;
    const char **names = objc_copyClassNamesForImage(_dyld_get_image_name(0), &n);
    for (unsigned int i = 0; names && i < n; i++) {
        Class c = objc_getClass(names[i]);
        if (!c) continue;
        unsigned int mcount = 0;
        Method *ml = class_copyMethodList(c, &mcount);
        for (unsigned int j = 0; ml && j < mcount; j++) {
            const char *mn = sel_getName(method_getName(ml[j]));
            for (int q = 0; q < 8; q++) {
                if (strcmp(mn, selNames[q]) != 0) continue;
                g_fnkbmLifeOrig[[NSString stringWithFormat:@"%p/%s", (void *)c, mn]] = [NSValue valueWithPointer:(void *)method_getImplementation(ml[j])];
                method_setImplementation(ml[j], (IMP)fnkbmHookedLifecycle);
                hooked++;
                KLOG("stay active: hooked %{public}s %{public}s", names[i], mn);
            }
        }
        free(ml);
    }
    free(names);
    KLOG("stay active=%d (%d methods)", g_fnkbmStayActive, hooked);
}

// ── Frame rate unlock ────────────────────────────────────────────────────
// Two things hold the frame rate to the display: the Metal layer waits for
// the display's refresh before showing a frame (vsync), and the game's frame
// pacer releases one frame per display refresh. With the unlock on, the layer
// stops waiting, and the pacer is released far more often than the display
// refreshes. The game may still cap frames with its own limiter; the measured
// rate is logged every few seconds so that can be seen.
static BOOL g_fnkbmFpsUnlock = YES;
static void (*g_origSetDisplaySync)(id, SEL, BOOL) = NULL;
static id (*g_origNextDrawable)(id, SEL) = NULL;
static void (*g_origPacerSignal)(id, SEL, id) = NULL;
static __weak id g_fnkbmLayer = nil;
static id g_fnkbmPacer = nil, g_fnkbmPacerParam = nil;
static SEL g_fnkbmPacerSel = NULL;
static _Atomic long g_fnkbmFrames = 0, g_fnkbmRealSignals = 0, g_fnkbmBoostSignals = 0, g_fnkbmDrawableWait = 0;
static dispatch_source_t g_fnkbmBoostTimer = nil, g_fnkbmFpsLogTimer = nil;
// The game's pacer method is never entered from two threads at once.
static pthread_mutex_t g_fnkbmPacerLock = PTHREAD_MUTEX_INITIALIZER;

// ── Stall detector (diagnostic build) ────────────────────────────────────
// Counts entries and returns of the frame calls this tweak already sits on, plus
// the Metal command buffer's commit and wait calls. When no new frame has been
// asked for in two seconds, it logs which of them is still in progress.
static _Atomic long g_dgNdIn = 0, g_dgNdOut = 0, g_dgNdNil = 0, g_dgPresIn = 0, g_dgPresOut = 0, g_dgCbPresIn = 0, g_dgCbPresOut = 0;
static _Atomic long g_dgCommitIn = 0, g_dgCommitOut = 0, g_dgWaitSIn = 0, g_dgWaitSOut = 0, g_dgWaitCIn = 0, g_dgWaitCOut = 0;
static _Atomic long g_dgSigRealIn = 0, g_dgSigRealOut = 0, g_dgSigBoostIn = 0, g_dgSigBoostOut = 0;
static _Atomic uint64_t g_dgNdTin = 0, g_dgNdTout = 0, g_dgPresT = 0, g_dgCommitT = 0, g_dgSigT = 0, g_dgWaitCT = 0;
static double fnkbmDgMsSince(uint64_t t) {
    if (t == 0) return -1.0;
    static mach_timebase_info_data_t tb; if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)(mach_absolute_time() - t) * tb.numer / tb.denom / 1e6;
}
// ── Frame semaphore watch ────────────────────────────────────────────────
// After it presents a frame, the game's renderer waits without a time limit on a
// semaphore that is released when the previous frame has finished on the graphics
// card. These two system calls are counted for that one semaphore. If that wait
// lasts longer than 400 ms it is released once from here, so the renderer goes on.
// The wait is recognised by where it is called from (present function, 43.10).
#define FNKBM_FS_SITE_OFFSET 0x20dc494UL   // return address of that wait, counted from the start of the game file
static intptr_t (*orig_dsema_wait)(dispatch_semaphore_t, dispatch_time_t) = NULL;
static intptr_t (*orig_dsema_signal)(dispatch_semaphore_t) = NULL;
static _Atomic(void *) g_fsSem = NULL;
static _Atomic uint64_t g_fsWaitStart = 0;   // start of the wait in progress, 0 = none
static _Atomic long g_fsWaitIn = 0, g_fsWaitOut = 0, g_fsSignals = 0, g_fsForced = 0;
static intptr_t hooked_dsema_wait(dispatch_semaphore_t sem, dispatch_time_t timeout) {
    static _Atomic uintptr_t site = 0, notSite = 0;
    uintptr_t ra = (uintptr_t)__builtin_return_address(0);
    if (timeout == DISPATCH_TIME_FOREVER && (ra & 0x3FFF) == (FNKBM_FS_SITE_OFFSET & 0x3FFF) && atomic_load(&site) == 0 && atomic_load(&notSite) != ra) {
        // First time this address is seen: it counts only if it is that place inside the game's own program file.
        Dl_info di;
        if (dladdr((const void *)ra, &di) && di.dli_fbase && ((const struct mach_header_64 *)di.dli_fbase)->filetype == MH_EXECUTE && ra - (uintptr_t)di.dli_fbase == FNKBM_FS_SITE_OFFSET) atomic_store(&site, ra);
        else atomic_store(&notSite, ra);
    }
    if (timeout == DISPATCH_TIME_FOREVER && ra == atomic_load(&site) && ra != 0) {
        atomic_store(&g_fsSem, (__bridge void *)sem);
        atomic_fetch_add(&g_fsWaitIn, 1);
        atomic_store(&g_fsWaitStart, mach_absolute_time());
        intptr_t r = orig_dsema_wait(sem, timeout);
        atomic_store(&g_fsWaitStart, 0);
        atomic_fetch_add(&g_fsWaitOut, 1);
        return r;
    }
    return orig_dsema_wait(sem, timeout);
}
static intptr_t hooked_dsema_signal(dispatch_semaphore_t sem) {
    if ((__bridge void *)sem == atomic_load(&g_fsSem)) atomic_fetch_add(&g_fsSignals, 1);
    return orig_dsema_signal(sem);
}
static void (*g_dgOrigCommit)(id, SEL) = NULL, (*g_dgOrigWaitS)(id, SEL) = NULL, (*g_dgOrigWaitC)(id, SEL) = NULL;
static void dgCommit(id self, SEL _cmd) { atomic_fetch_add(&g_dgCommitIn, 1); atomic_store(&g_dgCommitT, mach_absolute_time()); g_dgOrigCommit(self, _cmd); atomic_fetch_add(&g_dgCommitOut, 1); }
static void dgWaitScheduled(id self, SEL _cmd) { atomic_fetch_add(&g_dgWaitSIn, 1); g_dgOrigWaitS(self, _cmd); atomic_fetch_add(&g_dgWaitSOut, 1); }
static void dgWaitCompleted(id self, SEL _cmd) { atomic_fetch_add(&g_dgWaitCIn, 1); atomic_store(&g_dgWaitCT, mach_absolute_time()); g_dgOrigWaitC(self, _cmd); atomic_fetch_add(&g_dgWaitCOut, 1); }
// Called once with the class of a real command buffer.
static void fnkbmDgHookCommandBuffer(id buffer) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class c = object_getClass(buffer);
        Method a = class_getInstanceMethod(c, NSSelectorFromString(@"commit"));
        Method b = class_getInstanceMethod(c, NSSelectorFromString(@"waitUntilScheduled"));
        Method d = class_getInstanceMethod(c, NSSelectorFromString(@"waitUntilCompleted"));
        if (a) { g_dgOrigCommit = (void (*)(id, SEL))method_getImplementation(a); method_setImplementation(a, (IMP)dgCommit); }
        if (b) { g_dgOrigWaitS = (void (*)(id, SEL))method_getImplementation(b); method_setImplementation(b, (IMP)dgWaitScheduled); }
        if (d) { g_dgOrigWaitC = (void (*)(id, SEL))method_getImplementation(d); method_setImplementation(d, (IMP)dgWaitCompleted); }
        KLOG("stall detector: command buffer class %{public}s, hooks commit=%d waitScheduled=%d waitCompleted=%d", class_getName(c), a != NULL, b != NULL, d != NULL);
    });
}

// ── Low latency frame handling ───────────────────────────────────────────
// A frame the game has finished waits in a queue until the display takes it.
// With three drawables two frames can wait, so what is on screen is up to a
// frame older than it needs to be. With two drawables only one can wait.
// A present that asks for a minimum time on screen, or for a set time, is
// turned into a plain present, so no frame is held back on purpose.
// The time from present to screen is measured and logged.
static BOOL g_fnkbmLowLatency = YES;
static _Atomic long g_fnkbmPresPlain = 0, g_fnkbmPresAfter = 0, g_fnkbmPresAt = 0, g_fnkbmShown = 0, g_fnkbmNotShown = 0;
static _Atomic long g_fnkbmHeldTicks = 0, g_fnkbmHeldN = 0, g_fnkbmToScreenUs = 0, g_fnkbmToScreenMaxUs = 0;
static _Atomic uint64_t g_fnkbmAcquireTick = 0;
static _Atomic int g_fnkbmFullscreen = -1;

// Main thread. Game Mode and direct display only come with real full screen.
static void fnkbmReadFullscreen(void) {
    Class appClass = NSClassFromString(@"NSApplication");
    id app = appClass ? ((id (*)(Class, SEL))objc_msgSend)(appClass, NSSelectorFromString(@"sharedApplication")) : nil;
    if (!app) return;
    id win = ((id (*)(id, SEL))objc_msgSend)(app, NSSelectorFromString(@"mainWindow"));
    if (!win) win = [((NSArray *(*)(id, SEL))objc_msgSend)(app, NSSelectorFromString(@"windows")) firstObject];
    if (!win) return;
    NSUInteger mask = ((NSUInteger (*)(id, SEL))objc_msgSend)(win, NSSelectorFromString(@"styleMask"));
    atomic_store(&g_fnkbmFullscreen, (mask & (1UL << 14)) ? 1 : 0);
}
static void fnkbmInstallLowLatency(void) {
    g_fnkbmLowLatency = NO;
    KLOG("low latency removed: frames and presents are left to the game");
    // Switches in the panel: smoothing and keep-running take effect at once.
    [[NSNotificationCenter defaultCenter] addObserverForName:@"fnkbm.optionsChanged" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        id sm = [d objectForKey:@"fnkbm.mouseSmooth"], st = [d objectForKey:@"fnkbm.stayActive"];
        g_fnkbmMouseSmooth = sm ? [sm boolValue] : YES;
        g_fnkbmStayActive = st ? [st boolValue] : YES;
        KLOG("options changed: smoothing=%d stay active=%d", g_fnkbmMouseSmooth, g_fnkbmStayActive);
    }];
}

static void fnkbmApplyDisplaySync(void) {
    id layer = g_fnkbmLayer;
    if (!layer || !g_origSetDisplaySync) return;
    g_origSetDisplaySync(layer, NSSelectorFromString(@"setDisplaySyncEnabled:"), g_fnkbmFpsUnlock ? NO : YES);
}
static void hooked_setDisplaySync(id self, SEL _cmd, BOOL enabled) {
    static int said = 0;
    if (said < 4) { said++; KLOG("game set display sync=%d, unlock=%d", enabled, g_fnkbmFpsUnlock); }
    g_origSetDisplaySync(self, _cmd, g_fnkbmFpsUnlock ? NO : enabled);
}
static id hooked_nextDrawable(id self, SEL _cmd) {
    if (g_fnkbmLayer != self) {
        g_fnkbmLayer = self;
        NSUInteger had = ((NSUInteger (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"maximumDrawableCount"));
        KLOG("frame layer %p, display sync hook=%d, drawable count %lu -> %lu", self, g_origSetDisplaySync != NULL, (unsigned long)had,
             (unsigned long)((NSUInteger (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"maximumDrawableCount")));
        fnkbmApplyDisplaySync();
    }
    atomic_fetch_add(&g_fnkbmFrames, 1);
    uint64_t t0 = mach_absolute_time();
    atomic_fetch_add(&g_dgNdIn, 1); atomic_store(&g_dgNdTin, t0);
    id drawable = g_origNextDrawable(self, _cmd);
    uint64_t t1 = mach_absolute_time();
    atomic_fetch_add(&g_dgNdOut, 1); atomic_store(&g_dgNdTout, t1); if (!drawable) atomic_fetch_add(&g_dgNdNil, 1);
    atomic_fetch_add(&g_fnkbmDrawableWait, (long)(t1 - t0));
    atomic_store(&g_fnkbmAcquireTick, t1);
    return drawable;
}
static void hooked_pacerSignal(id self, SEL _cmd, id param) {
    g_fnkbmPacer = self; g_fnkbmPacerParam = param; g_fnkbmPacerSel = _cmd;
    atomic_fetch_add(&g_fnkbmRealSignals, 1);
    atomic_fetch_add(&g_dgSigRealIn, 1); atomic_store(&g_dgSigT, mach_absolute_time());
    pthread_mutex_lock(&g_fnkbmPacerLock);
    g_origPacerSignal(self, _cmd, param);
    pthread_mutex_unlock(&g_fnkbmPacerLock);
    atomic_fetch_add(&g_dgSigRealOut, 1);
}
// Frame rate unlock, part 3: the game presents each frame with "stay on screen
// for at least 1/120 s". That alone holds it to 120. With the unlock on, such a
// present (and a present at a set time) becomes a plain present.
static void (*g_origDrawablePresent)(id, SEL) = NULL;
static void (*g_origDrawablePresentAfter)(id, SEL, CFTimeInterval) = NULL;
static void (*g_origDrawablePresentAt)(id, SEL, CFTimeInterval) = NULL;
static __thread int t_fnkbmPresentDepth = 0;   // one present method may call another
static void hooked_drawablePresent(id self, SEL _cmd) {
    BOOL outer0 = (t_fnkbmPresentDepth++ == 0);
    if (outer0) { atomic_fetch_add(&g_fnkbmPresPlain, 1); atomic_fetch_add(&g_dgPresIn, 1); atomic_store(&g_dgPresT, mach_absolute_time()); }
    g_origDrawablePresent(self, _cmd);
    if (outer0) atomic_fetch_add(&g_dgPresOut, 1);
    t_fnkbmPresentDepth--;
}
static void hooked_drawablePresentAfter(id self, SEL _cmd, CFTimeInterval duration) {
    BOOL outer = (t_fnkbmPresentDepth++ == 0);
    if (outer) { atomic_fetch_add(&g_fnkbmPresAfter, 1); atomic_fetch_add(&g_dgPresIn, 1); atomic_store(&g_dgPresT, mach_absolute_time()); }
    if (outer && g_fnkbmFpsUnlock) g_origDrawablePresent(self, NSSelectorFromString(@"present"));
    else g_origDrawablePresentAfter(self, _cmd, duration);
    if (outer) atomic_fetch_add(&g_dgPresOut, 1);
    t_fnkbmPresentDepth--;
}
static void hooked_drawablePresentAt(id self, SEL _cmd, CFTimeInterval when) {
    BOOL outer = (t_fnkbmPresentDepth++ == 0);
    if (outer) { atomic_fetch_add(&g_fnkbmPresAt, 1); atomic_fetch_add(&g_dgPresIn, 1); atomic_store(&g_dgPresT, mach_absolute_time()); }
    if (outer && g_fnkbmFpsUnlock) g_origDrawablePresent(self, NSSelectorFromString(@"present"));
    else g_origDrawablePresentAt(self, _cmd, when);
    if (outer) atomic_fetch_add(&g_dgPresOut, 1);
    t_fnkbmPresentDepth--;
}
static void fnkbmSetFpsUnlock(BOOL on, const char *why) {
    g_fnkbmFpsUnlock = on;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kFnKbmFpsUnlockKey];
    fnkbmApplyDisplaySync();
    KLOG("fps unlock=%d (%{public}s)", on, why);
}
static void fnkbmInstallFpsUnlock(void) {
    id saved = [[NSUserDefaults standardUserDefaults] objectForKey:kFnKbmFpsUnlockKey];
    (void)saved;
    g_fnkbmFpsUnlock = YES;  // test build: always on, there is no key or panel to switch it
    Class drawableClass = objc_getClass("CAMetalDrawable");
    Method p0 = drawableClass ? class_getInstanceMethod(drawableClass, NSSelectorFromString(@"present")) : NULL;
    Method p1 = drawableClass ? class_getInstanceMethod(drawableClass, NSSelectorFromString(@"presentAfterMinimumDuration:")) : NULL;
    Method p2 = drawableClass ? class_getInstanceMethod(drawableClass, NSSelectorFromString(@"presentAtTime:")) : NULL;
    if (p0 && p1 && p2) {
        g_origDrawablePresent = (void (*)(id, SEL))method_getImplementation(p0); method_setImplementation(p0, (IMP)hooked_drawablePresent);
        g_origDrawablePresentAfter = (void (*)(id, SEL, CFTimeInterval))method_getImplementation(p1); method_setImplementation(p1, (IMP)hooked_drawablePresentAfter);
        g_origDrawablePresentAt = (void (*)(id, SEL, CFTimeInterval))method_getImplementation(p2); method_setImplementation(p2, (IMP)hooked_drawablePresentAt);
    }
    KLOG("fps unlock: present hooks=%d", g_origDrawablePresent != NULL);
    Class layerClass = objc_getClass("CAMetalLayer");
    Method m = class_getInstanceMethod(layerClass, NSSelectorFromString(@"setDisplaySyncEnabled:"));
    if (m) { g_origSetDisplaySync = (void (*)(id, SEL, BOOL))method_getImplementation(m); method_setImplementation(m, (IMP)hooked_setDisplaySync); }
    Method n = class_getInstanceMethod(layerClass, NSSelectorFromString(@"nextDrawable"));
    if (n) { g_origNextDrawable = (id (*)(id, SEL))method_getImplementation(n); method_setImplementation(n, (IMP)hooked_nextDrawable); }
    Class pacerClass = objc_getClass("FIOSFramePacer");
    Method p = pacerClass ? class_getInstanceMethod(pacerClass, NSSelectorFromString(@"signal:")) : NULL;
    if (p) { g_origPacerSignal = (void (*)(id, SEL, id))method_getImplementation(p); method_setImplementation(p, (IMP)hooked_pacerSignal); }
    KLOG("fps unlock=%d hooks: displaySync=%d nextDrawable=%d pacer=%d", g_fnkbmFpsUnlock, m != NULL, n != NULL, p != NULL);

    // Extra pacer releases, about one per millisecond, while the unlock is on.
    dispatch_queue_t bq = dispatch_queue_create("fnkbm.pacerboost", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    g_fnkbmBoostTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, bq);
    dispatch_source_set_timer(g_fnkbmBoostTimer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), NSEC_PER_MSEC, 0);
    dispatch_source_set_event_handler(g_fnkbmBoostTimer, ^{
        BOOL unfocusedRun = g_fnkbmStayActive && !atomic_load(&g_fnkbmRealActive);
        if ((!g_fnkbmFpsUnlock && !unfocusedRun) || !g_origPacerSignal) return;
        id pacer = g_fnkbmPacer, param = g_fnkbmPacerParam;
        if (!pacer || !g_fnkbmPacerSel) return;
        atomic_fetch_add(&g_dgSigBoostIn, 1);
        pthread_mutex_lock(&g_fnkbmPacerLock);
        g_origPacerSignal(pacer, g_fnkbmPacerSel, param);
        pthread_mutex_unlock(&g_fnkbmPacerLock);
        atomic_fetch_add(&g_dgSigBoostOut, 1);
        atomic_fetch_add(&g_fnkbmBoostSignals, 1);
    });
    dispatch_resume(g_fnkbmBoostTimer);

    // Frame semaphore watch: every 50 ms. A wait older than 400 ms is released once.
    static dispatch_source_t fsTimer;
    fsTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, dispatch_queue_create("fnkbm.framesem", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0)));
    dispatch_source_set_timer(fsTimer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 50 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(fsTimer, ^{
        static uint64_t released = 0;
        uint64_t ws = atomic_load(&g_fsWaitStart);
        if (ws == 0 || ws == released || !orig_dsema_signal) return;
        double ms = fnkbmDgMsSince(ws);
        if (ms < 400.0) return;
        void *sem = atomic_load(&g_fsSem);
        if (!sem || atomic_load(&g_fsWaitStart) != ws) return;
        released = ws;
        long n = atomic_fetch_add(&g_fsForced, 1) + 1;
        long in = atomic_load(&g_fsWaitIn), sig = atomic_load(&g_fsSignals);
        orig_dsema_signal((__bridge dispatch_semaphore_t)sem);
        if (n <= 30 || (n % 50) == 0) KLOG("FRAME SEMAPHORE: wait %ld had lasted %.0f ms with no release (releases seen so far %ld); released from the tweak, time %ld", in, ms, sig, n);
    });
    dispatch_resume(fsTimer);

    // Stall detector: twice a second, looks whether a new frame was asked for.
    static dispatch_source_t dgTimer;
    dgTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(dgTimer, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), NSEC_PER_SEC / 2, NSEC_PER_SEC / 20);
    dispatch_source_set_event_handler(dgTimer, ^{
        static long lastIn = -1; static int quiet = 0, reports = 0;
        long in = atomic_load(&g_dgNdIn);
        if (in != lastIn) { if (reports) KLOG("STALL over: frames are being asked for again"); lastIn = in; quiet = 0; reports = 0; return; }
        quiet++;
        if (in < 300 || reports >= 3 || (quiet != 4 && quiet != 14 && quiet != 40)) return;   // at 2 s, 7 s and 20 s without a frame
        reports++;
        long ndOut = atomic_load(&g_dgNdOut);
        id layer = g_fnkbmLayer; int sync = -1, timeout = -1, trans = -1; unsigned long count = 0; CGSize size = CGSizeZero;
        if (layer) {
            sync = (int)((BOOL (*)(id, SEL))objc_msgSend)(layer, NSSelectorFromString(@"displaySyncEnabled"));
            timeout = (int)((BOOL (*)(id, SEL))objc_msgSend)(layer, NSSelectorFromString(@"allowsNextDrawableTimeout"));
            trans = (int)((BOOL (*)(id, SEL))objc_msgSend)(layer, NSSelectorFromString(@"presentsWithTransaction"));
            count = (unsigned long)((NSUInteger (*)(id, SEL))objc_msgSend)(layer, NSSelectorFromString(@"maximumDrawableCount"));
            size = ((CGSize (*)(id, SEL))objc_msgSend)(layer, NSSelectorFromString(@"drawableSize"));
        }
        KLOG("STALL %d: no new frame for %.1f s. In progress now: nextDrawable=%ld drawablePresent=%ld bufferPresent=%ld commit=%ld waitScheduled=%ld waitCompleted=%ld pacerDisplay=%ld pacerExtra=%ld",
             reports, quiet / 2.0, in - ndOut, atomic_load(&g_dgPresIn) - atomic_load(&g_dgPresOut), atomic_load(&g_dgCbPresIn) - atomic_load(&g_dgCbPresOut),
             atomic_load(&g_dgCommitIn) - atomic_load(&g_dgCommitOut), atomic_load(&g_dgWaitSIn) - atomic_load(&g_dgWaitSOut), atomic_load(&g_dgWaitCIn) - atomic_load(&g_dgWaitCOut),
             atomic_load(&g_dgSigRealIn) - atomic_load(&g_dgSigRealOut), atomic_load(&g_dgSigBoostIn) - atomic_load(&g_dgSigBoostOut));
        KLOG("STALL %d totals: nextDrawable asked=%ld returned=%ld nil=%ld, drawable presents=%ld, buffer presents=%ld, commits=%ld, waitCompleted=%ld, pacer display=%ld extra=%ld",
             reports, in, ndOut, atomic_load(&g_dgNdNil), atomic_load(&g_dgPresOut), atomic_load(&g_dgCbPresOut), atomic_load(&g_dgCommitOut), atomic_load(&g_dgWaitCOut),
             atomic_load(&g_dgSigRealOut), atomic_load(&g_dgSigBoostOut));
        KLOG("STALL %d ms since last: nextDrawable asked=%.0f returned=%.0f, drawable present=%.0f, commit=%.0f, waitCompleted=%.0f, pacer display signal=%.0f",
             reports, fnkbmDgMsSince(atomic_load(&g_dgNdTin)), fnkbmDgMsSince(atomic_load(&g_dgNdTout)), fnkbmDgMsSince(atomic_load(&g_dgPresT)),
             fnkbmDgMsSince(atomic_load(&g_dgCommitT)), fnkbmDgMsSince(atomic_load(&g_dgWaitCT)), fnkbmDgMsSince(atomic_load(&g_dgSigT)));
        uint64_t fsStart = atomic_load(&g_fsWaitStart);
        KLOG("STALL %d frame semaphore: hooks wait=%d signal=%d, wait in progress=%d for %.0f ms, waits started=%ld returned=%ld, releases seen=%ld, released from the tweak=%ld",
             reports, orig_dsema_wait != NULL, orig_dsema_signal != NULL, fsStart != 0, fsStart ? fnkbmDgMsSince(fsStart) : 0.0,
             atomic_load(&g_fsWaitIn), atomic_load(&g_fsWaitOut), atomic_load(&g_fsSignals), atomic_load(&g_fsForced));
        KLOG("STALL %d layer: display sync=%d, drawables=%lu, nextDrawable timeout allowed=%d, presents with transaction=%d, size=%.0fx%.0f; unlock=%d, in front=%d, cursor locked=%d",
             reports, sync, count, timeout, trans, size.width, size.height, g_fnkbmFpsUnlock, (int)atomic_load(&g_fnkbmRealActive), isMouseLocked);
    });
    dispatch_resume(dgTimer);

    // Measured frame rate, every five seconds while frames are being drawn.
    g_fnkbmFpsLogTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(g_fnkbmFpsLogTimer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(g_fnkbmFpsLogTimer, ^{
        long f = atomic_exchange(&g_fnkbmFrames, 0), r = atomic_exchange(&g_fnkbmRealSignals, 0), b = atomic_exchange(&g_fnkbmBoostSignals, 0);
        long w = atomic_exchange(&g_fnkbmDrawableWait, 0);
        if (f == 0) return;
        static mach_timebase_info_data_t tb; if (tb.denom == 0) mach_timebase_info(&tb);
        double waitMs = (double)w * tb.numer / tb.denom / 1e6 / (double)f;
        long ge = atomic_exchange(&g_fnkbmGcEvents, 0), hv = atomic_exchange(&g_fnkbmHidValues, 0), hf = atomic_exchange(&g_fnkbmHidForwarded, 0);
        id syncLayer = g_fnkbmLayer; SEL syncSel = NSSelectorFromString(@"displaySyncEnabled");
        int syncNow = (syncLayer && [syncLayer respondsToSelector:syncSel]) ? (int)((BOOL (*)(id, SEL))objc_msgSend)(syncLayer, syncSel) : -1;
        static long fsLastForced = 0; long fsForced = atomic_load(&g_fsForced);
        if (fsForced != fsLastForced || atomic_load(&g_fsWaitIn) == 0) { KLOG("frame semaphore over 5s: waits so far=%ld, releases seen=%ld, released from the tweak=%ld (new %ld)", atomic_load(&g_fsWaitIn), atomic_load(&g_fsSignals), fsForced, fsForced - fsLastForced); fsLastForced = fsForced; }
        KLOG("fps=%.0f over 5s (unlock=%d, display sync now=%d, pacer releases per second: display=%.0f extra=%.0f, wait for a frame slot=%.2f ms)", f / 5.0, g_fnkbmFpsUnlock, syncNow, r / 5.0, b / 5.0, waitMs);
        long hn = atomic_exchange(&g_fnkbmHeldN, 0), ht = atomic_exchange(&g_fnkbmHeldTicks, 0);
        long sh = atomic_exchange(&g_fnkbmShown, 0), ns = atomic_exchange(&g_fnkbmNotShown, 0), su = atomic_exchange(&g_fnkbmToScreenUs, 0), smax = atomic_exchange(&g_fnkbmToScreenMaxUs, 0);
        long pp = atomic_exchange(&g_fnkbmPresPlain, 0), pa = atomic_exchange(&g_fnkbmPresAfter, 0), pt = atomic_exchange(&g_fnkbmPresAt, 0);
        KLOG("frame timing over 5s: held before present=%.2f ms, present to screen=%.2f ms (longest %.2f), shown=%ld, not shown=%ld, presents plain=%ld min-duration=%ld timed=%ld, low latency=%d, fullscreen=%d, borderless=%d",
             hn ? (double)ht * tb.numer / tb.denom / 1e6 / (double)hn : 0.0, sh ? (double)su / 1000.0 / (double)sh : 0.0, (double)smax / 1000.0, sh, ns, pp, pa, pt,
             g_fnkbmLowLatency, atomic_load(&g_fnkbmFullscreen), isBorderlessModeEnabled);
        dispatch_async(dispatch_get_main_queue(), ^{ fnkbmReadFullscreen(); });
        long fd = atomic_exchange(&g_fnkbmFeedDirect, 0), fh = atomic_exchange(&g_fnkbmFeedHeld, 0);
        if (ge || hv) KLOG("mouse over 5s: GameController events=%ld, device values=%ld, device values passed to game=%ld, report interval=%.1f ms, smoothed=%ld, straight through=%ld, focused=%d", ge, hv, hf, g_fnkbmSmooth.interval, fh, fd, (int)atomic_load(&g_fnkbmRealActive));
    });
    dispatch_resume(g_fnkbmFpsLogTimer);
}

%ctor {
    // Swizzle isiOSAppOnMac and isiOSAppOnMic for both NSProcessInfo and its Swift subclass _NSSwiftProcessInfo
    swizzleIsiOSAppOnMac(objc_getClass("NSProcessInfo"));
    swizzleIsiOSAppOnMac(objc_getClass("_NSSwiftProcessInfo"));
    swizzleIsiOSAppOnMic(objc_getClass("NSProcessInfo"));
    swizzleIsiOSAppOnMic(objc_getClass("_NSSwiftProcessInfo"));
    swizzleIsMacCatalystApp(objc_getClass("NSProcessInfo"));
    swizzleIsMacCatalystApp(objc_getClass("_NSSwiftProcessInfo"));

    // LEVEL 15: Total Dominance Performance Suite
    // We initialize this immediately to kill App Nap and elevate priority before the engine loads.
    [[PerformanceGuard sharedInstance] startHyperPerformanceMode];
    [[PerformanceGuard sharedInstance] elevateProcessPriority];
    
    // Force P-Core Affinity for the main thread
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

    setupHIDManager();
    
    // Initialize Gyro-Mouse Proxy hooks
    ue_init_gyro_hooks();

    // Dynamic Linker Stealth Initialization
    Dl_info our_info;
    if (dladdr((const void *)swizzleIsiOSAppOnMac, &our_info)) {
        g_our_header = (const struct mach_header *)our_info.dli_fbase;
    }

    // Fishhook for device spoofing + macOS 26.4 crash fix + EU marketplace bypass + Sandbox sysctl virtualization + dyld hiding
    struct rebinding rebindings[] = {
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
        {"fclose", (void *)hooked_fclose, (void **)&orig_fclose},
        {"dispatch_semaphore_wait", (void *)hooked_dsema_wait, (void **)&orig_dsema_wait},
        {"dispatch_semaphore_signal", (void *)hooked_dsema_signal, (void **)&orig_dsema_signal}
    };
    rebind_symbols(rebindings, 19);

    NSString* currentVersion = @"6.0.0";
    NSString* lastVersion = [[NSUserDefaults standardUserDefaults] stringForKey:@"fnmactweak.lastSeenVersion"];

    if (!lastVersion || ![lastVersion isEqualToString:currentVersion]) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kKeyRemapKey];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"fnmactweak.welcomeSeenVersion"];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"fnmactweak.welcomeSuppressed"];
        [[NSUserDefaults standardUserDefaults] setObject:currentVersion forKey:@"fnmactweak.lastSeenVersion"];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];



    NSData *bookmark = [[NSUserDefaults standardUserDefaults] dataForKey:@"fnmactweak.datafolder"];
    if (bookmark) {
        BOOL stale = NO;
        NSError *error = nil;
        NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark
                                               options:NSURLBookmarkResolutionWithoutUI
                                         relativeToURL:nil
                                   bookmarkDataIsStale:&stale
                                                 error:&error];
        if (url) {
            [url startAccessingSecurityScopedResource];
        }
    }

    TRIGGER_KEY = GCKeyCodeLeftAlt;
    // POPUP_KEY = GCKeyCodeKeyP; // Removed as requested
    
    loadTweakSettings();

    recalculateSensitivities();
    loadKeyRemappings();
    loadFortniteKeybinds();
    loadControllerMappings();
    KLOG("tweak loaded build=%{public}s ctrl=%d always=%d sens=%.0f/%.0f ads=%.0f keys typing=%ld lock=%ld panel=%ld",
         __DATE__ " " __TIME__, isControllerModeEnabled, NATIVE_ALWAYS_ON, NATIVE_SENS_X, NATIVE_SENS_Y, NATIVE_ADS_SENS,
         (long)FNKBM_KEY_TYPING, (long)FNKBM_KEY_LOCK, (long)FNKBM_KEY_PANEL);
    KLOG("fps key=%ld", (long)FNKBM_KEY_FPS);
    fnkbmWriteInputIni();
    fnkbmCleanOldConfig();
    fnkbmLogBinds("launch");
    fnkbmStartLogFollower();
    fnkbmInstallFpsUnlock();
    fnkbmInstallLowLatency();
    fnkbmInstallKeyTranslation();
    fnkbmInstallStayActive();
    fnkbmInstallMouseSmooth();
#ifdef FNKBM_DEBUG
    fnkbmDebugInstall();
#endif

    // Install OS-level mouse button tap (Deeper than NSEvent monitor)
    void *cgHandle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW);
    if (cgHandle) {
        _CGEventTapCreate = (CFMachPortRef (*)(int, int, int, uint64_t, CGEventTapCallBack, void *))dlsym(cgHandle, "CGEventTapCreate");
        _CGEventTapEnable = (void (*)(CFMachPortRef, bool))dlsym(cgHandle, "CGEventTapEnable");
        _CGEventSetType = (void (*)(CGEventRef, uint32_t))dlsym(cgHandle, "CGEventSetType");
        _CGEventCreateMouseEvent = (CGEventRef (*)(void *, uint32_t, CGPoint, int))dlsym(cgHandle, "CGEventCreateMouseEvent");
    }

    if (_CGEventTapCreate && _CGEventTapEnable) {
        uint64_t keyboardMask = (1ULL << 10) | (1ULL << 11) | (1ULL << 12); // KeyDown, KeyUp, FlagsChanged
        uint64_t mouseMask = (1ULL << kCGEventOtherMouseDown) | (1ULL << kCGEventOtherMouseUp) | (1ULL << kCGEventOtherMouseDragged);
        CFMachPortRef eventTap = _CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                                  keyboardMask | mouseMask,
                                                  mouseButtonTapCallback, NULL);
        if (eventTap) {
            fnm_eventTap = eventTap;
            CFRunLoopSourceRef runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0);
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
            _CGEventTapEnable(eventTap, true);
        }
    }

    for (NSNotificationName name in @[GCControllerDidConnectNotification, GCControllerDidDisconnectNotification]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *notification) {
                handleControllerNotification(notification);
            }];
    }

    // ── GCVirtualController — connect after UIKit is ready ───────────────────
    // Required for controller-mode button/stick/trigger dispatching.
    // cfg.elements must include every button we ever want to drive.
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        
        // LEVEL 10: App Focus Transition Guard
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull focusNote) {
            resetControllerState();
        }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // No virtual gamepad unless controller mode is on. A connected
            // pad makes the game switch away from keyboard-and-mouse mode.
            // Turning controller mode on takes effect at the next launch.
            if (!isControllerModeEnabled) return;
            if (@available(iOS 15, *)) {
                g_controllerLifecycleStarted = YES;
                fnRefreshVirtualController();
                g_inputPulseHelper = [[FnInputPulse alloc] init];
                CADisplayLink *displayLink = [CADisplayLink displayLinkWithTarget:g_inputPulseHelper selector:@selector(onDisplayTick:)];
                [displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

                // --- STEALTH COMPOSITOR WINDOW (Level 5 Full-Screen Shield) ---
                // Forces macOS to stay in Composited Mode even in Fullscreen
                if (!stealthCompositorWindow) {
                    UIWindowScene *activeScene = (UIWindowScene *)[[UIApplication sharedApplication].connectedScenes anyObject];
                    if (activeScene) {
                        stealthCompositorWindow = [[UIWindow alloc] initWithWindowScene:activeScene];
                        stealthCompositorWindow.frame = activeScene.screen.bounds;
                        stealthCompositorWindow.windowLevel = UIWindowLevelStatusBar + 1000;
                        stealthCompositorWindow.backgroundColor = [UIColor clearColor];
                        stealthCompositorWindow.alpha = 0.01;
                        stealthCompositorWindow.userInteractionEnabled = NO;
                        stealthCompositorWindow.hidden = NO;
                    }
                }

                // --- ELITE ACTIVITY LOCKER & OVERCLOCK ---
                // Disables App Nap, prevents throttling, and sets highest process priority
                if (!g_backgroundActivityToken) {
                    // Options: UserInitiated (0xFF) | LatencyCritical | IdleSleepDisabled | DisplaySleepDisabled
                    uint64_t options = 0x000000FF | 0x0000000100000000ULL | 0x0000000800000000ULL | 0x0000004000000000ULL;
                    g_backgroundActivityToken = [[NSProcessInfo processInfo] beginActivityWithOptions:options
                                                                                           reason:@"Elite Gaming Overclock"];
                    
                    // Set UNIX process priority to -20 (Highest VIP priority)
                    setpriority(PRIO_PROCESS, 0, -20);
                }
            }
        });
    }];


    isBorderlessModeEnabled = [tweakDefaults() boolForKey:kBorderlessWindowKey];
    // The NSWindow hook handles styling before the window appears.
    // For positioning, we listen for the window becoming key — this fires once
    // the window is fully on screen and settled, with no race condition.
    // We unregister immediately after the first fire so it never runs again.
    if (isBorderlessModeEnabled) {
        id __block observer = [[NSNotificationCenter defaultCenter]
            addObserverForName:NSNotificationName(@"NSWindowDidBecomeKeyNotification")
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
                        [[NSNotificationCenter defaultCenter] removeObserver:observer];
                        observer = nil;
                        updateBorderlessMode();
                    }];
    }

    // ─────────────────────────────────────────────────────────────────────
    // Bypasses GCKit entirely to catch true hardware scroll ticks/keys.
    Class nsEventClass = NSClassFromString(@"NSEvent");
    if (nsEventClass) {
        // ── Keyboard/Scroll Remapping Root-Level Support ────────────────────
        if (!_CGEventPost) {
            void *cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW);
            if (cg) {
                _CGEventCreateKeyboardEvent = (CGEventRef(*)(void*,uint16_t,bool))dlsym(cg, "CGEventCreateKeyboardEvent");
                _CGEventSetFlags = (void(*)(CGEventRef,CGEventFlags))dlsym(cg, "CGEventSetFlags");
                _CGEventGetFlags = (CGEventFlags(*)(CGEventRef))dlsym(cg, "CGEventGetFlags");
                _CGEventPost = (void(*)(int,CGEventRef))dlsym(cg, "CGEventPost");
                _CGEventSetIntegerValueField = (void(*)(CGEventRef,int,int64_t))dlsym(cg, "CGEventSetIntegerValueField");
                _CGEventGetIntegerValueField = (int64_t(*)(CGEventRef,int))dlsym(cg, "CGEventGetIntegerValueField");
                _CGEventGetDoubleValueField = (double(*)(CGEventRef,int))dlsym(cg, "CGEventGetDoubleValueField");
                _CGEventSetDoubleValueField = (void(*)(CGEventRef,int,double))dlsym(cg, "CGEventSetDoubleValueField");
                _CGEventGetTimestamp = (CGEventTimestamp(*)(CGEventRef))dlsym(cg, "CGEventGetTimestamp");
                _CGEventKeyboardGetUnicodeString = (void(*)(CGEventRef,UniCharCount,UniCharCount*,UniChar[]))dlsym(cg, "CGEventKeyboardGetUnicodeString");
                _CGEventKeyboardSetUnicodeString = (void(*)(CGEventRef,UniCharCount,const UniChar[]))dlsym(cg, "CGEventKeyboardSetUnicodeString");
            }
        }

        static BOOL gcToNSVKInitialized = NO;
        if (!gcToNSVKInitialized) {
            memset(gcToNSVK, 0, sizeof(gcToNSVK));
            for (int i = 0; i < 128; i++) {
                if (nsVKToGC[i] != 0 && nsVKToGC[i] < 256) gcToNSVK[nsVKToGC[i]] = (uint16_t)i;
            }
            gcToNSVKInitialized = YES;
        }

        static SEL keyCodeSel2  = NULL;
        static SEL modFlagsSel2 = NULL;
        static SEL typeSel3     = NULL;
        if (!keyCodeSel2)  keyCodeSel2  = NSSelectorFromString(@"keyCode");
        if (!modFlagsSel2) modFlagsSel2 = NSSelectorFromString(@"modifierFlags");
        if (!typeSel3)     typeSel3     = NSSelectorFromString(@"type");

        // Added (1ULL << 25) | (1ULL << 26) for OtherMouse events (M3, M4, etc)
        unsigned long long keyMask = (1ULL << 1) | (1ULL << 2) | (1ULL << 3) | (1ULL << 4) | (1ULL << 5) | (1ULL << 6) | (1ULL << 7) | (1ULL << 8) | (1ULL << 10) | (1ULL << 11) | (1ULL << 12) | (1ULL << 25) | (1ULL << 26);

        // Use performSelector since we don't have AppKit headers imported.
        // Equivalent to:
        // [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel handler:...]
        // NSEventMaskScrollWheel = 1ULL << 22
        unsigned long long scrollMask = 1ULL << 22;
        
        // Cache the SEL once — NSSelectorFromString does a string hash lookup,
        // no need to repeat it on every scroll event.
        static SEL scrollingDeltaYSel = NULL;
        if (!scrollingDeltaYSel) scrollingDeltaYSel = NSSelectorFromString(@"scrollingDeltaY");

        id (^handlerBlock)(id) = ^id (id event) {
            static dispatch_once_t once;
            dispatch_once(&once, ^{ elevateThreadToRealTime(); });
            // Safety: Only handle if app is active
            if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return event;

            // Use objc_msgSend directly — avoids NSInvocation alloc on every scroll tick.
            if (![event respondsToSelector:scrollingDeltaYSel]) return event;
            CGFloat deltaY = ((CGFloat(*)(id, SEL))objc_msgSend)(event, scrollingDeltaYSel);

            if (deltaY == 0) return event;

            // macOS deltaY is positive for UP, negative for DOWN
            int scrollCode = (deltaY > 0) ? MOUSE_SCROLL_UP : MOUSE_SCROLL_DOWN;
            int idx = scrollCode - MOUSE_SCROLL_UP;
            
            GCKeyCode kc = (idx >= 0 && idx < MOUSE_SCROLL_COUNT) ? mouseScrollRemapArray[idx] : 0;
            // Fall back to Fortnite default keybind if no advanced remap is set
            if (kc == 0 && idx >= 0 && idx < MOUSE_SCROLL_COUNT)
                kc = mouseScrollFortniteArray[idx];
            
            // Check unified Keybinds tab mappings
            if (kc == 0 && scrollCode < 10200)
                kc = fortniteRemapArray[scrollCode];
            
            // PRIORITY 1: Handle User UI overrides (Capture Mode)
            // Even if the mouse is unlocked (we are in the Tweak Settings Menu),
            // this needs to be able to catch the scroll direction!
            if (mouseButtonCaptureCallback != nil || keyCaptureCallback != nil) {
              if (mouseButtonCaptureCallback) mouseButtonCaptureCallback(scrollCode);
              else if (keyCaptureCallback) keyCaptureCallback((GCKeyCode)scrollCode);
              return nil;
            }

            // PRIORITY 2: TYPING MODE bypass
            if (isTypingModeEnabled) return event;

            // PRIORITY 3: CONTROLLER MODE mapping
            if (isControllerModeEnabled && !isPopupVisible) {
                BOOL isMappedToController = NO;
                
                // Elite: O(1) Zero-Alloc Bitmask Lookup
                if (scrollCode > 0 && scrollCode < 10240) {
                    uint32_t mask = g_vctrlReverseMap[scrollCode] | g_vctrlCustomMap[scrollCode];
                    while (mask) {
                        int i = __builtin_ctz(mask);
                        isMappedToController = YES;
                        if (isMouseLocked || isTriggerHeld) {
                             dispatchControllerButton(i, YES, NO);
                             NSUInteger revision = g_controllerRevision;
                             dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.015 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                 if (revision == g_controllerRevision) dispatchControllerButton(i, NO, NO);
                             });
                        }
                        mask &= ~(1 << i);
                    }
                }
                
                if (isMappedToController) return nil; // Always consume if remapped to controller
            }

            // PRIORITY 3: KEYBOARD/ACTION mapping
            // If a keybind is mapped for this scroll direction, ALWAYS consume the
            // hardware event — never let raw scroll reach GCKit even when unlocked.
            // Exception: if the P settings panel is open, let scroll through.
            if (kc != 0 && !isPopupVisible && isMouseLocked) {   // cursor free: falls through to the menu path below
                if (isMouseLocked) {
                    // Inject with a small delay to ensure game registers the press (Rapid Fire)
                    _sendDualKeyEvent(kc, YES);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        _sendDualKeyEvent(kc, NO);
                    });
                }
                return nil; // consume remapped scroll
            }

            // Cursor free, tweak panel closed: the wheel also goes to the game's own
            // scroll handler, so its "press a key" prompt can bind wheel up and down.
            if (!isMouseLocked) {
                if (!isPopupVisible && NATIVE_ALWAYS_ON && !isControllerModeEnabled) {
                    GCMouse *menuMouse = GCMouse.current;
                    GCControllerDirectionPad *menuPad = menuMouse.mouseInput.scroll;
                    if (menuPad && menuPad.valueChangedHandler) {
                        g_fnkbmMenuScroll = YES;
                        menuPad.valueChangedHandler(menuPad, 0.0f, (deltaY > 0) ? 1.0f : -1.0f);
                        menuPad.valueChangedHandler(menuPad, 0.0f, 0.0f);
                        g_fnkbmMenuScroll = NO;
                    }
                }
                return event;
            }

            // PRIORITY 3: Handle Raw Unmapped Game Scroll (Zero Delay)
            // Only reached when kc == 0 for this direction.
            // Check only this direction — don't block the other unbound direction.
            if (idx >= 0 && idx < MOUSE_SCROLL_COUNT) {
                if (mouseScrollRemapArray[idx] != 0 || mouseScrollFortniteArray[idx] != 0) return nil;
            }

            GCMouse *currentMouse = GCMouse.current;
            if (currentMouse && currentMouse.mouseInput) {
                GCControllerDirectionPad *scrollPad = currentMouse.mouseInput.scroll;
                if (scrollPad && scrollPad.valueChangedHandler) {
                    float yVal = (deltaY > 0) ? 1.0f : -1.0f;
                    
                    // Dispatch directly to the game synchronously
                    scrollPad.valueChangedHandler(scrollPad, 0.0f, yVal);
                    
                    // Reset internal state to ensure game logic doesn't drop it internally
                    if ([scrollPad.yAxis respondsToSelector:@selector(setValue:)]) {
                        [scrollPad.yAxis setValue:0.0f];
                    }
                    
                    // Send an immediate center (0.0) tick so the game engine recognizes
                    // it as a distinct discrete toggle rather than a held input.
                    scrollPad.valueChangedHandler(scrollPad, 0.0f, 0.0f);
                }
            }

            // Consume the original GCKit event off the native layer so we don't double-fire
            return nil;
        };
        
        SEL addMonitorSel = NSSelectorFromString(@"addLocalMonitorForEventsMatchingMask:handler:");
        if ([nsEventClass respondsToSelector:addMonitorSel]) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:[nsEventClass methodSignatureForSelector:addMonitorSel]];
            [inv setSelector:addMonitorSel];
            [inv setTarget:nsEventClass];
            
            [inv setArgument:&scrollMask atIndex:2];
            
            id blockArg = [handlerBlock copy];
            [inv setArgument:&blockArg atIndex:3];
            
            [inv invoke];
        }

        static BOOL prevOptionHeld2 = NO;

        id (^kbMonitor)(id) = ^id(id event) {
            // Safety: Only handle if app is active
            if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return event;

            // Avoid recursion from our own injected events
            static SEL cgEventSel = NULL;
            if (!cgEventSel) cgEventSel = NSSelectorFromString(@"CGEvent");
            CGEventRef cgEv = ((CGEventRef(*)(id,SEL))objc_msgSend)(event, cgEventSel);
            NSUInteger evType = ((NSUInteger(*)(id,SEL))objc_msgSend)(event, typeSel3);
            if (cgEv && _CGEventGetIntegerValueField(cgEv, kCGEventSourceUserData) == 0x1337) {
                // A key the tweak injected: note it so it is not translated again.
                if (evType == 10 || evType == 11 || evType == 12) {
                    unsigned short svk = ((unsigned short(*)(id,SEL))objc_msgSend)(event, NSSelectorFromString(@"keyCode"));
                    GCKeyCode sgc = (svk < 128) ? nsVKToGC[svk] : 0;
                    if (sgc > 0 && sgc < 512) g_fnkbmSynthHeld[sgc] = (evType == 10) ? YES : (evType == 11) ? NO : !g_fnkbmSynthHeld[sgc];
                }
                return event;
            }

            // Typing mode (raw input) on its own key. Checked before the bypass
            // below so the same key also turns it off again.
            if ((evType == 10 || evType == 11) && keyCaptureCallback == nil && !isPopupVisible) {
                unsigned short vk0 = ((unsigned short(*)(id,SEL))objc_msgSend)(event, NSSelectorFromString(@"keyCode"));
                GCKeyCode g0 = (vk0 < 128) ? nsVKToGC[vk0] : 0;
                if (g0 != 0 && g0 == FNKBM_KEY_TYPING) {
                    SEL rs0 = NSSelectorFromString(@"isARepeat");
                    BOOL rep0 = [event respondsToSelector:rs0] ? ((BOOL(*)(id,SEL))objc_msgSend)(event, rs0) : NO;
                    if (evType == 10 && !rep0) {
                        isTypingModeEnabled = !isTypingModeEnabled;
                        resetControllerState();
                        KLOG("typing mode (raw input) = %d", isTypingModeEnabled);
                    }
                    return nil;
                }
            }

            // --- TYPING MODE BYPASS ---
            if (isTypingModeEnabled) return event;


             // ── Mouse Movement (Movement handled in quartz tap for Level 8 Pure Alpha) ──
             // We return event for moves here to allow system UI but we don't accumulate here.
             if (evType >= 5 && evType <= 8) {
                 return event;
             }

            // ── Mouse Buttons (L 1/2/6, R 3/4/7, Other 25/26/8) ───────────────────
            if ((evType >= 1 && evType <= 4) || evType == 25 || evType == 26 || (evType >= 6 && evType <= 8)) {
                int currentBtnCode = 0;
                // Press: LDown(1), RDown(3), ODown(25), LDrag(6), RDrag(7), ODrag(8)
                BOOL isPressed = (evType == 1 || evType == 3 || evType == 25 || (evType >= 6 && evType <= 8));
                
                if (evType == 1 || evType == 2 || evType == 6) currentBtnCode = MOUSE_BUTTON_LEFT;
                else if (evType == 3 || evType == 4 || evType == 7) currentBtnCode = MOUSE_BUTTON_RIGHT;
                else if (evType == 25 || evType == 26 || evType == 8) {
                    static SEL btnNumSel = NULL;
                    if (!btnNumSel) btnNumSel = NSSelectorFromString(@"buttonNumber");
                    NSInteger btnNum = ((NSInteger(*)(id,SEL))objc_msgSend)(event, btnNumSel);
                    if (btnNum == 2) currentBtnCode = MOUSE_BUTTON_MIDDLE;
                    else if (btnNum >= 3) currentBtnCode = (int)(MOUSE_BUTTON_AUX_BASE + (btnNum - 3));
                }

                // Native mode: GameController delivers every mouse button, to the
                // game or to the key it is bound to. The UI event is not used,
                // so it is dropped here before any touch or remap is made from it.
                if (isGCMouseDirectActive && isMouseLocked && !isPopupVisible && !isTriggerHeld) return nil;

                if (isPressed) {
                    if (mouseButtonCaptureCallback != nil || keyCaptureCallback != nil) {
                        if (isPopupVisible) {
                            // 1 left click pass through workaround
                            if (currentBtnCode == MOUSE_BUTTON_LEFT && ignoreNextLeftClickCount > 0) {
                                ignoreNextLeftClickCount--;
                                return event;
                            }

                            typedef CGPoint (*LocationFunc)(id, SEL);
                            LocationFunc getLoc = (LocationFunc)objc_msgSend;
                            CGPoint pt = getLoc(event, NSSelectorFromString(@"locationInWindow"));
                            // Flip bottom-left (NSEvent) to top-left (UIWindow)
                            pt.y = popupWindow.bounds.size.height - pt.y;

                            UIViewController *vc = popupWindow.rootViewController;
                            if (vc) {
                                UIViewController *presented = vc.presentedViewController;
                                if (presented) {
                                    CGPoint alertPt = [popupWindow convertPoint:pt toView:presented.view];
                                    UIView *aHit = [presented.view hitTest:alertPt withEvent:nil];
                                    // If we hit ANYTHING inside the presented view (dialog, buttons, etc), pass it through
                                    if (aHit && aHit != presented.view) {
                                        return event; // Pass through to UI, don't capture
                                    }
                                }
                            }
                            
                            if (mouseButtonCaptureCallback != nil) {
                                mouseButtonCaptureCallback(currentBtnCode);
                                return nil; // swallow
                            }
                            if (keyCaptureCallback != nil) {
                                keyCaptureCallback(currentBtnCode);
                                return nil; // swallow
                            }
                        }
                    }
                }

                if (isPopupVisible) return event;

                if (isMouseLocked || isGCMouseDirectActive) {
                    if (evType == 1) leftButtonIsPressed = YES;
                    if (evType == 2) leftButtonIsPressed = NO;
                    if (evType == 3) rightButtonIsPressed = YES;
                    if (evType == 4) rightButtonIsPressed = NO;
                    if (evType == 25) middleButtonIsPressed = YES;
                    if (evType == 26) middleButtonIsPressed = NO;
                } else if (!isMouseLocked && !isTriggerHeld) {
                    // TRULY UNLOCKED (e.g. Settings Open): Return event to allow Catalyst interaction
                    return event; 
                }

                if (isControllerModeEnabled && !isPopupVisible) {
                    if (currentBtnCode != 0) {
                        updateGCMouseDirectState(currentBtnCode, isPressed);
                        
                        // Hardware controller mapping — O(1) BITMASK LOOKUP
                        if (isMouseLocked || isTriggerHeld || !isPressed) {
                            if (currentBtnCode > 0 && currentBtnCode < 10240) {
                                uint32_t mask = g_vctrlReverseMap[currentBtnCode] | g_vctrlCustomMap[currentBtnCode];
                                while (mask) {
                                    int i = __builtin_ctz(mask);
                                    dispatchControllerButton(i, isPressed, YES);
                                    mask &= ~(1 << i);
                                }
                            }
                        }
                        
                        // Custom vctrl remaps — Elite: O(1) Zero-Alloc Bitmask Lookup
                        if (isMouseLocked || isTriggerHeld || !isPressed) {
                            if (currentBtnCode > 0 && currentBtnCode < 10240) {
                                // Block rapid-fire repeats (macOS key repeat)
                                if (isPressed && vctrlKeyState[currentBtnCode]) return nil;
                                vctrlKeyState[currentBtnCode] = isPressed;
                                
                                uint32_t cmask = g_vctrlCustomMap[currentBtnCode];
                                while (cmask) {
                                    int i = __builtin_ctz(cmask);
                                    dispatchControllerButton(i, isPressed, YES);
                                    cmask &= ~(1 << i);
                                }
                            }
                        }
                    }
                }

                // ── Advanced Mouse Button Remaps (Unified Keybinds tab & Mouse tab) ──
                int mbIdx = currentBtnCode - MOUSE_BUTTON_MIDDLE;
                if (!isPopupVisible && currentBtnCode != 0) {
                    GCKeyCode mbTarget = 0;
                    
                    // Priority 1: Unified Keybinds Tab (fortniteRemapArray)
                    if (currentBtnCode >= 0 && currentBtnCode < 10200) {
                        mbTarget = fortniteRemapArray[currentBtnCode];
                    }
                    
                    // Priority 2: Advanced Mouse Remaps (mouseButtonRemapArray)
                    if (mbTarget == 0 && mbIdx >= 0 && mbIdx < MOUSE_REMAP_COUNT) {
                        GCKeyCode custom = mouseButtonRemapArray[mbIdx];
                        if (custom == (GCKeyCode)-1) return nil; // explicitly blocked
                        if (custom != 0) mbTarget = custom;
                        else mbTarget = mouseFortniteArray[mbIdx];
                    }

                    if (mbTarget != 0) {
                        if (isPressed) {
                            if (isMouseLocked) {
                                _sendDualKeyEvent(mbTarget, YES);
                                remappedMouseButtonsState[mbIdx] = YES;
                            }
                        } else {
                            if (remappedMouseButtonsState[mbIdx]) {
                                _sendDualKeyEvent(mbTarget, NO);
                                remappedMouseButtonsState[mbIdx] = NO;
                            }
                        }
                        return nil; // SWALLOW remapped click
                    }
                }

                // ── Mandatory suppression check (Blocks double-input and handles unmapped buttons) ──
                if (_isMouseButtonSuppressed(currentBtnCode) && !isPopupVisible) {
                    // BOTH-AT-ONCE: If holding Option, return event to Catalyst even if mapped to controller
                    // so we get UI Dragging + Controller Action simultaneously. Strip Option flag.
                    if (isTriggerHeld) {
                        static SEL setFlagsSel = NULL;
                        if (!setFlagsSel) setFlagsSel = NSSelectorFromString(@"_setModifierFlags:");
                        if (!setFlagsSel) setFlagsSel = NSSelectorFromString(@"setModifierFlags:");
                        NSUInteger currentFlags = ((NSUInteger(*)(id,SEL))objc_msgSend)(event, modFlagsSel2);
                        NSUInteger clearFlags = currentFlags & ~0x80000;
                        if ([event respondsToSelector:setFlagsSel]) {
                            ((void(*)(id,SEL,NSUInteger))objc_msgSend)(event, setFlagsSel, clearFlags);
                        }
                        return event;
                    }
                    return nil; // Standard mapped button suppression
                }

                return event; // Always return event to keep Move events flowing for L/R/M
            }

            // ── FlagsChanged (12): Modifier keys (Shift, Cmd, Caps, Ctrl, etc.) + Option teleport ─
            if (evType == 12) {
                // Determine the GCKeyCode for the modifier that just changed
                unsigned short modVK = ((unsigned short(*)(id,SEL))objc_msgSend)(event, keyCodeSel2);
                GCKeyCode modGC = 0;
                if (modVK == 56) modGC = 225; // Left Shift
                else if (modVK == 60) modGC = 229; // Right Shift
                else if (modVK == 55) modGC = 227; // Left Cmd
                else if (modVK == 54) modGC = 231; // Right Cmd
                else if (modVK == 57) modGC = 57;  // Caps Lock
                else if (modVK == 59) modGC = 224; // Left Ctrl
                else if (modVK == 62) modGC = 228; // Right Ctrl
                else if (modVK == 58) modGC = 226; // Left Option
                else if (modVK == 61) modGC = 230; // Right Option

                // When capture mode is active, deliver modifier to callback
                if (keyCaptureCallback != nil && modGC != 0) {
                    keyCaptureCallback(modGC);
                    return nil;
                }

                // Determine pressed state from flags.
                // Per-key tracking using static previous-flag storage keyed by nsVK.
                // NSEventModifierFlags bits: Shift=0x20000, Ctrl=0x40000, Opt=0x80000,
                //   Cmd=0x100000, CapsLock=0x10000. For L/R distinction we read the
                //   per-key "raw" flag bits from the modifier keycode.
                NSUInteger modFlags = ((NSUInteger(*)(id,SEL))objc_msgSend)(event, modFlagsSel2);
                BOOL modPressed = NO;
                // Use a small static lookup keyed by nsVK to track previous state
                static NSUInteger prevModFlags = 0;
                NSUInteger relevantBit = 0;
                if (modVK == 56 || modVK == 60) relevantBit = 0x20000;  // Shift
                else if (modVK == 55 || modVK == 54) relevantBit = 0x100000; // Cmd
                else if (modVK == 59 || modVK == 62) relevantBit = 0x40000;  // Ctrl
                else if (modVK == 57) relevantBit = 0x10000; // Caps Lock
                else if (modVK == 58 || modVK == 61) relevantBit = 0x80000;  // Option
                if (relevantBit != 0) {
                    BOOL wasPressed = (prevModFlags & relevantBit) != 0;
                    modPressed = (modFlags & relevantBit) != 0;
                    prevModFlags = (modFlags & ~0x80000); // exclude Option (handled separately)
                    if (modPressed == wasPressed && modGC != 57) {
                        // No change for this modifier (another mod changed) — skip
                        goto fnm_option_check;
                    }
                }


                if (modGC != 0 && !isPopupVisible) {
                    // CONTROLLER MODE: check if this modifier is mapped to a controller button
                    if (isControllerModeEnabled && (isMouseLocked || isTriggerHeld || !modPressed)) {
                        BOOL handled = NO;
                        // Elite: O(1) Zero-Alloc Bitmask Lookup
                        if ((int)modGC > 0 && (int)modGC < 10240) {
                            uint32_t mask = g_vctrlReverseMap[(int)modGC] | g_vctrlCustomMap[(int)modGC];
                            while (mask) {
                                int i = __builtin_ctz(mask);
                                dispatchControllerButton(i, modPressed, NO);
                                handled = YES;
                                mask &= ~(1 << i);
                            }
                        }
                        if (handled) return nil;
                    }

                    // FORTNITE KEYBIND: check if this modifier is remapped to a default game key
                    if (!(g_fnkbmKeysInProcess && g_fnkbmModsInProcess) && modGC < 512) {
                        // Check custom remap first
                        GCKeyCode customTarget = keyRemapArray[modGC];
                        GCKeyCode fnTarget = (modGC < 512) ? fortniteRemapArray[modGC] : 0;
                        GCKeyCode target = (customTarget != 0 && customTarget != (GCKeyCode)-1) ? customTarget
                                         : (fnTarget != 0) ? fnTarget : 0;
                                         
                        if (target > 0) {
                            if (target < 256 && modGC == 57) {
                                // Special handling for Caps Lock: make every press a "Tap" (Down+Up)
                                // This bypasses the OS toggle behavior for gaming.
                                _sendDualKeyEvent(target, YES);
                                _sendDualKeyEvent(target, NO);
                            } else {
                                _sendDualKeyEvent(target, modPressed);
                            }
                            return nil; // swallow original modifier
                        }
                    }
                }

                fnm_option_check:;
                // Native mode has no use for the Option "free the cursor" hold,
                // so Left Option stays an ordinary key for the game.
                if (NATIVE_ALWAYS_ON) return event;
                NSUInteger flags = modFlags;
                BOOL optNow = (flags & 0x80000) != 0; // NSEventModifierFlagOption
                if (optNow == prevOptionHeld2) return event;
                prevOptionHeld2 = optNow;
                
                if (isPopupVisible) return event;

                if (optNow) {
                    isTriggerHeld = YES;
                    if (isMouseLocked) {
                        // Unlock and warp to Blue Dot
                        if (!blueDotIndicator) createBlueDotIndicator();
                        UIWindowScene *_wsc = (UIWindowScene *)[[UIApplication sharedApplication].connectedScenes anyObject];
                        UIWindow *_kw = _wsc ? (_wsc.keyWindow ?: _wsc.windows.firstObject) : nil;
                        CGFloat _winX = _kw ? _kw.frame.origin.x : 0;
                        CGFloat _winY = _kw ? _kw.frame.origin.y : 0;
                        CGPoint warpPt = CGPointMake(blueDotPosition.x + _winX, blueDotPosition.y + _winY);
                        isMouseLocked = NO;
                        updateMouseLock(NO, warpPt);
                        
                        // Option temporarily unlocks the cursor; existing virtual
                        // holds remain latched until their sources are released.
                    }
                } else {
                    isTriggerHeld = NO;
                    if (!isMouseLocked) {
                        // Lock and warp to center
                        isMouseLocked = YES;
                        updateMouseLock(YES, CGPointZero);
                    }
                }
                return event; // pass through
            }

            // ── KeyDown (10) / KeyUp (11) ─────────────────────────────────────
            BOOL pressed = (evType == 10);
            
            // Prevent key repeat flood from lagging the main thread!
            if (pressed) {
                SEL repeatSel = NSSelectorFromString(@"isARepeat");
                if ([event respondsToSelector:repeatSel]) {
                    // BOOL isRepeat = ((BOOL(*)(id,SEL))objc_msgSend)(event, repeatSel);
                    // if (isRepeat) return event;
                }
            }

            unsigned short nsVK = ((unsigned short(*)(id,SEL))objc_msgSend)(event, keyCodeSel2);
            if (nsVK >= 128) return event;

            GCKeyCode gck = nsVKToGC[nsVK];
            SEL fnkbmRepSel = NSSelectorFromString(@"isARepeat");
            BOOL fnkbmRep = [event respondsToSelector:fnkbmRepSel] ? ((BOOL(*)(id,SEL))objc_msgSend)(event, fnkbmRepSel) : NO;
            if (!fnkbmRep) KLOG("key vk=%d gc=%ld pressed=%d lock=%d direct=%d popup=%d", (int)nsVK, (long)gck, pressed, isMouseLocked, isGCMouseDirectActive, isPopupVisible);
            if (gck != 0 && gck == GCMOUSE_DIRECT_KEY) {
                updateGCMouseDirectState((int)gck, pressed);
                // pass through
            }

            // ── 'L' keyDown (evType 10) — toggle mouse lock ────
            if (gck != 0 && gck == FNKBM_KEY_FPS) {
                if (pressed && !fnkbmRep && !isPopupVisible) fnkbmSetFpsUnlock(!g_fnkbmFpsUnlock, "key");
                return nil;
            }
            if (gck != 0 && gck == FNKBM_KEY_LOCK && (!pressed || fnkbmRep)) return nil;
            if (pressed && gck != 0 && gck == FNKBM_KEY_LOCK) {
                if (isPopupVisible) return event;
                isMouseLocked = !isMouseLocked;
                if (!isMouseLocked) {
                    UIWindowScene *_sc = (UIWindowScene *)[[UIApplication sharedApplication].connectedScenes anyObject];
                    CGRect _sb = _sc ? _sc.screen.bounds : CGRectMake(0, 0, 1920, 1080);
                    CGPoint _center = CGPointMake(_sb.size.width / 2.0, _sb.size.height / 2.0);
                    updateMouseLock(NO, _center);
                    resetControllerState();
                } else {
                    updateMouseLock(YES, CGPointZero);
                    // Force virtual sticks to neutral on lock
                    if (g_virtualController) {
                        if (!g_virtualGamepad) g_virtualGamepad = ue_get_extended_gamepad(g_virtualController);
                        if (g_virtualGamepad) {
                            g_vctrl_cached_ls = [g_virtualGamepad leftThumbstick];
                            g_vctrl_cached_rs = [g_virtualGamepad rightThumbstick];
                            _updateVStick(NO, YES);
                            _updateVStick(YES, YES);
                        }
                    }
                }
                return nil; // consume
            }

            // ── POPUP_KEY (P key, VK 35) — show/hide settings popup ──
            // Using raw NSVirtualKeyCode 35 is proven more reliable on Catalyst.
            if (gck != 0 && gck == FNKBM_KEY_PANEL) {
                if (pressed && !fnkbmRep) {
                    if (!popupWindow) createPopup();
                    if (isPopupVisible) {
                        popupViewController *vc = (popupViewController *)popupWindow.rootViewController;
                        if ([vc respondsToSelector:@selector(closeButtonTapped)])
                            [vc performSelector:@selector(closeButtonTapped)];
                        else { isPopupVisible = NO; popupWindow.hidden = YES; updateBlueDotVisibility(); }
                    } else {
                        isPopupVisible = YES;
                        popupWindow.hidden = NO;
                        [popupWindow makeKeyAndVisible]; // Ensure it gets focus
                    }
                    isMouseLocked = NO;
                    updateMouseLock(NO, CGPointZero);
                    resetControllerState();
                }
                return nil; // consume — don't pass P through to the game
            }

            GCKeyCode keyCode = nsVKToGC[nsVK];
            if (keyCode == 0) return event;

            // ── Hardened Suppression for Controller/Remap ───────────────────
            BOOL isRemappedElsewhere = (isControllerModeEnabled && !isTypingModeEnabled && keyCode < 10240 &&
                (g_vctrlSuppressionMap[keyCode] || g_vctrlCustomMap[keyCode]));

            // PRIORITIZE CONTROLLER MODE: dispatch mapped controller button.
            if (isControllerModeEnabled && (isMouseLocked || isTriggerHeld || !pressed) && !isPopupVisible && keyCaptureCallback == nil) {
                BOOL handled = NO;
                // Elite: O(1) Zero-Alloc Bitmask Lookup
                if ((int)keyCode >= 0 && (int)keyCode < 10240) {
                    // Block rapid-fire repeats (macOS key repeat)
                    if (pressed && vctrlKeyState[keyCode]) return nil;
                    vctrlKeyState[keyCode] = pressed;
                    
                    uint32_t mask = g_vctrlReverseMap[(int)keyCode] | g_vctrlCustomMap[(int)keyCode];
                    while (mask) {
                        int i = __builtin_ctz(mask);
                        dispatchControllerButton(i, pressed, YES); // SYNC: Instant Injection
                        handled = YES;
                        mask &= ~(1 << i);
                    }
                }
                if (handled) return nil; // swallow - must not reach game
            }

            // ── Advanced Custom Remaps (tracked state for robust KeyUp) ───
            // Skipped when bound keys are translated in place (see the top of the file).
            if (!g_fnkbmKeysInProcess && !isPopupVisible && keyCaptureCallback == nil) {
                GCKeyCode target = 0;
                GCKeyCode customTarget = (keyCode < 512) ? keyRemapArray[keyCode] : 0;
                if (customTarget == (GCKeyCode)-1) return nil; 
                if (customTarget != 0) {
                    target = customTarget;
                } else if (keyCode < 512) {
                    GCKeyCode fnTarget = fortniteRemapArray[keyCode];
                    if (fnTarget != 0) {
                        target = fnTarget;
                    } else if (fortniteBlockedDefaults[keyCode] != 0 || isRemappedElsewhere) {
                        return nil; // swallowed (either by Keybind block or Controller map)
                    }
                }

                if (target > 0) {
                    if (pressed) {
                        if (isMouseLocked || target >= 10000) {
                            if (!remappedKeysState[keyCode]) KLOG("key %ld bound to key %ld: key down", (long)keyCode, (long)target);
                            _sendDualKeyEvent(target, YES);
                            remappedKeysState[keyCode] = YES;
                            return nil;
                        }
                    } else {
                        // RELEASE: catch KeyUp even if just unlocked
                        if (remappedKeysState[keyCode]) {
                            _sendDualKeyEvent(target, NO);
                            remappedKeysState[keyCode] = NO;
                            return nil;
                        }
                    }
                }
            }

            // Option key events handled entirely via FlagsChanged above.
            // Allow ESC through when not remapped.
            if (keyCode == TRIGGER_KEY) {
                if (keyCaptureCallback != nil && pressed) {
                    keyCaptureCallback(keyCode);
                    return nil;
                }
                if (keyCaptureCallback == nil) {
                    // Only swallow if it's remapped (already handled above) or being captured.
                    // If no remap exists, allow the physical key to reach the game.
                    if (keyRemapArray[keyCode] == 0 && fortniteRemapArray[keyCode] == 0) return event;
                    return nil;
                }
            }


            // ── Key capture for popup remapping UI — swallow and deliver to callback
            if (keyCaptureCallback != nil && pressed) {
                keyCaptureCallback(keyCode);
                return nil; // Swallow ALL keys (including ESC) to prevent dismissing the alert
            }

            if (keyCaptureCallback != nil && !pressed) {
                return nil; // Swallow KeyUp as well during capture
            }

            return event;
        };

        if ([nsEventClass respondsToSelector:addMonitorSel]) {
            NSInvocation *kbInv = [NSInvocation invocationWithMethodSignature:
                [nsEventClass methodSignatureForSelector:addMonitorSel]];
            [kbInv setSelector:addMonitorSel];
            [kbInv setTarget:nsEventClass];
            [kbInv setArgument:&keyMask atIndex:2];
            id kbBlock = [kbMonitor copy];
            [kbInv setArgument:&kbBlock atIndex:3];
            [kbInv invoke];
        }
    }
}

// --------- HELPER FUNCTIONS ---------

static inline CGFloat PixelAlign(CGFloat value) {
    UIWindowScene *scene = (UIWindowScene *)[[UIApplication sharedApplication].connectedScenes anyObject];
    CGFloat scale = scene.screen.scale ?: 2.0;
    return round(value * scale) / scale;
}

static void createPopup() {
    UIWindowScene *scene = (UIWindowScene *)[[UIApplication sharedApplication] connectedScenes].anyObject;
    // LEVEL 17: GPU Render-Guard (Hiding UI when inactive)
    popupWindow = [[FnOverlayWindow alloc] initWithWindowScene:scene];

    CGFloat popupW = PixelAlign(330.0);
    CGFloat popupH = PixelAlign(600.0);
    CGRect screen = scene ? scene.screen.bounds : CGRectMake(0, 0, 390, 844);
    CGFloat centeredY = PixelAlign((screen.size.height - popupH) / 2.0);

    popupWindow.frame = CGRectMake(PixelAlign(100.0), centeredY, popupW, popupH);
    popupWindow.windowLevel = UIWindowLevelAlert + 1;
    popupWindow.backgroundColor = [UIColor clearColor];
    
    popupViewController *popupVC = [popupViewController new];
    popupWindow.rootViewController = popupVC;
}

void showPopupOnQuickStartTab(void) {
    if (!popupWindow) createPopup();
    isPopupVisible = YES;
    popupWindow.hidden = NO;
    popupViewController *vc = (popupViewController *)popupWindow.rootViewController;
    if ([vc respondsToSelector:@selector(switchToQuickStartTab)]) {
        [vc switchToQuickStartTab];
    }
}


void createBlueDotIndicator() {
    if (blueDotIndicator) return;
    
    UIWindowScene *scene = (UIWindowScene *)[[UIApplication sharedApplication] connectedScenes].anyObject;
    if (!scene) return;
    
    blueDotIndicator = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 20, 20)];
    blueDotIndicator.backgroundColor = [UIColor colorWithRed:0.0 green:0.5 blue:1.0 alpha:0.9];
    blueDotIndicator.layer.cornerRadius = 10;
    blueDotIndicator.layer.borderWidth = 2;
    blueDotIndicator.layer.borderColor = [UIColor whiteColor].CGColor;
    blueDotIndicator.hidden = YES;
    blueDotIndicator.userInteractionEnabled = YES;
    
    UIPanGestureRecognizer *panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:blueDotIndicator action:nil];
    __weak UIView *weakDot = blueDotIndicator;
    [panGesture addTarget:weakDot action:@selector(handleBluePan:)];
    [blueDotIndicator addGestureRecognizer:panGesture];
    
    UIWindow *gameWindow = nil;
    for (UIWindow *w in scene.windows) {
        if (w != popupWindow) { gameWindow = w; break; }
    }
    
    if (gameWindow) {
        [gameWindow addSubview:blueDotIndicator];
        
        CGRect screenBounds = gameWindow.bounds;
        NSDictionary *savedPosition = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kBlueDotPositionKey];
        
        if (savedPosition) {
            CGFloat x = [savedPosition[@"x"] floatValue];
            CGFloat y = [savedPosition[@"y"] floatValue];
            x = MAX(10, MIN(screenBounds.size.width - 10, x));
            y = MAX(10, MIN(screenBounds.size.height - 10, y));
            blueDotPosition = CGPointMake(x, y);
        } else {
            // Default to bottom right area
            blueDotPosition = CGPointMake(screenBounds.size.width * 0.875, screenBounds.size.height * 0.875);
        }
        
        blueDotIndicator.center = blueDotPosition;
    }
}

void resetBlueDotPosition(void) {
    if (!blueDotIndicator) createBlueDotIndicator();
    
    if (blueDotIndicator && blueDotIndicator.superview) {
        CGRect screenBounds = blueDotIndicator.superview.bounds;
        CGPoint defaultPosition = CGPointMake(screenBounds.size.width * 0.875, screenBounds.size.height * 0.875);
        blueDotPosition = defaultPosition;
        blueDotIndicator.center = defaultPosition;
        
        NSDictionary *positionDict = @{@"x": @(defaultPosition.x), @"y": @(defaultPosition.y)};
        [[NSUserDefaults standardUserDefaults] setObject:positionDict forKey:kBlueDotPositionKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}

void updateBlueDotVisibility(void) {
    if (!blueDotIndicator) createBlueDotIndicator();
    blueDotIndicator.hidden = !isPopupVisible;
}

// Button state declarations moved to global scope
static BOOL leftClickSentToGame  = NO;
static GCControllerButtonValueChangedHandler leftButtonGameHandler = nil;
static GCControllerButtonValueChangedHandler leftButtonRawHandler  = nil; // raw game handler, never the wrapper
static GCControllerButtonInput *leftButtonInput = nil;
// isTriggerHeld — declared above as forward decl
static UIView  *lastCheckedView     = nil;
static BOOL     lastViewWasUIElement = NO;
static UIWindow *cachedKeyWindow    = nil;

// CGAssociateMouseAndMouseCursorPosition — absent from iOS SDK headers, resolved at runtime.
typedef CGError (*CGAssociateMouseAndMouseCursorPosition_t)(boolean_t connected);
static CGAssociateMouseAndMouseCursorPosition_t fnCGAssociateMouse = NULL;

// CGWarpMouseCursorPosition — absent from iOS SDK headers, resolved at runtime.
typedef CGError (*CGWarpMouseCursorPosition_t)(CGPoint newCursorPosition);
static CGWarpMouseCursorPosition_t fnCGWarpMouse = NULL;

void clearAllControllerButtons() {
    // 1. Zero out all joystick axes
    for (int i=0; i<4; i++) {
        lstickState[i] = NO;
        rstickState[i] = NO;
    }
    _updateVStick(NO, NO);
    _updateVStick(YES, NO);

    // 2. Release all mapped virtual controller buttons
    for (int i = 0; i < FnCtrlButtonCount; i++) {
        dispatchControllerButton(i,  NO, NO);
    }
}

static void updateMouseLock(BOOL value, CGPoint warpPos) {
    UIWindowScene *scene = (UIWindowScene *)[[[UIApplication sharedApplication].connectedScenes allObjects] firstObject];
    if (!scene) return;

    // AGGRESSIVE UNLOCK: Notify all view controllers in all windows.
    // Catalyst can be picky about which VC actually owns the lock.
    for (UIWindow *window in scene.windows) {
        UIViewController *root = window.rootViewController;
        if ([root respondsToSelector:NSSelectorFromString(@"setNeedsUpdateOfPrefersPointerLocked")]) {
            ((void (*)(id, SEL))objc_msgSend)(root, NSSelectorFromString(@"setNeedsUpdateOfPrefersPointerLocked"));
        }
    }

    if (value) {
        Class nsCursorClass = NSClassFromString(@"NSCursor");
        if (nsCursorClass) {
            ((void(*)(Class,SEL))objc_msgSend)(nsCursorClass, NSSelectorFromString(@"hide"));
        }

        // Decouple exactly how cursorteleportation did it — freezing the hardware cursor seamlessly.
        if (!fnCGAssociateMouse)
            fnCGAssociateMouse = (CGAssociateMouseAndMouseCursorPosition_t)dlsym(RTLD_DEFAULT, "CGAssociateMouseAndMouseCursorPosition");
        if (fnCGAssociateMouse) fnCGAssociateMouse(0);
        
        // LEVEL 11: Head-Tap Priority Re-Assertion
        if (fnm_eventTap && _CGEventTapEnable) {
            _CGEventTapEnable(fnm_eventTap, true);
        }

        // LOCKING — cancel any in-flight click before the lock gesture takes hold.
        BOOL hadGCPress = leftClickSentToGame;  // GC press was actually sent to game
        GCControllerButtonValueChangedHandler gcHandler = leftButtonGameHandler;
        GCControllerButtonInput *gcInput = leftButtonInput;

        leftButtonIsPressed  = NO;
        leftClickSentToGame  = NO;
        lastCheckedView      = nil;
        lastViewWasUIElement = NO;

        void (^cancelBlock)(void) = ^{
            UIApplication *app = [UIApplication sharedApplication];
            static IMP cancelAllTouchesIMP = NULL;
            if (!cancelAllTouchesIMP)
                cancelAllTouchesIMP = [app methodForSelector:@selector(_cancelAllTouches)];
            if (cancelAllTouchesIMP)
                ((void (*)(id, SEL))cancelAllTouchesIMP)(app, @selector(_cancelAllTouches));
            if (hadGCPress && gcHandler && gcInput)
                gcHandler(gcInput, 0.0, NO);
        };
        if ([NSThread isMainThread]) cancelBlock();
        else dispatch_sync(dispatch_get_main_queue(), cancelBlock);
    } else {
        // Unconditionally re-couple mouse movement to the hardware cursor
        if (!fnCGAssociateMouse)
            fnCGAssociateMouse = (CGAssociateMouseAndMouseCursorPosition_t)dlsym(RTLD_DEFAULT, "CGAssociateMouseAndMouseCursorPosition");
        if (fnCGAssociateMouse) fnCGAssociateMouse(1);

        // We briefly decouple to ensure UIKit doesn't fight the warp, then instantly recouple for the specific position.
        if (warpPos.x > 0 || warpPos.y > 0) {
            if (fnCGAssociateMouse) fnCGAssociateMouse(0);
            if (!fnCGWarpMouse)
                fnCGWarpMouse = (CGWarpMouseCursorPosition_t)dlsym(RTLD_DEFAULT, "CGWarpMouseCursorPosition");
            if (fnCGWarpMouse) fnCGWarpMouse(warpPos);
            if (fnCGAssociateMouse) fnCGAssociateMouse(1);
        }

        Class nsCursorClass = NSClassFromString(@"NSCursor");
        if (nsCursorClass) {
            ((void(*)(Class,SEL))objc_msgSend)(nsCursorClass, NSSelectorFromString(@"unhide"));
        }

        // PANIC RELEASE: ensure no remapped keys or mouse buttons stay stuck on unlock
        // EXCEPT: Skip this if we are temporarily unlocking via the Option key (Sticky Mode)
        if (!isTriggerHeld) {
            for (int i = 0; i < 512; i++) {
                if (remappedKeysState[i]) {
                    GCKeyCode target = 0;
                    GCKeyCode customTarget = keyRemapArray[i];
                    if (customTarget != 0 && customTarget != (GCKeyCode)-1) {
                        target = customTarget;
                    } else {
                        target = fortniteRemapArray[i];
                    }
                    
                    if (target > 0 && target < 256) {
                        uint16_t remappedVK = gcToNSVK[(uint8_t)target];
                        if ((remappedVK > 0 || target == 4) && _CGEventCreateKeyboardEvent && _CGEventPost) {
                            CGEventRef ev = _CGEventCreateKeyboardEvent(NULL, remappedVK, false);
                            if (ev) {
                                _CGEventSetIntegerValueField(ev, kCGEventSourceUserData, 0x1337);
                                _CGEventPost(kCGHIDEventTap, ev);
                                CFRelease(ev);
                            }
                        }
                    }
                    remappedKeysState[i] = NO;
                }
            }
            for (int i = 0; i < FnCtrlButtonCount; i++) {
                dispatchControllerButton(i,  NO, NO);
            }
        }

        // UNLOCKING — only purge game inputs if the settings popup is shown.
        // For Option-key 'teleports', we want to allow continuous movement/firing.
        if (isPopupVisible) {
            clearAllControllerButtons();
            wasADSInitialized = NO;

            GCControllerButtonValueChangedHandler gcHandler = leftButtonGameHandler;
            GCControllerButtonInput *gcInput = leftButtonInput;
            BOOL hadUITouch = leftButtonIsPressed;
            BOOL hadGCPress = leftClickSentToGame;

            leftButtonIsPressed  = NO;
            rightButtonIsPressed = NO;
            leftClickSentToGame  = NO;
            leftButtonRawHandler = nil;
            cachedKeyWindow      = nil;
            lastCheckedView      = nil;
            lastViewWasUIElement = NO;

            if (hadUITouch || hadGCPress) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    UIApplication *app = [UIApplication sharedApplication];
                    static IMP cancelAllTouchesIMP = NULL;
                    if (!cancelAllTouchesIMP)
                        cancelAllTouchesIMP = [app methodForSelector:@selector(_cancelAllTouches)];
                    if (cancelAllTouchesIMP)
                        ((void (*)(id, SEL))cancelAllTouchesIMP)(app, @selector(_cancelAllTouches));
                    if (hadGCPress && gcHandler && gcInput)
                        gcHandler(gcInput, 0.0, NO);
                });
            }
        }
    }


    if (!value) isGCMouseDirectActive = NO;
    else if (NATIVE_ALWAYS_ON) isGCMouseDirectActive = YES;
    KLOG("mouse lock=%d direct=%d", value, isGCMouseDirectActive);
    updateBlueDotVisibility();
}

// --------- THEOS HOOKS ---------
// Mouse movement — PC-accurate sensitivity
// ─────────────────────────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────
// installMouseButtonHandlers
// Called from setMouseMovedHandler — guaranteed to fire because Fortnite
// always calls it. At this point self is the fully connected GCMouseInput
// and all button objects exist. We use valueChangedHandler on middle and
// all aux buttons — it's a separate property from pressedChangedHandler,
// so Fortnite's own handler setup can never overwrite ours.
// ─────────────────────────────────────────────────────────────────────


// ─────────────────────────────────────────────────────────────────────
// GCExtendedGamepad hook — inject L3/R3 properties if they are missing.
// Fortnite (UE) requires these properties to exist on the gamepad object
// to recognize stick clicks. GCVirtualController excludes them by default.
// ─────────────────────────────────────────────────────────────────────
%hook GCExtendedGamepad

- (id)leftThumbstickButton {
    id val = %orig;
    if (val) return val;
    return getInjectedButton(self, @"leftThumbstickButton");
}

- (id)_leftThumbstickButton {
    if (self != ue_get_extended_gamepad(g_virtualController)) return [self leftThumbstickButton];
    if ([self respondsToSelector:@selector(leftThumbstickButton)]) {
        return [self leftThumbstickButton];
    }
    return getInjectedButton(self, @"leftThumbstickButton");
}

- (id)rightThumbstickButton {
    id val = %orig;
    if (val) return val;
    return getInjectedButton(self, @"rightThumbstickButton");
}

- (id)_rightThumbstickButton {
    if (self != ue_get_extended_gamepad(g_virtualController)) return [self rightThumbstickButton];
    if ([self respondsToSelector:@selector(rightThumbstickButton)]) {
        return [self rightThumbstickButton];
    }
    return getInjectedButton(self, @"rightThumbstickButton");
}

%end

// ─────────────────────────────────────────────────────────────────────
// GCController hook — Spoof the virtual controller as a DualShock 4.
// Fortnite enables L3/R3 and more features for recognized controllers.
// ─────────────────────────────────────────────────────────────────────
%hook GCController

- (NSString *)productCategory {
    GCVirtualController *vc = (GCVirtualController *)g_virtualController;
    if (vc && self == vc.controller) {
        return @"DualSense";
    }
    return %orig;
}

- (NSString *)vendorName {
    GCVirtualController *vc = (GCVirtualController *)g_virtualController;
    if (vc && self == vc.controller) {
        return @"DualSense Wireless Controller";
    }
    return %orig;
}

%end

%hook NSWindow

- (void)makeKeyAndOrderFront:(id)sender {
    if (isBorderlessModeEnabled) {
        id win = self;
        NSUInteger currentMask = [[win valueForKey:@"styleMask"] unsignedIntegerValue];
        NSUInteger fullSizeMask = (1ULL << 15);
        [win setValue:@(currentMask | fullSizeMask) forKey:@"styleMask"];
        [win setValue:@YES forKey:@"titlebarAppearsTransparent"];
        [win setValue:@(1) forKey:@"titleVisibility"];

        SEL buttonSel = NSSelectorFromString(@"standardWindowButton:");
        typedef id (*ButtonFunc)(id, SEL, NSInteger);
        for (NSInteger i = 0; i <= 2; i++) {
            id btn = ((ButtonFunc)objc_msgSend)(win, buttonSel, i);
            if (btn) [btn setValue:@YES forKey:@"hidden"];
        }
        id closeBtn = ((ButtonFunc)objc_msgSend)(win, buttonSel, 0);
        if (closeBtn) {
            id container = [closeBtn valueForKey:@"superview"];
            if (container) [container setValue:@YES forKey:@"hidden"];
        }
    }
    %orig;
}

%end

%hook GCMouseInput
- (void)setMouseMovedHandler:(GCMouseMoved)handler {
    if (!handler) { %orig; return; }
    g_originalMouseHandler = [handler copy];
    g_capturedMouseInput = self;
    if (self.leftButton) objc_setAssociatedObject(self.leftButton, &kButtonCodeKey, @(MOUSE_BUTTON_LEFT), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (self.rightButton) objc_setAssociatedObject(self.rightButton, &kButtonCodeKey, @(MOUSE_BUTTON_RIGHT), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (self.middleButton) objc_setAssociatedObject(self.middleButton, &kButtonCodeKey, @(MOUSE_BUTTON_MIDDLE), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSArray<GCControllerButtonInput *> *aux = self.auxiliaryButtons;
    for (NSInteger i = 0; i < (NSInteger)aux.count; i++) {
        if (aux[i]) objc_setAssociatedObject(aux[i], &kButtonCodeKey, @(MOUSE_BUTTON_AUX_BASE + i), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    GCMouse *currentMouse = GCMouse.current;
    if (currentMouse && currentMouse.handlerQueue != dispatch_get_main_queue())
        currentMouse.handlerQueue = dispatch_get_main_queue();
    GCMouseMoved customHandler = [^(GCMouseInput *eventMouse, float deltaX, float deltaY) {
        if (isGCMouseDirectActive) {
            if (fnkbmHidOnGCEvent(deltaX, deltaY)) return;
            // DIRECT MODE: movement goes to the game's own mouse handler,
            // scaled by the native sensitivity settings. Whole counts are
            // sent and the fraction is carried, so slow moves are not lost
            // if the engine truncates.
            double ads = rightButtonIsPressed ? (NATIVE_ADS_SENS / 100.0) : 1.0;
            fnkbmMouseFeed((double)deltaX * (NATIVE_SENS_X / 100.0) * ads, (double)deltaY * (NATIVE_SENS_Y / 100.0) * ads);
            static int directCount = 0;
            if ((++directCount % 240) == 1) KLOG("mouse move direct n=%d in=(%.1f,%.1f) ads=%d", directCount, deltaX, deltaY, rightButtonIsPressed);
            // Also ensure we don't accumulate gyro delta
            atomic_store(&mouseAccumBufferX[0], 0);
            atomic_store(&mouseAccumBufferX[1], 0);
            atomic_store(&mouseAccumBufferY[0], 0);
            atomic_store(&mouseAccumBufferY[1], 0);
        } else if (isMouseLocked) {
            // MOUSE-TO-GYRO MODE: Integrate into accumulators for ue_reflection
            int idx = atomic_load(&activeBufferIdx);
            atomic_add_double(&mouseAccumBufferX[idx], (double)deltaX);
            atomic_add_double(&mouseAccumBufferY[idx], (double)deltaY);
        }
    } copy];
#ifdef FNKBM_DEBUG
    g_dbgMouseWrapper = customHandler;
#endif
    KLOG("game registered mouse moved handler");
    %orig(customHandler);
}
%end




// ─────────────────────────────────────────────────────────────────────
// GCMouse hook — ensure callbacks fire on main queue.
// ─────────────────────────────────────────────────────────────────────


// ─────────────────────────────────────────────────────────────────────
// GCKit Scroll direction pad
// ─────────────────────────────────────────────────────────────────────
// Completely disabled and suppressed. All scroll logic is handled natively 
// by AppKit NSEvent monitor at 0ms latency for perfect 1:1 hardware ticks.
%hook GCControllerDirectionPad

- (void)setValueChangedHandler:(void (^)(GCControllerDirectionPad *, float, float))handler {
    GCMouse *currentMouse = GCMouse.current;
    BOOL isScrollPad = NO;
    if (currentMouse && currentMouse.mouseInput) {
        GCMouseInput *mouseInput = currentMouse.mouseInput;
        if ([mouseInput respondsToSelector:@selector(scroll)]) {
            isScrollPad = ([mouseInput scroll] == self);
        } else {
            isScrollPad = (self.xAxis != nil && self.yAxis != nil &&
                           self.up == nil && self.down == nil &&
                           self.left == nil && self.right == nil);
        }
    }
    
    // If it's a regular D-PAD on a controller, let it through normally
    if (!isScrollPad || !handler) { 
        %orig; 
        return; 
    }

    // Wrap the handler: suppress raw scroll if the specific direction scrolled has
    // a keybind assigned, OR if mouse is unlocked. NSEvent monitor handles key firing.
    void (^wrappedHandler)(GCControllerDirectionPad *, float, float) =
        ^(GCControllerDirectionPad *pad, float xValue, float yValue) {
            // Unlocked: only the wheel the tweak passes on for menus gets through.
            if (g_fnkbmMenuScroll) { handler(pad, xValue, yValue); return; }
            if (!isMouseLocked) return;

            // Suppress per-direction: if the direction being scrolled has a keybind,
            // the NSEvent monitor already fired the key — don't double-fire raw scroll.
            int scrollCode = (yValue > 0) ? MOUSE_SCROLL_UP : (yValue < 0 ? MOUSE_SCROLL_DOWN : 0);
            if (scrollCode != 0) {
                int idx = scrollCode - MOUSE_SCROLL_UP;
                // Check keyboard/Fortnite remaps
                if (mouseScrollRemapArray[idx] != 0 || 
                    mouseScrollFortniteArray[idx] != 0 || 
                    fortniteRemapArray[scrollCode] != 0) return;
                
                // [NEW] Check controller remaps — if mapped to controller button, suppress here
                if (isControllerModeEnabled) {
                    for (int i = 0; i < FnCtrlButtonCount; i++) {
                        if (controllerMappingArray[i] == scrollCode) return;
                    }
                }
            }

            handler(pad, xValue, yValue);
        };
    %orig(wrappedHandler);

    // Nuke the underlying reporting so GCKit stops sending duplicate events
    if ([self.yAxis respondsToSelector:@selector(setValue:)]) {
        [self.yAxis setValue:0.0f];
    }
}

%end
//
// DESIGN: At hook-registration time (setPressedChangedHandler: call), we check
// self against GCMouse.current.mouseInput to classify this button. If the mouse
// isn't ready yet (nil), we install a universal handler that classifies at
// press-time by scanning all mice. This covers every timing scenario.
// ─────────────────────────────────────────────────────────────────────


// HELPER: Centralized suppression check for Mouse Buttons (L, R, M, Aux1...)
// Prevents default game listening for M4/M5 and blocks double-input for remapped keys.
static BOOL _isMouseButtonSuppressed(int code) {
    if (code <= 0 || code >= 10240) return NO;

    // 1. O(1) BITMASK SUPPRESSION CHECK (Hardware Look-up)
    // This handles all Controller Mode mappings (Level 3 Elite)
    if (isControllerModeEnabled && !isTypingModeEnabled && !isPopupVisible &&
        (g_vctrlSuppressionMap[code] || g_vctrlCustomMap[code])) return YES;
    
    // 2. Fortnite Tab Remapping (Key -> Default Key)
    if (fortniteRemapArray[code] != 0) return YES;
    if (fortniteBlockedDefaults[code] != 0) return YES;

    // 3. Mouse Tab Remapping (Sensitivity or Mouse Remaps)
    int mbIdx = code - MOUSE_BUTTON_MIDDLE;
    if (mbIdx >= 0 && mbIdx < MOUSE_REMAP_COUNT) {
        if (mouseButtonRemapArray[mbIdx] != 0) return YES;
        if (mouseFortniteArray[mbIdx] != 0) return YES;
    }

    // 4. Advanced Custom Remapping (Remaps tab)
    if (code < 512 && keyRemapArray[code] != 0) return YES;
    // Modulo check only for special cases likePopup UI
    if (keyRemapArray[code % 512] != 0) return YES;

    // 5. Direct (native) mouse mode: left, right and middle are NOT suppressed
    // here. The game reads them as real mouse buttons through GameController.
    // The matching UI click is swallowed in the event monitor instead, so the
    // game never also sees a screen touch.

    // 6. Direct Mouse Toggle Key (Exclusive)
    if (code != 0 && (GCKeyCode)code == GCMOUSE_DIRECT_KEY) return YES;

    return NO;
}

// OS-LEVEL EVENT TAP: Intercepts M4/M5 before they reach ANY system or app layer.
// Providing the "FULL block" requested by the user.
static CGEventRef mouseButtonTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ elevateThreadToRealTime(); });

    // ── SAFETY CHECK: GLOBAL INTERFERENCE PREVENTION ──
    // Only process events if our app is actually in the foreground.
    // This prevents neutralizing Caps Lock or OtherMouse buttons for the entire OS.
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive || !atomic_load(&g_fnkbmRealActive)) {
        return event;
    }

    // A. MOVEMENT ACCUMULATION (Level 8 Pure Alpha Pipeline)
    // We handle this at the absolute top of the tap to ensure clicking NEVER stalls aim.
    if (type == kCGEventMouseMoved || type == kCGEventLeftMouseDragged || type == kCGEventRightMouseDragged || type == kCGEventOtherMouseDragged) {
        if (isMouseLocked || isGCMouseDirectActive) {
            // LEVEL 14: IOHID-Prime BYPASS
            // If the HID Manager is active and handling raw reports, we do NOT 
            // accumulate deltas here. This prevents double-counting and ensures
            // we use the ultra-low-latency HID source instead of Quartz.
            if (g_hidManager) {
                // HID Engine is the primary source now. Just swallow the Quartz event.
                if (isMouseLocked) return NULL;
                return event;
            }

            double dx = _CGEventGetDoubleValueField ? _CGEventGetDoubleValueField(event, kCGMouseEventDeltaX) : 0;
            double dy = _CGEventGetDoubleValueField ? -(_CGEventGetDoubleValueField(event, kCGMouseEventDeltaY)) : 0;

            // LEVEL 9: Pulse-Injection Engine (Zero Latency PUSH)
            if (g_originalMouseHandler && (fabs(dx) > 0.0001 || fabs(dy) > 0.0001)) {
                // Bypass the OS event loop and pulse movement directly into the engine.
                // We do this via an immediate block invocation to hit the sub-millisecond goal.
                g_originalMouseHandler(g_capturedMouseInput, (float)dx, (float)dy);
            } else {
                // LEVEL 12: Hybrid Phase-Lock (Exclusive Engine)
                // Only use the 'Pull' accumulator if the 'Push' engine above is inactive.
                // This prevents 'Double-Reporting' which is the source of the choppy jitter.
                int idx = atomic_load(&activeBufferIdx);
                atomic_add_double(&mouseAccumBufferX[idx], dx);
                atomic_add_double(&mouseAccumBufferY[idx], dy);
                if (_CGEventGetTimestamp) {
                    mouseHardwareTimestamp[idx] = _CGEventGetTimestamp(event);
                }
            }

            // LEVEL 11/12: Stabilized Re-Center (Deep Isolation)
            // Prevent the virtual cursor from ever hitting a screen boundary by warping
            // it back to the window center every 50 packets for maximum stability.
            if (isMouseLocked) {
                static int warpCounter = 0;
                if (++warpCounter >= 50) {
                    warpCounter = 0;
                    if (fnCGWarpMouse && fnCGAssociateMouse) {
                        // Dissociate briefly to hide the warp from the OS delta-calculator
                        fnCGAssociateMouse(0);
                        fnCGWarpMouse(CGPointMake(blueDotPosition.x, blueDotPosition.y));
                        fnCGAssociateMouse(0); // Maintain lock
                    }
                }
            }
            
            // If we are locked, swallow the move so Catalyst doesn't fight our warp
            if (isMouseLocked) return NULL;
        }
    }

    // B. KEYBOARD EVENTS (System-Level Intervention)
    if (type == 10 || type == 11 || type == 12) { // KeyDown, KeyUp, FlagsChanged
        if (_CGEventGetFlags && _CGEventSetFlags) {
            CGEventFlags flags = _CGEventGetFlags(event);
            
            // 0. Intercept Capture Keys (including ESC and Key A)
            if (keyCaptureCallback != nil) {
                int64_t vk = _CGEventGetIntegerValueField ? _CGEventGetIntegerValueField(event, 9) : 0;
                if (type == 10 || type == 12) { // KeyDown or FlagsChanged
                    keyCaptureCallback(nsVKToGC[vk]);
                }
                return NULL; // SWALLOW ALL KEYS DURING CAPTURE
            }

            // 1. Intercept Caps Lock (VK 57)
            int64_t vk = _CGEventGetIntegerValueField ? _CGEventGetIntegerValueField(event, 9) : 0;
            if (type == 12 && vk == 57 && fnkbmKeyTarget(57) > 0) {
                // Caps Lock is bound: it presses its key and no longer toggles typing mode.
                if (fnkbmRemapActive()) fnkbmTapKey((GCKeyCode)fnkbmKeyTarget(57));
                return NULL;
            }
            // Command is bound: while playing, keys pressed with it held stay plain
            // keys. Otherwise macOS treats them as shortcuts and never reports
            // their release, which leaves them stuck in the game.
            // Left alone: Command+Tab (switch apps) and Command+Shift+3/4/5 (macOS screenshots).
            BOOL fnkbmShot = (flags & kCGEventFlagMaskShift) && (vk == 20 || vk == 21 || vk == 23);
            if ((type == 10 || type == 11) && (flags & FNKBM_CMD_MASK) && fnkbmRemapActive() && vk != 48 && !fnkbmShot) {
                flags &= ~FNKBM_CMD_MASK;
                _CGEventSetFlags(event, flags);
            }
            if (type == 12 && vk == 57) {
                // Caps Lock does not switch typing mode (one stray press turned every bind
                // off). It goes on to the game, which gets it as a short press.
                return event;
            }
            
            // 2. Global Caps Lock Stripping & Lowercasing
            if (flags & kCGEventFlagMaskAlphaShift) {
                _CGEventSetFlags(event, flags & ~kCGEventFlagMaskAlphaShift);
                
                // Force lowercase unicode strings if Shift isn't held
                if (type == 10 && !(flags & kCGEventFlagMaskShift) && _CGEventKeyboardGetUnicodeString && _CGEventKeyboardSetUnicodeString) {
                    UniChar unicodeChars[4];
                    UniCharCount actualLen = 0;
                    _CGEventKeyboardGetUnicodeString(event, 4, &actualLen, unicodeChars);
                    if (actualLen > 0) {
                        BOOL changed = NO;
                        for (int i = 0; i < (int)actualLen; i++) {
                            if (unicodeChars[i] >= 'A' && unicodeChars[i] <= 'Z') {
                                unicodeChars[i] += ('a' - 'A');
                                changed = YES;
                            }
                        }
                        if (changed) {
                            _CGEventKeyboardSetUnicodeString(event, actualLen, unicodeChars);
                        }
                    }
                }
            }
        }
    }

    if (isTypingModeEnabled) return event;

    // --- MOUSE BUTTON SUPPRESSION & REMAPPING ---
    if (type == kCGEventLeftMouseDown || type == kCGEventLeftMouseUp || type == kCGEventLeftMouseDragged ||
        type == kCGEventRightMouseDown || type == kCGEventRightMouseUp || type == kCGEventRightMouseDragged ||
        type == kCGEventOtherMouseDown || type == kCGEventOtherMouseUp || type == kCGEventOtherMouseDragged) {
        
        int currentBtnCode = 0;
        if (type == kCGEventLeftMouseDown || type == kCGEventLeftMouseUp || type == kCGEventLeftMouseDragged) {
            currentBtnCode = MOUSE_BUTTON_LEFT;
        } else if (type == kCGEventRightMouseDown || type == kCGEventRightMouseUp || type == kCGEventRightMouseDragged) {
            currentBtnCode = MOUSE_BUTTON_RIGHT;
        } else {
            int64_t btnNum = _CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);
            // UNIFIED CODING: Middle click (btnNum 2) -> 10050, M4 (btnNum 3) -> 10051, etc.
            if (btnNum == 2) {
                currentBtnCode = MOUSE_BUTTON_MIDDLE;
            } else {
                currentBtnCode = (int)(MOUSE_BUTTON_MIDDLE + (btnNum - 2));
            }
        }

        BOOL isPressed = (type == kCGEventLeftMouseDown || type == kCGEventRightMouseDown || type == kCGEventOtherMouseDown ||
                          type == kCGEventLeftMouseDragged || type == kCGEventRightMouseDragged || type == kCGEventOtherMouseDragged);

        if (!isPopupVisible) {
            // Safety Reset: If mouse is unlocked or popup is shown, clear tracking state
            static BOOL tapRemapState[128] = {0};
            static BOOL lastLockedState = NO;
            if (!isMouseLocked || isPopupVisible) {
                // If we were locked and now we're not, send "Up" for any stuck buttons
                if (lastLockedState) {
                    for (int i = 0; i < 128; i++) {
                        if (tapRemapState[i]) {
                           // We don't have the target here easily, but clearing state
                           // is enough to allow the next press to work.
                           // Actually, most games handle "window lose focus" by clearing their own state.
                           tapRemapState[i] = NO;
                        }
                    }
                }
                lastLockedState = NO;
            } else {
                lastLockedState = YES;
            }

            // 0. Update Direct Mouse Toggle state
            if (currentBtnCode != 0 && (GCKeyCode)currentBtnCode == GCMOUSE_DIRECT_KEY) {
                updateGCMouseDirectState(currentBtnCode, isPressed);
                // ALWAYS pass through the trigger key/button so the game sees clicks
                return event;
            }

            if (isGCMouseDirectActive) {
                // Native mode: handled from GameController, nothing to do here.
                return event;
            }

            // Sync physical mouse state removed (GC clicks should NEVER fire)

            // 1. Remapping Logic (from Sensitivity or Remaps tab)
            int mbIdx = currentBtnCode - MOUSE_BUTTON_MIDDLE;
            GCKeyCode mbTarget = 0;
            if (currentBtnCode >= 0 && currentBtnCode < 10200) {
                 mbTarget = fortniteRemapArray[currentBtnCode];
            }
            if (mbTarget == 0 && mbIdx >= 0 && mbIdx < MOUSE_REMAP_COUNT) {
                 mbTarget = mouseButtonRemapArray[mbIdx];
                 if (mbTarget == 0) mbTarget = mouseFortniteArray[mbIdx];
            }
            if (mbTarget == 0 && currentBtnCode >= 0 && currentBtnCode < 512) {
                 mbTarget = keyRemapArray[currentBtnCode];
            }
            // MODULO Fallback for Popup UI
            if (mbTarget == 0 && currentBtnCode >= 0 && currentBtnCode < 10200) {
                 mbTarget = keyRemapArray[currentBtnCode % 512];
            }

            if (mbTarget != 0) {
                // Use the static state declared above (moved to avoid local static issues)
                int tapIdx = (currentBtnCode == MOUSE_BUTTON_LEFT) ? 120 : 
                             (currentBtnCode == MOUSE_BUTTON_RIGHT) ? 121 : 
                             (int)(currentBtnCode - MOUSE_BUTTON_MIDDLE);

                if (tapIdx >= 0 && tapIdx < 120) {
                    if (isPressed) {
                        if (isMouseLocked && !tapRemapState[tapIdx]) {
                            _sendDualKeyEvent(mbTarget, YES);
                            tapRemapState[tapIdx] = YES;
                        }
                    } else if (type == kCGEventLeftMouseUp || type == kCGEventRightMouseUp || type == kCGEventOtherMouseUp) {
                        if (tapRemapState[tapIdx]) {
                            _sendDualKeyEvent(mbTarget, NO);
                            tapRemapState[tapIdx] = NO;
                        }
                    }
                }
            }

            // 2. Controller Mode — O(1) BITMASK LOOKUP
            if (isControllerModeEnabled) {
                if (currentBtnCode > 0 && currentBtnCode < 10240) {
                    // Block rapid-fire repeats (mouse is usually 1:1, but safety first)
                    if (isPressed && vctrlKeyState[currentBtnCode]) return event;
                    vctrlKeyState[currentBtnCode] = isPressed;
                    
                    uint32_t mask = g_vctrlReverseMap[currentBtnCode] | g_vctrlCustomMap[currentBtnCode];
                    while (mask) {
                        int i = __builtin_ctz(mask);
                        if (isMouseLocked || !isPressed) {
                            dispatchControllerButton(i, isPressed, YES);
                        }
                        mask &= ~(1 << i);
                    }
                }
            }

            // 3. SWALLOW IF SUPPRESSED
            if (_isMouseButtonSuppressed(currentBtnCode)) {
                return NULL; 
            }
        }
    }
    return event;
}

// =====================================================================
// KEY REMAPPING SYSTEM - ZERO LATENCY OPTIMIZATION
// =====================================================================
// Intercept keyboard input and remap keys according to user settings
// PERFORMANCE: Using inline cache function for ~5ns overhead (cache hit)
// or ~50ns overhead (cache miss). Non-remapped keys: zero overhead.

%hook GCKeyboardInput

- (void)setKeyChangedHandler:(GCKeyboardValueChangedHandler)handler {
    if (!handler) {
        %orig;
        return;
    }

    // Store the raw handler and keyboard input so mouse buttons / scroll can
    // synthesize keyboard key events without going through buttonForKeyCode.
    storedKeyboardInput = self;
    storedKeyboardHandler = handler;
    
    GCKeyboardValueChangedHandler customHandler = ^(GCKeyboardInput * _Nonnull keyboard, GCControllerButtonInput * _Nonnull key, GCKeyCode keyCode, BOOL pressed) {
        // PRIORITY: Key capture for popup (when adding/changing remappings)
        if (keyCaptureCallback != nil && pressed) {
            keyCaptureCallback(keyCode);
            return; // Don't pass key to game during capture
        }

        // ── Controller mode remap (Key → Controller Button) ───────────
        // We handle this here to suppress the key if it's bound to a controller.
        // kbMonitor dispatches the controller button, so we only need to swallow.
        if (isControllerModeEnabled && !isTypingModeEnabled && !isPopupVisible &&
            (isMouseLocked || isTriggerHeld) && keyCode >= 0 && keyCode < 10240 &&
            (g_vctrlReverseMap[keyCode] || g_vctrlCustomMap[keyCode])) {
            return; // Only swallow while the virtual controller can accept this input.
        }
        KLOG("key %ld pressed=%d remap=%ld fnremap=%ld blocked=%d", (long)keyCode, pressed,
             (keyCode >= 0 && keyCode < 512) ? (long)keyRemapArray[keyCode] : 0L,
             (keyCode >= 0 && keyCode < 512) ? (long)fortniteRemapArray[keyCode] : 0L,
             (keyCode >= 0 && keyCode < 512) ? (int)fortniteBlockedDefaults[keyCode] : 0);

        // TWO-TIER REMAPPING SYSTEM (ULTRA-FAST):
        // PRIORITY 1: Advanced Custom Remaps - user's explicit overrides (~2ns)
        // PRIORITY 2: Fortnite Keybinds - custom key → default key (~2ns)
        // PRIORITY 3: Block default Fortnite keys when remapped away (~2ns)
        // Total overhead: ~6ns (all are direct array lookups, zero dictionary overhead)
        
        GCKeyCode finalKey = keyCode;
        BOOL wasRemapped = NO;
        
        if (keyCode >= 0 && keyCode < 512) {
            // PRIORITY 1: Check Advanced Custom Remaps first (takes precedence)
            GCKeyCode customRemap = keyRemapArray[keyCode];
            if (customRemap == (GCKeyCode)-1) {
                // Special case: key is explicitly blocked (remapped to -1)
                return;
            } else if (customRemap != 0) {
                // Advanced Custom Remap found - use it!
                finalKey = customRemap;
                wasRemapped = YES;
            } else {
                // PRIORITY 2: Check Fortnite keybinds (ultra-fast array lookup)
                GCKeyCode fortniteRemap = fortniteRemapArray[keyCode];
                if (fortniteRemap != 0) {
                    // Fortnite keybind found - use it!
                    finalKey = fortniteRemap;
                    wasRemapped = YES;
                } else {
                    // PRIORITY 3: Check if this is a blocked default Fortnite key
                    // Example: if Reload was changed from R to L, we need to block R
                    if (fortniteBlockedDefaults[keyCode] != 0) {
                        // This default key has been remapped to another key - block it!
                        return;
                    }
                }
            }
        }
        
        // When a key is remapped, suppress the original and send the target.
        if (wasRemapped) {
            BOOL injected = NO;

            // Path 1: GCKit button — zero-latency, works for letters/F-keys
            GCControllerButtonInput* remappedBtn = [keyboard buttonForKeyCode:finalKey];
            if (remappedBtn) {
                handler(keyboard, remappedBtn, finalKey, pressed);
                injected = YES;
            }

            // Path 2: Root-level CGEventPost — covers modifier keys, number keys,
            // and any key GCKit doesn't expose via buttonForKeyCode.
            if (!injected && finalKey < 256 && _CGEventCreateKeyboardEvent && _CGEventPost) {
                uint16_t targetVK = gcToNSVK[(uint8_t)finalKey];
                // targetVK 0 is only valid for GC code 4 ('A')
                if (targetVK > 0 || finalKey == 4) {
                    CGEventRef ev = _CGEventCreateKeyboardEvent(NULL, targetVK, (bool)pressed);
                    if (ev) {
                        _CGEventSetIntegerValueField(ev, kCGEventSourceUserData, 0x1337); _CGEventPost(kCGHIDEventTap, ev);
                        CFRelease(ev);
                        injected = YES;
                    }
                }
            }

            // Suppress original regardless — even if injection failed
            return;
        }
        
        // No remapping - call handler with original key
        handler(keyboard, key, keyCode, pressed);
    };
#ifdef FNKBM_DEBUG
    g_dbgKbWrapper = [customHandler copy];
#endif
    KLOG("game registered keyboard handler");

    %orig(customHandler);
}

%end

// Disable pointer "locking" mechanism:
// We explicitly disable Apple native pointer lock to prevent Catalyst from rejecting
// the Backtick key press and causing tracking drift bounds clamping. The custom
// `updateMouseLock` state manually leverages `CGAssociateMouse(0)` instead.
%hook IOSViewController

- (BOOL)prefersPointerLocked {
    return isMouseLocked;
}

%end

// Enable 120 FPS on any screen
%hook UIScreen

- (NSInteger)maximumFramesPerSecond {
    return 120;
}

%end

// Trick the game into thinking mouse clicks are touchscreen clicks
%hook UITouch

- (UITouchType)type {
    UITouchType _original = %orig;
    
    // FAST PATH: If not indirect pointer, return immediately
    if (_original != UITouchTypeIndirectPointer) {
        return _original;
    }

    // FAST PATH: Mouse unlocked (includes when Option is held) — convert to direct touch
    // so clicks and drags work while the cursor is free.
    if (!isMouseLocked) {
        return UITouchTypeDirect;
    }

    return _original;
}

%end

// =============================================================================
// GLOBAL TOUCH SUPPRESSION
// This fixes the "Circle Spring" by blocking Catalyst's virtual touch emulation
// when we are in raw-aiming mode.
// =============================================================================
%hook UIWindow
- (void)sendEvent:(UIEvent *)event {
    if (isMouseLocked && event.type == 0) { // UIEventTypeTouches = 0
        NSSet *touches = [event allTouches];
        for (UITouch *touch in touches) {
            // UITouchTypePointer = 3 (Catalyst Mouse-Touch)
            if ((int)touch.type == 3) {
                return; // Swallow! Prevent virtual joystick accumulation.
            }
        }
    }
    %orig;
}
%end


%hook GCControllerButtonInput

- (void)setPressedChangedHandler:(GCControllerButtonValueChangedHandler)handler {
    if (!handler) { %orig; return; }
    GCControllerButtonValueChangedHandler wrapper = ^(GCControllerButtonInput *btn, float val, BOOL pressed) {
        NSNumber *codeNum = objc_getAssociatedObject(btn, &kButtonCodeKey);
        BOOL sup = codeNum && _isMouseButtonSuppressed([codeNum intValue]);
        if (codeNum && pressed && fnkbmCaptureMouseButton([codeNum intValue])) return;
        if (codeNum && NATIVE_ALWAYS_ON) {
            if (!fnkbmNativeButton([codeNum intValue], pressed, g_fnkbmFwdPressed, YES)) return;
            KLOG("mouse button code=%d pressed=%d sent to game", [codeNum intValue], pressed);
            handler(btn, val, pressed);
            return;
        }
        if (sup) {
             return; 
        }
        handler(btn, val, pressed);
    };
    int mbi = fnkbmMouseButtonIndex(self);
    if (mbi >= 0) {
        g_fnkbmGameBtnHandler[mbi] = [handler copy];
        g_fnkbmGameBtn[mbi] = self;
        KLOG("game registered pressedChanged for mouse button %d", mbi);
#ifdef FNKBM_DEBUG
        g_dbgBtnPressed[mbi] = [wrapper copy]; g_dbgBtn[mbi] = self;
#endif
    }
    %orig(wrapper);
}

- (void)setValueChangedHandler:(GCControllerButtonValueChangedHandler)handler {
    if (!handler) { %orig; return; }
    GCControllerButtonValueChangedHandler wrapper = ^(GCControllerButtonInput *btn, float val, BOOL pressed) {
        NSNumber *codeNum = objc_getAssociatedObject(btn, &kButtonCodeKey);
        BOOL sup = codeNum && _isMouseButtonSuppressed([codeNum intValue]);
        if (codeNum && pressed && isPopupVisible && (mouseButtonCaptureCallback != nil || keyCaptureCallback != nil) && [codeNum intValue] != MOUSE_BUTTON_LEFT) return;
        if (codeNum && NATIVE_ALWAYS_ON) {
            if (!fnkbmNativeButton([codeNum intValue], pressed, g_fnkbmFwdValue, NO)) return;
            handler(btn, val, pressed);
            return;
        }
        if (sup) {
             return; 
        }
        handler(btn, val, pressed);
    };
    int mbi = fnkbmMouseButtonIndex(self);
    if (mbi >= 0) {
        KLOG("game registered valueChanged for mouse button %d", mbi);
#ifdef FNKBM_DEBUG
        g_dbgBtnValue[mbi] = [wrapper copy]; g_dbgBtn[mbi] = self;
#endif
    }
    %orig(wrapper);
}

- (BOOL)isPressed {
    NSNumber *codeNum = objc_getAssociatedObject(self, &kButtonCodeKey);
    if (codeNum) {
        int code = [codeNum intValue];
        // 1. Suppression Priority: If this is a mouse button being handled by the tweak,
        // it must ALWAYS return NO to the game's GC frame listeners.
        if (_isMouseButtonSuppressed(code)) return NO;

        // 2. Legacy synthesis check (Fallback)
        if (!isGCMouseDirectActive) {
            if (code == MOUSE_BUTTON_LEFT && leftButtonIsPressed) return NO; // Absolute block
            if (code == MOUSE_BUTTON_RIGHT && rightButtonIsPressed) return NO;
            if (code == MOUSE_BUTTON_MIDDLE && middleButtonIsPressed) return NO;
        }
    }
    return %orig;
}

- (float)value {
    NSNumber *codeNum = objc_getAssociatedObject(self, &kButtonCodeKey);
    if (codeNum) {
        int code = [codeNum intValue];
        if (_isMouseButtonSuppressed(code)) return 0.0f;
        
        // Absolute block for synthesized states
        if (!isGCMouseDirectActive) {
            if (code == MOUSE_BUTTON_LEFT && leftButtonIsPressed) return 0.0f;
            if (code == MOUSE_BUTTON_RIGHT && rightButtonIsPressed) return 0.0f;
            if (code == MOUSE_BUTTON_MIDDLE && middleButtonIsPressed) return 0.0f;
        }
    }
    return %orig;
}

- (void)setValue:(float)val {
    NSNumber *codeNum = objc_getAssociatedObject(self, &kButtonCodeKey);
    if (codeNum && _isMouseButtonSuppressed([codeNum intValue])) {
        %orig(0.0f);
        return;
    }
    %orig;
}

- (void)setPressed:(BOOL)pressed {
    NSNumber *codeNum = objc_getAssociatedObject(self, &kButtonCodeKey);
    if (codeNum && _isMouseButtonSuppressed([codeNum intValue])) {
        %orig(NO);
        return;
    }
    %orig;
}

- (BOOL)pressed {
    return [self isPressed];
}

%end
// Fortnite may establish its initial responder from its game thread. On Mac,
// UIKit forwards that change to UINSWindowProxyFocusHelper, which asserts that
// it runs on main. Marshal the entire responder change, preserving its result.
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

%hook NSNotificationCenter
- (void)postNotificationName:(NSNotificationName)aName object:(id)anObject userInfo:(NSDictionary *)aUserInfo {
    if ([aName isEqualToString:@"NSApplicationWillResignActiveNotification"] || 
        [aName isEqualToString:@"NSApplicationDidResignActiveNotification"]) {
        return;
    }
    %orig;
}
%end

%hook CADisplayLink

- (void)setPreferredFramesPerSecond:(NSInteger)fps {
    NSLog(@"[FnMacTweak] setPreferredFramesPerSecond called with: %ld (forcing 120)", (long)fps);
    %orig(120);
}

- (void)setFrameInterval:(NSInteger)interval {
    NSLog(@"[FnMacTweak] setFrameInterval called with: %ld (forcing 1)", (long)interval);
    %orig(1);
}

- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    NSLog(@"[FnMacTweak] setPreferredFrameRateRange called with: min=%f, max=%f, preferred=%f (forcing 120)", range.minimum, range.maximum, range.preferred);
    CAFrameRateRange newRange;
    newRange.minimum = 120.0f;
    newRange.maximum = 120.0f;
    newRange.preferred = 120.0f;
    %orig(newRange);
}

%end

%hook _MTLCommandBuffer

- (void)presentDrawable:(id)drawable afterMinimumDuration:(double)duration {
    static double minDuration = -1.0;
    if (minDuration < 0.0) {
        NSInteger maxFPS = 120; // Default fallback
        Class screenClass = NSClassFromString(@"UIScreen");
        if (screenClass) {
            id (*getMainScreen)(Class, SEL) = (id (*)(Class, SEL))objc_msgSend;
            id mainScreen = getMainScreen(screenClass, @selector(mainScreen));
            if (mainScreen) {
                NSInteger (*getMaxFPS)(id, SEL) = (NSInteger (*)(id, SEL))objc_msgSend;
                maxFPS = getMaxFPS(mainScreen, @selector(maximumFramesPerSecond));
            }
        }
        if (maxFPS <= 0) maxFPS = 120;
        minDuration = 1.0 / (double)maxFPS;
        NSLog(@"[FnMacTweak] Dynamic frame rate limit set to: %ld FPS (minDuration: %f)", (long)maxFPS, minDuration);
    }

    double targetDuration = duration;
    if (duration > minDuration) {
        targetDuration = minDuration; // Dynamically bypass the engine's 60 FPS cap
    }
    fnkbmDgHookCommandBuffer(self);
    atomic_fetch_add(&g_dgCbPresIn, 1);
    %orig(drawable, targetDuration);
    atomic_fetch_add(&g_dgCbPresOut, 1);
}

%end

