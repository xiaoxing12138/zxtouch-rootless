#ifndef FLOW_WINDOW_H
#define FLOW_WINDOW_H

#import <Foundation/Foundation.h>

/*
 可视化脚本编辑器（悬浮卡片，注入 SpringBoard）。

 为什么做在插件里而不是 App 里：编辑时要「从屏幕取坐标 / 取色 / 框模板」，
 而抓屏抓的是屏幕上现在显示的东西 —— App 在前台时只抓得到它自己。
 放进插件后，取点器盖在游戏上，取到的就是游戏画面，而且结果直接回调，
 中间不需要任何进程间通信。

 页面栈：列表页（整条流程 / 某条判断的成立·不成立）→ 参数页 → 分支列表页，
 根页底部多两块「循环次数 / 每轮间隔」。保存 = 写 flow.plist + 重新生成 main.py。
*/
@interface FlowWindow : NSObject
+ (instancetype)shared;

/// 打开脚本包里的流程；脚本里没有 flow.plist 就用一份空流程（保存会覆盖手写的 main.py，会提醒）
- (void)openBundle:(NSString *)bundlePath;
/// 新建一个可视化脚本包（建目录 + 空流程）并打开
- (void)createBundleAtPath:(NSString *)bundlePath;
- (void)hide;
- (BOOL)isShown;

@end

// socket 任务 44：44;;open;;<脚本包绝对路径> / 44;;new;;<脚本包绝对路径>
NSString *handleFlowEditorTaskWithRawData(UInt8 *eventData, NSError **error);

#endif