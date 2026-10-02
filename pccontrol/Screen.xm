#include "Screen.h"
#include "Common.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wavailability"
#pragma clang diagnostic ignored "-Wattributes"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#include "headers/IOSurface/IOSurfaceAccelerator.h"
#include "headers/IOSurface/IOMobileFramebuffer.h"
#import "headers/IOSurface/IOSurface.h"
#include "headers/IOSurface/CoreSurface.h"
#pragma clang diagnostic pop

OBJC_EXTERN void CARenderServerRenderDisplay(kern_return_t a, CFStringRef b, IOSurfaceRef surface, int x, int y);
OBJC_EXTERN kern_return_t IOSurfaceLock(IOSurfaceRef buffer, IOSurfaceLockOptions options, uint32_t *seed);
OBJC_EXTERN kern_return_t IOSurfaceUnLock(IOSurfaceRef buffer, IOSurfaceLockOptions options, uint32_t *seed);
OBJC_EXTERN IOSurfaceRef IOSurfaceCreate(CFDictionaryRef dictionary);
OBJC_EXTERN void *IOSurfaceGetBaseAddress(IOSurfaceRef buffer);
OBJC_EXTERN CGImageRef UICreateCGImageFromIOSurface(IOSurfaceRef surface);

static CGFloat device_screen_width = 0;
static CGFloat device_screen_height = 0;

/*
抓屏用的帧缓冲。旧实现每次取色 / 匹配都新建一块 1640x2360x4 ≈ 15.5MB 的 IOSurface、
用完立刻释放，这笔分配开销每次命令都要付一遍；现在只建一次，只有屏幕尺寸变了才重建。
另外 30ms 内到达的多个读屏命令共用同一帧（脚本里「判背包 → 判丹药页」这类连续判据
只需要抓一次屏），触摸之后立刻失效，保证不会读到动作之前的旧画面。
*/
static IOSurfaceRef gFrameSurface = NULL;
static UInt8 *gFramePixels = NULL;
static int gFrameWidth = 0;
static int gFrameHeight = 0;
static int gFrameStride = 0;
static CFTimeInterval gFrameStamp = 0;
static CFTimeInterval gLastRenderSeconds = 0;
static NSLock *gFrameLock = nil;
static const CFTimeInterval kFrameFreshSeconds = 0.03;

@implementation Screen
{
    // device screen size
}


/*
Get the size of the screen and set them.
*/
+ (void)setScreenSize:(CGFloat)x height:(CGFloat) y
{
	device_screen_width = x;
	device_screen_height = y;

	if (device_screen_width == 0 || device_screen_height == 0 || device_screen_width > 10000 || device_screen_height > 10000)
	{
		NSLog(@"com.zjx.springboard: Unable to initialze the screen size. screen width: %f, screen height: %f", device_screen_width, device_screen_height);
	}
	else
	{
		NSLog(@"com.zjx.springboard: successfully initialize the screen size. screen width: %f, screen height: %f", device_screen_width, device_screen_height);
	}
}

+ (int)getScreenOrientation
{
    __block int screenOrientation = -1;

    void (^readOrientation)(void) = ^{
        @try{
            SpringBoard *springboard = (SpringBoard*)[%c(SpringBoard) sharedApplication];
            screenOrientation = [springboard _frontMostAppOrientation];
            //NSLog(@"com.zjx.springboard: orientation %d", screenOrientation);
        }
        @catch (NSException *exception) {
            NSLog(@"com.zjx.springboard: Debug: %@", exception.reason);
        }
    };

    if ([NSThread isMainThread]) {
        readOrientation();
    } else {
        dispatch_sync(dispatch_get_main_queue(), readOrientation);
    }

    return screenOrientation;
}

+ (CGFloat)getScreenWidth
{
    if (device_screen_width == 0)
    {
        NSLog(@"com.zjx.springboard: Cannot get screen width. Maybe you call [Screen getScreenWidth] before springboard getting the screen size.");
    }
    return device_screen_width;
}

+ (CGFloat)getScreenHeight
{
    if (device_screen_height == 0)
    {
        NSLog(@"com.zjx.springboard: Cannot get screen height. Maybe you call [Screen getScreenHeight] before springboard getting the screen size.");
    }
    return device_screen_height;
}

+ (CGFloat)getScale
{    
    return [[UIScreen mainScreen] scale];
}

+ (CGRect)getBounds
{
    return [UIScreen mainScreen].bounds;
}


OBJC_EXTERN UIImage *_UICreateScreenUIImage(void);
+ (NSString*)screenShot
{
    UIImage *screenImage = _UICreateScreenUIImage();
    // Create path.
    NSString *filePath = [getDocumentRoot() stringByAppendingPathComponent:@"screenshot.png"];

    // Save image.
    [UIImagePNGRepresentation(screenImage) writeToFile:filePath atomically:NO];
    return filePath;
}

+ (UIImage*)screenShotUIImage // memory leak, need to be fixed
{
    return _UICreateScreenUIImage();
}

