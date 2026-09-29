#include "DeviceInfo.h"
#include "Screen.h"
#include "Play.h"
#include "Process.h"
#include "Record.h"
#import <sys/utsname.h>
static NSString* modelName()
{
    struct utsname systemInfo;
    uname(&systemInfo);

    return [NSString stringWithCString:systemInfo.machine
                                encoding:NSUTF8StringEncoding];
}

NSString *getDeviceInfoFromRawData(UInt8* eventData, NSError **error)
{
    NSArray *data = [[NSString stringWithFormat:@"%s", eventData] componentsSeparatedByString:@";;"];
    int task = [data[0] intValue];
    if (task == DEVICE_INFO_TASK_GET_SCREEN_SIZE)
    {
        __block CGRect bounds = CGRectZero;
        __block CGFloat scale = 1.0f;
        void (^readScreen)(void) = ^{
            UIScreen *screen = [UIScreen mainScreen];
            bounds = screen.bounds;
            scale = screen.scale;
        };
        if ([NSThread isMainThread]) readScreen();
        else dispatch_sync(dispatch_get_main_queue(), readScreen);
        return [NSString stringWithFormat:@"%f;;%f", CGRectGetWidth(bounds) * scale, CGRectGetHeight(bounds) * scale];
    }
    else if (task == DEVICE_INFO_TASK_GET_SCREEN_ORIENTATION)
    {
        return [NSString stringWithFormat:@"%d", [Screen getScreenOrientation]];
    }
    else if (task == DEVICE_INFO_TASK_GET_SCREEN_SCALE)
    {
        return [NSString stringWithFormat:@"%f", [Screen getScale]];
    }
    else if (task == DEVICE_INFO_TASK_GET_DEVICE_INFO)
    {
        return [NSString stringWithFormat:@"%@;;%@;;%@;;%@;;%@", 
                                        [[UIDevice currentDevice] name], 
                                        [[UIDevice currentDevice] systemName], 
                                        [[UIDevice currentDevice] systemVersion], 
                                        modelName(), 
                                        [[UIDevice currentDevice] identifierForVendor]];
    }
    else if (task == DEVICE_INFO_TASK_GET_BATTERY_INFO)
    {
        UIDevice *myDevice = [UIDevice currentDevice];
        [myDevice setBatteryMonitoringEnabled:YES];

        int state = [myDevice batteryState];
        double batLeft = (float)[myDevice batteryLevel] * 100;


        return [NSString stringWithFormat:@"%d;;%f", 
                                state, 
                                batLeft];
    }
    else if (task == DEVICE_INFO_TASK_GET_RUNTIME_STATUS)
    {
        id frontMostApp = getFrontMostApplication();
        NSString *bundleIdentifier = nil;
        if ([frontMostApp respondsToSelector:@selector(bundleIdentifier)]) {
            bundleIdentifier = [frontMostApp bundleIdentifier];
        }
        if (bundleIdentifier.length == 0) bundleIdentifier = @"com.apple.springboard";
        return [NSString stringWithFormat:@"%@;;%d;;%d", bundleIdentifier, isScriptPlaying(), isRecordingStart()];
    }
    else
    {
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"-1;;Unknown device info task type. The task you provide: %d\r\n", task]}];
        return @"";
    }
}
