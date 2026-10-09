#import "FunctionWindow.h"
#import "FloatingMenu.h"      // FMPassthroughWindow + preferredWindowScene
#import "Common.h"            // ZXSafeMainAsync / getScriptsFolder
#import "Config.h"            // PANEL_STATE_CONFIG_PATH
#import "ScriptFunctions.h"
#import "AlertBox.h"
#import "Play.h"
#import "Record.h"           // 录制开关：startRecording / stopRecording / isRecordingStart
#import "PickOverlay.h"      // 参数行「取点」：悬浮十字取坐标
#import "FlowWindow.h"       // 可视化流程编辑器（内容挂在本面板里）+ FlowEditorHost
#import "FlowScript.h"       // bundleHasFlow：判断脚本包里有没有可视化流程
#import <UIKit/UIKit.h>

#define FN_TOP_H     49.0f
#define FN_CARD_W    540.0f   // 卡片宽度：要装下「名称 + 4 个参数框 + 开关」一整行（屏幕不够宽时按屏宽自动缩）
#define FN_NAME_W    104.0f   // 功能名宽度：能站下 7 个中文字（14pt 字号）
#define FN_ROW_H     40.0f    // 脚本列表里一行的高度
#define FN_ROW_GAP   6.0f
#define FN_MIN_W     260.0f                // 面板最小宽度
#define FN_MIN_H     (FN_TOP_H + 120.0f)   // 面板最小高度
// 面板第一次打开（plist 里还没存过尺寸）时用的初始宽高：按用户实际调好的尺寸来，
// 别再退回「按内容自适应」（那样偏小）
#define FN_DEFAULT_W 553.0f
#define FN_DEFAULT_H 598.5f
#define FN_GRIP      26.0f                 // 右下角缩放把手的边长

// window 内空白区域透传：只有真正落在卡片子视图上的触摸才拦截，
// 卡片外的点击落到下层 App。
@interface FNPassthroughView : UIView
@end

@implementation FNPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}
@end

@interface FNRootViewController : UIViewController
@end

@implementation FNRootViewController
- (void)loadView {
    FNPassthroughView *root = [[FNPassthroughView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    root.backgroundColor = [UIColor clearColor];
    self.view = root;
}
@end

static UIButton *fnMakeButton(NSString *title, UIColor *color) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    b.backgroundColor = [UIColor secondarySystemBackgroundColor];
    b.layer.cornerRadius = 8;
    b.layer.borderColor = color.CGColor;
    b.layer.borderWidth = 1;
    [b setTitleColor:color forState:UIControlStateNormal];
    return b;
}

static UIImage *fnSymbol(NSString *name) {
    if (@available(iOS 13.0, *)) {
        return [UIImage systemImageNamed:name];
    }
    return nil;
}

// 脚本列表里的一行用容器 + block 点击：UIButton 摆不下「左边的名字 + 右边靠边的时间」两段文字
@interface FNTapView : UIView
@property (nonatomic, copy) void (^onTap)(void);
@end

@implementation FNTapView
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    if (!touch || !self.onTap) return;
    if (CGRectContainsPoint(self.bounds, [touch locationInView:self])) self.onTap();
}
@end

#define FN_SCRIPT_DELETE_W 72.0f   // 脚本行左滑露出的「删除」宽度

// 脚本列表里的脚本行：左滑露「删除」，长按弹菜单（复制 / 导出），点按选择
@interface FNScriptRowView : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView   *content;
@property (nonatomic, copy) void (^onTap)(void);
@property (nonatomic, copy) void (^onDelete)(void);
@property (nonatomic, copy) void (^onMenu)(void);
@end

@implementation FNScriptRowView {
    BOOL    _open;
    CGFloat _panStartX;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.cornerRadius = 8;
        self.clipsToBounds = YES;

        UIButton *del = [UIButton buttonWithType:UIButtonTypeSystem];
        del.backgroundColor = [UIColor systemRedColor];
        del.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        [del setTitle:@"删除" forState:UIControlStateNormal];
        [del setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        del.hidden = YES;
        del.tag = 9;
        __weak typeof(self) weakSelf = self;
        [del addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
            FNScriptRowView *row = weakSelf;
            if (row && row.onDelete) row.onDelete();
        }] forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:del];

        _content = [[UIView alloc] initWithFrame:self.bounds];
        _content.backgroundColor = [UIColor secondarySystemBackgroundColor];
        _content.layer.cornerRadius = 8;
        [self addSubview:_content];

        UILongPressGestureRecognizer *press =
            [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handlePress:)];
        press.minimumPressDuration = 0.45;
        [self addGestureRecognizer:press];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
        [tap requireGestureRecognizerToFail:press];
        [_content addGestureRecognizer:tap];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        pan.delegate = self;
        [self addGestureRecognizer:pan];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self viewWithTag:9].frame = CGRectMake(self.bounds.size.width - FN_SCRIPT_DELETE_W, 0,
                                            FN_SCRIPT_DELETE_W, self.bounds.size.height);
    if (CGAffineTransformIsIdentity(_content.transform)) _content.frame = self.bounds;
}

- (void)handleTap {
    if (_open) { [self setOpen:NO animated:YES]; return; }
    if (self.onTap) self.onTap();
}

- (void)handlePress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    [self setOpen:NO animated:NO];
    if (self.onMenu) self.onMenu();
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) _panStartX = _content.transform.tx;
    CGFloat x = _panStartX + [g translationInView:self].x;
    if (x > 0) x = 0;
    if (x < -FN_SCRIPT_DELETE_W) x = -FN_SCRIPT_DELETE_W;
    [self viewWithTag:9].hidden = (x > -1.0f);
    _content.transform = CGAffineTransformMakeTranslation(x, 0);
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        [self setOpen:(x < -FN_SCRIPT_DELETE_W / 2.0f) animated:YES];
    }
}

- (void)setOpen:(BOOL)open animated:(BOOL)animated {
    _open = open;
    [self viewWithTag:9].hidden = !open;
    void (^apply)(void) = ^{
        self->_content.transform = CGAffineTransformMakeTranslation(open ? -FN_SCRIPT_DELETE_W : 0, 0);
    };
    if (animated) [UIView animateWithDuration:0.18 animations:apply];
    else apply();
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if ([g isKindOfClass:[UIPanGestureRecognizer class]]) {
        CGPoint v = [(UIPanGestureRecognizer *)g velocityInView:self];
        return fabs(v.x) > fabs(v.y);   // 竖直方向留给列表自己滚
    }
    return YES;
}
@end

// 可视化脚本的总步骤数（读包内 flow.plist 的 Steps）；不是可视化脚本返回 -1
static NSInteger fnFlowStepCount(NSString *bundlePath) {
    NSDictionary *flow = [NSDictionary dictionaryWithContentsOfFile:
                          [bundlePath stringByAppendingPathComponent:kFlowFileName]];
    NSArray *steps = [flow[@"Steps"] isKindOfClass:[NSArray class]] ? flow[@"Steps"] : nil;
    return steps ? (NSInteger)steps.count : -1;
}

// 步骤数分档上色：0 灰，之后每 5 步换一色，30 步以上红
static UIColor *fnStepCountColor(NSInteger count) {
    if (count <= 0)  return [UIColor systemGrayColor];
    if (count <= 5)  return [UIColor systemBlueColor];
    if (count <= 10) return [UIColor systemGreenColor];
    if (count <= 15) return [UIColor systemOrangeColor];
    if (count <= 20) return [UIColor systemPurpleColor];
    if (count <= 25) return [UIColor systemPinkColor];
    if (count <= 30) return [UIColor systemTealColor];
    return [UIColor systemRedColor];
}

// 文件最后修改时间：今年的只显示「月-日 时:分」，往年带上年份
static NSString *fnDateText(NSDate *date) {
    if (!date) return @"";
    static NSDateFormatter *thisYear = nil;
    static NSDateFormatter *otherYear = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        thisYear = [[NSDateFormatter alloc] init];
        thisYear.dateFormat = @"MM-dd HH:mm";
        otherYear = [[NSDateFormatter alloc] init];
        otherYear.dateFormat = @"yyyy-MM-dd HH:mm";
    });
    NSDateFormatter *fmt = thisYear;
    NSInteger year = [[NSCalendar currentCalendar] component:NSCalendarUnitYear fromDate:date];
    NSInteger nowYear = [[NSCalendar currentCalendar] component:NSCalendarUnitYear fromDate:[NSDate date]];
    if (year != nowYear) fmt = otherYear;
    return [fmt stringFromDate:date];
}

// 界面外观：0跟随系统 1浅色 2深色。旧配置只有 dark_mode 布尔值，按 深色/浅色 迁移。
NSInteger ZXAppearanceModeFromConfig(NSDictionary *config) {
    if (config[@"appearance_mode"]) {
        return [config[@"appearance_mode"] integerValue];
    }
    if (config[@"dark_mode"]) {
        return [config[@"dark_mode"] boolValue] ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
    }
    return UIUserInterfaceStyleUnspecified;
}

void applyPanelAppearanceMode(NSInteger mode) {
    [[FunctionWindow shared] setAppearanceMode:mode];
}

// 面板两种内容：手写脚本 = 功能 + 选项；可视化脚本 = 流程编辑（同一张卡片，不另开窗口）
typedef NS_ENUM(NSInteger, FNPanelMode) {
    FNPanelModeFunctions = 0,
    FNPanelModeFlow,
};

