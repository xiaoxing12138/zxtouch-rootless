#import "FloatingMenu.h"
#import "Common.h"
#import "Screen.h"
#import "Play.h"
#import "Toast.h"
#import "AlertBox.h"
#import "Process.h"
#import <QuartzCore/QuartzCore.h>
#include <roothide.h>

/*
 * 按键精灵式悬浮控制按钮（v2）
 * -------------------------
 * 窗口模型（与 NetSpeedIndicator / 触摸指示器同源）：
 *   - UIWindow 占满竖屏固定坐标空间（短边宽 W、长边高 H），window 不旋转；
 *   - rootView 是 hitTest 透传视图：空白处触摸全部落到下层 app，
 *     只有圆点 / 菜单按钮命中时才拦截，所以全屏 window 也不会挡操作；
 *   - contentView 按当前方向旋转，内部全部用「视觉坐标」(原点=视觉左上)，
 *     边缘吸附、菜单展开方向都在视觉空间计算，任意方向行为一致。
 *
 * 交互：
 *   - 收起态：48pt 圆点自动吸附视觉左/右边缘，只露一半（center 在边线），
 *     随时可拖；松手按离哪条竖边近重新吸附并持久化；
 *   - 点圆点：在靠屏幕内侧展开「启动 / 设置 / 返回」（纵向朝空间足的一侧排）；
 *   - 位置以「贴哪边 + 纵向比例」持久化，旋转后位置自然正确。
 *
 * 健壮性：
 *   - 方向用 [Screen getScreenOrientation]（最前台 app 方向，iPad 可靠），
 *     状态栏方向通知 + 1 秒轮询双重检测；
 *   - 1 秒自检：window 丢了就重建、被系统 hidden 就恢复、scene 失效就重挂，
 *     杜绝"显示一秒后消失"。
 */

// 圆点尺寸改为可配置（设置页滑块 32..80pt），默认 48pt。
// 吸附时圆点中心距屏幕边缘恒等于半径 → 永远「完全贴边全显示」。
#define kFMDotDefaultSize 48.0f
#define kFMDotMinSize     32.0f
#define kFMDotMaxSize     80.0f
#define kFMMenuBtnSize    44.0f   // 菜单圆形图标按钮尺寸
#define kFMMenuPanelGap   8.0f    // 圆点到菜单面板间距
#define kFMMenuBtnGap     4.0f    // 菜单圆形按钮之间的间距
#define kFMMenuLabelGap   2.0f    // 圆形按钮到下方标签间距
#define kFMAnim           0.18

#define kFMCfgEnabled     @"floating_menu_enabled"
#define kFMCfgEdge        @"floating_menu_edge"       // 1=贴右 0=左
#define kFMCfgYRatio      @"floating_menu_y_ratio"   // 纵向位置 0..1
#define kFMCfgScript      @"floating_menu_script"
#define kFMCfgIconPath    @"floating_menu_icon_path"  // 用户自定义图标文件路径（nil=用 app 图标）
#define kFMCfgDotSize     @"floating_menu_dot_size"   // 圆点大小 32..80
#define kFMCfgMenuBtnSize @"floating_menu_menu_size"  // 菜单按钮大小 32..72
#define kFMZXTouchBID     @"com.zjx.zxtouch"

#pragma mark - 透传视图 / 透传窗口 / 根控制器

@interface FMPassthroughView : UIView
@end

@implementation FMPassthroughView
// 只有真正落在按钮/圆点上的触摸才拦截，空白处一律放行给下层 app
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}
@end

@implementation FMPassthroughWindow {
    BOOL _portraitLockEnabled;
}

// ----------- 架构说明（2026-09-30 修正） -----------
// 旧版 setFrame 强制锁 portrait 尺寸 (820×1180) 导致横屏 window.width 只有 820，
// iPad 横屏屏幕 1180×820，右侧 360pt 没有被 window 覆盖，触摸事件丢失。
//
// 新版：让 scene 管 self.frame（跟随方向自动变），不拦截。
// portraitFrame 只作为内部 portrait 容器的尺寸信息，供调用方用 transform 旋转 + 居中。
// ---------------------------------------------------

- (instancetype)initWithWindowScene:(UIWindowScene *)windowScene {
    self = [super initWithWindowScene:windowScene];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }
    return self;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }
    return self;
}

- (void)setPortraitFrame:(CGRect)portraitFrame {
    _portraitFrame = portraitFrame;
    _portraitLockEnabled = !CGRectIsEmpty(portraitFrame);
    [self setNeedsLayout];
}

// 不再拦截 setFrame —— 让 scene 管，window.frame 跟随方向变化
// 横屏 window.frame 自动变成 (0,0,1180,820)，覆盖整个屏幕

- (void)layoutSubviews {
    [super layoutSubviews];
    // 确保 rootViewController.view 填满 window（系统可能会 reset）
    if (self.rootViewController && !CGRectEqualToRect(self.rootViewController.view.frame, self.bounds)) {
        self.rootViewController.view.frame = self.bounds;
    }
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}
@end

@interface FMRootViewController : UIViewController
@end

@implementation FMRootViewController
- (void)loadView
{
    FMPassthroughView *rootView = [[FMPassthroughView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    rootView.backgroundColor = [UIColor clearColor];
    rootView.multipleTouchEnabled = NO;
    self.view = rootView;
}
@end

static FloatingMenu *_fmShared = nil;

#pragma mark - C helpers

static CGAffineTransform fmTransformForOrientation(int orientation)
{
    // content 旋转角度（与 NetSpeedIndicator 一致）：
    // LandscapeLeft → -M_PI_2，LandscapeRight → M_PI_2
    switch (orientation) {
        case UIInterfaceOrientationLandscapeLeft:
            return CGAffineTransformMakeRotation(-M_PI_2);
        case UIInterfaceOrientationLandscapeRight:
            return CGAffineTransformMakeRotation(M_PI_2);
        case UIInterfaceOrientationPortraitUpsideDown:
            return CGAffineTransformMakeRotation(M_PI);
        default:
            return CGAffineTransformIdentity;
    }
}

static void fmToast(NSString *content, int type)
{
    [Toast showToastWithContent:content type:type duration:1.8f position:1 fontSize:14];
}

static NSString *fmConfigPath(void)
{
    return getCommonConfigFilePath();
}

// 小体量 plist 写入放后台队列，避免拖动结束时卡主线程
static void fmPersistKeys(NSDictionary *pairs)
{
    if (pairs.count == 0) {
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            @try {
                NSString *path = fmConfigPath();
                NSMutableDictionary *config = [[NSMutableDictionary alloc] initWithContentsOfFile:path];
                if (!config) {
                    config = [NSMutableDictionary dictionary];
                }
                [config addEntriesFromDictionary:pairs];
                [config writeToFile:path atomically:YES];
            } @catch (NSException *exception) {
                ZXLogUIException(exception);
            }
        }
    });
}

