#ifndef PICK_OVERLAY_H
#define PICK_OVERLAY_H

#import <UIKit/UIKit.h>
#import "FlowScript.h"

/*
 悬浮取点器：铺在游戏之上的全屏窗口，用来替可视化编辑器填坐标 / 颜色 / 识图模板。

 为什么必须做在插件里：抓屏抓的是「屏幕上现在显示的东西」，App 在前台时抓到的只有它自己，
 所以取点只能在注入 SpringBoard 的插件里做。窗口跟着方向转，
 屏幕上的点 × 屏幕缩放 = 触摸指示器坐标，不需要任何旋转 / 缩放换算。

   Point / Color  不冻屏：可拖的十字（只在十字周围一小块响应，别处触摸穿给游戏），实时读数
   Rect / Template 冻一帧铺满屏：拖框选择，框外压暗；识图模板从「未转正原始帧」抠出来存盘

 结果字典（都已经是触摸指示器坐标，脚本里直接能用）：
   kPickStart / kPickEnd   NSValue(CGPoint)  拖动的起点 / 终点（方向保留，滑动要用）
   kPickRect               NSValue(CGRect)   外接矩形
   kPickHex                NSString          "RRGGBB"，取色模式才有
   kPickTemplate           NSString          模板文件名（已写进 tpl 目录），识图模式才有
*/
extern NSString * const kPickStart;
extern NSString * const kPickEnd;
extern NSString * const kPickRect;
extern NSString * const kPickHex;
extern NSString * const kPickTemplate;

@interface PickOverlay : NSObject

+ (void)presentWithMode:(FlowPickMode)mode
             completion:(void (^)(NSDictionary *result))completion
                 cancel:(void (^)(void))cancel;
+ (void)dismiss;
+ (BOOL)isShown;

@end

#endif