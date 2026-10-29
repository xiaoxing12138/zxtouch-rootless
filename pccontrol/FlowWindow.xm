//
//  FlowWindow.xm
//  小新Lap 可视化流程编辑器（内容挂在选项面板里，自己不弹窗）
//

#import "FlowWindow.h"
#import "FunctionWindow.h"    // 同一张面板：编辑器不再自己开窗口
#import "FloatingMenu.h"      // 单步调试时临时藏掉控制圆点
#import "ScriptFloat.h"      // 脚本悬浮球配置
#import "FlowScript.h"
#import "PickOverlay.h"
#import "AlertBox.h"
#import "Common.h"
#import "Config.h"

// 「执行此步骤」直接调引擎，不走 Python
#import "Touch.h"
#import "ColorPicker.h"
#import "ScreenMatch.h"
#import "TextRecognization/TextRecognizer.h"
#import "Process.h"
#import "UIKeyboard.h"
#import "Play.h"
#import "../zxtouch/zxtouch/ZXImageCropViewController.h"

#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>
#import <math.h>   // llround / fabs
#import <stdio.h>  // snprintf
#import <string.h> // memcpy
#import <unistd.h> // usleep

#define FW_ROW_H    45.0f
#define FW_GAP      5.0f
#define FW_DELETE_W 88.0f   // 左滑露出来的「删除」宽度
#define FW_CELL_H   38.0f   // 「添加步骤」子浮窗里一个类型格的高度
#define FW_SUB_TITLE_H 46.0f
#define FW_SUB_MIN_W 220.0f
#define FW_SUB_MIN_H 120.0f
#define FW_SUB_GRIP  26.0f  // 右下角缩放把手的大小
#define FW_SUB_EXEC_W 74.0f // 「执行此步骤」按钮宽度

// 子浮窗宽高：所有脚本共用一套，存公共配置（和选项面板的 panel_state 一样是全局的）
static char kFWRepeatStepKey;

// 「不成立」分支开关：缺省开（老脚本行为不变）
static BOOL fwElseEnabled(NSDictionary *step)
{
    id v = step[@"ElseEnabled"];
    return [v isKindOfClass:[NSNumber class]] ? [v boolValue] : YES;
}

// 判断分支是否收起：缺省展开
static BOOL fwCollapsed(NSDictionary *step)
{
    id v = step[@"Collapsed"];
    return [v isKindOfClass:[NSNumber class]] ? [v boolValue] : NO;
}

// 拖动时不能把步骤放进自己内部：把这些容器数组全部排除掉
// 用指针相等的集合：空的 Then/Else 内容彼此 isEqual，用 Set 会把别的分支也误排除
static void fwCollectContainers(NSDictionary *step, NSHashTable *out)
{
    for (NSString *key in @[@"Steps", @"Then", @"Else"]) {
        id arr = step[key];
        if (![arr isKindOfClass:[NSMutableArray class]]) continue;
        [out addObject:arr];
        for (id child in arr) {
            if ([child isKindOfClass:[NSDictionary class]]) fwCollectContainers(child, out);
        }
    }
}

static NSString * const kSubSizeWidthKey  = @"flow_sub_w";
static NSString * const kSubSizeHeightKey = @"flow_sub_h";

static CGSize fwSubSizeLoad(void)
{
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:getCommonConfigFilePath()];
    CGFloat w = [config[kSubSizeWidthKey] doubleValue];
    CGFloat h = [config[kSubSizeHeightKey] doubleValue];
    return CGSizeMake((w > 0) ? w : 0, (h > 0) ? h : 0);
}

static void fwSubSizeSave(CGFloat w, CGFloat h)
{
    NSString *path = getCommonConfigFilePath();
    NSMutableDictionary *config = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (!config) config = [NSMutableDictionary dictionary];
    config[kSubSizeWidthKey] = @(w);
    config[kSubSizeHeightKey] = @(h);
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                             withIntermediateDirectories:YES attributes:nil error:NULL];
    [config writeToFile:path atomically:YES];
}

static NSString *fwOCRLanguageTitle(NSString *code)
{
    static NSDictionary<NSString *, NSString *> *names = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @{ @"zh-Hans": @"简体中文", @"zh-Hant": @"繁体中文", @"en-US": @"英文",
                   @"fr-FR": @"法语", @"it-IT": @"意大利语", @"de-DE": @"德语",
                   @"es-ES": @"西班牙语", @"pt-BR": @"葡萄牙语" };
    });
    NSString *name = names[code];
    return name.length > 0 ? name : code;
}

static NSArray<NSString *> *fwOCRSelectedLanguages(id value)
{
    NSString *text = [value isKindOfClass:[NSString class]] ? value : @"";
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *part in [text componentsSeparatedByString:@","]) {
        NSString *code = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (code.length > 0 && ![out containsObject:code]) [out addObject:code];
    }
    return out;
}

static NSString *fwOCRLanguageSummary(NSArray<NSString *> *codes)
{
    if (codes.count == 0) return @"点这里选择";
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (NSString *code in codes) [titles addObject:fwOCRLanguageTitle(code)];
    return [titles componentsJoinedByString:@"、"];
}

// 脚本目录里所有 .bdl（含子目录），按文件名排序；选择器里存的是包的绝对路径
static NSArray<NSDictionary *> *fwScriptItems(void)
{
    NSString *root = getScriptsFolder();
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    NSDirectoryEnumerator *e = [[NSFileManager defaultManager] enumeratorAtPath:root];
    for (NSString *rel in e) {
        if (![rel.pathExtension isEqualToString:@"bdl"]) continue;
        [items addObject:@{ @"name": rel.lastPathComponent,
                            @"folder": rel.stringByDeletingLastPathComponent ?: @"",
                            @"path": [root stringByAppendingPathComponent:rel] }];
    }
    return [items sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCompare:b[@"name"]];
    }];
}

static NSString * const kSubPosXKey = @"flow_sub_x";
static NSString * const kSubPosYKey = @"flow_sub_y";

static BOOL fwSubPosLoad(CGPoint *out)
{
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:getCommonConfigFilePath()];
    id x = config[kSubPosXKey];
    id y = config[kSubPosYKey];
    if (![x isKindOfClass:[NSNumber class]] || ![y isKindOfClass:[NSNumber class]]) return NO;
    out->x = [x doubleValue];
    out->y = [y doubleValue];
    return YES;
}

static void fwSubPosSave(CGPoint origin)
{
    NSString *path = getCommonConfigFilePath();
    NSMutableDictionary *config = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (!config) config = [NSMutableDictionary dictionary];
    config[kSubPosXKey] = @(origin.x);
    config[kSubPosYKey] = @(origin.y);
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                             withIntermediateDirectories:YES attributes:nil error:NULL];
    [config writeToFile:path atomically:YES];
}

// 页面种类（参数编辑 / 设置都在子浮窗里，不再是页面）
static NSString * const kPageList = @"list";   // 步骤列表（整条流程 / 成立时 / 不成立时）

#pragma mark - 配色

// 一种颜色给一深一浅两份，跟着面板窗口的 overrideUserInterfaceStyle 切
static UIColor *fwColor(uint32_t light, uint32_t dark)
{
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        uint32_t v = (traits.userInterfaceStyle == UIUserInterfaceStyleDark) ? dark : light;
        return [UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0
                               green:((v >> 8) & 0xFF) / 255.0
                                blue:(v & 0xFF) / 255.0 alpha:1];
    }];
}

// 每种步骤一个色：左边色条、图标底、子浮窗的格子都用它
static UIColor *fwTypeColor(NSString *kind)
{
    if ([kind isEqualToString:kFlowTap])       return fwColor(0x2F6BFF, 0x5A9BFF);
    if ([kind isEqualToString:kFlowSwipe])     return fwColor(0x7B4DFF, 0xA98BFF);
    if ([kind isEqualToString:kFlowWait])      return fwColor(0xB87700, 0xFFB84D);
    if ([kind isEqualToString:kFlowToast])     return fwColor(0x0E9F8A, 0x2ED3B7);
    if ([kind isEqualToString:kFlowRepeat])    return fwColor(0x8D6E63, 0xBCAAA4);
    if ([kind isEqualToString:kFlowColor])     return fwColor(0xD9551F, 0xFF8F5E);
    if ([kind isEqualToString:kFlowFindColor]) return fwColor(0xC22E7A, 0xF0559B);
    if ([kind isEqualToString:kFlowCountColor]) return fwColor(0x8A4B00, 0xD08A2E);
    if ([kind isEqualToString:kFlowImage])     return fwColor(0x1B8F49, 0x35C46B);
    if ([kind isEqualToString:kFlowOCR])       return fwColor(0x0E7490, 0x2AA6C4);
    if ([kind isEqualToString:kFlowAppSwitch])  return fwColor(0x3F51B5, 0x7C8CF8);
    if ([kind isEqualToString:kFlowWiFi])       return fwColor(0x00796B, 0x4DB6AC);
    if ([kind isEqualToString:kFlowScreenshot]) return fwColor(0x455A64, 0x90A4AE);
    if ([kind isEqualToString:kFlowPaste])     return fwColor(0x6A1B9A, 0xB085D8);
    if ([kind isEqualToString:kFlowRing])      return fwColor(0xB8860B, 0xF0C24B);
    if ([kind isEqualToString:kFlowVolume])    return fwColor(0x00838F, 0x4DD0E1);
    if ([kind isEqualToString:kFlowStopAll])   return fwColor(0x8E24AA, 0xC77DFF);
    if ([kind isEqualToString:kFlowRunScript]) return fwColor(0x00695C, 0x4DB6AC);
    if ([kind isEqualToString:kFlowCall])      return fwColor(0x2E7D32, 0x66BB6A);
    if ([kind isEqualToString:kFlowSMS])       return fwColor(0x0277BD, 0x4FC3F7);
    if ([kind isEqualToString:kFlowDingTalk])  return fwColor(0x1765AD, 0x4A90D9);
    if ([kind isEqualToString:kFlowWeCom])     return fwColor(0x0FA958, 0x4DD98A);
    if ([kind isEqualToString:kFlowWeChat])    return fwColor(0x1FAE1F, 0x5CE65C);
    if ([kind isEqualToString:kFlowHttp])      return fwColor(0x1565C0, 0x64B5F6);
    if ([kind isEqualToString:kFlowShell])     return fwColor(0x37474F, 0x8FA3AD);
    return fwColor(0x4C8DFF, 0x6EA8FF);
}

// 步骤名 + 一个铅笔字符：提示左上角这行名字点一下就能改
static NSAttributedString *fwStepNameWithPencil(NSString *name)
{
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:(name ?: @"")
        attributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold],
                      NSForegroundColorAttributeName: ZXPalette(ZXPalText) }];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:@"  ✎"
        attributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightRegular],
                      NSForegroundColorAttributeName: ZXPalette(ZXPalSub) }]];
    return s;
}

// 步骤里已保存的坐标：缺字段 / 空串都当作没保存
static NSNumber *fwStepCoordNumber(NSDictionary *step, NSString *key)
{
    id v = step[key];
    if ([v isKindOfClass:[NSNumber class]]) return v;
    if ([v isKindOfClass:[NSString class]] && [v length] > 0) return @([v doubleValue]);
    return nil;
}

// 参数按语义分组，声明顺序仍然是字段自己的声明顺序
static NSArray<NSDictionary<NSString *, id> *> *fwGroupsForKind(NSString *kind)
{
    if ([kind isEqualToString:kFlowTap]) return @[
        @{ @"title": @"位置", @"keys": @[ @"X", @"Y" ] },
        @{ @"title": @"点按", @"keys": @[ @"Count", @"Interval", @"Hold" ] },
    ];
    if ([kind isEqualToString:kFlowSwipe]) return @[
        @{ @"title": @"起点", @"keys": @[ @"X1", @"Y1" ] },
        @{ @"title": @"终点", @"keys": @[ @"X2", @"Y2" ] },
        @{ @"title": @"滑动时长", @"keys": @[ @"Duration" ] },
    ];
    if ([kind isEqualToString:kFlowWait]) return @[
        @{ @"title": @"延迟方式", @"keys": @[ @"Mode" ] },
        @{ @"title": @"固定延迟", @"keys": @[ @"Seconds" ] },
        @{ @"title": @"随机延迟", @"keys": @[ @"SecondsMin", @"SecondsMax" ] },
    ];
    if ([kind isEqualToString:kFlowToast]) return @[ @{ @"title": @"提示", @"keys": @[ @"Text", @"Seconds" ] } ];
    if ([kind isEqualToString:kFlowColor]) return @[
        @{ @"title": @"位置", @"keys": @[ @"X", @"Y" ] },
        @{ @"title": @"颜色", @"keys": @[ @"Color", @"Tolerance" ] },
    ];
    if ([kind isEqualToString:kFlowFindColor]) return @[
        @{ @"title": @"区域", @"keys": @[ @"X1", @"Y1", @"X2", @"Y2" ] },
        @{ @"title": @"颜色", @"keys": @[ @"Color", @"Tolerance" ] },
    ];
    if ([kind isEqualToString:kFlowCountColor]) return @[
        @{ @"title": @"区域", @"keys": @[ @"X1", @"Y1", @"X2", @"Y2" ] },
        @{ @"title": @"颜色", @"keys": @[ @"Color", @"Tolerance" ] },
        @{ @"title": @"数量", @"keys": @[ @"Count", @"Mode" ] },
    ];
    if ([kind isEqualToString:kFlowImage]) return @[
        @{ @"title": @"模板", @"keys": @[ @"Template" ] },
        @{ @"title": @"匹配", @"keys": @[ @"Threshold" ] },
        @{ @"title": @"搜索范围", @"keys": @[ @"Mode" ] },
        @{ @"title": @"区域", @"keys": @[ @"X1", @"Y1", @"X2", @"Y2" ] },
    ];
    if ([kind isEqualToString:kFlowOCR]) return @[
        @{ @"title": @"区域", @"keys": @[ @"X1", @"Y1", @"X2", @"Y2" ] },
        @{ @"title": @"判据", @"keys": @[ @"Match", @"Text" ] },
        @{ @"title": @"识别", @"keys": @[ @"Languages" ] },
    ];
    if ([kind isEqualToString:kFlowAppSwitch]) return @[
        @{ @"title": @"方式", @"keys": @[ @"Mode" ] },
        @{ @"title": @"目标", @"keys": @[ @"Bundle" ] },
    ];
    if ([kind isEqualToString:kFlowWiFi]) return @[ @{ @"title": @"方式", @"keys": @[ @"Mode" ] } ];
    if ([kind isEqualToString:kFlowPaste]) return @[
        @{ @"title": @"输入方式", @"keys": @[ @"Mode" ] },
        @{ @"title": @"自定义文字", @"keys": @[ @"Text" ] },
    ];
    if ([kind isEqualToString:kFlowRunScript]) return @[ @{ @"title": @"脚本", @"keys": @[ @"Script" ] } ];
    if ([kind isEqualToString:kFlowRing]) return @[
        @{ @"title": @"铃声", @"keys": @[ @"Sound" ] },
        @{ @"title": @"时长", @"keys": @[ @"Seconds" ] },
    ];
    if ([kind isEqualToString:kFlowVolume]) return @[
        @{ @"title": @"方式", @"keys": @[ @"Mode" ] },
        @{ @"title": @"数值", @"keys": @[ @"Percent" ] },
    ];
    if ([kind isEqualToString:kFlowCall]) return @[
        @{ @"title": @"拨打", @"keys": @[ @"Number", @"SIM" ] },
    ];
    if ([kind isEqualToString:kFlowSMS]) return @[
        @{ @"title": @"发送", @"keys": @[ @"Number", @"Text", @"SIM" ] },
    ];
    if ([kind isEqualToString:kFlowDingTalk]) return @[
        @{ @"title": @"接收", @"keys": @[ @"URL", @"Secret" ] },
        @{ @"title": @"内容", @"keys": @[ @"Text" ] },
    ];
    if ([kind isEqualToString:kFlowWeCom]) return @[
        @{ @"title": @"接收", @"keys": @[ @"URL" ] },
        @{ @"title": @"内容", @"keys": @[ @"Text" ] },
    ];
    if ([kind isEqualToString:kFlowHttp]) return @[
        @{ @"title": @"请求", @"keys": @[ @"Method", @"URL" ] },
        @{ @"title": @"请求选项", @"keys": @[ @"Headers", @"Body", @"Timeout", @"SaveFile" ] },
    ];
    if ([kind isEqualToString:kFlowShell]) return @[
        @{ @"title": @"命令", @"keys": @[ @"Command", @"Timeout" ] },
    ];
    return @[];
}

#pragma mark - 定时设置（和 App 的 ScheduleSettingsViewController / 引擎 Schedule.xm 键值一一对应）

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

/// 把「9:5」「09:30」「9：30」都理成「09:30」；不是合法时刻就返回 nil
static NSString *fwNormalizeTime(NSString *text)
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

/// 每次改动都立刻写进脚本包的 info.plist；全手动 = Schedule 键整个拿掉，调度器直接跳过
static void fwPersistSchedule(NSString *bundlePath, NSString *startMode, NSString *startTime,
                              NSArray<NSNumber *> *weekdays, NSString *endMode,
                              NSInteger durationMinutes, NSString *endTime)
{
    NSString *infoPath = [bundlePath stringByAppendingPathComponent:@"info.plist"];
    NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:infoPath];
    NSMutableDictionary *info = [existing isKindOfClass:[NSDictionary class]] ? [existing mutableCopy]
                                                                              : [NSMutableDictionary dictionary];

    NSMutableDictionary *schedule = [NSMutableDictionary dictionary];
    if ([startMode isEqualToString:kModeDaily]) {
        schedule[kStartMode] = kModeDaily;
        schedule[kStartTime] = fwNormalizeTime(startTime) ?: @"09:00";
        schedule[kWeekdays] = [weekdays copy];          // 空数组 = 每天
    }
    if ([endMode isEqualToString:kModeDuration]) {
        schedule[kEndMode] = kModeDuration;
        schedule[kDurationMinutes] = @(MAX(1, durationMinutes));
    } else if ([endMode isEqualToString:kModeDaily]) {
        schedule[kEndMode] = kModeDaily;
        schedule[kEndTime] = fwNormalizeTime(endTime) ?: @"23:00";
    }

    if (schedule.count == 0) [info removeObjectForKey:kScheduleKey];
    else info[kScheduleKey] = schedule;

    if (![info writeToFile:infoPath atomically:YES]) {
        showAlertBox(@"错误", @"无法写入 info.plist。", 999);
    }
}

#pragma mark - 列表行

// 列表里的一行：左滑露出「删除」，长按弹「复制到下方」，右侧把手按住直接拖动排序
@interface FWStepRowView : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView   *content;     // 会被左右平移的那层
@property (nonatomic, strong) UILabel  *numberLabel; // 排序时要重编号
@property (nonatomic, strong) UIButton *deleteBtn;
@property (nonatomic, strong) UIView   *dragHandle;  // 右侧把手（自己挂 pan，有 translationInView 可用）
@property (nonatomic, weak)   NSDictionary *step;    // 排序时靠它把视图和数据对上
@property (nonatomic, strong) NSMutableArray *ownerSteps; // 这行属于哪一层（根列表 / 重复里 / 成立 / 不成立）
@property (nonatomic) NSInteger ownerDepth;          // 缩进层数，拖动时用来选落点
@property (nonatomic) CGFloat blockBottom;            // 这一步连同子步骤的底边（拖动时收空档用）
@property (nonatomic) BOOL swipeEnabled;             // 能左滑删除
@property (nonatomic) BOOL dragEnabled;              // 把手能拖动排序
@property (nonatomic, copy) void (^onTap)(void);
@property (nonatomic, copy) void (^onDelete)(void);
@property (nonatomic, copy) void (^onCopy)(void);
@property (nonatomic, copy) void (^onDragBegan)(void);
@property (nonatomic, copy) void (^onDragMoved)(CGFloat dy);
@property (nonatomic, copy) void (^onDragEnded)(void);
@end

@implementation FWStepRowView {
    BOOL    _open;          // 删除按钮是不是已经露出来
    CGFloat _panStartX;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // 行自己就是圆角容器：左滑时拽出去的那层被裁掉，删除块正好填满右边
        self.layer.cornerRadius = 12;
        self.clipsToBounds = YES;

        _deleteBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        _deleteBtn.backgroundColor = ZXPalette(ZXPalDanger);
        _deleteBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        [_deleteBtn setTitle:@"删除" forState:UIControlStateNormal];
        [_deleteBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _deleteBtn.hidden = YES;
        __weak typeof(self) weakSelf = self;
        [_deleteBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
            FWStepRowView *row = weakSelf;
            if (row && row.onDelete) row.onDelete();
        }] forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_deleteBtn];

        _content = [[UIView alloc] initWithFrame:self.bounds];
        _content.backgroundColor = ZXPalette(ZXPalRow);
        _content.layer.cornerRadius = 12;
        [self addSubview:_content];

        // 长按弹「复制到下方」；点按要等长按失败才算数，不然一松手两个都触发
        UILongPressGestureRecognizer *press =
            [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handlePress:)];
        press.minimumPressDuration = 0.45;
        press.delegate = self;
        [self addGestureRecognizer:press];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
        tap.delegate = self;
        [tap requireGestureRecognizerToFail:press];
        [_content addGestureRecognizer:tap];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        pan.delegate = self;
        [self addGestureRecognizer:pan];
    }
    return self;
}

// 右侧把手：按住直接上下拖（不用先长按），图标本体只负责显示
- (void)installDragHandle {
    if (_dragHandle) return;
    _dragHandle = [[UIView alloc] init];
    _dragHandle.userInteractionEnabled = YES;
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"line.3.horizontal"]];
    icon.tintColor = ZXPalette(ZXPalSub);
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tag = 7;
    [_dragHandle addSubview:icon];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleDragPan:)];
    [_dragHandle addGestureRecognizer:pan];
    [_content addSubview:_dragHandle];   // 跟着 content 走，左滑时一起让开
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _deleteBtn.frame = CGRectMake(self.bounds.size.width - FW_DELETE_W, 0, FW_DELETE_W, self.bounds.size.height);
    // 平移中（transform 非单位矩阵）不能碰 frame，UIKit 会算错
    if (CGAffineTransformIsIdentity(_content.transform)) _content.frame = self.bounds;
    _dragHandle.frame = CGRectMake(self.bounds.size.width - 34.0f, 0, 34.0f, self.bounds.size.height);
    UIView *icon = [_dragHandle viewWithTag:7];
    icon.frame = CGRectMake((34.0f - 16.0f) / 2.0f, (self.bounds.size.height - 16.0f) / 2.0f, 16, 16);
}

// 按下去给一点反馈：整行压暗一档，抬手 / 被手势抢走就还原
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    [UIView animateWithDuration:0.1 animations:^{ self->_content.alpha = 0.68f; }];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    [self resetPressFeedback];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    [self resetPressFeedback];
}
- (void)resetPressFeedback {
    [UIView animateWithDuration:0.16 animations:^{ self->_content.alpha = 1.0f; }];
}

// 露着「删除」时点一下 = 收回来，不触发进参数
- (void)handleTap {
    if (_open) { [self setOpen:NO animated:YES]; return; }
    if (self.onTap) self.onTap();
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    if (!self.swipeEnabled) return;
    if (g.state == UIGestureRecognizerStateBegan) _panStartX = _content.transform.tx;
    CGFloat x = _panStartX + [g translationInView:self].x;
    if (x > 0) x = 0;
    if (x < -FW_DELETE_W) x = -FW_DELETE_W;
    _deleteBtn.hidden = (x > -1.0f);
    _content.transform = CGAffineTransformMakeTranslation(x, 0);
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        [self setOpen:(x < -FW_DELETE_W / 2.0f) animated:YES];
    }
}

- (void)setOpen:(BOOL)open animated:(BOOL)animated {
    _open = open;
    _deleteBtn.hidden = !open;
    void (^apply)(void) = ^{
        self->_content.transform = CGAffineTransformMakeTranslation(open ? -FW_DELETE_W : 0, 0);
    };
    if (animated) [UIView animateWithDuration:0.18 animations:apply];
    else apply();
}