#pragma mark - FloatingMenu

@interface FloatingMenu () {
    FMPassthroughWindow      *_window;
    UIView                   *_content;
    UIButton                 *_dotButton;
    UIView                   *_menuPanel;        // 白色半透明面板（菜单容器）
    NSMutableArray<UIButton *> *_menuButtons; // 启动 / 设置 / 返回（圆形图标按钮）
    NSMutableArray<UILabel *>  *_menuLabels;  // 对应下方文字标签
    NSTimer                  *_watchTimer;

    BOOL     _enabled;
    BOOL     _expanded;
    BOOL     _dragging;
    BOOL     _observing;
    BOOL     _menuAnimating;   // 展开/收起动画中，防止 toggle 混乱
    NSInteger _menuUp;        // 1 = 菜单按钮排在圆点上方；-1 = 下方；0 = 收起
    int      _edge;           // 1 右 / 0 左
    CGFloat  _yRatio;         // 圆点纵向位置比例
    CGFloat  _dotSize;        // 圆点直径 pt（32..80，配置驱动）
    int      _lastOrientation;

    CGPoint  _dragStartVisual;
    NSString *_scriptPath;
}

- (void)applyGeometry;
- (void)expandMenu;
- (void)collapseMenu;

@end

@implementation FloatingMenu

- (instancetype)init
{
    self = [super init];
    if (self) {
        _dotSize = kFMDotDefaultSize;
    }
    return self;
}

+ (instancetype)shared
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _fmShared = [[FloatingMenu alloc] init];
    });
    return _fmShared;
}

+ (void)setEnabled:(BOOL)enabled
{
    [[self shared] setEnabled:enabled persist:YES];
}

+ (BOOL)isEnabled
{
    return [[self shared] boolEnabled];
}

+ (void)reloadConfig
{
    [[self shared] reloadConfig];
}

- (BOOL)boolEnabled
{
    return _enabled;
}

#pragma mark 视觉坐标工具

// 圆点半径。吸附时圆点中心距屏幕边缘恒等于半径，因此不论多大都「完全贴边全显示」。
- (CGFloat)dotRadius
{
    return _dotSize / 2.0f;
}

// 圆点内字母随直径等比缩放，保持默认 48pt → 22pt 的视觉比例
- (CGFloat)dotTitleFontSize
{
    return roundf(_dotSize * (22.0f / kFMDotDefaultSize));
}

- (void)canvasPortraitWidth:(CGFloat *)width height:(CGFloat *)height
{
    CGRect bounds = [Screen getBounds];
    CGFloat w = MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    CGFloat h = MAX(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    if (w <= 0) { w = 375.0f; }
    if (h <= 0) { h = 667.0f; }
    if (width)  { *width = w; }
    if (height) { *height = h; }
}

- (int)currentOrientation
{
    int o = [Screen getScreenOrientation];
    switch (o) {
        case UIInterfaceOrientationPortrait:
        case UIInterfaceOrientationPortraitUpsideDown:
        case UIInterfaceOrientationLandscapeLeft:
        case UIInterfaceOrientationLandscapeRight:
            return o;
        default:
            return UIInterfaceOrientationPortrait;
    }
}

// 视觉尺寸（宽始终沿视觉水平方向）
- (void)visualWidth:(CGFloat *)visW height:(CGFloat *)visH portrait:(CGRect *)portrait
{
    // 优先用 window.bounds（已被 scene 管理，跟随方向），
    // 但 window 刚创建时 bounds 可能还是 zero（scene 还没 layout），
    // 此时 fallback 到 UIScreen.mainScreen.bounds（总是 portrait 尺寸，
    // 竖屏正确；横屏时 buildWindow 延迟一帧会再次调 applyGeometry）。
    CGRect wb = _window ? _window.bounds : CGRectZero;
    if (wb.size.width == 0 || wb.size.height == 0) {
        wb = [Screen getBounds];
    }
    if (visW) { *visW = wb.size.width; }
    if (visH) { *visH = wb.size.height; }
    if (portrait) { *portrait = wb; }
}

// 圆点在视觉坐标系的中心
- (CGPoint)dotVisualPoint
{
    CGFloat visW, visH;
    [self visualWidth:&visW height:&visH portrait:NULL];
    CGFloat radius = [self dotRadius];
    CGFloat y = _yRatio * visH;
    y = MIN(MAX(y, radius + 2.0f), visH - radius - 2.0f);
    // 中心距边缘 = 半径 → 圆点完全贴边且完整显示
    CGFloat x = (_edge == 0) ? radius : (visW - radius);
    return CGPointMake(x, y);
}

// rootView 坐标系下的位移 → 视觉坐标系下的位移
// LandscapeLeft: 设备顺时针 90°（用户视角），rootView +x = 视觉 -y，rootView +y = 视觉 +x
// LandscapeRight: 设备逆时针 90°（用户视角），rootView +x = 视觉 +y，rootView +y = 视觉 -x
- (CGPoint)visualTranslationFromRootView:(CGPoint)t orientation:(int)orientation
{
    // 简化：rootView.frame = window.bounds，rootView 坐标即 window 坐标，无需方向转换
    return t;
}

#pragma mark window 构建

+ (UIWindowScene *)preferredWindowScene
{
    UIWindowScene *fallback = nil;
    @try {
        NSSet<UIScene *> *scenes = [UIApplication sharedApplication].connectedScenes;
        for (UIScene *scene in scenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                return (UIWindowScene *)scene;
            }
            if (!fallback) {
                fallback = (UIWindowScene *)scene;
            }
        }
    } @catch (NSException *exception) {
        ZXLogUIException(exception);
    }
    return fallback;
}

