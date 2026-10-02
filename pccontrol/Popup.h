#ifndef POPUP_H
#define POPUP_H

#import <Foundation/Foundation.h>

@interface PopupWindow : NSObject
- (void) show;
- (void) hide;
- (void) setAppearanceMode:(NSInteger)mode;
- (BOOL) isShown;
@end

// 界面外观取自配置：appearance_mode 直接存 UIUserInterfaceStyle
// （0跟随系统 1浅色 2深色），旧配置只有 dark_mode 布尔值。
NSInteger ZXAppearanceModeFromConfig(NSDictionary *config);

void applyPanelAppearanceMode(NSInteger mode);

#endif