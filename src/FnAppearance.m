#import "FnAppearance.h"
#import <objc/message.h>

// AppKit owns the user's accent preference for iOS apps running on macOS.
// Convert through sRGB rather than bridging NSColor objects into UIKit.
UIColor *fnAccentColor(void) {
    Class colors = NSClassFromString(@"NSColor");
    Class spaces = NSClassFromString(@"NSColorSpace");
    SEL accentSelector = NSSelectorFromString(@"controlAccentColor");
    SEL spaceSelector = NSSelectorFromString(@"sRGBColorSpace");
    if ([colors respondsToSelector:accentSelector] && [spaces respondsToSelector:spaceSelector]) {
        id accent = ((id (*)(id, SEL))objc_msgSend)(colors, accentSelector);
        id space = ((id (*)(id, SEL))objc_msgSend)(spaces, spaceSelector);
        SEL convert = NSSelectorFromString(@"colorUsingColorSpace:");
        if ([accent respondsToSelector:convert]) {
            id rgb = ((id (*)(id, SEL, id))objc_msgSend)(accent, convert, space);
            SEL cgColor = NSSelectorFromString(@"CGColor");
            if ([rgb respondsToSelector:cgColor]) {
                CGColorRef color = ((CGColorRef (*)(id, SEL))objc_msgSend)(rgb, cgColor);
                if (color) return [UIColor colorWithCGColor:color];
            }
        }
    }
    return UIColor.systemBlueColor;
}

static void applySwitchAccent(UIView *view, UIColor *color) {
    if ([view isKindOfClass:UISwitch.class]) ((UISwitch *)view).onTintColor = color;
    for (UIView *child in view.subviews) applySwitchAccent(child, color);
}

void fnApplyAccentColor(UIView *view) {
    UIColor *color = fnAccentColor();
    view.tintColor = color;
    applySwitchAccent(view, color);
}