// 长按 = 弹「复制到下方」小菜单（落在把手上不算，把手是拖排序的）
- (void)handlePress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (self.dragEnabled && [g locationInView:self].x > self.bounds.size.width - 34.0f) return;
    if (self.onCopy) self.onCopy();
}

// 把手上的拖动排序：Began 即拿起，松手落下
- (void)handleDragPan:(UIPanGestureRecognizer *)g {
    if (!self.dragEnabled) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        [self setOpen:NO animated:NO];
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.3f;
        self.layer.shadowOffset = CGSizeMake(0, 3);
        self.layer.shadowRadius = 8;
        [UIView animateWithDuration:0.12 animations:^{
            self.transform = CGAffineTransformMakeScale(1.03f, 1.03f);
            self.alpha = 0.95f;
        }];
        if (self.onDragBegan) self.onDragBegan();
    } else if (g.state == UIGestureRecognizerStateChanged) {
        if (self.onDragMoved) self.onDragMoved([g translationInView:self.superview].y);
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        self.layer.shadowOpacity = 0;
        [UIView animateWithDuration:0.12 animations:^{
            self.transform = CGAffineTransformIdentity;
            self.alpha = 1.0f;
        }];
        if (self.onDragEnded) self.onDragEnded();
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch
{
    UIView *view = touch.view;
    while (view && view != self) {
        if ([view isKindOfClass:[UIControl class]]) return NO;
        view = view.superview;
    }
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if ([g isKindOfClass:[UIPanGestureRecognizer class]]) {
        if (!self.swipeEnabled) return NO;
        // 把手那条竖条留给拖动排序，别在这里触发左滑
        if (self.dragEnabled && [g locationInView:self].x > self.bounds.size.width - 34.0f) return NO;
        CGPoint v = [(UIPanGestureRecognizer *)g velocityInView:self];
        return fabs(v.x) > fabs(v.y);   // 竖直方向留给列表自己滚
    }
    return YES;
}
@end

@interface FlowWindow () <UITextFieldDelegate, PHPickerViewControllerDelegate>
@end

static FlowWindow *_fwShared = nil;

@implementation FlowWindow {
    __weak id<FlowEditorHost> _host;
    __weak UIScrollView      *_scroll;      // 面板的内容区，由 FunctionWindow 提供
    CGFloat                   _pw;          // 行宽基准

    NSString                    *_bundlePath;
    NSMutableDictionary         *_flow;
    NSMutableArray<NSMutableDictionary *> *_stack;
    BOOL                         _handwritten;   // main.py 是手写的，改动会覆盖它

    NSMutableArray<FWStepRowView *> *_rows;      // 当前列表里所有层级的步骤行
    NSMutableArray<NSDictionary *>  *_spans;     // 每一层容器的纵向区间（选拖动落点用）
    NSMutableArray<NSDictionary *>  *_branchLabels; // 分支标题 / 空分支提示（拖动容器时一起隐藏）
    FWStepRowView               *_dragRow;
    NSMutableArray               *_dragSourceSteps;
    NSInteger                     _dragSourceIndex;
    NSMutableArray               *_dragTargetSteps;
    NSInteger                     _dragTargetIndex;
    CGFloat                       _dragStartY;
    UIView                       *_dragLine;     // 松手后会插到哪里的指示线
    NSTimer                      *_dragScrollTimer; // 拖动到上下边缘时的自动滚动
    NSInteger                     _stepCursor;    // 全局步骤序号（判断分支、重复内部也算）
    CGFloat                       _dragDisplayY;  // 拖动行当前在内容坐标里的顶部（自动滚动时累加）

    BOOL                         _animateTransition;   // 换页时淡入 + 上移

    // 子浮窗（添加步骤 / 编辑参数 / 设置）：挂在窗口根的整屏容器上，屏幕中间
    UIView                      *_subDim;        // 遮罩 + 卡片
    UIView                      *_subCard;       // 卡片本体（拖把手改尺寸就是改它）
    UIView                      *_subTitleBar;   // 标题栏（拖它可以整体移动子浮窗）
    UILabel                     *_subTitleLabel; // 纯文字标题
    UITextField                 *_subTitleField; // 单步参数页：名字直接放在标题栏里改
    NSMutableDictionary         *_subStep;       // 名字输入框对应的步骤（nil = 纯文字标题）
    UIButton                    *_subExecBtn;    // 「执行此步骤」（单步调试）
    UIButton                    *_subCloseBtn;
    UIImageView                 *_subGrip;       // 右下角把手：拖它改子浮窗宽高
    UIScrollView                *_subScroll;     // 卡片里的内容区
    CGFloat                      _subResizeW;    // 拖把手时的基准宽高（增量累加用）
    CGFloat                      _subResizeH;
    CGFloat                      _kbShift;       // 键盘避让把子浮窗上移了多少
    BOOL                         _subQuietRebuild;

    // 重开子浮窗要用到的参数：改完尺寸要按新宽度把内容重排一遍
    NSString                    *_subTitle;
    CGFloat (^_subBuilder)(UIScrollView *content, CGFloat width);
    void (^_subExec)(void);

    NSMutableDictionary         *_pickDragStep;
    FlowStepType                *_pickDragType;

    // 悬浮球自定义图片：取图用独立窗口，取完在预览页里缩放 / 拖动裁圆
    UIWindow                    *_ballPickWindow;
    UIViewController            *_ballPickHost;
    __weak UIWindow             *_ballPrevKeyWindow;
    NSString                    *_ballPickPath;
    CGFloat                      _ballPickKeepY;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // 键盘避让：子浮窗里的输入框被键盘挡住时，先滚内容区，不够再把子浮窗整体上移。
        // 必须直接读通知里的 frame —— 不能依赖全局 gZXKeyboardTop：它是懒注册的，
        // 第一次弹键盘时本 block 执行的那一刻它还是旧值 0，表现为「第一次点不上移、再点才动」。
        __weak typeof(self) weakSelf = self;
        [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillChangeFrameNotification
            object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
                [weakSelf handleSubKeyboardFrame:n];
            }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillHideNotification
            object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
                [weakSelf animateSubCardBackWithNotification:n];
            }];
    }
    return self;
}

+ (instancetype)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ _fwShared = [[FlowWindow alloc] init]; });
    return _fwShared;
}

- (void)setHost:(id<FlowEditorHost>)host { _host = host; }

#pragma mark - 载入 / 实时落盘

- (void)loadBundle:(NSString *)bundlePath {
    if (bundlePath.length == 0) return;
    _bundlePath = [bundlePath copy];
    if ([FlowScript bundleHasFlow:bundlePath]) {
        _flow = [FlowScript loadFlowFromBundle:bundlePath];
        _handwritten = NO;
    } else {
        _flow = [FlowScript emptyFlow];
        // 手写脚本开进编辑器：改动会实时覆盖 main.py，先说一声
        _handwritten = ![FlowScript bundleHasGeneratedScript:bundlePath];
    }
    if (!_flow) _flow = [FlowScript emptyFlow];

    _stack = [NSMutableArray array];
    [_stack addObject:[self rootPage]];
    _animateTransition = YES;
    [self refresh];
    if (_handwritten) {
        showAlertBox(@"提示", @"这个脚本的 main.py 是手写的，这里的每次修改都会实时覆盖它。", 3);
    }
}

// 实时落盘：每次改动（字段、添加、删除、排序、取点、循环参数）都调它，静默写 flow.plist + 重新生成 main.py
- (void)autosave {
    if (_bundlePath.length == 0 || !_flow) return;
    NSError *error = nil;
    if (![FlowScript saveFlow:_flow toBundle:_bundlePath error:&error] ||
        ![FlowScript writeGeneratedScriptForFlow:_flow toBundle:_bundlePath error:&error]) {
        showAlertBox(@"错误", error.localizedDescription ?: @"保存失败。", 999);
    }
}

- (NSMutableDictionary *)rootPage {
    NSString *name = [[_bundlePath lastPathComponent] stringByDeletingPathExtension];
    return [@{ @"kind": kPageList,
               @"isRoot": @YES,
               @"title": name.length ? name : @"可视化脚本",
               @"steps": _flow[@"Steps"] } mutableCopy];
}

#pragma mark - 页面栈

- (NSMutableArray *)currentSteps {
    id steps = _stack.lastObject[@"steps"];
    return [steps isKindOfClass:[NSMutableArray class]] ? steps : nil;
}

- (void)pushPage:(NSDictionary *)page {
    _animateTransition = YES;
    [_stack addObject:[page mutableCopy]];
    [self refresh];
}

- (void)goBack {
    if (_stack.count > 1) {
        _animateTransition = YES;
        [_stack removeLastObject];
    }
    [self refresh];
}

// 加一步：落盘后直接在子浮窗里打开它的参数
- (void)addStepOfKind:(NSString *)kind toSteps:(NSMutableArray *)steps {
    if (!steps) return;
    NSMutableDictionary *step = [FlowScript newStepOfKind:kind];
    if (!step) return;
    // 设置里定制的默认值覆盖内置默认；只在这一刻生效，已有步骤不受影响
    NSDictionary *defaults = [_flow[@"StepDefaults"] isKindOfClass:[NSDictionary class]]
        ? _flow[@"StepDefaults"][kind] : nil;
    if ([defaults isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in defaults) {
            if ([key isEqualToString:@"Kind"]) continue;
            step[key] = defaults[key];
        }
    }
    [steps addObject:step];
    [self autosave];
    [self refresh];
    [self showParamsSubForStep:step parentSteps:steps];
}

#pragma mark - 把手拖动调整顺序 / 换层

// 拖拽时所有层级的落点：每层容器在布局时登记一条 top / bottom 区间
- (void)registerSpan:(NSMutableArray *)steps top:(CGFloat)top bottom:(CGFloat)bottom
                   x:(CGFloat)x width:(CGFloat)w depth:(NSInteger)depth
{
    [_spans addObject:[NSMutableDictionary dictionaryWithDictionary:
        @{ @"steps": steps, @"top": @(top), @"bottom": @(bottom),
           @"x": @(x), @"width": @(w), @"depth": @(depth) }]];
}

// 这个数组里已经排好版的行，按数据顺序返回（拖动时算插入位置）
- (NSMutableArray<FWStepRowView *> *)rowsForSteps:(NSArray *)steps skip:(FWStepRowView *)skip
{
    NSMutableArray<FWStepRowView *> *out = [NSMutableArray array];
    for (id step in steps) {
        for (FWStepRowView *row in _rows) {
            if (row != skip && row.step == step) { [out addObject:row]; break; }
        }
    }
    return out;
}

- (void)beginDragRow:(FWStepRowView *)row {
    if (!row || !row.ownerSteps) return;
    NSUInteger index = [row.ownerSteps indexOfObjectIdenticalTo:row.step];
    if (index == NSNotFound) return;
    _dragRow = row;
    _dragSourceSteps = row.ownerSteps;
    _dragSourceIndex = (NSInteger)index;
    _dragTargetSteps = nil;
    _dragTargetIndex = NSNotFound;
    // 用 center 算基准：拿起时行上已经挂了缩放，frame 是缩放后的外框
    _dragStartY = row.center.y - FW_ROW_H / 2.0f;
    _dragDisplayY = _dragStartY;
    _scroll.scrollEnabled = NO;
    if (!_dragLine) {
        _dragLine = [[UIView alloc] initWithFrame:CGRectZero];
        _dragLine.backgroundColor = ZXPalette(ZXPalAccent);
        _dragLine.layer.cornerRadius = 1.5f;
        _dragLine.hidden = YES;
    }
    if (_dragLine.superview != _scroll) [_scroll addSubview:_dragLine];
    // 拖动容器时，它里面的行先隐掉，免得出现「父行在飞、子行留在原地」的错觉
    NSHashTable *excluded = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    if (row.step) fwCollectContainers(row.step, excluded);
    for (FWStepRowView *r in _rows) {
        if (r != row && [excluded containsObject:r.ownerSteps]) r.alpha = 0.0f;
    }
    for (NSDictionary *rec in _branchLabels) {
        if ([excluded containsObject:rec[@"steps"]]) [(UILabel *)rec[@"label"] setAlpha:0.0f];
    }
    [self collapseDraggedBlock:row];
    [_scroll bringSubviewToFront:row];

    [_dragScrollTimer invalidate];
    _dragScrollTimer = [NSTimer timerWithTimeInterval:1.0 / 60.0
                                               target:self
                                             selector:@selector(autoScrollDuringDrag:)
                                             userInfo:nil
                                              repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_dragScrollTimer forMode:NSRunLoopCommonModes];
}

- (void)moveDragRow:(FWStepRowView *)row dy:(CGFloat)dy
{
    if (!row || row != _dragRow) return;
    [self positionDragRowAt:_dragStartY + dy];
}

- (void)positionDragRowAt:(CGFloat)y
{
    FWStepRowView *row = _dragRow;
    if (!row) return;
    CGFloat maxY = MAX(0.0f, _scroll.contentSize.height - FW_ROW_H);
    if (y < 0) y = 0;
    if (y > maxY) y = maxY;
    // 拖动中 row 上有缩放 transform，不能碰 frame，只能改 center
    row.center = CGPointMake(row.center.x, y + FW_ROW_H / 2.0f);
    _dragDisplayY = y;
    [self updateDragTargetAtPointerY:y + FW_ROW_H / 2.0f];
}

- (void)autoScrollDuringDrag:(NSTimer *)timer
{
    if (!_dragRow || !_scroll) {
        [timer invalidate];
        _dragScrollTimer = nil;
        return;
    }
    CGFloat visibleH = _scroll.bounds.size.height;
    CGFloat screenY = _dragRow.center.y - _scroll.contentOffset.y;
    CGFloat edge = 46.0f;
    CGFloat step = 0.0f;
    if (screenY < edge) step = -MIN((edge - screenY) * 0.35f + 3.0f, 14.0f);
    else if (screenY > visibleH - edge) step = MIN((screenY - (visibleH - edge)) * 0.35f + 3.0f, 14.0f);
    if (step == 0.0f) return;

    CGFloat maxOffset = MAX(0.0f, _scroll.contentSize.height - visibleH);
    CGFloat target = MAX(0.0f, MIN(_scroll.contentOffset.y + step, maxOffset));
    CGFloat delta = target - _scroll.contentOffset.y;
    if (delta == 0.0f) return;
    _scroll.contentOffset = CGPointMake(0, target);
    [self positionDragRowAt:_dragDisplayY + delta];
}

- (void)collapseDraggedBlock:(FWStepRowView *)row
{
    CGFloat top = row.frame.origin.y;
    CGFloat bottom = MAX(row.blockBottom, top + FW_ROW_H);
    CGFloat delta = bottom - top;
    if (delta <= 0.0f) return;

    for (FWStepRowView *r in _rows) {
        if (r != row && r.frame.origin.y >= bottom) r.frame = CGRectOffset(r.frame, 0, -delta);
    }
    for (NSDictionary *rec in _branchLabels) {
        UILabel *label = rec[@"label"];
        if (label.frame.origin.y >= bottom) label.frame = CGRectOffset(label.frame, 0, -delta);
    }
    for (NSDictionary *dict in _spans) {
        NSMutableDictionary *s = (NSMutableDictionary *)dict;
        CGFloat sTop = [s[@"top"] doubleValue];
        CGFloat sBottom = [s[@"bottom"] doubleValue];
        if (sTop >= bottom) {
            s[@"top"] = @(sTop - delta);
            s[@"bottom"] = @(sBottom - delta);
        } else if (sBottom >= bottom) {
            s[@"bottom"] = @(sBottom - delta);
        }
    }
    CGSize size = _scroll.contentSize;
    _scroll.contentSize = CGSizeMake(size.width, MAX(size.height - delta, 0.0f));
}

- (void)updateDragTargetAtPointerY:(CGFloat)pointerY
{
    FWStepRowView *row = _dragRow;
    if (!row) return;
    NSHashTable *excluded = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    if (row.step) fwCollectContainers(row.step, excluded);

    NSDictionary *span = nil;
    BOOL appendToBranch = NO;
    // 指针压在判断条件的行上时，直接放进它的「成立」分支，而不是排到条件后面
    for (FWStepRowView *r in _rows) {
        if (r == row) continue;
        CGFloat ry = r.frame.origin.y;
        if (pointerY < ry || pointerY > ry + FW_ROW_H) continue;
        NSDictionary *st = r.step;
        if (![st[@"Kind"] isKindOfClass:[NSString class]]) continue;
        if (![FlowScript typeForKind:st[@"Kind"]].isCondition) continue;
        id then = st[@"Then"];
        if (![then isKindOfClass:[NSMutableArray class]] || [excluded containsObject:then]) continue;
        for (NSDictionary *s in _spans) {
            if (s[@"steps"] != then) continue;
            span = s;
            break;
        }
        if (span) { appendToBranch = YES; break; }
    }
    if (!span) {
        for (NSDictionary *s in _spans) {
            if ([excluded containsObject:s[@"steps"]]) continue;
            CGFloat top = [s[@"top"] doubleValue];
            CGFloat bottom = [s[@"bottom"] doubleValue];
            if (pointerY < top || pointerY > bottom) continue;
            if (!span || [s[@"depth"] integerValue] > [span[@"depth"] integerValue]) span = s;
        }
    }
    if (!span) {
        CGFloat best = CGFLOAT_MAX;
        for (NSDictionary *s in _spans) {
            if ([excluded containsObject:s[@"steps"]]) continue;
            CGFloat top = [s[@"top"] doubleValue];
            CGFloat bottom = [s[@"bottom"] doubleValue];
            CGFloat d = (pointerY < top) ? top - pointerY : ((pointerY > bottom) ? pointerY - bottom : 0);
            if (d < best - 0.01f) { best = d; span = s; }
            else if (fabs(d - best) <= 0.01f && span &&
                     [s[@"depth"] integerValue] < [span[@"depth"] integerValue]) span = s;
        }
    }
    if (!span) return;

    NSMutableArray *targetSteps = span[@"steps"];
    NSArray<FWStepRowView *> *ordered = appendToBranch ? @[] : [self rowsForSteps:targetSteps skip:row];
    FWStepRowView *beforeRow = nil;
    for (FWStepRowView *r in ordered) {
        if (pointerY < CGRectGetMidY(r.frame)) { beforeRow = r; break; }
    }
    NSInteger index = beforeRow ? (NSInteger)[targetSteps indexOfObjectIdenticalTo:beforeRow.step]
                                : (NSInteger)targetSteps.count;
    if (index == NSNotFound) index = (NSInteger)targetSteps.count;

    CGFloat lineY = beforeRow ? beforeRow.frame.origin.y - 3.0f
                              : [span[@"bottom"] doubleValue] + 2.0f;
    _dragTargetSteps = targetSteps;
    _dragTargetIndex = index;
    _dragLine.frame = CGRectMake([span[@"x"] doubleValue] + 6.0f, lineY,
                                 MAX([span[@"width"] doubleValue] - 12.0f, 40.0f), 3.0f);
    _dragLine.hidden = NO;
    [_scroll bringSubviewToFront:_dragLine];
    [_scroll bringSubviewToFront:row];
}

- (void)endDragRow {
    FWStepRowView *row = _dragRow;
    NSMutableArray *src = _dragSourceSteps;
    NSMutableArray *dst = _dragTargetSteps;
    NSInteger dstIndex = _dragTargetIndex;
    _dragRow = nil;
    _dragSourceSteps = nil;
    _dragTargetSteps = nil;
    _dragTargetIndex = NSNotFound;
    _dragLine.hidden = YES;
    _scroll.scrollEnabled = YES;
    [_dragScrollTimer invalidate];
    _dragScrollTimer = nil;

    BOOL changed = NO;
    NSDictionary *moved = row.step;   // 行里存的是弱引用：先强持住，免得从数组摘下来那一刻被释放
    NSUInteger oldIndex = (row && src && moved) ? [src indexOfObjectIdenticalTo:moved] : NSNotFound;
    if (oldIndex != NSNotFound && dst && dstIndex != NSNotFound) {
        if (dst == src && dstIndex > (NSInteger)oldIndex) dstIndex -= 1;
        if (dstIndex < 0) dstIndex = 0;
        if (dstIndex <= (NSInteger)dst.count) {
            if (!(dst == src && (NSInteger)oldIndex == dstIndex)) {
                [src removeObjectAtIndex:oldIndex];
                if (dstIndex > (NSInteger)dst.count) dstIndex = (NSInteger)dst.count;
                [dst insertObject:moved atIndex:(NSUInteger)dstIndex];
                changed = YES;
            }
        }
    }
    if (changed) [self autosave];
    [self refreshKeepingScroll];    // 重建一遍最省事（顺带恢复行的缩放和阴影）
}

// 左滑删除：从当前这一页的数组里摘掉这一步
- (void)deleteStep:(NSMutableDictionary *)step {
    [self deleteStep:step fromSteps:[self currentSteps]];
}

- (void)deleteStep:(NSMutableDictionary *)step fromSteps:(NSMutableArray *)steps {
    if (!steps) return;
    NSUInteger index = [steps indexOfObjectIdenticalTo:step];
    if (index == NSNotFound) return;
    [steps removeObjectAtIndex:index];
    [self autosave];
    [self refreshKeepingScroll];
}

// 长按行的菜单：复制到下方
- (void)showCopyMenuForRow:(FWStepRowView *)row step:(NSMutableDictionary *)step {
    [self showCopyMenuForRow:row step:step steps:[self currentSteps]];
}

- (void)showCopyMenuForRow:(FWStepRowView *)row step:(NSMutableDictionary *)step steps:(NSMutableArray *)steps {
    __weak typeof(self) weakSelf = self;
    ZXShowMiniMenuNearView(row, @[ @{
        @"title": @"复制到下方",
        @"icon": @"doc.on.doc",
        @"action": ^{
            FlowWindow *strongSelf = weakSelf;
            if (!strongSelf || !steps) return;
            NSUInteger index = [steps indexOfObjectIdenticalTo:step];
            if (index == NSNotFound) return;
            NSMutableDictionary *copy = [FlowScript mutableStepFromStep:step];
            if (!copy) return;
            [steps insertObject:copy atIndex:index + 1];
            [strongSelf autosave];
            [strongSelf refreshKeepingScroll];
        },
    } ]);
}

#pragma mark - 取点

// 取点器要盖在游戏上，面板和子浮窗都先让开；取完再放回来
- (void)beginPickingForStep:(NSMutableDictionary *)step type:(FlowStepType *)type {
    [self beginPickingForStep:step mode:type.pickMode targets:type.pickTargets];
}

- (void)beginPickingForStep:(NSMutableDictionary *)step mode:(FlowPickMode)mode
                    targets:(NSArray<NSString *> *)targets {
    [_scroll endEditing:YES];
    [_subScroll endEditing:YES];
    [_host flowHostSetCardHidden:YES];
    _subDim.hidden = YES;   // 子浮窗也会被烤进冻结帧

    __weak typeof(self) weakSelf = self;
    // 打开取点器时把这一步已保存的坐标带上：选择器一出现就落在上次保存的位置，不用重新找
    CGPoint pickStart = CGPointZero, pickEnd = CGPointZero;
    BOOL hasPickStart = NO, hasPickEnd = NO;
    if ((mode == FlowPickModePoint || mode == FlowPickModeColor) && targets.count >= 2) {
        NSNumber *x = fwStepCoordNumber(step, targets[0]);
        NSNumber *y = fwStepCoordNumber(step, targets[1]);
        if (x && y) { pickStart = CGPointMake(x.doubleValue, y.doubleValue); hasPickStart = YES; }
    } else if ((mode == FlowPickModePath || mode == FlowPickModeRect) && targets.count >= 4) {
        NSNumber *x1 = fwStepCoordNumber(step, targets[0]);
        NSNumber *y1 = fwStepCoordNumber(step, targets[1]);
        NSNumber *x2 = fwStepCoordNumber(step, targets[2]);
        NSNumber *y2 = fwStepCoordNumber(step, targets[3]);
        if (x1 && y1) { pickStart = CGPointMake(x1.doubleValue, y1.doubleValue); hasPickStart = YES; }
        if (x2 && y2) { pickEnd = CGPointMake(x2.doubleValue, y2.doubleValue); hasPickEnd = YES; }
    }
    [PickOverlay presentWithMode:mode
                    initialStart:pickStart hasStart:hasPickStart
                      initialEnd:pickEnd hasEnd:hasPickEnd
                      completion:^(NSDictionary *result) {
        FlowWindow *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf applyPickResult:result toStep:step mode:mode targets:targets];
        [strongSelf autosave];
        [strongSelf->_host flowHostSetCardHidden:NO];
        strongSelf->_subDim.hidden = NO;
        [strongSelf rebuildSubAnimated:NO];
        [strongSelf refreshKeepingScroll];
    } cancel:^{
        FlowWindow *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf->_host flowHostSetCardHidden:NO];
        strongSelf->_subDim.hidden = NO;
    }];
}

