#import "Schedule.h"
#import "Common.h"
#import "Config.h"
#import "Play.h"
#import "AlertBox.h"

/*
 脚本包 info.plist 里 `Schedule` 字典的键（由 App 的可视化编辑器写入）：

   StartMode       "manual" | "daily"        默认 manual
   StartTime       "HH:MM"                   每天启动时刻
   Weekdays        数组，1=周日 … 7=周六      缺省或空数组 = 每天都启动
   EndMode         "manual" | "duration" | "daily"
   DurationMinutes 运行多少分钟后自动结束
   EndTime         "HH:MM"                   每天结束时刻

 用法：脚本只在「勾了定时」时才需要这些键；没有 Schedule 键 = 完全手动，调度器跳过。
*/

static NSString * const kScheduleKey      = @"Schedule";
static NSString * const kStartMode         = @"StartMode";
static NSString * const kStartTime         = @"StartTime";
static NSString * const kWeekdays          = @"Weekdays";
static NSString * const kEndMode           = @"EndMode";
static NSString * const kDurationMinutes   = @"DurationMinutes";
static NSString * const kEndTime           = @"EndTime";

static NSString * const kModeDaily         = @"daily";
static NSString * const kModeDuration      = @"duration";

static const NSTimeInterval kTickInterval = 20.0;

// 已按「日期 + 时刻」触发过启动的脚本，避免同一分钟内重复启动。
// 每天清一次，防止长期运行后无限增长。
static NSMutableDictionary<NSString *, NSString *> *gLaunchedKeys = nil;
static NSString *gLaunchedKeysDay = nil;

// 调度器自己观察到的「正在播放的脚本包路径 + 开始时间」。
// 不侵入播放层：每 tick 对比一次 ZXCurrentScriptBundlePath() 即可，
// 最长 20 秒的误差对「运行 N 分钟后结束」完全够用。
static NSString *gObservedPath = nil;
static NSDate *gObservedSince = nil;

static NSTimer *gTickTimer = nil;

static void ZXScheduleTick(void);

/*
把 now 拆成「日期 / 时刻 / 星期」三个串，tick 里判断全用它们。
*/
static void ZXScheduleComponents(NSDate *now, NSString **dayOut, NSString **hmOut, NSInteger *weekdayOut)
{
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSCalendarUnit units = NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
                           NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitWeekday;
    NSDateComponents *components = [calendar components:units fromDate:now];
    if (dayOut) {
        *dayOut = [NSString stringWithFormat:@"%04ld-%02ld-%02ld",
                   (long)components.year, (long)components.month, (long)components.day];
    }
    if (hmOut) {
        *hmOut = [NSString stringWithFormat:@"%02ld:%02ld", (long)components.hour, (long)components.minute];
    }
    if (weekdayOut) {
        *weekdayOut = components.weekday; // 1 = 周日
    }
}

static BOOL ZXScheduleWeekdayMatches(NSDictionary *schedule, NSInteger weekday)
{
    NSArray *days = schedule[kWeekdays];
    if (![days isKindOfClass:[NSArray class]] || days.count == 0) return YES; // 未配置 = 每天
    for (id value in days) {
        if ([value integerValue] == weekday) return YES;
    }
    return NO;
}

static void ZXScheduleStopCurrent(NSString *reason)
{
    NSError *error = nil;
    NSString *path = ZXCurrentScriptBundlePath();
    stopScriptPlaying(&error);
    if (path.length == 0) return;

    NSString *name = [[path lastPathComponent] stringByDeletingPathExtension];
    ZXSafeMainAsync(^{
        showAlertBox(@"小新Lap", [NSString stringWithFormat:@"「%@」%@", name, reason], 3);
    });
}

