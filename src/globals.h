#import <UIKit/UIKit.h>
#include <stdatomic.h>
#include <stdbool.h>

#define DEVICE_MODEL "iPad17,4"
#define OEM_ID "A3361"
#define kTweakSuiteName @"com.fnmactweak.prefs"
#define tweakDefaults() [[NSUserDefaults alloc] initWithSuiteName:kTweakSuiteName]
#define kBorderlessWindowKey @"fnmactweak.borderlessWindowEnabled"
// Keep the lite preference keys to migrate existing installations.
#define kUnlockFrameRateKey @"fnmactweak.lite.unlockFrameRate"
#define kStayActiveKey @"fnmactweak.lite.stayActive"
#define kMenuShortcutKey @"fnmactweak.lite.menuShortcut"
#define kGraphicsShortcutKey @"fnmactweak.kbm.graphicsShortcut"
#define kCursorShortcutKey @"fnmactweak.lite.cursorShortcut"
#define kDataFolderKey @"fnmactweak.datafolder"
#define FnSettingsChangedNotification @"FnMacTweakKBMSettingsChanged"

#ifdef __cplusplus
extern "C" {
#endif
extern BOOL isBorderlessModeEnabled;
extern BOOL isPopupVisible;
extern BOOL isMouseLocked;
extern BOOL fnMouseInputActive;
extern _Atomic(bool) fnUnlockFrameRate;
extern _Atomic(bool) fnStayActive;
extern _Atomic(double) fnUserFrameLimit;
void fnReadGameFrameLimit(const char *path);
extern UIWindow *popupWindow;
extern NSDictionary *fnMenuShortcut;
extern NSDictionary *fnCursorShortcut;
extern NSDictionary *fnGraphicsShortcut;
extern void (^fnShortcutCapture)(NSDictionary *shortcut);
void fnLoadSettings(void);
void fnSettingsChanged(void);
BOOL fnValidShortcut(id value, BOOL allowEmpty);
NSString *fnShortcutTitle(NSDictionary *shortcut);
void updateBorderlessMode(void);
void fnSetCursorLocked(BOOL locked);
void fnFollowGameCursor(void);
void fnReleaseGameMouseButtons(void);
void fnReleaseGameKeys(void);
void fnReleaseGCKeys(void);
void fnInstallPanelInput(void);
void fnCancelMouseTouches(void);
void fnShowMenu(BOOL show);
void fnInstallRuntime(void);
BOOL fnSelectDataFolder(NSURL *url, NSError **error);
NSURL *fnDataFolder(void);
#ifdef __cplusplus
}
#endif