// 拖动卡片：只认从顶栏开始的手势，中间那块滚动内容不抢
@interface FunctionWindow () <UIGestureRecognizerDelegate, FlowEditorHost, UITextFieldDelegate>
- (void)savePanelState;
- (void)handleResizePan:(UIPanGestureRecognizer *)pan;
@end

@implementation FunctionWindow
{
    UIWindow        *_window;
    UIView          *_cardView;
    UIScrollView    *_functionScrollView;
    UIButton        *_functionScriptBtn;
    UIButton        *_closeBtn;
    UIButton        *_saveBtn;
    UIButton        *_runBtn;
    UIButton        *_recordBtn;
    UIButton        *_newScriptBtn;  // 挑脚本时顶行的「＋」：弹菜单（新建 / 导入）
    UIButton        *_flowSettingsBtn; // 流程编辑页的「设置」：循环次数/间隔 + 定时启动结束
    UIImageView     *_resizeGrip;   // 右下角把手：拖它改面板大小
    FNPanelMode      _panelMode;    // 功能页 / 流程编辑页
    BOOL             _flowCanGoBack; // 流程编辑器在子页（顶栏左键 = 返回）

    NSArray<NSString *>        *_functionNames;
    NSMutableArray<UISwitch *> *_functionSwitches;
    NSString                   *_functionScriptPath;
    NSMutableDictionary<NSString *, NSString *> *_functionOptionValues;  // 选项名 → 当前值
    // 功能名 → 参数名 → 当前值（x/y/延迟/次数 这些，声明了才在面板上出现）
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSString *> *> *_functionParamValues;
    BOOL                        _pickingScript;   // 正在挑「功能」页要用的脚本
    NSMutableSet<NSString *>   *_expandedFolders; // 脚本列表里展开着的文件夹（绝对路径），存 plist
    BOOL                        _shown;
    BOOL                        _panelMoved;      // 用户手动拖过卡片，之后不再自动居中
    CGPoint                     _panelOrigin;
    NSInteger                   _appearanceMode;  // 0 跟随系统 1 浅色 2 深色
    CGFloat                     _contentHeight;   // 卡片中间滚动区的内容高度（用于自适应卡片高度）
    // 面板宽高是全局的：所有脚本、所有页面共用一个尺寸，存在 panel_state.plist 里，拖右下角改
    CGFloat                     _panelW;
    CGFloat                     _panelH;
}

+ (instancetype)shared {
    static FunctionWindow *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[FunctionWindow alloc] init];
    });
    return shared;
}

- (id)init {
    self = [super init];
    if (self) {
        _functionOptionValues = [NSMutableDictionary dictionary];
        _functionParamValues = [NSMutableDictionary dictionary];
        _pickingScript = NO;
        _shown = NO;
        _panelMoved = NO;
        _panelOrigin = CGPointZero;
        _appearanceMode = ZXAppearanceModeFromConfig([[NSDictionary alloc] initWithContentsOfFile:getCommonConfigFilePath()]);
        _contentHeight = 0;
        NSDictionary *state = [[NSDictionary alloc] initWithContentsOfFile:PANEL_STATE_CONFIG_PATH];
        _expandedFolders = [NSMutableSet setWithArray:(state[@"expanded"] ?: @[])];
        _panelW = [state[@"panel_w"] doubleValue];
        _panelH = [state[@"panel_h"] doubleValue];
    }
    return self;
}

#pragma mark - window / 卡片构建

- (void)ensureWindow {
    if (_window) return;
    [self buildWindow];
}

- (void)buildWindow {
    // iOS 13+ 必须用 initWithWindowScene:，initWithFrame: 创建的窗口不会显示
    UIWindowScene *scene = [FloatingMenu preferredWindowScene];
    if (scene) {
        _window = [[FMPassthroughWindow alloc] initWithWindowScene:scene];
    } else {
        _window = [[FMPassthroughWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    }
    _window.windowLevel = UIWindowLevelAlert + 1;
    _window.backgroundColor = [UIColor clearColor];
    _window.overrideUserInterfaceStyle = (UIUserInterfaceStyle)_appearanceMode;

    _window.rootViewController = [[FNRootViewController alloc] init];
    UIView *root = _window.rootViewController.view;

    // 居中卡片（frame 由 layoutCard 计算，autoresizing 保证旋转后仍居中）
    _cardView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, FN_CARD_W, 200)];
    _cardView.backgroundColor = [UIColor systemBackgroundColor];
    _cardView.layer.cornerRadius = 14;
    _cardView.layer.borderColor = [UIColor separatorColor].CGColor;
    _cardView.layer.borderWidth = 1;
    _cardView.clipsToBounds = YES;
    _cardView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin
                               | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [root addSubview:_cardView];

    // 手动拖动卡片换位置：手指按在顶栏拖（顶栏上的按钮轻点照常触发，只有真的拖动才会走这里）
    UIPanGestureRecognizer *cardPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleCardPan:)];
    cardPan.delegate = self;
    [_cardView addGestureRecognizer:cardPan];

    // 顶行左边：当前脚本（点一下去挑脚本）；流程编辑器在子页时它是「← 返回」
    _functionScriptBtn = fnMakeButton(@"脚本：", [UIColor systemBlueColor]);
    _functionScriptBtn.frame = CGRectMake(8, 6, FN_CARD_W - 8 - 40 - 6, 36);
    _functionScriptBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    _functionScriptBtn.titleLabel.adjustsFontSizeToFitWidth = YES;   // 脚本名长了缩字号
    _functionScriptBtn.titleLabel.minimumScaleFactor = 0.8;
    _functionScriptBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [_functionScriptBtn setImage:fnSymbol(@"list.bullet") forState:UIControlStateNormal];
    [_functionScriptBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        if (self->_pickingScript) {
            // 再点一下 = 放弃挑选，回到原来的内容
            self->_pickingScript = NO;
            [self reloadCurrentPage];
        } else if (self->_panelMode == FNPanelModeFlow && self->_flowCanGoBack) {
            [[FlowWindow shared] goBack];   // 流程子页：回上一页
        } else {
            [self beginScriptPicking];
        }
    }] forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_functionScriptBtn];

    _closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _closeBtn.frame = CGRectMake(FN_CARD_W - 40, 6, 32, 36);
    _closeBtn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _closeBtn.backgroundColor = [UIColor secondarySystemBackgroundColor];
    _closeBtn.layer.cornerRadius = 8;
    [_closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [_closeBtn setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    [_closeBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        [self hide];   // ✕：只关闭，不额外存盘
    }] forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_closeBtn];

    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(0, FN_TOP_H - 1, FN_CARD_W, 1)];
    sep.backgroundColor = [UIColor separatorColor];
    sep.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_cardView addSubview:sep];

    // 中间：选项 + 功能（可滚动）
    _functionScrollView = [[UIScrollView alloc] initWithFrame:CGRectMake(0, FN_TOP_H, FN_CARD_W, 160)];
    _functionScrollView.backgroundColor = [UIColor clearColor];
    _functionScrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_cardView addSubview:_functionScrollView];

    // 顶行右侧：运行 / 保存（都在 ✕ 左边，位置在 layoutCard 里排）
    _runBtn = fnMakeButton(@"运行", [UIColor systemGreenColor]);
    _runBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _runBtn.backgroundColor = [UIColor.systemGreenColor colorWithAlphaComponent:0.14];
    [_runBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        [self runFunctionSelection];
    }] forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_runBtn];

    _saveBtn = fnMakeButton(@"保存", [UIColor systemBlueColor]);
    _saveBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [_saveBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        [self saveAndHide];   // 功能页：存「选项值 + 功能参数 + 功能勾选」再关闭（流程页每次改动实时落盘，没有保存按钮）
    }] forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_saveBtn];

    // 流程编辑页顶行：设置（循环次数/间隔 + 定时启动结束，按脚本实时保存）
    _flowSettingsBtn = fnMakeButton(@"", [UIColor systemBlueColor]);
    [_flowSettingsBtn setImage:fnSymbol(@"gearshape") forState:UIControlStateNormal];
    [_flowSettingsBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        [[FlowWindow shared] showSettings];
    }] forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_flowSettingsBtn];

    // 顶行右侧：录制（未录制显示「录制」，录制中显示「停止」）
    _recordBtn = fnMakeButton(@"录制", [UIColor systemRedColor]);
    [_recordBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        [self toggleRecording];
    }] forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_recordBtn];

    // 挑脚本时才显示：弹菜单（新建可视化脚本 / 从「导入导出」文件夹导入）
    _newScriptBtn = fnMakeButton(@"＋", [UIColor systemBlueColor]);
    _newScriptBtn.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    [_newScriptBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        [self showNewScriptMenu];
    }] forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_newScriptBtn];

    // 右下角缩放把手：拖它改面板大小（大小是所有脚本、所有页面共用的，存 plist）
    _resizeGrip = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, FN_GRIP, FN_GRIP)];
    _resizeGrip.image = fnSymbol(@"arrow.up.left.and.arrow.down.right");
    _resizeGrip.tintColor = [UIColor secondaryLabelColor];
    _resizeGrip.contentMode = UIViewContentModeScaleAspectFit;
    _resizeGrip.userInteractionEnabled = YES;
    [_resizeGrip addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                            action:@selector(handleResizePan:)]];
    [_cardView addSubview:_resizeGrip];

    [self layoutCard];

    // 建好后先隐藏，等 show 时再显示
    _window.hidden = YES;

    // 旋转后居中 / 重排（卡片宽度取 FN_CARD_W 与屏幕宽度 - 40 的较小值，需按新尺寸重算）
    [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceOrientationDidChangeNotification
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            if (!self->_shown) return;
            [self persistAllValues];
            [self reloadCurrentPage];
        }];
}

