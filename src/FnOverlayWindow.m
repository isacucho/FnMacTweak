#import "FnOverlayWindow.h"
#import "globals.h"

@implementation FnOverlayWindow
- (BOOL)canBecomeKeyWindow { return isPopupVisible; }
- (void)becomeKeyWindow {
    if (isPopupVisible) [super becomeKeyWindow];
}
@end