- (void)buildWindow
{
    // SpringBoard 启动早期 scene 可能还没 ready（所有 scene 都是 inactive），
    // 此时 initWithFrame 创建的 window 在 iOS 13+ 上不会显示。
    // 延迟 0.5s 重试，让 watchdog 在 scene ready 后自动成功。
    UIWindowScene *scene = [FloatingMenu preferredWindowScene];
    if (!scene) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5f * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (self->_enabled && !self->_window) {
                [self buildWindow];
            }
        });
        // 先用 initWithFrame 创建占位 window（watchdog 每 1s 重试）
        _window = [[FMPassthroughWindow alloc] initWithFrame:CGRectZero];
    } else {
        _window = [[FMPassthroughWindow alloc] initWithWindowScene:scene];
    }
    _window.windowLevel = UIWindowLevelStatusBar + 2;

    FMRootViewController *root = [[FMRootViewController alloc] init];
    _window.rootViewController = root;

    // _content：FMPassthroughView 空白处穿透，跟随 window.bounds 变化
    _content = [[FMPassthroughView alloc] init];
    _content.backgroundColor = [UIColor clearColor];
    _content.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root.view addSubview:_content];

    // 圆点
    _dotButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _dotButton.frame = CGRectMake(0, 0, _dotSize, _dotSize);
    _dotButton.backgroundColor = [UIColor colorWithRed:20.0f / 255.0f
                                                green:20.0f / 255.0f
                                                 blue:28.0f / 255.0f
                                                alpha:0.82f];
    _dotButton.layer.cornerRadius = [self dotRadius];
    _dotButton.titleLabel.font = [UIFont systemFontOfSize:[self dotTitleFontSize] weight:UIFontWeightBold];
    [_dotButton setTitle:@"Z" forState:UIControlStateNormal];
    [_dotButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _dotButton.adjustsImageWhenHighlighted = NO;
    [_content addSubview:_dotButton];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(handleDotPan:)];
    pan.maximumNumberOfTouches = 1;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(handleDotTap:)];
    [tap requireGestureRecognizerToFail:pan];
    [_dotButton addGestureRecognizer:pan];
    [_dotButton addGestureRecognizer:tap];

    // 菜单：三个独立圆形按钮 + 下方文字标签（仿按键精灵，无容器面板）
    _menuButtons = [NSMutableArray array];
    _menuLabels  = [NSMutableArray array];
    _menuPanel = nil;  // 不再需要白色容器面板

    CGFloat btnSize  = 36;   // 图标放大
    CGFloat btnGap   = 6;    // 间距缩小
    CGFloat labelH   = 14;
    CGFloat btnLabelGap = 2;
    CGFloat rowH     = btnSize + btnLabelGap + labelH;

    NSArray *symbolNames = @[@"play.fill", @"gearshape.fill", @"arrow.uturn.backward.circle.fill"];
    NSArray *titles      = @[@"启动", @"设置", @"返回"];

    for (NSUInteger i = 0; i < 3; i++) {
        UIButton *iconBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        iconBtn.frame = CGRectMake(0, 0, btnSize, btnSize);
        iconBtn.backgroundColor = [UIColor colorWithWhite:0.12f alpha:0.92f];  // 黑底
        iconBtn.layer.cornerRadius = btnSize / 2.0f;
        iconBtn.hidden = YES;
        iconBtn.alpha = 0.0f;
        if (@available(iOS 13.0, *)) {
            [iconBtn setImage:[UIImage systemImageNamed:symbolNames[i]] forState:UIControlStateNormal];
            iconBtn.tintColor = [UIColor whiteColor];  // 白色图标
            iconBtn.imageEdgeInsets = UIEdgeInsetsMake(5, 5, 5, 5);
        }
        [iconBtn addTarget:self action:@selector(handleMenuIconTap:) forControlEvents:UIControlEventTouchUpInside];
        [_content addSubview:iconBtn];
        [_menuButtons addObject:iconBtn];

        UILabel *lbl = [[UILabel alloc] init];
        lbl.text = titles[i];
        lbl.font = [UIFont systemFontOfSize:12.0f];   // 字号放大
        lbl.textColor = [UIColor whiteColor];          // 白色文字
        lbl.textAlignment = NSTextAlignmentCenter;
        lbl.frame = CGRectMake(0, 0, btnSize, labelH);
        lbl.backgroundColor = [UIColor colorWithWhite:0.12f alpha:0.92f];  // 黑底
        lbl.hidden = YES;
        lbl.alpha = 0.0f;
        lbl.layer.cornerRadius = 4;
        lbl.layer.masksToBounds = YES;
        [_content addSubview:lbl];
        [_menuLabels addObject:lbl];
    }

    _lastOrientation = [self currentOrientation];

    // 先做一次初步定位（window.bounds 可能还是 zero，visualWidth 会 fallback）
    [self applyGeometry];

    _window.hidden = NO;

    // 关键：dispatch 到下一个 runloop，让 scene 先把 window.bounds 设为
    // 正确的全屏尺寸（横屏 1180×820 / 竖屏 820×1180），再用真实 bounds 重定位
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [self applyGeometry];
        } @catch (NSException *exception) {
            ZXLogUIException(exception);
        }
    });
}

#pragma mark 几何布局（主线程，视觉坐标）

