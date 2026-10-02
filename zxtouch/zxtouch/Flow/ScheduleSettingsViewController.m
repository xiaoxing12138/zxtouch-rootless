//
//  ScheduleSettingsViewController.m
//  小新Lap 可视化脚本
//

#import "ScheduleSettingsViewController.h"
#import "Util.h"
#import "Socket.h"

#import <math.h>

// info.plist 里 Schedule 字典的键（和引擎 Schedule.xm 一一对应，改这里要同步改那边）
static NSString * const kScheduleKey     = @"Schedule";
static NSString * const kStartMode       = @"StartMode";
static NSString * const kStartTime       = @"StartTime";
static NSString * const kWeekdays        = @"Weekdays";
static NSString * const kEndMode         = @"EndMode";
static NSString * const kDurationMinutes = @"DurationMinutes";
static NSString * const kEndTime         = @"EndTime";

static NSString * const kModeManual   = @"manual";
static NSString * const kModeDaily    = @"daily";
static NSString * const kModeDuration = @"duration";

static NSArray<NSString *> *ZXWeekdayTitles(void)
{
    return @[@"周日", @"周一", @"周二", @"周三", @"周四", @"周五", @"周六"];   // 序号 1 = 周日
}

/// 把「9:5」「09:30」「9：30」都理成「09:30」；不是合法时刻就返回 nil
static NSString *ZXNormalizeTime(NSString *text)
{
    NSString *raw = [[text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                     stringByReplacingOccurrencesOfString:@"：" withString:@":"];
    NSArray<NSString *> *parts = [raw componentsSeparatedByString:@":"];
    if (parts.count != 2) return nil;
    NSInteger hour = parts[0].integerValue;
    NSInteger minute = parts[1].integerValue;
    if (parts[0].length == 0 || parts[1].length == 0) return nil;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return nil;
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)hour, (long)minute];
}

// 页面上的段：可见段按 RunMode 动态拼，段号不写死，免得条件一改就要重排
typedef NS_ENUM(NSInteger, ZXScheduleSection) {
    ZXScheduleSectionRunNow = 0,
    ZXScheduleSectionStartMode,
    ZXScheduleSectionStartTime,
    ZXScheduleSectionWeekdays,
    ZXScheduleSectionEndMode,
    ZXScheduleSectionDuration,
    ZXScheduleSectionEndTime,
};

@interface ScheduleSettingsViewController ()

@property (nonatomic, copy) NSString *bundlePath;

@property (nonatomic, copy) NSString *startMode;
@property (nonatomic, copy) NSString *startTime;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *weekdays;
@property (nonatomic, copy) NSString *endMode;
@property (nonatomic) NSInteger durationMinutes;
@property (nonatomic, copy) NSString *endTime;

@property (nonatomic, strong) NSArray<NSNumber *> *sections;   // 可见段（ZXScheduleSection）

@end

@implementation ScheduleSettingsViewController

- (instancetype)initWithScriptBundlePath:(NSString *)bundlePath
{
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) {
        _bundlePath = [bundlePath copy];
        _startMode = kModeManual;
        _startTime = @"09:00";
        _weekdays = [NSMutableArray array];
        _endMode = kModeManual;
        _durationMinutes = 30;
        _endTime = @"23:00";
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"启动 / 结束";
    [self loadFromBundle];
    [self rebuildSections];
}

- (void)loadFromBundle
{
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                          [self.bundlePath stringByAppendingPathComponent:@"info.plist"]];
    NSDictionary *schedule = [info[kScheduleKey] isKindOfClass:[NSDictionary class]] ? info[kScheduleKey] : nil;

    self.startMode = [schedule[kStartMode] isEqual:kModeDaily] ? kModeDaily : kModeManual;
    self.startTime = ZXNormalizeTime(schedule[kStartTime]) ?: @"09:00";

    NSMutableArray<NSNumber *> *days = [NSMutableArray array];
    for (id value in schedule[kWeekdays]) {
        if ([value isKindOfClass:[NSNumber class]]) [days addObject:value];
    }
    self.weekdays = days;

    NSString *mode = schedule[kEndMode];
    if ([mode isEqualToString:kModeDuration]) {
        self.endMode = kModeDuration;
    } else if ([mode isEqualToString:kModeDaily]) {
        self.endMode = kModeDaily;
    } else {
        self.endMode = kModeManual;
    }
    self.durationMinutes = [schedule[kDurationMinutes] integerValue] ?: 30;
    self.endTime = ZXNormalizeTime(schedule[kEndTime]) ?: @"23:00";
}