// 面板宽度（给页面排版用）：用户调过就用调的，没调过就按默认宽算
- (CGFloat)cardWidth {
    CGFloat screenW = _window ? _window.bounds.size.width : [UIScreen mainScreen].bounds.size.width;
    if (screenW <= 0) screenW = 375.0f;
    if (_panelW > 0) return MIN(MAX(_panelW, FN_MIN_W), screenW - 16.0f);
    return MIN(FN_CARD_W, MAX(screenW - 40.0f, 200.0f));
}

// 面板尺寸是全局的：所有脚本、所有页面共用同一个宽高（存 plist）。
// 第一次打开（plist 里还没有）用 FN_DEFAULT_W/H 当初始值，之后就固定下来，只有拖右下角把手才会变。
- (CGSize)cardSizeInScreen:(CGSize)screen {
    if (_panelW <= 0 || _panelH <= 0) {
        _panelW = MIN(FN_DEFAULT_W, MAX(screen.width - 40.0f, 200.0f));
        _panelH = MIN(FN_DEFAULT_H, screen.height - 40.0f);
        [self savePanelState];
    }
    CGFloat w = MIN(MAX(_panelW, FN_MIN_W), screen.width - 16.0f);
    CGFloat h = MIN(MAX(_panelH, FN_MIN_H), screen.height - 40.0f);
    return CGSizeMake(w, h);
}

- (void)layoutCard {
    if (!_window || !_cardView) return;
    CGFloat screenW = _window.bounds.size.width;
    CGFloat screenH = _window.bounds.size.height;
    if (screenW <= 0) screenW = [UIScreen mainScreen].bounds.size.width;
    if (screenH <= 0) screenH = [UIScreen mainScreen].bounds.size.height;

    CGSize cardSize = [self cardSizeInScreen:CGSizeMake(screenW, screenH)];
    CGFloat cardW = cardSize.width;
    CGFloat cardH = cardSize.height;

    // 拖过就用拖到的地方，没拖过就居中；两种情况都要保证整张卡还在屏幕里
    CGFloat originX = _panelMoved ? _panelOrigin.x : (screenW - cardW) / 2.0f;
    CGFloat originY = _panelMoved ? _panelOrigin.y : (screenH - cardH) / 2.0f;
    if (originX + cardW > screenW - 8.0f) originX = MAX(screenW - cardW - 8.0f, 8.0f);
    if (originX < 8.0f) originX = 8.0f;
    if (originY + cardH > screenH - 8.0f) originY = MAX(screenH - cardH - 8.0f, 8.0f);
    if (originY < 8.0f) originY = 8.0f;
    if (_panelMoved) _panelOrigin = CGPointMake(originX, originY);

    _cardView.frame = CGRectMake(originX, originY, cardW, cardH);

    // 顶行按钮按内容切换：挑脚本时「＋ / 录制」；功能页「运行 / 保存」；流程页「设置」（流程实时落盘，没有保存/预览）
    BOOL flow = (!_pickingScript && _panelMode == FNPanelModeFlow);
    _runBtn.hidden = (_pickingScript || flow);
    _saveBtn.hidden = (_pickingScript || flow);
    _flowSettingsBtn.hidden = !flow;
    _recordBtn.hidden = !_pickingScript;
    _newScriptBtn.hidden = !_pickingScript;

    // 顶行从右往左排：✕ / 保存 / 运行 / 设置 / 录制 / ＋（隐藏的不占位），剩下的左边给脚本选择（约占卡片 1/3）
    CGFloat topY = 6.0f, topH = 36.0f, gap = 6.0f;
    CGFloat rightX = cardW - 8.0f;
    _closeBtn.frame = CGRectMake(rightX - 32.0f, topY, 32.0f, topH);
    rightX -= (32.0f + gap);

    NSArray<UIButton *> *topButtons = @[ _saveBtn, _runBtn, _flowSettingsBtn, _recordBtn, _newScriptBtn ];
    NSArray<NSNumber *> *topWidths = @[ @64.0, @64.0, @40.0, @60.0, @40.0 ];
    for (NSUInteger i = 0; i < topButtons.count; i++) {
        UIButton *btn = topButtons[i];
        if (btn.hidden) continue;
        CGFloat w = topWidths[i].doubleValue;
        btn.frame = CGRectMake(rightX - w, topY, w, topH);
        rightX -= (w + gap);
    }

    CGFloat scriptW = cardW / 3.0f;
    if (8.0f + scriptW > rightX - 6.0f) scriptW = MAX(rightX - 6.0f - 8.0f, 80.0f);
    _functionScriptBtn.frame = CGRectMake(8, topY, scriptW, topH);

    _functionScrollView.frame = CGRectMake(0, FN_TOP_H, cardW, MAX(cardH - FN_TOP_H, 0));

    // 右下角把手（往内缩 8pt，免得被圆角裁掉）
    _resizeGrip.frame = CGRectMake(cardW - 8.0f - FN_GRIP, cardH - 8.0f - FN_GRIP, FN_GRIP, FN_GRIP);
}

#pragma mark - 拖动卡片

- (void)handleCardPan:(UIPanGestureRecognizer *)pan {
    if (!_cardView) return;
    if (pan.state == UIGestureRecognizerStateBegan) _panelMoved = YES;

    CGPoint t = [pan translationInView:_cardView.superview];
    [pan setTranslation:CGPointZero inView:_cardView.superview];

    CGRect f = _cardView.frame;
    f.origin.x += t.x;
    f.origin.y += t.y;
    _cardView.frame = f;
    _panelOrigin = f.origin;   // 松手后 layoutCard 会按这个位置摆（并夹回屏幕里）

    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        [self layoutCard];   // 拖出屏幕外的部分夹回来，免得面板找不回来
    }
}

// 只有落在顶栏上的拖动才算拖卡片，中间那块滚动内容留给列表自己滚
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if ([g isKindOfClass:[UIPanGestureRecognizer class]]) {
        return [g locationInView:_cardView].y <= FN_TOP_H;
    }
    return YES;
}

// 拖右下角把手改面板大小：改完存盘，所有脚本、所有页面下次打开都是这个大小
- (void)handleResizePan:(UIPanGestureRecognizer *)pan {
    if (!_cardView) return;
    CGPoint t = [pan translationInView:_cardView.superview];
    [pan setTranslation:CGPointZero inView:_cardView.superview];

    CGFloat screenW = _window ? _window.bounds.size.width : [UIScreen mainScreen].bounds.size.width;
    CGFloat screenH = _window ? _window.bounds.size.height : [UIScreen mainScreen].bounds.size.height;
    if (screenW <= 0) screenW = [UIScreen mainScreen].bounds.size.width;
    if (screenH <= 0) screenH = [UIScreen mainScreen].bounds.size.height;

    _panelW = MIN(MAX(_panelW + t.x, FN_MIN_W), screenW - 16.0f);
    _panelH = MIN(MAX(_panelH + t.y, FN_MIN_H), screenH - 40.0f);
    [self layoutCard];

    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        [self persistAllValues];
        [self savePanelState];
        // 行是按宽度算好位置的，换宽度后要重排一遍
        [self reloadCurrentPage];
    }
}

#pragma mark - 选项控件

// 输入框弹出键盘时，键盘上方的「完成」条
- (UIView *)optionKeyboardAccessory {
    return [self optionKeyboardAccessoryWithPick:nil];
}

// 传了 pickAction 就多一个「取点」：x / y 两个框共用一条，点了在游戏画面上拖十字定坐标
- (UIView *)optionKeyboardAccessoryWithPick:(void (^)(void))pickAction {
    UIToolbar *bar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UIBarButtonItem *space = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                          target:nil action:nil];
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                                             style:UIBarButtonItemStylePlain
                                                            target:self
                                                            action:@selector(dismissOptionKeyboard)];
    if (pickAction) {
        UIAction *action = [UIAction actionWithTitle:@"取点" image:nil identifier:nil handler:^(__kindof UIAction *a) {
            pickAction();
        }];
        bar.items = @[[[UIBarButtonItem alloc] initWithPrimaryAction:action], space, done];
    } else {
        bar.items = @[space, done];
    }
    return bar;
}

- (void)dismissOptionKeyboard {
    [_cardView endEditing:YES];
}

// 输入框所在的 window 不是 key window 时，系统键盘不会出来（Apple QA1813：输入框的 window
// 必须成为 key window，否则「The keyboard doesn't show」）。面板窗口全程只 hidden=NO、
// 从没 makeKey，所以「部分设备/系统版本」上点输入框没反应。
// 在开始编辑之前（本回调保证在 becomeFirstResponder 之前）把窗口变成 key，再放行。
- (BOOL)textFieldShouldBeginEditing:(UITextField *)textField {
    UIWindow *win = textField.window;
    if (win && !win.isKeyWindow) [win makeKeyWindow];
    return YES;
}

