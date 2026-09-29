#include "Process.h"
#include "Common.h"
int (*openApp)(CFStringRef, Boolean);

static void* sbServices = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);

int switchProcessForegroundFromRawData(UInt8 *eventData)
{
    return bringAppForeground([NSString stringWithFormat:@"%s", eventData]);
}

int bringAppForeground(NSString *appIdentifier)
{
    CFStringRef appBundleName = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@"), appIdentifier);
    //[NSString stringWithFormat:@"%s", eventData];
    NSLog(@"### com.zjx.springboard: Switch to application: %@", appBundleName);
    if (!openApp)
        openApp = (int(*)(CFStringRef, Boolean))dlsym(sbServices,"SBSLaunchApplicationWithIdentifier");

    return openApp(appBundleName, false);
}

id getFrontMostApplication()
{
    //TODO: might cause problem here. Both _accessibilityFrontMostApplication failed or front most application springboard will cause app be nil.
    __block id app = nil;
    // This is reached both from the socket server (background thread) and from
    // the hotkey/panel handlers, which already run on the main queue. An
    // unconditional dispatch_sync to the main queue makes the main queue wait
    // on itself in the latter case, and libdispatch traps the process:
    //   "BUG IN CLIENT OF LIBDISPATCH: dispatch_sync called on queue already
    //    owned by current thread"
    // which took SpringBoard into safe mode every time recording was toggled
    // with the hotkey. Run the block inline when we are already on main.
    void (^fetchBlock)(void) = ^{
        @try{
            SpringBoard *springboard = (SpringBoard*)[%c(SpringBoard) sharedApplication];
            app = [springboard _accessibilityFrontMostApplication];
            //NSLog(@"com.zjx.springboard: app: %@, id: %@", app, [app displayIdentifier]);
        }
        @catch (NSException *exception) {
            NSLog(@"com.zjx.springboard: Debug: %@", exception.reason);
        }
        };

    if ([NSThread isMainThread])
    {
        fetchBlock();
    }
    else
    {
        dispatch_sync(dispatch_get_main_queue(), fetchBlock);
    }
    return app;
}