- (void)rebuildSections
{
    NSMutableArray<NSNumber *> *list = [NSMutableArray array];
    [list addObject:@(ZXScheduleSectionRunNow)];
    [list addObject:@(ZXScheduleSectionStartMode)];
    if ([self.startMode isEqualToString:kModeDaily]) {
        [list addObject:@(ZXScheduleSectionStartTime)];
        [list addObject:@(ZXScheduleSectionWeekdays)];
    }
    [list addObject:@(ZXScheduleSectionEndMode)];
    if ([self.endMode isEqualToString:kModeDuration]) {
        [list addObject:@(ZXScheduleSectionDuration)];
    } else if ([self.endMode isEqualToString:kModeDaily]) {
        [list addObject:@(ZXScheduleSectionEndTime)];
    }
    self.sections = list;
}

- (ZXScheduleSection)sectionKind:(NSInteger)index
{
    return (ZXScheduleSection)self.sections[index].integerValue;
}

#pragma mark - 保存

- (void)persist
{
    NSString *infoPath = [self.bundlePath stringByAppendingPathComponent:@"info.plist"];
    NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:infoPath];
    NSMutableDictionary *info = [existing isKindOfClass:[NSDictionary class]] ? [existing mutableCopy]
                                                                              : [NSMutableDictionary dictionary];

    NSMutableDictionary *schedule = [NSMutableDictionary dictionary];
    if ([self.startMode isEqualToString:kModeDaily]) {
        schedule[kStartMode] = kModeDaily;
        schedule[kStartTime] = self.startTime;
        schedule[kWeekdays] = [self.weekdays copy];     // 空数组 = 每天
    }
    if ([self.endMode isEqualToString:kModeDuration]) {
        schedule[kEndMode] = kModeDuration;
        schedule[kDurationMinutes] = @(MAX(1, self.durationMinutes));
    } else if ([self.endMode isEqualToString:kModeDaily]) {
        schedule[kEndMode] = kModeDaily;
        schedule[kEndTime] = self.endTime;
    }

    if (schedule.count == 0) {
        [info removeObjectForKey:kScheduleKey];        // 全手动 = 键都不留，调度器直接跳过这个脚本
    } else {
        info[kScheduleKey] = schedule;
    }

    if (![info writeToFile:infoPath atomically:YES]) {
        [Util showAlertBoxWithOneOption:self title:@"保存失败" message:@"无法写入 info.plist。" buttonString:@"确定"];
    }
    [self rebuildSections];
    [self.tableView reloadData];
}

#pragma mark - 立即启动

/*
 立刻跑一次。和脚本列表里点「运行」走同一条命令（19 + 脚本包路径），
 只是这里顺手把「定时结束」也带上了 —— 脚本跑起来之后照样会被调度器按设置停掉。
*/
- (void)runNow
{
    Socket *socket = [[Socket alloc] init];
    if ([socket connect:@"127.0.0.1" byPort:6000] != 0) {
        [Util showAlertBoxWithOneOption:self title:@"错误" message:@"小新Lap 服务不可用，请确认插件已生效。" buttonString:@"确定"];
        return;
    }
    // 命令必须以 \r\n 结尾，否则 socket server 不派发，recv 会一直阻塞把 App 卡死
    [socket send:[NSString stringWithFormat:@"19%@\r\n", self.bundlePath]];
    NSString *result = [socket recv:1024];
    [socket close];

    if (result.length == 0 || [result characterAtIndex:0] != '0') {
        [Util showAlertBoxWithOneOption:self title:@"错误"
                                message:[NSString stringWithFormat:@"无法运行脚本。%@", result.length ? result : @"服务无响应"]
                           buttonString:@"确定"];
    }
}

