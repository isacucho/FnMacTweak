#pragma once
#import <UIKit/UIKit.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef NS_ENUM(NSInteger, FnPanelTab) { FnPanelGraphics = 0, FnPanelSettings = 1 };
UIViewController *fnCreateSettingsPanel(FnPanelTab tab);
FnPanelTab fnCurrentPanelTab(void);
void fnSelectPanelTab(FnPanelTab tab);
void fnShowPanel(FnPanelTab tab);
void fnInstallGraphics(void);
void fnGraphicsFrameLayer(id layer);
void fnGraphicsCursorIntoGame(void);
float fnGraphicsMenuWheelPlace(void);
uint64_t fnGraphicsBeginFrame(void);
void fnGraphicsEndFrame(uint64_t start);
void fnGraphicsPacerTick(void);
#ifdef __cplusplus
}
#endif
