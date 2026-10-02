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

#endif