- (void)handlePickRowPan:(UIPanGestureRecognizer *)g {
    NSMutableDictionary *step = _pickDragStep;
    FlowStepType *type = _pickDragType;
    if (!step || !type) return;

    CGPoint point = [g locationInView:nil];
    if (g.state == UIGestureRecognizerStateBegan) {
        __weak typeof(self) weakSelf = self;
        NSArray<NSString *> *targets = type.pickTargets;
        FlowPickMode mode = type.pickMode;
        [PickOverlay beginFollowWithMode:mode completion:^(NSDictionary *result) {
            FlowWindow *s = weakSelf;
            if (!s) return;
            [s applyPickResult:result toStep:step mode:mode targets:targets];
            [s autosave];
            [s rebuildSubAnimated:NO];
            [s refreshKeepingScroll];
        } cancel:^{}];
        [PickOverlay updateFollowAtWindowPoint:point];
    } else if (g.state == UIGestureRecognizerStateChanged) {
        [PickOverlay updateFollowAtWindowPoint:point];
    } else if (g.state == UIGestureRecognizerStateEnded) {
        [PickOverlay finishFollow];
    } else if (g.state == UIGestureRecognizerStateCancelled) {
        [PickOverlay cancelFollow];
    }
}

// 取点 / 框选行只有一种样式（青绿底 + 描边 + 圆圈十字），模板框选与区域框选共用
- (UIView *)makePickRowForStep:(NSDictionary *)step mode:(FlowPickMode)mode
                       targets:(NSArray<NSString *> *)targets title:(NSString *)title
                         width:(CGFloat)w action:(void (^)(void))action
{
    return [self makeActionRow:title
                        detail:[self pickDetailForStep:step mode:mode targets:targets]
                         color:ZXPalette(ZXPalAccent) primary:YES symbol:@"scope" width:w action:action];
}

- (void)applyPickResult:(NSDictionary *)result toStep:(NSMutableDictionary *)step mode:(FlowPickMode)mode
               targets:(NSArray<NSString *> *)targets {
    if (targets.count == 0) return;

    if (mode == FlowPickModePoint || mode == FlowPickModePath ||
        mode == FlowPickModeRect) {
        // 起点 / 终点分开写：滑动要的是方向，不能被外接矩形抹掉
        CGPoint start = [result[kPickStart] CGPointValue];
        CGPoint end = [result[kPickEnd] CGPointValue];
        NSArray<NSNumber *> *values = @[ @(llround(start.x)), @(llround(start.y)),
                                         @(llround(end.x)), @(llround(end.y)) ];
        for (NSUInteger i = 0; i < targets.count && i < values.count; i++) {
            step[targets[i]] = values[i];
        }
    } else if (mode == FlowPickModeColor) {
        CGPoint point = [result[kPickStart] CGPointValue];
        step[targets[0]] = @(llround(point.x));
        if (targets.count > 1) step[targets[1]] = @(llround(point.y));
        if ([result[kPickHex] length] > 0) step[@"Color"] = result[kPickHex];
    } else if (mode == FlowPickModeTemplate) {
        if ([result[kPickTemplate] length] > 0) step[targets[0]] = result[kPickTemplate];
    }
}

// 取点按钮右侧的回显：已经取到的值
- (NSString *)pickDetailForStep:(NSDictionary *)step mode:(FlowPickMode)mode
                        targets:(NSArray<NSString *> *)t {
    NSString *(^v)(NSUInteger) = ^NSString *(NSUInteger i) {
        return (i < t.count) ? [FlowScript textForValue:step[t[i]]] : @"";
    };
    switch (mode) {
        case FlowPickModePoint:
            return [NSString stringWithFormat:@"%@, %@", v(0), v(1)];
        case FlowPickModeColor:
            return [NSString stringWithFormat:@"%@, %@   #%@", v(0), v(1),
                    [FlowScript textForValue:step[@"Color"]]];
        case FlowPickModePath:
            return [NSString stringWithFormat:@"%@,%@ → %@,%@", v(0), v(1), v(2), v(3)];
        case FlowPickModeRect:
            return [NSString stringWithFormat:@"%@,%@ → %@,%@", v(0), v(1), v(2), v(3)];
        case FlowPickModeTemplate: {
            NSString *name = v(0);
            return name.length ? name : @"还没框选";
        }
        default:
            return nil;
    }
}

#pragma mark - 行控件

// 列表里的一行：序号 + 左侧色条 + 图标底 + 标题 / 细节 + 右侧把手
// deletable = 能左滑删除，sortable = 右侧把手拖动排序
- (FWStepRowView *)makeStepRow:(NSString *)title
                    customName:(NSString *)customName
                        detail:(NSString *)detail
                         index:(NSInteger)index
                        symbol:(NSString *)symbol
                         color:(UIColor *)color
                     deletable:(BOOL)deletable
                      sortable:(BOOL)sortable
                         width:(CGFloat)w
                         onTap:(void (^)(void))onTap
                      onDelete:(void (^)(void))onDelete
{
    FWStepRowView *row = [[FWStepRowView alloc] initWithFrame:CGRectMake(0, 0, w, FW_ROW_H)];
    row.swipeEnabled = deletable;
    row.dragEnabled = sortable;
    row.onTap = onTap;
    row.onDelete = onDelete;

    if (index >= 0) {
        UILabel *number = [[UILabel alloc] initWithFrame:CGRectMake(8, 0, 20, FW_ROW_H)];
        number.text = [NSString stringWithFormat:@"%ld", (long)index + 1];
        number.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
        number.textColor = ZXPalette(ZXPalSub);
        number.textAlignment = NSTextAlignmentCenter;
        [row.content addSubview:number];
        row.numberLabel = number;
    }

    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(34, 8, 3, FW_ROW_H - 16)];
    bar.backgroundColor = color;
    bar.layer.cornerRadius = 1.5;
    [row.content addSubview:bar];

    UIView *tile = [[UIView alloc] initWithFrame:CGRectMake(45, (FW_ROW_H - 26) / 2.0f, 26, 26)];
    tile.backgroundColor = [color colorWithAlphaComponent:0.16];
    tile.layer.cornerRadius = 8;
    [row.content addSubview:tile];

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.tintColor = color;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.frame = CGRectInset(tile.bounds, 5, 5);
    [tile addSubview:icon];

    CGFloat textX = 79.0f;
    CGFloat textW = MAX(w - textX - (sortable ? 34.0f : 12.0f), 60.0f);
    UILabel *main = [[UILabel alloc] initWithFrame:CGRectMake(textX, detail.length ? 3 : 0,
                                                              textW, detail.length ? 18 : FW_ROW_H)];
    main.adjustsFontSizeToFitWidth = YES;
    main.minimumScaleFactor = 0.8;
    main.tag = 101;
    if (customName.length > 0) {
        // 自定义名用青绿色加粗跟在最前，系统原名灰色小字跟在右边，一眼能分清
        NSMutableAttributedString *s = [[NSMutableAttributedString alloc] init];
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:customName attributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold],
            NSForegroundColorAttributeName: ZXPalette(ZXPalAccent),
        }]];
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"  %@", title] attributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightRegular],
            NSForegroundColorAttributeName: ZXPalette(ZXPalSub),
        }]];
        main.attributedText = s;
    } else {
        main.text = title;
        main.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        main.textColor = ZXPalette(ZXPalText);
    }
    [row.content addSubview:main];

    if (detail.length > 0) {
        UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(textX, 22, textW, 14)];
        sub.tag = 102;
        sub.text = detail;
        sub.font = [UIFont systemFontOfSize:11];
        sub.textColor = ZXPalette(ZXPalSub);
        sub.adjustsFontSizeToFitWidth = YES;
        sub.minimumScaleFactor = 0.75;
        [row.content addSubview:sub];
    }

    if (sortable) [row installDragHandle];
    return row;
}

// 一整行的按钮：标题左对齐 + 右侧细节
// primary = 主操作（青绿底 + 青绿描边），否则就是一张普通卡片
- (UIView *)makeActionRow:(NSString *)title
                   detail:(NSString *)detail
                    color:(UIColor *)color
                  primary:(BOOL)primary
                    width:(CGFloat)w
                   action:(void (^)(void))action
{
    return [self makeActionRow:title detail:detail color:color primary:primary
                        symbol:nil width:w action:action];
}

// symbol 非空时在标题后面挂个图标（取坐标那行挂「圆圈加十字」，让人一眼看出这行可以点）
- (UIView *)makeActionRow:(NSString *)title
                   detail:(NSString *)detail
                    color:(UIColor *)color
                  primary:(BOOL)primary
                   symbol:(NSString *)symbolName
                    width:(CGFloat)w
                   action:(void (^)(void))action
{
    UIButton *row = [UIButton buttonWithType:UIButtonTypeSystem];
    CGFloat rowH = FW_ROW_H - 5.0f;
    row.frame = CGRectMake(0, 0, w, rowH);
    row.backgroundColor = primary ? [color colorWithAlphaComponent:0.16] : ZXPalette(ZXPalRow);
    row.layer.cornerRadius = 10;
    row.layer.borderWidth = 1;
    row.layer.borderColor = (primary ? [color colorWithAlphaComponent:0.55] : ZXPalette(ZXPalLine)).CGColor;

    // 标题和右侧细节都自己摆：按钮自带的 titleLabel 没法定宽，窄面板上会和细节叠字
    CGFloat detailW = (detail.length > 0) ? MAX(w * 0.52f, 90.0f) : 0;
    UILabel *main = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, MAX(w - 28 - detailW - 8, 60), rowH)];
    UIFont *mainFont = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    UIColor *mainColor = primary ? color : ZXPalette(ZXPalText);
    UIImage *symbolImage = symbolName.length ? [[UIImage systemImageNamed:symbolName] imageWithTintColor:mainColor] : nil;
    if (symbolImage) {
        NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
        attachment.image = symbolImage;
        attachment.bounds = CGRectMake(0, -2.0f, 14, 14);
        NSMutableAttributedString *text =
            [[NSMutableAttributedString alloc] initWithString:[title stringByAppendingString:@"  "]
                                                   attributes:@{ NSFontAttributeName: mainFont,
                                                                 NSForegroundColorAttributeName: mainColor }];
        [text appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
        main.attributedText = text;
    } else {
        main.text = title;
        main.font = mainFont;
        main.textColor = mainColor;
    }
    main.adjustsFontSizeToFitWidth = YES;
    main.minimumScaleFactor = 0.75;
    main.userInteractionEnabled = NO;
    [row addSubview:main];

    if (detail.length > 0) {
        UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(w - 14 - detailW, 0, detailW, rowH)];
        sub.text = detail;
        sub.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
        sub.textColor = primary ? color : ZXPalette(ZXPalValue);
        sub.textAlignment = NSTextAlignmentRight;
        sub.adjustsFontSizeToFitWidth = YES;
        sub.minimumScaleFactor = 0.7;
        sub.userInteractionEnabled = NO;
        [row addSubview:sub];
    }

    [row addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        if (action) action();
    }] forControlEvents:UIControlEventTouchUpInside];
    return row;
}

// 一行「标签 + 输入框」：步骤参数和循环设置共用
- (UIView *)makeValueRow:(NSString *)title
                   value:(id)value
                 integer:(BOOL)integer
                   width:(CGFloat)w
                onChange:(void (^)(NSString *text))onChange
{
    return [self makeValueRow:title value:value integer:integer stepper:NO stepValue:0 width:w onChange:onChange];
}

// stepper = YES 时输入框右边挂一对上下箭头，点一下按当前值的量级加减；
// stepValue > 0 时改为固定按这个值加减
- (UIView *)makeValueRow:(NSString *)title
                   value:(id)value
                 integer:(BOOL)integer
                 stepper:(BOOL)stepper
               stepValue:(double)stepValue
                   width:(CGFloat)w
                onChange:(void (^)(NSString *text))onChange
{
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, FW_ROW_H - 5.0f)];
    row.backgroundColor = ZXPalette(ZXPalRow);
    row.layer.cornerRadius = 10;
    row.layer.borderWidth = 1;
    row.layer.borderColor = ZXPalette(ZXPalLine).CGColor;

    CGFloat labelW = MIN(150.0f, w * 0.46f);
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, labelW, row.frame.size.height)];
    label.text = title;
    label.font = [UIFont systemFontOfSize:14];
    label.textColor = ZXPalette(ZXPalSub);
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.75;
    [row addSubview:label];

    CGFloat fieldX = 12 + labelW + 6;
    CGFloat fieldH = row.frame.size.height - 12.0f;
    CGFloat fieldW = MAX(w - fieldX - 12 - (stepper ? 26.0f : 0.0f), 60);
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(fieldX, 6, fieldW, fieldH)];
    field.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    field.textColor = ZXPalette(ZXPalValue);
    field.tintColor = ZXPalette(ZXPalAccent);
    field.backgroundColor = ZXPalette(ZXPalField);
    field.layer.cornerRadius = 8;
    field.layer.borderColor = ZXPalette(ZXPalLine).CGColor;
    field.layer.borderWidth = 1;
    field.autoresizingMask = stepper ? UIViewAutoresizingNone : UIViewAutoresizingFlexibleWidth;
    field.keyboardType = integer ? UIKeyboardTypeDecimalPad : UIKeyboardTypeDefault;
    field.inputAccessoryView = ZXFieldKeyboardAccessory(field, title);
    field.delegate = self;   // 开始编辑前把窗口变 key，否则键盘不弹（见 textFieldShouldBeginEditing:）
    field.textAlignment = NSTextAlignmentLeft;
    field.text = [FlowScript textForValue:value];
    [field addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        if (onChange) onChange(field.text ?: @"");
    }] forControlEvents:UIControlEventEditingChanged];
    [row addSubview:field];
    if (stepper) {
        UIView *box = ZXMakeNumberStepperStep(field, integer, stepValue);
        box.frame = CGRectMake(w - 12.0f - 24.0f, 6.0f + (fieldH - 30.0f) / 2.0f, 24.0f, 30.0f);
        [row addSubview:box];
    }
    return row;
}

// 键盘上方那条「完成」：数字键盘没有回车键
- (UIView *)keyboardAccessory {
    UIToolbar *bar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UIBarButtonItem *space = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                          target:nil action:nil];
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                                             style:UIBarButtonItemStylePlain
                                                            target:self
                                                            action:@selector(dismissKeyboard)];
    bar.items = @[space, done];
    return bar;
}

- (void)dismissKeyboard {
    [_scroll endEditing:YES];
    [_subScroll endEditing:YES];
}

// 输入框所在的 window 不是 key window 时，系统键盘不会出来（Apple QA1813：输入框的 window
// 必须成为 key window，否则「The keyboard doesn't show」）。编辑器卡片挂在 FunctionWindow 的
// 窗口上，那个窗口只 hidden=NO、从没 makeKey，所以部分设备/系统版本上点输入框没反应。
// 本回调保证在 becomeFirstResponder 之前调用，先变 key 再放行。
- (BOOL)textFieldShouldBeginEditing:(UITextField *)textField {
    ZXMakeWindowKeyIfNeeded(textField.window);
    return YES;
}

// 编辑结束后归还 key window，否则面板一直占着 key window 会干扰 SpringBoard 触摸路由
- (void)textFieldDidEndEditing:(UITextField *)textField {
    UIWindow *win = textField.window;
    if (win.isKeyWindow) [win resignKeyWindow];
    // 列表里的行内输入（如重复次数）改完后重建一遍，标题上的摘要跟着更新
    [self refreshKeepingScroll];
}

#pragma mark - 子浮窗（屏幕中间：添加步骤 / 编辑参数 / 设置都走这里）

// builder 往内容区铺控件（x 从 8 开始，宽 width），返回内容总高度
- (void)showSubWithTitle:(NSString *)title builder:(CGFloat (^)(UIScrollView *content, CGFloat width))builder {
    [self showSubWithTitle:title step:nil exec:nil builder:builder];
}

/*
 扩展版：
 - step 非 nil 时，标题栏里直接放「步骤名」输入框（不再单独占一行），改完即存；
 - exec 非 nil 时，标题栏右上角多一个「执行此步骤」，用来单步调试。
 宽高记在公共配置里（所有脚本共用一套），拖右下角把手改，和选项面板一个套路。
*/
- (void)showSubWithTitle:(NSString *)title
                    step:(NSMutableDictionary *)step
                    exec:(void (^)(void))exec
                 builder:(CGFloat (^)(UIScrollView *content, CGFloat width))builder
{
    [self dismissSubAnimated:NO];
    _subTitle = [title copy];
    _subStep = step;
    _subBuilder = [builder copy];
    _subExec = [exec copy];
    [self rebuildSubAnimated:!_subQuietRebuild];
}

// 按记录的宽高把子浮窗重新铺一遍；改完尺寸要靠它把内容按新宽度重排
#pragma mark - 子浮窗背景（与选项面板同步）

