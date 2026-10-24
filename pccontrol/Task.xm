#include "Task.h"
#include <roothide.h>
#include "Touch.h"
#include "ColorPicker.h"
#include "ScreenMatch.h"
#include "Process.h"
#include "AlertBox.h"
#include "Record.h"
#include "Play.h"
#include "SocketServer.h"
#include "Toast.h"
#include "Common.h"
#include "UIKeyboard.h"
#include "DeviceInfo.h"
#include "TouchIndicator/TouchIndicatorWindow.h"
#import <objc/runtime.h>
#include <mach/mach.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/time.h>
#include <limits.h>
#include <unistd.h>
#include <spawn.h>
#include <signal.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <errno.h>
#include <Foundation/NSDistributedNotificationCenter.h>
#include <TextRecognization/TextRecognizer.h>
#include "UpdateCache.h"
#include "Screen.h"
#include "TemplateMatch.h"
#include "NetSpeedIndicator.h"
#include "TouchCoordinateIndicator.h"
#include "FloatingMenu.h"
#include "TapTestWindow.h"
#import "FlowWindow.h"

extern CFRunLoopRef recordRunLoop;

/*
get task type
*/
static int getTaskType(UInt8* dataArray)
{
	int taskType = 0;
	for (int i = 0; i <= 1; i++)
	{
		taskType += (dataArray[i] - '0')*pow(10, 1-i);
	}
	return taskType;
}

static NSString *ZXProbeWrite(NSDictionary *out)
{
    NSData *data = [NSJSONSerialization dataWithJSONObject:out options:0 error:NULL];
    NSString *json = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Library/ZXTouch"
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    [json writeToFile:@"/var/mobile/Library/ZXTouch/intent_probe.json" atomically:YES
              encoding:NSUTF8StringEncoding error:NULL];
    return json;
}

static NSString *ZXIntentProbeJSON(void)
{
    NSMutableDictionary *out = [NSMutableDictionary dictionary];

    void *link = dlopen("/System/Library/PrivateFrameworks/LinkServices.framework/LinkServices", RTLD_LAZY);
    out[@"link"] = @(link != NULL);
    if (!link) out[@"linkErr"] = @(strerror(errno));
    void *wf = dlopen("/System/Library/PrivateFrameworks/WorkflowKit.framework/WorkflowKit", RTLD_LAZY);
    out[@"workflow"] = @(wf != NULL);
    void *ai = dlopen("/System/Library/Frameworks/AppIntents.framework/AppIntents", RTLD_LAZY);
    out[@"appintents"] = @(ai != NULL);
    out[@"sendMessageIntent"] = @(NSClassFromString(@"INSendMessageIntent") != NULL);

    NSMutableArray *cls = [NSMutableArray array];
    int total = objc_getClassList(NULL, 0);
    if (total > 0) {
        Class *all = (Class *)malloc(sizeof(Class) * total);
        total = objc_getClassList(all, total);
        for (int i = 0; i < total && cls.count < 400; i++) {
            NSString *n = NSStringFromClass(all[i]);
            if ([n hasPrefix:@"LN"] || [n hasPrefix:@"WFWorkflow"] ||
                [n hasPrefix:@"WFShortcut"] || [n hasPrefix:@"WFBackground"]) [cls addObject:n];
        }
        free(all);
    }
    out[@"classes"] = cls;

    Class provider = NSClassFromString(@"LNMetadataProvider");
    out[@"provider"] = @(provider != NULL);
    NSMutableArray *methods = [NSMutableArray array];
    if (provider) {
        unsigned int n = 0;
        Method *ms = class_copyMethodList(provider, &n);
        for (unsigned int i = 0; i < n; i++) [methods addObject:NSStringFromSelector(method_getName(ms[i]))];
        free(ms);
    }
    out[@"providerMethods"] = methods;

    id p = provider ? [[provider alloc] init] : nil;
    NSArray *actions = nil;
    NSString *queryError = nil;
    out[@"queryStarted"] = @(p != nil);

    if (p)
    {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block NSArray *found = nil;
        __block NSString *failed = nil;

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            @autoreleasepool {
                SEL sel = NSSelectorFromString(@"actionsForBundleIdentifier:error:");
                if ([p respondsToSelector:sel])
                {
                    @try
                    {
                        NSMethodSignature *sig = [p methodSignatureForSelector:sel];
                        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                        inv.target = p;
                        inv.selector = sel;
                        NSString *bid = @"com.tencent.xin";
                        NSError *e = nil;
                        [inv setArgument:&bid atIndex:2];
                        [inv setArgument:&e atIndex:3];
                        [inv invoke];
                        NSArray *ret = nil;
                        [inv getReturnValue:&ret];
                        found = ret;
                        failed = e.localizedDescription;
                    }
                    @catch (NSException *ex)
                    {
                        failed = ex.reason ?: @"exception";
                    }
                }
                else
                {
                    failed = @"selector missing";
                }
                dispatch_semaphore_signal(sem);
            }
        });

        if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC))) != 0)
        {
            out[@"queryTimeout"] = @YES;
        }
        else
        {
            actions = found;
            queryError = failed;
        }
    }

    out[@"queryError"] = queryError ?: @"";

    NSMutableArray *acts = [NSMutableArray array];
    for (id a in actions) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"identifier", @"title", @"bundleIdentifier", @"actionIdentifier"]) {
            @try {
                id v = [a valueForKey:key];
                if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) d[key] = v;
            } @catch (NSException *e) {}
        }
        @try {
            id list = [a valueForKey:@"parameters"];
            if ([list isKindOfClass:[NSArray class]]) {
                NSMutableArray *params = [NSMutableArray array];
                for (id pm in list) {
                    NSMutableDictionary *pd = [NSMutableDictionary dictionary];
                    for (NSString *key in @[@"key", @"title", @"name", @"valueType"]) {
                        @try {
                            id v = [pm valueForKey:key];
                            if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) pd[key] = v;
                        } @catch (NSException *e) {}
                    }
                    if (pd.count > 0) [params addObject:pd];
                }
                if (params.count) d[@"parameters"] = params;
            }
        } @catch (NSException *e) {}
        [acts addObject:d];
    }
    out[@"actions"] = acts;
    out[@"actionCount"] = @(actions.count);

    NSMutableArray *plugins = [NSMutableArray array];
    NSString *appRoot = @"/var/containers/Bundle/Application";
    for (NSString *sub in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:appRoot error:NULL]) {
        NSString *dir = [appRoot stringByAppendingPathComponent:sub];
        for (NSString *app in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL]) {
            if (![app hasSuffix:@".app"]) continue;
            NSString *appPath = [dir stringByAppendingPathComponent:app];
            NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:
                                   [appPath stringByAppendingPathComponent:@"Info.plist"]];
            if (![plist[@"CFBundleIdentifier"] isEqualToString:@"com.tencent.xin"]) continue;
            out[@"wechatPath"] = appPath;
            NSString *plug = [appPath stringByAppendingPathComponent:@"PlugIns"];
            for (NSString *ex in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:plug error:NULL]) {
                NSString *ext = [plug stringByAppendingPathComponent:ex];
                NSDictionary *ep = [NSDictionary dictionaryWithContentsOfFile:
                                    [ext stringByAppendingPathComponent:@"Info.plist"]];
                id pts = ep[@"NSExtension"][@"NSExtensionPointIdentifier"];
                id intents = ep[@"NSExtension"][@"NSExtensionAttributes"][@"INIntentsSupported"];
                id intentDefs = ep[@"NSExtension"][@"NSExtensionAttributes"][@"IntentsSupported"];
                [plugins addObject:[NSString stringWithFormat:@"%@ | %@ | intents=%@ | defs=%@",
                                    ex, pts ?: @"", intents ?: @"", intentDefs ?: @""]];
            }

            NSMutableArray *meta = [NSMutableArray array];
            NSDirectoryEnumerator *walk = [[NSFileManager defaultManager] enumeratorAtPath:appPath];
            for (NSString *rel in walk) {
                if ([rel.pathExtension isEqualToString:@"appintents"] ||
                    [rel.pathExtension isEqualToString:@"intentdefinition"] ||
                    [rel.lastPathComponent isEqualToString:@"Metadata.appintents"]) {
                    [meta addObject:rel];
                    if (meta.count >= 60) break;
                }
            }
            out[@"wechatIntentMeta"] = meta;
        }
    }
    out[@"wechatPlugins"] = plugins;

    return ZXProbeWrite(out);
}

