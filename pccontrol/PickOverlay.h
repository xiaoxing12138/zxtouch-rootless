#ifndef PICK_OVERLAY_H
#define PICK_OVERLAY_H

#import <UIKit/UIKit.h>
#import "FlowScript.h"

/*
 悬浮取点器：铺在游戏之上的全屏窗口，用来替可视化编辑器填坐标 / 颜色 / 识图模板。

 为什么必须做在插件里：抓屏抓的是「屏幕上现在显示的东西」，App 在前台时抓到的只有它自己，
 所以取点只能在注入 SpringBoard 的插件里做。窗口跟着方向转，
 屏幕上的点 × 屏幕缩放 = 触摸指示器坐标，不需要任何旋转 / 缩放换算。

 所有模式都先冻一帧铺满屏：取点期间画面不许再变，否则手指按下的位置和最后看到的像素对不上。

   Point / Color    一个选择器（圆环 + 圆内十字，四段短线指向圆心，交点就是选中的那颗像素）
   Path             一帧上同时放起、终两个选择器，中间一条带方向箭头的轨迹（滑动的走向）
   Rect / Template  拖框选区域；Template 从「未转正原始帧」抠图存盘

 一个可拖动的小面板压在取点图层之上：坐标读数、上下左右微调、准心周围的放大预览、
 当前像素的颜色块。面板读的是冻帧自己的像素，不是实时屏幕——冻了屏还去读实时帧
 只会读到游戏已经跑掉之后的内容。

 结果字典（都已经是触摸指示器坐标，脚本里直接能用）：
   kPickStart / kPickEnd   NSValue(CGPoint)  起点 / 终点（Path 模式就是两个选择器）
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
