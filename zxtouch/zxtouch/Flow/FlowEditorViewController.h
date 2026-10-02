//
//  FlowEditorViewController.h
//  小新Lap 可视化脚本
//
//  可视化编辑器。两种用法：
//    - 顶层：编辑一个脚本包的整条流程（flow.plist 是真源，改完立刻重新生成 main.py）
//    - 分支：编辑一个判断步骤里「成立时 / 不成立时」的动作列表（只能放动作，不能放判断）
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface FlowEditorViewController : UITableViewController

/// 顶层编辑器
- (instancetype)initWithScriptBundlePath:(NSString *)bundlePath;

/// 分支编辑器；直接改传进来的数组（它是外层步骤里的 Then / Else）
- (instancetype)initWithBranchSteps:(NSMutableArray *)steps title:(NSString *)title;

@end

NS_ASSUME_NONNULL_END
