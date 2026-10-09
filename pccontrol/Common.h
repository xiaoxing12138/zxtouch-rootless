#ifndef COMMON_H
#define COMMON_H

#import <UIKit/UIKit.h>
#include <signal.h>
#include <dispatch/dispatch.h>

#define SYSTEM_VERSION_EQUAL_TO(v)                  ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] == NSOrderedSame)
#define SYSTEM_VERSION_GREATER_THAN(v)              ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] == NSOrderedDescending)
#define SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(v)  ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] != NSOrderedAscending)
#define SYSTEM_VERSION_LESS_THAN(v)                 ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] == NSOrderedAscending)
#define SYSTEM_VERSION_LESS_THAN_OR_EQUAL_TO(v)     ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] != NSOrderedDescending)


@interface SpringBoard : UIApplication
-(int)_frontMostAppOrientation;
-(id)_accessibilityFrontMostApplication;
@end



@interface SBApplication : NSObject {
}
@property (nonatomic, retain, readonly) NSString *displayIdentifier NS_DEPRECATED_IOS(4_0, 8_0);
@property (nonatomic, retain, readonly) NSString *bundleIdentifier NS_AVAILABLE_IOS(8_0); // Technically available in iOS 5 as well (https://github.com/MP0w/iOS-Headers/blob/master/iOS5.0/SpringBoard/SB.h#L143) and even iOS 4, but you probably don't want to use that (see: Camera/Photos).
@property (nonatomic, retain, readonly) NSString *displayName;
@end

int getRandomNumberInt(int min, int max);
float getRandomNumberFloat(float min, float max);
NSString* getDocumentRoot();
NSString* getScriptsFolder();
void swapCGFloat(CGFloat *a, CGFloat *b);
NSString *getConfigFilePath();
NSString *getCommonConfigFilePath();
pid_t system2(const char *command, int *infp, int *outfp);
pid_t system2Cancelable(const char *command, int *infp, int *outfp,
                        pid_t *processGroup, volatile sig_atomic_t *cancelRequested);
int call_system(const char *cmd);
int roundUp(int numToRound, int multiple);
Boolean isIpad();
NSString* getDeviceName();

/*
 Main-queue UI guard.

 An Objective-C exception raised inside a dispatch_async(main) block unwinds
 straight out of the block and terminates the host process. In a tweak injected
 into SpringBoard that host is SpringBoard itself, so a single failing UIKit
 call is enough to drop the device into safe mode. Routing every main-queue
 block through ZXSafeMainAsync turns that crash into a log entry instead.
*/
void ZXLogUIException(NSException *exception);

/*
 输入框开始编辑前，保证它所在的窗口是 key window。
 Apple QA1813：输入框的 window 不是 key window 时系统键盘不会弹（部分设备/系统版本会中招）。
*/
void ZXMakeWindowKeyIfNeeded(UIWindow *window);

/*
 数值输入框后面挂的「上下箭头」步进器（纯数值字段用）。
 点一下改 field.text 并触发 EditingChanged，复用调用方已经挂好的落盘逻辑。
 步长：整数按 1；小数按当前值量级（>=100 走 10，>=10 走 1，>=1 走 0.1，否则 0.01）。
*/
UIView *ZXMakeNumberStepper(UITextField *field, BOOL integer);

/// 键盘上方工具条：左边实时显示「title：当前输入值」，右边「完成」。返回值直接赋给 textField.inputAccessoryView
UIView *ZXFieldKeyboardAccessory(UITextField *field, NSString *title);

/// 找到 root 子树里的第一响应者（键盘避让要用）；找不到返回 nil
UIView *ZXFirstResponderView(UIView *root);

/// 键盘顶边在 view 所在窗口坐标系里的 y；键盘没出来时返回 CGFLOAT_MAX（表示不挡）
CGFloat ZXKeyboardTopForView(UIView *view);

/*
 键盘避让：先把输入框滚进它所在的 UIScrollView 可见区，再返回「滚完之后仍被键盘挡住的高度」。
 返回值 > 0 时，调用方把承载它的卡片整体上移这么多。
*/
CGFloat ZXScrollResponderIntoView(UIView *responder, UIScrollView *scroll, CGFloat keyboardTop);

/*
 面板配色：深浅两套写进同一个动态颜色，跟着窗口的 overrideUserInterfaceStyle 切。
 全工程只此一份，别在各家 view 里再散落写死色值。
*/
typedef NS_ENUM(NSInteger, ZXPaletteRole) {
    ZXPalCard = 0,   // 卡片 / 面板底
    ZXPalRow,        // 列表行底
    ZXPalLine,       // 描边 / 分隔线
    ZXPalText,       // 主文字
    ZXPalSub,        // 次文字
    ZXPalField,      // 输入框底
    ZXPalAccent,     // 主操作（青绿）
    ZXPalDanger,     // 危险 / 删除
    ZXPalValue,      // 参数数值高亮
};
UIColor *ZXPalette(ZXPaletteRole role);

/// 解析 #RRGGBB 十六进制颜色字符串，失败返回 nil
UIColor *ZXColorFromHex(NSString *hex);

/*
 随行小菜单（非强弹窗）：锚在 anchor 旁弹出，点别处或选中后消失。
 items 每项：@{ @"title": 文字（必填）, @"icon": SF Symbol 名（可省）,
               @"destructive": @YES（可省，红色）, @"action": dispatch_block_t（选中执行） }
*/
void ZXShowMiniMenuNearView(UIView *anchor, NSArray<NSDictionary *> *items);

static inline void ZXSafeMainAsync(dispatch_block_t block)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            block();
        } @catch (NSException *exception) {
            ZXLogUIException(exception);
        }
    });
}

#endif