// 拖十字取坐标，回填这一组参数的 x / y
- (void)pickPointForXField:(UITextField *)xField
                    yField:(UITextField *)yField
                     store:(NSMutableDictionary<NSString *, NSString *> *)store
{
    [_cardView endEditing:YES];
    _cardView.hidden = YES;   // 卡片必须让开：否则会被烤进冻结帧，也挡住游戏画面

    __weak typeof(self) weakSelf = self;
    [PickOverlay presentWithMode:FlowPickModePoint completion:^(NSDictionary *result) {
        FunctionWindow *window = weakSelf;
        if (!window) return;
        CGPoint point = [result[kPickStart] CGPointValue];
        NSArray<UITextField *> *fields = @[xField, yField];
        NSArray<NSString *> *keys = @[@"x", @"y"];
        NSArray<NSNumber *> *values = @[ @(llround(point.x)), @(llround(point.y)) ];
        for (NSUInteger i = 0; i < 2; i++) {
            fields[i].text = [NSString stringWithFormat:@"%ld", (long)values[i].integerValue];
            store[keys[i]] = fields[i].text;
        }
        [window persistAllValues];
        window->_cardView.hidden = NO;
    } cancel:^{
        FunctionWindow *window = weakSelf;   // 弱引用不能直接取 ivar，先落实成强引用
        if (!window) return;
        window->_cardView.hidden = NO;
    }];
}

// 把当前选项值存回 plist（切脚本 / 关闭 / 运行 / 输入框失焦时调用）
- (void)persistOptionValues {
    if (_functionScriptPath.length == 0) return;
    if (_functionOptionValues.count == 0) return;
    ZXSaveScriptOptionValues(_functionScriptPath, _functionOptionValues);
}

// 把当前功能参数（x/y/延迟/次数）存回 plist
- (void)persistFunctionParamValues {
    if (_functionScriptPath.length == 0) return;
    if (_functionParamValues.count == 0) return;
    ZXSaveScriptFunctionParams(_functionScriptPath, _functionParamValues);
}

- (void)persistAllValues {
    [self persistOptionValues];
    [self persistFunctionParamValues];
}

// 当前开关勾了哪些功能（下标与 _functionNames 一一对应）
- (NSArray<NSString *> *)pickedFunctionNames {
    NSMutableArray<NSString *> *picked = [NSMutableArray array];
    for (NSUInteger i = 0; i < _functionSwitches.count && i < _functionNames.count; i++) {
        if (_functionSwitches[i].isOn) [picked addObject:_functionNames[i]];
    }
    return picked;
}

// 「保存」按钮：选项值 + 功能参数 + 功能勾选 全部写盘，再关闭
- (void)saveAndHide {
    [self persistAllValues];
    if (_functionScriptPath.length > 0 && _functionNames.count > 0) {
        ZXSaveScriptFunctionSelection(_functionScriptPath, [self pickedFunctionNames]);
    }
    [self hide];
}

- (void)optionEditingEnded {
    [self persistAllValues];
}

// 一格选项：左边名称，右边按类型给控件。cellW = 这一格的宽度（选项区一行放两格）
- (UIView *)buildOptionCell:(NSDictionary *)decl value:(NSString *)value width:(CGFloat)cellW {
    NSString *name = decl[@"name"];
    ZXOptionType type = (ZXOptionType)[decl[@"type"] integerValue];
    NSArray<NSString *> *choices = decl[@"choices"];
    NSString *initial = value.length ? value : @"";

    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cellW, 44)];
    row.backgroundColor = [UIColor secondarySystemBackgroundColor];
    row.layer.cornerRadius = 8;

    CGFloat labelW = 72.0f;   // 放得下「抬起延迟」「自动拾取」这种 4 个字
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(10, 0, labelW, 44)];
    label.text = name;
    label.font = [UIFont systemFontOfSize:14];
    label.textColor = [UIColor labelColor];
    [row addSubview:label];

    // 控件跟在名称后面，占满这一格剩下的宽度
    CGFloat ctrlX = 10 + labelW + 6;
    CGFloat ctrlW = cellW - ctrlX - 10;
    if (ctrlW < 50) ctrlW = 50;

    if (type == ZXOptionTypeNumber || type == ZXOptionTypeText) {
        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(ctrlX, 6, ctrlW, 32)];
        tf.font = [UIFont systemFontOfSize:14];
        tf.textColor = [UIColor labelColor];
        tf.backgroundColor = [UIColor systemBackgroundColor];
        tf.layer.cornerRadius = 8;
        tf.layer.borderColor = [UIColor separatorColor].CGColor;
        tf.layer.borderWidth = 1;
        tf.textAlignment = NSTextAlignmentLeft;   // 值紧跟标签，别贴到格子最右
        tf.keyboardType = (type == ZXOptionTypeNumber) ? UIKeyboardTypeDecimalPad : UIKeyboardTypeDefault;
        tf.inputAccessoryView = [self optionKeyboardAccessory];
        tf.delegate = self;   // 开始编辑前把窗口变 key，否则键盘不弹（见 textFieldShouldBeginEditing:）
        tf.text = initial;
        tf.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        UIView *padL = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 32)];
        tf.leftView = padL; tf.leftViewMode = UITextFieldViewModeAlways;
        UIView *padR = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 32)];
        tf.rightView = padR; tf.rightViewMode = UITextFieldViewModeAlways;
        [tf addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
            self->_functionOptionValues[name] = tf.text ?: @"";
        }] forControlEvents:UIControlEventEditingChanged];
        [tf addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
            [self optionEditingEnded];
        }] forControlEvents:UIControlEventEditingDidEnd];
        [row addSubview:tf];
    } else if (type == ZXOptionTypeDropdown) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(ctrlX, 6, ctrlW, 32);
        btn.titleLabel.font = [UIFont systemFontOfSize:14];
        btn.backgroundColor = [UIColor systemBackgroundColor];
        btn.layer.cornerRadius = 8;
        btn.layer.borderColor = [UIColor separatorColor].CGColor;
        btn.layer.borderWidth = 1;
        btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        btn.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [btn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        // 左对齐时标题是贴着框边的，前面留一个空格当内边距（跟输入框的 8pt 左内边距对齐）
        [btn setTitle:[NSString stringWithFormat:@" %@  ▾", initial] forState:UIControlStateNormal];

        // 用 UIMenu 做下拉：窗口是独立 UIWindow，弹 UIAlertController 会被限制在窗口尺寸里
        NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
        for (NSString *choice in choices) {
            [items addObject:[UIAction actionWithTitle:choice image:nil identifier:nil handler:^(__kindof UIAction *a) {
                self->_functionOptionValues[name] = choice;
                [btn setTitle:[NSString stringWithFormat:@" %@  ▾", choice] forState:UIControlStateNormal];
                [self optionEditingEnded];
            }]];
        }
        btn.menu = [UIMenu menuWithTitle:@"" children:items];
        btn.showsMenuAsPrimaryAction = YES;
        [row addSubview:btn];
    } else {
        UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:choices];
        seg.frame = CGRectMake(ctrlX, 6, ctrlW, 32);
        NSInteger idx = [choices indexOfObject:initial];
        seg.selectedSegmentIndex = (idx == NSNotFound) ? 0 : idx;
        seg.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [seg addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
            NSInteger i = seg.selectedSegmentIndex;
            if (i >= 0 && i < (NSInteger)choices.count) self->_functionOptionValues[name] = choices[i];
            [self optionEditingEnded];
        }] forControlEvents:UIControlEventValueChanged];
        [row addSubview:seg];
    }

    return row;
}

// 一行放两个选项（左一格右一格），最后落单的就只占左半
- (UIView *)buildOptionPairRow:(NSArray<NSDictionary *> *)decls
                        values:(NSArray<NSString *> *)values
                         width:(CGFloat)pw {
    CGFloat rowW = pw - 8;
    CGFloat gap = 6.0f;
    CGFloat cellW = (rowW - gap) / 2.0f;

    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(4, 0, rowW, 44)];
    row.backgroundColor = [UIColor clearColor];
    row.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    for (NSUInteger i = 0; i < decls.count && i < 2; i++) {
        UIView *cell = [self buildOptionCell:decls[i] value:values[i] width:cellW];
        cell.frame = CGRectMake(i * (cellW + gap), 0, cellW, 44);
        [row addSubview:cell];
    }
    return row;
}

