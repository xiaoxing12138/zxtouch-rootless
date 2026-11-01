#ifndef SCREEN_H
#define SCREEN_H

#import <UIKit/UIKit.h>


@interface Screen :NSObject
{
    
}

+ (void)setScreenSize:(CGFloat)x height:(CGFloat) y;
+ (int)getScreenOrientation;
+ (CGFloat)getScreenWidth;
+ (CGFloat)getScreenHeight;
+ (CGFloat)getScale;
+ (NSString*)screenShot;
+ (CGRect)getBounds;
+ (NSString*)screenShotAlwaysUp;
+ (UIImage*)screenShotUIImage;
+ (void)releaseUIImage:(UIImage**)img;
+ (CGImageRef)createScreenShotCGImageRef;

// 抓一帧并返回原始像素首地址（竖屏物理尺寸，BGRA 布局，行跨距由 outStride 带回）。
// 同一帧窗口（30ms）内多个读屏命令共用同一张；触摸之后立即失效。
// 拿不到返回 NULL。像素在下一帧渲染前一直有效，调用方只用不改。
+ (const UInt8 *)framePixelsWithStride:(int *)outStride width:(int *)outWidth height:(int *)outHeight;
+ (void)invalidateFrame;
+ (double)lastRenderMilliseconds;

@end

/*
「触摸指示器坐标」与「屏幕原始帧坐标」互转，全工程只此一份。

- 触摸指示器坐标：当前方向的像素，用户肉眼看到、脚本里写的那个数（横屏 2360×1640 进制）。
- 屏幕原始帧坐标：竖屏物理像素（1640×2360），抓屏 / 取色 / 找色 / 识图 / 触摸引擎用的是它。

四条链路（触摸、取色、找色、识图）必须共用这里的换算，否则「看到哪、写哪、点哪/取哪」对不上。
等式都是 90° 的倍数、进出都是整数，不存在 400 变 399 的精度问题。
*/
/*
方向判定的唯一入口。触摸注入、取色、找色、识图、框选画面的旋转全都问这一个函数——
任何一处自己判断方向，都会和别处差 90°。

只有一条来源：前台 App 的方向。读不到就按竖屏。

**不要给这里加任何兜底**（设备物理方向、状态栏方向都试过，全部翻车）：
- 设备方向 = 「手机怎么拿的」，不是「界面朝哪」；手机横着拿而界面锁竖屏时会转错 90°。
- 状态栏方向 = 「SpringBoard 认为前台是谁」，主屏横屏布局时也会转错 90°。
- 「读不到」本身就意味着「没有前台 App，界面是 SpringBoard 自己的」，那它就是竖屏。
*/
int ZXEffectiveOrientation(void);
int ZXStatusBarOrientation(void);       // 仅自检诊断用，-1 = 无效
CGFloat ZXMainWindowWidth(void);        // 仅自检诊断用：SpringBoard 窗口宽（判断界面横竖）
CGFloat ZXMainWindowHeight(void);
UIInterfaceOrientation ZXInterfaceFromDeviceOrientation(UIDeviceOrientation deviceOrientation);  // 仅触摸指示器用

CGPoint ZXFramePointFromIndicatorPoint(CGPoint indicatorPoint);
CGPoint ZXIndicatorPointFromFramePoint(CGPoint framePoint);
CGRect ZXFrameRectFromIndicatorRect(CGRect indicatorRect);
CGRect ZXIndicatorRectFromFrameRect(CGRect frameRect);

#endif