- (void)applyGeometry
{
    if (!_window || !_content || !_dotButton) {
        return;
    }

    CGRect portrait;
    CGFloat visW, visH;
    [self visualWidth:&visW height:&visH portrait:&portrait];
    int orientation = [self currentOrientation];
    _lastOrientation = orientation;

    _content.frame = _window.bounds;
    _content.transform = CGAffineTransformIdentity;

    CGPoint dot;
    if (_dragging && _dotButton.superview) {
        // 拖动中用当前位置，不要覆盖 pan.Changed 里设的值
        dot = _dotButton.center;
    } else {
        dot = [self dotVisualPoint];
        CGFloat radius = [self dotRadius];
        _dotButton.transform = CGAffineTransformIdentity;
        _dotButton.frame = CGRectMake(dot.x - radius, dot.y - radius, _dotSize, _dotSize);
    }

    CGFloat dotRadius = [self dotRadius];

    if (_expanded) {
        // 三个按钮+标签的整体尺寸
        CGFloat btnSize  = 32;
        CGFloat btnGap   = 10;
        CGFloat labelH   = 12;
        CGFloat btnLabelGap = 2;
        CGFloat totalBtnW = btnSize * 3 + btnGap * 2;
        CGFloat rowH      = btnSize + btnLabelGap + labelH;

        // 横向位置：贴右 → 按钮在圆点左边；贴左 → 按钮在圆点右边
        CGFloat firstBtnX;
        if (_edge == 0) {
            firstBtnX = dot.x + dotRadius + kFMMenuPanelGap;
        } else {
            firstBtnX = dot.x - dotRadius - kFMMenuPanelGap - totalBtnW;
        }

        // 纵向：整体居中对齐圆点中心
        CGFloat startY = dot.y - rowH / 2.0f;

        for (NSUInteger i = 0; i < 3; i++) {
            CGFloat bx = firstBtnX + i * (btnSize + btnGap);
            CGFloat by = startY;
            CGFloat ly = by + btnSize + btnLabelGap;
            if (i < _menuButtons.count) {
                UIButton *b = _menuButtons[i];
                // 先重置 transform（关键！transform 非 identity 时 frame 值不可靠）
                b.transform = CGAffineTransformIdentity;
                b.alpha = 1.0f;
                b.frame = CGRectMake(bx, by, btnSize, btnSize);
                b.hidden = NO;
            }
            if (i < _menuLabels.count) {
                UILabel *l = _menuLabels[i];
                l.transform = CGAffineTransformIdentity;
                l.alpha = 1.0f;
                l.frame = CGRectMake(bx, ly, btnSize, labelH);
                l.hidden = NO;
            }
        }
    } else {
        for (UIButton *b in _menuButtons) {
            b.transform = CGAffineTransformIdentity;
            b.alpha = 0.0f;
            b.hidden = YES;
        }
        for (UILabel *l in _menuLabels) {
            l.transform = CGAffineTransformIdentity;
            l.alpha = 0.0f;
            l.hidden = YES;
        }
    }
}

#pragma mark 展开 / 收起

- (void)expandMenu
{
    if (_expanded || !_window) return;
    _expanded = YES;
    _menuAnimating = YES;
    [self applyGeometry];  // 先让按钮/标签到正确位置

    CGPoint dotCenter = _dotButton.center;

    // 先保存正确位置（关键！不能改 frame 后再存）
    NSMutableArray *targets = [NSMutableArray array];
    for (NSUInteger i = 0; i < _menuButtons.count; i++) {
        UIButton *b = _menuButtons[i];
        UILabel *l = _menuLabels[i];
        [targets addObject:@{
            @"b_center": [NSValue valueWithCGPoint:b.center],
            @"l_center": [NSValue valueWithCGPoint:l.center],
            @"b_size": [NSValue valueWithCGSize:b.frame.size],
            @"l_size": [NSValue valueWithCGSize:l.frame.size]
        }];
    }

    // 瀑布流：每个按钮/标签从 dot 位置缩放淡入
    NSUInteger total = _menuButtons.count;
    for (NSUInteger i = 0; i < total; i++) {
        UIButton *b = _menuButtons[i];
        UILabel *l = _menuLabels[i];
        NSDictionary *t = targets[i];
        CGSize bSize = [t[@"b_size"] CGSizeValue];
        CGSize lSize = [t[@"l_size"] CGSizeValue];
        CGPoint bTarget = [t[@"b_center"] CGPointValue];
        CGPoint lTarget = [t[@"l_center"] CGPointValue];

        // 把它们放到 dot 位置、缩小、透明
        b.frame = CGRectMake(dotCenter.x - bSize.width/2,
                             dotCenter.y - bSize.height/2,
                             bSize.width, bSize.height);
        b.transform = CGAffineTransformMakeScale(0.1f, 0.1f);
        b.alpha = 0.0f;
        b.hidden = NO;
        b.layer.zPosition = 3.0f;

        l.frame = CGRectMake(dotCenter.x - lSize.width/2,
                             dotCenter.y - lSize.height/2,
                             lSize.width, lSize.height);
        l.transform = CGAffineTransformMakeScale(0.1f, 0.1f);
        l.alpha = 0.0f;
        l.hidden = NO;
        l.layer.zPosition = 4.0f;

        double delay = i * 0.05f;
        BOOL isLast = (i == total - 1);
        [UIView animateWithDuration:0.30f
                              delay:delay
             usingSpringWithDamping:0.85f
              initialSpringVelocity:0.6f
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            b.center = bTarget;
            b.transform = CGAffineTransformIdentity;
            b.alpha = 1.0f;
            l.center = lTarget;
            l.transform = CGAffineTransformIdentity;
            l.alpha = 1.0f;
        } completion:^(BOOL finished) {
            if (isLast) self->_menuAnimating = NO;  // 最后一个结束才解锁
        }];
    }
    _dotButton.layer.zPosition = 1.0f;
}

