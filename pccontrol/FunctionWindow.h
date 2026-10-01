#ifndef FUNCTION_WINDOW_H
#define FUNCTION_WINDOW_H

#import <Foundation/Foundation.h>

// 独立的功能页窗口：脚本切换 + 选项区 + 功能区 + 全选 / 全不选 / 运行。
// 从老控制面板 PopupWindow 里彻底解耦出来，自行持有 UIWindow，不依赖任何全局变量。
@interface FunctionWindow : NSObject
+ (instancetype) shared;
- (void) show;
- (void) hide;
- (BOOL) isShown;
@end

#endif