// 读同一份全局配置：颜色 / 透明度 / 自定义图片，跟 FunctionWindow.applyPanelBackground 一致
- (void)applySubCardBackground:(UIView *)card {
    if (!card) return;
    NSDictionary *config = [[NSDictionary alloc] initWithContentsOfFile:getCommonConfigFilePath()] ?: @{};

    NSString *hex = [config[@"floating_menu_panel_bg_color"] isKindOfClass:[NSString class]]
                        ? config[@"floating_menu_panel_bg_color"] : @"";
    NSString *imageName = [config[@"floating_menu_panel_bg_image"] isKindOfClass:[NSString class]]
                        ? config[@"floating_menu_panel_bg_image"] : @"";
    BOOL hasAlpha = [config[@"floating_menu_panel_bg_alpha"] isKindOfClass:[NSNumber class]];
    CGFloat alpha = hasAlpha ? [config[@"floating_menu_panel_bg_alpha"] doubleValue] : 0.9;
    if (alpha > 1) alpha = 1;
    if (alpha < 0) alpha = 0;

    BOOL hasImageAlpha = [config[@"floating_menu_panel_bg_image_alpha"] isKindOfClass:[NSNumber class]];
    CGFloat imageAlpha = hasImageAlpha ? [config[@"floating_menu_panel_bg_image_alpha"] doubleValue] : -1;
    if (imageAlpha > 1) imageAlpha = 1;
    if (imageAlpha < 0 && hasImageAlpha) imageAlpha = 0;

    UIColor *color = ZXColorFromHex(hex);
    if (!color) color = ZXPalette(ZXPalCard);
    color = [color colorWithAlphaComponent:alpha];

    imageName = [imageName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    UIImage *image = nil;
    if (imageName.length > 0) {
        NSString *path = [[getCommonConfigFilePath() stringByDeletingLastPathComponent]
                          stringByAppendingPathComponent:imageName];
        image = [UIImage imageWithContentsOfFile:path];
    }

    // 清掉旧的背景层
    for (UIView *v in [card.subviews copy]) {
        if (v.tag == 99801 || v.tag == 99802) [v removeFromSuperview];
    }

    if (!image) {
        card.backgroundColor = color;
        return;
    }

    // 有图：图铺底，颜色层叠在图上
    UIImageView *bg = [[UIImageView alloc] initWithFrame:card.bounds];
    bg.image = image;
    bg.alpha = (hasImageAlpha ? imageAlpha : 1.0f);
    bg.contentMode = UIViewContentModeScaleAspectFill;
    bg.clipsToBounds = YES;
    bg.userInteractionEnabled = NO;
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    bg.tag = 99801;
    [card insertSubview:bg atIndex:0];

    card.backgroundColor = [UIColor clearColor];
    if (alpha > 0 && ZXColorFromHex(hex)) {
        UIView *tint = [[UIView alloc] initWithFrame:card.bounds];
        tint.backgroundColor = [ZXColorFromHex(hex) colorWithAlphaComponent:alpha];
        tint.userInteractionEnabled = NO;
        tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        tint.tag = 99802;
        [card insertSubview:tint aboveSubview:bg];
    }
}

- (void)rebuildSubAnimated:(BOOL)animated
{
    UIView *host = [_host flowHostOverlayContainer];
    if (!host || !_subBuilder) return;

    UIView *oldDim = _subDim;
    if (oldDim) {
        [oldDim endEditing:YES];
        @try { [oldDim removeFromSuperview]; } @catch (NSException *e) {}
    }
    _subDim = nil; _subCard = nil; _subTitleBar = nil; _subTitleLabel = nil;
    _subTitleField = nil; _subExecBtn = nil; _subCloseBtn = nil; _subGrip = nil; _subScroll = nil;
    _kbShift = 0;

    __weak typeof(self) weakSelf = self;

    CGFloat hostW = MAX(host.bounds.size.width, 240.0f);
    CGFloat hostH = MAX(host.bounds.size.height, 320.0f);
    CGFloat maxCardW = hostW - 24.0f;
    CGFloat maxCardH = MAX(hostH - 60.0f, FW_SUB_TITLE_H + FW_SUB_MIN_H);

    CGSize remembered = fwSubSizeLoad();
    CGFloat cardW = (remembered.width > 0) ? remembered.width : MIN(hostW - 96.0f, 340.0f);
    cardW = MIN(MAX(cardW, FW_SUB_MIN_W), maxCardW);

    UIView *dim = [[UIView alloc] initWithFrame:host.bounds];

    // 轻遮罩：还能看见后面的主流程。点子浮窗区域外只关子浮窗，主面板保留
    UIView *backdrop = [[UIView alloc] initWithFrame:dim.bounds];
    backdrop.backgroundColor = [UIColor colorWithWhite:0 alpha:0.15];
    backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [backdrop addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                         action:@selector(handleSubBackdropTap:)]];
    [dim addSubview:backdrop];

    UIView *card = [[UIView alloc] init];
    card.backgroundColor = ZXPalette(ZXPalCard);
    card.layer.cornerRadius = 14;
    card.layer.borderWidth = 1;
    card.layer.borderColor = ZXPalette(ZXPalLine).CGColor;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.25f;
    card.layer.shadowRadius = 14;
    card.layer.shadowOffset = CGSizeMake(0, 4);
    card.clipsToBounds = YES;
    // 子浮窗背景与选项面板同步（颜色 / 透明度 / 自定义图片，全局配置）
    [self applySubCardBackground:card];
    [dim addSubview:card];

    // 整条标题栏是拖动手柄（✕ / 执行 按钮在它之上，不挡）
    UIView *titleBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cardW, FW_SUB_TITLE_H)];
    [titleBar addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                         action:@selector(handleSubTitlePan:)]];
    [card addSubview:titleBar];

    // 标题栏内容：参数页是「可点击编辑的步骤名」，其他页是纯文字
    if (_subStep) {
        // 容器：label（带下划线，默认显示）和 textField（编辑时显示）互切
        UIView *nameContainer = [[UIView alloc] init];
        [titleBar addSubview:nameContainer];

        UILabel *nameLabel = [[UILabel alloc] init];
        nameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        nameLabel.textColor = ZXPalette(ZXPalText);
        nameLabel.adjustsFontSizeToFitWidth = YES;
        nameLabel.minimumScaleFactor = 0.8;
        nameLabel.userInteractionEnabled = YES;
        [nameContainer addSubview:nameLabel];
        _subTitleLabel = nameLabel;

        // 下划线
        UIView *underline = [[UIView alloc] init];
        underline.backgroundColor = ZXPalette(ZXPalAccent);
        underline.alpha = 0.6f;
        [nameContainer addSubview:underline];

        UITextField *field = [[UITextField alloc] init];
        field.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        field.textColor = ZXPalette(ZXPalText);
        field.tintColor = ZXPalette(ZXPalAccent);
        // 无边框纯文字：编辑态看起来和标题文字一样，只是可改
        field.backgroundColor = [UIColor clearColor];
        field.placeholder = _subTitle;
        field.returnKeyType = UIReturnKeyDone;
        field.delegate = self;
        field.inputAccessoryView = ZXFieldKeyboardAccessory(field, @"步骤名");
        field.hidden = YES;
        [nameContainer addSubview:field];
        _subTitleField = field;

        // 点击 label → 进入编辑（用 target/action，不用 initWithAction: 因旧 SDK 不支持）
        [nameLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                                action:@selector(handleSubTitleTap:)]];

        __weak UILabel *weakLabel = nameLabel;
        __weak UIView *weakUnder = underline;

        // 输入时实时写回步骤名
        [field addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
            FlowWindow *s = weakSelf;
            UITextField *f = s->_subTitleField;
            if (!s || !f) return;
            NSString *trimmed = [f.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trimmed.length > 0) s->_subStep[@"Name"] = trimmed;
            else [s->_subStep removeObjectForKey:@"Name"];
            [s autosave];
        }] forControlEvents:UIControlEventEditingChanged];

        // 编辑结束 → 切回 label 显示
        [field addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
            FlowWindow *s = weakSelf;
            UITextField *f = s->_subTitleField;
            UILabel *l = weakLabel;
            UIView *u = weakUnder;
            if (!s || !f || !l) return;
            NSString *name = [s->_subStep[@"Name"] isKindOfClass:[NSString class]] ? s->_subStep[@"Name"] : @"";
            l.attributedText = fwStepNameWithPencil(name.length ? name : s->_subTitle);
            l.hidden = NO; u.hidden = NO; f.hidden = YES;
            [s refreshKeepingScroll];
        }] forControlEvents:UIControlEventEditingDidEnd];

        // 初始文字
        NSString *initName = [_subStep[@"Name"] isKindOfClass:[NSString class]] ? _subStep[@"Name"] : @"";
        nameLabel.attributedText = fwStepNameWithPencil(initName.length ? initName : _subTitle);
    } else {
        UILabel *label = [[UILabel alloc] init];
        label.text = _subTitle;
        label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        label.textColor = ZXPalette(ZXPalText);
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.8;
        [titleBar addSubview:label];
        _subTitleLabel = label;
    }

    if (_subExec) {
        UIButton *execBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        execBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        execBtn.titleLabel.adjustsFontSizeToFitWidth = YES;
        execBtn.titleLabel.minimumScaleFactor = 0.7;
        execBtn.backgroundColor = [ZXPalette(ZXPalAccent) colorWithAlphaComponent:0.16];
        execBtn.layer.cornerRadius = 14;
        execBtn.layer.borderWidth = 1;
        execBtn.layer.borderColor = [ZXPalette(ZXPalAccent) colorWithAlphaComponent:0.55].CGColor;
        [execBtn setTitle:@"执行此步骤" forState:UIControlStateNormal];
        [execBtn setTitleColor:ZXPalette(ZXPalAccent) forState:UIControlStateNormal];
        [execBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
            FlowWindow *s = weakSelf;
            if (s && s->_subExec) s->_subExec();
        }] forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:execBtn];
        _subExecBtn = execBtn;
    }

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    close.backgroundColor = ZXPalette(ZXPalField);
    close.layer.cornerRadius = 14;
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:ZXPalette(ZXPalSub) forState:UIControlStateNormal];
    [close addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        [self dismissSubAnimated:YES];
    }] forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:close];
    _subCloseBtn = close;

    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(0, FW_SUB_TITLE_H - 1, cardW, 1)];
    sep.backgroundColor = ZXPalette(ZXPalLine);
    sep.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [card addSubview:sep];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    [card addSubview:scroll];

    _subDim = dim;
    _subCard = card;
    _subTitleBar = titleBar;
    _subScroll = scroll;

    // 把手压在滚动区之上（后加的在上面），拖它改宽高
    UIImageView *grip = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.left.and.arrow.down.right"]];
    grip.tintColor = ZXPalette(ZXPalSub);
    grip.contentMode = UIViewContentModeScaleAspectFit;
    grip.userInteractionEnabled = YES;
    [grip addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                     action:@selector(handleSubResizePan:)]];
    [card addSubview:grip];
    _subGrip = grip;

    CGFloat contentH = _subBuilder(scroll, cardW - 16.0f);
    CGFloat naturalH = FW_SUB_TITLE_H + MAX(contentH + 4.0f, 60.0f);
    CGFloat cardH = (remembered.height > 0) ? remembered.height : MIN(naturalH, hostH - 140.0f);
    cardH = MIN(MAX(cardH, FW_SUB_TITLE_H + 80.0f), maxCardH);
    CGPoint origin;
    if (fwSubPosLoad(&origin)) {
        origin.x = MIN(MAX(origin.x, 0.0f), MAX(hostW - cardW, 0.0f));
        origin.y = MIN(MAX(origin.y, 0.0f), MAX(hostH - cardH, 0.0f));
    } else {
        origin = CGPointMake((hostW - cardW) / 2.0f, (hostH - cardH) / 2.0f);
    }
    card.frame = CGRectMake(origin.x, origin.y, cardW, cardH);
    scroll.contentSize = CGSizeMake(cardW, contentH + 4.0f);
    [self layoutSubCard];

    [host addSubview:dim];
    if (!animated) return;
    // 子浮窗与主面板一套动画：主面板 X 轴翻转，子浮窗 Y 轴翻转
    dim.alpha = 0;
    card.layer.transform = CATransform3DMakeRotation(M_PI_2, 0.0, 1.0, 0.0);
    card.alpha = 0.0f;
    [UIView animateWithDuration:0.26 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        dim.alpha = 1;
        card.layer.transform = CATransform3DIdentity;
        card.alpha = 1.0f;
    } completion:nil];
}

// 子浮窗遮罩：点子浮窗区域外只收子浮窗，主面板保留
- (void)handleSubBackdropTap:(UITapGestureRecognizer *)g
{
    [self dismissSubAnimated:YES];
}

// 卡片宽高变了之后，把贴边的东西重新摆一遍
- (void)layoutSubCard
{
    UIView *card = _subCard;
    if (!card) return;
    CGFloat w = card.bounds.size.width;
    CGFloat h = card.bounds.size.height;
    CGFloat titleH = FW_SUB_TITLE_H;

    CGFloat execW = _subExecBtn ? FW_SUB_EXEC_W : 0.0f;
    CGFloat closeX = w - 40.0f;
    CGFloat titleW = MAX(closeX - 6.0f - execW - 14.0f, 60.0f);

    _subTitleBar.frame = CGRectMake(0, 0, w, titleH);
    // 步骤名容器：label（带下划线）和 textField（编辑时）都在里面
    CGRect nameFrame = CGRectMake(14, 0, titleW, titleH);
    if (_subStep) {
        _subTitleLabel.superview.frame = nameFrame;
        _subTitleLabel.frame = CGRectMake(0, 0, titleW, titleH);
        // 下划线贴着文字：宽度和文字一样长，紧跟文字底部
        UIView *under = _subTitleLabel.superview.subviews.count > 1 ? _subTitleLabel.superview.subviews[1] : nil;
        if (under) {
            CGFloat textW = titleW;
            NSString *t = _subTitleLabel.text;
            if (t.length > 0) {
                CGSize sz = [t sizeWithAttributes:@{NSFontAttributeName: _subTitleLabel.font}];
                textW = MIN(sz.width, titleW);
            }
            CGFloat lineY = (titleH + _subTitleLabel.font.lineHeight) / 2.0f + 1.0f;
            under.frame = CGRectMake(0, lineY, textW, 1.0f);
        }
        _subTitleField.frame = CGRectMake(0, (titleH - 30.0f) / 2.0f, titleW, 30.0f);
    } else {
        _subTitleLabel.frame = nameFrame;
    }
    _subCloseBtn.frame = CGRectMake(closeX, (titleH - 28.0f) / 2.0f, 28, 28);
    if (_subExecBtn) _subExecBtn.frame = CGRectMake(closeX - 6.0f - execW, (titleH - 28.0f) / 2.0f, execW, 28);
    _subScroll.frame = CGRectMake(0, titleH, w, MAX(h - titleH, 0));
    _subGrip.frame = CGRectMake(w - 8.0f - FW_SUB_GRIP, h - 8.0f - FW_SUB_GRIP, FW_SUB_GRIP, FW_SUB_GRIP);
}

// 拖右下角把手：改子浮窗宽高，松手落盘（所有脚本共用一套）
- (void)handleSubResizePan:(UIPanGestureRecognizer *)g {
    UIView *card = _subCard;
    UIView *host = card.superview;
    if (!card || !host) return;
    CGPoint t = [g translationInView:host];
    [g setTranslation:CGPointZero inView:host];

    if (g.state == UIGestureRecognizerStateBegan) {
        _subResizeW = card.bounds.size.width;
        _subResizeH = card.bounds.size.height;
    }
    CGFloat maxW = host.bounds.size.width - 24.0f;
    CGFloat maxH = MAX(host.bounds.size.height - 60.0f, FW_SUB_TITLE_H + FW_SUB_MIN_H);
    _subResizeW = MIN(MAX(_subResizeW + t.x, FW_SUB_MIN_W), maxW);
    _subResizeH = MIN(MAX(_subResizeH + t.y, FW_SUB_TITLE_H + FW_SUB_MIN_H), maxH);

    // 卡片在屏幕中间，缩放时保持左上角不动最直观
    CGRect f = card.frame;
    card.frame = CGRectMake(f.origin.x, f.origin.y, _subResizeW, _subResizeH);
    [self layoutSubCard];

    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        fwSubSizeSave(_subResizeW, _subResizeH);
        fwSubPosSave(card.frame.origin);
        [self rebuildSubAnimated:NO];   // 按新宽度把内容重排一遍（不重播入场动画）
    }
}

// 键盘弹出：先滚子浮窗内容区（只滚到当前输入框露出为止），还挡着才把卡片上移
- (void)handleSubKeyboardFrame:(NSNotification *)note {
    UIView *card = _subCard;
    if (!card) return;
    [self restoreSubCardAfterKeyboard];   // 先回原位再算，免得连续调整越叠越多
    UIView *responder = ZXFirstResponderView(card);
    if (!responder || !note) return;
    // 直接用本次通知里的键盘目标 frame（屏幕坐标），换进 card 所在窗口坐标系
    CGRect kbScreen = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    UIWindow *win = card.window;
    CGRect kbInWin = win ? [win convertRect:kbScreen fromWindow:nil] : kbScreen;
    CGFloat keyboardTop = CGRectGetMinY(kbInWin);
    CGFloat overlap = ZXScrollResponderIntoView(responder, _subScroll, keyboardTop);
    if (overlap <= 0) return;
    CGFloat shift = MIN(overlap, MAX(card.frame.origin.y - 8.0f, 0.0f));
    if (shift <= 0) return;
    NSTimeInterval duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:duration delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        CGRect frame = card.frame;
        frame.origin.y -= shift;
        card.frame = frame;
    } completion:nil];
    _kbShift = shift;
}

// 键盘收起：把上移过的子浮窗放回去（立即，供重新计算时连调）
- (void)restoreSubCardAfterKeyboard {
    if (_kbShift <= 0 || !_subCard) return;
    CGRect frame = _subCard.frame;
    frame.origin.y += _kbShift;
    _subCard.frame = frame;
    _kbShift = 0;
}

// 键盘收起通知：跟着键盘的动画一起滑回去
- (void)animateSubCardBackWithNotification:(NSNotification *)note {
    if (_kbShift <= 0 || !_subCard) return;
    NSTimeInterval duration = note ? [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue] : 0.25;
    CGFloat shift = _kbShift;
    UIView *card = _subCard;
    _kbShift = 0;
    [UIView animateWithDuration:duration delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        CGRect frame = card.frame;
        frame.origin.y += shift;
        card.frame = frame;
    } completion:nil];
}

// 点击步骤名 label → 切到输入框编辑
- (void)handleSubTitleTap:(UITapGestureRecognizer *)g {
    UITextField *f = _subTitleField;
    UILabel *l = _subTitleLabel;
    if (!f || !l) return;
    UIView *under = l.superview.subviews.count > 1 ? l.superview.subviews[1] : nil;
    NSString *name = [_subStep[@"Name"] isKindOfClass:[NSString class]] ? _subStep[@"Name"] : @"";
    f.text = name.length ? name : _subTitle;
    l.hidden = YES; under.hidden = YES; f.hidden = NO;
    [f becomeFirstResponder];
}

// 拖标题栏移动子浮窗；松手夹回屏幕内
- (void)handleSubTitlePan:(UIPanGestureRecognizer *)g {
    UIView *card = g.view.superview;
    UIView *host = card.superview;
    if (!card || !host) return;
    CGPoint t = [g translationInView:host];
    [g setTranslation:CGPointZero inView:host];
    CGPoint c = card.center;
    c.x += t.x;
    c.y += t.y;
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        CGRect b = host.bounds;
        c.x = MAX(card.bounds.size.width / 2.0f,  MIN(b.size.width  - card.bounds.size.width  / 2.0f, c.x));
        c.y = MAX(card.bounds.size.height / 2.0f, MIN(b.size.height - card.bounds.size.height / 2.0f, c.y));
        fwSubPosSave(CGPointMake(c.x - card.bounds.size.width / 2.0f, c.y - card.bounds.size.height / 2.0f));
        [UIView animateWithDuration:0.16 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            card.center = c;
        } completion:nil];
    } else {
        card.center = c;
    }
}

- (void)dismissSubAnimated:(BOOL)animated {
    UIView *dim = _subDim;
    UIView *card = _subCard;
    _subCard = nil;
    _subTitleBar = nil;
    _subTitleLabel = nil;
    _subTitleField = nil;
    _subStep = nil;
    _subExecBtn = nil;
    _subCloseBtn = nil;
    _subGrip = nil;
    _subScroll = nil;
    _subTitle = nil;
    _subBuilder = nil;
    _subExec = nil;
    _kbShift = 0;
    if (!dim) return;
    [dim endEditing:YES];
    if (!animated) {
        _subDim = nil;
        @try { [dim removeFromSuperview]; } @catch (NSException *e) {}
        return;
    }
    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        dim.alpha = 0;
        card.layer.transform = CATransform3DMakeRotation(M_PI_2, 0.0, 1.0, 0.0);
        card.alpha = 0.0f;
    } completion:^(BOOL finished) {
        @try { [dim removeFromSuperview]; } @catch (NSException *e) {}
        FlowWindow *s = weakSelf;
        if (s && s->_subDim == dim) s->_subDim = nil;
    }];
}

- (BOOL)isSubShown {
    return _subDim != nil;
}

- (CGRect)subCardScreenRect {
    if (!_subCard) return CGRectNull;
    return [_subCard convertRect:_subCard.bounds toCoordinateSpace:[UIScreen mainScreen].coordinateSpace];
}

- (void)dismissSubOverlay {
    if (!_subDim) return;
    [self dismissSubAnimated:YES];
}

// 面板整体收起（点 ✕ / 隐藏）时把子浮窗一起收掉，否则它会飘在游戏上
- (void)hideOverlays {
    [self dismissSubAnimated:NO];
}

// 子浮窗里铺一行的帮手：x=8，往下排
- (CGFloat)subAddRow:(UIView *)row y:(CGFloat)y {
    row.frame = CGRectMake(8, y, row.frame.size.width, row.frame.size.height);
    [_subScroll addSubview:row];
    return y + row.frame.size.height + FW_GAP;
}

- (CGFloat)subAddSection:(NSString *)text width:(CGFloat)w y:(CGFloat)y {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12, y, w - 8, 18)];
    label.text = text;
    label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    label.textColor = ZXPalette(ZXPalSub);
    [_subScroll addSubview:label];
    return y + 24;
}

#pragma mark - 子浮窗：交流与免责声明

static NSString * const kFwQQGroup     = @"558715113";
static NSString * const kFwBilibiliURL = @"https://space.bilibili.com/1036605484";

static NSString *fwDisclaimerText(void)
{
    return @"本软件（小新Lap）全功能免费，禁止倒卖、转售或二次打包收费；"
            "仅可用于学习交流与自动化测试，禁止用于任何违法违规用途，"
            "请勿在游戏、金融等对公平性或安全性有要求的场景中违规使用。"
            "使用本软件产生的一切后果由使用者自行承担，开发者不承担任何责任。"
            "请自觉遵守当地法律法规，如不同意本声明请立即停止使用并卸载本软件。";
}

static NSString *fwNoticeText(void)
{
    return @"本软件（小新Lap）基于开源项目 ZXTouch 二次修改，仅供学习与交流使用，"
            "代码与功能均已按需调整，此处仅声明来源。";
}

static NSString *fwAppVersion(void)
{
    static NSString *cached = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *paths = @[ @"/var/jb/Applications/zxtouch.app/Info.plist",
                                        @"/Applications/zxtouch.app/Info.plist" ];
        for (NSString *path in paths) {
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:path];
            NSString *version = info[@"CFBundleShortVersionString"];
            if ([version isKindOfClass:[NSString class]] && version.length > 0) {
                cached = version;
                break;
            }
        }
    });
    return cached ?: @"";
}

static NSArray<NSString *> *fwVersionURLs(void)
{
    return @[ @"https://api.github.com/repos/xiaoxing12138/zxtouch-rootless/releases/latest",
              @"https://cdn.jsdelivr.net/gh/xiaoxing12138/zxtouch-rootless@main/version.json",
              @"https://raw.githubusercontent.com/xiaoxing12138/zxtouch-rootless/main/version.json" ];
}

static NSString *fwCleanVersion(NSString *raw)
{
    NSMutableString *result = [NSMutableString string];
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if ((c >= '0' && c <= '9') || c == '.') [result appendFormat:@"%C", c];
    }
    return result;
}

static BOOL fwVersionIsNewer(NSString *remote, NSString *current)
{
    NSArray<NSString *> *a = [fwCleanVersion(remote) componentsSeparatedByString:@"."];
    NSArray<NSString *> *b = [fwCleanVersion(current) componentsSeparatedByString:@"."];
    NSUInteger n = MAX(a.count, b.count);
    for (NSUInteger i = 0; i < n; i++) {
        NSInteger x = (i < a.count) ? a[i].integerValue : 0;
        NSInteger y = (i < b.count) ? b[i].integerValue : 0;
        if (x != y) return x > y;
    }
    return NO;
}

static void fwFetchLatestVersion(NSUInteger index, void (^completion)(NSString *version))
{
    NSArray<NSString *> *urls = fwVersionURLs();
    if (index >= urls.count) {
        completion(nil);
        return;
    }
    NSURL *url = [NSURL URLWithString:urls[index]];
    if (!url) {
        fwFetchLatestVersion(index + 1, completion);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 10;
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [request setValue:@"xiaoxinlap" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *version = nil;
        if (data.length > 0) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) {
                id value = json[@"version"];
                if ([value isKindOfClass:[NSString class]]) version = value;
                if (version.length == 0) {
                    id tag = json[@"tag_name"];
                    if ([tag isKindOfClass:[NSString class]]) {
                        version = tag;
                        if ([version hasPrefix:@"v"] || [version hasPrefix:@"V"]) {
                            version = [version substringFromIndex:1];
                        }
                    }
                }
            }
        }
        if (version.length == 0) {
            fwFetchLatestVersion(index + 1, completion);
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(version); });
        }
    }];
    [task resume];
}

#define FW_ABOUT_VERSION_TAG 99817

- (UILabel *)subAddPlainLabel:(NSString *)text font:(UIFont *)font color:(UIColor *)color
                        width:(CGFloat)w tag:(NSInteger)tag
{
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, w - 16, 18)];
    label.text = text;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = 1;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.7;
    label.tag = tag;
    return label;
}

- (void)fwRefreshAboutVersion
{
    UILabel *label = (UILabel *)[self->_subScroll viewWithTag:FW_ABOUT_VERSION_TAG];
    if (![label isKindOfClass:[UILabel class]]) return;
    NSString *current = fwAppVersion();
    label.textColor = ZXPalette(ZXPalSub);
    label.text = @"最新版本：检测中…";

    __weak typeof(self) weakSelf = self;
    fwFetchLatestVersion(0, ^(NSString *version) {
        FlowWindow *strongSelf = weakSelf;
        if (!strongSelf) return;
        UILabel *l = (UILabel *)[strongSelf->_subScroll viewWithTag:FW_ABOUT_VERSION_TAG];
        if (![l isKindOfClass:[UILabel class]]) return;
        if (version.length == 0) {
            l.text = @"最新版本：获取失败（请检查网络后重试）";
            l.textColor = ZXPalette(ZXPalDanger);
            return;
        }
        if (current.length > 0 && fwVersionIsNewer(version, current)) {
            l.text = [NSString stringWithFormat:@"最新版本：v%@（有新版本，请加 QQ 群获取）", version];
            l.textColor = ZXPalette(ZXPalDanger);
        } else {
            l.text = [NSString stringWithFormat:@"最新版本：v%@（已是最新）", version];
        }
    });
}