- (void)collapseMenu
{
    if (!_expanded || !_window) return;
    _menuAnimating = YES;
    CGPoint dotCenter = _dotButton.center;

    // 先保存当前位置（改 frame 之前）
    NSMutableArray *targets = [NSMutableArray array];
    for (NSUInteger i = 0; i < _menuButtons.count; i++) {
        UIButton *b = _menuButtons[i];
        UILabel *l = _menuLabels[i];
        [targets addObject:@{
            @"b_center": [NSValue valueWithCGPoint:b.center],
            @"l_center": [NSValue valueWithCGPoint:l.center],
            @"b_size": [NSValue valueWithCGSize:b.frame.size],
            @"l_size": [NSValue valueWithCGSize:l.frame.size]
        }];
    }

    // 反向瀑布流：每个按钮/标签向 dot 位置缩小淡出，最后一个先收
    NSUInteger total = _menuButtons.count;
    for (NSUInteger i = 0; i < total; i++) {
        UIButton *b = _menuButtons[i];
        UILabel *l = _menuLabels[i];
        NSDictionary *t = targets[i];
        CGSize bSize = [t[@"b_size"] CGSizeValue];
        CGSize lSize = [t[@"l_size"] CGSizeValue];

        CGRect bTarget = CGRectMake(dotCenter.x - bSize.width/2,
                                    dotCenter.y - bSize.height/2,
                                    bSize.width, bSize.height);
        CGRect lTarget = CGRectMake(dotCenter.x - lSize.width/2,
                                    dotCenter.y - lSize.height/2,
                                    lSize.width, lSize.height);

        double delay = (total - 1 - i) * 0.04f;
        BOOL isFirst = (i == 0);
        [UIView animateWithDuration:0.25f
                              delay:delay
                            options:UIViewAnimationOptionCurveEaseIn
                         animations:^{
            b.frame = bTarget;
            b.transform = CGAffineTransformMakeScale(0.1f, 0.1f);
            b.alpha = 0.0f;
            l.frame = lTarget;
            l.transform = CGAffineTransformMakeScale(0.1f, 0.1f);
            l.alpha = 0.0f;
        } completion:^(BOOL finished) {
            if (isFirst) {
                self->_expanded = NO;
                self->_menuAnimating = NO;  // 最后一个（最早开始的）结束才解锁
                [self applyGeometry];
            }
        }];
    }
}

- (void)toggleMenu
{
    // 动画中：取消所有动画 → view 跳到 applyGeometry 算的正确位置 → 再 toggle
    if (_menuAnimating) {
        [_content.layer removeAllAnimations];
        for (UIButton *b in _menuButtons) { [b.layer removeAllAnimations]; }
        for (UILabel *l in _menuLabels) { [l.layer removeAllAnimations]; }
        _menuAnimating = NO;
        [self applyGeometry];  // 所有 view 跳到 _expanded 当前状态对应的正确位置
    }
    if (_expanded) [self collapseMenu];
    else [self expandMenu];
}

#pragma mark 手势

- (void)handleDotTap:(UITapGestureRecognizer *)tap
{
    if (tap.state == UIGestureRecognizerStateRecognized) {
        [self toggleMenu];
    }
}

- (void)handleDotPan:(UIPanGestureRecognizer *)pan
{
    CGFloat visW, visH;
    [self visualWidth:&visW height:&visH portrait:NULL];
    CGFloat dotRadius = [self dotRadius];

    // 用 rootView（未旋转）作为参考，避免 translationInView:_content 在
    // _content 旋转后行为不一致导致拖动方向错乱（用户反馈横屏拖不到右侧）
    UIView *rootView = _window.rootViewController.view;
    int orientation = [self currentOrientation];

    if (pan.state == UIGestureRecognizerStateBegan) {
        _dragging = YES;
        _dragStartVisual = [self dotVisualPoint];
        // 注意：拖动时菜单保持展开，实时跟随（按键精灵行为）
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [pan translationInView:rootView];
        CGPoint vt = [self visualTranslationFromRootView:t orientation:orientation];
        CGFloat x = MIN(MAX(_dragStartVisual.x + vt.x, dotRadius), visW - dotRadius);
        CGFloat y = MIN(MAX(_dragStartVisual.y + vt.y, dotRadius + 2.0f), visH - dotRadius - 2.0f);

        _content.transform = CGAffineTransformIdentity;
        _dotButton.frame = CGRectMake(x - dotRadius, y - dotRadius, _dotSize, _dotSize);
        // 实时更新 edge（跨过半屏自动切换）并重算按钮位置
        int curEdge = (x < visW / 2.0f) ? 0 : 1;
        if (curEdge != _edge) {
            _edge = curEdge;
        }
        if (_expanded) {
            [self applyGeometry];
        }
    } else if (pan.state == UIGestureRecognizerStateEnded ||
               pan.state == UIGestureRecognizerStateCancelled ||
               pan.state == UIGestureRecognizerStateFailed) {
        CGPoint t = [pan translationInView:rootView];
        CGPoint vt = [self visualTranslationFromRootView:t orientation:orientation];
        CGFloat x = MIN(MAX(_dragStartVisual.x + vt.x, dotRadius), visW - dotRadius);
        CGFloat y = MIN(MAX(_dragStartVisual.y + vt.y, dotRadius + 2.0f), visH - dotRadius - 2.0f);

        // 吸附：离哪条竖边近贴哪条，中心距边缘 = 半径 → 圆点完全贴边且完整显示
        int newEdge = (x < visW / 2.0f) ? 0 : 1;
        _dragging = NO;
        _edge = newEdge;
        _yRatio = y / visH;

        fmPersistKeys(@{
            kFMCfgEdge: @(newEdge),
            kFMCfgYRatio: @(_yRatio)
        });

        // 平滑吸附动画：先算好最终位置，然后直接在 animate block 里设置，
        // UIKit 会从当前 model 值（pan.Changed 的最后一帧）过渡到吸附位置
        [UIView animateWithDuration:0.25f
                              delay:0
             usingSpringWithDamping:0.75f
              initialSpringVelocity:0.8f
                            options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            // dot 最终吸附位置
            CGPoint finalDot = [self dotVisualPoint];
            self->_dotButton.frame = CGRectMake(finalDot.x - dotRadius, finalDot.y - dotRadius,
                                                 self->_dotSize, self->_dotSize);
            // menu 按钮/标签也跟着到最终位置
            if (self->_expanded) {
                [self applyGeometry];
            }
        } completion:nil];
    }
}

#pragma mark - 菜单 icon 点击

