// Native-mouse compatibility for Fortnite iOS menus. No bindings or synthesis.
#import "globals.h"
#import "FnMouseRouting.h"
#import <GameController/GameController.h>
#import <objc/runtime.h>
#import <objc/message.h>

@interface FnMouseButtonRoute : NSObject
@property(nonatomic, weak) GCControllerButtonInput *button;
@property(nonatomic, copy) GCControllerButtonValueChangedHandler handler;
@property(nonatomic, assign) BOOL leftButton;
@property(nonatomic, assign) BOOL forwarded;
@end
@implementation FnMouseButtonRoute
@end

static NSHashTable<FnMouseButtonRoute *> *mouseRoutes;
static char pressedRouteKey, valueRouteKey;

static GCMouse *mouseOwningButton(GCControllerButtonInput *button) {
    for (GCMouse *mouse in GCMouse.mice) {
        GCMouseInput *input = mouse.mouseInput;
        if (button == input.leftButton || button == input.rightButton || button == input.middleButton ||
            [input.auxiliaryButtons containsObject:button]) return mouse;
    }
    return nil;
}

static GCControllerButtonValueChangedHandler routeHandler(GCControllerButtonInput *button,
    GCMouse *mouse, GCControllerButtonValueChangedHandler handler, void *key) {
    // The original tweak also delivered native mouse callbacks on main. Keep
    // transitions and button delivery serialized with menu/focus changes.
    mouse.handlerQueue = dispatch_get_main_queue();
    if (!mouseRoutes) mouseRoutes = [NSHashTable weakObjectsHashTable];
    FnMouseButtonRoute *old = objc_getAssociatedObject(button, key);
    if (old) [mouseRoutes removeObject:old];
    objc_setAssociatedObject(button, key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!handler) return nil;
    FnMouseButtonRoute *route = [FnMouseButtonRoute new];
    route.button = button;
    route.handler = handler;
    route.leftButton = button == mouse.mouseInput.leftButton;
    objc_setAssociatedObject(button, key, route, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [mouseRoutes addObject:route];
    return [^(GCControllerButtonInput *input, float value, BOOL pressed) {
        bool forwarded = route.forwarded;
        BOOL deliver = fnRouteMouseButton(pressed, route.leftButton, isMouseLocked,
                                         isPopupVisible, fnMouseInputActive, &forwarded);
        route.forwarded = forwarded;
        if (deliver) route.handler(input, value, pressed);
    } copy];
}

void fnReleaseGameMouseButtons(void) {
    for (FnMouseButtonRoute *route in mouseRoutes.allObjects) {
        if (!route.forwarded) continue;
        route.forwarded = NO;
        GCControllerButtonInput *button = route.button;
        if (button && route.handler) route.handler(button, 0, NO);
    }
}

void fnCancelMouseTouches(void) {
    UIApplication *app = UIApplication.sharedApplication;
    SEL cancel = NSSelectorFromString(@"_cancelAllTouches");
    if ([app respondsToSelector:cancel]) ((void (*)(id, SEL))objc_msgSend)(app, cancel);
}

// iOS Fortnite menus consume touches, even when the executable's mouse-support
// checks have been patched. Preserve the original tweak's unlocked conversion.
%hook UITouch
- (UITouchType)type {
    UITouchType original = %orig;
    return fnMouseTouchIsDirect(original == UITouchTypeIndirectPointer, isMouseLocked)
        ? UITouchTypeDirect : original;
}
%end

// During gameplay the real mouse callback is authoritative. Do not also create
// a touch click/drag, which can activate the mobile joystick or fire twice.
%hook UIWindow
- (void)sendEvent:(UIEvent *)event {
    if (event.type == UIEventTypeTouches) {
        for (UITouch *touch in event.allTouches) {
            if (fnDropMouseTouch(touch.type == UITouchTypeIndirectPointer, isMouseLocked, self == popupWindow)) return;
        }
    }
    %orig;
}
%end

%hook GCControllerButtonInput
- (void)setPressedChangedHandler:(GCControllerButtonValueChangedHandler)handler {
    GCMouse *mouse = mouseOwningButton(self);
    if (!mouse) { %orig; return; } // Physical controller buttons pass through.
    %orig(routeHandler(self, mouse, handler, &pressedRouteKey));
}
- (void)setValueChangedHandler:(GCControllerButtonValueChangedHandler)handler {
    GCMouse *mouse = mouseOwningButton(self);
    if (!mouse) { %orig; return; }
    %orig(routeHandler(self, mouse, handler, &valueRouteKey));
}
%end
