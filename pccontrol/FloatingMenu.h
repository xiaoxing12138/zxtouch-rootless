#ifndef FLOATING_MENU_H
#define FLOATING_MENU_H

#import <UIKit/UIKit.h>

// 全屏透传 UIWindow 子类：
// 1) hitTest 返回 nil 让触摸穿透到下层；
// 2) portraitFrame 属性 + override setFrame：拦截 UIWindowScene 强制改 frame，
//    确保 window.frame 永远是竖屏固定坐标系（portrait 尺寸）。
@interface FMPassthroughWindow : UIWindow
@property (nonatomic, assign) CGRect portraitFrame;
@end

/*
 * 按键精灵式悬浮控制按钮（注入 SpringBoard，rootless）。
 *
 * 常驻一个 48pt 圆形悬浮按钮，可拖动、可展开「启动 / 设置 / 返回」三个
 * 纵向菜单按钮。所有配置存放在 getCommonConfigFilePath() 返回的 plist 中：
 *
 *   floating_menu_enabled   BOOL      是否开启
 *   floating_menu_edge      NSNumber  吸附边：1=视觉右边(默认) 0=左边
 *   floating_menu_y_ratio   NSNumber  圆点纵向位置比例 0..1
 *   floating_menu_script    NSString  选中的 .bdl 脚本绝对路径
 *   （旧版 floating_menu_x/y 仍可被读取并自动迁移，不再写入）
 */
@interface FloatingMenu : NSObject

+ (instancetype)shared;

// 开关悬浮按钮；同时持久化 floating_menu_enabled
+ (void)setEnabled:(BOOL)enabled;
+ (BOOL)isEnabled;

// 重新读取 plist 并应用全部配置（enabled、位置、脚本）
+ (void)reloadConfig;

// 返回当前悬浮按钮的调试信息字典；若 window 尚未创建则返回 nil
+ (NSDictionary *)debugInfo;

// 脚本运行中旋转光圈特效
+ (void)startRunningSpinner;
+ (void)stopRunningSpinner;

// 「启动」钮三态：按当前脚本状态刷新（未运行=启动 / 运行中=暂停 / 已暂停=继续）
+ (void)refreshScriptPlayState;
// 脚本结束或被停止后强制回到「未运行」态（此时 getter 可能还没更新，不能靠查询）
+ (void)setScriptIdle;

// 获取当前前台可用的 UIWindowScene（iOS 13+ 创建可渲染 window 必需）
+ (UIWindowScene *)preferredWindowScene;

@end

// socket 任务 32：32;;1 开启 / 32;;0 关闭 / 32;;2 查询（"0;;1\r\n" 或 "0;;0\r\n"）
NSString *handleFloatingMenuTaskWithRawData(UInt8 *eventData, NSError **error);

#endif