- (void)handleMenuIconTap:(UIButton *)sender
{
    NSUInteger idx = [_menuButtons indexOfObject:sender];
    if (idx == NSNotFound) return;
    // 不要在这里调 collapseMenu！每个 action 自己决定要不要收菜单：
    // actionStart 启动脚本后保持菜单打开（方便停止），actionSettings/actionBack 收菜单
    if (idx == 0) [self actionStart];
    else if (idx == 1) [self actionSettings];
    else if (idx == 2) [self actionBack];
}

#pragma mark - 菜单动作

- (void)actionStart
{
    [self collapseMenu];

    NSString *path = [_scriptPath copy];
    if (path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        fmToast(@"请先点击设置选择脚本", 2);
        return;
    }

    // 与 Popup.xm 一致：播放在后台队列，错误弹 AlertBox
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            NSError *err = nil;
            playScriptWithSettings((UInt8 *)[path UTF8String], 0, 1.0f, 0.0f, &err);
            if (err) {
                NSString *message = [[err localizedDescription] copy];
                ZXSafeMainAsync(^{
                    @try {
                        showAlertBox(@"错误", message, 999);
                    } @catch (NSException *exception) {
                        ZXLogUIException(exception);
                    }
                });
            }
        }
    });
}

- (void)actionSettings
{
    [self collapseMenu];

    @try {
        NSString *base = [getScriptsFolder() copy];
        NSMutableArray<NSString *> *relativePaths = [NSMutableArray array];
        NSFileManager *fm = [NSFileManager defaultManager];

        if (base.length > 0) {
            NSDirectoryEnumerator<NSString *> *enumerator = [fm enumeratorAtPath:base];
            for (NSString *relative in enumerator) {
                @autoreleasepool {
                    if (![[relative pathExtension] isEqualToString:@"bdl"]) {
                        continue;
                    }
                    NSString *full = [base stringByAppendingPathComponent:relative];
                    BOOL isDir = NO;
                    if ([fm fileExistsAtPath:full isDirectory:&isDir] && isDir) {
                        [relativePaths addObject:relative];
                    }
                }
            }
        }
        [relativePaths sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        [self presentScriptPicker:relativePaths scriptsBase:base];
    } @catch (NSException *exception) {
        ZXLogUIException(exception);
        fmToast(@"扫描脚本目录失败", 1);
    }
}

- (void)presentScriptPicker:(NSArray<NSString *> *)relativePaths scriptsBase:(NSString *)base
{
    if (!_window) {
        return;
    }
    UIViewController *presenter = _window.rootViewController;
    if (presenter.presentedViewController) {
        return;
    }

    NSString *message = relativePaths.count > 0 ? nil : @"未找到任何 .bdl 脚本";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"选择脚本"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSString *relative in relativePaths) {
        NSString *display = [relative stringByDeletingPathExtension]; // 相对路径，支持中文
        NSString *full = [base stringByAppendingPathComponent:relative];
        [alert addAction:[UIAlertAction actionWithTitle:display
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            self->_scriptPath = [full copy];
            fmPersistKeys(@{ kFMCfgScript: full });
            fmToast([NSString stringWithFormat:@"已选择 %@", display], 4);
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    // iPad 上 actionSheet 必须挂 popover，否则会抛异常
    @try {
        UIPopoverPresentationController *popover = alert.popoverPresentationController;
        if (popover) {
            popover.sourceView = _dotButton;
            popover.sourceRect = _dotButton.bounds;
            popover.permittedArrowDirections = 0;
        }
    } @catch (NSException *exception) {
        ZXLogUIException(exception);
    }

    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)actionBack
{
    // 同步隐藏 UI（立即消失）
    _expanded = NO;
    for (UIButton *b in _menuButtons) { b.hidden = YES; b.alpha = 0.0f; }
    for (UILabel *l in _menuLabels)  { l.hidden = YES; l.alpha = 0.0f; }
    [self applyGeometry];

    // 放到后台线程 launch——SBSLaunchApplicationWithIdentifier 是同步阻塞调用，
    // 在主线程调会卡 SpringBoard 几秒钟
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self launchZXTouchApp];
    });
}

#pragma mark 返回 ZXTouch app

// 使用 SpringBoard Services 私有函数 SBSLaunchApplicationWithIdentifier
// （与 Process.xm / ScriptPlayer.xm 的 bringAppForeground 同源，已在项目中验证可靠）
- (void)launchZXTouchApp
{
    @try {
        // SBSLaunchApplicationWithIdentifier 是 C 函数，不依赖主线程。
        // 在后台线程直接调避免卡 SpringBoard（主线程）UI。
        bringAppForeground(kFMZXTouchBID);
    } @catch (NSException *exception) {
        ZXLogUIException(exception);
    }
}

#pragma mark 轮询 / 自愈

- (void)startWatchers
{
    if (!_watchTimer) {
        _watchTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                       target:self
                                                     selector:@selector(handleWatchTick:)
                                                     userInfo:nil
                                                      repeats:YES];
    }
    if (!_observing) {
        _observing = YES;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleOrientationNote:)
                                                     name:UIApplicationDidChangeStatusBarOrientationNotification
                                                   object:nil];
    }
}

- (void)stopWatchers
{
    if (_watchTimer) {
        [_watchTimer invalidate];
        _watchTimer = nil;
    }
    if (_observing) {
        _observing = NO;
        [[NSNotificationCenter defaultCenter] removeObserver:self];
    }
}

- (void)handleWatchTick:(NSTimer *)timer
{
    ZXSafeMainAsync(^{
        @try {
            // 自愈 0：enabled 但 window 不存在或 hidden → 重建（SpringBoard 重启后 scene 延迟就绪）
            if (self->_enabled && (!self->_window || self->_window.hidden)) {
                [self setEnabled:YES persist:NO];
                return;
            }
            if (!self->_enabled) {
                return;
            }
            // 自愈 1：window 丢了就重建
            if (!self->_window) {
                [self buildWindow];
                return;
            }
            // 自愈 2：方向变了重布局（SpringBoard 重启可能跳过方向通知）
            int ori = [self currentOrientation];
            if (ori != self->_lastOrientation) {
                [self applyGeometry];
            }
            // 自愈 3：dot 位置不对（比如 window.bounds 变了但没触发通知）
            if (!self->_dragging) {
                CGPoint expected = [self dotVisualPoint];
                if (fabs(self->_dotButton.center.x - expected.x) > 1.0f ||
                    fabs(self->_dotButton.center.y - expected.y) > 1.0f) {
                    [self applyGeometry];
                }
            }
            if (self->_window.hidden) {
                self->_window.hidden = NO;
            }
        } @catch (NSException *exception) {
            ZXLogUIException(exception);
        }
    });
}

