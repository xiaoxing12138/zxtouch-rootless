//
//  FlowScript.xm
//  小新Lap 可视化脚本
//

#import "FlowScript.h"
#import "Screen.h"

#import <math.h>

NSString * const kFlowFileName = @"flow.plist";
NSString * const kFlowTemplateFolder = @"/var/mobile/Library/ZXTouch/tpl";

NSString * const kFlowTap = @"tap";
NSString * const kFlowSwipe = @"swipe";
NSString * const kFlowWait = @"wait";
NSString * const kFlowToast = @"toast";
NSString * const kFlowColor = @"color";
NSString * const kFlowFindColor = @"findColor";
NSString * const kFlowImage = @"image";
NSString * const kFlowOCR = @"ocr";
NSString * const kFlowOpenApp = @"openApp";
NSString * const kFlowHome = @"home";
NSString * const kFlowKillApp = @"killApp";
NSString * const kFlowPaste = @"paste";
NSString * const kFlowRing = @"ring";
NSString * const kFlowVolume = @"volume";
NSString * const kFlowStopAll = @"stopAll";
NSString * const kFlowCall = @"call";
NSString * const kFlowSMS = @"sms";
NSString * const kFlowWeChat = @"wechat";

// 分类固定顺序：触摸 → 判断条件 → 流程 → App 与输入 → 提醒
static NSString * const kCatTouch = @"触摸";
static NSString * const kCatCondition = @"判断条件";
static NSString * const kCatFlow = @"流程";
static NSString * const kCatApp = @"App 与输入";
static NSString * const kCatRemind = @"提醒";

// 点击的默认值：改这里，生成器与弹窗默认值一起跟着变
static const double kDefaultTapInterval = 0.02;
static const double kDefaultTapHold = 0.02;

// 生成脚本开头那一行标记：靠它判断 main.py 是不是我们生成的
static NSString * const kGeneratedMarker = @"# 本脚本由「小新Lap」可视化编辑器生成。";

// 「用哪张卡」的选择项：默认卡 / 卡 1 / 卡 2（打电话、发短信共用）
static FlowFieldSpec *flowSimFieldSpec(void)
{
    FlowFieldSpec *sim = [FlowFieldSpec key:@"SIM" title:@"用哪张卡" integer:NO def:@"default"];
    sim.choiceTitles = @[ @"默认卡", @"卡 1", @"卡 2" ];
    sim.choiceValues = @[ @"default", @"1", @"2" ];
    return sim;
}

// 卡号在界面上的中文名
static NSString *fwSimTitle(id value)
{
    NSString *sim = [value isKindOfClass:[NSString class]] ? value : @"default";
    if ([sim isEqualToString:@"1"]) return @"卡 1";
    if ([sim isEqualToString:@"2"]) return @"卡 2";
    return @"默认卡";
}

// 卡号落进 plist 的值
static NSString *fwSimValue(id value)
{
    NSString *sim = [value isKindOfClass:[NSString class]] ? value : @"default";
    return sim.length ? sim : @"default";
}

@implementation FlowFieldSpec
+ (instancetype)key:(NSString *)key title:(NSString *)title integer:(BOOL)integer def:(NSString *)def
{
    FlowFieldSpec *spec = [[FlowFieldSpec alloc] init];
    spec.key = key;
    spec.title = title;
    spec.integer = integer;
    spec.defaultValue = def;
    return spec;
}

+ (instancetype)numKey:(NSString *)key title:(NSString *)title integer:(BOOL)integer def:(NSString *)def
{
    FlowFieldSpec *spec = [self key:key title:title integer:integer def:def];
    spec.numeric = YES;
    return spec;
}
@end

@implementation FlowStepType
@end

@implementation FlowScript

#pragma mark - 类型元数据

