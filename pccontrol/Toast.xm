#import "Toast.h"
#import "Screen.h"
#import <mach/mach.h>
#include "Common.h"

static int windowWidth = 200;
static int windowHeight = 200;
static NSDictionary* backgroundColorDict = @{@"4":[UIColor colorWithRed:0.282f green:0.78f blue:0.45f alpha:1.0f], @"1":[UIColor colorWithRed:0.945f green:0.275f blue:0.408f alpha:1.0f],@"2":[UIColor colorWithRed:1.0f green:0.867f blue:0.341f alpha:1.0f],@"3":[UIColor whiteColor]};
static NSDictionary* fontColorDict = @{@"4":[UIColor whiteColor], @"1":[UIColor whiteColor],@"2":[UIColor colorWithRed:0.0f green:0.0f blue:0.0f alpha:0.7f],@"3":[UIColor colorWithRed:0.0f green:0.0f blue:0.0f alpha:0.7f]};
static UIWindow *_window;
void showToastFromRawData(UInt8 *eventData, NSError **error)
{
    @autoreleasepool{
        NSArray *data = [[NSString stringWithFormat:@"%s", eventData] componentsSeparatedByString:@";;"];
        if ([data count] < 3)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;数据格式应为 \"type;;content;;duration(in seconds)[];;position(0: 顶部, 1: 底部, 2: 左侧, 3: 右侧)]\"（类型;;内容;;持续时间(秒)[];;位置）。例如：0;;success;;1.5;;0\r\n"}];
            return;
        }
        int type = [data[0] intValue];
        int duration = [data[2] intValue];
        int position = 0;
        int fontSize = 0;
        if ([data count] >= 4)
        {
            position = [data[3] intValue];
        }
        if ([data count] >= 5)
        {
            fontSize = [data[4] intValue];
        }

        if (type > 4 || type < 0)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;未知类型，类型取值范围为 0-3，请参阅 Github 上的文档。\r\n"}];
            return;
        }
        if (duration <= 0 && type != 0)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;持续时间应为正数（浮点数）。\r\n"}];
            return;
        }
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            if (type == 0)
                [Toast hideToast];
            else
                [Toast showToastWithContent:data[1] type:type duration:duration position:position fontSize:fontSize];
        });
    }
}

@implementation Toast
{
    int duration;
    UIColor *backgroundColor;
    int type; // 0 hide 1 error 2 warning 3 message 4 success
}

+ (void) hideToast
{
    ZXSafeMainAsync(^{
        if (_window != NULL)
        {
            _window.hidden = YES;
            _window = nil;
        }
    });
}

+ (void) showToastWithContent:(NSString*)content type:(int)type duration:(float)duration position:(int)position fontSize:(int)afontSize // positon: 0 top 1 bottom 2 left(not supported) 3 right (ns)
{
    __block UIWindow* currentWindow = NULL;
    ZXSafeMainAsync(^{
        if (_window != NULL)
        {
            _window.hidden = YES;
            _window = nil;
        }
        CGFloat screenWidth = [Screen getScreenWidth];
        CGFloat screenHeight = [Screen getScreenHeight];

        CGFloat scale = [Screen getScale];
        
        int fontSize = 15;
        if (afontSize != 0)
        {
            fontSize = afontSize;
        }
        else
        {
            fontSize = (int)(0.015*screenWidth);
            if (fontSize <= 15)
            {
                fontSize = 15;
            }
            else if (fontSize >= 30)
            {
                fontSize = 30;
            }
        }

        UIFont * font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightLight];
        CGSize contentSize = [content sizeWithFont:font];

        windowWidth = contentSize.width + 40;
        windowHeight = contentSize.height;
        //windowHeight = (int)((screenHeight/scale)/4);

        int windowLeftTopCornerX = (int)((screenWidth/scale)/2 - windowWidth/2);
        int windowLeftTopCornerY = 30;

        if (position == 0)
        {
            windowLeftTopCornerY = 30;
        }
        else if (position == 1)
        {
            windowLeftTopCornerY = (int)((screenHeight - contentSize.height - 50)/scale);
        }

        if (@available(iOS 11.0, *)) {
            UIWindowScene *scene = (UIWindowScene *)[[UIApplication sharedApplication].connectedScenes anyObject];
            UIWindow *anyWindow = scene.windows.firstObject;
            CGFloat bottomPadding = anyWindow ? anyWindow.safeAreaInsets.bottom : 0;
            windowLeftTopCornerY = bottomPadding + windowLeftTopCornerY;
        }



        
        UIWindowScene *toastScene = (UIWindowScene *)[[UIApplication sharedApplication].connectedScenes anyObject];
        if (toastScene) {
            _window = [[UIWindow alloc] initWithWindowScene:toastScene];
            _window.frame = CGRectMake(windowLeftTopCornerX, windowLeftTopCornerY, windowWidth, windowHeight);
        } else {
            _window = [[UIWindow alloc] initWithFrame:CGRectMake(windowLeftTopCornerX, windowLeftTopCornerY, windowWidth, windowHeight)];
        }
        _window.rootViewController = [[UIViewController alloc] init];
        currentWindow = _window;
        _window.windowLevel = UIWindowLevelStatusBar + 1;
        [_window setBackgroundColor: backgroundColorDict[[@(type) stringValue]]];

        _window.layer.borderColor = [UIColor clearColor].CGColor;
        _window.layer.borderWidth = 2.0f;
        _window.layer.cornerRadius = 10;
        [_window setUserInteractionEnabled:NO];

        UILabel *contentLabel = [[UILabel alloc]initWithFrame:CGRectMake(windowWidth/2 - contentSize.width/2, 0, contentSize.width, contentSize.height)];
        contentLabel.font = font;
        contentLabel.text = content;
        contentLabel.numberOfLines = 1;
        contentLabel.baselineAdjustment = UIBaselineAdjustmentAlignBaselines; // or UIBaselineAdjustmentAlignCenters, or UIBaselineAdjustmentNone
        contentLabel.adjustsFontSizeToFitWidth = YES;
        contentLabel.adjustsLetterSpacingToFitWidth = YES;
        contentLabel.minimumScaleFactor = 10.0f/12.0f;
        contentLabel.clipsToBounds = YES;
        contentLabel.backgroundColor = [UIColor clearColor];
        contentLabel.textColor = fontColorDict[[@(type) stringValue]];
        contentLabel.textAlignment = NSTextAlignmentLeft;
        [_window addSubview:contentLabel];

        _window.hidden = NO;

    });
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [NSThread sleepForTimeInterval:duration];
        ZXSafeMainAsync(^{
            if (currentWindow != _window)
            {
                return;
            }
            _window.hidden = YES;
            _window = nil;
        });
    });
    
}

- (void) show {

    
}

- (void) setContent:(NSString*)content {
    self.content = content;
}

- (void) setBackgroundColor:(UIColor*)color{

}

- (void) setDuration:(int)d {
    duration = d;
}






@end