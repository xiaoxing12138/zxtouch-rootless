#ifndef FUNCTION_WINDOW_H
#define FUNCTION_WINDOW_H

#import <Foundation/Foundation.h>

// 独立的功能页（选项面板）窗口：脚本切换 + 选项区 + 功能区 + 全选 / 全不选 / 运行。
// 自持 UIWindow，不依赖任何全局变量（老控制面板 PopupWindow 已移除）。
@interface FunctionWindow : NSObject
+ (instancetype) shared;
- (void) show;
- (void) hide;
- (BOOL) isShown;

// 界面外观：0 跟随系统 1 浅色 2 深色
- (void) setAppearanceMode:(NSInteger)mode;

// 可视化脚本：打开某个脚本包的流程编辑（面板里点脚本、App 发 44 命令都走这里）
- (void) openFlowBundle:(NSString *)bundlePath;
// 新建可视化脚本包并直接打开编辑器（App 发 44;;new;; 时用）
- (void) createFlowScriptAtPath:(NSString *)bundlePath;
@end

// 界面外观取自配置：appearance_mode 直接存 UIUserInterfaceStyle
// （0跟随系统 1浅色 2深色），旧配置只有 dark_mode 布尔值。
NSInteger ZXAppearanceModeFromConfig(NSDictionary *config);

// 把界面外观套到选项面板上（App 改设置后通过 903 命令调用）
void applyPanelAppearanceMode(NSInteger mode);

#endif