// 一格功能：名称（左，固定宽）+ 参数（在名称与开关之间居中）+ 开关（右，固定位）
// pw = 这一格的宽度（一行一个时是整张卡，一行两个时是半张卡），外面负责定位，这里不再加内缩
// 参数有两种，声明里就能看出来：
//   数字     「x=333」        → 小字标签 + 输入框
//   下拉     「范围=全部提醒|仅提醒白蛋|仅提醒黑蛋」 → 一个下拉按钮（值里带 | 就是下拉）
// 参数区整体居中，所以每行的开关都落在同一条竖线上，参数也不会挤在名字旁边。
- (UIView *)buildFunctionRow:(NSDictionary *)decl
                        isOn:(BOOL)isOn
                       saved:(NSDictionary<NSString *, NSString *> *)saved
                       width:(CGFloat)pw
                      switch:(UISwitch **)outSwitch
                      height:(CGFloat *)outHeight {
    NSString *funcName = decl[@"name"];
    NSArray<NSString *> *keys = decl[@"paramOrder"] ?: @[];

    CGFloat rowW = pw;
    CGFloat rowH = 46.0f;
    CGFloat pad = 10.0f;
    CGFloat nameW = FN_NAME_W;    // 够放 7 个中文字
    CGFloat switchW = 51.0f;
    CGFloat capW = 26.0f;         // 参数名小字（x / 延迟 / 次数…）的宽度
    CGFloat capGap = 4.0f;
    CGFloat gap = 6.0f;
    CGFloat midX = pad + nameW + 10;                  // 参数区可用的左边界
    CGFloat midW = rowW - midX - switchW - pad - 10;  // 参数区可用宽度
    if (midW < 60.0f) midW = 60.0f;

    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, rowW, rowH)];
    row.backgroundColor = [UIColor secondarySystemBackgroundColor];
    row.layer.cornerRadius = 8;
    row.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(pad, 0, nameW, rowH)];
    label.text = funcName;
    label.font = [UIFont systemFontOfSize:14];
    label.textColor = [UIColor labelColor];
    label.adjustsFontSizeToFitWidth = YES;   // 超长的名字缩字号，不留省略号
    label.minimumScaleFactor = 0.8;
    [row addSubview:label];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(rowW - pad - switchW, (rowH - 31) / 2.0f, switchW, 31)];
    sw.on = isOn;
    sw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [row addSubview:sw];
    if (outSwitch) *outSwitch = sw;

    if (keys.count > 0) {
        NSMutableDictionary<NSString *, NSString *> *store = _functionParamValues[funcName];
        if (!store) {
            store = [NSMutableDictionary dictionary];
            _functionParamValues[funcName] = store;
        }

        // 第一遍：定每个参数控件的宽度。数字框平分剩下的地方（封顶 56，够放 4 位数），下拉按最长选项定宽
        NSMutableArray<NSArray<NSString *> *> *choicesOf = [NSMutableArray array];
        NSMutableArray<NSNumber *> *widths = [NSMutableArray array];
        CGFloat fixedW = 0;
        NSUInteger numCount = 0;
        for (NSString *key in keys) {
            NSString *declared = decl[@"params"][key] ?: @"";
            NSArray<NSString *> *choices = [declared componentsSeparatedByString:@"|"];
            if ([declared rangeOfString:@"|"].location != NSNotFound) {
                CGFloat w = 96.0f;
                for (NSString *c in choices) {
                    CGFloat cw = [c sizeWithAttributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:13] }].width + 34.0f;
                    if (cw > w) w = cw;
                }
                [choicesOf addObject:choices];
                [widths addObject:@(w)];
                fixedW += w;
            } else {
                [choicesOf addObject:@[]];
                [widths addObject:@(0)];   // 第二遍再补
                fixedW += capW + capGap;
                numCount += 1;
            }
        }
        CGFloat fieldW = 56.0f;
        if (numCount > 0) {
            fieldW = (midW - fixedW - gap * (keys.count - 1)) / (CGFloat)numCount;
            fieldW = MIN(56.0f, fieldW);
            if (fieldW < 30.0f) fieldW = 30.0f;
        }

        CGFloat totalW = fixedW + fieldW * numCount + gap * (keys.count - 1);
        CGFloat fx = midX + (midW - totalW) / 2.0f;   // 整块参数居中
        if (fx < midX) fx = midX;

        // 第二遍：摆控件（顺手把数字框按 key 记下来，循环完给 x/y 挂「取点」）
        NSMutableDictionary<NSString *, UITextField *> *numFields = [NSMutableDictionary dictionary];
        for (NSUInteger i = 0; i < keys.count; i++) {
            NSString *key = keys[i];
            NSArray<NSString *> *choices = choicesOf[i];
            NSString *value = saved[key];
            CGFloat ctrlW = choices.count > 0 ? [widths[i] doubleValue] : fieldW;
            // 一行两个时中间只剩 60~70pt，控件要缩到装得下，否则会压到右边的开关
            CGFloat limit = (choices.count > 0) ? midW : (midW - capW - capGap);
            if (ctrlW > limit) ctrlW = limit;
            if (ctrlW < 20.0f) ctrlW = 20.0f;

            if (choices.count > 0) {
                // 下拉参数：存的值得是候选项之一，不是就用第一个（声明里那串带 | 的只是候选表）
                if (![choices containsObject:value ?: @""]) value = choices[0];
                store[key] = value;

                UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
                btn.frame = CGRectMake(fx, (rowH - 30) / 2.0f, ctrlW, 30);
                btn.titleLabel.font = [UIFont systemFontOfSize:13];
                btn.titleLabel.adjustsFontSizeToFitWidth = YES;
                btn.titleLabel.minimumScaleFactor = 0.8;
                btn.backgroundColor = [UIColor systemBackgroundColor];
                btn.layer.cornerRadius = 6;
                btn.layer.borderColor = [UIColor separatorColor].CGColor;
                btn.layer.borderWidth = 1;
                [btn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
                [btn setTitle:[NSString stringWithFormat:@"%@  ▾", value] forState:UIControlStateNormal];

                NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
                for (NSString *choice in choices) {
                    [items addObject:[UIAction actionWithTitle:choice image:nil identifier:nil handler:^(__kindof UIAction *a) {
                        store[key] = choice;
                        [btn setTitle:[NSString stringWithFormat:@"%@  ▾", choice] forState:UIControlStateNormal];
                        [self persistAllValues];
                    }]];
                }
                btn.menu = [UIMenu menuWithTitle:@"" children:items];
                btn.showsMenuAsPrimaryAction = YES;
                [row addSubview:btn];
            } else {
                if (value.length == 0) value = decl[@"params"][key];
                if (value.length == 0) value = @"";
                store[key] = value;

                UILabel *cap = [[UILabel alloc] initWithFrame:CGRectMake(fx, 0, capW, rowH)];
                cap.text = key;   // x / y / 延迟 / 次数
                cap.font = [UIFont systemFontOfSize:11];
                cap.textColor = [UIColor secondaryLabelColor];
                cap.textAlignment = NSTextAlignmentRight;
                [row addSubview:cap];

                UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(fx + capW + capGap, (rowH - 30) / 2.0f, ctrlW, 30)];
                tf.font = [UIFont systemFontOfSize:13];
                tf.textColor = [UIColor labelColor];
                tf.backgroundColor = [UIColor systemBackgroundColor];
                tf.layer.cornerRadius = 6;
                tf.layer.borderColor = [UIColor separatorColor].CGColor;
                tf.layer.borderWidth = 1;
                tf.textAlignment = NSTextAlignmentCenter;
                tf.keyboardType = UIKeyboardTypeDecimalPad;
                tf.adjustsFontSizeToFitWidth = YES;
                tf.minimumFontSize = 9;
                tf.inputAccessoryView = [self optionKeyboardAccessory];
                tf.delegate = self;   // 开始编辑前把窗口变 key，否则键盘不弹（见 textFieldShouldBeginEditing:）
                tf.text = value;
                [tf addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
                    store[key] = tf.text ?: @"";
                }] forControlEvents:UIControlEventEditingChanged];
                [tf addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
                    [self persistAllValues];
                }] forControlEvents:UIControlEventEditingDidEnd];
                [row addSubview:tf];
                numFields[key] = tf;
            }

            // 数字参数占的是「小字标签 + 输入框」，推进量必须把标签那一段算进去，
            // 否则下一个标签会压在上一个输入框上（4 个参数能压掉 90pt）
            fx += (choices.count > 0 ? ctrlW : capW + capGap + ctrlW) + gap;
        }

        // 声明了 x 和 y 的功能，键盘上加一个「取点」：拖十字定坐标，两个框一起回填
        UITextField *xField = numFields[@"x"];
        UITextField *yField = numFields[@"y"];
        if (xField && yField) {
            // 弱引用进 block：strong 的话「输入框 → 工具栏 → 动作 → block → 输入框」成环，面板一重建就漏一组
            __weak UITextField *weakX = xField;
            __weak UITextField *weakY = yField;
            UIToolbar *bar = (UIToolbar *)[self optionKeyboardAccessoryWithPick:^{
                [self pickPointForXField:weakX yField:weakY store:store];
            }];
            xField.inputAccessoryView = bar;
            yField.inputAccessoryView = bar;
        }
    }

    if (outHeight) *outHeight = rowH;
    return row;
}

- (void)addSectionLabel:(NSString *)text width:(CGFloat)pw atY:(CGFloat)y {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12, y, pw - 24, 18)];
    label.text = text;
    label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    label.textColor = [UIColor secondaryLabelColor];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_functionScrollView addSubview:label];
}

#pragma mark - 内容刷新