+ (NSArray<FlowStepType *> *)allStepTypes
{
    static NSArray<FlowStepType *> *types = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        FlowStepType *tap = [self type:kFlowTap title:@"点击" symbol:@"hand.tap.fill" condition:NO];
        tap.category = kCatTouch;
        tap.pickActionTitle = @"从屏幕取坐标";
        tap.pickMode = FlowPickModePoint;
        tap.pickTargets = @[@"X", @"Y"];
        tap.fields = @[
            [FlowFieldSpec key:@"X" title:@"X 坐标" integer:YES def:@"400"],
            [FlowFieldSpec key:@"Y" title:@"Y 坐标" integer:YES def:@"400"],
            [FlowFieldSpec key:@"Count" title:@"连续点几下" integer:YES def:@"1"],
            [FlowFieldSpec numKey:@"Interval" title:@"每下之间停（秒）" integer:NO def:@"0.02"],
            [FlowFieldSpec numKey:@"Hold" title:@"按住多久（秒）" integer:NO def:@"0.02"],
        ];

        FlowStepType *swipe = [self type:kFlowSwipe title:@"滑动" symbol:@"hand.draw.fill" condition:NO];
        swipe.category = kCatTouch;
        swipe.pickActionTitle = @"从屏幕取起点和终点";
        swipe.pickMode = FlowPickModePath;
        swipe.pickTargets = @[@"X1", @"Y1", @"X2", @"Y2"];
        swipe.fields = @[
            [FlowFieldSpec key:@"X1" title:@"起点 X" integer:YES def:@"300"],
            [FlowFieldSpec key:@"Y1" title:@"起点 Y" integer:YES def:@"400"],
            [FlowFieldSpec key:@"X2" title:@"终点 X" integer:YES def:@"600"],
            [FlowFieldSpec key:@"Y2" title:@"终点 Y" integer:YES def:@"400"],
            [FlowFieldSpec numKey:@"Duration" title:@"划多久（秒）" integer:NO def:@"0.4"],
        ];

        FlowStepType *wait = [self type:kFlowWait title:@"等待" symbol:@"clock.fill" condition:NO];
        wait.category = kCatFlow;
        wait.fields = @[ [FlowFieldSpec numKey:@"Seconds" title:@"等几秒" integer:NO def:@"0.5"] ];

        FlowStepType *toast = [self type:kFlowToast title:@"提示" symbol:@"text.bubble.fill" condition:NO];
        toast.category = kCatFlow;
        toast.fields = @[
            [FlowFieldSpec key:@"Text" title:@"提示文字" integer:NO def:@"完成"],
            [FlowFieldSpec numKey:@"Seconds" title:@"显示几秒" integer:NO def:@"2"],
        ];

        FlowStepType *color = [self type:kFlowColor title:@"识色" symbol:@"eyedropper.halffull" condition:YES];
        color.category = kCatCondition;
        color.pickActionTitle = @"从屏幕取颜色";
        color.pickMode = FlowPickModeColor;
        color.pickTargets = @[@"X", @"Y"];
        color.fields = @[
            [FlowFieldSpec key:@"X" title:@"X 坐标" integer:YES def:@"400"],
            [FlowFieldSpec key:@"Y" title:@"Y 坐标" integer:YES def:@"400"],
            [FlowFieldSpec key:@"Color" title:@"颜色（如 FF8800）" integer:NO def:@"FFFFFF"],
            [FlowFieldSpec key:@"Tolerance" title:@"容差（0-255）" integer:YES def:@"10"],
        ];

        FlowStepType *findColor = [self type:kFlowFindColor title:@"找色" symbol:@"magnifyingglass" condition:YES];
        findColor.category = kCatCondition;
        findColor.pickActionTitle = @"从屏幕框选区域";
        findColor.pickMode = FlowPickModeRect;
        findColor.pickTargets = @[@"X1", @"Y1", @"X2", @"Y2"];
        findColor.fields = @[
            [FlowFieldSpec key:@"X1" title:@"区域左" integer:YES def:@"0"],
            [FlowFieldSpec key:@"Y1" title:@"区域上" integer:YES def:@"0"],
            [FlowFieldSpec key:@"X2" title:@"区域右" integer:YES def:@"1000"],
            [FlowFieldSpec key:@"Y2" title:@"区域下" integer:YES def:@"600"],
            [FlowFieldSpec key:@"Color" title:@"颜色（如 FF8800）" integer:NO def:@"FFFFFF"],
            [FlowFieldSpec key:@"Tolerance" title:@"容差（0-255）" integer:YES def:@"10"],
        ];

        FlowStepType *image = [self type:kFlowImage title:@"识图" symbol:@"photo.fill" condition:YES];
        image.category = kCatCondition;
        image.pickActionTitle = @"从屏幕框选模板";
        image.pickMode = FlowPickModeTemplate;
        image.pickTargets = @[@"Template"];
        image.fields = @[
            [FlowFieldSpec key:@"Template" title:@"模板图（用下面的按钮框选）" integer:NO def:@""],
            [FlowFieldSpec numKey:@"Threshold" title:@"相似度（0-1）" integer:NO def:@"0.8"],
        ];

        // 识字：把框选区域里的文字/数字识别出来，只用来判断，不改变脚本流程
        FlowStepType *ocr = [self type:kFlowOCR title:@"识字" symbol:@"text.viewfinder" condition:YES];
        ocr.category = kCatCondition;
        ocr.pickActionTitle = @"从屏幕框选识字区域";
        ocr.pickMode = FlowPickModeRect;
        ocr.pickTargets = @[@"X1", @"Y1", @"X2", @"Y2"];
        FlowFieldSpec *ocrMatch = [FlowFieldSpec key:@"Match" title:@"判据" integer:NO def:@"contains"];
        ocrMatch.choiceTitles = @[ @"包含", @"等于", @"不包含" ];
        ocrMatch.choiceValues = @[ @"contains", @"equals", @"notContains" ];
        ocr.fields = @[
            [FlowFieldSpec key:@"X1" title:@"区域左" integer:YES def:@"0"],
            [FlowFieldSpec key:@"Y1" title:@"区域上" integer:YES def:@"0"],
            [FlowFieldSpec key:@"X2" title:@"区域右" integer:YES def:@"1000"],
            [FlowFieldSpec key:@"Y2" title:@"区域下" integer:YES def:@"600"],
            ocrMatch,
            [FlowFieldSpec key:@"Text" title:@"要比对的文字或数字" integer:NO def:@""],
            [FlowFieldSpec key:@"Languages" title:@"识别语言（zh-Hans 中文 / en-US 英文）" integer:NO def:@"zh-Hans,en-US"],
        ];

        // 打开 App：Bundle 从「已安装 App 列表」里选，不手打
        FlowStepType *openApp = [self type:kFlowOpenApp title:@"打开App" symbol:@"app.badge.fill" condition:NO];
        openApp.category = kCatApp;
        FlowFieldSpec *openAppBundle = [FlowFieldSpec key:@"Bundle" title:@"目标 App" integer:NO def:@""];
        openAppBundle.pickerKind = @"app";
        openApp.fields = @[ openAppBundle ];

        // 返回主屏幕：无参数
        FlowStepType *home = [self type:kFlowHome title:@"返回主屏幕" symbol:@"house.fill" condition:NO];
        home.category = kCatApp;
        home.fields = @[];

        // 关闭 App（杀后台）
        FlowStepType *killApp = [self type:kFlowKillApp title:@"关闭App" symbol:@"xmark.app.fill" condition:NO];
        killApp.category = kCatApp;
        killApp.hint = @"「关闭App」会把该 App 的后台进程直接杀掉（等同于上滑清后台），并不是简单切走。";
        FlowFieldSpec *killAppBundle = [FlowFieldSpec key:@"Bundle" title:@"目标 App" integer:NO def:@""];
        killAppBundle.pickerKind = @"app";
        killApp.fields = @[ killAppBundle ];

        // 粘贴：填了文字就输入文字，没填就用剪贴板
        FlowStepType *paste = [self type:kFlowPaste title:@"粘贴" symbol:@"doc.on.clipboard" condition:NO];
        paste.category = kCatApp;
        paste.fields = @[
            [FlowFieldSpec key:@"Text" title:@"要输入的文字（留空 = 粘贴剪贴板）" integer:NO def:@""],
        ];

        // 响铃：系统铃声 + 持续秒数
        FlowStepType *ring = [self type:kFlowRing title:@"响铃" symbol:@"bell.fill" condition:NO];
        ring.category = kCatRemind;
        FlowFieldSpec *ringSound = [FlowFieldSpec key:@"Sound" title:@"铃声" integer:NO def:@"Alarm.m4r"];
        ringSound.pickerKind = @"ringtone";
        ring.fields = @[
            ringSound,
            [FlowFieldSpec numKey:@"Seconds" title:@"响几秒" integer:NO def:@"3"],
        ];

        // 调整设备音量：方式 + 百分比（不再用 1-16 格）
        FlowStepType *volume = [self type:kFlowVolume title:@"调整音量" symbol:@"speaker.wave.3.fill" condition:NO];
        volume.category = kCatApp;
        FlowFieldSpec *volumeMode = [FlowFieldSpec key:@"Mode" title:@"方式" integer:NO def:@"percent"];
        volumeMode.choiceTitles = @[ @"调整至目标音量", @"调高", @"调低" ];
        volumeMode.choiceValues = @[ @"percent", @"up", @"down" ];
        volume.fields = @[
            volumeMode,
            [FlowFieldSpec key:@"Percent" title:@"百分比（0-100）" integer:YES def:@"50"],
        ];

        // 停止所有脚本：给流程一个统一的终止指令
        FlowStepType *stopAll = [self type:kFlowStopAll title:@"停止所有脚本" symbol:@"stop.circle.fill" condition:NO];
        stopAll.category = kCatFlow;
        stopAll.fields = @[];

        // 打电话 / 发短信：号码 + 正文 + 用哪张卡
        FlowStepType *call = [self type:kFlowCall title:@"打电话" symbol:@"phone.fill" condition:NO];
        call.category = kCatRemind;
        call.fields = @[
            [FlowFieldSpec key:@"Number" title:@"号码" integer:NO def:@""],
            flowSimFieldSpec(),
        ];

        FlowStepType *sms = [self type:kFlowSMS title:@"发短信" symbol:@"message.fill" condition:NO];
        sms.category = kCatRemind;
        sms.fields = @[
            [FlowFieldSpec key:@"Number" title:@"号码" integer:NO def:@""],
            [FlowFieldSpec key:@"Text" title:@"短信内容" integer:NO def:@""],
            flowSimFieldSpec(),
        ];

        // 发微信：占位步骤，暂不执行，先放在这里
        FlowStepType *wechat = [self type:kFlowWeChat title:@"发微信" symbol:@"bubble.left.and.bubble.right.fill" condition:NO];
        wechat.category = kCatRemind;
        wechat.hint = @"「发微信」目前是占位步骤，放进流程里不会真正发送，后续版本再接。";
        wechat.fields = @[];

        types = @[tap, swipe, wait, toast, color, findColor, image, ocr,
                  stopAll, openApp, home, killApp, paste, volume,
                  ring, call, sms, wechat];
    });
    return types;
}

