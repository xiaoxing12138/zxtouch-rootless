#include "ColorPicker.h"
#include "Screen.h"
#import <CoreGraphics/CoreGraphics.h>
#import <mach/mach.h>

#define COLOR_SEARCHER_SEARCH_SINGLE_POINT 1

NSDictionary* getRGBFromRawData(UInt8 *eventData, NSError **error)
{
    NSArray *data = [[NSString stringWithFormat:@"%s", eventData] componentsSeparatedByString:@";;"];
    if ([data count] < 2)
    {
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;无法取色，数据格式应为 \"x;;y\"（x、y 为坐标）\r\n"}];
        return @{@"blue": @(-1), @"red": @(-1), @"green": @(-1)};
    }

    int stride = 0, width = 0, height = 0;
    const UInt8 *buffer = [Screen framePixelsWithStride:&stride width:&width height:&height];
    if (!buffer)
    {
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;无法取色：内部错误，截图为空。\r\n"}];
        return @{@"blue": @(-1), @"red": @(-1), @"green": @(-1)};
    }

    // 脚本里写的是触摸指示器上看到的像素，这里读的是竖屏原始帧，先换算（全工程只此一份）
    CGPoint framePoint = ZXFramePointFromIndicatorPoint(CGPointMake([data[0] intValue], [data[1] intValue]));
    int x = (int)lround(framePoint.x);
    int y = (int)lround(framePoint.y);
    // 越界不报错也不返回垃圾：夹到最近的合法像素，保证 24 小时跑不会因为一次越界读炸掉脚本
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x >= width) x = width - 1;
    if (y >= height) y = height - 1;

    return [ColorPicker colorAtPositionFromBuffer:buffer stride:stride x:x andY:y];
}

NSString* searchRGBFromRawData(UInt8 *eventData, NSError **error)
{
    NSArray *data = [[NSString stringWithFormat:@"%s", eventData] componentsSeparatedByString:@";;"];
    
    int searchType = [data[0] intValue];
    
    if (searchType == COLOR_SEARCHER_SEARCH_SINGLE_POINT)
    {
        
        if ([data count] < 12)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;无法搜索颜色，数据格式应为 \"searchtype;;x;;y;;width;;height;;redMin;;redMax;;greenMin;;greenMax;;blueMin;;blueMax;;skip\"（搜索类型;;x 坐标;;y 坐标;;宽度;;高度;;红色最小值;;红色最大值;;绿色最小值;;绿色最大值;;蓝色最小值;;蓝色最大值;;步长）\r\n"}];
            return @"";
        }
        int stride = 0, screenWidth = 0, screenHeight = 0;
        const UInt8 *buffer = [Screen framePixelsWithStride:&stride width:&screenWidth height:&screenHeight];

        if (!buffer)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;无法搜索颜色：内部错误，截图为空。\r\n"}];
            return @"";
        }


        // 搜索区域按触摸指示器坐标写，换成竖屏原始帧的矩形再扫（全工程只此一份换算）
        CGRect frameRect = ZXFrameRectFromIndicatorRect(CGRectMake([data[1] intValue], [data[2] intValue],
                                                                  [data[3] intValue], [data[4] intValue]));
        int x = (int)lround(CGRectGetMinX(frameRect));
        int y = (int)lround(CGRectGetMinY(frameRect));
        int width =  (int)lround(CGRectGetWidth(frameRect));
        int height =  (int)lround(CGRectGetHeight(frameRect));
        int redMin = [data[5] intValue];
        int redMax = [data[6] intValue];
        int greenMin =  [data[7] intValue];
        int greenMax =  [data[8] intValue];
        int blueMin =  [data[9] intValue];
        int blueMax =  [data[10] intValue];
        int skip =  [data[11] intValue];

        if (x > screenWidth)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"-1;;x 坐标超出屏幕宽度范围。屏幕宽度为 %d，你传入的 x 为 %d\r\n", screenWidth, x]}];
            NSLog(@"com.zjx.springboard: %@", *error);
            return @"";
        }
        if (y > screenHeight)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"-1;;y 坐标超出屏幕高度范围。屏幕高度为 %d，你传入的 y 为 %d\r\n", screenHeight, y]}];
            NSLog(@"com.zjx.springboard: %@", *error);
            return @"";
        }
        if (redMax < 0 || redMin < 0 || redMax > 255 || redMin > 255 || redMax < redMin)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"-1;;红色 RGB 的最大值和最小值应在 0 到 255 之间，且最大值应大于等于最小值。你传入的 redMax 为 %d，redMin 为 %d\r\n", redMax, redMin]}];
            NSLog(@"com.zjx.springboard: %@", *error);
            return @"";
        }
        if (greenMax < 0 || greenMin < 0 || greenMax > 255 || greenMin > 255 || greenMax < greenMin)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"-1;;绿色 RGB 的最大值和最小值应在 0 到 255 之间，且最大值应大于等于最小值。你传入的 greenMax 为 %d，greenMin 为 %d\r\n", greenMax, greenMin]}];
            NSLog(@"com.zjx.springboard: %@", *error);
            return @"";
        }
        if (blueMax < 0 || blueMin < 0 || blueMax > 255 || blueMin > 255 || blueMax < blueMin)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"-1;;蓝色 RGB 的最大值和最小值应在 0 到 255 之间，且最大值应大于等于最小值。你传入的 blueMax 为 %d，blueMin 为 %d\r\n", blueMax, blueMin]}];
            NSLog(@"com.zjx.springboard: %@", *error);
            return @"";
        }
        if (skip < 0)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"-1;;skip（步长）不能为负数\r\n", skip]}];
            NSLog(@"com.zjx.springboard: %@", *error);
            return @"";
        }

        if (width <= 0 || x + width > screenWidth)
        {
            width = screenWidth - x;
        }    
        if (height <= 0 || y + height > screenHeight)
        {
            height = screenHeight - y;
        }
    
        NSString *result = [ColorPicker searchRGBFromBuffer:buffer stride:stride region:CGRectMake(x, y, width, height) redMin:redMin redMax:redMax greenMin:greenMin greenMax:greenMax blueMin:blueMin blueMax:blueMax skip:skip];

        // 命中的坐标是竖屏原始帧坐标，换回触摸指示器坐标，脚本拿到就能直接点（与点这里同一套坐标）
        NSArray *hit = [result componentsSeparatedByString:@";;"];
        if ([hit count] >= 5 && [hit[0] intValue] >= 0)
        {
            CGPoint indicatorPoint = ZXIndicatorPointFromFramePoint(CGPointMake([hit[0] intValue], [hit[1] intValue]));
            result = [NSString stringWithFormat:@"%.0f;;%.0f;;%@;;%@;;%@",
                      indicatorPoint.x, indicatorPoint.y, hit[2], hit[3], hit[4]];
        }

        return result;
    }
    else
    {
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;无法搜索颜色：未知的颜色搜索任务类型。\r\n"}];
        NSLog(@"com.zjx.springboard: %@", *error);
        return nil;
    }
}


