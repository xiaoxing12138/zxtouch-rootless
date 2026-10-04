#ifndef FLOW_WINDOW_H
#define FLOW_WINDOW_H

#import <UIKit/UIKit.h>

/*
 可视化流程编辑器。它自己不弹窗 —— 卡片由选项面板（FunctionWindow）提供，
 所以「挑脚本 / 功能页 / 流程编辑页」永远在同一张面板里，不会出现两张卡片。

 主面板始终显示步骤列表（整条流程 / 某条判断的成立·不成立分支页）；
 「添加步骤 / 编辑参数 / 运行与定时设置」都在屏幕中间的子浮窗里完成，主流程始终可见。
 所有改动实时落盘（flow.plist + 重新生成 main.py），没有保存按钮。

 FunctionWindow 实现下面的 FlowEditorHost，提供滚动区与顶栏状态。
*/
@protocol FlowEditorHost <NSObject>
@required
/// 渲染到这个滚动区（面板的内容区）
- (UIScrollView *)flowHostScrollView;
/// 行宽基准（= 面板宽度）
- (CGFloat)flowHostContentWidth;
/// 覆盖层容器：整屏、在卡片之上（子浮窗挂这里，不受卡片尺寸裁剪）
- (UIView *)flowHostOverlayContainer;
/// 顶栏左边那个按钮：canGoBack=NO 显示「脚本：title」点=挑脚本，YES 显示「← title」点=返回
- (void)flowHostSetNavigationTitle:(NSString *)title canGoBack:(BOOL)canGoBack;
/// 取点时把卡片藏起来（卡片会被烤进冻结帧、也挡游戏画面）
- (void)flowHostSetCardHidden:(BOOL)hidden;
@end

@interface FlowWindow : NSObject
+ (instancetype)shared;

- (void)setHost:(id<FlowEditorHost>)host;

/// 载入脚本包的流程并回到根页；脚本里没有 flow.plist 就用一份空流程
- (void)loadBundle:(NSString *)bundlePath;

/// 重画当前页
- (void)refresh;

/// 顶栏「设置」：弹出运行方式（循环次数/间隔）+ 定时启动/结束 的子浮窗
- (void)showSettings;

/// 顶栏左键返回上一页（根页什么都不做）
- (void)goBack;

/// 收起编辑器自己弹出的覆盖层（子浮窗 / 行菜单）；面板整体收起时要调
- (void)hideOverlays;

@end

// socket 任务 44：44;;open;;<脚本包绝对路径> / 44;;new;;<脚本包绝对路径>
NSString *handleFlowEditorTaskWithRawData(UInt8 *eventData, NSError **error);

#endif
