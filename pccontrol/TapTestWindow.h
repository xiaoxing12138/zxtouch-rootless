#ifndef TAP_TEST_WINDOW_H
#define TAP_TEST_WINDOW_H

#import <UIKit/UIKit.h>

@interface TapTestWindow : NSObject

/// 显示 SpringBoard 进程内的全屏透明坐标测试窗口。
/// 用户点击屏幕任意位置都会记录：当前 orientation、screen bounds、
/// 点击的屏幕坐标、点击的 window 坐标。窗口本身使用 portrait 固定尺寸模型。
+ (void)show;

+ (void)hide;

+ (BOOL)isVisible;

/// 清空所有点击记录
+ (void)clearRecords;

/// 返回当前所有点击记录的字典数组（可 JSON 序列化）
+ (NSArray<NSDictionary *> *)tapRecords;

@end

#endif
