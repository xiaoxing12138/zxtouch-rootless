#ifndef NET_SPEED_INDICATOR_H
#define NET_SPEED_INDICATOR_H

#import <UIKit/UIKit.h>

@interface NetSpeedIndicator : NSObject

+ (void)setEnabled:(BOOL)enabled;
+ (BOOL)isEnabled;
+ (void)reloadConfig;

// 返回当前网速窗的调试信息字典（位置、尺寸、方向、window 是否 hidden 等）；
// 若 window 尚未创建则返回 nil。必须在主线程调用。
+ (NSDictionary *)debugInfo;

@end

NSString *handleNetSpeedIndicatorTaskWithRawData(UInt8 *eventData, NSError **error);

#endif