- (void)showAboutSheet
{
    NSString *current = fwAppVersion();
    __weak typeof(self) weakSelf = self;
    [self showSubWithTitle:@"交流与免责声明" builder:^CGFloat(UIScrollView *content, CGFloat w) {
        FlowWindow *strongSelf = weakSelf;
        if (!strongSelf) return 0.0f;
        CGFloat y = 8.0f;

        y = [strongSelf subAddSection:@"版本" width:w y:y];

        UILabel *cur = [strongSelf subAddPlainLabel:[NSString stringWithFormat:@"当前版本：v%@", current.length ? current : @"未知"]
                                               font:[UIFont systemFontOfSize:12]
                                              color:ZXPalette(ZXPalSub) width:w tag:0];
        y = [strongSelf subAddRow:cur y:y];

        // 版本行：左侧「最新版本：…」（两行自适应），右侧常显的「检测更新」按钮
        const CGFloat versionRowH = 40.0f;
        const CGFloat versionBtnW = 82.0f;
        UIView *versionRow = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w - 16, versionRowH)];

        UILabel *latest = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, MAX(versionRow.frame.size.width - versionBtnW - 8, 60), versionRowH)];
        latest.text = @"最新版本：检测中…";
        latest.font = [UIFont systemFontOfSize:12];
        latest.textColor = ZXPalette(ZXPalSub);
        latest.numberOfLines = 2;
        latest.adjustsFontSizeToFitWidth = YES;
        latest.minimumScaleFactor = 0.7;
        latest.tag = FW_ABOUT_VERSION_TAG;
        [versionRow addSubview:latest];

        UIButton *versionBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        versionBtn.frame = CGRectMake(versionRow.frame.size.width - versionBtnW, (versionRowH - 28) / 2.0f, versionBtnW, 28);
        versionBtn.backgroundColor = [ZXPalette(ZXPalAccent) colorWithAlphaComponent:0.16];
        versionBtn.layer.cornerRadius = 8;
        versionBtn.layer.borderWidth = 1;
        versionBtn.layer.borderColor = [ZXPalette(ZXPalAccent) colorWithAlphaComponent:0.55].CGColor;
        versionBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        [versionBtn setTitle:@"检测更新" forState:UIControlStateNormal];
        [versionBtn setTitleColor:ZXPalette(ZXPalAccent) forState:UIControlStateNormal];
        __weak typeof(strongSelf) weakVersion = strongSelf;
        [versionBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
            [weakVersion fwRefreshAboutVersion];
        }] forControlEvents:UIControlEventTouchUpInside];
        [versionRow addSubview:versionBtn];
        y = [strongSelf subAddRow:versionRow y:y];
        [strongSelf fwRefreshAboutVersion];

        y = [strongSelf subAddSection:@"交流" width:w y:y];
        UIView *qq = [strongSelf makeActionRow:@"QQ 交流群"
                                        detail:kFwQQGroup
                                         color:ZXPalette(ZXPalAccent) primary:NO width:w
                                        action:^{
            [UIPasteboard generalPasteboard].string = kFwQQGroup;
            showAlertBox(@"QQ 交流群", [NSString stringWithFormat:@"群号 %@ 已复制到剪贴板。", kFwQQGroup], 2);
        }];
        y = [strongSelf subAddRow:qq y:y];

        UIView *bili = [strongSelf makeActionRow:@"bilibili：小新Lap"
                                          detail:@"点击打开主页"
                                           color:ZXPalette(ZXPalAccent) primary:NO width:w
                                          action:^{
            NSURL *url = [NSURL URLWithString:kFwBilibiliURL];
            if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }];
        y = [strongSelf subAddRow:bili y:y];

        y = [strongSelf subAddSection:@"开源声明" width:w y:y];
        UILabel *notice = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, w - 16, 10)];
        notice.text = fwNoticeText();
        notice.font = [UIFont systemFontOfSize:12];
        notice.textColor = ZXPalette(ZXPalSub);
        notice.numberOfLines = 0;
        CGRect noticeRect = [notice.text boundingRectWithSize:CGSizeMake(w - 16, CGFLOAT_MAX)
                                                     options:NSStringDrawingUsesLineFragmentOrigin
                                                  attributes:@{ NSFontAttributeName: notice.font } context:nil];
        notice.frame = CGRectMake(0, 0, w - 16, ceil(noticeRect.size.height) + 4);
        y = [strongSelf subAddRow:notice y:y];

        y = [strongSelf subAddSection:@"免责声明" width:w y:y];
        UILabel *text = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, w - 16, 10)];
        text.text = fwDisclaimerText();
        text.font = [UIFont systemFontOfSize:12];
        text.textColor = ZXPalette(ZXPalSub);
        text.numberOfLines = 0;
        CGRect rect = [text.text boundingRectWithSize:CGSizeMake(w - 16, CGFLOAT_MAX)
                                              options:NSStringDrawingUsesLineFragmentOrigin
                                           attributes:@{ NSFontAttributeName: text.font } context:nil];
        text.frame = CGRectMake(0, 0, w - 16, ceil(rect.size.height) + 4);
        y = [strongSelf subAddRow:text y:y];
        return y;
    }];
}

#pragma mark - 子浮窗：添加步骤

- (void)showAddSheet {
    NSMutableArray *targetSteps = [self currentSteps];
    if (!targetSteps) return;
    NSArray<FlowStepType *> *all = [FlowScript allStepTypes];
    if (all.count == 0) return;

    // 按分类分组，分类顺序固定；没归类的兜底放进「其他」
    NSMutableArray<NSDictionary *> *groups = [NSMutableArray array];
    NSMutableArray<FlowStepType *> *rest = [NSMutableArray array];
    for (NSString *category in [FlowScript categoryTitles]) {
        NSMutableArray<FlowStepType *> *list = [NSMutableArray array];
        for (FlowStepType *type in all) {
            if ([type.category isEqualToString:category]) [list addObject:type];
        }
        if (list.count > 0) [groups addObject:@{ @"title": category, @"types": list }];
    }
    for (FlowStepType *type in all) {
        if (![[FlowScript categoryTitles] containsObject:type.category]) [rest addObject:type];
    }
    if (rest.count > 0) [groups addObject:@{ @"title": @"其他", @"types": rest }];

    __weak typeof(self) weakSelf = self;
    [self showSubWithTitle:@"添加步骤" builder:^CGFloat(UIScrollView *content, CGFloat w) {
        const CGFloat cellGap = 6.0f;
        const CGFloat maxCellW = 124.0f;
        const CGFloat minCellW = 72.0f;
        const CGFloat innerW = MAX(w - 16.0f, 60.0f);

        // 列数：先按「每个按钮不超过最大宽度」定下限，再按「不小于最小宽度」封顶
        NSInteger byMax = (NSInteger)ceil((innerW + cellGap) / (maxCellW + cellGap));
        NSInteger byMin = (NSInteger)floor((innerW + cellGap) / (minCellW + cellGap));
        NSInteger cols = MIN(MAX(byMax, 1), MAX(byMin, 1));
        cols = MIN(cols, 6);
        CGFloat cellW = floor((innerW - (cols - 1) * cellGap) / cols);

        CGFloat y = 8.0f;
        for (NSDictionary *group in groups) {
            UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12, y, w - 8, 18)];
            label.text = group[@"title"];
            label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
            label.textColor = ZXPalette(ZXPalSub);
            [content addSubview:label];
            y += 20.0f;

            NSArray<FlowStepType *> *types = group[@"types"];
            for (NSUInteger i = 0; i < types.count; i++) {
                FlowStepType *type = types[i];
                NSInteger col = (NSInteger)(i % (NSUInteger)cols);
                NSInteger line = (NSInteger)(i / (NSUInteger)cols);
                UIButton *cell = [UIButton buttonWithType:UIButtonTypeSystem];
                cell.frame = CGRectMake(8 + col * (cellW + cellGap), y + line * (FW_CELL_H + cellGap),
                                        cellW, FW_CELL_H);
                cell.backgroundColor = ZXPalette(ZXPalRow);
                cell.layer.cornerRadius = 10;
                cell.layer.borderWidth = 1;
                cell.layer.borderColor = ZXPalette(ZXPalLine).CGColor;

                UIColor *color = fwTypeColor(type.kind);
                UIView *tile = [[UIView alloc] initWithFrame:CGRectMake(9, (FW_CELL_H - 22) / 2.0f, 22, 22)];
                tile.backgroundColor = [color colorWithAlphaComponent:0.16];
                tile.layer.cornerRadius = 7;
                tile.userInteractionEnabled = NO;
                [cell addSubview:tile];

                UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:type.symbolName]];
                icon.tintColor = color;
                icon.contentMode = UIViewContentModeScaleAspectFit;
                icon.frame = CGRectInset(tile.bounds, 4, 4);
                [tile addSubview:icon];

                UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(37, 0, MAX(cellW - 43, 24), FW_CELL_H)];
                name.text = type.title;
                name.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
                name.textColor = ZXPalette(ZXPalText);
                name.adjustsFontSizeToFitWidth = YES;
                name.minimumScaleFactor = 0.8;
                name.userInteractionEnabled = NO;
                [cell addSubview:name];

                NSString *kind = type.kind;
                [cell addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
                    FlowWindow *strongSelf = weakSelf;
                    if (!strongSelf) return;
                    [strongSelf dismissSubAnimated:NO];
                    [strongSelf addStepOfKind:kind toSteps:targetSteps];
                }] forControlEvents:UIControlEventTouchUpInside];
                [content addSubview:cell];
            }
            NSInteger lines = (NSInteger)ceil((double)types.count / (double)cols);
            y += lines * FW_CELL_H + (lines - 1) * cellGap + 8.0f;
        }
        return y;
    }];
}

#pragma mark - 子浮窗：某一步的参数

- (void)showParamsSubForStep:(NSMutableDictionary *)step parentSteps:(NSMutableArray *)parentSteps {
    FlowStepType *type = [FlowScript typeForKind:step[@"Kind"]];
    if (!type) return;

    (void)parentSteps;   // 删掉「删除这一步」之后这个参数只剩签名在用，保留是为了调用方不改
    __weak typeof(self) weakSelf = self;
    void (^execBlock)(void) = ^{
        FlowWindow *s = weakSelf;
        if (s) [s runStepNow:step];
    };
    [self showSubWithTitle:type.title ?: @"步骤" step:step exec:execBlock
                   builder:^CGFloat(UIScrollView *content, CGFloat w) {
        FlowWindow *strongSelf = weakSelf;
        if (!strongSelf) return 0.0f;
        CGFloat y = 8.0f;

        if (type.hint.length > 0) {
            UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, w - 16, 10)];
            hint.text = type.hint;
            hint.font = [UIFont systemFontOfSize:12];
            hint.textColor = ZXPalette(ZXPalSub);
            hint.numberOfLines = 0;
            CGRect hrect = [hint.text boundingRectWithSize:CGSizeMake(w - 16, CGFLOAT_MAX)
                                                  options:NSStringDrawingUsesLineFragmentOrigin
                                               attributes:@{ NSFontAttributeName: hint.font } context:nil];
            hint.frame = CGRectMake(0, 0, w - 16, ceil(hrect.size.height) + 4);
            y = [strongSelf subAddRow:hint y:y];
            y += 2;
        }

        // 识别范围：全屏 / 自定义区域。放在取点行上面，全屏时区域取点行收起来
        NSString *areaKey = nil;
        BOOL areaFull = NO;
        if (FlowStepSupportsArea(step)) {
            areaKey = [type.kind isEqualToString:kFlowImage] ? @"Mode" : @"AreaMode";
            areaFull = [FlowAreaModeForStep(step) isEqualToString:@"full"];
            y += 2;
            UIView *areaRow = [strongSelf makeChoiceRow:@"识别范围"
                                                 titles:@[ @"全屏", @"自定义区域" ]
                                               selected:(areaFull ? 0 : 1) width:w
                                               onChange:^(NSInteger idx) {
                step[areaKey] = idx == 1 ? @"area" : @"full";
                [weakSelf autosave];
                [weakSelf rebuildSubAnimated:NO];
                [weakSelf refreshKeepingScroll];
            }];
            y = [strongSelf subAddRow:areaRow y:y];
            y += 2;
        }

        if (type.pickMode != FlowPickModeNone && !(areaFull && type.pickMode == FlowPickModeRect)) {
            UIView *pick = [strongSelf makePickRowForStep:step mode:type.pickMode targets:type.pickTargets
                                                    title:type.pickActionTitle width:w
                                                   action:^{ [strongSelf beginPickingForStep:step type:type]; }];
            if (type.pickMode == FlowPickModePoint || type.pickMode == FlowPickModeColor) {
                strongSelf->_pickDragStep = step;
                strongSelf->_pickDragType = type;
                UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:strongSelf
                                                                                     action:@selector(handlePickRowPan:)];
                [pick addGestureRecognizer:pan];
                [content.panGestureRecognizer requireGestureRecognizerToFail:pan];
            }
            y = [strongSelf subAddRow:pick y:y];
        }

        if (type.pickMode2 != FlowPickModeNone) {
            BOOL showAlt = YES;
            if (type.pick2GateKey.length > 0) {
                id gate = step[type.pick2GateKey];
                showAlt = [gate isKindOfClass:[NSString class]] && [gate isEqualToString:type.pick2GateValue];
            }
            if (showAlt) {
                y += 2;
                UIView *alt = [strongSelf makePickRowForStep:step mode:type.pickMode2 targets:type.pickTargets2
                                                       title:type.pickActionTitle2 width:w
                                                      action:^{
                    [strongSelf beginPickingForStep:step mode:type.pickMode2 targets:type.pickTargets2];
                }];
                y = [strongSelf subAddRow:alt y:y];
            }
        }

        NSArray<NSDictionary<NSString *, id> *> *groups = fwGroupsForKind(step[@"Kind"]);
        NSMutableSet<NSString *> *used = [NSMutableSet set];
        // 取点行已经承载了这些字段（坐标 / 模板名），下面不再重复铺输入框
        [used addObjectsFromArray:type.pickTargets];
        [used addObjectsFromArray:type.pickTargets2];
        // 识别范围改由上面的标签切换，不再铺旧的「搜索范围」选择行
        if (areaKey.length > 0) [used addObject:areaKey];
        for (NSDictionary<NSString *, id> *group in groups) {
            // 输入步骤：方式选「剪贴板」时不显示「自定义文字」输入框
            if ([type.kind isEqualToString:kFlowPaste] &&
                [group[@"keys"] containsObject:@"Text"] &&
                ![[FlowScript pasteModeForStep:step] isEqualToString:@"text"]) {
                [used addObjectsFromArray:group[@"keys"]];
                continue;
            }
            // 等待步骤：固定延迟只显示「等几秒」，随机延迟只显示最短 / 最长两个输入框
            if ([type.kind isEqualToString:kFlowWait]) {
                NSString *waitMode = [step[@"Mode"] isKindOfClass:[NSString class]] ? step[@"Mode"] : @"fixed";
                BOOL waitRandom = [waitMode isEqualToString:@"random"];
                if (waitRandom && [group[@"keys"] containsObject:@"Seconds"]) {
                    [used addObjectsFromArray:group[@"keys"]];
                    continue;
                }
                if (!waitRandom && [group[@"keys"] containsObject:@"SecondsMin"]) {
                    [used addObjectsFromArray:group[@"keys"]];
                    continue;
                }
            }
            NSMutableArray<FlowFieldSpec *> *specs = [NSMutableArray array];
            for (NSString *key in group[@"keys"]) {
                if ([used containsObject:key]) continue;
                FlowFieldSpec *spec = [strongSelf specForKey:key inType:type];
                if (spec) { [specs addObject:spec]; [used addObject:key]; }
            }
            if (specs.count == 0) continue;
            y += 4;
            y = [strongSelf subAddSection:group[@"title"] width:w y:y];
            for (FlowFieldSpec *spec in specs) {
                y = [strongSelf subAddRow:[strongSelf fieldRowForSpec:spec step:step width:w] y:y];
            }
        }
        // 兜底：分组表没列到的字段也要显示出来，别让参数凭空消失
        NSMutableArray<FlowFieldSpec *> *rest = [NSMutableArray array];
        for (FlowFieldSpec *spec in type.fields) {
            if (![used containsObject:spec.key]) [rest addObject:spec];
        }
        if (rest.count > 0) {
            y += 4;
            y = [strongSelf subAddSection:@"其他" width:w y:y];
            for (FlowFieldSpec *spec in rest) {
                y = [strongSelf subAddRow:[strongSelf fieldRowForSpec:spec step:step width:w] y:y];
            }
        }

        return y;
    }];
}

#pragma mark - 单步调试（子浮窗右上角「执行此步骤」）

// 取参数值：缺字段 / 空串都回落到内置默认
static double fwStepNumber(NSDictionary *step, NSString *key, double fallback)
{
    id value = step[key];
    if ([value isKindOfClass:[NSNumber class]]) return [value doubleValue];
    if ([value isKindOfClass:[NSString class]] && [value length] > 0) return [value doubleValue];
    return fallback;
}