- (void)reloadFunctionPage {
    if (!_window) return;
    CGFloat pw = [self cardWidth];

    NSString *title = _functionScriptPath.length
        ? [[_functionScriptPath lastPathComponent] stringByDeletingPathExtension]
        : @"（点这里选脚本）";
    [_functionScriptBtn setTitle:[NSString stringWithFormat:@"脚本：%@", title] forState:UIControlStateNormal];

    [_cardView endEditing:YES];
    for (UIView *v in _functionScrollView.subviews) [v removeFromSuperview];
    _functionSwitches = [NSMutableArray array];
    _functionOptionValues = [NSMutableDictionary dictionary];
    _functionParamValues = [NSMutableDictionary dictionary];

    BOOL hasScript = _functionScriptPath.length > 0;
    NSArray<NSDictionary *> *decls = hasScript ? (ZXScriptOptionDeclarations(_functionScriptPath) ?: @[]) : @[];
    NSArray<NSDictionary *> *funcDecls = hasScript ? (ZXScriptFunctionDeclarations(_functionScriptPath) ?: @[]) : @[];
    NSMutableArray<NSString *> *funcNames = [NSMutableArray array];
    for (NSDictionary *d in funcDecls) [funcNames addObject:d[@"name"]];
    _functionNames = funcNames;
    NSDictionary<NSString *, NSString *> *saved = hasScript ? ZXScriptOptionValues(_functionScriptPath) : @{};
    NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *savedParams =
        hasScript ? ZXScriptFunctionParams(_functionScriptPath) : @{};

    CGFloat y = 4;

    // 用户要求：功能勾选区在上，选项区挪到面板最下面
    if (_functionNames.count > 0) {
        [self addSectionLabel:@"功能" width:pw atY:y];
        y += 22;

        NSArray<NSString *> *selected = hasScript ? ZXScriptFunctionSelection(_functionScriptPath) : nil;

        // 先把功能按行分组（顺序不变，勾选序号才对得上）：
        // 两个以上参数的自己占一整行（一行一个）；只有 0 或 1 个参数的攒够两个排一行
        NSMutableArray<NSArray<NSDictionary *> *> *rowGroups = [NSMutableArray array];
        NSMutableArray<NSDictionary *> *batch = [NSMutableArray array];
        for (NSDictionary *decl in funcDecls) {
            BOOL wide = [(decl[@"paramOrder"] ?: @[]) count] >= 2;
            if (wide) {
                if (batch.count > 0) { [rowGroups addObject:[batch copy]]; [batch removeAllObjects]; }
                [rowGroups addObject:@[decl]];
            } else {
                [batch addObject:decl];
                if (batch.count == 2) { [rowGroups addObject:[batch copy]]; [batch removeAllObjects]; }
            }
        }
        if (batch.count > 0) [rowGroups addObject:[batch copy]];

        CGFloat contentW = pw - 8;   // 卡片里能用的宽度（左右各留 4pt）
        CGFloat rowGap = 6.0f;
        for (NSArray<NSDictionary *> *group in rowGroups) {
            CGFloat rowH = 0;
            if (group.count == 1) {
                NSString *n = group[0][@"name"];
                UISwitch *sw = nil;
                UIView *cell = [self buildFunctionRow:group[0]
                                                 isOn:(selected == nil ? YES : [selected containsObject:n])
                                                saved:savedParams[n]
                                                width:contentW
                                               switch:&sw
                                               height:&rowH];
                [_functionSwitches addObject:sw];
                cell.frame = CGRectMake(4, y, contentW, rowH);
                [_functionScrollView addSubview:cell];
            } else {
                CGFloat cellW = (contentW - rowGap) / 2.0f;
                UIView *row = [[UIView alloc] initWithFrame:CGRectMake(4, y, contentW, 0)];
                for (NSUInteger i = 0; i < group.count; i++) {
                    NSString *n = group[i][@"name"];
                    UISwitch *sw = nil;
                    CGFloat cellH = 0;
                    UIView *cell = [self buildFunctionRow:group[i]
                                                     isOn:(selected == nil ? YES : [selected containsObject:n])
                                                    saved:savedParams[n]
                                                    width:cellW
                                                   switch:&sw
                                                   height:&cellH];
                    cell.frame = CGRectMake(i * (cellW + rowGap), 0, cellW, cellH);
                    [row addSubview:cell];
                    [_functionSwitches addObject:sw];
                    if (cellH > rowH) rowH = cellH;
                }
                row.frame = CGRectMake(4, y, contentW, rowH);
                [_functionScrollView addSubview:row];
            }
            y += rowH + rowGap;
        }
        y += 4;
    }

    if (decls.count > 0) {
        [self addSectionLabel:@"选项" width:pw atY:y];
        y += 22;

        // 选项一行放两个
        for (NSUInteger i = 0; i < decls.count; i += 2) {
            NSMutableArray<NSDictionary *> *pair = [NSMutableArray array];
            NSMutableArray<NSString *> *pairValues = [NSMutableArray array];
            for (NSUInteger j = i; j < i + 2 && j < decls.count; j++) {
                NSDictionary *decl = decls[j];
                NSString *name = decl[@"name"];
                NSString *value = saved[name];
                if (value.length == 0) value = decl[@"default"];
                if (value.length == 0) value = @"";
                _functionOptionValues[name] = value;
                [pair addObject:decl];
                [pairValues addObject:value];
            }

            UIView *row = [self buildOptionPairRow:pair values:pairValues width:pw];
            row.frame = CGRectMake(4, y, pw - 8, 44);
            [_functionScrollView addSubview:row];
            y += 44 + 6;
        }
    }

    if (decls.count == 0 && _functionNames.count == 0) {
        UILabel *empty = [[UILabel alloc] initWithFrame:CGRectMake(12, 16, pw - 24, 90)];
        empty.numberOfLines = 0;
        empty.font = [UIFont systemFontOfSize:12];
        empty.textColor = [UIColor secondaryLabelColor];
        empty.text = @"这个脚本还没有声明功能或选项。\n在脚本里加一行\n「# @功能 攻击 x=100 y=200」或\n「# @选项 名称 数字 默认=0」\n就会出现（写了哪些参数就出几个输入框）。";
        empty.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [_functionScrollView addSubview:empty];
        y = 110;
    }

    _functionScrollView.contentSize = CGSizeMake(pw, y + 4);
    [_functionScrollView setContentOffset:CGPointZero animated:NO];
    _contentHeight = y + 8;
    [self layoutCard];
}

// 列一层目录，顺序严格照 App 的脚本列表（ScriptListViewController 的 insertFileListIntoArray:）：
// 非 .bdl 的文件夹「插到最前」，其余按系统枚举顺序追加 —— 这样面板里的顺序和 App 里看到的完全一致。
// .bdl 本身是脚本包（也是文件夹），一律当脚本行，不能当文件夹展开。
static NSArray<NSDictionary *> *fnListScriptEntries(NSString *dir) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[];
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (NSString *name in items) {
        if ([name hasPrefix:@"."]) continue;
        NSString *path = [dir stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDir]) continue;
        BOOL isBdl = [[name pathExtension].lowercaseString isEqualToString:@"bdl"];
        if (!isDir && !isBdl) continue;   // 面板只列「文件夹」和「脚本」，普通文件不进来
        NSDate *date = [fm attributesOfItemAtPath:path error:nil][NSFileModificationDate];
        NSDictionary *entry = @{ @"name": name, @"path": path,
                                 @"dir": @(isDir && !isBdl),
                                 @"date": date ?: [NSDate distantPast] };
        if (isDir && !isBdl) [entries insertObject:entry atIndex:0];
        else [entries addObject:entry];
    }
    return entries;
}

// 面板状态存 plist：展开的文件夹 + 全局宽高，下次打开还是这样
- (void)savePanelState {
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    state[@"expanded"] = [_expandedFolders.allObjects sortedArrayUsingSelector:@selector(compare:)];
    if (_panelW > 0) state[@"panel_w"] = @(_panelW);
    if (_panelH > 0) state[@"panel_h"] = @(_panelH);
    [state writeToFile:PANEL_STATE_CONFIG_PATH atomically:YES];
}

