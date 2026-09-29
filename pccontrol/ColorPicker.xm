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
    CGImageRef screen = [Screen createScreenShotCGImageRef];
    
    int x = [data[0] intValue];
    int y = [data[1] intValue];

    NSDictionary* result = [ColorPicker colorAtPositionFromCGImage:screen x:x andY:y];

    CGImageRelease(screen);
    return result;

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
        CGImageRef screen = [Screen createScreenShotCGImageRef];

        if (!screen)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;无法搜索颜色：内部错误，截图为空。\r\n"}];
            return @"";
        }

        size_t screenWidth = CGImageGetWidth(screen);
        size_t screenHeight = CGImageGetHeight(screen);


        int x = [data[1] intValue];
        int y = [data[2] intValue];
        int width =  [data[3] intValue];
        int height =  [data[4] intValue];
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
    
        NSString *result = [ColorPicker searchRGBFromCGImageRef:screen region:CGRectMake(x, y, width, height) redMin:redMin redMax:redMax greenMin:greenMin greenMax:greenMax blueMin:blueMin blueMax:blueMax skip:skip];
        CGImageRelease(screen);

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

+ (NSDictionary *)colorAtPositionFromCGImage:(CGImageRef)img x:(int)x andY:(int)y {
    CGRect sourceRect = CGRectMake(x, y, 1.f, 1.f);
    CGImageRef imageRef = CGImageCreateWithImageInRect(img, sourceRect);
    
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    unsigned char *buffer = (unsigned char *)malloc(4);
    CGBitmapInfo bitmapInfo = kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big;
    CGContextRef context = CGBitmapContextCreate(buffer, 1, 1, 8, 4, colorSpace, bitmapInfo);
    CGColorSpaceRelease(colorSpace);
    CGContextDrawImage(context, CGRectMake(0.f, 0.f, 1.f, 1.f), imageRef);
    CGImageRelease(imageRef);
    CGContextRelease(context);
    
    unsigned char r = buffer[0];
    unsigned char g = buffer[1];
    unsigned char b = buffer[2];

    free(buffer);
    return @{@"blue": @(b), @"red": @(r), @"green": @(g)};
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

+ (NSString*)searchRGBFromCGImageRef:(CGImageRef)img region:(CGRect)region redMin:(int)redMin redMax:(int)redMax greenMin:(int)greenMin greenMax:(int)greenMax blueMin:(int)blueMin blueMax:(int)blueMax skip:(int)skip {
    int x = region.origin.x;
    int y = region.origin.y; 
    
    int width = region.size.width;
    int height = region.size.height;

    CGImageRef imageRef = CGImageCreateWithImageInRect(img, region);
    
    int bytesPerElement = 4;
    int bytesPerRow = bytesPerElement * width;
    int totalBufferBytes = bytesPerRow * height;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();

    unsigned char *buffer = (unsigned char *)malloc(totalBufferBytes);
    memset(buffer, 0, totalBufferBytes);

    CGBitmapInfo bitmapInfo = kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big;
    CGContextRef context = CGBitmapContextCreate(buffer, width, height, 8, bytesPerRow, colorSpace, bitmapInfo);
    CGColorSpaceRelease(colorSpace);
    CGContextDrawImage(context, CGRectMake(0.f, 0.f, width, height), imageRef);
    CGImageRelease(imageRef);
    CGContextRelease(context);
    
    for (int currentY = 0; currentY < height; currentY += skip + 1)
    {
        for (int currentX = 0; currentX < width; currentX += skip + 1)
        {
            int baseAddress = (currentY * width + currentX) * 4;

            if (baseAddress >= totalBufferBytes-3)
            {
                NSLog(@"com.zjx.springboard: cannot search rgb from cgimage. Internal error. start coordinate on img: (%d, %d). current coordinate: (%d, %d), baseaddress: %d, totalBufferBytes: %d", x, y, currentX, currentY, baseAddress, totalBufferBytes);
                return @"-1;;-1;;-1;;-1;;-1";
            }

            unsigned char red = buffer[baseAddress];
            unsigned char green = buffer[baseAddress+1];
            unsigned char blue = buffer[baseAddress+2];


            //NSLog(@"com.zjx.springboard: x: %d, y: %d, blue: %u, green: %u, red: %u.", currentX, currentY, blue, green, red);
            if (red >= redMin && red <= redMax && green >= greenMin && green <= greenMax && blue >= blueMin && blue <= blueMax)
            {
                free(buffer);
                return [NSString stringWithFormat:@"%d;;%d;;%d;;%d;;%d", x+currentX, y+currentY, red, green, blue];
            }
        }
    }
    

    free(buffer);
    return @"-1;;-1;;-1;;-1;;-1";
}




@end