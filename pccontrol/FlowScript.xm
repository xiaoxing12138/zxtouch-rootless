//
//  FlowScript.xm
//  小新Lap 可视化脚本
//

#import "FlowScript.h"
#import "Common.h"
#import "Screen.h"

#import <math.h>

// 步骤标题里的 App：包名换成中文显示名（找不到就退回包名）。结果缓存 10 秒，避免每个步骤行都去枚举一遍
static NSString *fwAppDisplayName(NSString *bundle)
{
    if (bundle.length == 0) return bundle;

    static NSDictionary<NSString *, NSString *> *map = nil;
    static NSTimeInterval loadedAt = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (map == nil || now - loadedAt > 10.0) {
        NSMutableDictionary<NSString *, NSString *> *m = [NSMutableDictionary dictionary];
        for (NSDictionary *app in ZXInstalledApplications()) {
            NSString *b = app[@"bundle"];
            NSString *n = app[@"name"];
            if (b.length > 0 && n.length > 0) m[b] = n;
        }
        map = m;
        loadedAt = now;
    }

    NSString *name = map[bundle];
    return name.length > 0 ? name : bundle;
}

// 判断步骤的「不成立」分支可以整体关掉；缺省开（老脚本行为不变）
static BOOL fwFlowElseEnabled(NSDictionary *step)
{
    id v = step[@"ElseEnabled"];
    return [v isKindOfClass:[NSNumber class]] ? [v boolValue] : YES;
}

NSString * const kFlowFileName = @"flow.plist";
NSString * const kFlowTemplateFolder = @"/var/mobile/Library/ZXTouch/tpl";

NSString * const kFlowTap = @"tap";
NSString * const kFlowSwipe = @"swipe";
NSString * const kFlowWait = @"wait";
NSString * const kFlowToast = @"toast";
NSString * const kFlowRepeat = @"repeat";
NSString * const kFlowColor = @"color";
NSString * const kFlowFindColor = @"findColor";
NSString * const kFlowCountColor = @"countColor";
NSString * const kFlowImage = @"image";
NSString * const kFlowOCR = @"ocr";
NSString * const kFlowRunScript = @"runScript";
NSString * const kFlowAppSwitch = @"appSwitch";
NSString * const kFlowWiFi = @"wifi";
NSString * const kFlowScreenshot = @"screenshot";
NSString * const kFlowPaste = @"paste";
NSString * const kFlowRing = @"ring";
NSString * const kFlowVolume = @"volume";
NSString * const kFlowStopAll = @"stopAll";
NSString * const kFlowCall = @"call";
NSString * const kFlowSMS = @"sms";
NSString * const kFlowDingTalk = @"dingtalk";
NSString * const kFlowWeCom = @"wecom";
NSString * const kFlowWeChat = @"wechat";
NSString * const kFlowHttp = @"http";
NSString * const kFlowShell = @"shell";

BOOL FlowStepSupportsArea(NSDictionary *step)
{
    NSString *kind = step[@"Kind"];
    return [kind isEqualToString:kFlowFindColor] || [kind isEqualToString:kFlowCountColor]
        || [kind isEqualToString:kFlowImage] || [kind isEqualToString:kFlowOCR];
}

NSString * FlowAreaModeForStep(NSDictionary *step)
{
    if ([step[@"Kind"] isEqualToString:kFlowImage]) {
        id m = step[@"Mode"];
        NSString *mode = [m isKindOfClass:[NSString class]] ? m : @"full";
        return [mode isEqualToString:@"area"] ? @"area" : @"full";
    }
    id v = step[@"AreaMode"];
    if ([v isKindOfClass:[NSString class]]) {
        return [v isEqualToString:@"full"] ? @"full" : @"area";
    }
    for (NSString *key in @[@"X1", @"Y1", @"X2", @"Y2"]) {
        id n = step[key];
        double d = 0;
        if ([n isKindOfClass:[NSNumber class]]) d = [n doubleValue];
        else if ([n isKindOfClass:[NSString class]] && [n length] > 0) d = [n doubleValue];
        if (d != 0) return @"area";
    }
    return @"full";
}

// 分类固定顺序：触摸 → 判断条件 → 流程 → App 与输入 → 设备 → 提醒
static NSString * const kCatTouch = @"触摸";
static NSString * const kCatCondition = @"判断条件";
static NSString * const kCatFlow = @"流程";
static NSString * const kCatApp = @"App 与输入";
static NSString * const kCatDevice = @"设备";
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