// 递归铺目录：文件夹点一下展开 / 收起；脚本行支持左滑删除、长按菜单（复制/导出），
// 行右显示最后编辑时间，名字左边是可视化脚本的总步骤数（按档上色）
- (CGFloat)addScriptEntriesAtDir:(NSString *)dir depth:(NSInteger)depth y:(CGFloat)y width:(CGFloat)pw {
    __weak typeof(self) weakSelf = self;
    CGFloat indent = 8.0f + depth * 18.0f;
    CGFloat rowW = pw - 8.0f;
    CGFloat timeW = 96.0f;

    for (NSDictionary *entry in fnListScriptEntries(dir)) {
        BOOL isFolder = [entry[@"dir"] boolValue];
        NSString *path = entry[@"path"];
        BOOL expanded = isFolder && [_expandedFolders containsObject:path];

        if (isFolder) {
            FNTapView *row = [[FNTapView alloc] initWithFrame:CGRectMake(4, y, rowW, FN_ROW_H)];
            row.backgroundColor = [UIColor secondarySystemBackgroundColor];
            row.layer.cornerRadius = 8;

            UIImageView *arrow = [[UIImageView alloc] initWithFrame:CGRectMake(indent + 8, (FN_ROW_H - 12) / 2.0f, 12, 12)];
            arrow.image = fnSymbol(expanded ? @"chevron.down" : @"chevron.right");
            arrow.tintColor = [UIColor secondaryLabelColor];
            arrow.contentMode = UIViewContentModeScaleAspectFit;
            [row addSubview:arrow];

            UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectMake(indent + 26, (FN_ROW_H - 16) / 2.0f, 16, 16)];
            icon.image = fnSymbol(expanded ? @"folder.fill" : @"folder");
            icon.tintColor = [UIColor systemBlueColor];
            icon.contentMode = UIViewContentModeScaleAspectFit;
            [row addSubview:icon];

            CGFloat nameX = indent + 48.0f;
            UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(nameX, 0, MAX(rowW - nameX - 10.0f, 40.0f), FN_ROW_H)];
            name.text = entry[@"name"];
            name.font = [UIFont systemFontOfSize:13];
            name.textColor = [UIColor labelColor];
            name.adjustsFontSizeToFitWidth = YES;
            name.minimumScaleFactor = 0.8;
            [row addSubview:name];

            row.onTap = ^{
                FunctionWindow *window = weakSelf;
                if (!window) return;
                if (expanded) [window->_expandedFolders removeObject:path];
                else [window->_expandedFolders addObject:path];
                [window savePanelState];
                [window reloadScriptPicker];
            };

            [_functionScrollView addSubview:row];
            y += FN_ROW_H + FN_ROW_GAP;
            if (expanded) y = [self addScriptEntriesAtDir:path depth:depth + 1 y:y width:pw];
            continue;
        }

        // ---- 脚本行 ----
        FNScriptRowView *row = [[FNScriptRowView alloc] initWithFrame:CGRectMake(4, y, rowW, FN_ROW_H)];
        // 当前选中的脚本用浅色标出来，下次进列表一眼看到
        if ([path isEqualToString:_functionScriptPath]) {
            row.content.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.14];
        }

        // 步数在最左边（占文件夹箭头那格），然后才是图标和文件名
        NSInteger stepCount = fnFlowStepCount(path);
        CGFloat countX = indent + 6.0f;
        CGFloat countW = 34.0f;
        if (stepCount >= 0) {
            UILabel *count = [[UILabel alloc] initWithFrame:CGRectMake(countX, 0, countW, FN_ROW_H)];
            count.text = [NSString stringWithFormat:@"%ld步", (long)stepCount];
            count.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightSemibold];
            count.textColor = fnStepCountColor(stepCount);
            count.adjustsFontSizeToFitWidth = YES;
            count.minimumScaleFactor = 0.8;
            [row.content addSubview:count];
        }

        UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectMake(countX + countW + 2.0f,
                                                                          (FN_ROW_H - 16) / 2.0f, 16, 16)];
        icon.image = fnSymbol(@"doc.text.fill");
        icon.tintColor = [UIColor secondaryLabelColor];
        icon.contentMode = UIViewContentModeScaleAspectFit;
        [row.content addSubview:icon];

        CGFloat nameX = countX + countW + 2.0f + 16.0f + 4.0f;
        CGFloat nameW = rowW - nameX - 10.0f - (timeW + 8.0f);
        UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(nameX, 0, MAX(nameW, 40.0f), FN_ROW_H)];
        name.text = entry[@"name"];   // 保留 .bdl 后缀，和文件 App 里看到的名字一致
        name.font = [UIFont systemFontOfSize:13];
        name.textColor = [UIColor labelColor];
        name.adjustsFontSizeToFitWidth = YES;
        name.minimumScaleFactor = 0.8;
        [row.content addSubview:name];

        UILabel *time = [[UILabel alloc] initWithFrame:CGRectMake(rowW - 10.0f - timeW, 0, timeW, FN_ROW_H)];
        time.text = fnDateText(entry[@"date"]);
        time.font = [UIFont systemFontOfSize:11];
        time.textColor = [UIColor secondaryLabelColor];
        time.textAlignment = NSTextAlignmentRight;
        [row.content addSubview:time];

        __weak FNScriptRowView *weakRow = row;
        row.onTap = ^{
            FunctionWindow *window = weakSelf;
            if (!window) return;
            [window selectFunctionScript:path];
        };
        row.onDelete = ^{
            FunctionWindow *window = weakSelf;
            if (!window) return;
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            // 删掉的如果正是当前选中的脚本，把选择也清掉，免得面板还去读一个已不存在的包
            if ([path isEqualToString:window->_functionScriptPath]) window->_functionScriptPath = nil;
            [window reloadScriptPicker];
        };
        row.onMenu = ^{
            FunctionWindow *window = weakSelf;
            if (!window) return;
            [window showScriptActionMenuForPath:path anchor:weakRow];
        };

        [_functionScrollView addSubview:row];
        y += FN_ROW_H + FN_ROW_GAP;
    }
    return y;
}

// 挑脚本模式：按文件夹层级列出脚本目录里所有 .bdl 供选择
- (void)reloadScriptPicker {
    if (!_window) return;
    CGFloat pw = [self cardWidth];

    [_cardView endEditing:YES];
    // 正在挑脚本：左上角不能还挂着上一个脚本的名字，容易让人以为点的是它
    [_functionScriptBtn setTitle:@"选择脚本" forState:UIControlStateNormal];
    for (UIView *v in _functionScrollView.subviews) [v removeFromSuperview];

    CGFloat y = [self addScriptEntriesAtDir:getScriptsFolder() depth:0 y:6 width:pw];

    if (y <= 6.5f) {
        UILabel *empty = [[UILabel alloc] initWithFrame:CGRectMake(12, 16, pw - 24, 40)];
        empty.numberOfLines = 0;
        empty.font = [UIFont systemFontOfSize:12];
        empty.textColor = [UIColor secondaryLabelColor];
        empty.text = @"脚本目录里还没有 .bdl 文件。";
        [_functionScrollView addSubview:empty];
        y = 60;
    }

    _functionScrollView.contentSize = CGSizeMake(pw, y + 4);
    [_functionScrollView setContentOffset:CGPointZero animated:NO];
    _contentHeight = y + 8;
    [self layoutCard];
}

#pragma mark - 脚本选择

- (void)beginScriptPicking {
    [_cardView endEditing:YES];
    _pickingScript = YES;
    [self reloadCurrentPage];
}

- (void)selectFunctionScript:(NSString *)path {
    [_cardView endEditing:YES];
    [self persistAllValues];
    _pickingScript = NO;
    _functionScriptPath = [path copy];
    ZXSaveLastFunctionScriptPath(_functionScriptPath);
    // 可视化脚本（包里有 flow.plist）没有「功能」可勾，直接进流程编辑；手写脚本才看功能页
    if ([FlowScript bundleHasFlow:path]) {
        [self enterFlowMode];
        return;
    }
    _panelMode = FNPanelModeFunctions;
    [self reloadFunctionPage];
}

// 切到流程编辑：功能页留下的参数值是别的脚本的，清掉免得被写进可视化脚本的配置
- (void)enterFlowMode {
    _panelMode = FNPanelModeFlow;
    _flowCanGoBack = NO;
    _functionNames = @[];
    _functionSwitches = nil;
    _functionOptionValues = [NSMutableDictionary dictionary];
    _functionParamValues = [NSMutableDictionary dictionary];
    [[FlowWindow shared] setHost:self];
    [[FlowWindow shared] loadBundle:_functionScriptPath];
    [self layoutCard];
}

// 打开某个可视化脚本包并显示面板（面板里点脚本、App 发 44 命令都走这里）
- (void)openFlowBundle:(NSString *)bundlePath {
    ZXSafeMainAsync(^{
        if (bundlePath.length == 0) return;
        [self ensureWindow];
        if (!self->_window) return;
        self->_shown = YES;
        self->_pickingScript = NO;
        self->_functionScriptPath = [bundlePath copy];
        ZXSaveLastFunctionScriptPath(self->_functionScriptPath);
        [[FlowWindow shared] setHost:self];
        [self enterFlowMode];
        [self refreshRecordingButton];
        self->_window.hidden = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_shown) [self layoutCard];
        });
    });
}

// 新建可视化脚本包并直接打开编辑器（挑脚本时的「＋」与 App 的 44;;new;; 都走这里）
- (void)createFlowScriptAtPath:(NSString *)bundlePath {
    ZXSafeMainAsync(^{
        NSError *error = nil;
        if (![FlowScript createVisualScriptAtPath:bundlePath error:&error]) {
            showAlertBox(@"错误", error.localizedDescription ?: @"创建失败。", 999);
            return;
        }
        [self openFlowBundle:bundlePath];
    });
}

// 挑脚本时点「＋」：按 App 同样的命名规则新建一个可视化脚本包，建完直接开编辑器
- (void)createVisualScriptHere {
    NSString *folder = getScriptsFolder();
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"yyyyMMdd_HHmmss"];
    NSString *name = [fmt stringFromDate:[NSDate date]];

    NSString *path = [[folder stringByAppendingPathComponent:name] stringByAppendingPathExtension:@"bdl"];
    // 同一秒里连点两下（基本不会发生）就往后加 -2、-3，保证不重名
    NSInteger seq = 2;
    while ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        path = [[folder stringByAppendingPathComponent:
                 [NSString stringWithFormat:@"%@-%ld", name, (long)seq++]] stringByAppendingPathExtension:@"bdl"];
    }
    [self createFlowScriptAtPath:path];
}

#pragma mark - 脚本的 新建 / 导入 / 复制 / 导出

// 导入导出的固定文件夹：SpringBoard 里用不了系统文件选择器，就用这个目录中转
static NSString *fnImportExportFolder(void) {
    return @"/var/mobile/Library/ZXTouch/导入导出";
}

// 顶行「＋」：随行小菜单（不是强弹窗）
- (void)showNewScriptMenu {
    __weak typeof(self) weakSelf = self;
    ZXShowMiniMenuNearView(_newScriptBtn, @[
        @{ @"title": @"新建脚本", @"icon": @"plus", @"action": ^{
            [weakSelf createVisualScriptHere];
        } },
        @{ @"title": @"导入脚本", @"icon": @"square.and.arrow.down", @"action": ^{
            [weakSelf importScriptHere];
        } },
    ]);
}