// "FF8800" / "#ff8800" → 三个通道；解析不出来返回 NO
static BOOL fwParseHexColor(NSString *text, int *r, int *g, int *b)
{
    NSString *hex = [text ?: @"" stringByReplacingOccurrencesOfString:@"#" withString:@""];
    hex = [hex stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    hex = hex.uppercaseString;
    if (hex.length != 6) return NO;
    unsigned int value = 0;
    if (![[NSScanner scannerWithString:hex] scanHexInt:&value]) return NO;
    if (r) *r = (int)((value >> 16) & 0xFF);
    if (g) *g = (int)((value >> 8) & 0xFF);
    if (b) *b = (int)(value & 0xFF);
    return YES;
}

// 单指触摸：载荷 = 事件数(1) + 类型(1) + 手指号(2) + x*10(5) + y*10(5)，坐标是触摸指示器上的像素
static void fwSendTouch(int type, double x, double y)
{
    char payload[24];
    snprintf(payload, sizeof(payload), "1%d%02d%05d%05d", type, 1,
             (int)llround(x * 10.0), (int)llround(y * 10.0));
    performTouchFromRawData((UInt8 *)payload);
}

// 引擎的 *FromRawData 收的是 NUL 结尾的可写缓冲；NSString 的 UTF8String 生命周期不好保证，
// 统一拷进一块 NSMutableData（由 outKeepAlive 拿住，调用期间别放）
static UInt8 *fwRawBuffer(NSString *text, NSMutableData **outKeepAlive)
{
    NSData *data = [(text ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *buffer = [NSMutableData dataWithLength:data.length + 1];
    memcpy(buffer.mutableBytes, data.bytes, data.length);
    if (outKeepAlive) *outKeepAlive = buffer;
    return (UInt8 *)buffer.mutableBytes;
}

// 「执行此步骤」：按这一步当前的参数直接调引擎跑一遍，不走 Python
- (void)runStepNow:(NSMutableDictionary *)step
{
    FlowStepType *type = [FlowScript typeForKind:step[@"Kind"]];
    if (!type) return;
    [self dismissKeyboard];   // 参数可能刚改完还没收键盘
    [self autosave];
    NSDictionary *snapshot = [step copy];   // 后台只读，避免和还在编辑的输入框并发
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        FlowWindow *s = weakSelf;
        if (!s) return;
        // 单步也算「运行中」：圆点保持可见，方便随时按停止；只藏选项面板，
        // 免得注入的触摸点到面板、取色识图把面板拍进去
        ZXStepRunBegin();
        ZXSafeMainAsync(^{ [FloatingMenu refreshScriptPlayState]; });
        [[FunctionWindow shared] setExecutionMasked:YES];
        ZXStepRunWait(0.26);
        @try {
            if (ZXStepRunAborted()) return;
            if (type.isCondition) [s performCheckStep:snapshot];
            else [s performActionStep:snapshot];
        } @finally {
            [[FunctionWindow shared] setExecutionMasked:NO];
            ZXStepRunFinish();
            ZXSafeMainAsync(^{ [FloatingMenu refreshScriptPlayState]; });
        }
    });
}

- (void)performActionStep:(NSDictionary *)step
{
    NSString *kind = step[@"Kind"];

    if ([kind isEqualToString:kFlowRepeat]) {
        // 单步执行「重复」= 把里面这一组动作按次数跑完
        NSInteger times = MAX((NSInteger)llround(fwStepNumber(step, @"Times", 3)), 0);
        NSArray *children = [step[@"Steps"] isKindOfClass:[NSArray class]] ? step[@"Steps"] : @[];
        for (NSInteger round = 0; round < times; round++) {
            if (ZXStepRunAborted()) break;
            for (NSDictionary *child in children) {
                if (ZXStepRunAborted()) break;
                FlowStepType *childType = [FlowScript typeForKind:child[@"Kind"]];
                if (childType.isCondition) [self performCheckStep:child];
                else [self performActionStep:child];
            }
        }
    } else if ([kind isEqualToString:kFlowTap]) {
        double x = fwStepNumber(step, @"X", 0);
        double y = fwStepNumber(step, @"Y", 0);
        NSInteger count = MAX((NSInteger)llround(fwStepNumber(step, @"Count", 1)), 1);
        double interval = MAX(fwStepNumber(step, @"Interval", 0.02), 0.0);
        double hold = MAX(fwStepNumber(step, @"Hold", 0.02), 0.0);
        // 和生成器里的「点()」一致：按下 → 按住 → 抬起 → 停一会儿，连做 count 下
        for (NSInteger i = 0; i < count; i++) {
            if (ZXStepRunAborted()) break;
            fwSendTouch(TOUCH_DOWN, x, y);
            BOOL held = (hold <= 0) ? YES : ZXStepRunWait(hold);
            fwSendTouch(TOUCH_UP, x, y);
            if (!held) break;
            if (i < count - 1 && interval > 0 && !ZXStepRunWait(interval)) break;
        }
    } else if ([kind isEqualToString:kFlowSwipe]) {
        double x1 = fwStepNumber(step, @"X1", 0), y1 = fwStepNumber(step, @"Y1", 0);
        double x2 = fwStepNumber(step, @"X2", 0), y2 = fwStepNumber(step, @"Y2", 0);
        double duration = MAX(fwStepNumber(step, @"Duration", 0.4), 0.05);
        const int steps = 12;   // 和「滑()」一样分 12 步，免得被游戏当成点击
        double cx = x1, cy = y1;
        fwSendTouch(TOUCH_DOWN, x1, y1);
        for (int i = 1; i <= steps; i++) {
            if (!ZXStepRunWait(duration / steps)) break;
            cx = x1 + (x2 - x1) * i / steps;
            cy = y1 + (y2 - y1) * i / steps;
            fwSendTouch(TOUCH_MOVE, cx, cy);
        }
        fwSendTouch(TOUCH_UP, cx, cy);
    } else if ([kind isEqualToString:kFlowWait]) {
        NSString *waitMode = [step[@"Mode"] isKindOfClass:[NSString class]] ? step[@"Mode"] : @"fixed";
        double seconds = MAX(fwStepNumber(step, @"Seconds", 0.5), 0.0);
        if ([waitMode isEqualToString:@"random"]) {
            double low = MAX(fwStepNumber(step, @"SecondsMin", 0.5), 0.0);
            double high = MAX(fwStepNumber(step, @"SecondsMax", 1), 0.0);
            if (low > high) {
                double swap = low;
                low = high;
                high = swap;
            }
            seconds = low + (high - low) * ((double)arc4random() / (double)UINT32_MAX);
        }
        ZXStepRunWait(seconds);
    } else if ([kind isEqualToString:kFlowToast]) {
        NSString *text = [step[@"Text"] isKindOfClass:[NSString class]] ? step[@"Text"] : @"";
        double seconds = MAX(fwStepNumber(step, @"Seconds", 2), 1);
        showAlertBox(@"提示", text.length ? text : @"（没填提示文字）", (int)llround(seconds));
        return;
    } else if ([kind isEqualToString:kFlowAppSwitch]) {
        NSString *mode = [step[@"Mode"] isKindOfClass:[NSString class]] ? step[@"Mode"] : @"open";
        NSString *bundle = [step[@"Bundle"] isKindOfClass:[NSString class]] ? step[@"Bundle"] : @"";
        if (bundle.length == 0) {
            showAlertBox(@"开关app", @"还没有选择目标 App。", 2);
            return;
        }
        if ([mode isEqualToString:@"close"]) {
            NSError *error = nil;
            if (!ZXKillApp(bundle, &error)) {
                showAlertBox(@"开关app", error.localizedDescription ?: @"执行失败。", 2);
                return;
            }
        } else {
            bringAppForeground(bundle);
            ZXStepRunWait(0.4);
        }
    } else if ([kind isEqualToString:kFlowWiFi]) {
        NSString *mode = [step[@"Mode"] isKindOfClass:[NSString class]] ? step[@"Mode"] : @"on";
        NSError *error = nil;
        if (!ZXSetWiFi([mode isEqualToString:@"on"], &error)) {
            showAlertBox(@"开关WiFi", error.localizedDescription ?: @"执行失败。", 2);
            return;
        }
    } else if ([kind isEqualToString:kFlowScreenshot]) {
        NSError *error = nil;
        NSString *path = nil;
        if (!ZXSaveScreenshot(&path, &error)) {
            showAlertBox(@"截屏保存", error.localizedDescription ?: @"执行失败。", 2);
            return;
        }
    } else if ([kind isEqualToString:kFlowDingTalk]) {
        NSString *url = [step[@"URL"] isKindOfClass:[NSString class]] ? step[@"URL"] : @"";
        NSString *secret = [step[@"Secret"] isKindOfClass:[NSString class]] ? step[@"Secret"] : @"";
        NSString *text = [step[@"Text"] isKindOfClass:[NSString class]] ? step[@"Text"] : @"";
        NSError *error = nil;
        if (!ZXSendDingTalk(url, secret, text, &error)) {
            showAlertBox(@"钉钉机器人", error.localizedDescription ?: @"推送失败。", 2);
            return;
        }
    } else if ([kind isEqualToString:kFlowWeCom]) {
        NSString *url = [step[@"URL"] isKindOfClass:[NSString class]] ? step[@"URL"] : @"";
        NSString *text = [step[@"Text"] isKindOfClass:[NSString class]] ? step[@"Text"] : @"";
        NSError *error = nil;
        if (!ZXSendWeCom(url, text, &error)) {
            showAlertBox(@"企业微信机器人", error.localizedDescription ?: @"推送失败。", 2);
            return;
        }
    } else if ([kind isEqualToString:kFlowPaste]) {
        NSString *mode = [FlowScript pasteModeForStep:step];
        NSString *text = [step[@"Text"] isKindOfClass:[NSString class]] ? step[@"Text"] : @"";
        NSMutableData *keep = nil;
        NSString *payload = ([mode isEqualToString:@"text"] && text.length > 0)
                          ? [NSString stringWithFormat:@"1;;%@", text] : @"5";
        UInt8 *raw = fwRawBuffer(payload, &keep);
        NSError *error = nil;
        inputTextFromRawData(raw, &error);
        if (error) {
            showAlertBox(@"输入", error.localizedDescription ?: @"执行失败。", 2);
            return;
        }
        ZXStepRunWait(0.3);
    } else if ([kind isEqualToString:kFlowRunScript]) {
        NSString *path = [step[@"Script"] isKindOfClass:[NSString class]] ? step[@"Script"] : @"";
        if (path.length == 0) {
            showAlertBox(@"运行其他脚本", @"还没有选择要运行的脚本。", 2);
            return;
        }
        NSMutableData *keep = nil;
        UInt8 *raw = fwRawBuffer(path, &keep);
        NSError *error = nil;
        playScript(raw, &error);
        if (error) {
            showAlertBox(@"运行其他脚本", error.localizedDescription ?: @"执行失败。", 2);
            return;
        }
        ZXStepRunWait(0.3);
    } else if ([kind isEqualToString:kFlowHttp]) {
        NSString *method = [step[@"Method"] isKindOfClass:[NSString class]] ? step[@"Method"] : @"GET";
        NSString *url = [step[@"URL"] isKindOfClass:[NSString class]] ? step[@"URL"] : @"";
        NSString *headers = [step[@"Headers"] isKindOfClass:[NSString class]] ? step[@"Headers"] : @"";
        NSString *body = [step[@"Body"] isKindOfClass:[NSString class]] ? step[@"Body"] : @"";
        NSString *saveFile = [step[@"SaveFile"] isKindOfClass:[NSString class]] ? step[@"SaveFile"] : @"";
        double timeout = MAX(fwStepNumber(step, @"Timeout", 10), 1);
        NSString *text = nil;
        NSError *error = nil;
        NSInteger status = ZXHTTPRequest(method, url, headers, body, timeout, &text, &error);
        if (error) {
            showAlertBox(@"URL 请求", error.localizedDescription ?: @"请求失败。", 3);
            return;
        }
        if (saveFile.length > 0) {
            [text writeToFile:saveFile atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }
        showAlertBox(@"URL 请求", [NSString stringWithFormat:@"%@ %@\n返回 %ld", method, url, (long)status], 2);
        return;
    } else if ([kind isEqualToString:kFlowShell]) {
        NSString *command = [step[@"Command"] isKindOfClass:[NSString class]] ? step[@"Command"] : @"";
        double timeout = MAX(fwStepNumber(step, @"Timeout", 10), 1);
        NSString *output = nil;
        NSError *error = nil;
        NSInteger code = ZXRunShell(command, timeout, &output, &error);
        if (code != 0) {
            NSString *msg = error.localizedDescription;
            if (msg.length == 0) {
                msg = output.length > 0 ? output : [NSString stringWithFormat:@"退出码 %ld", (long)code];
            }
            showAlertBox(@"执行命令", msg, 3);
            return;
        }
        showAlertBox(@"执行命令", output.length > 0 ? output : @"执行完成（无输出）", 2);
        return;
    } else if ([kind isEqualToString:kFlowRing]) {
        NSString *sound = [step[@"Sound"] isKindOfClass:[NSString class]] ? step[@"Sound"] : @"";
        double seconds = MAX(fwStepNumber(step, @"Seconds", 3), 0.5);
        NSError *error = nil;
        if (!ZXPlayRingtone(sound, seconds, &error)) {
            showAlertBox(@"响铃", error.localizedDescription ?: @"执行失败。", 2);
            return;
        }
    } else if ([kind isEqualToString:kFlowVolume]) {
        NSString *mode = [step[@"Mode"] isKindOfClass:[NSString class]] ? step[@"Mode"] : @"percent";
        double percent = MAX(MIN(fwStepNumber(step, @"Percent", 50), 100), 0);
        NSError *error = nil;
        BOOL ok = NO;
        if ([mode isEqualToString:@"up"]) {
            ok = ZXSetVolume(@"deltaPercent", MAX(percent, 1), &error);
        } else if ([mode isEqualToString:@"down"]) {
            ok = ZXSetVolume(@"deltaPercent", -MAX(percent, 1), &error);
        } else {
            ok = ZXSetVolume(@"percent", percent, &error);
        }
        if (!ok) {
            showAlertBox(@"调整音量", error.localizedDescription ?: @"执行失败。", 2);
            return;
        }
    } else if ([kind isEqualToString:kFlowStopAll]) {
        NSError *error = nil;
        if (!ZXStopAllScripts(&error)) {
            showAlertBox(@"停止所有脚本", error.localizedDescription ?: @"执行失败。", 2);
            return;
        }
    } else if ([kind isEqualToString:kFlowCall]) {
        NSString *number = [step[@"Number"] isKindOfClass:[NSString class]] ? step[@"Number"] : @"";
        NSString *sim = [step[@"SIM"] isKindOfClass:[NSString class]] ? step[@"SIM"] : @"default";
        NSError *error = nil;
        if (!ZXMakeCall(number, sim, &error)) {
            showAlertBox(@"打电话", error.localizedDescription ?: @"执行失败。", 2);
            return;
        }
    } else if ([kind isEqualToString:kFlowSMS]) {
        NSString *number = [step[@"Number"] isKindOfClass:[NSString class]] ? step[@"Number"] : @"";
        NSString *text = [step[@"Text"] isKindOfClass:[NSString class]] ? step[@"Text"] : @"";
        NSString *sim = [step[@"SIM"] isKindOfClass:[NSString class]] ? step[@"SIM"] : @"default";
        NSError *error = nil;
        if (!ZXSendSMS(number, text, sim, &error)) {
            showAlertBox(@"发送短信", error.localizedDescription ?: @"执行失败。", 2);
            return;
        }
    } else if ([kind isEqualToString:kFlowWeChat]) {
        showAlertBox(@"发微信", @"该步骤暂未开放，仅作占位。", 2);
        return;
    } else {
        return;
    }

    // 触摸 / 等待没有画面反馈，弹一条短的让用户确认真的跑了
    if (ZXStepRunAborted()) return;
    showAlertBox([FlowScript typeForKind:kind].title ?: @"步骤", @"已执行", 1);
}

// 判断类步骤：跑一遍判据，把结果（成立 / 不成立 + 细节）弹出来
- (void)performCheckStep:(NSDictionary *)step
{
    NSString *kind = step[@"Kind"];
    NSString *title = [FlowScript typeForKind:kind].title ?: @"结果";
    NSString *result = nil;
    NSError *error = nil;

    if ([kind isEqualToString:kFlowColor]) {
        NSMutableData *keep = nil;
        UInt8 *raw = fwRawBuffer([NSString stringWithFormat:@"%ld;;%ld",
                                  (long)llround(fwStepNumber(step, @"X", 0)),
                                  (long)llround(fwStepNumber(step, @"Y", 0))], &keep);
        NSDictionary *rgb = getRGBFromRawData(raw, &error);
        int r = [rgb[@"red"] intValue], g = [rgb[@"green"] intValue], b = [rgb[@"blue"] intValue];
        if (r < 0 || g < 0 || b < 0) {
            result = error.localizedDescription ?: @"取色失败";
        } else {
            int tr = 0, tg = 0, tb = 0;
            int tolerance = (int)MAX(fwStepNumber(step, @"Tolerance", 10), 0);
            BOOL hasTarget = fwParseHexColor(step[@"Color"], &tr, &tg, &tb);
            // 与生成器的「是色()」同一套判据：通道差 <= 容差
            BOOL hit = hasTarget && abs(r - tr) <= tolerance && abs(g - tg) <= tolerance && abs(b - tb) <= tolerance;
            result = [NSString stringWithFormat:@"取到 #%02X%02X%02X，目标 #%@，容差 %d → %@",
                      r, g, b,
                      hasTarget ? [NSString stringWithFormat:@"%02X%02X%02X", tr, tg, tb] : @"（颜色填错了）",
                      tolerance, hit ? @"成立 ✓" : @"不成立 ✗"];
        }
    } else if ([kind isEqualToString:kFlowFindColor]) {
        NSInteger x = 0, y = 0, w = 0, h = 0;
        if (![FlowAreaModeForStep(step) isEqualToString:@"full"]) {
            NSInteger left = (NSInteger)llround(fwStepNumber(step, @"X1", 0));
            NSInteger top = (NSInteger)llround(fwStepNumber(step, @"Y1", 0));
            NSInteger right = (NSInteger)llround(fwStepNumber(step, @"X2", 0));
            NSInteger bottom = (NSInteger)llround(fwStepNumber(step, @"Y2", 0));
            x = MIN(left, right); y = MIN(top, bottom);
            w = MAX(labs(right - left), 1), h = MAX(labs(bottom - top), 1);
        }
        int tr = 0, tg = 0, tb = 0;
        int tolerance = (int)MAX(fwStepNumber(step, @"Tolerance", 10), 0);
        if (!fwParseHexColor(step[@"Color"], &tr, &tg, &tb)) {
            result = @"颜色填错了（应为 6 位十六进制，如 FF8800）";
        } else {
            NSMutableData *keep = nil;
            UInt8 *raw = fwRawBuffer([NSString stringWithFormat:@"1;;%ld;;%ld;;%ld;;%ld;;%d;;%d;;%d;;%d;;%d;;%d;;1",
                                      (long)x, (long)y, (long)w, (long)h,
                                      MAX(tr - tolerance, 0), MIN(tr + tolerance, 255),
                                      MAX(tg - tolerance, 0), MIN(tg + tolerance, 255),
                                      MAX(tb - tolerance, 0), MIN(tb + tolerance, 255)], &keep);
            NSString *answer = searchRGBFromRawData(raw, &error);
            if (error) {
                result = error.localizedDescription;
            } else {
                NSArray *hit = [answer componentsSeparatedByString:@";;"];
                if (hit.count >= 5 && [hit[0] intValue] >= 0) {
                    result = [NSString stringWithFormat:@"在 (%@, %@) 找到了颜色 → 成立 ✓", hit[0], hit[1]];
                } else {
                    result = @"区域里没找到这个颜色 → 不成立 ✗";
                }
            }
        }
    } else if ([kind isEqualToString:kFlowCountColor]) {
        NSInteger x = 0, y = 0, w = 0, h = 0;
        if (![FlowAreaModeForStep(step) isEqualToString:@"full"]) {
            NSInteger left = (NSInteger)llround(fwStepNumber(step, @"X1", 0));
            NSInteger top = (NSInteger)llround(fwStepNumber(step, @"Y1", 0));
            NSInteger right = (NSInteger)llround(fwStepNumber(step, @"X2", 0));
            NSInteger bottom = (NSInteger)llround(fwStepNumber(step, @"Y2", 0));
            x = MIN(left, right); y = MIN(top, bottom);
            w = MAX(labs(right - left), 1); h = MAX(labs(bottom - top), 1);
        }
        int tr = 0, tg = 0, tb = 0;
        int tolerance = (int)MAX(fwStepNumber(step, @"Tolerance", 10), 0);
        if (!fwParseHexColor(step[@"Color"], &tr, &tg, &tb)) {
            result = @"颜色填错了（应为 6 位十六进制，如 FF8800）";
        } else {
            NSString *mode = [step[@"Mode"] isKindOfClass:[NSString class]] ? step[@"Mode"] : @"atLeast";
            long long want = (long long)llround(fwStepNumber(step, @"Count", 0));
            NSMutableData *keep = nil;
            UInt8 *raw = fwRawBuffer([NSString stringWithFormat:@"2;;%ld;;%ld;;%ld;;%ld;;%d;;%d;;%d;;%d;;%d;;%d;;1",
                                      (long)x, (long)y, (long)w, (long)h,
                                      MAX(tr - tolerance, 0), MIN(tr + tolerance, 255),
                                      MAX(tg - tolerance, 0), MIN(tg + tolerance, 255),
                                      MAX(tb - tolerance, 0), MIN(tb + tolerance, 255)], &keep);
            NSString *answer = searchRGBFromRawData(raw, &error);
            if (error) {
                result = error.localizedDescription;
            } else {
                long long count = [answer longLongValue];
                BOOL atMost = [mode isEqualToString:@"atMost"];
                BOOL hit = atMost ? (count <= want) : (count >= want);
                result = [NSString stringWithFormat:@"区域里 #%02X%02X%02X（±%d）的像素 %lld 个，要求%@ %lld → %@",
                          tr, tg, tb, tolerance, count, atMost ? @"至多" : @"至少", want, hit ? @"成立 ✓" : @"不成立 ✗"];
            }
        }
    } else if ([kind isEqualToString:kFlowImage]) {
        NSString *name = [step[@"Template"] isKindOfClass:[NSString class]] ? step[@"Template"] : @"";
        NSString *path = [kFlowTemplateFolder stringByAppendingPathComponent:name.length ? name : @"未框选.png"];
        double threshold = fwStepNumber(step, @"Threshold", 0.8);
        NSInteger x = 0, y = 0, w = 0, h = 0;
        NSString *imageMode = [step[@"Mode"] isKindOfClass:[NSString class]] ? step[@"Mode"] : @"full";
        if ([imageMode isEqualToString:@"area"]) {
            NSInteger left = (NSInteger)llround(fwStepNumber(step, @"X1", 0));
            NSInteger top = (NSInteger)llround(fwStepNumber(step, @"Y1", 0));
            NSInteger right = (NSInteger)llround(fwStepNumber(step, @"X2", 0));
            NSInteger bottom = (NSInteger)llround(fwStepNumber(step, @"Y2", 0));
            x = MIN(left, right); y = MIN(top, bottom);
            w = labs(right - left); h = labs(bottom - top);
        }
        NSMutableData *keep = nil;
        UInt8 *raw = fwRawBuffer([NSString stringWithFormat:@"%@;;0;;%@;;0.8;;%ld;;%ld;;%ld;;%ld", path, [FlowScript textForValue:@(threshold)], (long)x, (long)y, (long)w, (long)h], &keep);
        float best = 0;
        CGRect rect = screenMatchFromRawData(raw, &error, &best);
        if (error) {
            result = error.localizedDescription;
        } else if (rect.size.width <= 0 || rect.size.height <= 0) {
            result = [NSString stringWithFormat:@"没找到模板（最高得分 %.3f，要求 %.2f）→ 不成立 ✗", best, threshold];
        } else {
            result = [NSString stringWithFormat:@"在 (%.0f, %.0f) 找到模板 %.0f×%.0f（得分 %.3f）→ 成立 ✓",
                      rect.origin.x, rect.origin.y, rect.size.width, rect.size.height, best];
        }
    } else if ([kind isEqualToString:kFlowOCR]) {
        NSInteger x = 0, y = 0, w = 0, h = 0;
        if (![FlowAreaModeForStep(step) isEqualToString:@"full"]) {
            NSInteger left = (NSInteger)llround(fwStepNumber(step, @"X1", 0));
            NSInteger top = (NSInteger)llround(fwStepNumber(step, @"Y1", 0));
            NSInteger right = (NSInteger)llround(fwStepNumber(step, @"X2", 0));
            NSInteger bottom = (NSInteger)llround(fwStepNumber(step, @"Y2", 0));
            x = MIN(left, right); y = MIN(top, bottom);
            w = MAX(labs(right - left), 1); h = MAX(labs(bottom - top), 1);
        }
        NSString *langs = [step[@"Languages"] isKindOfClass:[NSString class]] ? step[@"Languages"] : @"";
        if (langs.length == 0) langs = @"zh-Hans,en-US";
        // 引擎按 ",," 切语言列表，用户填的是逗号分隔
        NSMutableArray<NSString *> *langList = [NSMutableArray array];
        for (NSString *part in [langs componentsSeparatedByString:@","]) {
            NSString *trimmed = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (trimmed.length > 0) [langList addObject:trimmed];
        }
        NSMutableData *keep = nil;
        UInt8 *raw = fwRawBuffer([NSString stringWithFormat:@"1;;%ld,,%ld,,%ld,,%ld;;;;0;;0;;%@;;0;;",
                                  (long)x, (long)y, (long)w, (long)h,
                                  [langList componentsJoinedByString:@",,"]], &keep);
        NSString *answer = performTextRecognizerTextFromRawData(raw, &error);
        if (error) {
            result = error.localizedDescription;
        } else {
            // 引擎把每段识别结果用 ";;" 拼起来，段内是 "文字,,x,,y,,宽,,高"
            NSMutableArray<NSString *> *texts = [NSMutableArray array];
            for (NSString *item in [answer componentsSeparatedByString:@";;"]) {
                if (item.length == 0) continue;
                [texts addObject:[item componentsSeparatedByString:@",,"].firstObject ?: @""];
            }
            NSString *joined = [texts componentsJoinedByString:@" "];
            NSString *target = [step[@"Text"] isKindOfClass:[NSString class]] ? step[@"Text"] : @"";
            NSString *match = [step[@"Match"] isKindOfClass:[NSString class]] ? step[@"Match"] : @"contains";
            BOOL hit;
            if ([match isEqualToString:@"equals"]) hit = [joined isEqualToString:target];
            else if ([match isEqualToString:@"notContains"]) hit = ([joined rangeOfString:target].location == NSNotFound);
            else hit = ([joined rangeOfString:target].location != NSNotFound);
            result = [NSString stringWithFormat:@"识别到「%@」\n要比对「%@」→ %@",
                      joined.length ? joined : @"（没识别到文字）", target, hit ? @"成立 ✓" : @"不成立 ✗"];
        }
    }

    if (result.length == 0) return;
    showAlertBox(title, result, 8);
}

#pragma mark - 子浮窗：设置（运行方式 + 定时，全都改完即存）

- (void)showSettings {
    [self showSettingsKeepingY:-1];
}

- (void)refreshSettingsKeepingY:(CGFloat)keepY {
    [self showSettingsKeepingY:keepY];
}

- (void)showSettingsKeepingY:(CGFloat)keepY {
    if (_bundlePath.length == 0 || !_flow) return;
    BOOL sfKeep = (keepY >= 0);
    _subQuietRebuild = sfKeep;

    // 从 info.plist 读当前的定时设置（默认值和 App 的设置页一致）
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                          [_bundlePath stringByAppendingPathComponent:@"info.plist"]];
    NSDictionary *schedule = [info[kScheduleKey] isKindOfClass:[NSDictionary class]] ? info[kScheduleKey] : nil;

    __block NSString *startMode = [schedule[kStartMode] isEqual:kModeDaily] ? kModeDaily : kModeManual;
    __block NSString *startTime = fwNormalizeTime(schedule[kStartTime]) ?: @"09:00";
    __block NSMutableArray<NSNumber *> *weekdays = [NSMutableArray array];
    for (id value in schedule[kWeekdays]) {
        if ([value isKindOfClass:[NSNumber class]]) [weekdays addObject:value];
    }
    __block NSString *endMode = kModeManual;
    if ([schedule[kEndMode] isEqualToString:kModeDuration]) endMode = kModeDuration;
    else if ([schedule[kEndMode] isEqualToString:kModeDaily]) endMode = kModeDaily;
    __block NSInteger durationMinutes = [schedule[kDurationMinutes] integerValue] ?: 30;
    __block NSString *endTime = fwNormalizeTime(schedule[kEndTime]) ?: @"23:00";

    __weak typeof(self) weakSelf = self;
    void (^persist)(void) = ^{
        FlowWindow *strongSelf = weakSelf;
        if (!strongSelf) return;
        fwPersistSchedule(strongSelf->_bundlePath, startMode, startTime, weekdays,
                          endMode, durationMinutes, endTime);
    };

    [self showSubWithTitle:@"设置" builder:^CGFloat(UIScrollView *content, CGFloat w) {
        FlowWindow *strongSelf = weakSelf;
        if (!strongSelf) return 0.0f;
        CGFloat y = 8.0f;

        // ---- 运行方式：写 flow.plist（随流程一起生成 main.py）----
        y = [strongSelf subAddSection:@"运行方式" width:w y:y];
        UIView *loopTimes = [strongSelf makeValueRow:@"循环次数（0 = 一直循环）" value:strongSelf->_flow[@"LoopTimes"]
                                             integer:YES width:w
                                            onChange:^(NSString *text) {
                                                FlowWindow *s = weakSelf;
                                                if (!s) return;
                                                s->_flow[@"LoopTimes"] = [FlowScript valueFromText:text integer:YES];
                                                [s autosave];
                                            }];
        y = [strongSelf subAddRow:loopTimes y:y];
        UIView *loopInterval = [strongSelf makeValueRow:@"每轮之间停（秒）" value:strongSelf->_flow[@"LoopInterval"]
                                               integer:NO width:w
                                              onChange:^(NSString *text) {
                                                  FlowWindow *s = weakSelf;
                                                  if (!s) return;
                                                  s->_flow[@"LoopInterval"] = [FlowScript valueFromText:text integer:NO];
                                                  [s autosave];
                                              }];
        y = [strongSelf subAddRow:loopInterval y:y];

        // ---- 定时启动 ----
        y += 6;
        y = [strongSelf subAddSection:@"定时启动" width:w y:y];
        NSArray<NSString *> *startTitles = @[ @"手动", @"每天定时" ];
        NSArray<NSString *> *startModes = @[ kModeManual, kModeDaily ];
        for (NSInteger i = 0; i < 2; i++) {
            BOOL selected = [startMode isEqualToString:startModes[i]];
            NSString *mode = startModes[i];
            UIView *row = [strongSelf makeActionRow:startTitles[i] detail:(selected ? @"✓" : nil)
                                              color:ZXPalette(ZXPalAccent) primary:selected width:w
                                             action:^{
                                                 CGFloat keepY = strongSelf->_subScroll ? strongSelf->_subScroll.contentOffset.y : 0.0f;
                                                 startMode = mode;
                                                 persist();
                                                 [weakSelf refreshSettingsKeepingY:keepY];
                                             }];
            y = [strongSelf subAddRow:row y:y];
        }
        if ([startMode isEqualToString:kModeDaily]) {
            UIView *timeRow = [strongSelf makeValueRow:@"启动时间（如 09:30）" value:startTime integer:NO width:w
                                              onChange:^(NSString *text) {
                                                  NSString *t = fwNormalizeTime(text);
                                                  if (!t) return;   // 不合法先不写，用户还在输
                                                  startTime = t;
                                                  persist();
                                              }];
            y = [strongSelf subAddRow:timeRow y:y];

            // 周日 ~ 周七个小圆块，选中亮色；一个都不选 = 每天
            y = [strongSelf subAddSection:@"重复（都不选 = 每天）" width:w y:y];
            NSArray<NSString *> *dayTitles = @[ @"日", @"一", @"二", @"三", @"四", @"五", @"六" ];
            CGFloat chipGap = 6.0f;
            CGFloat chipW = floor((w - chipGap * 6) / 7.0f);
            UIView *chipRow = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 32)];
            for (NSInteger i = 0; i < 7; i++) {
                NSNumber *day = @(i + 1);   // 1 = 周日
                BOOL on = [weekdays containsObject:day];
                UIButton *chip = [UIButton buttonWithType:UIButtonTypeSystem];
                chip.frame = CGRectMake(i * (chipW + chipGap), 0, chipW, 32);
                chip.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
                chip.layer.cornerRadius = 16;
                chip.layer.borderWidth = 1;
                [chip setTitle:dayTitles[i] forState:UIControlStateNormal];
                void (^paint)(UIButton *, BOOL) = ^(UIButton *c, BOOL isOn) {
                    c.backgroundColor = isOn ? [ZXPalette(ZXPalAccent) colorWithAlphaComponent:0.20] : ZXPalette(ZXPalField);
                    c.layer.borderColor = (isOn ? ZXPalette(ZXPalAccent) : ZXPalette(ZXPalLine)).CGColor;
                    [c setTitleColor:(isOn ? ZXPalette(ZXPalAccent) : ZXPalette(ZXPalSub)) forState:UIControlStateNormal];
                };
                paint(chip, on);
                [chip addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
                    BOOL nowOn = ![weekdays containsObject:day];
                    if (nowOn) [weekdays addObject:day]; else [weekdays removeObject:day];
                    paint(chip, nowOn);
                    persist();
                }] forControlEvents:UIControlEventTouchUpInside];
                [chipRow addSubview:chip];
            }
            y = [strongSelf subAddRow:chipRow y:y];
        }

        // ---- 定时结束 ----
        y += 6;
        y = [strongSelf subAddSection:@"定时结束" width:w y:y];
        NSArray<NSString *> *endTitles = @[ @"手动", @"跑够时长", @"到点停" ];
        NSArray<NSString *> *endModes = @[ kModeManual, kModeDuration, kModeDaily ];
        for (NSInteger i = 0; i < 3; i++) {
            BOOL selected = [endMode isEqualToString:endModes[i]];
            NSString *mode = endModes[i];
            UIView *row = [strongSelf makeActionRow:endTitles[i] detail:(selected ? @"✓" : nil)
                                              color:ZXPalette(ZXPalAccent) primary:selected width:w
                                             action:^{
                                                 CGFloat keepY = strongSelf->_subScroll ? strongSelf->_subScroll.contentOffset.y : 0.0f;
                                                 endMode = mode;
                                                 persist();
                                                 [weakSelf refreshSettingsKeepingY:keepY];
                                             }];
            y = [strongSelf subAddRow:row y:y];
        }
        if ([endMode isEqualToString:kModeDuration]) {
            UIView *durRow = [strongSelf makeValueRow:@"跑够多少分钟" value:@(durationMinutes) integer:YES width:w
                                             onChange:^(NSString *text) {
                                                 NSInteger m = [[FlowScript valueFromText:text integer:YES] integerValue];
                                                 if (m <= 0) return;
                                                 durationMinutes = m;
                                                 persist();
                                             }];
            y = [strongSelf subAddRow:durRow y:y];
        } else if ([endMode isEqualToString:kModeDaily]) {
            UIView *endRow = [strongSelf makeValueRow:@"结束时间（如 23:00）" value:endTime integer:NO width:w
                                            onChange:^(NSString *text) {
                                                NSString *t = fwNormalizeTime(text);
                                                if (!t) return;
                                                endTime = t;
                                                persist();
                                            }];
            y = [strongSelf subAddRow:endRow y:y];
        }

        // ---- 脚本悬浮球：每个脚本一个，长按悬浮球可快速隐藏 ----
        y += 6;
        y = [strongSelf subAddSection:@"脚本悬浮球（长按悬浮球可快速隐藏）" width:w y:y];
        {
            NSString *ballPath = strongSelf->_bundlePath;
            NSDictionary *ballConfig = [ScriptFloat ballConfigForScriptPath:ballPath];
            BOOL ballOn = [ballConfig[@"enabled"] boolValue];
            BOOL ballLocked = [ballConfig[@"locked"] boolValue];
            NSInteger ballIcon = ballConfig[@"icon"] ? [ballConfig[@"icon"] integerValue] : 1;
            if (ballIcon < 1 || ballIcon > 4) ballIcon = 1;

            UIView *ballToggle = [strongSelf makeActionRow:@"启停悬浮球"
                                                    detail:(ballOn ? @"已开启" : @"未开启")
                                                     color:ZXPalette(ZXPalAccent) primary:ballOn width:w
                                                    action:^{
                CGFloat keepY = strongSelf->_subScroll ? strongSelf->_subScroll.contentOffset.y : 0.0f;
                [ScriptFloat setBallEnabled:!ballOn forScriptPath:ballPath];
                [weakSelf refreshSettingsKeepingY:keepY];
            }];
            y = [strongSelf subAddRow:ballToggle y:y];

            if (ballOn) {
                UIView *ballLock = [strongSelf makeActionRow:(ballLocked ? @"解锁位置" : @"锁定位置")
                                                      detail:(ballLocked ? @"已锁定" : @"可拖动")
                                                       color:ZXPalette(ZXPalAccent) primary:ballLocked width:w
                                                      action:^{
                    CGFloat keepY = strongSelf->_subScroll ? strongSelf->_subScroll.contentOffset.y : 0.0f;
                    [ScriptFloat setBallLocked:!ballLocked forScriptPath:ballPath];
                    [weakSelf refreshSettingsKeepingY:keepY];
                }];
                y = [strongSelf subAddRow:ballLock y:y];

                UIView *ballIconRow = [strongSelf makeChoiceRow:@"图标"
                                                         titles:@[ @"脚本首字", @"App 图标", @"自定义图片", @"纯色" ]
                                                       selected:(ballIcon - 1) width:w
                                                       onChange:^(NSInteger idx) {
                    CGFloat keepY = strongSelf->_subScroll ? strongSelf->_subScroll.contentOffset.y : 0.0f;
                    if (idx == 2) {
                        [strongSelf chooseBallImageForPath:ballPath];
                        return;
                    }
                    if (idx == 3) {
                        [strongSelf showBallColorPickerForPath:ballPath];
                        return;
                    }
                    [ScriptFloat setBallIconMode:(idx == 1 ? 2 : 1) forScriptPath:ballPath];
                    [weakSelf refreshSettingsKeepingY:keepY];
                }];
                y = [strongSelf subAddRow:ballIconRow y:y];
            }
        }

        // ---- 新建步骤默认值：改的是「以后新建的步骤」，已有步骤一律不动 ----
        y += 6;
        y = [strongSelf subAddSection:@"新建步骤默认值（只对之后新建的步骤生效）" width:w y:y];

        void (^setDefault)(NSString *, NSString *, id) = ^(NSString *kind, NSString *key, id value) {
            FlowWindow *s = weakSelf;
            if (!s) return;
            NSMutableDictionary *all = s->_flow[@"StepDefaults"];
            if (![all isKindOfClass:[NSMutableDictionary class]]) {
                all = [NSMutableDictionary dictionary];
                s->_flow[@"StepDefaults"] = all;
            }
            NSMutableDictionary *kindDefaults = all[kind];
            if (![kindDefaults isKindOfClass:[NSMutableDictionary class]]) {
                kindDefaults = [NSMutableDictionary dictionary];
                all[kind] = kindDefaults;
            }
            kindDefaults[key] = value;
            [s autosave];
        };

        for (FlowStepType *type in [FlowScript allStepTypes]) {
            NSDictionary *kindDefaults = strongSelf->_flow[@"StepDefaults"][type.kind];
            NSDictionary *savedDefaults = [kindDefaults isKindOfClass:[NSDictionary class]] ? kindDefaults : nil;
            y += 2;
            y = [strongSelf subAddSection:type.title width:w y:y];
            for (FlowFieldSpec *spec in type.fields) {
                id current = savedDefaults[spec.key] ?: [FlowScript valueFromText:spec.defaultValue integer:spec.integer];
                UIView *row = nil;
                if (spec.choiceTitles.count > 0) {
                    NSArray<NSString *> *values = (spec.choiceValues.count == spec.choiceTitles.count)
                        ? spec.choiceValues : spec.choiceTitles;
                    NSInteger selected = (NSInteger)[values indexOfObject:current];
                    if (selected == NSNotFound) selected = 0;
                    NSString *key = spec.key;
                    NSString *kind = type.kind;
                    row = [strongSelf makeChoiceRow:spec.title titles:spec.choiceTitles selected:selected width:w
                                          onChange:^(NSInteger idx) { setDefault(kind, key, values[idx]); }];
                } else {
                    NSString *key = spec.key;
                    NSString *kind = type.kind;
                    BOOL integer = spec.integer;
                    row = [strongSelf makeValueRow:spec.title value:current integer:integer stepper:spec.numeric
                                         stepValue:spec.stepperStep width:w
                                         onChange:^(NSString *text) {
                                             setDefault(kind, key, [FlowScript valueFromText:text integer:integer]);
                                         }];
                }
                y = [strongSelf subAddRow:row y:y];
            }
        }

        return y;
    }];
    _subQuietRebuild = NO;
    if (sfKeep && _subScroll) {
        CGFloat maxY = MAX(0.0f, _subScroll.contentSize.height - _subScroll.bounds.size.height);
        _subScroll.contentOffset = CGPointMake(0, MIN(MAX(keepY, 0.0f), maxY));
    }
}