// 每个判断条件都带一组「找不到就重试」：0 次 = 只判断一次（老脚本的默认行为）
static NSArray<FlowFieldSpec *> *flowRetryFieldSpecs(void)
{
    FlowFieldSpec *interval = [FlowFieldSpec numKey:@"RetryInterval" title:@"找不到时隔几秒再找" integer:NO def:@"1"];
    FlowFieldSpec *times = [FlowFieldSpec key:@"RetryTimes" title:@"最多重试几次（0=不重试）" integer:YES def:@"0"];
    return @[ interval, times ];
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

@interface FlowScript ()
+ (void)appendStep:(NSDictionary *)step to:(NSMutableString *)out indent:(NSInteger)indent;
+ (void)appendRepeat:(NSDictionary *)step to:(NSMutableString *)out indent:(NSInteger)indent;
+ (void)appendActions:(id)actions to:(NSMutableString *)out indent:(NSInteger)indent;
+ (void)appendAction:(NSDictionary *)step to:(NSMutableString *)out indent:(NSInteger)indent;
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
        FlowFieldSpec *waitMode = [FlowFieldSpec key:@"Mode" title:@"延迟方式" integer:NO def:@"fixed"];
        waitMode.choiceTitles = @[ @"固定延迟", @"随机延迟" ];
        waitMode.choiceValues = @[ @"fixed", @"random" ];
        FlowFieldSpec *waitSeconds = [FlowFieldSpec numKey:@"Seconds" title:@"等几秒" integer:NO def:@"0.5"];
        waitSeconds.stepperStep = 1;
        FlowFieldSpec *waitMin = [FlowFieldSpec numKey:@"SecondsMin" title:@"最短等几秒" integer:NO def:@"0.5"];
        waitMin.stepperStep = 1;
        FlowFieldSpec *waitMax = [FlowFieldSpec numKey:@"SecondsMax" title:@"最长等几秒" integer:NO def:@"1"];
        waitMax.stepperStep = 1;
        wait.fields = @[ waitMode, waitSeconds, waitMin, waitMax ];

        FlowStepType *toast = [self type:kFlowToast title:@"提示" symbol:@"text.bubble.fill" condition:NO];
        toast.category = kCatFlow;
        toast.fields = @[
            [FlowFieldSpec key:@"Text" title:@"提示文字" integer:NO def:@"完成"],
            [FlowFieldSpec numKey:@"Seconds" title:@"显示几秒" integer:NO def:@"2"],
        ];

        // 重复：把一组动作跑 N 遍，里面还能再放重复
        FlowStepType *repeat = [self type:kFlowRepeat title:@"重复" symbol:@"repeat" condition:NO];
        repeat.category = kCatFlow;
        repeat.hint = @"「重复」里面可以再放动作（也能再放重复），直接在列表里缩进显示；步骤行里填跑几遍，填 0 就一遍都不跑。";
        repeat.fields = @[ [FlowFieldSpec key:@"Times" title:@"重复几次" integer:YES def:@"3"] ];

        FlowStepType *color = [self type:kFlowColor title:@"识色" symbol:@"eyedropper.halffull" condition:YES];
        color.category = kCatCondition;
        color.hint = @"「找不到时隔几秒再找」「最多重试几次」：重试用完还找不到，才执行「不成立时」里的动作；填 0 次就是只判断一次。";
        color.pickActionTitle = @"从屏幕取颜色";
        color.pickMode = FlowPickModeColor;
        color.pickTargets = @[@"X", @"Y"];
        color.fields = [@[
            [FlowFieldSpec key:@"X" title:@"X 坐标" integer:YES def:@"400"],
            [FlowFieldSpec key:@"Y" title:@"Y 坐标" integer:YES def:@"400"],
            [FlowFieldSpec key:@"Color" title:@"颜色（如 FF8800）" integer:NO def:@"FFFFFF"],
            [FlowFieldSpec key:@"Tolerance" title:@"容差（0-255）" integer:YES def:@"10"],
        ] arrayByAddingObjectsFromArray:flowRetryFieldSpecs()];

        FlowStepType *findColor = [self type:kFlowFindColor title:@"找色" symbol:@"magnifyingglass" condition:YES];
        findColor.category = kCatCondition;
        findColor.hint = @"「找不到时隔几秒再找」「最多重试几次」：重试用完还找不到，才执行「不成立时」里的动作；填 0 次就是只判断一次。";
        findColor.pickActionTitle = @"从屏幕框选区域";
        findColor.pickMode = FlowPickModeRect;
        findColor.pickTargets = @[@"X1", @"Y1", @"X2", @"Y2"];
        findColor.fields = [@[
            [FlowFieldSpec key:@"X1" title:@"区域左" integer:YES def:@"0"],
            [FlowFieldSpec key:@"Y1" title:@"区域上" integer:YES def:@"0"],
            [FlowFieldSpec key:@"X2" title:@"区域右" integer:YES def:@"1000"],
            [FlowFieldSpec key:@"Y2" title:@"区域下" integer:YES def:@"600"],
            [FlowFieldSpec key:@"Color" title:@"颜色（如 FF8800）" integer:NO def:@"FFFFFF"],
            [FlowFieldSpec key:@"Tolerance" title:@"容差（0-255）" integer:YES def:@"10"],
        ] arrayByAddingObjectsFromArray:flowRetryFieldSpecs()];

        FlowStepType *countColor = [self type:kFlowCountColor title:@"数色" symbol:@"number.square.fill" condition:YES];
        countColor.category = kCatCondition;
        countColor.hint = @"「找不到时隔几秒再找」「最多重试几次」：重试用完还没达到你要的数量，才执行「不成立时」里的动作；填 0 次就是只判断一次。";
        countColor.pickActionTitle = @"从屏幕框选区域";
        countColor.pickMode = FlowPickModeRect;
        countColor.pickTargets = @[@"X1", @"Y1", @"X2", @"Y2"];
        FlowFieldSpec *countMode = [FlowFieldSpec key:@"Mode" title:@"判据" integer:NO def:@"atLeast"];
        countMode.choiceTitles = @[ @"至少", @"至多" ];
        countMode.choiceValues = @[ @"atLeast", @"atMost" ];
        countColor.fields = [@[
            [FlowFieldSpec key:@"X1" title:@"区域左" integer:YES def:@"0"],
            [FlowFieldSpec key:@"Y1" title:@"区域上" integer:YES def:@"0"],
            [FlowFieldSpec key:@"X2" title:@"区域右" integer:YES def:@"1000"],
            [FlowFieldSpec key:@"Y2" title:@"区域下" integer:YES def:@"600"],
            [FlowFieldSpec key:@"Color" title:@"颜色（如 FF8800）" integer:NO def:@"FFFFFF"],
            [FlowFieldSpec key:@"Tolerance" title:@"容差（0-255）" integer:YES def:@"10"],
            [FlowFieldSpec key:@"Count" title:@"像素数量" integer:YES def:@"1000"],
            countMode,
        ] arrayByAddingObjectsFromArray:flowRetryFieldSpecs()];

        FlowStepType *image = [self type:kFlowImage title:@"识图" symbol:@"photo.fill" condition:YES];
        image.category = kCatCondition;
        image.hint = @"「找不到时隔几秒再找」「最多重试几次」：重试用完还没找到模板，才执行「不成立时」里的动作；填 0 次就是只判断一次。";
        image.pickActionTitle = @"从屏幕框选模板";
        image.pickMode = FlowPickModeTemplate;
        image.pickTargets = @[@"Template"];
        image.pickActionTitle2 = @"从屏幕框选识别区域";
        image.pickMode2 = FlowPickModeRect;
        image.pickTargets2 = @[@"X1", @"Y1", @"X2", @"Y2"];
        image.pick2GateKey = @"Mode";
        image.pick2GateValue = @"area";
        FlowFieldSpec *imageMode = [FlowFieldSpec key:@"Mode" title:@"搜索范围" integer:NO def:@"full"];
        imageMode.choiceTitles = @[ @"全屏", @"自定义区域" ];
        imageMode.choiceValues = @[ @"full", @"area" ];
        image.fields = [@[
            [FlowFieldSpec key:@"Template" title:@"模板图（用下面的按钮框选）" integer:NO def:@""],
            [FlowFieldSpec numKey:@"Threshold" title:@"相似度（0-1）" integer:NO def:@"0.8"],
            imageMode,
            [FlowFieldSpec key:@"X1" title:@"区域左" integer:YES def:@"0"],
            [FlowFieldSpec key:@"Y1" title:@"区域上" integer:YES def:@"0"],
            [FlowFieldSpec key:@"X2" title:@"区域右" integer:YES def:@"0"],
            [FlowFieldSpec key:@"Y2" title:@"区域下" integer:YES def:@"0"],
        ] arrayByAddingObjectsFromArray:flowRetryFieldSpecs()];

        // 识字：把框选区域里的文字/数字识别出来，只用来判断，不改变脚本流程
        FlowStepType *ocr = [self type:kFlowOCR title:@"识字" symbol:@"text.viewfinder" condition:YES];
        ocr.category = kCatCondition;
        ocr.hint = @"「找不到时隔几秒再找」「最多重试几次」：重试用完还没识别到你要的文字，才执行「不成立时」里的动作；填 0 次就是只判断一次。";
        ocr.pickActionTitle = @"从屏幕框选识字区域";
        ocr.pickMode = FlowPickModeRect;
        ocr.pickTargets = @[@"X1", @"Y1", @"X2", @"Y2"];
        FlowFieldSpec *ocrMatch = [FlowFieldSpec key:@"Match" title:@"判据" integer:NO def:@"contains"];
        ocrMatch.choiceTitles = @[ @"包含", @"等于", @"不包含" ];
        ocrMatch.choiceValues = @[ @"contains", @"equals", @"notContains" ];
        FlowFieldSpec *ocrLanguages = [FlowFieldSpec key:@"Languages" title:@"识别语言" integer:NO def:@"zh-Hans,en-US"];
        ocrLanguages.pickerKind = @"languages";
        ocr.fields = [@[
            [FlowFieldSpec key:@"X1" title:@"区域左" integer:YES def:@"0"],
            [FlowFieldSpec key:@"Y1" title:@"区域上" integer:YES def:@"0"],
            [FlowFieldSpec key:@"X2" title:@"区域右" integer:YES def:@"1000"],
            [FlowFieldSpec key:@"Y2" title:@"区域下" integer:YES def:@"600"],
            ocrMatch,
            [FlowFieldSpec key:@"Text" title:@"要比对的文字或数字" integer:NO def:@""],
            ocrLanguages,
        ] arrayByAddingObjectsFromArray:flowRetryFieldSpecs()];

        // 开关 App：一个步骤同时管「打开」和「关闭」，用哪个由「方式」决定
        FlowStepType *appSwitch = [self type:kFlowAppSwitch title:@"开关app" symbol:@"arrow.triangle.2.circlepath" condition:NO];
        appSwitch.category = kCatApp;
        appSwitch.hint = @"「关闭」会把该 App 的后台进程直接杀掉（等同于上滑清后台），并不是简单切走。";
        FlowFieldSpec *appSwitchMode = [FlowFieldSpec key:@"Mode" title:@"方式" integer:NO def:@"open"];
        appSwitchMode.choiceTitles = @[ @"打开", @"关闭" ];
        appSwitchMode.choiceValues = @[ @"open", @"close" ];
        FlowFieldSpec *appSwitchBundle = [FlowFieldSpec key:@"Bundle" title:@"目标 App" integer:NO def:@""];
        appSwitchBundle.pickerKind = @"app";
        appSwitch.fields = @[ appSwitchMode, appSwitchBundle ];

        // 开关 WiFi：方式为「打开 / 关闭」
        FlowStepType *wifi = [self type:kFlowWiFi title:@"开关WiFi" symbol:@"wifi" condition:NO];
        wifi.category = kCatDevice;
        FlowFieldSpec *wifiMode = [FlowFieldSpec key:@"Mode" title:@"方式" integer:NO def:@"on"];
        wifiMode.choiceTitles = @[ @"打开", @"关闭" ];
        wifiMode.choiceValues = @[ @"on", @"off" ];
        wifi.fields = @[ wifiMode ];

        // 截屏保存：后台截图直接写进相册，不弹系统截图预览
        FlowStepType *screenshot = [self type:kFlowScreenshot title:@"截屏保存" symbol:@"camera.fill" condition:NO];
        screenshot.category = kCatDevice;
        screenshot.hint = @"「截屏保存」在后台截当前屏幕并存进相册，不会弹出系统截图预览。";
        screenshot.fields = @[];

        // 输入：从剪贴板粘贴，或输入自定义文字，由「输入方式」决定
        FlowStepType *paste = [self type:kFlowPaste title:@"输入" symbol:@"keyboard.fill" condition:NO];
        paste.category = kCatApp;
        FlowFieldSpec *pasteMode = [FlowFieldSpec key:@"Mode" title:@"输入方式" integer:NO def:@"text"];
        pasteMode.choiceTitles = @[ @"自定义文字", @"剪贴板" ];
        pasteMode.choiceValues = @[ @"text", @"clipboard" ];
        paste.fields = @[
            pasteMode,
            [FlowFieldSpec key:@"Text" title:@"自定义文字" integer:NO def:@""],
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

        // 运行其他脚本：选一个已安装的脚本，启动它（不会等它跑完）
        FlowStepType *runScript = [self type:kFlowRunScript title:@"运行其他脚本" symbol:@"play.circle.fill" condition:NO];
        runScript.category = kCatFlow;
        runScript.hint = @"启动选中的脚本后立刻继续执行当前流程，不会等它跑完。";
        FlowFieldSpec *runScriptPicker = [FlowFieldSpec key:@"Script" title:@"要运行的脚本" integer:NO def:@""];
        runScriptPicker.pickerKind = @"script";
        runScript.fields = @[ runScriptPicker ];

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

        // 钉钉机器人：webhook 地址 + 加签密钥（可空）+ 推送内容
        FlowStepType *dingtalk = [self type:kFlowDingTalk title:@"钉钉机器人" symbol:@"paperplane.fill" condition:NO];
        dingtalk.category = kCatRemind;
        dingtalk.hint = @"「钉钉机器人」按群机器人的 webhook 推送一条文本。加了加签安全设置就把密钥一起填上，没有就留空。";
        dingtalk.fields = @[
            [FlowFieldSpec key:@"URL" title:@"webhook 地址" integer:NO def:@""],
            [FlowFieldSpec key:@"Secret" title:@"加签密钥（没有就留空）" integer:NO def:@""],
            [FlowFieldSpec key:@"Text" title:@"推送内容" integer:NO def:@""],
        ];

        // 企业微信机器人：webhook 地址 + 推送内容
        FlowStepType *wecom = [self type:kFlowWeCom title:@"企业微信机器人" symbol:@"paperplane.fill" condition:NO];
        wecom.category = kCatRemind;
        wecom.hint = @"「企业微信机器人」按群机器人的 webhook 地址推送一条文本。";
        wecom.fields = @[
            [FlowFieldSpec key:@"URL" title:@"webhook 地址" integer:NO def:@""],
            [FlowFieldSpec key:@"Text" title:@"推送内容" integer:NO def:@""],
        ];

        // 发微信：占位步骤，暂不执行，先放在这里
        FlowStepType *wechat = [self type:kFlowWeChat title:@"发微信" symbol:@"bubble.left.and.bubble.right.fill" condition:NO];
        wechat.category = kCatRemind;
        wechat.hint = @"「发微信」目前是占位步骤，放进流程里不会真正发送，后续版本再接。";
        wechat.fields = @[];

        FlowStepType *http = [self type:kFlowHttp title:@"URL 请求" symbol:@"network" condition:NO];
        http.category = kCatDevice;
        http.hint = @"按地址发 HTTP 请求；返回 4xx / 5xx 或网络失败时提示并停止当前流程。";
        FlowFieldSpec *httpMethod = [FlowFieldSpec key:@"Method" title:@"请求方式" integer:NO def:@"GET"];
        httpMethod.choiceTitles = @[ @"GET", @"POST", @"PUT", @"DELETE" ];
        httpMethod.choiceValues = @[ @"GET", @"POST", @"PUT", @"DELETE" ];
        http.fields = @[
            httpMethod,
            [FlowFieldSpec key:@"URL" title:@"地址" integer:NO def:@"https://"],
            [FlowFieldSpec key:@"Headers" title:@"请求头（K: V; K2: V2）" integer:NO def:@""],
            [FlowFieldSpec key:@"Body" title:@"请求体（可空）" integer:NO def:@""],
            [FlowFieldSpec numKey:@"Timeout" title:@"超时（秒）" integer:NO def:@"10"],
            [FlowFieldSpec key:@"SaveFile" title:@"响应保存到文件（可空）" integer:NO def:@""],
        ];

        FlowStepType *shell = [self type:kFlowShell title:@"执行命令" symbol:@"terminal.fill" condition:NO];
        shell.category = kCatDevice;
        shell.hint = @"在设备上执行一条 shell 命令；退出码不为 0 时提示并停止当前流程。";
        shell.fields = @[
            [FlowFieldSpec key:@"Command" title:@"命令" integer:NO def:@""],
            [FlowFieldSpec numKey:@"Timeout" title:@"超时（秒）" integer:NO def:@"10"],
        ];

        types = @[tap, swipe, wait, toast, repeat, color, findColor, countColor, image, ocr,
                  stopAll, runScript, appSwitch, wifi, screenshot, paste, volume,
                  ring, call, sms, dingtalk, wecom, wechat, http, shell];
    });
    return types;
}

