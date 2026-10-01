#ifndef POPUP_H
#define POPUP_H

#import <Foundation/Foundation.h>

@interface PopupWindow : NSObject
- (void) show;
// 打开面板并直接停在「功能」页（悬浮菜单的「功能」按钮走这里）
- (void) showFunctionPage;
- (void) hide;
- (void) setDarkMode:(BOOL)dark;
- (BOOL) isShown;
@end

void applyPanelDarkMode(BOOL dark);

#endif