- (void)handleOrientationNote:(NSNotification *)note
{
    ZXSafeMainAsync(^{
        @try {
            [self applyGeometry];
        } @catch (NSException *exception) {
            ZXLogUIException(exception);
        }
    });
}

#pragma mark - Script running spinner（旋转光圈）

- (void)startRunningSpinner
{
    if (!_dotButton) return;
    if ([_dotButton.layer animationForKey:@"fmSpinning"]) return;

    CGFloat s = _dotSize + 10;  // 比 dot 大 5pt（更明显）

    // 绿蛇：3 段渐变圆弧，每段粗细不同，前深后浅
    NSArray *segments = @[
        @{@"end": @(0.30f), @"width": @(3.5f), @"color": [UIColor colorWithRed:0.2f green:0.95f blue:0.3f alpha:1.0f]},
        @{@"end": @(0.20f), @"width": @(2.5f), @"color": [UIColor colorWithRed:0.3f green:0.8f  blue:0.3f alpha:0.8f]},
        @{@"end": @(0.10f), @"width": @(1.5f), @"color": [UIColor colorWithRed:0.4f green:0.65f blue:0.3f alpha:0.5f]},
    ];

    for (NSUInteger i = 0; i < segments.count; i++) {
        NSDictionary *seg = segments[i];
        CAShapeLayer *ring = [CAShapeLayer layer];
        ring.frame = CGRectMake(-5, -5, s, s);
        UIBezierPath *path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(3, 3, s - 6, s - 6)];
        ring.path = path.CGPath;
        ring.fillColor = [UIColor clearColor].CGColor;
        ring.strokeColor = ((UIColor *)seg[@"color"]).CGColor;
        ring.lineWidth = [seg[@"width"] floatValue];
        ring.lineCap = kCALineCapRound;
        ring.strokeStart = 0.0f;
        ring.strokeEnd = [seg[@"end"] floatValue];
        ring.name = [NSString stringWithFormat:@"fmSpinnerRing_%lu", (unsigned long)i];
        ring.zPosition = -1;
        [_dotButton.layer addSublayer:ring];

        CABasicAnimation *rot = [CABasicAnimation animationWithKeyPath:@"transform.rotation"];
        rot.fromValue = @(0);
        rot.toValue = @(2 * M_PI);
        rot.duration = 1.0f;
        rot.repeatCount = INFINITY;
        rot.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        [ring addAnimation:rot forKey:@"fmSpinning"];
    }
}

- (void)stopRunningSpinner
{
    if (!_dotButton) return;
    // 遍历所有子 layer，移除所有 fmSpinnerRing 开头的
    NSMutableArray *toRemove = [NSMutableArray array];
    for (CALayer *sub in _dotButton.layer.sublayers) {
        if ([sub.name hasPrefix:@"fmSpinnerRing_"]) {
            [toRemove addObject:sub];
        }
    }
    for (CALayer *s in toRemove) {
        [s removeAllAnimations];
        [s removeFromSuperlayer];
    }
}

+ (void)startRunningSpinner { [[self shared] startRunningSpinner]; }
+ (void)stopRunningSpinner  { [[self shared] stopRunningSpinner]; }

#pragma mark 开关 / 配置

- (void)setEnabled:(BOOL)enabled persist:(BOOL)persist
{
    _enabled = enabled;
    if (persist) {
        fmPersistKeys(@{ kFMCfgEnabled: @(enabled) });
    }

    ZXSafeMainAsync(^{
        @try {
            if (enabled) {
                if (!self->_window) {
                    [self buildWindow];
                } else {
                    self->_window.hidden = NO;
                    [self applyGeometry];
                }
                [self startWatchers];
            } else {
                [self stopWatchers];
                if (self->_window) {
                    self->_window.hidden = YES;
                    self->_window.rootViewController = nil;
                    self->_window = nil;
                    self->_content = nil;
                    self->_dotButton = nil;
                    self->_menuButtons = nil;
                    self->_expanded = NO;
                }
            }
        } @catch (NSException *exception) {
            ZXLogUIException(exception);
        }
    });
}

- (void)reloadConfig
{
    ZXSafeMainAsync(^{
        @try {
            BOOL enabled = NO;
            BOOL hasEdge = NO;
            int edge = 1;
            BOOL hasRatio = NO;
            CGFloat ratio = 0.5f;
            CGFloat dotSize = kFMDotDefaultSize;
            NSString *script = @"";

            NSDictionary *config = [[NSDictionary alloc] initWithContentsOfFile:fmConfigPath()];
            if ([config isKindOfClass:[NSDictionary class]]) {
                enabled = [config[kFMCfgEnabled] boolValue];
                NSNumber *edgeValue = config[kFMCfgEdge];
                if ([edgeValue isKindOfClass:[NSNumber class]]) {
                    edge = [edgeValue intValue];
                    hasEdge = YES;
                }
                NSNumber *ratioValue = config[kFMCfgYRatio];
                if ([ratioValue isKindOfClass:[NSNumber class]]) {
                    ratio = [ratioValue doubleValue];
                    hasRatio = YES;
                }
                NSNumber *dotSizeValue = config[kFMCfgDotSize];
                if ([dotSizeValue isKindOfClass:[NSNumber class]]) {
                    dotSize = [dotSizeValue doubleValue];
                }
                if (!hasEdge) {
                    NSNumber *xValue = config[@"floating_menu_x"];
                    CGFloat pw, ph;
                    [self visualWidth:&pw height:&ph portrait:NULL];
                    if ([xValue isKindOfClass:[NSNumber class]]) {
                        edge = ([xValue doubleValue] < pw / 2.0f) ? 0 : 1;
                    }
                }
                NSString *savedScript = config[kFMCfgScript];
                if ([savedScript isKindOfClass:[NSString class]]) {
                    script = savedScript;
                }
            }

            self->_edge = (edge == 0) ? 0 : 1;
            self->_yRatio = MIN(MAX(hasRatio ? ratio : 0.5f, 0.02f), 0.98f);
            self->_dotSize = MIN(MAX(dotSize, kFMDotMinSize), kFMDotMaxSize);
            self->_scriptPath = script;

            // 彻底照搬 NetSpeedIndicator.reloadAppearance 模式：
            // 先 destroy 再 create——确保 SpringBoard 重启后 window 一定能显示
            if (enabled) {
                [self destroyWindow];
                [self buildWindow];
                self->_enabled = YES;
                [self startWatchers];
            } else {
                [self destroyWindow];
                self->_enabled = NO;
                [self stopWatchers];
            }
        } @catch (NSException *exception) {
            ZXLogUIException(exception);
        }
    });
}