/*
真正抓一帧。调用前必须已持有 gFrameLock。
屏幕的物理帧缓冲永远是竖屏摆放的（UIScreen.bounds 自 iOS 8 起也不随方向变化），
CARenderServerRenderDisplay 会把整块竖屏帧缓冲按 1:1 画到 surface 的左上角。
因此 surface 必须按“竖屏物理尺寸”分配，旧代码在 iPad 上把宽高换成横屏尺寸，
超出部分被裁掉（屏幕右侧约 720px 丢失），导致图像识别 / 取色看不到背包右栏。
这里统一按竖屏物理尺寸分配，像素坐标与触摸引擎使用的竖屏物理像素空间一致。
*/
+ (BOOL)renderFrameLocked
{
    CGFloat scale = [UIScreen mainScreen].scale;
    CGSize screenSize = [UIScreen mainScreen].bounds.size;

    int width = (int)(screenSize.width * scale);
    int height = (int)(screenSize.height * scale);
    if (width > height)
    {
        int temp = width;
        width = height;
        height = temp;
    }
    int bytesPerRow = roundUp(4 * width, 32); // IOSurface 的行跨距必须是 32 的倍数

    if (gFrameSurface && (gFrameWidth != width || gFrameHeight != height))
    {
        CFRelease(gFrameSurface);
        gFrameSurface = NULL;
        gFramePixels = NULL;
    }

    if (!gFrameSurface)
    {
        NSDictionary *properties = @{ @"IOSurfaceAllocSize": @(bytesPerRow * height),
                                      @"IOSurfaceBytesPerElement": @4,
                                      @"IOSurfaceBytesPerRow": @(bytesPerRow),
                                      @"IOSurfaceHeight": @(height),
                                      @"IOSurfaceIsGlobal": @1,
                                      @"IOSurfacePixelFormat": @1111970369, // 'BGRA'
                                      @"IOSurfaceWidth": @(width) };
        gFrameSurface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
        if (!gFrameSurface)
        {
            NSLog(@"com.zjx.springboard: Unable to create IOSurface for screenshot.");
            return NO;
        }
        gFrameWidth = width;
        gFrameHeight = height;
        gFrameStride = bytesPerRow;
        gFramePixels = (UInt8 *)IOSurfaceGetBaseAddress(gFrameSurface);
        if (!gFramePixels)
        {
            NSLog(@"com.zjx.springboard: Unable to get IOSurface base address.");
            CFRelease(gFrameSurface);
            gFrameSurface = NULL;
            return NO;
        }
    }

    IOSurfaceLock(gFrameSurface, 0, NULL);
    CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
    CARenderServerRenderDisplay(0, CFSTR("LCD"), gFrameSurface, 0, 0);
    gLastRenderSeconds = CFAbsoluteTimeGetCurrent() - startedAt;
    IOSurfaceUnLock(gFrameSurface, 0, NULL);
    gFrameStamp = CFAbsoluteTimeGetCurrent();
    return YES;
}

+ (const UInt8 *)framePixelsWithStride:(int *)outStride width:(int *)outWidth height:(int *)outHeight
{
    if (!gFrameLock) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{ gFrameLock = [NSLock new]; });
    }
    [gFrameLock lock];

    BOOL fresh = (gFramePixels != NULL) && ((CFAbsoluteTimeGetCurrent() - gFrameStamp) < kFrameFreshSeconds);
    if (!fresh && ![self renderFrameLocked])
    {
        [gFrameLock unlock];
        return NULL;
    }

    if (outStride) *outStride = gFrameStride;
    if (outWidth) *outWidth = gFrameWidth;
    if (outHeight) *outHeight = gFrameHeight;
    const UInt8 *pixels = gFramePixels;

    [gFrameLock unlock];
    return pixels;
}

+ (void)invalidateFrame
{
    gFrameStamp = 0;
}

+ (double)lastRenderMilliseconds
{
    return gLastRenderSeconds * 1000.0;
}

+ (CGImageRef)createScreenShotCGImageRef
{
    if (![self framePixelsWithStride:NULL width:NULL height:NULL]) return NULL;
    return UICreateCGImageFromIOSurface(gFrameSurface);
}


+ (NSString*)screenShotAlwaysUp
{
     UIImage *screenImage = _UICreateScreenUIImage();
    int orientation = [self getScreenOrientation];

    UIImageOrientation after = UIImageOrientationUp;
    if (orientation == 4)
    {
        after = UIImageOrientationRight;
    }
    else if (orientation == 3)
    {
        after = UIImageOrientationLeft;
    }
    else if (orientation == 2)
    {
        after = UIImageOrientationDown;
    }

    UIImage *result = [UIImage imageWithCGImage:[screenImage CGImage]
              scale:[screenImage scale]
              orientation: after];

    // Create path.
    NSString *filePath = [getDocumentRoot() stringByAppendingPathComponent:@"screenshot.png"];

    // Save image.
    [UIImagePNGRepresentation(result) writeToFile:filePath atomically:NO];
    return filePath;
}
@end
