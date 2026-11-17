// Keep the settings overlay isolated from Fortnite's native input handlers.
#import "globals.h"
#import "FnGraphics.h"
#import <GameController/GameController.h>
#import <objc/message.h>
#import <math.h>

@interface FnPanelKey : NSObject
@property(nonatomic) NSInteger code;
@property(nonatomic, copy) NSString *characters;
@end
@implementation FnPanelKey
- (id)key { return self; }
- (NSInteger)keyCode { return self.code; }
- (NSString *)charactersIgnoringModifiers { return self.characters; }
@end

static __weak id gameKeyTarget;
static NSMutableDictionary<NSNumber *, FnPanelKey *> *heldKeys;
static BOOL releasingKeys;

void fnReleaseGameKeys(void) {
    id target = gameKeyTarget;
    SEL method = NSSelectorFromString(@"ProcessKeyPresses:eventType:");
    if (!heldKeys.count || !target || ![target respondsToSelector:method]) return;
    NSSet *keys = [NSSet setWithArray:heldKeys.allValues];
    [heldKeys removeAllObjects];
    releasingKeys = YES;
    ((BOOL (*)(id, SEL, NSSet *, int))objc_msgSend)(target, method, keys, 1);
    releasingKeys = NO;
}

%hook IOSViewController
- (BOOL)ProcessKeyPresses:(NSSet *)presses eventType:(int)type {
    if (releasingKeys) return %orig;
    if (isPopupVisible || !fnMouseInputActive) return YES;
    gameKeyTarget = self;
    if (!heldKeys) heldKeys = [NSMutableDictionary dictionary];
    NSMutableSet *deliver = [NSMutableSet set];
    for (UIPress *press in presses) {
        UIKey *key = press.key;
        if (!key) { [deliver addObject:press]; continue; }
        NSNumber *code = @(key.keyCode);
        if (type == 0) {
            FnPanelKey *copy = [FnPanelKey new];
            copy.code = key.keyCode;
            copy.characters = key.characters ?: @"";
            heldKeys[code] = copy;
            [deliver addObject:press];
        } else if (type == 1) {
            // Match the identity used at key-down even if modifiers changed.
            FnPanelKey *copy = heldKeys[code];
            if (copy) { [deliver addObject:copy]; [heldKeys removeObjectForKey:code]; }
        } else [deliver addObject:press];
    }
    if (!deliver.count) return YES;
    return %orig(deliver, type);
}
%end

// Alternate GameController keyboard path, used by some engine builds.
static __weak GCKeyboardInput *keyboardInput;
static GCKeyboardValueChangedHandler keyboardHandler;
static NSMutableDictionary<NSNumber *, GCControllerButtonInput *> *keyboardDown;

void fnReleaseGCKeys(void) {
    NSDictionary *keys = [keyboardDown copy];
    [keyboardDown removeAllObjects];
    for (NSNumber *code in keys)
        if (keyboardHandler && keyboardInput) keyboardHandler(keyboardInput, keys[code], (GCKeyCode)code.integerValue, NO);
}

%hook GCKeyboardInput
- (void)setKeyChangedHandler:(GCKeyboardValueChangedHandler)handler {
    fnReleaseGCKeys();
    keyboardInput = self;
    keyboardHandler = handler;
    if (!handler) { %orig; return; }
    if (!keyboardDown) keyboardDown = [NSMutableDictionary dictionary];
    GCKeyboardValueChangedHandler wrapped = ^(GCKeyboardInput *input, GCControllerButtonInput *button, GCKeyCode code, BOOL pressed) {
        if (pressed) {
            if (isPopupVisible || !fnMouseInputActive) return;
            keyboardDown[@(code)] = button;
        } else {
            if (!keyboardDown[@(code)]) return;
            [keyboardDown removeObjectForKey:@(code)];
        }
        handler(input, button, code, pressed);
    };
    %orig(wrapped);
}
%end

// v3's patched wheel handler accepts the pointer position in the x argument.
static GCControllerDirectionPad *gameScrollPad;
static void (^gameScrollHandler)(GCControllerDirectionPad *, float, float);
static id scrollMonitor;

%hook GCControllerDirectionPad
- (void)setValueChangedHandler:(void (^)(GCControllerDirectionPad *, float, float))handler {
    BOOL mouseScroll = NO;
    for (GCMouse *mouse in GCMouse.mice) if (mouse.mouseInput.scroll == self) { mouseScroll = YES; break; }
    if (!mouseScroll) { %orig; return; }
    gameScrollPad = handler ? self : nil;
    gameScrollHandler = handler;
    // AppKit provides one wheel source for mice and trackpads; suppress duplicates.
    void (^wrapped)(GCControllerDirectionPad *, float, float) = nil;
    if (handler) wrapped = ^(GCControllerDirectionPad *pad, float x, float y) {};
    %orig(wrapped);
}
%end

void fnInstallPanelInput(void) {
    Class events = NSClassFromString(@"NSEvent");
    SEL install = NSSelectorFromString(@"addLocalMonitorForEventsMatchingMask:handler:");
    if (![events respondsToSelector:install]) return;
    __block double carry = 0;
    __block CFTimeInterval previous = 0;
    scrollMonitor = ((id (*)(id, SEL, unsigned long long, id))objc_msgSend)(events, install, 1ULL << 22, ^id(id event) {
        if (!fnMouseInputActive || isPopupVisible) { carry = 0; return event; }
        if (!gameScrollHandler || !gameScrollPad) return event;
        double delta = ((CGFloat (*)(id, SEL))objc_msgSend)(event, NSSelectorFromString(@"scrollingDeltaY"));
        BOOL precise = ((BOOL (*)(id, SEL))objc_msgSend)(event, NSSelectorFromString(@"hasPreciseScrollingDeltas"));
        CFTimeInterval now = CACurrentMediaTime();
        if (now - previous > 0.25 || (carry && delta && (carry > 0) != (delta > 0))) carry = 0;
        previous = now;
        carry += precise ? delta / 10.0 : delta;
        int steps = (int)trunc(carry);
        carry -= steps;
        // Bound a single event's work without losing fractional trackpad motion.
        steps = MAX(-32, MIN(32, steps));
        float place = isMouseLocked ? 0 : fnGraphicsMenuWheelPlace();
        for (int i = 0; i < abs(steps); i++) gameScrollHandler(gameScrollPad, place, steps > 0 ? 1 : -1);
        return nil;
    });
}