- (void)destroyWindow
{
    _window.hidden = YES;
    _window.rootViewController = nil;
    _window = nil;
    _content = nil;
    _dotButton = nil;
    _menuPanel = nil;
    [_menuButtons removeAllObjects];
    [_menuLabels removeAllObjects];
    _expanded = NO;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// 实例方法：收集 self 的调试状态
- (NSDictionary *)debugInfoInstance
{
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"enabled"] = @(_enabled);
    info[@"expanded"] = @(_expanded);
    info[@"edge"] = @(_edge);          // 1=右 0=左
    info[@"edge_name"] = (_edge == 0) ? @"左" : @"右";
    info[@"y_ratio"] = @(_yRatio);
    info[@"dot_size"] = @(_dotSize);
    info[@"last_orientation"] = @(_lastOrientation);

    CGFloat visW, visH;
    [self visualWidth:&visW height:&visH portrait:NULL];
    info[@"visual_w"] = @(visW);
    info[@"visual_h"] = @(visH);
    CGPoint dot = [self dotVisualPoint];
    info[@"dot_visual_x"] = @(dot.x);
    info[@"dot_visual_y"] = @(dot.y);

    if (!_window) {
        info[@"window_exists"] = @(NO);
        info[@"note"] = @"window 尚未创建";
        return [info copy];
    }

    info[@"window_exists"] = @(YES);
    info[@"window_hidden"] = @(_window.hidden);
    CGRect wf = _window.frame;
    info[@"window_frame_x"] = @(wf.origin.x);
    info[@"window_frame_y"] = @(wf.origin.y);
    info[@"window_frame_w"] = @(wf.size.width);
    info[@"window_frame_h"] = @(wf.size.height);

    if (_content) {
        CGAffineTransform ct = _content.transform;
        info[@"content_transform_a"] = @(ct.a);
        info[@"content_transform_b"] = @(ct.b);
        info[@"content_transform_c"] = @(ct.c);
        info[@"content_transform_d"] = @(ct.d);
        info[@"content_bounds_w"] = @(_content.bounds.size.width);
        info[@"content_bounds_h"] = @(_content.bounds.size.height);
    }

    if (_dotButton) {
        CGRect df = _dotButton.frame;
        CGPoint centerInRoot = [_dotButton convertPoint:CGPointMake(_dotSize/2, _dotSize/2) toView:_window.rootViewController.view];
        CGPoint centerInWindow = [_dotButton convertPoint:CGPointMake(_dotSize/2, _dotSize/2) toView:nil];
        info[@"dot_frame_x"] = @(df.origin.x);
        info[@"dot_frame_y"] = @(df.origin.y);
        info[@"dot_frame_w"] = @(df.size.width);
        info[@"dot_frame_h"] = @(df.size.height);
        info[@"dot_center_in_root_x"] = @(centerInRoot.x);
        info[@"dot_center_in_root_y"] = @(centerInRoot.y);
        info[@"dot_center_in_window_x"] = @(centerInWindow.x);
        info[@"dot_center_in_window_y"] = @(centerInWindow.y);
    }

    return [info copy];
}

+ (NSDictionary *)debugInfo
{
    __block NSDictionary *result = nil;
    void (^gather)(void) = ^{
        @try {
            result = [[FloatingMenu shared] debugInfoInstance];
        } @catch (NSException *exception) {
            result = @{ @"error": [exception reason] ?: @"unknown exception" };
        }
    };
    if ([NSThread isMainThread]) {
        gather();
    } else {
        dispatch_sync(dispatch_get_main_queue(), gather);
    }
    return result;
}

@end

#pragma mark - socket 任务 32

NSString *handleFloatingMenuTaskWithRawData(UInt8 *eventData, NSError **error)
{
    __block NSString *response = nil;
    @autoreleasepool {
        NSString *data = @"";
        if (eventData) {
            data = [NSString stringWithUTF8String:(const char *)eventData] ?: @"";
        }
        NSArray *parts = [data componentsSeparatedByString:@";;"];
        int action = [parts count] > 1 ? [parts[1] intValue] : 2;

        if (action == 2) {
            response = [NSString stringWithFormat:@"0;;%d\r\n", [FloatingMenu isEnabled] ? 1 : 0];
            if (error) {
                *error = nil;
            }
            return response;
        }

        if (action != 0 && action != 1 && action != 3) {
            if (error) {
                *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                             code:999
                                         userInfo:@{NSLocalizedDescriptionKey:@"-1;;数据格式应为 \"enabled\"（1=开启, 0=关闭, 2=查询, 3=reload 配置）\r\n"}];
            }
            return nil;
        }

        if (action == 3) {
            [FloatingMenu reloadConfig];
            response = @"0\r\n";
            if (error) *error = nil;
            return response;
        }

        BOOL enabled = (action == 1);
        [FloatingMenu setEnabled:enabled]; // 内部会持久化 floating_menu_enabled

        response = @"0\r\n";
        if (error) {
            *error = nil;
        }
    }
    return response;
}