@implementation ColorPicker
{

}

// 旧路径是「整屏 CGImage → 裁 1x1 → 画进 1x1 上下文 → 读 4 字节」，整屏那一遍纯属浪费。
// IOSurface 的像素格式是 'BGRA'，内存里就是 B,G,R,A，直接按这个顺序取即可。
+ (NSDictionary *)colorAtPositionFromBuffer:(const UInt8 *)buffer stride:(int)stride x:(int)x andY:(int)y {
    const UInt8 *pixel = buffer + (size_t)y * stride + (size_t)x * 4;
    return @{@"blue": @(pixel[0]), @"red": @(pixel[2]), @"green": @(pixel[1])};
}

/*
+ (NSDictionary*) getRgbFromMat:(Mat)img x:(int)x y:(int)y {
    //NSLog(@"com.zjx.springboard: height: %d, width: %d, channels: %d. scale: %f", img.rows, img.cols, img.channels(), [Screen getScale]);

    Vec3b intensity = img.at<Vec3b>(y, x);
    // Don't know why. This version of opencv stores read at [0] rather than [2]
    unsigned char blue = intensity.val[0];
    unsigned char green = intensity.val[1];
    unsigned char red = intensity.val[2];
    //NSLog(@"com.zjx.springboard: blue: %u, green: %u, red: %u.", blue, green, red);

    NSDictionary *result = @{@"blue": @(blue), @"red": @(red), @"green": @(green)};
    return result;
}
*/

/*
+ (NSString*) searchRGBFromMat:(Mat)img region:(CGRect)region redMin:(int)redMin redMax:(int)redMax greenMin:(int)greenMin greenMax:(int)greenMax blueMin:(int)blueMin blueMax:(int)blueMax skip:(int)skip {
    //NSLog(@"com.zjx.springboard: image height: %d, width: %d, channels: %d. scale: %f. Rect: %@. skip: %d. redSearch: (%d, %d), greenSearch: (%d, %d), blueSearch: (%d, %d)", img.rows, img.cols, img.channels(), [Screen getScale], NSStringFromCGRect(region), skip, redMin, redMax, greenMin, greenMax, blueMin, blueMax);
    
    int x = region.origin.x;
    int y = region.origin.y;

    int width = region.size.width;
    int height = region.size.height;

    int searchMaxX = x + width;
    int searchMaxY = y + height;

    for (int currentY = y; currentY <= searchMaxY; currentY += skip + 1)
    {
        for (int currentX = x; currentX <= searchMaxX; currentX += skip + 1)
        {
            Vec3b intensity = img.at<Vec3b>(currentY, currentX);
            unsigned char blue = intensity.val[0];
            unsigned char green = intensity.val[1];
            unsigned char red = intensity.val[2];

            //NSLog(@"com.zjx.springboard: x: %d, y: %d, blue: %u, green: %u, red: %u.", currentX, currentY, blue, green, red);
            if (red >= redMin && red <= redMax && green >= greenMin && green <= greenMax && blue >= blueMin && blue <= blueMax)
            {
                return [NSString stringWithFormat:@"%d;;%d;;%d;;%d;;%d", currentX, currentY, red, green, blue];
            }
        }
    }

    return @"-1;;-1;;-1";
}
*/

+ (NSString*)searchRGBFromBuffer:(const UInt8 *)buffer stride:(int)stride region:(CGRect)region redMin:(int)redMin redMax:(int)redMax greenMin:(int)greenMin greenMax:(int)greenMax blueMin:(int)blueMin blueMax:(int)blueMax skip:(int)skip {
    int x = region.origin.x;
    int y = region.origin.y; 
    
    int width = region.size.width;
    int height = region.size.height;

    for (int currentY = 0; currentY < height; currentY += skip + 1)
    {
        const UInt8 *row = buffer + (size_t)(y + currentY) * stride + (size_t)x * 4;
        for (int currentX = 0; currentX < width; currentX += skip + 1)
        {
            const UInt8 *pixel = row + (size_t)currentX * 4;
            unsigned char blue = pixel[0];
            unsigned char green = pixel[1];
            unsigned char red = pixel[2];

            if (red >= redMin && red <= redMax && green >= greenMin && green <= greenMax && blue >= blueMin && blue <= blueMax)
            {
                return [NSString stringWithFormat:@"%d;;%d;;%d;;%d;;%d", x+currentX, y+currentY, red, green, blue];
            }
        }
    }

    return @"-1;;-1;;-1;;-1;;-1";
}




@end