/**
Process Task
*/
void processTask(UInt8 *buff, CFWriteStreamRef writeStreamRef)
{
    //NSLog(@"### com.zjx.springboard: task type: %d. Data: %s", getTaskType(buff), buff);
    UInt8 *eventData = buff + 0x2;
    int taskType = getTaskType(buff);

    //for touching
    if (taskType == TASK_PERFORM_TOUCH)
    {
        // 脚本刚被停掉时，管道里还堆着一堆已经发出去、来不及执行的触摸，直接丢掉
        if (ZXShouldDropTouchInjection())
        {
            return;
        }
        @autoreleasepool{
            performTouchFromRawData(eventData);
        }
    }
    else if (taskType == TASK_PROCESS_BRING_FOREGROUND) //bring to foreground
    {
        @autoreleasepool{   
            switchProcessForegroundFromRawData(eventData);
            notifyClient((UInt8*)"0\r\n", writeStreamRef); 
        }
    }
    else if (taskType == TASK_SHOW_ALERT_BOX)
    {
        @autoreleasepool{   
            NSError *err = nil;
            showAlertBoxFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_USLEEP)
    {
        if (writeStreamRef)
        {
            int usleepTime = 0;
            @try{
                usleepTime = atoi((char*)eventData);
            }
            @catch (NSException *exception) {
                NSLog(@"com.zjx.springboard: Debug: %@", exception.reason);
                return;
            }
            //NSLog(@"com.zjx.springboard: sleep %d microseconds", usleepTime);
            usleep(usleepTime);
            notifyClient((UInt8*)"0;;等待结束\r\n", writeStreamRef);
        }
        else
        {
            int usleepTime = 0;

            @try{
                usleepTime = atoi((char*)eventData);
            }
            @catch (NSException *exception) {
                NSLog(@"com.zjx.springboard: Debug: %@", exception.reason);
                return;
            }
            //NSLog(@"com.zjx.springboard: sleep %d microseconds", usleepTime);
            usleep(usleepTime);
        }

    }
    else if (taskType == TASK_RUN_SHELL)
    {
        @autoreleasepool{
            // %s decodes the raw bytes as MacRoman, which corrupts any non-ASCII
            // shell command. Decode the payload as UTF-8 instead.
            NSString *shellCommand = [NSString stringWithUTF8String:(const char *)eventData] ?: @"";
            system2([[NSString stringWithFormat:@"%@ -c \"%@\"", jbroot(@"/bin/sh"), shellCommand] UTF8String], NULL, NULL);
            notifyClient((UInt8*)"0\r\n", writeStreamRef);
        }
    }
    else if (taskType == TASK_TOUCH_RECORDING_START)
    {
        @autoreleasepool {
            NSError *err = nil;
            startRecording(writeStreamRef, &err);    
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_TOUCH_RECORDING_STOP)
    {
        @autoreleasepool {
            stopRecording(); 
            notifyClient((UInt8*)"0\r\n", writeStreamRef); 
        }
    }
    else if (taskType == TASK_PLAY_SCRIPT)
    {
        @autoreleasepool {
            NSError *err = nil;
            playScript((UInt8*)eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_PLAY_SCRIPT_FORCE_STOP)
    {
        @autoreleasepool {
            NSError *err = nil;
            stopScriptPlaying(&err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_TEMPLATE_MATCH)
    {
        @autoreleasepool {
            NSError *err = nil;
            float bestScore = 0.0f;
            CGRect result = screenMatchFromRawData(eventData, &err, &bestScore);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%.2f;;%.2f;;%.2f;;%.2f;;%.3f\r\n",
                    result.origin.x, result.origin.y, result.size.width, result.size.height, bestScore] UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_SHOW_TOAST)
    {
        @autoreleasepool {
            NSError *err = nil;
            showToastFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_COLOR_PICKER)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSDictionary *result = getRGBFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@;;%@;;%@\r\n",
                    result[@"red"], result[@"green"], result[@"blue"]] UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_TEXT_INPUT)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSString *result = inputTextFromRawData(eventData,  &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@\r\n", result] UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_GET_DEVICE_INFO)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSString *deviceInfo = getDeviceInfoFromRawData(eventData,  &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@\r\n", deviceInfo] UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_TOUCH_INDICATOR)
    {
        @autoreleasepool {
            NSError *err = nil;
            handleTouchIndicatorTaskWithRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_TEXT_RECOGNIZER)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSString *text = performTextRecognizerTextFromRawData(eventData,  &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@\r\n", text] UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_COLOR_SEARCHER)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSString *result = searchRGBFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@\r\n", result] UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_PROMPT_INPUT)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSString *result = promptInputFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                result = [[result stringByReplacingOccurrencesOfString:@"\r" withString:@" "] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@\r\n", result] UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_SCREENSHOT)
    {
        @autoreleasepool {
            if (!writeStreamRef) {
                return;
            }

            CGImageRef screenshot = NULL;
            BOOL responseHeaderSent = NO;

            @try {
                screenshot = [Screen createScreenShotCGImageRef];
                if (!screenshot) {
                    notifyClient((UInt8 *)"-1;;截图失败\r\n", writeStreamRef);
                    return;
                }

                UIImageOrientation imageOrientation = UIImageOrientationUp;
                int screenOrientation = [Screen getScreenOrientation];
                if (screenOrientation == 4) {
                    imageOrientation = UIImageOrientationRight;
                } else if (screenOrientation == 3) {
                    imageOrientation = UIImageOrientationLeft;
                } else if (screenOrientation == 2) {
                    imageOrientation = UIImageOrientationDown;
                }

                UIImage *image = [UIImage imageWithCGImage:screenshot
                                                     scale:[Screen getScale]
                                               orientation:imageOrientation];
                if (image && imageOrientation != UIImageOrientationUp) {
                    CGFloat scale = [Screen getScale];
                    CGSize orientedSize = CGSizeMake(CGImageGetWidth(screenshot) / scale,
                                                     CGImageGetHeight(screenshot) / scale);
                    if (imageOrientation == UIImageOrientationLeft ||
                        imageOrientation == UIImageOrientationRight) {
                        orientedSize = CGSizeMake(orientedSize.height, orientedSize.width);
                    }

                    UIGraphicsBeginImageContextWithOptions(orientedSize, YES, scale);
                    [image drawInRect:CGRectMake(0, 0, orientedSize.width, orientedSize.height)];
                    UIImage *orientedImage = UIGraphicsGetImageFromCurrentImageContext();
                    UIGraphicsEndImageContext();
                    image = orientedImage;
                }

                NSData *jpegData = image ? UIImageJPEGRepresentation(image, 0.85) : nil;
                if (!jpegData || [jpegData length] == 0) {
                    notifyClient((UInt8 *)"-1;;将截图编码为 JPEG 失败\r\n", writeStreamRef);
                    return;
                }

                NSString *header = [NSString stringWithFormat:@"0;;image/jpeg;;%lu\r\n",
                                                             (unsigned long)[jpegData length]];
                NSData *headerData = [header dataUsingEncoding:NSUTF8StringEncoding];
                if (!headerData || notifyClientData((const UInt8 *)[headerData bytes],
                                                    (CFIndex)[headerData length],
                                                    writeStreamRef) != 0) {
                    return;
                }
                responseHeaderSent = YES;

                if (notifyClientData((const UInt8 *)[jpegData bytes],
                                     (CFIndex)[jpegData length],
                                     writeStreamRef) != 0) {
                    NSLog(@"com.zjx.springboard: Failed to send screenshot JPEG payload.");
                }
            }
            @catch (NSException *exception) {
                NSLog(@"com.zjx.springboard: Screenshot task failed: %@", exception.reason);
                if (!responseHeaderSent) {
                    notifyClient((UInt8 *)"-1;;截图失败\r\n", writeStreamRef);
                }
            }
            @finally {
                if (screenshot) {
                    CGImageRelease(screenshot);
                }
            }
        }
    }
    else if (taskType == TASK_SCREENSHOT_RAW)
    {
        @autoreleasepool {
            if (!writeStreamRef) {
                return;
            }

            CGImageRef screenshot = [Screen createScreenShotCGImageRef];
            if (!screenshot) {
                notifyClient((UInt8 *)"-1;;截图失败\r\n", writeStreamRef);
                return;
            }

            // 与 TASK_SCREENSHOT 的区别：这里不做转正，直接给竖屏原始帧，
            // 再多带一个当前方向，让 App 自己决定「显示转正 / 存盘按原帧抠」。
            UIImage *image = [UIImage imageWithCGImage:screenshot
                                                 scale:[Screen getScale]
                                           orientation:UIImageOrientationUp];
            NSData *jpegData = image ? UIImageJPEGRepresentation(image, 0.85) : nil;
            if (!jpegData || [jpegData length] == 0) {
                notifyClient((UInt8 *)"-1;;将截图编码为 JPEG 失败\r\n", writeStreamRef);
                CGImageRelease(screenshot);
                return;
            }

            NSString *header = [NSString stringWithFormat:@"0;;image/jpeg;;%lu;;%d\r\n",
                                (unsigned long)[jpegData length], [Screen getScreenOrientation]];
            NSData *headerData = [header dataUsingEncoding:NSUTF8StringEncoding];
            if (headerData && notifyClientData((const UInt8 *)[headerData bytes],
                                               (CFIndex)[headerData length],
                                               writeStreamRef) == 0) {
                notifyClientData((const UInt8 *)[jpegData bytes],
                                 (CFIndex)[jpegData length],
                                 writeStreamRef);
            }
            CGImageRelease(screenshot);
        }
    }
    else if (taskType == TASK_NET_SPEED_INDICATOR)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSString *result = handleNetSpeedIndicatorTaskWithRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else if (result)
            {
                notifyClient((UInt8*)[result UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_FLOATING_MENU)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSString *result = handleFloatingMenuTaskWithRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else if (result)
            {
                notifyClient((UInt8*)[result UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_TOUCH_COORDINATE_INDICATOR)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSString *result = handleTouchCoordinateTaskWithRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else if (result)
            {
                notifyClient((UInt8*)[result UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_FLOW_EDITOR)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSString *result = handleFlowEditorTaskWithRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else if (result)
            {
                notifyClient((UInt8*)[result UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_DEBUG_INFO)
    {
        @autoreleasepool {
            NSString *data = eventData ? [NSString stringWithUTF8String:(const char *)eventData] : @"";
            NSArray *parts = [data componentsSeparatedByString:@";;"];
            NSString *target = [parts count] > 1 ? parts[1] : @"all";

            NSMutableDictionary *root = [NSMutableDictionary dictionary];
            if ([target isEqualToString:@"net_speed"]) {
                NSDictionary *info = [NetSpeedIndicator debugInfo];
                if (info) root[@"net_speed"] = info;
            } else if ([target isEqualToString:@"floating_menu"]) {
                NSDictionary *info = [FloatingMenu debugInfo];
                if (info) root[@"floating_menu"] = info;
            } else if ([target isEqualToString:@"touch_coord"]) {
                NSDictionary *info = [TouchCoordinateIndicator debugInfo];
                if (info) root[@"touch_coord"] = info;
            } else if ([target isEqualToString:@"perf"]) {
                // 性能埋点：抓屏渲染耗时 + 匹配三段耗时，优化时按这几项定位瓶颈
                root[@"perf"] = @{ @"screen_render_ms": @([Screen lastRenderMilliseconds]),
                                   @"match": [TemplateMatch lastTiming] };
            } else {
                NSDictionary *nsInfo = [NetSpeedIndicator debugInfo];
                if (nsInfo) root[@"net_speed"] = nsInfo;
                NSDictionary *fmInfo = [FloatingMenu debugInfo];
                if (fmInfo) root[@"floating_menu"] = fmInfo;
                NSDictionary *tcInfo = [TouchCoordinateIndicator debugInfo];
                if (tcInfo) root[@"touch_coord"] = tcInfo;
            }

            NSError *jsonErr = nil;
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:root
                                                               options:0
                                                                 error:&jsonErr];
            if (jsonErr) {
                notifyClient((UInt8*)[[NSString stringWithFormat:@"-1;;JSON 序列化失败: %@", [jsonErr localizedDescription]] UTF8String], writeStreamRef);
            } else {
                NSMutableData *payload = [NSMutableData dataWithData:jsonData];
                [payload appendBytes:"\r\n" length:2];
                notifyClientData((UInt8 *)payload.bytes, (CFIndex)payload.length, writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_PYTHON_CHECK)
    {
        @autoreleasepool {
            NSMutableDictionary *root = [NSMutableDictionary dictionary];
            NSMutableArray *checks = [NSMutableArray array];
            NSArray<NSString *> *candidates = @[
                jbroot(@"/usr/bin/python3.12"),
                jbroot(@"/usr/bin/python3.11"),
                jbroot(@"/usr/bin/python3.10"),
                jbroot(@"/usr/bin/python3.9"),
                jbroot(@"/usr/bin/python3.8"),
                jbroot(@"/usr/bin/python3"),
                @"/var/jb/usr/bin/python3.12",
                @"/var/jb/usr/bin/python3.11",
                @"/var/jb/usr/bin/python3.10",
                @"/var/jb/usr/bin/python3.9",
                @"/var/jb/usr/bin/python3.8",
                @"/var/jb/usr/bin/python3",
                @"/usr/bin/python3.12",
                @"/usr/bin/python3.11",
                @"/usr/bin/python3.10",
                @"/usr/bin/python3.9",
                @"/usr/bin/python3.8",
                @"/usr/bin/python3"
            ];
            NSFileManager *fm = [NSFileManager defaultManager];

            // ---- 环境信息：一次报告把「跑的是哪棵越狱目录」钉死 ----
            // 常见病灶：设备换过越狱/bootstrap 后出现两棵目录树，Sileo 把 python 装进
            // /var/jb 现在指向的树，而 SpringBoard 里跑的 tweak 还在老树上找解释器。
            Dl_info dinfo = {0};
            if (dladdr((void *)notifyClient, &dinfo) && dinfo.dli_fname) {
                root[@"tweak_path"] = @(dinfo.dli_fname);
            }
            root[@"uid"] = @(getuid());
            root[@"gid"] = @(getgid());
            char varjbBuf[PATH_MAX];
            ssize_t varjbLen = readlink("/var/jb", varjbBuf, sizeof(varjbBuf) - 1);
            if (varjbLen > 0) {
                root[@"varjb_target"] = [[NSString alloc] initWithBytes:varjbBuf length:(NSUInteger)varjbLen encoding:NSUTF8StringEncoding];
            } else {
                root[@"varjb_target"] = [NSString stringWithFormat:@"(readlink 失败 errno=%d)", errno];
            }
            NSString *prefixProbe = jbroot(@"/__zx_probe__");
            NSString *jbPrefix = @"";
            if ([prefixProbe hasSuffix:@"/__zx_probe__"]) {
                jbPrefix = [prefixProbe substringToIndex:prefixProbe.length - (NSUInteger)strlen("/__zx_probe__")];
            } else {
                jbPrefix = prefixProbe ?: @"";
            }
            root[@"jbroot_prefix"] = jbPrefix;
            // 规范化：去掉末尾斜杠再比较，避免 /a/b 和 /a/b/ 被误判为两棵树
            NSString *varjbNorm = [root[@"varjb_target"] stringByStandardizingPath];
            NSString *prefixNorm = [jbPrefix stringByStandardizingPath];
            root[@"same_tree"] = @([varjbNorm isEqualToString:prefixNorm]);

            for (NSString *path in candidates) {
                BOOL exists = [fm fileExistsAtPath:path];
                int savedErrno = 0;
                BOOL isExec = exists ? (access(path.UTF8String, X_OK) == 0) : NO;
                if (exists && !isExec) savedErrno = errno;
                NSMutableDictionary *item = [NSMutableDictionary dictionary];
                item[@"path"] = path;
                item[@"exists"] = @(exists);
                item[@"executable"] = @(isExec);
                struct stat st;
                if (lstat(path.UTF8String, &st) == 0) {
                    item[@"mode"] = [NSString stringWithFormat:@"%o", (unsigned)(st.st_mode & 07777)];
                    if (S_ISLNK(st.st_mode)) {
                        item[@"symlink"] = @YES;
                        char lt[PATH_MAX];
                        ssize_t m = readlink(path.UTF8String, lt, sizeof(lt) - 1);
                        if (m > 0) {
                            item[@"link_target"] = [[NSString alloc] initWithBytes:lt length:(NSUInteger)m encoding:NSUTF8StringEncoding];
                        }
                    }
                }
                if (savedErrno != 0) item[@"exec_errno"] = @(savedErrno);
                [checks addObject:item];
            }
            root[@"candidates"] = checks;

            NSString *found = nil;
            for (NSString *path in candidates) {
                if (access(path.UTF8String, X_OK) == 0) { found = path; break; }
            }
            root[@"found_path"] = found ?: @"";

            if (found) {
                // --- 两条探针并排跑，一次性定性 SpringBoard 沙盒行为 ---
                //
                // 探针 A：call_system() = sh -c '<found> --version'
                //   → 当前 ScriptPlayer 用的路径（shell 二跳 exec python）
                // 探针 B：posix_spawn 直接 exec python，绕开 shell
                //   → 若能跑通 = 沙盒只拦 shell 二跳，我们改 ScriptPlayer 直接 exec 即可
                //   → 若也 EPERM = 沙盒拦任何 exec python，必须上守护进程方案
                //
                NSString *probeA = @"/var/mobile/Library/ZXTouch/.pycheckA";
                NSString *probeB = @"/var/mobile/Library/ZXTouch/.pycheckB";

                // ---- 探针 A：现有 shell 路径 ----
                NSString *cmdA = [NSString stringWithFormat:@"'%@' --version > '%@' 2>&1", found, probeA];
                int stA = call_system(cmdA.UTF8String);
                int exitA = (stA == -1) ? -1 : (WIFEXITED(stA) ? WEXITSTATUS(stA) : -1);
                NSString *outA = [NSString stringWithContentsOfFile:probeA encoding:NSUTF8StringEncoding error:nil] ?: @"";
                [[NSFileManager defaultManager] removeItemAtPath:probeA error:nil];

                // ---- 探针 B：posix_spawn 直接 exec python（绕开 shell）----
                // 直接 exec，不走 sh -c；如果也 EPERM 说明沙盒拦任何 exec python
                NSString *exitBVal = @"-1";
                NSString *outB = @"";
                int bfd = open(probeB.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);
                if (bfd >= 0) {
                    int stdinFD = open("/dev/null", O_RDONLY);
                    posix_spawn_file_actions_t fa;
                    posix_spawn_file_actions_init(&fa);
                    posix_spawn_file_actions_adddup2(&fa, stdinFD, STDIN_FILENO);
                    posix_spawn_file_actions_adddup2(&fa, bfd, STDOUT_FILENO);
                    posix_spawn_file_actions_adddup2(&fa, bfd, STDERR_FILENO);
                    posix_spawnattr_t attr;
                    posix_spawnattr_init(&attr);
                    sigset_t emp; sigemptyset(&emp);
                    posix_spawnattr_setsigmask(&attr, &emp);
                    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGMASK);
                    char *argv[] = { (char *)found.UTF8String, (char *)"--version", NULL };
                    extern char **environ;
                    pid_t pidB = 0;
                    int errB = posix_spawn(&pidB, found.UTF8String, &fa, &attr, argv, environ);
                    posix_spawn_file_actions_destroy(&fa);
                    posix_spawnattr_destroy(&attr);
                    close(bfd);
                    if (stdinFD >= 0) close(stdinFD);
                    if (errB == 0) {
                        int st = 0;
                        int wB = zxWaitTimeout(pidB, 10.0, &st);
                        if (wB == 1) {
                            kill(pidB, SIGKILL);
                            int stKill = 0;
                            zxWaitTimeout(pidB, 2.0, &stKill);
                            exitBVal = @"timeout(killed)";
                        } else if (wB == -1) {
                            exitBVal = [NSString stringWithFormat:@"waitpid_errno=%d", errno];
                        } else {
                            exitBVal = [NSString stringWithFormat:@"%d", WIFEXITED(st) ? WEXITSTATUS(st) : -1];
                        }
                    } else {
                        exitBVal = [NSString stringWithFormat:@"posix_spawn_err=%d(%s)", errB, strerror(errB)];
                    }
                    outB = [NSString stringWithContentsOfFile:probeB encoding:NSUTF8StringEncoding error:nil] ?: @"";
                    [[NSFileManager defaultManager] removeItemAtPath:probeB error:nil];
                } else {
                    exitBVal = [NSString stringWithFormat:@"open_probe_errno=%d", errno];
                }

                root[@"spawn_probe_A_shell"]  = @{ @"exit": @(exitA), @"output": [outA stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] };
                root[@"spawn_probe_B_direct"] = @{ @"exit": exitBVal,   @"output": [outB stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] };

                // 保留原有字段向后兼容
                NSString *ver = exitA == 0 ? [outA stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                                           : [outB stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                root[@"version"] = ver ?: @"";
                root[@"spawn_exit_code"] = [NSString stringWithFormat:@"%d", exitA];

                // 检查 zxtouch 模块路径
                NSMutableArray<NSString *> *modulePaths = [NSMutableArray array];
                NSArray<NSString *> *moduleCandidates = @[
                    jbroot(@"/usr/share/zxtouch/python"),
                    jbroot(@"/usr/lib/python3/site-packages"),
                    jbroot(@"/usr/lib/python3/dist-packages"),
                    @"/var/jb/usr/share/zxtouch/python",
                    @"/var/jb/usr/lib/python3/site-packages",
                    @"/var/jb/usr/lib/python3/dist-packages",
                    @"/usr/lib/python3/site-packages",
                    @"/usr/lib/python3/dist-packages"
                ];
                for (NSString *p in moduleCandidates) {
                    if ([fm fileExistsAtPath:p]) [modulePaths addObject:p];
                }
                root[@"module_paths_found"] = modulePaths;

                NSString *impFile = @"/var/mobile/Library/ZXTouch/.pycheck_import";
                NSMutableDictionary *impInfo = [NSMutableDictionary dictionary];
                int ifd = open(impFile.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);
                if (ifd >= 0) {
                    int stdinFD2 = open("/dev/null", O_RDONLY);
                    posix_spawn_file_actions_t fa2;
                    posix_spawn_file_actions_init(&fa2);
                    posix_spawn_file_actions_adddup2(&fa2, stdinFD2, STDIN_FILENO);
                    posix_spawn_file_actions_adddup2(&fa2, ifd, STDOUT_FILENO);
                    posix_spawn_file_actions_adddup2(&fa2, ifd, STDERR_FILENO);
                    posix_spawnattr_t attr2;
                    posix_spawnattr_init(&attr2);
                    sigset_t emp2; sigemptyset(&emp2);
                    posix_spawnattr_setsigmask(&attr2, &emp2);
                    posix_spawnattr_setflags(&attr2, POSIX_SPAWN_SETSIGMASK);
                    char *iargv[] = { (char *)found.UTF8String, (char *)"-c",
                                      (char *)"import zxtouch,sys;print(zxtouch.__file__)", NULL };
                    extern char **environ;
                    pid_t ipid = 0;
                    int ierr = posix_spawn(&ipid, found.UTF8String, &fa2, &attr2, iargv, environ);
                    posix_spawn_file_actions_destroy(&fa2);
                    posix_spawnattr_destroy(&attr2);
                    close(ifd);
                    if (stdinFD2 >= 0) close(stdinFD2);
                    NSString *iexit = @"-1";
                    if (ierr == 0) {
                        int ist = 0;
                        int wI = zxWaitTimeout(ipid, 10.0, &ist);
                        if (wI == 1) {
                            kill(ipid, SIGKILL);
                            int stKillI = 0;
                            zxWaitTimeout(ipid, 2.0, &stKillI);
                            iexit = @"timeout(killed)";
                        } else if (wI == -1) {
                            iexit = [NSString stringWithFormat:@"waitpid_errno=%d", errno];
                        } else {
                            iexit = [NSString stringWithFormat:@"%d", WIFEXITED(ist) ? WEXITSTATUS(ist) : -1];
                        }
                    } else {
                        iexit = [NSString stringWithFormat:@"posix_spawn_err=%d(%s)", ierr, strerror(ierr)];
                    }
                    NSString *iout = [NSString stringWithContentsOfFile:impFile encoding:NSUTF8StringEncoding error:nil] ?: @"";
                    iout = [iout stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (iout.length > 200) iout = [[iout substringToIndex:200] stringByAppendingString:@"…"];
                    [[NSFileManager defaultManager] removeItemAtPath:impFile error:nil];
                    impInfo[@"exit"] = iexit;
                    impInfo[@"output"] = iout;
                } else {
                    impInfo[@"exit"] = [NSString stringWithFormat:@"open_errno=%d", errno];
                    impInfo[@"output"] = @"";
                }
                root[@"module_import"] = impInfo;
            } else {
                // ---- 一个能用的解释器都没有：取证模式 ----
                // 1) 对每个「存在」的候选直接试跑 --version（不管 access(X_OK) 结果），
                //    把 stderr 也抓进来 —— dyld 依赖损坏、Permission denied 一眼可辨。
                NSString *probeFile = @"/var/mobile/Library/ZXTouch/.pycheck_version";
                NSMutableArray *probes = [NSMutableArray array];
                for (NSDictionary *c in checks) {
                    if (![c[@"exists"] boolValue]) continue;
                    NSString *p = c[@"path"];
                    NSString *cmd = [NSString stringWithFormat:@"'%@' --version > '%@' 2>&1", p, probeFile];
                    int st = call_system(cmd.UTF8String);
                    int exitCode = (st == -1) ? -1 : (WIFEXITED(st) ? WEXITSTATUS(st) : -1);
                    NSString *out = [NSString stringWithContentsOfFile:probeFile encoding:NSUTF8StringEncoding error:nil] ?: @"";
                    out = [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (out.length > 200) out = [[out substringToIndex:200] stringByAppendingString:@"…"];
                    [probes addObject:@{ @"path": p, @"exit": [NSString stringWithFormat:@"%d", exitCode], @"output": out }];
                }
                root[@"probes"] = probes;

                // 2) 两棵树的 dpkg 记录：python3 到底装进了哪棵树、装的什么版本。
                //    输出空/报「no packages found」的那棵树 = python 没装进去的那棵。
                NSMutableDictionary *dpkgOut = [NSMutableDictionary dictionary];
                NSString *pkgArgs = @"python3 python3.12 python3.11 python3.10 python3.9";
                for (NSString *dq in @[root[@"jbroot_prefix"] ?: @"", @"/var/jb"]) {
                    if (![dq isKindOfClass:[NSString class]] || dq.length == 0) continue;
                    // rootless 越狱的 dpkg 数据库在 <jb>/var/lib/dpkg，必须指定 --admindir
                    // 否则 dpkg-query 用默认的 /var/lib/dpkg 查不到任何包
                    NSString *admindir = [dq stringByAppendingPathComponent:@"var/lib/dpkg"];
                    NSString *cmd = [NSString stringWithFormat:@"'%@/usr/bin/dpkg-query' --admindir='%@' -W %@ > '%@' 2>&1 || echo QUERY_FAILED",
                                     dq, admindir, pkgArgs, probeFile];
                    int stD = call_system(cmd.UTF8String);
                    NSString *out = [NSString stringWithContentsOfFile:probeFile encoding:NSUTF8StringEncoding error:nil] ?: @"";
                    out = [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (out.length == 0) {
                        out = (stD == -1) ? @"(查询通道不可用：shell 无法执行)" : @"(无输出)";
                    }
                    if (out.length > 500) out = [[out substringToIndex:500] stringByAppendingString:@"…"];
                    dpkgOut[dq] = out;
                }
                root[@"dpkg_query"] = dpkgOut;

                // 3) 沙盒范围探针：SpringBoard 到底能 exec /var/jb 下的哪些二进制？
                //    Device B 上 python EPERM 但 dpkg 是正规安装——需要搞清楚沙盒是
                //    拦整个 /var/jb/usr/bin 还是只拦 python。如果 shell 能 exec 但 python 不能，
                //    差异在签名/entitlement；如果整个 /var/jb/usr/bin 都不能 exec，
                //    那就是 Dopamine 配置问题，守护进程是唯一出路。
                {
                    NSArray<NSString *> *scopeProbe = @[
                        @"/bin/sh",
                        @"/var/jb/bin/sh",
                        @"/var/jb/usr/bin/sh",
                        @"/var/jb/usr/bin/date",
                        @"/var/jb/usr/bin/ls",
                        @"/var/jb/usr/bin/env",
                        @"/var/jb/usr/bin/dpkg",
                        @"/var/jb/usr/bin/python3.9",
                        @"/var/jb/usr/bin/python3",
                        @"/var/jb/usr/libexec/zxrunner",
                        @"/usr/bin/env",
                        @"/usr/bin/date",
                        @"/usr/bin/python3"
                    ];
                    NSMutableArray *scopeResults = [NSMutableArray array];
                    NSString *scopeProbeFile = @"/var/mobile/Library/ZXTouch/.pycheck_scope";
                    for (NSString *p in scopeProbe) {
                        NSString *item = [NSString string];
                        BOOL exists = [fm fileExistsAtPath:p];
                        int accErrno = 0;
                        BOOL acc = exists ? (access(p.UTF8String, X_OK) == 0) : NO;
                        if (exists && !acc) accErrno = errno;
                        // 有 access 权限才 posix_spawn 试跑；没权限的直接记 EPERM
                        NSString *spawnResult = @"";
                        if (acc) {
                            int sfd = open(scopeProbeFile.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);
                            if (sfd >= 0) {
                                posix_spawn_file_actions_t fa2;
                                posix_spawn_file_actions_init(&fa2);
                                posix_spawn_file_actions_addopen(&fa2, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
                                posix_spawn_file_actions_adddup2(&fa2, sfd, STDOUT_FILENO);
                                posix_spawn_file_actions_adddup2(&fa2, sfd, STDERR_FILENO);
                                posix_spawnattr_t attr2;
                                posix_spawnattr_init(&attr2);
                                sigset_t emp2; sigemptyset(&emp2);
                                posix_spawnattr_setsigmask(&attr2, &emp2);
                                posix_spawnattr_setflags(&attr2, POSIX_SPAWN_SETSIGMASK);
                                char *argv2[] = { (char *)p.UTF8String, (char *)"--version", NULL };
                                extern char **environ;
                                pid_t pid2 = 0;
                                int err2 = posix_spawn(&pid2, p.UTF8String, &fa2, &attr2, argv2, environ);
                                posix_spawn_file_actions_destroy(&fa2);
                                posix_spawnattr_destroy(&attr2);
                                close(sfd);
                                if (err2 == 0) {
                                    int st2 = 0;
                                    int w2 = zxWaitTimeout(pid2, 10.0, &st2);
                                    if (w2 == 1) {
                                        kill(pid2, SIGKILL);
                                        int stK2 = 0;
                                        zxWaitTimeout(pid2, 2.0, &stK2);
                                        spawnResult = @"spawn_ok timeout(killed)";
                                    } else if (w2 == -1) {
                                        spawnResult = [NSString stringWithFormat:@"waitpid_errno=%d", errno];
                                    } else {
                                        spawnResult = [NSString stringWithFormat:@"spawn_ok exit=%d", WIFEXITED(st2) ? WEXITSTATUS(st2) : -1];
                                    }
                                } else {
                                    spawnResult = [NSString stringWithFormat:@"spawn_err=%d(%s)", err2, strerror(err2)];
                                }
                            }
                        } else if (exists) {
                            spawnResult = [NSString stringWithFormat:@"access_EPERM errno=%d", accErrno];
                        }
                        [scopeResults addObject:@{
                            @"path": p,
                            @"exists": @(exists),
                            @"access_X_OK": @(acc),
                            @"access_errno": @(accErrno),
                            @"posix_spawn": spawnResult
                        }];
                    }
                    root[@"sandbox_scope_probe"] = scopeResults;
                    [[NSFileManager defaultManager] removeItemAtPath:scopeProbeFile error:nil];
                }
            }

            // 读守护进程 PoC 结果：/tmp/zxrunner_probe 记录 daemon 对 /var/jb 的 exec 权限
            {
                NSMutableDictionary *daemonInfo = [NSMutableDictionary dictionary];

                // 1. plist 存在性检查（LaunchAgents 路径，rootless）
                NSString *agentPlist = @"/var/jb/Library/LaunchAgents/com.zjx.zxrunner.plist";
                BOOL plistExists = [[NSFileManager defaultManager] fileExistsAtPath:agentPlist];
                daemonInfo[@"plist_path"] = agentPlist;
                daemonInfo[@"plist_exists"] = @(plistExists);

                // 2. daemon 二进制存在性
                NSString *binPath = @"/var/jb/usr/libexec/zxrunner";
                BOOL binExists = [[NSFileManager defaultManager] fileExistsAtPath:binPath];
                daemonInfo[@"bin_path"] = binPath;
                daemonInfo[@"bin_exists"] = @(binExists);
                int binErrno = 0;
                BOOL binAcc = binExists ? (access(binPath.UTF8String, X_OK) == 0) : NO;
                if (binExists && !binAcc) binErrno = errno;
                daemonInfo[@"bin_access_X_OK"] = @(binAcc);
                daemonInfo[@"bin_access_errno"] = @(binErrno);

                // 3. /tmp/zxrunner_probe 有没有（daemon 是否被 launchd 拉起过）
                NSString *probePath = @"/tmp/zxrunner_probe";
                NSString *probeContent = [NSString stringWithContentsOfFile:probePath encoding:NSUTF8StringEncoding error:nil];
                daemonInfo[@"probe_path"] = probePath;
                daemonInfo[@"probe_exists"] = @(probeContent.length > 0);
                daemonInfo[@"probe_content"] = probeContent ?: @"";

                NSString *sockPath = @"/tmp/zxrunner.sock";
                daemonInfo[@"socket_path"] = sockPath;
                daemonInfo[@"socket_exists"] = @([[NSFileManager defaultManager] fileExistsAtPath:sockPath]);
                BOOL sockConnected = NO;
                int sockErrno = 0;
                NSString *pingReply = @"";
                int cfd = socket(AF_UNIX, SOCK_STREAM, 0);
                if (cfd >= 0) {
                    struct sockaddr_un saddr = {0};
                    saddr.sun_family = AF_UNIX;
                    strncpy(saddr.sun_path, sockPath.UTF8String, sizeof(saddr.sun_path) - 1);
                    struct timeval ctv = { 1, 0 };
                    setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &ctv, sizeof(ctv));
                    setsockopt(cfd, SOL_SOCKET, SO_SNDTIMEO, &ctv, sizeof(ctv));
                    if (connect(cfd, (struct sockaddr *)&saddr, sizeof(saddr)) == 0) {
                        sockConnected = YES;
                        if (write(cfd, "{\"cmd\":\"ping\"}\r\n", sizeof("{\"cmd\":\"ping\"}\r\n") - 1) > 0) {
                            char rbuf[256];
                            ssize_t rn = read(cfd, rbuf, sizeof(rbuf) - 1);
                            if (rn > 0) {
                                rbuf[rn] = '\0';
                                pingReply = [NSString stringWithUTF8String:rbuf] ?: @"";
                            }
                        }
                    } else {
                        sockErrno = errno;
                    }
                    close(cfd);
                } else {
                    sockErrno = errno;
                }
                daemonInfo[@"socket_connect_ok"] = @(sockConnected);
                daemonInfo[@"socket_connect_errno"] = @(sockErrno);
                daemonInfo[@"socket_ping_reply"] = [pingReply stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

                {
                    NSString *dpPy = found ?: @"";
                    if (dpPy.length == 0) {
                        for (NSDictionary *c in checks) {
                            if ([c[@"exists"] boolValue]) { dpPy = c[@"path"]; break; }
                        }
                    }
                    NSMutableString *dpOut = [NSMutableString string];
                    NSString *dpExit = @"";
                    NSString *dpErr = @"";
                    if (dpPy.length == 0) {
                        dpErr = @"无候选 python 路径";
                    } else {
                        int dfd = socket(AF_UNIX, SOCK_STREAM, 0);
                        if (dfd < 0) {
                            dpErr = [NSString stringWithFormat:@"socket errno=%d", errno];
                        } else {
                            struct sockaddr_un daddr = {0};
                            daddr.sun_family = AF_UNIX;
                            strncpy(daddr.sun_path, sockPath.UTF8String, sizeof(daddr.sun_path) - 1);
                            struct timeval dtv = { 8, 0 };
                            setsockopt(dfd, SOL_SOCKET, SO_RCVTIMEO, &dtv, sizeof(dtv));
                            setsockopt(dfd, SOL_SOCKET, SO_SNDTIMEO, &dtv, sizeof(dtv));
                            if (connect(dfd, (struct sockaddr *)&daddr, sizeof(daddr)) != 0) {
                                dpErr = [NSString stringWithFormat:@"connect errno=%d", errno];
                            } else {
                                NSDictionary *dc = @{ @"cmd": @"spawn_python", @"path": dpPy, @"args": @[@"--version"],
                                                      @"env": @{ @"PATH": @"/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin" } };
                                NSData *dj = [NSJSONSerialization dataWithJSONObject:dc options:0 error:nil];
                                NSMutableData *dbuf = [NSMutableData dataWithData:dj ?: [NSData data]];
                                [dbuf appendBytes:"\r\n" length:2];
                                if (write(dfd, dbuf.bytes, dbuf.length) == (ssize_t)dbuf.length) {
                                    char lbuf[4096];
                                    int lpos = 0;
                                    while (1) {
                                        char ch;
                                        ssize_t rn = read(dfd, &ch, 1);
                                        if (rn <= 0) break;
                                        if (ch == '\n') {
                                            if (lpos == 0) continue;
                                            if (lbuf[lpos - 1] == '\r') lpos--;
                                            lbuf[lpos] = '\0';
                                            NSData *ld = [NSData dataWithBytes:lbuf length:lpos];
                                            NSDictionary *r = [NSJSONSerialization JSONObjectWithData:ld options:0 error:nil];
                                            if ([r isKindOfClass:[NSDictionary class]]) {
                                                NSString *rt = r[@"type"];
                                                if ([rt isEqualToString:@"stdout"] || [rt isEqualToString:@"stderr"]) {
                                                    [dpOut appendString:(r[@"data"] ?: @"")];
                                                } else if ([rt isEqualToString:@"exit"]) {
                                                    dpExit = [NSString stringWithFormat:@"%@", r[@"code"] ?: @"?"];
                                                    break;
                                                } else if ([rt isEqualToString:@"error"]) {
                                                    dpErr = r[@"msg"] ?: @"error";
                                                    break;
                                                }
                                            }
                                            lpos = 0;
                                        } else if (lpos < (int)sizeof(lbuf) - 1) {
                                            lbuf[lpos++] = ch;
                                        }
                                    }
                                } else {
                                    dpErr = @"write failed";
                                }
                            }
                            close(dfd);
                        }
                    }
                    NSString *dpOutStr = [dpOut stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (dpOutStr.length > 200) dpOutStr = [[dpOutStr substringToIndex:200] stringByAppendingString:@"…"];
                    daemonInfo[@"python_spawn_path"] = dpPy;
                    daemonInfo[@"python_spawn_exit"] = dpExit;
                    daemonInfo[@"python_spawn_output"] = dpOutStr;
                    daemonInfo[@"python_spawn_error"] = dpErr;
                }

                root[@"daemon_probe"] = daemonInfo;
            }

            // ---- 设备 / 电池 / 越狱 / 安装信息：让这份报告本身就能判断这台设备能否用连点器 ----
            @try {
                root[@"device_info"] = ZXDeviceSummary();
                root[@"battery"] = ZXBatterySummary();
                root[@"jailbreak"] = ZXJailbreakSummary();
                root[@"install"] = ZXInstallSummary();
            } @catch (NSException *exception) {
                root[@"env_info_error"] = exception.reason ?: @"采集失败";
            }

            NSError *jsonErr = nil;
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingPrettyPrinted error:&jsonErr];
            NSString *json = jsonData ? [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] : @"-1;;JSON 序列化失败";
            NSMutableData *payload = [NSMutableData dataWithData:[json dataUsingEncoding:NSUTF8StringEncoding]];
            [payload appendBytes:"\r\n" length:2];
            notifyClientData((UInt8 *)payload.bytes, (CFIndex)payload.length, writeStreamRef);
        }
    }
    else if (taskType == TASK_TAP_TEST)
    {
        @autoreleasepool {
            NSString *data = eventData ? [NSString stringWithUTF8String:(const char *)eventData] : @"";
            NSArray *parts = [data componentsSeparatedByString:@";;"];
            NSString *action = [parts count] > 1 ? parts[1] : @"1";

            if ([action isEqualToString:@"1"]) {
                [TapTestWindow show];
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            } else if ([action isEqualToString:@"0"]) {
                [TapTestWindow hide];
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            } else if ([action isEqualToString:@"clear"]) {
                [TapTestWindow clearRecords];
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            } else if ([action isEqualToString:@"get"]) {
                NSDictionary *payload = @{
                    @"visible": @([TapTestWindow isVisible]),
                    @"orientation": @([Screen getScreenOrientation]),
                    @"screen_bounds": NSStringFromCGRect([Screen getBounds]),
                    @"taps": [TapTestWindow tapRecords],
                };
                NSError *jsonErr = nil;
                NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload
                                                                   options:0
                                                                     error:&jsonErr];
                if (jsonErr) {
                    notifyClient((UInt8*)"-1;;JSON 序列化失败\r\n", writeStreamRef);
                } else {
                    NSMutableData *buf = [NSMutableData dataWithData:jsonData];
                    [buf appendBytes:"\r\n" length:2];
                    notifyClientData((UInt8 *)buf.bytes, (CFIndex)buf.length, writeStreamRef);
                }
            } else {
                notifyClient((UInt8*)"-1;;41;;1 打开 / 41;;0 关闭 / 41;;clear 清空 / 41;;get 记录\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_GO_HOME)
    {
        @autoreleasepool {
            NSError *err = nil;
            BOOL ok = ZXGoHome(&err);
            notifyClient((UInt8*)[(ok ? @"0\r\n" : [NSString stringWithFormat:@"-1;;%@\r\n", err.localizedDescription ?: @"返回主屏幕失败"]) UTF8String], writeStreamRef);
        }
    }
    else if (taskType == TASK_KILL_APP)
    {
        @autoreleasepool {
            NSString *bundle = eventData ? [NSString stringWithUTF8String:(const char *)eventData] : @"";
            bundle = [bundle stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSError *err = nil;
            BOOL ok = ZXKillApp(bundle, &err);
            notifyClient((UInt8*)[(ok ? @"0\r\n" : [NSString stringWithFormat:@"-1;;%@\r\n", err.localizedDescription ?: @"关闭失败"]) UTF8String], writeStreamRef);
        }
    }
    else if (taskType == TASK_PLAY_RING)
    {
        @autoreleasepool {
            NSString *data = eventData ? [NSString stringWithUTF8String:(const char *)eventData] : @"";
            NSArray *parts = [data componentsSeparatedByString:@";;"];
            NSString *path = parts.count > 0 ? parts[0] : @"";
            double seconds = parts.count > 1 ? [parts[1] doubleValue] : 0.0;
            if (seconds <= 0) seconds = 1.0;
            NSError *err = nil;
            BOOL ok = ZXPlayRingtone(path, seconds, &err);
            notifyClient((UInt8*)[(ok ? @"0\r\n" : [NSString stringWithFormat:@"-1;;%@\r\n", err.localizedDescription ?: @"响铃失败"]) UTF8String], writeStreamRef);
        }
    }
    else if (taskType == TASK_SET_VOLUME)
    {
        @autoreleasepool {
            NSString *data = eventData ? [NSString stringWithUTF8String:(const char *)eventData] : @"";
            NSArray *parts = [data componentsSeparatedByString:@";;"];
            NSString *mode = parts.count > 0 ? parts[0] : @"percent";
            double value = parts.count > 1 ? [parts[1] doubleValue] : 50.0;
            NSError *err = nil;
            BOOL ok = ZXSetVolume(mode, value, &err);
            notifyClient((UInt8*)[(ok ? @"0\r\n" : [NSString stringWithFormat:@"-1;;%@\r\n", err.localizedDescription ?: @"调整音量失败"]) UTF8String], writeStreamRef);
        }
    }
    else if (taskType == TASK_STOP_ALL_SCRIPTS)
    {
        @autoreleasepool {
            NSError *err = nil;
            BOOL ok = ZXStopAllScripts(&err);
            notifyClient((UInt8*)[(ok ? @"0\r\n" : [NSString stringWithFormat:@"-1;;%@\r\n", err.localizedDescription ?: @"停止脚本失败"]) UTF8String], writeStreamRef);
        }
    }
    else if (taskType == TASK_MAKE_CALL)
    {
        @autoreleasepool {
            NSString *data = eventData ? [NSString stringWithUTF8String:(const char *)eventData] : @"";
            NSArray *parts = [data componentsSeparatedByString:@";;"];
            NSString *number = parts.count > 0 ? parts[0] : @"";
            NSString *sim = parts.count > 1 ? parts[1] : @"default";
            NSError *err = nil;
            BOOL ok = ZXMakeCall(number, sim, &err);
            notifyClient((UInt8*)[(ok ? @"0\r\n" : [NSString stringWithFormat:@"-1;;%@\r\n", err.localizedDescription ?: @"拨号失败"]) UTF8String], writeStreamRef);
        }
    }
    else if (taskType == TASK_SEND_SMS)
    {
        @autoreleasepool {
            NSString *data = eventData ? [NSString stringWithUTF8String:(const char *)eventData] : @"";
            NSArray *parts = [data componentsSeparatedByString:@";;"];
            NSString *number = parts.count > 0 ? parts[0] : @"";
            NSString *text = parts.count > 1 ? parts[1] : @"";
            NSString *sim = parts.count > 2 ? parts[2] : @"default";
            NSError *err = nil;
            BOOL ok = ZXSendSMS(number, text, sim, &err);
            notifyClient((UInt8*)[(ok ? @"0\r\n" : [NSString stringWithFormat:@"-1;;%@\r\n", err.localizedDescription ?: @"发送短信失败"]) UTF8String], writeStreamRef);
        }
    }
    else if (taskType == TASK_SET_WIFI)
    {
        @autoreleasepool {
            NSString *data = eventData ? [NSString stringWithUTF8String:(const char *)eventData] : @"";
            NSString *mode = [[data stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
            BOOL enabled = [mode isEqualToString:@"1"] || [mode isEqualToString:@"on"] || [mode isEqualToString:@"true"];
            NSError *err = nil;
            BOOL ok = ZXSetWiFi(enabled, &err);
            notifyClient((UInt8*)[(ok ? @"0\r\n" : [NSString stringWithFormat:@"-1;;%@\r\n", err.localizedDescription ?: @"开关 WiFi 失败"]) UTF8String], writeStreamRef);
        }
    }
    else if (taskType == TASK_SAVE_SCREENSHOT)
    {
        @autoreleasepool {
            NSString *path = nil;
            NSError *err = nil;
            BOOL ok = ZXSaveScreenshot(&path, &err);
            if (ok) {
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@\r\n", path ?: @""] UTF8String], writeStreamRef);
            } else {
                notifyClient((UInt8*)[[NSString stringWithFormat:@"-1;;%@\r\n", err.localizedDescription ?: @"截屏失败"] UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_INTENT_PROBE)
    {
        @autoreleasepool {
            NSString *json = ZXIntentProbeJSON();
            notifyClient((UInt8*)[[@"0;;" stringByAppendingString:json] UTF8String], writeStreamRef);
        }
    }
    else if (taskType == TASK_INTENT_PROBE_READ)
    {
        @autoreleasepool {
            NSString *path = @"/var/mobile/Library/ZXTouch/intent_probe.json";
            NSString *json = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
            notifyClient((UInt8*)[[@"0;;" stringByAppendingString:(json ?: @"{}")] UTF8String], writeStreamRef);
        }
    }
    else if (taskType == TASK_WECHAT_SEND)
    {
        @autoreleasepool {
            NSString *data = eventData ? [NSString stringWithUTF8String:(const char *)eventData] : @"";
            NSArray *parts = [data componentsSeparatedByString:@";;"];
            NSString *recipient = parts.count > 0 ? parts[0] : @"";
            NSString *text = parts.count > 1 ? parts[1] : @"";
            NSString *log = ZXWeChatSendDiagnostics(recipient, text);
            notifyClient((UInt8*)[[@"0;;" stringByAppendingString:(log ?: @"")] UTF8String], writeStreamRef);
        }
    }
    else if (taskType == TASK_UPDATE_CACHE)
    {
        @autoreleasepool{
            NSError *err = nil;
            updateCacheFromRawData(eventData,  &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)[@"0\r\n" UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_TEST)
    {

    }
}
