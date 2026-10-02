#include "ScreenMatch.h"
#include "TemplateMatch.h"
#include "Screen.h"

CGRect screenMatchFromRawData(UInt8 *eventData, NSError **error, float *outBestScore)
{
    if (outBestScore) *outBestScore = 0.0f;
    NSArray *data = [[NSString stringWithFormat:@"%s", eventData] componentsSeparatedByString:@";;"];
    NSString *templatePath = data[0];
    int maxTryTimes = 2;
    float acceptableValue = 0.8;
    float scaleRation = 0.8;
    if ([data count] == 4)
    {
        maxTryTimes = [data[1] intValue];
        acceptableValue = [data[2] floatValue];
        scaleRation = [data[3] floatValue];
    }
    else if ([data count] != 1)
    {
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;数据格式应为 \"template_path[;;max_try_times;;acceptable_value;;scaleRation]\"（模板图片路径[;;最大尝试次数;;可接受匹配值;;缩放比例]）\r\n"}];
        return CGRect();
    }
    return [ScreenMatch matchCurrentScreenWithTemplate:templatePath maxTryTimes:maxTryTimes acceptableValue:acceptableValue scaleRation:scaleRation error:error bestScore:outBestScore];
}

@implementation ScreenMatch

+ (CGRect)matchCurrentScreenWithTemplate:(NSString*)templatePath maxTryTimes:(int)mtt acceptableValue:(float)av scaleRation:(float)sr error:(NSError**)err bestScore:(float*)outBestScore {
    if (![[NSFileManager defaultManager] fileExistsAtPath:templatePath])
    {
        *err = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"-1;;图像匹配找不到模板图片，模板路径：%@\r\n", templatePath]}];
        return CGRect();
    }
    TemplateMatch *templateMatch = [[TemplateMatch alloc] init];
    [templateMatch setAcceptableValue:av];
    [templateMatch setMaxTryTimes:mtt];
    [templateMatch setScaleRation:sr];

    int stride = 0;
    int screenWidth = 0;
    int screenHeight = 0;
    const UInt8 *pixels = [Screen framePixelsWithStride:&stride width:&screenWidth height:&screenHeight];
    if (!pixels)
    {
        *err = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;模板匹配时出错：截图为空。\r\n"}];
        NSLog(@"com.zjx.springboard: -1;;Error happens when template matching. Screenshot is nil.\r\n");
        return CGRect();
    }

    CGRect result = [templateMatch templateMatchWithPixels:pixels stride:stride width:(size_t)screenWidth height:(size_t)screenHeight templatePath:templatePath error:err];
    if (outBestScore) *outBestScore = templateMatch.lastBestScore;
    // 匹配结果原本是竖屏原始帧坐标，换回触摸指示器坐标，脚本拿到就能直接点（与点这里同一套坐标）
    if (result.size.width <= 0 || result.size.height <= 0) return result;
    return ZXIndicatorRectFromFrameRect(result);
}


@end