#pragma mark - 悬浮球：自定义图片 / 纯色

- (UIViewController *)ballPickerHostViewController
{
    if (_ballPickHost && _ballPickWindow && !_ballPickHost.presentedViewController) return _ballPickHost;
    if (!_ballPickWindow) {
        _ballPrevKeyWindow = [UIApplication sharedApplication].keyWindow;
        UIWindowScene *scene = (UIWindowScene *)[[UIApplication sharedApplication].connectedScenes anyObject];
        _ballPickWindow = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                                : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        _ballPickWindow.windowLevel = UIWindowLevelAlert + 4;
        UIViewController *rvc = [[UIViewController alloc] init];
        rvc.view.backgroundColor = [UIColor clearColor];
        _ballPickWindow.rootViewController = rvc;
        _ballPickHost = rvc;
    }
    [_ballPickWindow makeKeyAndVisible];
    return _ballPickHost;
}

- (void)closeBallPickerWindow
{
    UIWindow *window = _ballPickWindow;
    if (!window) return;
    _ballPickPath = nil;
    // 相册 / 预览页刚 dismiss 完的那一下还在收尾，立刻把窗口藏掉会把这次转场卡死
    // （SpringBoard 主线程 watchdog 直接判无响应），延后一拍再收窗
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        FlowWindow *s = weakSelf;
        window.hidden = YES;
        if (!s || s->_ballPickWindow != window) return;
        s->_ballPickWindow = nil;
        s->_ballPickHost = nil;
        [s->_ballPrevKeyWindow makeKeyWindow];
        s->_ballPrevKeyWindow = nil;
    });
}

- (void)chooseBallImageForPath:(NSString *)ballPath
{
    if (ballPath.length == 0) return;
    UIViewController *host = [self ballPickerHostViewController];
    if (!host) return;
    _ballPickPath = [ballPath copy];
    _ballPickKeepY = _subScroll ? _subScroll.contentOffset.y : 0.0f;

    PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
    config.filter = [PHPickerFilter imagesFilter];
    config.selectionLimit = 1;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;
    [host presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results
{
    NSString *path = [_ballPickPath copy];
    _ballPickPath = nil;
    __weak typeof(self) weakSelf = self;
    // 用户在相册点取消：回调也会走到这里（results 为空），只把相册关掉就行，
    // 不要在转场过程中重建选项面板，否则 SpringBoard 主线程会被卡住
    if (path.length == 0 || results.count == 0) {
        [picker dismissViewControllerAnimated:YES completion:^{
            [weakSelf closeBallPickerWindow];
        }];
        return;
    }
    [picker dismissViewControllerAnimated:YES completion:^{
        FlowWindow *s = weakSelf;
        if (!s) return;
        NSItemProvider *provider = results.firstObject.itemProvider;
        [provider loadObjectOfClass:[UIImage class] completionHandler:^(UIImage *image, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                FlowWindow *ss = weakSelf;
                if (!ss) return;
                if (!image) {
                    [ss closeBallPickerWindow];
                    return;
                }
                [ss presentBallCropForImage:image path:path];
            });
        }];
    }];
}

- (void)presentBallCropForImage:(UIImage *)image path:(NSString *)ballPath
{
    UIViewController *host = [self ballPickerHostViewController];
    if (!host || !image) {
        [self closeBallPickerWindow];
        [self refreshSettingsKeepingY:_ballPickKeepY];
        return;
    }

    __weak typeof(self) weakSelf = self;
    ZXImageCropViewController *crop = [[ZXImageCropViewController alloc] init];
    crop.sourceImage = image;
    crop.circleMask = YES;
    crop.outputMaxSide = 512.0f;
    crop.hintText = @"双指缩放，单指拖动\n圆圈里就是悬浮球显示的部分";
    crop.onFinish = ^(UIImage *cropped) {
        dispatch_async(dispatch_get_main_queue(), ^{
            FlowWindow *s = weakSelf;
            if (!s) return;
            if (cropped) [ScriptFloat setBallImage:cropped forScriptPath:ballPath];
            [s refreshSettingsKeepingY:s->_ballPickKeepY];
            [s closeBallPickerWindow];
        });
    };
    crop.onCancel = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            FlowWindow *s = weakSelf;
            if (!s) return;
            [s closeBallPickerWindow];
        });
    };
    [host presentViewController:crop animated:YES completion:nil];
}

- (void)showBallColorPickerForPath:(NSString *)ballPath
{
    if (ballPath.length == 0) return;
    NSArray<NSString *> *colors = @[ @"E53935", @"FB8C00", @"FDD835", @"43A047",
                                     @"00ACC1", @"1E88E5", @"8E24AA", @"D81B60",
                                     @"6D4C41", @"546E7A", @"111111", @"FFFFFF" ];
    NSString *currentHex = [ScriptFloat ballConfigForScriptPath:ballPath][@"color"];
    currentHex = [currentHex uppercaseString];

    __weak typeof(self) weakSelf = self;
    [self showSubWithTitle:@"悬浮球颜色" builder:^CGFloat(UIScrollView *content, CGFloat w) {
        FlowWindow *s = weakSelf;
        if (!s) return 0.0f;

        CGFloat inner = w - 8.0f;
        CGFloat y = 8.0f;

        UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(8.0f, y, inner, 18.0f)];
        hint.text = @"点一个颜色，悬浮球就换成纯色";
        hint.font = [UIFont systemFontOfSize:11];
        hint.textColor = ZXPalette(ZXPalSub);
        [content addSubview:hint];
        y += 18.0f + FW_GAP;

        NSInteger cols = 4;
        CGFloat gap = 10.0f;
        CGFloat chip = floor((inner - gap * (cols - 1)) / cols);
        for (NSUInteger i = 0; i < colors.count; i++) {
            NSInteger col = (NSInteger)i % cols;
            NSInteger row = (NSInteger)i / cols;
            NSString *hex = colors[i];
            UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
            b.frame = CGRectMake(8.0f + col * (chip + gap), y + row * (chip + gap), chip, chip);
            b.backgroundColor = ZXColorFromHex(hex);
            b.layer.cornerRadius = chip / 2.0f;
            b.layer.borderWidth = [hex isEqualToString:currentHex] ? 3.0f : 1.0f;
            b.layer.borderColor = ([hex isEqualToString:currentHex] ? ZXPalette(ZXPalAccent)
                                                                    : ZXPalette(ZXPalLine)).CGColor;
            [b addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
                FlowWindow *ss = weakSelf;
                if (!ss) return;
                [ScriptFloat setBallColorHex:hex forScriptPath:ballPath];
                [ss dismissSubAnimated:NO];
                [ss refreshKeepingScroll];
                [ss showSettings];
            }] forControlEvents:UIControlEventTouchUpInside];
            [content addSubview:b];
        }
        y += ((colors.count + cols - 1) / cols) * (chip + gap) + 4.0f;
        return y;
    }];
}

#pragma mark - 内容刷新

- (CGFloat)addRow:(UIView *)row y:(CGFloat)y {
    row.frame = CGRectMake(4, y, row.frame.size.width, row.frame.size.height);
    [_scroll addSubview:row];
    return y + row.frame.size.height + FW_GAP;
}

- (FlowFieldSpec *)specForKey:(NSString *)key inType:(FlowStepType *)type {
    for (FlowFieldSpec *spec in type.fields) {
        if ([spec.key isEqualToString:key]) return spec;
    }
    return nil;
}

- (UIView *)fieldRowForSpec:(FlowFieldSpec *)spec step:(NSMutableDictionary *)step width:(CGFloat)w {
    NSString *key = spec.key;
    BOOL integer = spec.integer;
    __weak typeof(self) weakSelf = self;

    if ([spec.pickerKind isEqualToString:@"languages"]) {
        NSArray<NSString *> *codes = fwOCRSelectedLanguages(step[key]);
        return [self makeActionRow:spec.title
                            detail:fwOCRLanguageSummary(codes)
                             color:ZXPalette(ZXPalAccent) primary:NO
                            symbol:@"list.bullet" width:w
                            action:^{ [weakSelf showLanguagePickerForSpec:spec step:step]; }];
    }

    // 从列表里选（已安装 App / 系统铃声 / 已安装脚本）：不手打，点开列表选
    if (spec.pickerKind.length > 0) {
        NSString *current = [step[key] isKindOfClass:[NSString class]] ? step[key] : @"";
        if ([spec.pickerKind isEqualToString:@"script"]) current = current.lastPathComponent ?: @"";
        return [self makeActionRow:spec.title
                            detail:(current.length > 0 ? current : @"点这里选择")
                             color:ZXPalette(ZXPalAccent) primary:NO
                            symbol:@"list.bullet" width:w
                            action:^{ [weakSelf showPickerForSpec:spec step:step]; }];
    }

    // 分段选择型字段（判据之类）：不做输入框，点哪段就存对应的值
    if (spec.choiceTitles.count > 0) {
        NSArray<NSString *> *titles = spec.choiceTitles;
        NSArray<NSString *> *values = (spec.choiceValues.count == titles.count) ? spec.choiceValues : titles;
        NSString *current = [step[key] isKindOfClass:[NSString class]] ? step[key] : nil;
        NSInteger selected = current ? (NSInteger)[values indexOfObject:current] : 0;
        if (selected == NSNotFound) selected = 0;
        return [self makeChoiceRow:spec.title titles:titles selected:selected width:w
                          onChange:^(NSInteger idx) {
            step[key] = values[idx];
            [weakSelf autosave];
            [weakSelf rebuildSubAnimated:NO];
            [weakSelf refreshKeepingScroll];
        }];
    }

    return [self makeValueRow:spec.title value:step[key] integer:integer stepper:spec.numeric
                    stepValue:spec.stepperStep width:w
                     onChange:^(NSString *text) {
                         step[key] = [FlowScript valueFromText:text integer:integer];
                         [weakSelf autosave];   // 每敲一个字都落盘
                         [weakSelf refreshKeepingScroll];
                     }];
}

// 选择列表：App 用 bundle id 存，铃声存绝对路径；顶部带搜索，列表分「用户 / 系统」两段
- (void)showPickerForSpec:(FlowFieldSpec *)spec step:(NSMutableDictionary *)step
{
    NSString *key = spec.key;
    BOOL isApp = [spec.pickerKind isEqualToString:@"app"];
    BOOL isScript = [spec.pickerKind isEqualToString:@"script"];
    NSArray<NSDictionary *> *apps = isApp ? ZXInstalledApplications() : nil;
    NSArray<NSDictionary *> *sounds = (!isApp && !isScript) ? ZXRingtoneItems() : nil;
    NSArray<NSDictionary *> *scripts = isScript ? fwScriptItems() : nil;

    __weak typeof(self) weakSelf = self;
    NSString *title = [NSString stringWithFormat:@"选择%@", spec.title ?: @"项目"];

    __block CGFloat listTop = 0.0f;
    __block CGFloat listWidth = 0.0f;

    CGFloat (^fill)(UIView *, NSString *) = ^CGFloat(UIView *box, NSString *query) {
        for (UIView *v in [box.subviews copy]) [v removeFromSuperview];
        FlowWindow *s = weakSelf;
        if (!s) return 0.0f;

        NSString *q = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        CGFloat w = box.frame.size.width;
        __block CGFloat y = 0.0f;

        void (^section)(NSString *) = ^(NSString *text) {
            UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, y, w, 18)];
            label.text = text;
            label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
            label.textColor = ZXPalette(ZXPalSub);
            [box addSubview:label];
            y += 20.0f;
        };

        void (^addRow)(NSString *, NSString *, NSString *) = ^(NSString *label, NSString *detail, NSString *value) {
            NSString *current = [step[key] isKindOfClass:[NSString class]] ? step[key] : @"";
            BOOL on = current.length > 0 &&
                      ([value isEqualToString:current] ||
                       [value.lastPathComponent isEqualToString:current]);
            UIView *row = [s makeActionRow:label
                                    detail:detail
                                     color:on ? ZXPalette(ZXPalAccent) : ZXPalette(ZXPalText)
                                   primary:on width:w
                                    action:^{
                FlowWindow *ss = weakSelf;
                if (!ss || value.length == 0) return;
                step[key] = value;
                [ss autosave];
                [ss dismissSubAnimated:NO];
                [ss refreshKeepingScroll];
                [ss showParamsSubForStep:step parentSteps:nil];
            }];
            row.frame = CGRectMake(0, y, row.frame.size.width, row.frame.size.height);
            [box addSubview:row];
            y += row.frame.size.height + FW_GAP;
        };

        if (isApp) {
            NSMutableArray *user = [NSMutableArray array];
            NSMutableArray *system = [NSMutableArray array];
            for (NSDictionary *app in apps) {
                NSString *name = app[@"name"] ?: @"";
                NSString *bundle = app[@"bundle"] ?: @"";
                if (q.length > 0 &&
                    ![name localizedCaseInsensitiveContainsString:q] &&
                    ![bundle localizedCaseInsensitiveContainsString:q]) continue;
                [( [app[@"system"] boolValue] ? system : user ) addObject:app];
            }
            if (user.count > 0) {
                section(@"用户 App");
                for (NSDictionary *app in user) addRow(app[@"name"], app[@"bundle"], app[@"bundle"]);
            }
            if (system.count > 0) {
                section(@"系统自带 App");
                for (NSDictionary *app in system) addRow(app[@"name"], app[@"bundle"], app[@"bundle"]);
            }
            if (user.count == 0 && system.count == 0) addRow(@"没有找到 App", nil, @"");
        } else if (isScript) {
            NSMutableArray *matched = [NSMutableArray array];
            for (NSDictionary *item in scripts) {
                NSString *name = item[@"name"] ?: @"";
                if (q.length > 0 && ![name localizedCaseInsensitiveContainsString:q]) continue;
                [matched addObject:item];
            }
            if (matched.count > 0) {
                section(@"脚本");
                for (NSDictionary *item in matched) {
                    NSString *folder = item[@"folder"] ?: @"";
                    addRow(item[@"name"], folder.length ? folder : nil, item[@"path"]);
                }
            } else {
                addRow(@"没有找到脚本", nil, @"");
            }
        } else {
            NSMutableArray *user = [NSMutableArray array];
            NSMutableArray *system = [NSMutableArray array];
            for (NSDictionary *item in sounds) {
                NSString *name = item[@"name"] ?: @"";
                if (q.length > 0 && ![name localizedCaseInsensitiveContainsString:q]) continue;
                [( [item[@"user"] boolValue] ? user : system ) addObject:item];
            }
            if (user.count > 0) {
                section(@"用户铃声");
                for (NSDictionary *item in user) addRow(item[@"name"], nil, item[@"path"]);
            }
            if (system.count > 0) {
                section(@"系统铃声");
                for (NSDictionary *item in system) addRow(item[@"name"], nil, item[@"path"]);
            }
            if (user.count == 0 && system.count == 0) addRow(@"没有找到铃声", nil, @"");
        }
        return y;
    };

    [self showSubWithTitle:title builder:^CGFloat(UIScrollView *content, CGFloat w) {
        FlowWindow *strongSelf = weakSelf;
        if (!strongSelf) return 0.0f;

        CGFloat inner = w - 8.0f;
        CGFloat y = 8.0f;

        UITextField *search = [[UITextField alloc] initWithFrame:CGRectMake(8.0f, y, inner, 34.0f)];
        search.placeholder = isApp ? @"搜索 App" : (isScript ? @"搜索脚本" : @"搜索铃声");
        search.font = [UIFont systemFontOfSize:13];
        search.textColor = ZXPalette(ZXPalText);
        search.backgroundColor = ZXPalette(ZXPalField);
        search.layer.cornerRadius = 8;
        search.layer.borderWidth = 1;
        search.layer.borderColor = ZXPalette(ZXPalLine).CGColor;
        search.clearButtonMode = UITextFieldViewModeWhileEditing;
        search.returnKeyType = UIReturnKeyDone;
        search.autocorrectionType = UITextAutocorrectionTypeNo;
        search.autocapitalizationType = UITextAutocapitalizationTypeNone;
        [content addSubview:search];
        y += 34.0f + FW_GAP;

        UIView *box = [[UIView alloc] initWithFrame:CGRectMake(8.0f, y, inner, 0.0f)];
        [content addSubview:box];
        listTop = y;
        listWidth = inner;
        CGFloat boxH = fill(box, @"");
        box.frame = CGRectMake(8.0f, listTop, inner, boxH);
        y = listTop + boxH + 8.0f;

        [search addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
            FlowWindow *ss = weakSelf;
            if (!ss) return;
            CGFloat newH = fill(box, search.text ?: @"");
            box.frame = CGRectMake(8.0f, listTop, listWidth, newH);
            UIScrollView *scroll = ss->_subScroll;
            if (scroll) scroll.contentSize = CGSizeMake(scroll.contentSize.width, listTop + newH + 8.0f);
        }] forControlEvents:UIControlEventEditingChanged];

        return y;
    }];
}

