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