/*
扫描脚本目录。只认 <xxx>.bdl 目录（递归进子文件夹），跳过隐藏文件。
*/
static void ZXScheduleScan(NSDate *now, NSString *day, NSString *hm, NSInteger weekday)
{
    NSString *root = getScriptsFolder();
    NSFileManager *manager = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [manager enumeratorAtPath:root];

    for (NSString *relativePath in enumerator) {
        if (![[relativePath pathExtension] isEqualToString:@"bdl"]) continue;

        [enumerator skipDescendants]; // .bdl 内部只有脚本文件，没必要往下走

        BOOL isDirectory = NO;
        NSString *bundlePath = [root stringByAppendingPathComponent:relativePath];
        if (![manager fileExistsAtPath:bundlePath isDirectory:&isDirectory] || !isDirectory) continue;

        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                              [bundlePath stringByAppendingPathComponent:@"info.plist"]];
        NSDictionary *schedule = info[kScheduleKey];
        if (![schedule isKindOfClass:[NSDictionary class]]) continue;

        // ---- 自动启动 ----
        NSString *startMode = schedule[kStartMode];
        NSString *startTime = schedule[kStartTime];
        if ([startMode isEqualToString:kModeDaily] &&
            [startTime isKindOfClass:[NSString class]] &&
            [startTime isEqualToString:hm] &&
            ZXScheduleWeekdayMatches(schedule, weekday)) {
            NSString *launchKey = [NSString stringWithFormat:@"%@|%@", bundlePath, day];
            if (gLaunchedKeys[launchKey] == nil) {
                gLaunchedKeys[launchKey] = hm;
                if (isScriptPlaying()) {
                    NSLog(@"com.zjx.springboard: 定时启动跳过「%@」：已有脚本在运行。", bundlePath);
                } else {
                    NSError *error = nil;
                    playScript((UInt8 *)[bundlePath UTF8String], &error);
                    NSLog(@"com.zjx.springboard: 定时启动「%@」：%@", bundlePath, error ?: @"成功");
                    if (!error) {
                        NSString *name = [[bundlePath lastPathComponent] stringByDeletingPathExtension];
                        ZXSafeMainAsync(^{
                            showAlertBox(@"小新Lap", [NSString stringWithFormat:@"已定时启动「%@」", name], 3);
                        });
                    }
                }
            }
        }

        // ---- 自动结束（只对正在播放的这个脚本生效）----
        if (gObservedPath.length == 0 || ![gObservedPath isEqualToString:bundlePath]) continue;

        NSString *endMode = schedule[kEndMode];
        if ([endMode isEqualToString:kModeDuration]) {
            NSInteger minutes = [schedule[kDurationMinutes] integerValue];
            if (minutes > 0 && gObservedSince &&
                [now timeIntervalSinceDate:gObservedSince] >= minutes * 60.0) {
                ZXScheduleStopCurrent([NSString stringWithFormat:@"已运行 %ld 分钟，自动停止。", (long)minutes]);
            }
        } else if ([endMode isEqualToString:kModeDaily]) {
            NSString *endTime = schedule[kEndTime];
            if ([endTime isKindOfClass:[NSString class]] && [endTime isEqualToString:hm]) {
                ZXScheduleStopCurrent(@"已到定时结束时刻，自动停止。");
            }
        }
    }
}

static void ZXScheduleTick(void)
{
    @autoreleasepool {
        NSDate *now = [NSDate date];
        NSString *day = nil;
        NSString *hm = nil;
        NSInteger weekday = 0;
        ZXScheduleComponents(now, &day, &hm, &weekday);

        if (!gLaunchedKeys || ![day isEqualToString:gLaunchedKeysDay]) {
            gLaunchedKeys = [NSMutableDictionary dictionary];
            gLaunchedKeysDay = [day copy];
        }

        // 观察当前播放脚本，换脚本（含从空闲进入播放）时重置计时
        NSString *playing = ZXCurrentScriptBundlePath();
        if (!(playing.length == 0 && gObservedPath.length == 0) && ![playing isEqualToString:gObservedPath]) {
            gObservedPath = [playing copy];
            gObservedSince = playing.length ? now : nil;
        }

        ZXScheduleScan(now, day, hm, weekday);
    }
}

void ZXScheduleInit(void)
{
    if (gTickTimer) return;
    gLaunchedKeys = [NSMutableDictionary dictionary];
    gLaunchedKeysDay = nil;
    gObservedPath = nil;
    gObservedSince = nil;

    // 必须显式挂到主 run loop：ZXScheduleInit() 是从后台队列调的，
    // scheduledTimerWithTimeInterval: 会挂到「当前线程」的 run loop 上，
    // 而那个 run loop 根本不会跑 —— 定时器就永远不触发。
    gTickTimer = [NSTimer timerWithTimeInterval:kTickInterval
                                        repeats:YES
                                          block:^(__unused NSTimer *timer) {
        @try {
            ZXScheduleTick();
        } @catch (NSException *exception) {
            NSLog(@"### com.zjx.springboard: 定时调度器异常：%@ -- %@", exception.name, exception.reason);
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:gTickTimer forMode:NSRunLoopCommonModes];
    NSLog(@"com.zjx.springboard: 脚本定时调度器已启动（%.0f 秒一轮）。", kTickInterval);
}