+ (NSArray<NSString *> *)categoryTitles
{
    return @[ kCatTouch, kCatCondition, kCatFlow, kCatApp, kCatRemind ];
}

+ (FlowStepType *)type:(NSString *)kind title:(NSString *)title symbol:(NSString *)symbol condition:(BOOL)condition
{
    FlowStepType *type = [[FlowStepType alloc] init];
    type.kind = kind;
    type.title = title;
    type.symbolName = symbol;
    type.isCondition = condition;
    type.category = @"";
    type.hint = @"";
    type.pickActionTitle = @"";
    type.pickMode = FlowPickModeNone;
    type.pickTargets = @[];
    type.fields = @[];
    return type;
}

+ (NSArray<FlowStepType *> *)simpleStepTypes
{
    NSMutableArray *result = [NSMutableArray array];
    for (FlowStepType *type in [self allStepTypes]) {
        if (!type.isCondition) [result addObject:type];
    }
    return result;
}

+ (FlowStepType *)typeForKind:(NSString *)kind
{
    for (FlowStepType *type in [self allStepTypes]) {
        if ([type.kind isEqualToString:kind]) return type;
    }
    return nil;
}

+ (NSMutableDictionary *)newStepOfKind:(NSString *)kind
{
    FlowStepType *type = [self typeForKind:kind];
    if (!type) return nil;

    NSMutableDictionary *step = [NSMutableDictionary dictionary];
    step[@"Kind"] = kind;
    for (FlowFieldSpec *spec in type.fields) {
        step[spec.key] = [self valueFromText:spec.defaultValue integer:spec.integer];
    }
    if (type.isCondition) {
        step[@"Then"] = [NSMutableArray array];
        step[@"Else"] = [NSMutableArray array];
    }
    return step;
}

/// 弹窗里拿到的是字符串，落盘前按类型转成数字，免得生成代码时出现 "400" 这样的字符串
+ (id)valueFromText:(NSString *)text integer:(BOOL)integer
{
    NSString *trimmed = [(text ?: @"") stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (integer) return @((NSInteger)llround(trimmed.doubleValue));
    if (trimmed.length == 0) return @"";
    // 纯数字（含小数点、负号）转成数字，其他（颜色、文字、模板名）保持字符串
    static NSCharacterSet *nonNumeric = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        nonNumeric = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789.-"] invertedSet];
    });
    if (trimmed.length == 0) return @"";
    if ([trimmed rangeOfCharacterFromSet:nonNumeric].location != NSNotFound) return trimmed;
    return @(trimmed.doubleValue);
}

#pragma mark - 列表文案

+ (NSString *)textForValue:(id)value
{
    if ([value isKindOfClass:[NSNumber class]]) {
        double d = [value doubleValue];
        if (d == floor(d) && fabs(d) < 1e15) return [NSString stringWithFormat:@"%.0f", d];
        return [NSString stringWithFormat:@"%g", d];
    }
    return [NSString stringWithFormat:@"%@", value ?: @""];
}

