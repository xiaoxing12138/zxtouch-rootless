//
//  ScheduleSettingsViewController.h
//  小新Lap 可视化脚本
//
//  定时启动 / 定时结束。这些设置写在脚本包 info.plist 的 `Schedule` 字典里，
//  由常驻 SpringBoard 的引擎调度器（每 20 秒一轮）读取并执行 —— 脚本自己跑没起来时
//  没人能读它，所以定时只能放在引擎里。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ScheduleSettingsViewController : UITableViewController

- (instancetype)initWithScriptBundlePath:(NSString *)bundlePath;

/// 一句话概括某个脚本的定时设置，没设置返回「未设置（手动启动）」。
/// 列表和编辑器都用它，保证只有这一份文案。
+ (NSString *)summaryForBundle:(NSString *)bundlePath;

@end

NS_ASSUME_NONNULL_END
