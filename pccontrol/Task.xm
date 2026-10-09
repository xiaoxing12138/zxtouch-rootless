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
#import <mach/mach.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <limits.h>
#include <unistd.h>
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
                // 真实运行检测：跑一次 python3 --version，确认解释器真能启动。
                // 只有执行权限不代表能跑起来 —— rootless 下常见 libpython 找不到、在 dyld 阶段就退出。
                NSString *probeFile = @"/var/mobile/Library/ZXTouch/.pycheck_version";
                NSString *probeCmd = [NSString stringWithFormat:@"'%@' --version > '%@' 2>&1", found, probeFile];
                int probeStatus = call_system(probeCmd.UTF8String);
                int exitCode = (probeStatus == -1) ? -1 : (WIFEXITED(probeStatus) ? WEXITSTATUS(probeStatus) : -1);
                NSString *ver = [NSString stringWithContentsOfFile:probeFile encoding:NSUTF8StringEncoding error:nil];
                [[NSFileManager defaultManager] removeItemAtPath:probeFile error:nil];
                root[@"version"] = [ver stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
                root[@"spawn_exit_code"] = [NSString stringWithFormat:@"%d", exitCode];

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
                    call_system(cmd.UTF8String);
                    NSString *out = [NSString stringWithContentsOfFile:probeFile encoding:NSUTF8StringEncoding error:nil] ?: @"";
                    out = [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (out.length > 500) out = [[out substringToIndex:500] stringByAppendingString:@"…"];
                    dpkgOut[dq] = out;
                }
                root[@"dpkg_query"] = dpkgOut;
                [[NSFileManager defaultManager] removeItemAtPath:probeFile error:nil];
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