+ (NSString *)summaryForStep:(NSDictionary *)step
{
    NSString *kind = step[@"Kind"];
    if ([kind isEqualToString:kFlowTap]) {
        return [NSString stringWithFormat:@"点击 (%@, %@) 共 %@ 下",
                [self textForValue:step[@"X"]], [self textForValue:step[@"Y"]], [self textForValue:step[@"Count"]]];
    }
    if ([kind isEqualToString:kFlowSwipe]) {
        return [NSString stringWithFormat:@"滑动 (%@, %@) → (%@, %@)",
                [self textForValue:step[@"X1"]], [self textForValue:step[@"Y1"]],
                [self textForValue:step[@"X2"]], [self textForValue:step[@"Y2"]]];
    }
    if ([kind isEqualToString:kFlowWait]) {
        return [NSString stringWithFormat:@"等待 %@ 秒", [self textForValue:step[@"Seconds"]]];
    }
    if ([kind isEqualToString:kFlowToast]) {
        return [NSString stringWithFormat:@"提示「%@」", step[@"Text"] ?: @""];
    }
    if ([kind isEqualToString:kFlowColor]) {
        return [NSString stringWithFormat:@"如果 (%@, %@) 是 #%@（±%@）",
                [self textForValue:step[@"X"]], [self textForValue:step[@"Y"]],
                step[@"Color"] ?: @"", [self textForValue:step[@"Tolerance"]]];
    }
    if ([kind isEqualToString:kFlowFindColor]) {
        return [NSString stringWithFormat:@"如果 (%@,%@)-(%@,%@) 里有 #%@（±%@）",
                [self textForValue:step[@"X1"]], [self textForValue:step[@"Y1"]],
                [self textForValue:step[@"X2"]], [self textForValue:step[@"Y2"]],
                step[@"Color"] ?: @"", [self textForValue:step[@"Tolerance"]]];
    }
    if ([kind isEqualToString:kFlowImage]) {
        NSString *name = [step[@"Template"] isKindOfClass:[NSString class]] ? step[@"Template"] : @"";
        return [NSString stringWithFormat:@"如果画面里有模板「%@」（≥%@）",
                name.length ? name : @"未框选", [self textForValue:step[@"Threshold"]]];
    }
    if ([kind isEqualToString:kFlowOCR]) {
        NSString *text = [step[@"Text"] isKindOfClass:[NSString class]] ? step[@"Text"] : @"";
        NSString *match = [step[@"Match"] isKindOfClass:[NSString class]] ? step[@"Match"] : @"contains";
        NSString *word = [match isEqualToString:@"equals"] ? @"等于"
                       : ([match isEqualToString:@"notContains"] ? @"不含" : @"包含");
        return [NSString stringWithFormat:@"如果 (%@,%@)-(%@,%@) 的文字%@「%@」",
                [self textForValue:step[@"X1"]], [self textForValue:step[@"Y1"]],
                [self textForValue:step[@"X2"]], [self textForValue:step[@"Y2"]],
                word, text.length ? text : @"（没填）"];
    }
    if ([kind isEqualToString:kFlowOpenApp]) {
        NSString *bundle = [step[@"Bundle"] isKindOfClass:[NSString class]] ? step[@"Bundle"] : @"";
        return [NSString stringWithFormat:@"打开 App %@", bundle.length ? bundle : @"（未选择）"];
    }
    if ([kind isEqualToString:kFlowHome]) {
        return @"返回主屏幕";
    }
    if ([kind isEqualToString:kFlowKillApp]) {
        NSString *bundle = [step[@"Bundle"] isKindOfClass:[NSString class]] ? step[@"Bundle"] : @"";
        return [NSString stringWithFormat:@"关闭 App %@（会杀死进程）", bundle.length ? bundle : @"（未选择）"];
    }
    if ([kind isEqualToString:kFlowPaste]) {
        NSString *text = [step[@"Text"] isKindOfClass:[NSString class]] ? step[@"Text"] : @"";
        return text.length ? [NSString stringWithFormat:@"输入「%@」", text] : @"粘贴剪贴板";
    }
    if ([kind isEqualToString:kFlowRing]) {
        NSString *sound = [step[@"Sound"] isKindOfClass:[NSString class]] ? step[@"Sound"] : @"";
        return [NSString stringWithFormat:@"响铃「%@」%@ 秒", sound.length ? sound : @"（未选择）", [self textForValue:step[@"Seconds"]]];
    }
    if ([kind isEqualToString:kFlowVolume]) {
        NSString *mode = [step[@"Mode"] isKindOfClass:[NSString class]] ? step[@"Mode"] : @"percent";
        if ([mode isEqualToString:@"up"]) {
            return [NSString stringWithFormat:@"音量调高 %@%%", [self textForValue:step[@"Percent"]]];
        }
        if ([mode isEqualToString:@"down"]) {
            return [NSString stringWithFormat:@"音量调低 %@%%", [self textForValue:step[@"Percent"]]];
        }
        return [NSString stringWithFormat:@"音量调整至 %@%%", [self textForValue:step[@"Percent"]]];
    }
    if ([kind isEqualToString:kFlowStopAll]) {
        return @"停止所有脚本";
    }
    if ([kind isEqualToString:kFlowCall]) {
        NSString *number = [step[@"Number"] isKindOfClass:[NSString class]] ? step[@"Number"] : @"";
        return [NSString stringWithFormat:@"打电话给 %@（%@）", number.length ? number : @"（没填号码）",
                fwSimTitle(step[@"SIM"])];
    }
    if ([kind isEqualToString:kFlowSMS]) {
        NSString *number = [step[@"Number"] isKindOfClass:[NSString class]] ? step[@"Number"] : @"";
        NSString *text = [step[@"Text"] isKindOfClass:[NSString class]] ? step[@"Text"] : @"";
        return [NSString stringWithFormat:@"发短信给 %@（%@）「%@」", number.length ? number : @"（没填号码）",
                fwSimTitle(step[@"SIM"]), text.length ? text : @"（空）"];
    }
    if ([kind isEqualToString:kFlowWeChat]) {
        return @"发微信（占位，暂不执行）";
    }
    return @"未知步骤";
}

+ (NSString *)detailForStep:(NSDictionary *)step
{
    FlowStepType *type = [self typeForKind:step[@"Kind"]];
    if (!type.isCondition) return nil;

    NSArray *then = [step[@"Then"] isKindOfClass:[NSArray class]] ? step[@"Then"] : @[];
    NSArray *otherwise = [step[@"Else"] isKindOfClass:[NSArray class]] ? step[@"Else"] : @[];
    return [NSString stringWithFormat:@"成立时 %lu 个动作 · 不成立时 %lu 个动作（点这一行编辑）",
            (unsigned long)then.count, (unsigned long)otherwise.count];
}

#pragma mark - 流程读写

+ (NSMutableDictionary *)emptyFlow
{
    return [@{ @"Version": @1,
               @"LoopTimes": @0,
               @"LoopInterval": @0.2,
               @"Steps": [NSMutableArray array] } mutableCopy];
}

+ (BOOL)bundleHasFlow:(NSString *)bundlePath
{
    return [[NSFileManager defaultManager] fileExistsAtPath:[bundlePath stringByAppendingPathComponent:kFlowFileName]];
}

+ (BOOL)bundleHasGeneratedScript:(NSString *)bundlePath
{
    NSString *path = [bundlePath stringByAppendingPathComponent:@"main.py"];
    NSString *source = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (source.length == 0) return NO;
    return [source containsString:kGeneratedMarker];
}

+ (BOOL)createVisualScriptAtPath:(NSString *)bundlePath error:(NSError **)error
{
    NSFileManager *manager = [NSFileManager defaultManager];
    if (![manager createDirectoryAtPath:bundlePath withIntermediateDirectories:YES attributes:nil error:error]) return NO;

    NSMutableDictionary *flow = [self emptyFlow];
    if (![self saveFlow:flow toBundle:bundlePath error:error]) return NO;

    NSDictionary *info = @{ @"Entry": @"main.py", @"FrontApp": @"", @"Orientation": @"1" };
    if (![info writeToFile:[bundlePath stringByAppendingPathComponent:@"info.plist"] atomically:YES]) {
        if (error) *error = [self error:@"无法写入 info.plist。"];
        return NO;
    }
    return [self writeGeneratedScriptForFlow:flow toBundle:bundlePath error:error];
}

#pragma mark - 录制转可视化

+ (NSMutableDictionary *)recordedWaitStep:(double)seconds
{
    NSMutableDictionary *step = [self newStepOfKind:kFlowWait];
    step[@"Seconds"] = @(round(seconds * 100.0) / 100.0);
    return step;
}

+ (void)appendRecordedGestureTo:(NSMutableArray *)steps
                           from:(CGPoint)start
                             to:(CGPoint)end
                    maxDistance:(double)maxDistance
                       duration:(double)duration
{
    if (maxDistance <= 12.0) {
        NSMutableDictionary *step = [self newStepOfKind:kFlowTap];
        step[@"X"] = @((NSInteger)llround(start.x));
        step[@"Y"] = @((NSInteger)llround(start.y));
        [steps addObject:step];
        return;
    }
    NSMutableDictionary *step = [self newStepOfKind:kFlowSwipe];
    step[@"X1"] = @((NSInteger)llround(start.x));
    step[@"Y1"] = @((NSInteger)llround(start.y));
    step[@"X2"] = @((NSInteger)llround(end.x));
    step[@"Y2"] = @((NSInteger)llround(end.y));
    step[@"Duration"] = @(round(MAX(duration, 0.1) * 100.0) / 100.0);
    [steps addObject:step];
}

