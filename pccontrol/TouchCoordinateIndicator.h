#ifndef TOUCH_COORDINATE_INDICATOR_H
#define TOUCH_COORDINATE_INDICATOR_H

#import <UIKit/UIKit.h>

/*
 触摸坐标悬浮窗：复刻网速悬浮窗（同款 FMPassthroughWindow + 四角定位 + X/Y 边距），
 用于常驻显示当前触点的屏幕坐标。

 数据来源：触摸指示器的 IOHID 回调（TouchIndicatorWindow.xm）。本悬浮窗不自己创建
 IOHID client —— 因此必须先开启「触摸指示器」，坐标悬浮窗才会有数据。

 坐标单位：像素（= pt × scale），与触摸指示器红点右侧的小标签完全一致。
 */
@interface TouchCoordinateIndicator : NSObject

+ (void)setEnabled:(BOOL)enabled;
+ (BOOL)isEnabled;

// 只重新读取配置（位置/边距/字号/颜色/空闲隐藏/多点模式），不改变总开关
+ (void)reloadConfig;

// 以下三个方法由 TouchIndicatorWindow 的触摸回调驱动，可在任意线程调用。
// xPx / yPx 为像素坐标（已经乘过 scale）。
+ (void)touchBeganWithIndex:(int)index xPx:(CGFloat)xPx yPx:(CGFloat)yPx;
+ (void)touchMovedWithIndex:(int)index xPx:(CGFloat)xPx yPx:(CGFloat)yPx;
+ (void)touchEndedWithIndex:(int)index;

// 返回调试信息字典；window 尚未创建时返回 nil。必须在主线程调用。
+ (NSDictionary *)debugInfo;

@end

NSString *handleTouchCoordinateTaskWithRawData(UInt8 *eventData, NSError **error);

#endif