- (void)showLanguagePickerForSpec:(FlowFieldSpec *)spec step:(NSMutableDictionary *)step
{
    NSString *key = spec.key;
    __weak typeof(self) weakSelf = self;

    [self showSubWithTitle:@"识别语言（可多选）" builder:^CGFloat(UIScrollView *content, CGFloat w) {
        FlowWindow *s = weakSelf;
        if (!s) return 0.0f;

        CGFloat inner = w - 8.0f;
        __block CGFloat y = 8.0f;

        UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(8.0f, y, inner, 18.0f)];
        hint.text = @"勾选后点「完成」，识别中文需要勾选简体中文";
        hint.font = [UIFont systemFontOfSize:11];
        hint.textColor = ZXPalette(ZXPalSub);
        [content addSubview:hint];
        y += 18.0f + FW_GAP;

        NSArray<NSString *> *supported = ZXSupportedOCRLanguages();
        if (supported.count == 0) {
            UILabel *empty = [[UILabel alloc] initWithFrame:CGRectMake(8.0f, y, inner, 18.0f)];
            empty.text = @"当前系统没有返回可用的识别语言";
            empty.font = [UIFont systemFontOfSize:12];
            empty.textColor = ZXPalette(ZXPalSub);
            [content addSubview:empty];
            y += 18.0f + FW_GAP;
        }

        for (NSString *code in supported) {
            BOOL on = [fwOCRSelectedLanguages(step[key]) containsObject:code];
            UIView *row = [s makeActionRow:fwOCRLanguageTitle(code)
                                    detail:code
                                     color:on ? ZXPalette(ZXPalAccent) : ZXPalette(ZXPalText)
                                   primary:on width:inner
                                    action:^{
                FlowWindow *ss = weakSelf;
                if (!ss) return;
                NSMutableArray<NSString *> *next = [fwOCRSelectedLanguages(step[key]) mutableCopy];
                if ([next containsObject:code]) [next removeObject:code];
                else [next addObject:code];
                step[key] = [next componentsJoinedByString:@","];
                [ss autosave];
                [ss rebuildSubAnimated:NO];
            }];
            row.frame = CGRectMake(8.0f, y, inner, row.frame.size.height);
            [content addSubview:row];
            y += row.frame.size.height + FW_GAP;
        }

        UIView *done = [s makeActionRow:@"完成" detail:nil
                                  color:ZXPalette(ZXPalAccent) primary:YES
                                 symbol:nil width:inner
                                 action:^{
            FlowWindow *ss = weakSelf;
            if (!ss) return;
            [ss dismissSubAnimated:NO];
            [ss refreshKeepingScroll];
            [ss showParamsSubForStep:step parentSteps:nil];
        }];
        done.frame = CGRectMake(8.0f, y + 4.0f, inner, done.frame.size.height);
        [content addSubview:done];

        return y + done.frame.size.height + 12.0f;
    }];
}

// 一行「标签 + 分段按钮」：选项不多时比输入框直观（如 包含 / 等于 / 不包含）
- (UIView *)makeChoiceRow:(NSString *)title
                   titles:(NSArray<NSString *> *)titles
                 selected:(NSInteger)selected
                    width:(CGFloat)w
                 onChange:(void (^)(NSInteger idx))onChange
{
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, FW_ROW_H - 5.0f)];
    row.backgroundColor = ZXPalette(ZXPalRow);
    row.layer.cornerRadius = 10;
    row.layer.borderWidth = 1;
    row.layer.borderColor = ZXPalette(ZXPalLine).CGColor;

    CGFloat labelW = MIN(120.0f, w * 0.34f);
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, labelW, row.frame.size.height)];
    label.text = title;
    label.font = [UIFont systemFontOfSize:14];
    label.textColor = ZXPalette(ZXPalSub);
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.75;
    [row addSubview:label];

    CGFloat x = 12 + labelW + 6;
    CGFloat avail = MAX(w - x - 12, 60);
    CGFloat gap = 6.0f;
    CGFloat count = MAX((CGFloat)titles.count, 1);
    CGFloat bw = floor((avail - gap * (count - 1)) / count);
    CGFloat bh = row.frame.size.height - 12.0f;

    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(x + i * (bw + gap), 6, bw, bh);
        b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        b.layer.cornerRadius = 8;
        b.layer.borderWidth = 1;
        b.clipsToBounds = YES;
        [b setTitle:titles[i] forState:UIControlStateNormal];
        [row addSubview:b];
        [buttons addObject:b];
    }
    void (^paint)(NSInteger) = ^(NSInteger idx) {
        for (NSInteger i = 0; i < (NSInteger)buttons.count; i++) {
            BOOL on = (i == idx);
            UIButton *b = buttons[i];
            b.backgroundColor = on ? [ZXPalette(ZXPalAccent) colorWithAlphaComponent:0.20] : ZXPalette(ZXPalField);
            b.layer.borderColor = (on ? ZXPalette(ZXPalAccent) : ZXPalette(ZXPalLine)).CGColor;
            [b setTitleColor:(on ? ZXPalette(ZXPalAccent) : ZXPalette(ZXPalSub)) forState:UIControlStateNormal];
        }
    };
    paint(selected);
    for (NSInteger i = 0; i < (NSInteger)buttons.count; i++) {
        UIButton *b = buttons[i];
        [b addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
            paint(i);
            if (onChange) onChange(i);
        }] forControlEvents:UIControlEventTouchUpInside];
    }
    return row;
}

// 一整层步骤：重复的里面、判断的成立 / 不成立都直接铺在主列表里，按层数缩进
- (CGFloat)layoutSteps:(NSMutableArray *)steps atY:(CGFloat)y x:(CGFloat)x width:(CGFloat)w depth:(NSInteger)depth
{
    if (![steps isKindOfClass:[NSMutableArray class]]) return y;
    __weak typeof(self) weakSelf = self;
    CGFloat top = y;

    if (steps.count == 0) {
        UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(x + 22.0f, y, MAX(w - 28.0f, 40.0f), 28.0f)];
        hint.text = @"空，拖步骤到这里";
        hint.font = [UIFont systemFontOfSize:11];
        hint.textColor = ZXPalette(ZXPalSub);
        [_scroll addSubview:hint];
        [_branchLabels addObject:@{ @"label": hint, @"steps": steps }];
        [self registerSpan:steps top:y bottom:y + 28.0f x:x width:w depth:depth];
        return y + 28.0f + FW_GAP;
    }

    for (NSInteger i = 0; i < (NSInteger)steps.count; i++) {
        NSMutableDictionary *step = steps[i];
        if (![step isKindOfClass:[NSMutableDictionary class]]) continue;
        FlowStepType *type = [FlowScript typeForKind:step[@"Kind"]];
        NSInteger number = _stepCursor;
        _stepCursor += 1;
        FWStepRowView *row = [self makeStepRow:[self rowTitleForStep:step]
                                     customName:[step[@"Name"] isKindOfClass:[NSString class]] ? step[@"Name"] : nil
                                         detail:[self rowDetailForStep:step]
                                          index:number
                                         symbol:type.symbolName
                                          color:fwTypeColor(type.kind)
                                      deletable:YES
                                       sortable:YES
                                          width:w
                                          onTap:^{
                                              [weakSelf showParamsSubForStep:(NSMutableDictionary *)step parentSteps:steps];
                                          }
                                       onDelete:^{
                                           [weakSelf deleteStep:(NSMutableDictionary *)step fromSteps:steps];
                                       }];
        __weak FWStepRowView *weakRow = row;
        row.onCopy = ^{ [weakSelf showCopyMenuForRow:weakRow step:(NSMutableDictionary *)step steps:steps]; };
        row.onDragBegan = ^{ [weakSelf beginDragRow:weakRow]; };
        row.onDragMoved = ^(CGFloat dy) { [weakSelf moveDragRow:weakRow dy:dy]; };
        row.onDragEnded = ^{ [weakSelf endDragRow]; };
        row.step = step;
        row.ownerSteps = steps;
        row.ownerDepth = depth;
        row.frame = CGRectMake(x, y, w, FW_ROW_H);
        [_rows addObject:row];
        [_scroll addSubview:row];

        NSString *kind = step[@"Kind"];
        CGFloat blockBottom = 0.0f;
        if ([kind isEqualToString:kFlowRepeat]) {
            [self attachRepeatTimesFieldToRow:row step:(NSMutableDictionary *)step];
            [self attachCollapseToggleToRow:row step:(NSMutableDictionary *)step];
            if (![step[@"Steps"] isKindOfClass:[NSMutableArray class]]) step[@"Steps"] = [NSMutableArray array];
            y += FW_ROW_H + FW_GAP;
            if (!fwCollapsed(step)) {
                y = [self layoutSteps:step[@"Steps"] atY:y x:x + 16.0f width:MAX(w - 16.0f, 80.0f) depth:depth + 1];
            }
            blockBottom = y - FW_GAP;
        } else if (type.isCondition) {
            [self attachElseToggleToRow:row step:(NSMutableDictionary *)step];
            if (![step[@"Then"] isKindOfClass:[NSMutableArray class]]) step[@"Then"] = [NSMutableArray array];
            if (![step[@"Else"] isKindOfClass:[NSMutableArray class]]) step[@"Else"] = [NSMutableArray array];
            if (fwCollapsed(step)) {
                y += FW_ROW_H + FW_GAP;
                blockBottom = y - FW_GAP;
            } else {
                CGFloat rowBottom = row.frame.origin.y + FW_ROW_H;
                y += FW_ROW_H + 4.0f;
                y = [self layoutBranch:@"成立" atY:y x:x width:w depth:depth steps:step[@"Then"] spanTop:rowBottom];
                blockBottom = y - FW_GAP;
                if (fwElseEnabled(step)) {
                    y = [self layoutBranch:@"不成立" atY:y x:x width:w depth:depth steps:step[@"Else"] spanTop:y - FW_GAP];
                    blockBottom = y - FW_GAP;
                } else {
                    y += FW_GAP;
                }
            }
        } else {
            y += FW_ROW_H + FW_GAP;
            blockBottom = y - FW_GAP;
        }
        row.blockBottom = blockBottom;
    }
    [self registerSpan:steps top:top bottom:MAX(y - FW_GAP, top) x:x width:w depth:depth];
    return y;
}

- (CGFloat)layoutBranch:(NSString *)text atY:(CGFloat)y x:(CGFloat)x width:(CGFloat)w
                  depth:(NSInteger)depth steps:(NSMutableArray *)steps spanTop:(CGFloat)spanTop
{
    CGFloat branchX = x + 16.0f;
    CGFloat branchW = MAX(w - 16.0f, 80.0f);
    UILabel *label = [self layoutBranchTitle:text atY:y x:x];
    [_branchLabels addObject:@{ @"label": label, @"steps": steps }];
    y += 18.0f;
    y = [self layoutSteps:steps atY:y x:branchX width:branchW depth:depth + 1];
    [self registerSpan:steps top:spanTop bottom:MAX(y - FW_GAP, spanTop)
                     x:branchX width:branchW depth:depth + 1];
    return y;
}

- (UILabel *)layoutBranchTitle:(NSString *)text atY:(CGFloat)y x:(CGFloat)x
{
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(x + 20.0f, y, 120.0f, 16.0f)];
    label.text = text;
    label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    label.textColor = ZXPalette(ZXPalSub);
    [_scroll addSubview:label];
    return label;
}

- (NSString *)rowTitleForStep:(NSDictionary *)step
{
    if ([step[@"Kind"] isEqualToString:kFlowRepeat]) return @"重复";
    return [FlowScript summaryForStep:step];
}

- (NSString *)rowDetailForStep:(NSDictionary *)step
{
    return nil;
}

// 次数输入框：标题和「输入框 + 次」放在同一条里，输入框跟着标题实际宽度往后挪
- (void)attachRepeatTimesFieldToRow:(FWStepRowView *)row step:(NSMutableDictionary *)step
{
    CGFloat limitX = row.bounds.size.width - 34.0f - 30.0f - 6.0f;
    CGFloat lineX = 79.0f;
    CGFloat lineW = MAX(limitX - lineX, 80.0f);
    CGFloat fieldW = 56.0f;
    CGFloat fieldH = 26.0f;
    CGFloat fieldY = (FW_ROW_H - fieldH) / 2.0f;
    CGFloat suffixW = 18.0f;

    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(lineX, 0, lineW, FW_ROW_H)];
    line.clipsToBounds = YES;
    [row.content addSubview:line];

    CGFloat titleW = 34.0f;
    UILabel *main = [row.content viewWithTag:101];
    if (main) {
        CGFloat natural = 34.0f;
        if (main.attributedText.length > 0) {
            natural = [main.attributedText size].width;
        } else if (main.text.length > 0) {
            natural = [main.text sizeWithAttributes:@{ NSFontAttributeName: main.font }].width;
        }
        CGFloat reserved = fieldW + 6.0f + suffixW + 8.0f;
        CGFloat available = MAX(lineW - reserved, 40.0f);
        titleW = MIN(MAX(natural + 4.0f, 34.0f), available);
        if (available < 60.0f) {
            fieldW = MAX(lineW - titleW - suffixW - 12.0f, 30.0f);
            fieldW = MIN(fieldW, 56.0f);
        }
        [main removeFromSuperview];
        main.frame = CGRectMake(0, 0, titleW, FW_ROW_H);
        [line addSubview:main];
    }

    UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(titleW + 8.0f, fieldY, fieldW, fieldH)];
    field.borderStyle = UITextBorderStyleNone;
    field.backgroundColor = ZXPalette(ZXPalField);
    field.layer.cornerRadius = 8.0f;
    field.layer.borderWidth = 1.0f;
    field.layer.borderColor = ZXPalette(ZXPalLine).CGColor;
    field.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
    field.textColor = ZXPalette(ZXPalText);
    field.keyboardType = UIKeyboardTypeNumberPad;
    field.textAlignment = NSTextAlignmentCenter;
    field.text = [FlowScript textForValue:step[@"Times"]];
    [field addTarget:self action:@selector(repeatTimesFieldChanged:) forControlEvents:UIControlEventEditingDidEnd];
    [field addTarget:self action:@selector(repeatTimesFieldChanged:) forControlEvents:UIControlEventEditingDidEndOnExit];
    objc_setAssociatedObject(field, &kFWRepeatStepKey, step, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [line addSubview:field];

    UILabel *suffix = [[UILabel alloc] initWithFrame:CGRectMake(titleW + fieldW + 14.0f, fieldY, suffixW, fieldH)];
    suffix.text = @"次";
    suffix.font = [UIFont systemFontOfSize:12];
    suffix.textColor = ZXPalette(ZXPalSub);
    [line addSubview:suffix];

    UILabel *sub = [row.content viewWithTag:102];
    if (sub) sub.hidden = YES;
}

// 判断行右侧的「不成立」开关：关掉后不成立分支的步骤连显示都不显示
- (void)attachElseToggleToRow:(FWStepRowView *)row step:(NSMutableDictionary *)step
{
    CGFloat w = row.bounds.size.width;
    CGFloat triW = 30.0f;
    CGFloat triX = w - 34.0f - triW;
    CGFloat toggleW = 62.0f;
    CGFloat toggleH = 30.0f;
    CGFloat x = triX - 6.0f - toggleW;
    BOOL on = fwElseEnabled(step);

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = CGRectMake(x, (FW_ROW_H - toggleH) / 2.0f, toggleW, toggleH);
    btn.backgroundColor = ZXPalette(ZXPalField);
    btn.layer.cornerRadius = 8.0f;
    btn.layer.borderWidth = 1.0f;
    btn.layer.borderColor = (on ? ZXPalette(ZXPalAccent) : ZXPalette(ZXPalLine)).CGColor;
    btn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    [btn setTitle:(on ? @"不成立 开" : @"不成立 关") forState:UIControlStateNormal];
    [btn setTitleColor:(on ? ZXPalette(ZXPalAccent) : ZXPalette(ZXPalSub)) forState:UIControlStateNormal];
    __weak typeof(self) weakSelf = self;
    [btn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        FlowWindow *s = weakSelf;
        if (!s) return;
        step[@"ElseEnabled"] = @(!fwElseEnabled(step));
        [s autosave];
        [s refreshKeepingScroll];
    }] forControlEvents:UIControlEventTouchUpInside];
    [row.content addSubview:btn];
    [self attachCollapseToggleToRow:row step:step];

    UILabel *main = [row.content viewWithTag:101];
    UILabel *sub = [row.content viewWithTag:102];
    CGFloat textW = MAX(x - 6.0f - 79.0f, 40.0f);
    if (main) main.frame = CGRectMake(79.0f, 0, textW, FW_ROW_H);
    if (sub) sub.hidden = YES;
}

// 能装分支的步骤（判断条件 / 重复）右侧的收起与展开
- (void)attachCollapseToggleToRow:(FWStepRowView *)row step:(NSMutableDictionary *)step
{
    CGFloat w = row.bounds.size.width;
    CGFloat triW = 30.0f;
    CGFloat triX = w - 34.0f - triW;
    BOOL collapsed = fwCollapsed(step);

    UIButton *tri = [UIButton buttonWithType:UIButtonTypeSystem];
    tri.frame = CGRectMake(triX, 0, triW, FW_ROW_H);
    tri.tintColor = ZXPalette(ZXPalSub);
    [tri setImage:[UIImage systemImageNamed:(collapsed ? @"chevron.down" : @"chevron.up")]
          forState:UIControlStateNormal];
    __weak typeof(self) weakSelf = self;
    [tri addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        FlowWindow *s = weakSelf;
        if (!s) return;
        step[@"Collapsed"] = @(!fwCollapsed(step));
        [s autosave];
        [s refreshKeepingScroll];
    }] forControlEvents:UIControlEventTouchUpInside];
    [row.content addSubview:tri];

    UILabel *main = [row.content viewWithTag:101];
    if (main && main.superview == row.content) {
        CGFloat available = triX - 6.0f - main.frame.origin.x;
        if (available > 60.0f) {
            main.frame = CGRectMake(main.frame.origin.x, main.frame.origin.y,
                                    available, main.frame.size.height);
        }
    }
}

- (void)repeatTimesFieldChanged:(UITextField *)field
{
    NSMutableDictionary *step = objc_getAssociatedObject(field, &kFWRepeatStepKey);
    if (!step) return;
    step[@"Times"] = [FlowScript valueFromText:field.text integer:YES];
    field.text = [FlowScript textForValue:step[@"Times"]];
    [self autosave];
}

- (void)refresh {
    if (!_host) return;
    UIScrollView *scroll = [_host flowHostScrollView];
    if (!scroll) return;
    _scroll = scroll;
    _pw = [_host flowHostContentWidth];

    NSMutableDictionary *page = _stack.lastObject;
    if (!page) return;
    CGFloat rowW = _pw - 8;

    [scroll endEditing:YES];
    for (UIView *v in scroll.subviews) [v removeFromSuperview];
    _rows = [NSMutableArray array];   // 每次重建都清空：换页后旧行不该再被拖动逻辑引用
    _spans = [NSMutableArray array];
    _branchLabels = [NSMutableArray array];
    _stepCursor = 0;
    _dragRow = nil;
    _dragSourceSteps = nil;
    _dragTargetSteps = nil;
    _dragTargetIndex = NSNotFound;
    _dragLine = nil;
    [_dragScrollTimer invalidate];
    _dragScrollTimer = nil;

    BOOL isRoot = [page[@"isRoot"] boolValue];
    [_host flowHostSetNavigationTitle:page[@"title"] canGoBack:!isRoot];

    BOOL animate = _animateTransition;
    _animateTransition = NO;

    CGFloat y = 8;

    NSMutableArray *steps = page[@"steps"];
    if (steps.count == 0) {
        UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(12, y, _pw - 24, 38)];
        hint.numberOfLines = 0;
        hint.font = [UIFont systemFontOfSize:12];
        hint.textColor = ZXPalette(ZXPalSub);
        hint.text = isRoot ? @"还没有步骤。点下面的「添加步骤」开始拼一条流程。"
                           : @"这一支还没有动作。";
        [_scroll addSubview:hint];
        y += 46;
    } else {
        y = [self layoutSteps:steps atY:y x:4.0f width:rowW depth:0];
    }

    UIView *add = [self makeActionRow:@"＋  添加步骤" detail:nil color:ZXPalette(ZXPalAccent) primary:YES
                                width:rowW action:^{ [self showAddSheet]; }];
    add.frame = CGRectMake(4, y, rowW, add.frame.size.height);
    [_scroll addSubview:add];
    y += add.frame.size.height + FW_GAP;

    scroll.contentSize = CGSizeMake(_pw, y + 8);
    [scroll setContentOffset:CGPointZero animated:NO];

    if (animate) {
        scroll.alpha = 0;
        scroll.transform = CGAffineTransformMakeTranslation(0, 8);
        [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            scroll.alpha = 1;
            scroll.transform = CGAffineTransformIdentity;
        } completion:nil];
    }
}

- (void)refreshKeepingScroll {
    UIScrollView *scroll = _scroll;
    CGFloat keepY = scroll ? scroll.contentOffset.y : 0.0f;
    [self refresh];
    UIScrollView *after = _scroll;
    if (!after) return;
    CGFloat maxY = MAX(0.0f, after.contentSize.height - after.bounds.size.height);
    [after setContentOffset:CGPointMake(0, MIN(MAX(keepY, 0.0f), maxY)) animated:NO];
}

@end

#pragma mark - socket 任务 44

NSString *handleFlowEditorTaskWithRawData(UInt8 *eventData, NSError **error) {
    NSString *data = eventData ? [NSString stringWithUTF8String:(const char *)eventData] : @"";
    NSArray<NSString *> *parts = [data componentsSeparatedByString:@";;"];
    // 形如 ";;open;;/var/mobile/.../脚本.bdl"：parts[0] 是空的
    NSString *action = parts.count > 1 ? parts[1] : @"";
    NSMutableArray<NSString *> *rest = [NSMutableArray array];
    for (NSUInteger i = 2; i < parts.count; i++) {
        if (parts[i].length > 0) [rest addObject:parts[i]];
    }
    NSString *path = [rest componentsJoinedByString:@";;"];

    if (path.length == 0) {
        if (error) *error = [NSError errorWithDomain:@"小新Lap" code:1
                                            userInfo:@{ NSLocalizedDescriptionKey: @"没有指定脚本路径。" }];
        return nil;
    }

    // 编辑器就在选项面板里，所以「打开可视化编辑」= 让面板切到流程编辑模式
    if ([action isEqualToString:@"new"]) {
        [[FunctionWindow shared] createFlowScriptAtPath:path];
    } else {
        [[FunctionWindow shared] openFlowBundle:path];
    }
    return @"0\r\n";
}