+ (NSMutableDictionary *)flowFromRecordingRawText:(NSString *)rawText
{
    NSMutableArray *steps = [NSMutableArray array];

    double pending = 0.0;
    double clock = 0.0;
    BOOL active = NO;
    double downTime = 0.0;
    CGPoint startPoint = CGPointZero;
    CGPoint lastPoint = CGPointZero;
    double maxDistance = 0.0;

    NSArray<NSString *> *lines = [rawText componentsSeparatedByString:@"\n"];
    for (NSString *raw in lines) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (line.length < 3) continue;

        if ([line hasPrefix:@"18"]) {
            pending = [[line substringFromIndex:2] doubleValue] / 1000000.0;
            if (pending < 0) pending = 0.0;
            continue;
        }
        if (![line hasPrefix:@"10"]) continue;

        NSString *payload = [line substringFromIndex:2];
        if (payload.length < 14) continue;
        int touchType = [[payload substringWithRange:NSMakeRange(1, 1)] intValue];
        CGFloat x = [[payload substringWithRange:NSMakeRange(4, 5)] doubleValue] / 10.0;
        CGFloat y = [[payload substringWithRange:NSMakeRange(9, 5)] doubleValue] / 10.0;
        CGPoint indicatorPoint = ZXIndicatorPointFromFramePoint(CGPointMake(x, y));
        x = indicatorPoint.x;
        y = indicatorPoint.y;

        double gap = pending;
        clock += pending;
        pending = 0.0;

        if (touchType == 1) {
            if (active) {
                [self appendRecordedGestureTo:steps from:startPoint to:lastPoint
                                  maxDistance:maxDistance duration:(clock - downTime)];
            } else if (steps.count > 0 && gap >= 0.1) {
                [steps addObject:[self recordedWaitStep:gap]];
            }
            active = YES;
            downTime = clock;
            startPoint = CGPointMake(x, y);
            lastPoint = startPoint;
            maxDistance = 0.0;
        } else if (touchType == 2) {
            if (!active) {
                active = YES;
                downTime = clock;
                startPoint = CGPointMake(x, y);
                maxDistance = 0.0;
            }
            lastPoint = CGPointMake(x, y);
            maxDistance = MAX(maxDistance, hypot(lastPoint.x - startPoint.x, lastPoint.y - startPoint.y));
        } else if (touchType == 0) {
            if (!active) continue;
            lastPoint = CGPointMake(x, y);
            maxDistance = MAX(maxDistance, hypot(lastPoint.x - startPoint.x, lastPoint.y - startPoint.y));
            [self appendRecordedGestureTo:steps from:startPoint to:lastPoint
                              maxDistance:maxDistance duration:(clock - downTime)];
            active = NO;
        }
    }

    if (active) {
        [self appendRecordedGestureTo:steps from:startPoint to:lastPoint
                          maxDistance:maxDistance duration:(clock - downTime)];
    }

    NSMutableDictionary *flow = [self emptyFlow];
    flow[@"Steps"] = steps;
    return flow;
}

+ (BOOL)convertRecordingBundleToFlow:(NSString *)bundlePath error:(NSError **)error
{
    NSFileManager *manager = [NSFileManager defaultManager];
    if (![manager fileExistsAtPath:bundlePath]) {
        if (error) *error = [self error:@"脚本目录不存在。"];
        return NO;
    }

    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                          [bundlePath stringByAppendingPathComponent:@"info.plist"]];
    NSString *entry = [info[@"Entry"] isKindOfClass:[NSString class]] ? info[@"Entry"] : nil;
    NSString *rawPath = entry.length ? [bundlePath stringByAppendingPathComponent:entry] : nil;
    if (rawPath == nil || ![manager fileExistsAtPath:rawPath]) {
        rawPath = nil;
        for (NSString *name in [manager contentsOfDirectoryAtPath:bundlePath error:nil]) {
            if ([[name pathExtension].lowercaseString isEqualToString:@"raw"]) {
                rawPath = [bundlePath stringByAppendingPathComponent:name];
                break;
            }
        }
    }
    if (rawPath == nil) {
        if (error) *error = [self error:@"找不到录制文件。"];
        return NO;
    }

    NSString *rawText = [NSString stringWithContentsOfFile:rawPath encoding:NSUTF8StringEncoding error:NULL];
    if (rawText.length == 0) {
        if (error) *error = [self error:@"录制文件是空的。"];
        return NO;
    }

    NSMutableDictionary *flow = [self flowFromRecordingRawText:rawText];
    if (![self saveFlow:flow toBundle:bundlePath error:error]) return NO;
    return [self writeGeneratedScriptForFlow:flow toBundle:bundlePath error:error];
}

+ (NSMutableDictionary *)loadFlowFromBundle:(NSString *)bundlePath
{
    NSString *path = [bundlePath stringByAppendingPathComponent:kFlowFileName];
    NSDictionary *flow = [NSDictionary dictionaryWithContentsOfFile:path];
    NSMutableDictionary *result = [self emptyFlow];
    if (![flow isKindOfClass:[NSDictionary class]]) return result;

    if (flow[@"LoopTimes"] != nil) result[@"LoopTimes"] = flow[@"LoopTimes"];
    if (flow[@"LoopInterval"] != nil) result[@"LoopInterval"] = flow[@"LoopInterval"];
    if ([flow[@"Steps"] isKindOfClass:[NSArray class]]) {
        NSMutableArray *steps = [NSMutableArray array];
        for (NSDictionary *step in flow[@"Steps"]) {
            if ([step isKindOfClass:[NSDictionary class]]) [steps addObject:[self mutableStepFromStep:step]];
        }
        result[@"Steps"] = steps;
    }
    return result;
}

/*
 plist 里读出来的数组是不可变的，而编辑器要往「成立时 / 不成立时」里增删动作。
 所以整棵树都要转成可变的，否则点一下「添加」就崩。
*/
+ (NSMutableDictionary *)mutableStepFromStep:(NSDictionary *)step
{
    NSMutableDictionary *result = [step mutableCopy];
    for (NSString *key in @[@"Then", @"Else"]) {
        NSArray *children = step[key];
        if (![children isKindOfClass:[NSArray class]]) continue;
        NSMutableArray *list = [NSMutableArray array];
        for (NSDictionary *child in children) {
            if ([child isKindOfClass:[NSDictionary class]]) [list addObject:[self mutableStepFromStep:child]];
        }
        result[key] = list;
    }
    return result;
}

+ (BOOL)saveFlow:(NSDictionary *)flow toBundle:(NSString *)bundlePath error:(NSError **)error
{
    NSFileManager *manager = [NSFileManager defaultManager];
    if (![manager fileExistsAtPath:bundlePath]) {
        if (error) *error = [self error:@"脚本目录不存在。"];
        return NO;
    }
    NSString *path = [bundlePath stringByAppendingPathComponent:kFlowFileName];
    if (![flow writeToFile:path atomically:YES]) {
        if (error) *error = [self error:@"无法写入 flow.plist。"];
        return NO;
    }
    return YES;
}