+ (NSString *)summaryForBundle:(NSString *)bundlePath
{
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                          [bundlePath stringByAppendingPathComponent:@"info.plist"]];
    NSDictionary *schedule = [info[kScheduleKey] isKindOfClass:[NSDictionary class]] ? info[kScheduleKey] : nil;
    if (schedule.count == 0) return @"未设置（手动启动）";

    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    if ([schedule[kStartMode] isEqual:kModeDaily]) {
        NSString *dayText = @"每天";
        NSArray *days = schedule[kWeekdays];
        if ([days isKindOfClass:[NSArray class]] && days.count > 0) {
            NSArray<NSString *> *titles = ZXWeekdayTitles();
            NSMutableArray<NSString *> *names = [NSMutableArray array];
            for (NSNumber *day in days) {
                NSInteger index = day.integerValue - 1;
                if (index >= 0 && index < (NSInteger)titles.count) [names addObject:titles[index]];
            }
            if (names.count) dayText = [names componentsJoinedByString:@"/"];
        }
        [parts addObject:[NSString stringWithFormat:@"%@ %@ 启动", dayText, ZXNormalizeTime(schedule[kStartTime]) ?: @"--:--"]];
    }

    NSInteger minutes = [schedule[kDurationMinutes] integerValue];
    if ([schedule[kEndMode] isEqual:kModeDuration] && minutes > 0) {
        [parts addObject:[NSString stringWithFormat:@"跑 %ld 分钟后停", (long)minutes]];
    } else if ([schedule[kEndMode] isEqual:kModeDaily]) {
        [parts addObject:[NSString stringWithFormat:@"%@ 停", ZXNormalizeTime(schedule[kEndTime]) ?: @"--:--"]];
    }

    return parts.count ? [parts componentsJoinedByString:@" · "] : @"未设置（手动启动）";
}

#pragma mark - 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return self.sections.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch ([self sectionKind:section]) {
        case ZXScheduleSectionRunNow:    return @"立即启动";
        case ZXScheduleSectionStartMode: return @"定时启动";
        case ZXScheduleSectionWeekdays:  return @"重复";
        case ZXScheduleSectionEndMode:   return @"定时结束";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    switch ([self sectionKind:section]) {
        case ZXScheduleSectionRunNow:
            return @"先跑一次看看效果，跟脚本列表里点「运行」是一回事。";
        case ZXScheduleSectionStartMode:
            return @"到点自动运行这个脚本。同一时刻只允许一个脚本在跑，已有脚本在运行时这一轮会跳过。";
        case ZXScheduleSectionWeekdays:
            return @"一个都不勾 = 每天都启动。";
        case ZXScheduleSectionEndMode:
            return @"只对正在运行的这个脚本生效，手动启动的脚本一样会被停掉。";
        default:
            return nil;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch ([self sectionKind:section]) {
        case ZXScheduleSectionRunNow:    return 1;
        case ZXScheduleSectionStartMode: return 2;   // 手动 / 每天定时
        case ZXScheduleSectionEndMode:   return 3;   // 手动 / 跑够时长 / 每天定时
        case ZXScheduleSectionWeekdays:  return 7;
        default: return 1;
    }
}