// 列出「导入导出」文件夹里的 .bdl，选一个拷进脚本目录
- (void)importScriptHere {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = fnImportExportFolder();
    NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[];
    NSMutableArray<NSString *> *bundles = [NSMutableArray array];
    for (NSString *name in items) {
        if ([name hasPrefix:@"."]) continue;
        if ([[name pathExtension].lowercaseString isEqualToString:@"bdl"]) [bundles addObject:name];
    }
    if (bundles.count == 0) {
        showAlertBox(@"导入脚本",
                     [NSString stringWithFormat:@"把 .bdl 脚本包放进：\n%@\n再点「导入脚本」。", dir], 4);
        return;
    }

    __weak typeof(self) weakSelf = self;
    NSMutableArray<NSDictionary *> *menuItems = [NSMutableArray array];
    for (NSString *name in bundles) {
        [menuItems addObject:@{ @"title": [name stringByDeletingPathExtension],
                                @"icon": @"doc.text.fill",
                                @"action": ^{
            FunctionWindow *window = weakSelf;
            if (!window) return;
            NSString *src = [dir stringByAppendingPathComponent:name];
            NSString *base = [name stringByDeletingPathExtension];
            NSString *dest = [[getScriptsFolder() stringByAppendingPathComponent:base]
                              stringByAppendingPathExtension:@"bdl"];
            NSInteger seq = 2;
            while ([[NSFileManager defaultManager] fileExistsAtPath:dest]) {
                dest = [[getScriptsFolder() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"%@-%ld", base, (long)seq++]] stringByAppendingPathExtension:@"bdl"];
            }
            NSError *err = nil;
            if ([[NSFileManager defaultManager] copyItemAtPath:src toPath:dest error:&err]) {
                [window reloadScriptPicker];
            } else {
                showAlertBox(@"错误", [NSString stringWithFormat:@"导入失败：%@", err.localizedDescription], 999);
            }
        } }];
    }
    ZXShowMiniMenuNearView(_newScriptBtn, menuItems);
}

// 长按脚本行：复制 / 导出
- (void)showScriptActionMenuForPath:(NSString *)path anchor:(UIView *)anchor {
    if (!anchor) return;
    __weak typeof(self) weakSelf = self;
    ZXShowMiniMenuNearView(anchor, @[
        @{ @"title": @"复制", @"icon": @"doc.on.doc", @"action": ^{
            [weakSelf duplicateScriptAtPath:path];
        } },
        @{ @"title": @"导出", @"icon": @"square.and.arrow.up", @"action": ^{
            [weakSelf exportScriptAtPath:path];
        } },
    ]);
}

// 在同目录复制一份「名称 副本.bdl」（重名就 副本2、副本3）
- (void)duplicateScriptAtPath:(NSString *)path {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [path stringByDeletingLastPathComponent];
    NSString *base = [[path lastPathComponent] stringByDeletingPathExtension];
    NSString *copy = [[dir stringByAppendingPathComponent:[base stringByAppendingString:@" 副本"]]
                      stringByAppendingPathExtension:@"bdl"];
    NSInteger seq = 2;
    while ([fm fileExistsAtPath:copy]) {
        copy = [[dir stringByAppendingPathComponent:
                 [NSString stringWithFormat:@"%@ 副本%ld", base, (long)seq++]] stringByAppendingPathExtension:@"bdl"];
    }
    NSError *err = nil;
    if ([fm copyItemAtPath:path toPath:copy error:&err]) {
        [self reloadScriptPicker];
    } else {
        showAlertBox(@"错误", [NSString stringWithFormat:@"复制失败：%@", err.localizedDescription], 999);
    }
}

// 导出 = 拷进「导入导出」文件夹（同名直接覆盖，导出就是为了带走）
- (void)exportScriptAtPath:(NSString *)path {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = fnImportExportFolder();
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dest = [dir stringByAppendingPathComponent:[path lastPathComponent]];
    if ([fm fileExistsAtPath:dest]) [fm removeItemAtPath:dest error:nil];
    NSError *err = nil;
    if ([fm copyItemAtPath:path toPath:dest error:&err]) {
        showAlertBox(@"已导出", [NSString stringWithFormat:@"文件在：\n%@", dest], 3);
    } else {
        showAlertBox(@"错误", [NSString stringWithFormat:@"导出失败：%@", err.localizedDescription], 999);
    }
}

// 按当前状态重画内容：挑脚本 / 功能页 / 流程编辑，三选一
- (void)reloadCurrentPage {
    if (!_window) return;
    if (_pickingScript) {
        [self reloadScriptPicker];
        return;
    }
    if (_panelMode == FNPanelModeFlow) {
        [[FlowWindow shared] setHost:self];
        [[FlowWindow shared] refresh];
        [self layoutCard];
        return;
    }
    [self reloadFunctionPage];
}

#pragma mark - 把面板借给流程编辑器（FlowEditorHost）

- (UIScrollView *)flowHostScrollView { return _functionScrollView; }
- (CGFloat)flowHostContentWidth { return [self cardWidth]; }
// 窗口的根视图铺满整屏且在卡片之上：底部半屏「添加步骤」挂这里才不会卡片裁剪
- (UIView *)flowHostOverlayContainer { return _window.rootViewController.view; }

- (void)flowHostSetNavigationTitle:(NSString *)title canGoBack:(BOOL)canGoBack {
    _flowCanGoBack = canGoBack;
    // 流程子页左键 = 返回；根页左键 = 挑脚本（和功能页一致）
    [_functionScriptBtn setTitle:(canGoBack ? [NSString stringWithFormat:@"← %@", title]
                                            : [NSString stringWithFormat:@"脚本：%@", title])
                        forState:UIControlStateNormal];
    [self layoutCard];   // 「预览」只在流程根页显示
}

- (void)flowHostSetCardHidden:(BOOL)hidden {
    _cardView.hidden = hidden;
}

#pragma mark - 运行

- (void)runFunctionSelection {
    if (_functionScriptPath.length == 0) {
        showAlertBox(@"提示", @"请先点顶部的「脚本」选一个脚本。", 2);
        return;
    }

    [_cardView endEditing:YES];
    [self persistAllValues];

    NSArray<NSString *> *picked = [self pickedFunctionNames];
    // 只有声明了功能的脚本才要求至少勾一个（只声明选项的脚本可以直接运行）
    if (_functionNames.count > 0 && picked.count == 0) {
        showAlertBox(@"提示", @"请至少勾选一个功能。", 2);
        return;
    }

    ZXSaveScriptFunctionSelection(_functionScriptPath, picked);
    ZXSaveLastFunctionScriptPath(_functionScriptPath);

    NSString *scriptPath = [_functionScriptPath copy];
    [self hide];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *err = nil;
        playScriptWithSettings((UInt8 *)[scriptPath UTF8String], 0, 1.0f, 0.0f, &err);
        if (err) showAlertBox(@"错误", [err localizedDescription], 999);
    });
}

#pragma mark - 录制

// 顶行的录制开关，和音量键的「开始/停止录制」调用同一对引擎函数，录完同样存进 scripts/录制脚本/
// 点完就关面板：录制要录的是游戏里的点按，面板挂在上面既挡画面、点它也会被录进去
- (void)toggleRecording {
    if (isRecordingStart()) {
        stopRecording();
        showAlertBox(@"小新Lap", @"录制已停止并保存。", 1);
    } else {
        NSError *err = nil;
        startRecording(0, &err);
        if (err) showAlertBox(@"错误", [NSString stringWithFormat:@"无法开始录制：%@", [err localizedDescription]], 999);
        else showAlertBox(@"小新Lap", @"录制已开始。", 1);
    }
    [self refreshRecordingButton];
    [self hide];
}

// 录制可能是在网页端 / 音量键起的，所以每次开面板都按真实状态重算按钮，不能只记本地开关
- (void)refreshRecordingButton {
    BOOL recording = isRecordingStart();
    [_recordBtn setTitle:(recording ? @"停止" : @"录制") forState:UIControlStateNormal];
    _recordBtn.backgroundColor = recording ? [[UIColor systemRedColor] colorWithAlphaComponent:0.20f]
                                           : [UIColor secondarySystemBackgroundColor];
}

#pragma mark - 显示 / 隐藏

- (void)show {
    _shown = YES;
    ZXSafeMainAsync(^{
        [self ensureWindow];
        if (!self->_window) return;

        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL valid = self->_functionScriptPath.length > 0 && [fm fileExistsAtPath:self->_functionScriptPath];
        if (!valid) {
            NSString *last = ZXLastFunctionScriptPath();
            if (last.length > 0 && [fm fileExistsAtPath:last]) {
                self->_functionScriptPath = last;
                valid = YES;
            }
        }
        if (!valid) self->_functionScriptPath = ZXFirstScriptPathWithFunctions();

        self->_pickingScript = NO;
        // 可视化脚本没有「功能」可勾，直接进流程编辑；手写脚本才看功能页
        if (self->_functionScriptPath.length > 0 && [FlowScript bundleHasFlow:self->_functionScriptPath]) {
            [self enterFlowMode];
        } else {
            self->_panelMode = FNPanelModeFunctions;
            [self reloadFunctionPage];
        }
        [self refreshRecordingButton];   // 录制可能在面板关着的时候被别人起停过
        self->_window.hidden = NO;

        // window 刚创建时 bounds 可能是 CGRectZero，layoutCard 会退回用 UIScreen.bounds；
        // 等下一帧 scene 把 bounds 摆正后再量一次，保证卡片居中（本项目踩过的坑）
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self->_shown) return;
            [self layoutCard];
        });
    });
}

// 关闭面板。「保存」走 saveAndHide；✕ 直接调这里，不额外存盘
- (void)hide {
    _shown = NO;
    [[FlowWindow shared] hideOverlays];   // 编辑器弹的半屏「添加步骤」挂在窗口根上，不跟着卡片一起消失
    ZXSafeMainAsync(^{
        if (!self->_window) return;
        [self->_cardView endEditing:YES];
        self->_window.hidden = YES;
    });
}

- (BOOL)isShown { return _shown; }

- (void)setAppearanceMode:(NSInteger)mode {
    _appearanceMode = mode;
    ZXSafeMainAsync(^{
        if (self->_window) self->_window.overrideUserInterfaceStyle = (UIUserInterfaceStyle)mode;
    });
}

@end