+ (BOOL)writeGeneratedScriptForFlow:(NSDictionary *)flow
                           toBundle:(NSString *)bundlePath
                              error:(NSError **)error
{
    NSFileManager *manager = [NSFileManager defaultManager];
    if (![manager fileExistsAtPath:bundlePath]) {
        if (error) *error = [self error:@"脚本目录不存在。"];
        return NO;
    }

    NSString *source = [self pythonSourceForFlow:flow];
    NSString *mainPath = [bundlePath stringByAppendingPathComponent:@"main.py"];
    if (![source writeToFile:mainPath atomically:YES encoding:NSUTF8StringEncoding error:error]) return NO;

    // info.plist：只补必要键，FrontApp / Orientation / Schedule 这些都保留用户原来的值
    NSString *infoPath = [bundlePath stringByAppendingPathComponent:@"info.plist"];
    NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:infoPath];
    NSMutableDictionary *info = [existing isKindOfClass:[NSDictionary class]] ? [existing mutableCopy]
                                                                              : [NSMutableDictionary dictionary];
    info[@"Entry"] = @"main.py";
    if (info[@"FrontApp"] == nil) info[@"FrontApp"] = @"";
    if (info[@"Orientation"] == nil) info[@"Orientation"] = @"1";
    if (![info writeToFile:infoPath atomically:YES]) {
        if (error) *error = [self error:@"无法写入 info.plist。"];
        return NO;
    }
    return YES;
}