+ (NSArray<NSString *> *)categoryTitles
{
    return @[ kCatTouch, kCatCondition, kCatFlow, kCatApp, kCatDevice, kCatRemind ];
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
    type.pickMode2 = FlowPickModeNone;
    type.pickActionTitle2 = @"";
    type.pickTargets2 = @[];
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
        step[@"ElseEnabled"] = @(NO);
    } else if ([kind isEqualToString:kFlowRepeat]) {
        step[@"Steps"] = [NSMutableArray array];
    }
    if ([kind isEqualToString:kFlowFindColor] || [kind isEqualToString:kFlowCountColor]
        || [kind isEqualToString:kFlowOCR]) {
        step[@"AreaMode"] = @"full";
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

+ (void)waitRangeForStep:(NSDictionary *)step minValue:(double *)minValue maxValue:(double *)maxValue
{
    NSNumber *minNumber = [step[@"SecondsMin"] isKindOfClass:[NSNumber class]] ? step[@"SecondsMin"] : @(0.5);
    NSNumber *maxNumber = [step[@"SecondsMax"] isKindOfClass:[NSNumber class]] ? step[@"SecondsMax"] : @(1);
    double low = MAX([minNumber doubleValue], 0);
    double high = MAX([maxNumber doubleValue], 0);
    if (low > high) {
        double swap = low;
        low = high;
        high = swap;
    }
    if (minValue) *minValue = low;
    if (maxValue) *maxValue = high;
}

+ (NSString *)waitRangeTextForStep:(NSDictionary *)step
{
    double low = 0, high = 0;
    [self waitRangeForStep:step minValue:&low maxValue:&high];
    return [NSString stringWithFormat:@"%@~%@", [self textForValue:@(low)], [self textForValue:@(high)]];
}

+ (NSString *)pasteModeForStep:(NSDictionary *)step
{
    NSString *mode = [step[@"Mode"] isKindOfClass:[NSString class]] ? step[@"Mode"] : @"";
    return mode.length > 0 ? mode : @"text";
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
        NSString *waitMode = [step[@"Mode"] isKindOfClass:[NSString class]] ? step[@"Mode"] : @"fixed";
        if ([waitMode isEqualToString:@"random"]) {
            return [NSString stringWithFormat:@"随机等待 %@ 秒", [self waitRangeTextForStep:step]];
        }
        return [NSString stringWithFormat:@"等待 %@ 秒", [self textForValue:step[@"Seconds"]]];
    }
    if ([kind isEqualToString:kFlowToast]) {
        return [NSString stringWithFormat:@"提示「%@」", step[@"Text"] ?: @""];
    }
    if ([kind isEqualToString:kFlowRepeat]) {
        NSArray *children = [step[@"Steps"] isKindOfClass:[NSArray class]] ? step[@"Steps"] : @[];
        return [NSString stringWithFormat:@"重复 %@ 次 · 里面 %lu 个动作",
                [self textForValue:step[@"Times"]], (unsigned long)children.count];
    }
    if ([kind isEqualToString:kFlowColor]) {
        return [NSString stringWithFormat:@"如果 (%@, %@) 是 #%@（±%@）",
                [self textForValue:step[@"X"]], [self textForValue:step[@"Y"]],
                step[@"Color"] ?: @"", [self textForValue:step[@"Tolerance"]]];
    }
    if ([kind isEqualToString:kFlowFindColor]) {
        return [NSString stringWithFormat:@"如果区域里有 #%@（±%@）",
                step[@"Color"] ?: @"", [self textForValue:step[@"Tolerance"]]];
    }
    if ([kind isEqualToString:kFlowCountColor]) {
        NSString *mode = [step[@"Mode"] isKindOfClass:[NSString class]] ? step[@"Mode"] : @"atLeast";
        return [NSString stringWithFormat:@"如果区域里 #%@（±%@）的像素%@ %@",
                step[@"Color"] ?: @"", [self textForValue:step[@"Tolerance"]],
                [mode isEqualToString:@"atMost"] ? @"至多" : @"至少",
                [self textForValue:step[@"Count"]]];
    }
    if ([kind isEqualToString:kFlowImage]) {
        NSString *name = [step[@"Template"] isKindOfClass:[NSString class]] ? step[@"Template"] : @"";
        NSString *imageMode = [step[@"Mode"] isKindOfClass:[NSString class]] ? step[@"Mode"] : @"full";
        NSString *where = @"全屏";
        if ([imageMode isEqualToString:@"area"]) {
            where = @"区域";
        }
        return [NSString stringWithFormat:@"如果 %@ 里有模板「%@」（≥%@）",
                where, name.length ? name : @"未框选", [self textForValue:step[@"Threshold"]]];
    }
    if ([kind isEqualToString:kFlowOCR]) {
        NSString *text = [step[@"Text"] isKindOfClass:[NSString class]] ? step[@"Text"] : @"";
        NSString *match = [step[@"Match"] isKindOfClass:[NSString class]] ? step[@"Match"] : @"contains";
        NSString *word = [match isEqualToString:@"equals"] ? @"等于"
                       : ([match isEqualToString:@"notContains"] ? @"不含" : @"包含");
        return [NSString stringWithFormat:@"如果区域%@「%@」",
                word, text.length ? text : @"（没填）"];
    }
    if ([kind isEqualToString:kFlowAppSwitch]) {
        NSString *mode = [step[@"Mode"] isKindOfClass:[NSString class]] ? step[@"Mode"] : @"open";
        NSString *bundle = [step[@"Bundle"] isKindOfClass:[NSString class]] ? step[@"Bundle"] : @"";
        return [NSString stringWithFormat:@"%@ App %@%@",
                [mode isEqualToString:@"close"] ? @"关闭" : @"打开",
                bundle.length ? fwAppDisplayName(bundle) : @"（未选择）",
                [mode isEqualToString:@"close"] ? @"（会杀死进程）" : @""];
    }
    if ([kind isEqualToString:kFlowWiFi]) {
        NSString *mode = [step[@"Mode"] isKindOfClass:[NSString class]] ? step[@"Mode"] : @"on";
        return [mode isEqualToString:@"off"] ? @"关闭 WiFi" : @"打开 WiFi";
    }
    if ([kind isEqualToString:kFlowScreenshot]) {
        return @"截屏并保存到相册";
    }
    if ([kind isEqualToString:kFlowPaste]) {
        NSString *mode = [self pasteModeForStep:step];
        if ([mode isEqualToString:@"text"]) {
            NSString *text = [step[@"Text"] isKindOfClass:[NSString class]] ? step[@"Text"] : @"";
            return text.length ? [NSString stringWithFormat:@"输入「%@」", text] : @"输入（没填文字）";
        }
        return @"粘贴剪贴板内容";
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
    if ([kind isEqualToString:kFlowRunScript]) {
        NSString *path = [step[@"Script"] isKindOfClass:[NSString class]] ? step[@"Script"] : @"";
        return [NSString stringWithFormat:@"运行脚本「%@」",
                path.length ? path.lastPathComponent.stringByDeletingPathExtension : @"（未选择）"];
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
    if ([kind isEqualToString:kFlowDingTalk]) {
        return @"推送钉钉机器人";
    }
    if ([kind isEqualToString:kFlowWeCom]) {
        return @"推送企业微信机器人";
    }
    if ([kind isEqualToString:kFlowWeChat]) {
        return @"发微信（占位，暂不执行）";
    }
    if ([kind isEqualToString:kFlowHttp]) {
        NSString *method = [step[@"Method"] isKindOfClass:[NSString class]] ? step[@"Method"] : @"GET";
        NSString *url = [step[@"URL"] isKindOfClass:[NSString class]] ? step[@"URL"] : @"";
        return [NSString stringWithFormat:@"%@ %@", method, url.length ? url : @"（没填地址）"];
    }
    if ([kind isEqualToString:kFlowShell]) {
        NSString *command = [step[@"Command"] isKindOfClass:[NSString class]] ? step[@"Command"] : @"";
        NSArray *lines = [command componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        NSString *first = lines.count > 0 ? lines[0] : @"";
        return [NSString stringWithFormat:@"执行命令：%@", first.length ? first : @"（没填命令）"];
    }
    return @"未知步骤";
}

+ (NSString *)detailForStep:(NSDictionary *)step
{
    FlowStepType *type = [self typeForKind:step[@"Kind"]];
    if (!type.isCondition) return nil;

    NSArray *then = [step[@"Then"] isKindOfClass:[NSArray class]] ? step[@"Then"] : @[];
    NSArray *otherwise = (fwFlowElseEnabled(step) && [step[@"Else"] isKindOfClass:[NSArray class]])
        ? step[@"Else"] : @[];
    NSInteger retryTimes = [step[@"RetryTimes"] integerValue];
    NSString *retry = @"";
    if (retryTimes > 0) {
        retry = [NSString stringWithFormat:@" · 找不到每 %@ 秒重试，共 %ld 次",
                 [self textForValue:step[@"RetryInterval"]], (long)retryTimes];
    }
    NSString *elseText = fwFlowElseEnabled(step)
        ? [NSString stringWithFormat:@"不成立时 %lu 个动作", (unsigned long)otherwise.count]
        : @"不成立分支已关闭";
    return [NSString stringWithFormat:@"成立时 %lu 个动作 · %@%@（点这一行编辑）",
            (unsigned long)then.count, elseText, retry];
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

    if (![self writeGeneratedScriptForFlow:flow toBundle:bundlePath error:error]) return NO;

    NSDictionary *info = @{ @"Entry": @"main.py", @"FrontApp": @"", @"Orientation": @"1" };
    if (![info writeToFile:[bundlePath stringByAppendingPathComponent:@"info.plist"] atomically:YES]) {
        if (error) *error = [self error:@"无法写入 info.plist。"];
        return NO;
    }
    return YES;
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
    for (NSString *key in @[@"Then", @"Else", @"Steps"]) {
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

// 生成代码里「重复 / 重试」用的临时变量编号，只在同一份输出里保证不重名
static NSInteger flowCodeSeq = 0;
static NSInteger flowNextCodeSeq(void)
{
    @synchronized([FlowScript class]) {
        flowCodeSeq += 1;
        return flowCodeSeq;
    }
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
    [out appendString:@"import time\nimport random\n\n"];
    [out appendString:@"from zxtouch.helpers import *\n"];
    [out appendString:@"from zxtouch.toasttypes import TOAST_MESSAGE\n\n"];
    [out appendString:[NSString stringWithFormat:@"循环次数 = %ld          # 0 = 一直循环，直到手动停止\n", (long)loopTimes]];
    [out appendString:[NSString stringWithFormat:@"每轮间隔 = %@      # 每轮之间歇多久（秒）\n\n", [self textForValue:@(loopInterval)]]];

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
    if ([step[@"Kind"] isEqualToString:kFlowRepeat]) {
        [self appendRepeat:step to:out indent:indent];
        return;
    }
    FlowStepType *type = [self typeForKind:step[@"Kind"]];
    if (type.isCondition) {
        [self appendCondition:step to:out indent:indent];
    } else {
        [self appendAction:step to:out indent:indent];
    }
}

+ (void)appendRepeat:(NSDictionary *)step to:(NSMutableString *)out indent:(NSInteger)indent
{
    NSInteger times = MAX(0, [step[@"Times"] integerValue]);
    NSArray *children = [step[@"Steps"] isKindOfClass:[NSArray class]] ? step[@"Steps"] : @[];
    NSInteger seq = flowNextCodeSeq();
    [self appendLine:out indent:indent
                text:[NSString stringWithFormat:@"for _zx_loop%ld in range(%ld):      # 重复 %ld 次",
                      (long)seq, (long)times, (long)times]];
    if (children.count == 0) {
        [self appendLine:out indent:indent + 1 text:@"pass          # 里面还没放动作"];
    } else {
        for (NSDictionary *child in children) {
            [self appendStep:child to:out indent:indent + 1];
        }
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
        NSInteger x = 0, y = 0, w = 0, h = 0;
        if (![FlowAreaModeForStep(step) isEqualToString:@"full"]) {
            NSInteger left = [step[@"X1"] integerValue], top = [step[@"Y1"] integerValue];
            NSInteger right = [step[@"X2"] integerValue], bottom = [step[@"Y2"] integerValue];
            // 允许用户从右下往左上框，生成前先把角点理顺
            x = MIN(left, right); y = MIN(top, bottom);
            w = labs(right - left); h = labs(bottom - top);
        }
        condition = [NSString stringWithFormat:@"找色(%ld, %ld, %ld, %ld, \"%@\", %@)",
                     (long)x, (long)y, (long)w, (long)h, color, tolerance];
    } else if ([kind isEqualToString:kFlowCountColor]) {
        NSInteger x = 0, y = 0, w = 0, h = 0;
        if (![FlowAreaModeForStep(step) isEqualToString:@"full"]) {
            NSInteger left = [step[@"X1"] integerValue], top = [step[@"Y1"] integerValue];
            NSInteger right = [step[@"X2"] integerValue], bottom = [step[@"Y2"] integerValue];
            x = MIN(left, right); y = MIN(top, bottom);
            w = labs(right - left); h = labs(bottom - top);
        }
        NSString *mode = [step[@"Mode"] isKindOfClass:[NSString class]] ? step[@"Mode"] : @"atLeast";
        NSString *want = [self textForValue:step[@"Count"]];
        if (want.length == 0) want = @"0";
        condition = [NSString stringWithFormat:@"(数色(%ld, %ld, %ld, %ld, \"%@\", %@) %@ %@)",
                     (long)x, (long)y, (long)w, (long)h, color, tolerance,
                     [mode isEqualToString:@"atMost"] ? @"<=" : @">=",
                     want];
    } else if ([kind isEqualToString:kFlowImage]) {
        NSString *name = [step[@"Template"] isKindOfClass:[NSString class]] ? step[@"Template"] : @"";
        NSString *path = [kFlowTemplateFolder stringByAppendingPathComponent:name.length ? name : @"未框选.png"];
        NSString *imageMode = [step[@"Mode"] isKindOfClass:[NSString class]] ? step[@"Mode"] : @"full";
        NSInteger x = 0, y = 0, w = 0, h = 0;
        if ([imageMode isEqualToString:@"area"]) {
            NSInteger left = [step[@"X1"] integerValue], top = [step[@"Y1"] integerValue];
            NSInteger right = [step[@"X2"] integerValue], bottom = [step[@"Y2"] integerValue];
            x = MIN(left, right); y = MIN(top, bottom);
            w = labs(right - left); h = labs(bottom - top);
        }
        condition = [NSString stringWithFormat:@"找图(\"%@\", %@, %ld, %ld, %ld, %ld)",
                     path, [self textForValue:step[@"Threshold"]], (long)x, (long)y, (long)w, (long)h];
    } else if ([kind isEqualToString:kFlowOCR]) {
        NSInteger x = 0, y = 0, w = 0, h = 0;
        if (![FlowAreaModeForStep(step) isEqualToString:@"full"]) {
            NSInteger left = [step[@"X1"] integerValue], top = [step[@"Y1"] integerValue];
            NSInteger right = [step[@"X2"] integerValue], bottom = [step[@"Y2"] integerValue];
            x = MIN(left, right); y = MIN(top, bottom);
            w = labs(right - left); h = labs(bottom - top);
        }
        NSString *langs = [step[@"Languages"] isKindOfClass:[NSString class]] ? step[@"Languages"] : @"";
        if (langs.length == 0) langs = @"zh-Hans,en-US";
        NSString *target = [step[@"Text"] isKindOfClass:[NSString class]] ? step[@"Text"] : @"";
        target = [target stringByReplacingOccurrencesOfString:@"\"" withString:@"'"];
        NSString *match = [step[@"Match"] isKindOfClass:[NSString class]] ? step[@"Match"] : @"contains";
        NSString *call = [NSString stringWithFormat:@"识字(%ld, %ld, %ld, %ld, \"%@\")",
                          (long)x, (long)y, (long)w, (long)h, langs];
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

    NSInteger retryTimes = MAX(0, [step[@"RetryTimes"] integerValue]);
    double retryInterval = [step[@"RetryInterval"] doubleValue];
    if (retryInterval < 0) retryInterval = 0;
    NSString *intervalText = [self textForValue:@(retryInterval)];

    if (retryTimes > 0) {
        NSInteger seq = flowNextCodeSeq();
        NSInteger attempts = retryTimes + 1;
        NSString *okVar = [NSString stringWithFormat:@"_zx_ok%ld", (long)seq];
        NSString *iVar = [NSString stringWithFormat:@"_zx_i%ld", (long)seq];
        [self appendLine:out indent:indent text:[NSString stringWithFormat:@"%@ = False", okVar]];
        [self appendLine:out indent:indent
                    text:[NSString stringWithFormat:@"for %@ in range(%ld):      # %@：最多试 %ld 次（每 %@ 秒一次）",
                          iVar, (long)attempts, [self shortTitle:kind], (long)attempts, intervalText]];
        [self appendLine:out indent:indent + 1 text:[NSString stringWithFormat:@"if %@:", condition]];
        [self appendLine:out indent:indent + 2 text:[NSString stringWithFormat:@"%@ = True", okVar]];
        [self appendLine:out indent:indent + 2 text:@"break"];
        if (retryInterval > 0) {
            [self appendLine:out indent:indent + 1
                        text:[NSString stringWithFormat:@"if %@ + 1 < %ld:", iVar, (long)attempts]];
            [self appendLine:out indent:indent + 2 text:[NSString stringWithFormat:@"time.sleep(%@)", intervalText]];
        }
        [self appendLine:out indent:indent text:[NSString stringWithFormat:@"if %@:      # 试满 %ld 次还找不到就不成立", okVar, (long)attempts]];
        [self appendActions:step[@"Then"] to:out indent:indent + 1];
        id elseActions = fwFlowElseEnabled(step) ? step[@"Else"] : nil;
        if ([elseActions isKindOfClass:[NSArray class]] && [elseActions count] > 0) {
            [self appendLine:out indent:indent text:@"else:"];
            [self appendActions:elseActions to:out indent:indent + 1];
        }
    } else {
        [self appendLine:out indent:indent text:[NSString stringWithFormat:@"if %@:      # %@", condition, [self shortTitle:kind]]];
        [self appendActions:step[@"Then"] to:out indent:indent + 1];
        id elseActions = fwFlowElseEnabled(step) ? step[@"Else"] : nil;
        if ([elseActions isKindOfClass:[NSArray class]] && [elseActions count] > 0) {
            [self appendLine:out indent:indent text:@"else:"];
            [self appendActions:elseActions to:out indent:indent + 1];
        }
    }
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
        [self appendStep:action to:out indent:indent];
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
        NSString *waitMode = [step[@"Mode"] isKindOfClass:[NSString class]] ? step[@"Mode"] : @"fixed";
        if ([waitMode isEqualToString:@"random"]) {
            double low = 0, high = 0;
            [self waitRangeForStep:step minValue:&low maxValue:&high];
            line = [NSString stringWithFormat:@"time.sleep(random.uniform(%@, %@))",
                    [self textForValue:@(low)], [self textForValue:@(high)]];
        } else {
            line = [NSString stringWithFormat:@"time.sleep(%@)", [self textForValue:step[@"Seconds"]]];
        }
    } else if ([kind isEqualToString:kFlowToast]) {
        NSString *text = [NSString stringWithFormat:@"%@", step[@"Text"] ?: @""];
        text = [text stringByReplacingOccurrencesOfString:@"\"" withString:@"'"];
        NSString *toastSeconds = [self textForValue:step[@"Seconds"]];
        if (toastSeconds.length == 0) toastSeconds = @"2";
        line = [NSString stringWithFormat:@"设备.show_toast(TOAST_MESSAGE, \"%@\", %@)", text, toastSeconds];
    } else if ([kind isEqualToString:kFlowAppSwitch]) {
        NSString *mode = [step[@"Mode"] isKindOfClass:[NSString class]] ? step[@"Mode"] : @"open";
        NSString *bundle = [NSString stringWithFormat:@"%@", step[@"Bundle"] ?: @""];
        bundle = [bundle stringByReplacingOccurrencesOfString:@"\"" withString:@"'"];
        if ([mode isEqualToString:@"close"]) {
            line = [NSString stringWithFormat:@"设备.kill_app(\"%@\")", bundle];
        } else {
            line = [NSString stringWithFormat:@"设备.switch_to_app(\"%@\")", bundle];
        }
    } else if ([kind isEqualToString:kFlowWiFi]) {
        NSString *mode = [step[@"Mode"] isKindOfClass:[NSString class]] ? step[@"Mode"] : @"on";
        line = [NSString stringWithFormat:@"设备.set_wifi(%@)", [mode isEqualToString:@"off"] ? @"False" : @"True"];
    } else if ([kind isEqualToString:kFlowScreenshot]) {
        line = @"设备.save_screenshot()";
    } else if ([kind isEqualToString:kFlowDingTalk]) {
        line = [NSString stringWithFormat:@"发送钉钉(\"%@\", \"%@\", \"%@\")",
                [self singleLineText:step[@"URL"]], [self singleLineText:step[@"Secret"]], [self singleLineText:step[@"Text"]]];
    } else if ([kind isEqualToString:kFlowWeCom]) {
        line = [NSString stringWithFormat:@"发送企业微信(\"%@\", \"%@\")",
                [self singleLineText:step[@"URL"]], [self singleLineText:step[@"Text"]]];
    } else if ([kind isEqualToString:kFlowPaste]) {
        NSString *mode = [self pasteModeForStep:step];
        NSString *text = [NSString stringWithFormat:@"%@", step[@"Text"] ?: @""];
        if ([mode isEqualToString:@"text"]) {
            text = [text stringByReplacingOccurrencesOfString:@"\"" withString:@"'"];
            line = [NSString stringWithFormat:@"设备.insert_text(\"%@\")", text];
        } else {
            line = @"设备.paste_from_clipboard()";
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
    } else if ([kind isEqualToString:kFlowRunScript]) {
        NSString *path = [NSString stringWithFormat:@"%@", step[@"Script"] ?: @""];
        path = [path stringByReplacingOccurrencesOfString:@"\"" withString:@"'"];
        line = [NSString stringWithFormat:@"设备.play_script(\"%@\")", path];
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
    } else if ([kind isEqualToString:kFlowHttp]) {
        NSString *httpTimeout = [self textForValue:step[@"Timeout"]];
        if (httpTimeout.length == 0) httpTimeout = @"10";
        line = [NSString stringWithFormat:@"请求(%@, %@, %@, %@, %@, %@)",
                [self pythonString:[self textForValue:step[@"Method"]]],
                [self pythonString:[self textForValue:step[@"URL"]]],
                [self pythonString:[self textForValue:step[@"Headers"]]],
                [self pythonString:[self textForValue:step[@"Body"]]],
                httpTimeout,
                [self pythonString:[self textForValue:step[@"SaveFile"]]]];
    } else if ([kind isEqualToString:kFlowShell]) {
        NSString *shellTimeout = [self textForValue:step[@"Timeout"]];
        if (shellTimeout.length == 0) shellTimeout = @"10";
        line = [NSString stringWithFormat:@"执行命令(%@, %@)",
                [self pythonString:[self textForValue:step[@"Command"]]],
                shellTimeout];
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

// 塞进生成代码的双引号字符串里的文本：换行和引号都换成安全字符，免得把 python 代码拆行
+ (NSString *)singleLineText:(id)value
{
    NSString *text = [NSString stringWithFormat:@"%@", value ?: @""];
    text = [text stringByReplacingOccurrencesOfString:@"\"" withString:@"'"];
    text = [text stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    return text;
}

+ (NSString *)pythonString:(id)value
{
    NSString *text = [NSString stringWithFormat:@"%@", value ?: @""];
    text = [text stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    text = [text stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    text = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\\n"];
    text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    text = [text stringByReplacingOccurrencesOfString:@"\r" withString:@"\\n"];
    return [NSString stringWithFormat:@"\"%@\"", text];
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