- (UITableViewCell *)valueCellWithIdentifier:(NSString *)identifier
{
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:identifier];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.imageView.image = nil;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    ZXScheduleSection kind = [self sectionKind:indexPath.section];

    if (kind == ZXScheduleSectionRunNow) {
        UITableViewCell *cell = [self valueCellWithIdentifier:@"runNow"];
        cell.textLabel.text = @"立刻运行一次";
        cell.textLabel.textColor = self.view.tintColor;
        cell.detailTextLabel.text = nil;
        return cell;
    }

    if (kind == ZXScheduleSectionStartMode || kind == ZXScheduleSectionEndMode) {
        UITableViewCell *cell = [self valueCellWithIdentifier:@"choice"];
        NSArray<NSString *> *titles = (kind == ZXScheduleSectionStartMode)
            ? @[@"手动启动", @"每天定时启动"]
            : @[@"手动停止", @"跑够时长自动停", @"每天定时停止"];
        NSString *current = (kind == ZXScheduleSectionStartMode) ? self.startMode : self.endMode;
        NSArray<NSString *> *modes = (kind == ZXScheduleSectionStartMode)
            ? @[kModeManual, kModeDaily]
            : @[kModeManual, kModeDuration, kModeDaily];
        cell.textLabel.text = titles[indexPath.row];
        cell.accessoryType = [current isEqualToString:modes[indexPath.row]] ? UITableViewCellAccessoryCheckmark
                                                                             : UITableViewCellAccessoryNone;
        cell.tintColor = self.view.tintColor;
        return cell;
    }

    if (kind == ZXScheduleSectionWeekdays) {
        UITableViewCell *cell = [self valueCellWithIdentifier:@"weekday"];
        NSInteger value = indexPath.row + 1;     // 1 = 周日
        cell.textLabel.text = ZXWeekdayTitles()[indexPath.row];
        BOOL on = NO;
        for (NSNumber *day in self.weekdays) {
            if (day.integerValue == value) { on = YES; break; }
        }
        cell.accessoryType = on ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.tintColor = self.view.tintColor;
        return cell;
    }

    UITableViewCell *cell = [self valueCellWithIdentifier:@"value"];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if (kind == ZXScheduleSectionStartTime) {
        cell.textLabel.text = @"启动时刻";
        cell.detailTextLabel.text = self.startTime;
    } else if (kind == ZXScheduleSectionEndTime) {
        cell.textLabel.text = @"结束时刻";
        cell.detailTextLabel.text = self.endTime;
    } else {
        cell.textLabel.text = @"运行多久";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld 分钟", (long)self.durationMinutes];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    ZXScheduleSection kind = [self sectionKind:indexPath.section];

    if (kind == ZXScheduleSectionRunNow) {
        [self runNow];
        return;
    }

    if (kind == ZXScheduleSectionStartMode || kind == ZXScheduleSectionEndMode) {
        if (kind == ZXScheduleSectionStartMode) {
            self.startMode = (indexPath.row == 0) ? kModeManual : kModeDaily;
        } else {
            self.endMode = @[kModeManual, kModeDuration, kModeDaily][indexPath.row];
        }
        [self persist];
        return;
    }

    if (kind == ZXScheduleSectionWeekdays) {
        NSInteger value = indexPath.row + 1;
        for (NSUInteger i = 0; i < self.weekdays.count; i++) {
            if (self.weekdays[i].integerValue == value) {
                [self.weekdays removeObjectAtIndex:i];
                [self persist];
                return;
            }
        }
        [self.weekdays addObject:@(value)];
        [self persist];
        return;
    }

    BOOL isTime = (kind == ZXScheduleSectionStartTime || kind == ZXScheduleSectionEndTime);
    NSString *current = (kind == ZXScheduleSectionStartTime) ? self.startTime
                      : (kind == ZXScheduleSectionEndTime)   ? self.endTime
                                                             : [NSString stringWithFormat:@"%ld", (long)self.durationMinutes];
    NSString *title = (kind == ZXScheduleSectionStartTime) ? @"启动时刻"
                    : (kind == ZXScheduleSectionEndTime)   ? @"结束时刻"
                                                           : @"运行多久";
    NSString *note = isTime ? @"24 小时制，例如 09:30 或 21:05" : @"单位是分钟，例如 30";

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:note
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = current;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.keyboardType = isTime ? UIKeyboardTypeNumbersAndPunctuation : UIKeyboardTypeNumberPad;
        field.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightMedium];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        ScheduleSettingsViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        NSString *text = alert.textFields.firstObject.text;

        if (isTime) {
            NSString *normalized = ZXNormalizeTime(text);
            if (!normalized) {
                [Util showAlertBoxWithOneOption:strongSelf title:@"时刻不对"
                                        message:@"请按 24 小时制填写，例如 09:30、21:05。"
                                   buttonString:@"确定"];
                return;
            }
            if (kind == ZXScheduleSectionStartTime) strongSelf.startTime = normalized;
            else strongSelf.endTime = normalized;
        } else {
            NSInteger minutes = (NSInteger)llround(text.doubleValue);
            if (minutes <= 0 || minutes > 24 * 60) {
                [Util showAlertBoxWithOneOption:strongSelf title:@"时长不对"
                                        message:@"请填 1 到 1440 之间的分钟数。" buttonString:@"确定"];
                return;
            }
            strongSelf.durationMinutes = minutes;
        }
        [strongSelf persist];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