+ (NSError *)error:(NSString *)message
{
    return [NSError errorWithDomain:@"小新Lap" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - 代码生成

+ (void)appendLine:(NSMutableString *)out indent:(NSInteger)indent text:(NSString *)text
{
    for (NSInteger i = 0; i < indent; i++) [out appendString:@"    "];
    [out appendString:text];
    [out appendString:@"\n"];
}

+ (NSString *)pythonSourceForFlow:(NSDictionary *)flow
{
    NSArray *steps = [flow[@"Steps"] isKindOfClass:[NSArray class]] ? flow[@"Steps"] : @[];
    NSInteger loopTimes = [flow[@"LoopTimes"] integerValue];
    double loopInterval = flow[@"LoopInterval"] ? [flow[@"LoopInterval"] doubleValue] : 0.2;

    NSMutableString *out = [NSMutableString string];

    [out appendString:@"# -*- coding: utf-8 -*-\n"];
    [out appendString:@"#\n"];
    [out appendFormat:@"%@\n", kGeneratedMarker];
    [out appendString:@"# 手改这里的内容，下次在编辑器里保存「运行方式」时会被覆盖；\n"];
    [out appendString:@"# 想写代码的脚本，请另外新建一个脚本，不要改这个。\n"];
    [out appendString:@"#\n"];
    [out appendString:@"# 坐标一律填「触摸指示器」上显示的像素值：点击 / 取色 / 找色 / 识图返回的是同一套，\n"];
    [out appendString:@"# 方向换算由引擎内部完成，脚本不用管。\n"];
    [out appendString:@"\n"];
    [out appendString:@"import time\n\n"];
    [out appendString:@"from zxtouch.client import zxtouch\n"];
    [out appendString:@"from zxtouch.touchtypes import TOUCH_DOWN, TOUCH_MOVE, TOUCH_UP\n"];
    [out appendString:@"from zxtouch.toasttypes import TOAST_MESSAGE\n\n"];
    [out appendString:@"设备 = zxtouch(\"127.0.0.1\")\n\n"];
    [out appendString:[NSString stringWithFormat:@"循环次数 = %ld          # 0 = 一直循环，直到手动停止\n", (long)loopTimes]];
    [out appendString:[NSString stringWithFormat:@"每轮间隔 = %@      # 每轮之间歇多久（秒）\n\n", [self textForValue:@(loopInterval)]]];

    [out appendString:
     @"\n"
     "def 点(x, y, 次数=1, 间隔=0.02, 按住=0.02):\n"
     "    \"\"\"按下 → 按住一会儿 → 抬起 → 停「间隔」秒，连做「次数」下。\"\"\"\n"
     "    x, y = int(round(float(x))), int(round(float(y)))\n"
     "    for _ in range(max(1, int(float(次数)))):\n"
     "        设备.touch(TOUCH_DOWN, 1, x, y)\n"
     "        if 按住 > 0:\n"
     "            time.sleep(按住)\n"
     "        设备.touch(TOUCH_UP, 1, x, y)\n"
     "        if 间隔 > 0:\n"
     "            time.sleep(间隔)\n"
     "\n"
     "\n"
     "def 滑(x1, y1, x2, y2, 时长=0.4):\n"
     "    \"\"\"从起点划到终点，中间分 12 步，免得划得太快被游戏当成点击。\"\"\"\n"
     "    x1, y1, x2, y2 = (int(round(float(v))) for v in (x1, y1, x2, y2))\n"
     "    步数 = 12\n"
     "    设备.touch(TOUCH_DOWN, 1, x1, y1)\n"
     "    for i in range(1, 步数 + 1):\n"
     "        time.sleep(float(时长) / 步数)\n"
     "        设备.touch(TOUCH_MOVE, 1, x1 + (x2 - x1) * i / 步数, y1 + (y2 - y1) * i / 步数)\n"
     "    设备.touch(TOUCH_UP, 1, x2, y2)\n"
     "\n"
     "\n"
     "def 取色(x, y):\n"
     "    \"\"\"读这一点的 RGB；读不到返回 -1,-1,-1。\"\"\"\n"
     "    ok, c = 设备.pick_color(int(x), int(y))\n"
     "    if not ok:\n"
     "        return -1, -1, -1\n"
     "    return int(c[\"red\"]), int(c[\"green\"]), int(c[\"blue\"])\n"
     "\n"
     "\n"
     "def 是色(x, y, 色, 容差=10):\n"
     "    \"\"\"这一点是不是指定颜色（十六进制如 FF8800）。\n"
     "    截图是 JPEG，纯色块也有 ±2 噪声，所以不能直接用 == 比。\"\"\"\n"
     "    目标 = str(色).lstrip(\"#\")\n"
     "    r, g, b = 取色(x, y)\n"
     "    return (abs(r - int(目标[0:2], 16)) <= 容差\n"
     "            and abs(g - int(目标[2:4], 16)) <= 容差\n"
     "            and abs(b - int(目标[4:6], 16)) <= 容差)\n"
     "\n"
     "\n"
     "def 找色(x, y, 宽, 高, 色, 容差=10, 步长=1):\n"
     "    \"\"\"在区域里找指定颜色，找到返回 (x, y)，没找到返回 None。\"\"\"\n"
     "    目标 = str(色).lstrip(\"#\")\n"
     "    r, g, b = int(目标[0:2], 16), int(目标[2:4], 16), int(目标[4:6], 16)\n"
     "    ok, 结果 = 设备.search_color((int(x), int(y), int(宽), int(高)),\n"
     "                                 max(0, r - 容差), min(255, r + 容差),\n"
     "                                 max(0, g - 容差), min(255, g + 容差),\n"
     "                                 max(0, b - 容差), min(255, b + 容差), int(步长))\n"
     "    if not ok:\n"
     "        return None\n"
     "    return int(结果[\"x\"]), int(结果[\"y\"])\n"
     "\n"
     "\n"
     "def 找图(模板, 阈值=0.8):\n"
     "    \"\"\"全屏找模板图，找到返回图中心 (x, y)，没找到返回 None。\n"
     "    第 3 个参数 0 = 关掉多尺度：模板是按原图 1:1 抠的，只扫一倍档，快很多。\"\"\"\n"
     "    ok, 结果 = 设备.image_match(模板, float(阈值), 0, 0.8)\n"
     "    if not ok:\n"
     "        return None\n"
     "    return (float(结果[\"x\"]) + float(结果[\"width\"]) / 2.0,\n"
     "            float(结果[\"y\"]) + float(结果[\"height\"]) / 2.0)\n"
     "\n"
     "\n"
     "def 识字(x, y, 宽, 高, 语言=\"zh-Hans,en-US\"):\n"
     "    \"\"\"识别区域里的文字，返回识别到的全部文字拼起来的字符串；识别不到或出错时返回空字符串。\n"
     "    语言用逗号分隔：zh-Hans = 简体中文，en-US = 英文。\"\"\"\n"
     "    语言列表 = [s for s in str(语言).replace(\"，\", \",\").split(\",\") if s]\n"
     "    ok, 结果 = 设备.ocr((int(x), int(y), int(宽), int(高)), languages=语言列表)\n"
     "    if not ok:\n"
     "        return \"\"\n"
     "    return \"\".join(str(项.get(\"text\", \"\")) for 项 in 结果)\n"
     "\n"
     "\n"];

    [out appendString:@"轮数 = 0\n"];
    [out appendString:@"while True:\n"];
    [self appendLine:out indent:1 text:@"if 循环次数 > 0 and 轮数 >= 循环次数:"];
    [self appendLine:out indent:2 text:@"break"];
    [self appendLine:out indent:1 text:@"轮数 += 1"];

    if (steps.count == 0) {
        [self appendLine:out indent:1 text:@"pass          # 还没有添加任何步骤"];
    } else {
        for (NSDictionary *step in steps) {
            [self appendStep:step to:out indent:1];
        }
    }

    [self appendLine:out indent:1 text:@"time.sleep(每轮间隔 if 每轮间隔 > 0 else 0.001)"];
    [out appendString:@"\n"];

    return out;
}

+ (void)appendStep:(NSDictionary *)step to:(NSMutableString *)out indent:(NSInteger)indent
{
    FlowStepType *type = [self typeForKind:step[@"Kind"]];
    if (type.isCondition) {
        [self appendCondition:step to:out indent:indent];
    } else {
        [self appendAction:step to:out indent:indent];
    }
}

+ (void)appendCondition:(NSDictionary *)step to:(NSMutableString *)out indent:(NSInteger)indent
{
    NSString *kind = step[@"Kind"];
    NSString *color = [self colorText:step[@"Color"]];
    NSString *tolerance = [self textForValue:step[@"Tolerance"]];
    NSString *condition = nil;

    if ([kind isEqualToString:kFlowColor]) {
        condition = [NSString stringWithFormat:@"是色(%@, %@, \"%@\", %@)",
                     [self textForValue:step[@"X"]], [self textForValue:step[@"Y"]], color, tolerance];
    } else if ([kind isEqualToString:kFlowFindColor]) {
        NSInteger left = [step[@"X1"] integerValue], top = [step[@"Y1"] integerValue];
        NSInteger right = [step[@"X2"] integerValue], bottom = [step[@"Y2"] integerValue];
        // 允许用户从右下往左上框，生成前先把角点理顺
        NSInteger x = MIN(left, right), y = MIN(top, bottom);
        NSInteger w = labs(right - left), h = labs(bottom - top);
        condition = [NSString stringWithFormat:@"找色(%ld, %ld, %ld, %ld, \"%@\", %@)",
                     (long)x, (long)y, (long)MAX(w, 1), (long)MAX(h, 1), color, tolerance];
    } else if ([kind isEqualToString:kFlowImage]) {
        NSString *name = [step[@"Template"] isKindOfClass:[NSString class]] ? step[@"Template"] : @"";
        NSString *path = [kFlowTemplateFolder stringByAppendingPathComponent:name.length ? name : @"未框选.png"];
        condition = [NSString stringWithFormat:@"找图(\"%@\", %@)", path, [self textForValue:step[@"Threshold"]]];
    } else if ([kind isEqualToString:kFlowOCR]) {
        NSInteger left = [step[@"X1"] integerValue], top = [step[@"Y1"] integerValue];
        NSInteger right = [step[@"X2"] integerValue], bottom = [step[@"Y2"] integerValue];
        NSInteger x = MIN(left, right), y = MIN(top, bottom);
        NSInteger w = labs(right - left), h = labs(bottom - top);
        NSString *langs = [step[@"Languages"] isKindOfClass:[NSString class]] ? step[@"Languages"] : @"";
        if (langs.length == 0) langs = @"zh-Hans,en-US";
        NSString *target = [step[@"Text"] isKindOfClass:[NSString class]] ? step[@"Text"] : @"";
        target = [target stringByReplacingOccurrencesOfString:@"\"" withString:@"'"];
        NSString *match = [step[@"Match"] isKindOfClass:[NSString class]] ? step[@"Match"] : @"contains";
        NSString *call = [NSString stringWithFormat:@"识字(%ld, %ld, %ld, %ld, \"%@\")",
                          (long)x, (long)y, (long)MAX(w, 1), (long)MAX(h, 1), langs];
        if ([match isEqualToString:@"equals"]) {
            condition = [NSString stringWithFormat:@"(\"%@\" == %@)", target, call];
        } else if ([match isEqualToString:@"notContains"]) {
            condition = [NSString stringWithFormat:@"(\"%@\" not in %@)", target, call];
        } else {
            condition = [NSString stringWithFormat:@"(\"%@\" in %@)", target, call];
        }
    } else {
        condition = @"True";
    }

    [self appendLine:out indent:indent text:[NSString stringWithFormat:@"if %@:      # %@", condition, [self shortTitle:kind]]];
    [self appendActions:step[@"Then"] to:out indent:indent + 1];
    [self appendLine:out indent:indent text:@"else:"];
    [self appendActions:step[@"Else"] to:out indent:indent + 1];
}

+ (void)appendActions:(id)actions to:(NSMutableString *)out indent:(NSInteger)indent
{
    NSArray *list = [actions isKindOfClass:[NSArray class]] ? actions : @[];
    if (list.count == 0) {
        // 不成立时什么都不做是常态，这里写 pass 而不是省略 else，结构更好读
        [self appendLine:out indent:indent text:@"pass"];
        return;
    }
    for (NSDictionary *action in list) {
        if (![action isKindOfClass:[NSDictionary class]]) continue;
        [self appendAction:action to:out indent:indent];
    }
}

+ (void)appendAction:(NSDictionary *)step to:(NSMutableString *)out indent:(NSInteger)indent
{
    NSString *kind = step[@"Kind"];
    NSString *line = nil;

    if ([kind isEqualToString:kFlowTap]) {
        double interval = step[@"Interval"] ? [step[@"Interval"] doubleValue] : kDefaultTapInterval;
        double hold = step[@"Hold"] ? [step[@"Hold"] doubleValue] : kDefaultTapHold;
        NSInteger count = [step[@"Count"] integerValue];
        NSMutableArray *args = [NSMutableArray arrayWithObjects:
                                [self textForValue:step[@"X"]], [self textForValue:step[@"Y"]], nil];
        if (count != 1) [args addObject:[NSString stringWithFormat:@"次数=%ld", (long)count]];
        if (fabs(interval - kDefaultTapInterval) > 1e-9) [args addObject:[NSString stringWithFormat:@"间隔=%@", [self textForValue:@(interval)]]];
        if (fabs(hold - kDefaultTapHold) > 1e-9) [args addObject:[NSString stringWithFormat:@"按住=%@", [self textForValue:@(hold)]]];
        line = [NSString stringWithFormat:@"点(%@)", [args componentsJoinedByString:@", "]];
    } else if ([kind isEqualToString:kFlowSwipe]) {
        line = [NSString stringWithFormat:@"滑(%@, %@, %@, %@, %@)",
                [self textForValue:step[@"X1"]], [self textForValue:step[@"Y1"]],
                [self textForValue:step[@"X2"]], [self textForValue:step[@"Y2"]],
                [self textForValue:step[@"Duration"]]];
    } else if ([kind isEqualToString:kFlowWait]) {
        line = [NSString stringWithFormat:@"time.sleep(%@)", [self textForValue:step[@"Seconds"]]];
    } else if ([kind isEqualToString:kFlowToast]) {
        NSString *text = [NSString stringWithFormat:@"%@", step[@"Text"] ?: @""];
        text = [text stringByReplacingOccurrencesOfString:@"\"" withString:@"'"];
        line = [NSString stringWithFormat:@"设备.show_toast(TOAST_MESSAGE, \"%@\", %@)", text, [self textForValue:step[@"Seconds"]]];
    } else if ([kind isEqualToString:kFlowOpenApp]) {
        NSString *bundle = [NSString stringWithFormat:@"%@", step[@"Bundle"] ?: @""];
        bundle = [bundle stringByReplacingOccurrencesOfString:@"\"" withString:@"'"];
        line = [NSString stringWithFormat:@"设备.switch_to_app(\"%@\")", bundle];
    } else if ([kind isEqualToString:kFlowHome]) {
        line = @"设备.go_home()";
    } else if ([kind isEqualToString:kFlowKillApp]) {
        NSString *bundle = [NSString stringWithFormat:@"%@", step[@"Bundle"] ?: @""];
        bundle = [bundle stringByReplacingOccurrencesOfString:@"\"" withString:@"'"];
        line = [NSString stringWithFormat:@"设备.kill_app(\"%@\")", bundle];
    } else if ([kind isEqualToString:kFlowPaste]) {
        NSString *text = [NSString stringWithFormat:@"%@", step[@"Text"] ?: @""];
        if (text.length == 0) {
            line = @"设备.paste_from_clipboard()";
        } else {
            text = [text stringByReplacingOccurrencesOfString:@"\"" withString:@"'"];
            line = [NSString stringWithFormat:@"设备.insert_text(\"%@\")", text];
        }
    } else if ([kind isEqualToString:kFlowRing]) {
        NSString *sound = [NSString stringWithFormat:@"%@", step[@"Sound"] ?: @""];
        if (sound.length == 0) sound = @"Alarm.m4r";
        sound = [sound stringByReplacingOccurrencesOfString:@"\"" withString:@"'"];
        line = [NSString stringWithFormat:@"设备.play_ring(\"%@\", %@)", sound, [self textForValue:step[@"Seconds"]]];
    } else if ([kind isEqualToString:kFlowVolume]) {
        NSString *mode = [step[@"Mode"] isKindOfClass:[NSString class]] ? step[@"Mode"] : @"percent";
        NSString *percent = [self textForValue:step[@"Percent"]];
        if ([mode isEqualToString:@"up"]) {
            line = [NSString stringWithFormat:@"设备.change_volume_percent(%@)", percent];
        } else if ([mode isEqualToString:@"down"]) {
            line = [NSString stringWithFormat:@"设备.change_volume_percent(-%@)", percent];
        } else {
            line = [NSString stringWithFormat:@"设备.set_volume(%@)", percent];
        }
    } else if ([kind isEqualToString:kFlowStopAll]) {
        line = @"设备.stop_all_scripts()";
    } else if ([kind isEqualToString:kFlowCall]) {
        NSString *number = [NSString stringWithFormat:@"%@", step[@"Number"] ?: @""];
        number = [number stringByReplacingOccurrencesOfString:@"\"" withString:@"'"];
        line = [NSString stringWithFormat:@"设备.make_call(\"%@\", \"%@\")", number, fwSimValue(step[@"SIM"])];
    } else if ([kind isEqualToString:kFlowSMS]) {
        NSString *number = [NSString stringWithFormat:@"%@", step[@"Number"] ?: @""];
        number = [number stringByReplacingOccurrencesOfString:@"\"" withString:@"'"];
        NSString *text = [NSString stringWithFormat:@"%@", step[@"Text"] ?: @""];
        text = [text stringByReplacingOccurrencesOfString:@"\"" withString:@"'"];
        line = [NSString stringWithFormat:@"设备.send_sms(\"%@\", \"%@\", \"%@\")", number, text, fwSimValue(step[@"SIM"])];
    } else if ([kind isEqualToString:kFlowWeChat]) {
        line = @"pass";
    } else {
        return;
    }

    [self appendLine:out indent:indent text:[NSString stringWithFormat:@"%@      # %@", line, [self shortTitle:kind]]];
}

+ (NSString *)shortTitle:(NSString *)kind
{
    FlowStepType *type = [self typeForKind:kind];
    return type.title ?: @"步骤";
}

/// 颜色统一成大写十六进制、去掉 # 号：引擎与「是色」都按 6 位十六进制解析
+ (NSString *)colorText:(id)value
{
    NSString *text = [NSString stringWithFormat:@"%@", value ?: @""];
    text = [text stringByReplacingOccurrencesOfString:@"#" withString:@""];
    text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return text.uppercaseString;
}

@end
