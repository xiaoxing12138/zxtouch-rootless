#import "FloatingMenu.h"
#import "Common.h"
#import "Screen.h"
#import "Play.h"
#import "Toast.h"
#import "AlertBox.h"
#import "Process.h"
#import "FunctionWindow.h"
#import "ScriptFunctions.h"      // ZXLastFunctionScriptPath / ZXFirstScriptPathWithFunctions
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>
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
 *   - 点圆点：在靠屏幕内侧横向展开「启动 / 功能 / 返回」（朝空间足的一侧排）；
 *     选哪个脚本在「功能」页里选，所以不再需要单独的「设置」入口；
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
#define kFMMenuLabelGap   2.0f    // 圆形按钮到下方标签的固定间距
#define kFMAnim           0.18

// 菜单外观可配置项（设置页「菜单外观」分组）的默认值与范围
// 注意：按钮尺寸/间距此前在 buildWindow 与 applyGeometry 各写一份且不一致，
// 现在统一由这几个 ivar 驱动，两处必须使用同一组值。
#define kFMMenuBtnSizeDefault   36.0f
#define kFMMenuBtnSizeMin       32.0f
#define kFMMenuBtnSizeMax       72.0f
#define kFMMenuBtnGapDefault    8.0f
#define kFMMenuBtnGapMin        0.0f
#define kFMMenuBtnGapMax        24.0f
#define kFMMenuLabelFontDefault 12.0f
#define kFMMenuLabelFontMin     9.0f
#define kFMMenuLabelFontMax     18.0f
#define kFMMenuIconInsetDefault 5.0f
#define kFMMenuIconInsetMin     0.0f
#define kFMMenuIconInsetMax     10.0f
#define kFMMenuPanelGapDefault  8.0f
#define kFMMenuPanelGapMin      0.0f
#define kFMMenuPanelGapMax      40.0f

#define kFMCfgEnabled     @"floating_menu_enabled"
#define kFMCfgEdge        @"floating_menu_edge"       // 1=贴右 0=左
#define kFMCfgYRatio      @"floating_menu_y_ratio"   // 纵向位置 0..1
#define kFMCfgDotSize     @"floating_menu_dot_size"   // 圆点大小 32..80
#define kFMCfgMenuBtnSize @"floating_menu_menu_size"  // 菜单按钮大小 32..72
#define kFMCfgMenuBgAlpha @"floating_menu_menu_bg_alpha" // 菜单黑底透明度 0..1
#define kFMCfgMenuBtnGap  @"floating_menu_menu_gap"       // 按钮间距 0..24
#define kFMCfgLabelFont   @"floating_menu_label_font_size" // 标签字号 9..18
#define kFMCfgIconInset   @"floating_menu_icon_inset"     // 图标圆内留白 0..10
#define kFMCfgPanelGap    @"floating_menu_panel_gap"      // 圆点到菜单间距 0..40
#define kFMCfgDotIcon     @"floating_menu_dot_icon"       // 圆点图标 0=字母Z 1=App图标 2=自定义图片
#define kFMCfgDotBgColor   @"floating_menu_dot_bg_color"   // 圆点背景色 #RRGGBB
#define kFMCfgMenuBtnColor @"floating_menu_menu_btn_color" // 菜单按钮背景色 #RRGGBB
#define kFMCfgIconColor    @"floating_menu_icon_color"     // 图标颜色 #RRGGBB（圆点字母 + 菜单图标）
#define kFMCfgLabelColor   @"floating_menu_label_color"    // 菜单标签文字色 #RRGGBB
#define kFMCfgPauseText    @"floating_menu_pause_text"        // 暂停时叠加在圆点上的文字
#define kFMCfgPauseFont    @"floating_menu_pause_font_size"   // 暂停文字字号 6..16
#define kFMCfgPauseColor   @"floating_menu_pause_text_color"  // 暂停文字颜色 #RRGGBB
#define kFMCfgPauseGray    @"floating_menu_pause_gray_alpha"  // 圆点变灰深度（灰罩不透明度）0..1

// 颜色默认值：圆点沿用旧硬编码色 (20,20,28)，菜单底沿用 white 0.12 (≈#1F1F1F)
#define kFMDotBgColorDefault   @"#14141C"
#define kFMMenuBtnColorDefault @"#1F1F1F"
#define kFMIconColorDefault    @"#FFFFFF"
#define kFMLabelColorDefault   @"#FFFFFF"
#define kFMDotBgAlpha          0.82f   // 圆点底色不透明度（未开放配置）

// 暂停显示默认值与范围（设置页「暂停显示」分组）
#define kFMPauseTextDefault  @"已暂停"
#define kFMPauseFontDefault  9.0f
#define kFMPauseFontMin      6.0f
#define kFMPauseFontMax      16.0f
#define kFMPauseColorDefault @"#FFFFFF"
#define kFMPauseGrayDefault  0.55f
#define kFMPauseGrayMin      0.0f
#define kFMPauseGrayMax      1.0f

// 菜单按钮随脚本状态切换（数量也不同）：
//   未运行 → 启动 / 功能 / 返回（脚本在「功能」页里选）
//   运行中 → 暂停 / 停止 / 返回
//   已暂停 → 启动 / 停止 / 返回（圆点同时变灰并叠加「已暂停」）
// 具体表见 menuTableForState:，点击按 role 派发
typedef NS_ENUM(NSInteger, FMScriptPlayState) {
    FMScriptPlayStateIdle    = 0,  // 未运行
    FMScriptPlayStateRunning = 1,  // 运行中
    FMScriptPlayStatePaused  = 2   // 已暂停
};

// 圆点图标来源
#define kFMDotIconModeZ       0
#define kFMDotIconModeApp     1
#define kFMDotIconModeCustom  2

// 菜单按钮/标签背景底色的不透明度默认值、可调范围
#define kFMMenuDefaultBgAlpha 0.92f
#define kFMMenuMinBgAlpha     0.0f
#define kFMMenuMaxBgAlpha     1.0f
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

// "#RRGGBB" / "#RGB" → UIColor，非法输入返回 nil（调用方决定兜底色）
static UIColor *fmColorFromHex(NSString *hex, CGFloat alpha)
{
    if (![hex isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSString *value = [hex stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([value hasPrefix:@"#"]) {
        value = [value substringFromIndex:1];
    }
    if (value.length == 3) {
        NSString *r = [value substringWithRange:NSMakeRange(0, 1)];
        NSString *g = [value substringWithRange:NSMakeRange(1, 1)];
        NSString *b = [value substringWithRange:NSMakeRange(2, 1)];
        value = [NSString stringWithFormat:@"%@%@%@%@%@%@", r, r, g, g, b, b];
    }
    if (value.length != 6) {
        return nil;
    }
    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:value];
    if (![scanner scanHexInt:&rgb]) {
        return nil;
    }
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0f
                           green:((rgb >> 8) & 0xFF) / 255.0f
                            blue:(rgb & 0xFF) / 255.0f
                           alpha:alpha];
}

static void fmToast(NSString *content, int type)
{
    [Toast showToastWithContent:content type:type duration:1.8f position:1 fontSize:14];
}

// 图片转灰度（饱和度置 0），用于脚本暂停时的圆点图标。失败时原样返回。
static UIImage *fmGrayscaleImage(UIImage *image)
{
    if (!image || !image.CGImage) {
        return image;
    }
    @try {
        CIImage *input = [CIImage imageWithCGImage:image.CGImage];
        CIFilter *filter = input ? [CIFilter filterWithName:@"CIColorControls"] : nil;
        if (!filter) {
            return image;
        }
        [filter setValue:input forKey:kCIInputImageKey];
        [filter setValue:@(0.0f) forKey:kCIInputSaturationKey];
        CIImage *output = filter.outputImage;
        if (!output) {
            return image;
        }
        // CIContext 创建开销大，全局只建一次
        static CIContext *context = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            context = [CIContext contextWithOptions:nil];
        });
        CGImageRef cgImage = [context createCGImage:output fromRect:output.extent];
        if (!cgImage) {
            return image;
        }
        UIImage *result = [UIImage imageWithCGImage:cgImage scale:image.scale orientation:image.imageOrientation];
        CGImageRelease(cgImage);
        return result ?: image;
    } @catch (NSException *exception) {
        return image;
    }
}

static NSString *fmConfigPath(void)
{
    return getCommonConfigFilePath();
}

// 圆点图标选「App 图标 / 自定义图片」时，由 App 端把 PNG 导出到共享目录，
// tweak 端只读取文件（不在 SpringBoard 里访问相册或私有图标接口）。
static NSString *fmDotIconAppPath(void)
{
    return [[fmConfigPath() stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"fm_dot_icon_app.png"];
}

static NSString *fmDotIconCustomPath(void)
{
    return [[fmConfigPath() stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"fm_dot_icon_custom.png"];
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
    UIImageView              *_dotIconView;      // 圆点图标（字母Z 模式时隐藏）
    UIImage                  *_dotIconImage;     // 圆点图标的原图（暂停时转灰度用）
    UIView                   *_pauseOverlay;     // 暂停时覆盖圆点的灰罩
    UILabel                  *_pauseLabel;       // 暂停时叠加在圆点上的文字
    UIView                   *_menuPanel;        // 白色半透明面板（菜单容器）
    NSMutableArray<UIButton *> *_menuButtons; // 菜单按钮（固定 3 个槽位，用几个由 _menuTable 决定）
    NSMutableArray<UILabel *>  *_menuLabels;  // 对应下方文字标签
    NSArray<NSDictionary *>  *_menuTable;     // 当前状态下要显示哪些按钮：@{role, symbol, title}
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
    CGFloat  _menuBgAlpha;    // 菜单按钮/标签黑底不透明度（0..1，配置驱动）
    CGFloat  _menuBtnSize;    // 菜单按钮直径 pt（32..72）
    CGFloat  _menuBtnGap;     // 菜单按钮之间间距 pt（0..24）
    CGFloat  _menuLabelFont;  // 菜单标签字号（9..18）
    CGFloat  _menuIconInset;  // 图标在按钮圆内的留白（0..10）
    CGFloat  _menuPanelGap;   // 圆点到菜单整体的间距（0..40）
    NSInteger _dotIconMode;   // 圆点图标来源（0=字母Z 1=App图标 2=自定义图片）
    NSString *_dotBgColorHex;   // 圆点背景色
    NSString *_menuBtnColorHex; // 菜单按钮背景色
    NSString *_iconColorHex;    // 图标颜色（圆点字母 + 菜单图标）
    NSString *_labelColorHex;   // 菜单标签文字色
    NSString *_pauseText;       // 暂停时圆点上的文字
    CGFloat  _pauseFont;        // 暂停文字字号（6..16）
    NSString *_pauseTextColorHex; // 暂停文字颜色
    CGFloat  _pauseGrayAlpha;   // 圆点变灰深度（灰罩不透明度 0..1）
    FMScriptPlayState _playState; // 当前脚本状态（驱动菜单按钮 + 圆点暂停外观）
    int      _lastOrientation;

    CGPoint  _dragStartVisual;
}

- (void)applyGeometry;
- (void)applyDotIcon;
- (void)applyPauseAppearance;
- (NSArray<NSDictionary *> *)menuTableForState:(FMScriptPlayState)state;
- (void)applyScriptPlayState:(FMScriptPlayState)state;
- (void)expandMenu;
- (void)collapseMenu;

@end

@implementation FloatingMenu

- (instancetype)init
{
    self = [super init];
    if (self) {
        _dotSize = kFMDotDefaultSize;
        _menuBgAlpha = kFMMenuDefaultBgAlpha;
        _menuBtnSize = kFMMenuBtnSizeDefault;
        _menuBtnGap = kFMMenuBtnGapDefault;
        _menuLabelFont = kFMMenuLabelFontDefault;
        _menuIconInset = kFMMenuIconInsetDefault;
        _menuPanelGap = kFMMenuPanelGapDefault;
        _dotIconMode = kFMDotIconModeZ;
        _dotBgColorHex = kFMDotBgColorDefault;
        _menuBtnColorHex = kFMMenuBtnColorDefault;
        _iconColorHex = kFMIconColorDefault;
        _labelColorHex = kFMLabelColorDefault;
        _pauseText = kFMPauseTextDefault;
        _pauseFont = kFMPauseFontDefault;
        _pauseTextColorHex = kFMPauseColorDefault;
        _pauseGrayAlpha = kFMPauseGrayDefault;
        _playState = FMScriptPlayStateIdle;
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

// 菜单按钮与标签共用的底色（颜色 + 不透明度均可配置）
- (UIColor *)menuBackgroundColor
{
    return fmColorFromHex(_menuBtnColorHex, _menuBgAlpha) ?: [UIColor colorWithWhite:0.12f alpha:_menuBgAlpha];
}

// 图标颜色（圆点字母 + 菜单 SF Symbol），非法值回退白色
- (UIColor *)iconColor
{
    return fmColorFromHex(_iconColorHex, 1.0f) ?: [UIColor whiteColor];
}

// 菜单标签文字色，非法值回退白色
- (UIColor *)labelColor
{
    return fmColorFromHex(_labelColorHex, 1.0f) ?: [UIColor whiteColor];
}

// 标签高度随字号推导。原代码 buildWindow 写死 14、applyGeometry 写死 12，
// 后者比标签字号还小会把文字裁掉，现在统一由字号推导。
- (CGFloat)menuLabelHeight
{
    return ceilf(_menuLabelFont * 1.35f);
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
    _dotButton.backgroundColor = fmColorFromHex(_dotBgColorHex, kFMDotBgAlpha)
                                 ?: [UIColor colorWithRed:20.0f / 255.0f green:20.0f / 255.0f blue:28.0f / 255.0f alpha:kFMDotBgAlpha];
    _dotButton.layer.cornerRadius = [self dotRadius];
    _dotButton.titleLabel.font = [UIFont systemFontOfSize:[self dotTitleFontSize] weight:UIFontWeightBold];
    [_dotButton setTitle:@"Z" forState:UIControlStateNormal];
    [_dotButton setTitleColor:[self iconColor] forState:UIControlStateNormal];
    _dotButton.adjustsImageWhenHighlighted = NO;
    [_content addSubview:_dotButton];

    // 圆点图标层：等比填满圆点并裁圆。注意不能给 _dotButton.layer 开 masksToBounds，
    // 否则会把运行中的旋转光圈（挂在 dot 外侧的子 layer）一起裁掉。
    _dotIconView = [[UIImageView alloc] initWithFrame:_dotButton.bounds];
    _dotIconView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _dotIconView.contentMode = UIViewContentModeScaleAspectFill;
    _dotIconView.clipsToBounds = YES;
    _dotIconView.layer.cornerRadius = [self dotRadius];
    _dotIconView.userInteractionEnabled = NO;
    _dotIconView.hidden = YES;
    [_dotButton addSubview:_dotIconView];

    // 暂停外观：灰罩 + 叠加文字（都在圆点内部，不拦触摸；文字必须在灰罩之上）
    _pauseOverlay = [[UIView alloc] initWithFrame:_dotButton.bounds];
    _pauseOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _pauseOverlay.layer.cornerRadius = [self dotRadius];
    _pauseOverlay.userInteractionEnabled = NO;
    _pauseOverlay.hidden = YES;
    [_dotButton addSubview:_pauseOverlay];

    _pauseLabel = [[UILabel alloc] initWithFrame:_dotButton.bounds];
    _pauseLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _pauseLabel.textAlignment = NSTextAlignmentCenter;
    _pauseLabel.adjustsFontSizeToFitWidth = YES;
    _pauseLabel.minimumScaleFactor = 0.5f;
    _pauseLabel.numberOfLines = 1;
    _pauseLabel.userInteractionEnabled = NO;
    _pauseLabel.hidden = YES;
    [_dotButton addSubview:_pauseLabel];

    [self applyDotIcon];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(handleDotPan:)];
    pan.maximumNumberOfTouches = 1;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(handleDotTap:)];
    [tap requireGestureRecognizerToFail:pan];
    [_dotButton addGestureRecognizer:pan];
    [_dotButton addGestureRecognizer:tap];

    // 菜单：独立圆形按钮 + 下方文字标签（仿按键精灵，无容器面板）
    // 三种状态最多都是 3 个按钮，所以固定建 3 个槽位；具体是哪三个由 _menuTable 决定
    _menuButtons = [NSMutableArray array];
    _menuLabels  = [NSMutableArray array];
    _menuPanel = nil;  // 不再需要白色容器面板

    CGFloat btnSize  = _menuBtnSize;
    CGFloat labelH   = [self menuLabelHeight];

    NSArray *symbolNames = @[@"play.fill", @"checklist", @"arrow.uturn.backward.circle.fill"];
    NSArray *titles      = @[@"启动", @"功能", @"返回"];

    for (NSUInteger i = 0; i < symbolNames.count; i++) {
        UIButton *iconBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        iconBtn.frame = CGRectMake(0, 0, btnSize, btnSize);
        iconBtn.backgroundColor = [self menuBackgroundColor];  // 黑底（透明度可配置）
        iconBtn.layer.cornerRadius = btnSize / 2.0f;
        iconBtn.hidden = YES;
        iconBtn.alpha = 0.0f;
        if (@available(iOS 13.0, *)) {
            [iconBtn setImage:[UIImage systemImageNamed:symbolNames[i]] forState:UIControlStateNormal];
            iconBtn.tintColor = [self iconColor];
            iconBtn.imageEdgeInsets = UIEdgeInsetsMake(_menuIconInset, _menuIconInset, _menuIconInset, _menuIconInset);
        }
        [iconBtn addTarget:self action:@selector(handleMenuIconTap:) forControlEvents:UIControlEventTouchUpInside];
        [_content addSubview:iconBtn];
        [_menuButtons addObject:iconBtn];

        UILabel *lbl = [[UILabel alloc] init];
        lbl.text = titles[i];
        lbl.font = [UIFont systemFontOfSize:_menuLabelFont];
        lbl.textColor = [self labelColor];
        lbl.textAlignment = NSTextAlignmentCenter;
        lbl.frame = CGRectMake(0, 0, btnSize, labelH);
        lbl.backgroundColor = [self menuBackgroundColor];  // 黑底（透明度可配置）
        lbl.hidden = YES;
        lbl.alpha = 0.0f;
        lbl.layer.cornerRadius = 4;
        lbl.layer.masksToBounds = YES;
        [_content addSubview:lbl];
        [_menuLabels addObject:lbl];
    }

    // 三态一次性刷新：菜单按钮图标/文字 + 圆点暂停外观 + 旋转光圈，
    // 重建窗口后也保证「脚本运行中但光圈消失 / 暂停却还在转」不会出现。
    [FloatingMenu refreshScriptPlayState];

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

#pragma mark 圆点图标

// 0=字母Z（默认） 1=App图标 2=自定义图片。
// 后两种由 App 端导出 PNG 到共享目录；文件缺失/读取失败时回退成字母 Z。
- (void)applyDotIcon
{
    if (!_dotButton) {
        return;
    }

    UIImage *icon = nil;
    if (_dotIconMode == kFMDotIconModeApp) {
        icon = [UIImage imageWithContentsOfFile:fmDotIconAppPath()];
    } else if (_dotIconMode == kFMDotIconModeCustom) {
        icon = [UIImage imageWithContentsOfFile:fmDotIconCustomPath()];
    }

    // 原图留一份，暂停时转灰度用（灰度的结果不覆盖原图）
    _dotIconImage = icon;

    if (icon) {
        _dotIconView.image = icon;
        _dotIconView.frame = _dotButton.bounds;
        _dotIconView.hidden = NO;
        [_dotButton setTitle:@"" forState:UIControlStateNormal];
    } else {
        _dotIconView.image = nil;
        _dotIconView.hidden = YES;
        [_dotButton setTitle:@"Z" forState:UIControlStateNormal];
    }

    [self applyPauseAppearance];
}

#pragma mark 暂停外观

// 暂停态：圆点图标转灰度 + 叠加灰罩 + 叠加文字。
// 光圈不在这里管——由 applyScriptPlayState: 统一按状态启停。
- (void)applyPauseAppearance
{
    if (!_dotButton) {
        return;
    }
    BOOL paused = (_playState == FMScriptPlayStatePaused);

    if (_dotIconImage) {
        _dotIconView.image = paused ? fmGrayscaleImage(_dotIconImage) : _dotIconImage;
        _dotIconView.hidden = NO;
    } else {
        // 字母 Z 模式没有图片，直接把字色转灰
        _dotIconView.image = nil;
        _dotIconView.hidden = YES;
        UIColor *color = paused ? [UIColor colorWithWhite:0.55f alpha:1.0f] : [self iconColor];
        [_dotButton setTitleColor:color forState:UIControlStateNormal];
    }

    _pauseOverlay.hidden = !paused;
    _pauseOverlay.backgroundColor = [UIColor colorWithWhite:0.45f alpha:_pauseGrayAlpha];

    _pauseLabel.hidden = !paused;
    if (paused) {
        _pauseLabel.text = _pauseText;
        _pauseLabel.font = [UIFont boldSystemFontOfSize:_pauseFont];
        _pauseLabel.textColor = fmColorFromHex(_pauseTextColorHex, 1.0f) ?: [UIColor whiteColor];
    }
}

#pragma mark 菜单三态

// 按脚本当前状态刷新菜单按钮与圆点。
// 结果不缓存——暂停/停止可能由 App 端或脚本自然结束触发，缓存会显示过期状态。
+ (void)refreshScriptPlayState
{
    FMScriptPlayState state = FMScriptPlayStateIdle;
    if (isScriptPlaying()) {
        state = isScriptPaused() ? FMScriptPlayStatePaused : FMScriptPlayStateRunning;
    }
    [[self shared] applyScriptPlayState:state];
}

+ (void)setScriptIdle
{
    [[self shared] applyScriptPlayState:FMScriptPlayStateIdle];
}

// 当前状态该出哪些按钮：role 决定点击干什么（不看下标，按钮增减不会错位）
//   未运行 → 启动 / 功能 / 返回（脚本在「功能」页里选）
//   运行中 → 暂停 / 停止 / 返回     （用户要求：跑起来以后不再显示「功能」）
//   已暂停 → 启动 / 停止 / 返回
- (NSArray<NSDictionary *> *)menuTableForState:(FMScriptPlayState)state
{
    NSDictionary *play   = @{ @"role": @"start",    @"symbol": @"play.fill",  @"title": @"启动" };
    NSDictionary *pause  = @{ @"role": @"start",    @"symbol": @"pause.fill", @"title": @"暂停" };
    NSDictionary *stop   = @{ @"role": @"stop",     @"symbol": @"stop.fill",  @"title": @"停止" };
    NSDictionary *func   = @{ @"role": @"function", @"symbol": @"checklist",  @"title": @"功能" };
    NSDictionary *back   = @{ @"role": @"back",     @"symbol": @"arrow.uturn.backward.circle.fill", @"title": @"返回" };

    if (state == FMScriptPlayStateRunning) return @[ pause, stop, back ];
    if (state == FMScriptPlayStatePaused)  return @[ play,  stop, back ];
    return @[ play, func, back ];
}

- (void)applyScriptPlayState:(FMScriptPlayState)state
{
    _playState = state;

    NSArray<NSDictionary *> *table = [self menuTableForState:state];
    _menuTable = table;

    for (NSUInteger i = 0; i < _menuButtons.count; i++) {
        if (i >= table.count) continue;   // 这个状态下用不到的槽位，交给 applyGeometry 隐藏
        NSDictionary *item = table[i];
        UIButton *button = _menuButtons[i];
        if (@available(iOS 13.0, *)) {
            [button setImage:[UIImage systemImageNamed:item[@"symbol"]] forState:UIControlStateNormal];
        }
        if (i < _menuLabels.count) {
            _menuLabels[i].text = item[@"title"];
        }
    }

    [self applyPauseAppearance];

    // 光圈只在真正运行时转
    if (state == FMScriptPlayStateRunning) {
        [self startRunningSpinner];
    } else {
        [self stopRunningSpinner];
    }

    // 菜单开着的时候状态变了（点了启动/暂停），按钮个数和内容要跟着重排
    if (_expanded && !_menuAnimating) {
        [self applyGeometry];
    }
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
        // 四个按钮+标签的整体尺寸（与 buildWindow 共用同一组配置，不再各写一份）
        CGFloat btnSize  = _menuBtnSize;
        CGFloat btnGap   = _menuBtnGap;
        CGFloat labelH   = [self menuLabelHeight];
        CGFloat btnLabelGap = kFMMenuLabelGap;
        // 按钮个数跟当前状态的按钮表走（没表时退回全部槽位）
        NSUInteger btnCount = _menuTable ? _menuTable.count : _menuButtons.count;
        CGFloat totalBtnW = btnSize * btnCount + btnGap * (btnCount > 0 ? btnCount - 1 : 0);
        CGFloat rowH      = btnSize + btnLabelGap + labelH;

        // 横向位置：贴右 → 按钮在圆点左边；贴左 → 按钮在圆点右边
        CGFloat firstBtnX;
        if (_edge == 0) {
            firstBtnX = dot.x + dotRadius + _menuPanelGap;
        } else {
            firstBtnX = dot.x - dotRadius - _menuPanelGap - totalBtnW;
        }

        // 纵向：整体居中对齐圆点中心
        CGFloat startY = dot.y - rowH / 2.0f;

        for (NSUInteger i = 0; i < _menuButtons.count; i++) {
            UIButton *b = _menuButtons[i];
            UILabel *l = (i < _menuLabels.count) ? _menuLabels[i] : nil;
            if (i >= btnCount) {
                // 当前状态不显示这个按钮（如运行中不显示「功能」）→ 收干净，别留残影
                b.transform = CGAffineTransformIdentity;
                b.alpha = 0.0f;
                b.hidden = YES;
                l.transform = CGAffineTransformIdentity;
                l.alpha = 0.0f;
                l.hidden = YES;
                continue;
            }
            CGFloat bx = firstBtnX + i * (btnSize + btnGap);
            CGFloat by = startY;
            CGFloat ly = by + btnSize + btnLabelGap;
            // 先重置 transform（关键！transform 非 identity 时 frame 值不可靠）
            b.transform = CGAffineTransformIdentity;
            b.alpha = 1.0f;
            b.frame = CGRectMake(bx, by, btnSize, btnSize);
            b.hidden = NO;
            if (l) {
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
    // 展开是唯一能看到按钮的时机：此处按真实状态刷新「启动/暂停/继续」，
    // 避免脚本被 App 端或自然结束后这里还显示「暂停」
    [FloatingMenu refreshScriptPlayState];
    [self applyGeometry];  // 先让按钮/标签到正确位置

    CGPoint dotCenter = _dotButton.center;
    NSUInteger total = _menuTable ? _menuTable.count : _menuButtons.count;

    // 先保存正确位置（关键！不能改 frame 后再存）
    NSMutableArray *targets = [NSMutableArray array];
    for (NSUInteger i = 0; i < total; i++) {
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
    NSUInteger total = _menuTable ? _menuTable.count : _menuButtons.count;

    // 先保存当前位置（改 frame 之前）
    NSMutableArray *targets = [NSMutableArray array];
    for (NSUInteger i = 0; i < total; i++) {
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
    if (idx == NSNotFound || idx >= _menuTable.count) return;
    // 按 role 派发，不看下标——各状态按钮个数不同也不会点错
    NSString *role = _menuTable[idx][@"role"];
    // 不要在这里调 collapseMenu！每个 action 自己决定要不要收菜单：
    // actionStart 启动脚本后保持菜单打开（方便停止），其余 action 收菜单
    if ([role isEqualToString:@"start"]) {
        [self actionStart];
    } else if ([role isEqualToString:@"function"]) {
        [self actionFunction];
    } else if ([role isEqualToString:@"stop"]) {
        [self actionStop];
    } else if ([role isEqualToString:@"back"]) {
        [self actionBack];
    }
}

// 「功能」= 直接弹出独立的功能页窗口（选项 + 功能开关）
- (void)actionFunction
{
    [self collapseMenu];
    [[FunctionWindow shared] show];
}

#pragma mark - 菜单动作

- (void)actionStart
{
    [self collapseMenu];

    // 脚本在跑 → 这个按钮是「暂停 / 启动」；没跑 → 才是「启动」
    if (isScriptPlaying()) {
        if (isScriptPaused()) {
            resumeScriptPlaying();
            fmToast(@"已启动", 3);
        } else {
            pauseScriptPlaying();
            fmToast(@"已暂停", 3);
        }
        [FloatingMenu refreshScriptPlayState];
        return;
    }

    // 跑哪个脚本以「功能」页选的为准（设置入口已去掉）；没选过就用老记录 / 扫到的第一个
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *path = ZXLastFunctionScriptPath();
    if (path.length == 0 || ![fm fileExistsAtPath:path]) path = ZXFirstScriptPathWithFunctions();
    if (path.length == 0 || ![fm fileExistsAtPath:path]) {
        fmToast(@"请先到「功能」里选一个脚本", 2);
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

- (void)actionStop
{
    [self collapseMenu];
    // stopScriptPlaying 内部已经会停光圈并把状态刷回「未运行」，这里不再重复
    NSError *err = nil;
    stopScriptPlaying(&err);
    fmToast(@"已停止", 3);
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
                    self->_dotIconView = nil;
                    self->_dotIconImage = nil;
                    self->_pauseOverlay = nil;
                    self->_pauseLabel = nil;
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
            CGFloat menuBgAlpha = kFMMenuDefaultBgAlpha;
            CGFloat menuBtnSize = kFMMenuBtnSizeDefault;
            CGFloat menuBtnGap = kFMMenuBtnGapDefault;
            CGFloat menuLabelFont = kFMMenuLabelFontDefault;
            CGFloat menuIconInset = kFMMenuIconInsetDefault;
            CGFloat menuPanelGap = kFMMenuPanelGapDefault;
            NSInteger dotIconMode = kFMDotIconModeZ;
            NSString *dotBgColorHex = kFMDotBgColorDefault;
            NSString *menuBtnColorHex = kFMMenuBtnColorDefault;
            NSString *iconColorHex = kFMIconColorDefault;
            NSString *labelColorHex = kFMLabelColorDefault;
            NSString *pauseText = kFMPauseTextDefault;
            CGFloat pauseFont = kFMPauseFontDefault;
            NSString *pauseColorHex = kFMPauseColorDefault;
            CGFloat pauseGrayAlpha = kFMPauseGrayDefault;

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
                NSNumber *menuBgAlphaValue = config[kFMCfgMenuBgAlpha];
                if ([menuBgAlphaValue isKindOfClass:[NSNumber class]]) {
                    menuBgAlpha = [menuBgAlphaValue doubleValue];
                }
                NSNumber *menuBtnSizeValue = config[kFMCfgMenuBtnSize];
                if ([menuBtnSizeValue isKindOfClass:[NSNumber class]]) {
                    menuBtnSize = [menuBtnSizeValue doubleValue];
                }
                NSNumber *menuBtnGapValue = config[kFMCfgMenuBtnGap];
                if ([menuBtnGapValue isKindOfClass:[NSNumber class]]) {
                    menuBtnGap = [menuBtnGapValue doubleValue];
                }
                NSNumber *menuLabelFontValue = config[kFMCfgLabelFont];
                if ([menuLabelFontValue isKindOfClass:[NSNumber class]]) {
                    menuLabelFont = [menuLabelFontValue doubleValue];
                }
                NSNumber *menuIconInsetValue = config[kFMCfgIconInset];
                if ([menuIconInsetValue isKindOfClass:[NSNumber class]]) {
                    menuIconInset = [menuIconInsetValue doubleValue];
                }
                NSNumber *menuPanelGapValue = config[kFMCfgPanelGap];
                if ([menuPanelGapValue isKindOfClass:[NSNumber class]]) {
                    menuPanelGap = [menuPanelGapValue doubleValue];
                }
                NSNumber *dotIconValue = config[kFMCfgDotIcon];
                if ([dotIconValue isKindOfClass:[NSNumber class]]) {
                    dotIconMode = [dotIconValue integerValue];
                }
                if ([config[kFMCfgDotBgColor] isKindOfClass:[NSString class]]) {
                    dotBgColorHex = config[kFMCfgDotBgColor];
                }
                if ([config[kFMCfgMenuBtnColor] isKindOfClass:[NSString class]]) {
                    menuBtnColorHex = config[kFMCfgMenuBtnColor];
                }
                if ([config[kFMCfgIconColor] isKindOfClass:[NSString class]]) {
                    iconColorHex = config[kFMCfgIconColor];
                }
                if ([config[kFMCfgLabelColor] isKindOfClass:[NSString class]]) {
                    labelColorHex = config[kFMCfgLabelColor];
                }
                if ([config[kFMCfgPauseText] isKindOfClass:[NSString class]] &&
                    [config[kFMCfgPauseText] length] > 0) {
                    pauseText = config[kFMCfgPauseText];
                }
                NSNumber *pauseFontValue = config[kFMCfgPauseFont];
                if ([pauseFontValue isKindOfClass:[NSNumber class]]) {
                    pauseFont = [pauseFontValue doubleValue];
                }
                if ([config[kFMCfgPauseColor] isKindOfClass:[NSString class]]) {
                    pauseColorHex = config[kFMCfgPauseColor];
                }
                NSNumber *pauseGrayValue = config[kFMCfgPauseGray];
                if ([pauseGrayValue isKindOfClass:[NSNumber class]]) {
                    pauseGrayAlpha = [pauseGrayValue doubleValue];
                }
                if (!hasEdge) {
                    NSNumber *xValue = config[@"floating_menu_x"];
                    CGFloat pw, ph;
                    [self visualWidth:&pw height:&ph portrait:NULL];
                    if ([xValue isKindOfClass:[NSNumber class]]) {
                        edge = ([xValue doubleValue] < pw / 2.0f) ? 0 : 1;
                    }
                }
            }

            self->_edge = (edge == 0) ? 0 : 1;
            self->_yRatio = MIN(MAX(hasRatio ? ratio : 0.5f, 0.02f), 0.98f);
            self->_dotSize = MIN(MAX(dotSize, kFMDotMinSize), kFMDotMaxSize);
            self->_menuBgAlpha = MIN(MAX(menuBgAlpha, kFMMenuMinBgAlpha), kFMMenuMaxBgAlpha);
            self->_menuBtnSize = MIN(MAX(menuBtnSize, kFMMenuBtnSizeMin), kFMMenuBtnSizeMax);
            self->_menuBtnGap = MIN(MAX(menuBtnGap, kFMMenuBtnGapMin), kFMMenuBtnGapMax);
            self->_menuLabelFont = MIN(MAX(menuLabelFont, kFMMenuLabelFontMin), kFMMenuLabelFontMax);
            self->_menuIconInset = MIN(MAX(menuIconInset, kFMMenuIconInsetMin), kFMMenuIconInsetMax);
            self->_menuPanelGap = MIN(MAX(menuPanelGap, kFMMenuPanelGapMin), kFMMenuPanelGapMax);
            self->_dotIconMode = MIN(MAX(dotIconMode, kFMDotIconModeZ), kFMDotIconModeCustom);
            self->_dotBgColorHex = dotBgColorHex;
            self->_menuBtnColorHex = menuBtnColorHex;
            self->_iconColorHex = iconColorHex;
            self->_labelColorHex = labelColorHex;
            self->_pauseText = pauseText;
            self->_pauseFont = MIN(MAX(pauseFont, kFMPauseFontMin), kFMPauseFontMax);
            self->_pauseTextColorHex = pauseColorHex;
            self->_pauseGrayAlpha = MIN(MAX(pauseGrayAlpha, kFMPauseGrayMin), kFMPauseGrayMax);

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
    _dotIconView = nil;
    _dotIconImage = nil;
    _pauseOverlay = nil;
    _pauseLabel = nil;
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
    info[@"menu_bg_alpha"] = @(_menuBgAlpha);
    info[@"menu_btn_size"] = @(_menuBtnSize);
    info[@"menu_btn_gap"] = @(_menuBtnGap);
    info[@"menu_label_font"] = @(_menuLabelFont);
    info[@"menu_icon_inset"] = @(_menuIconInset);
    info[@"menu_panel_gap"] = @(_menuPanelGap);
    info[@"dot_icon_mode"] = @(_dotIconMode);
    info[@"dot_bg_color"] = _dotBgColorHex ?: @"";
    info[@"menu_btn_color"] = _menuBtnColorHex ?: @"";
    info[@"icon_color"] = _iconColorHex ?: @"";
    info[@"label_color"] = _labelColorHex ?: @"";
    info[@"pause_text"] = _pauseText ?: @"";
    info[@"pause_font"] = @(_pauseFont);
    info[@"pause_text_color"] = _pauseTextColorHex ?: @"";
    info[@"pause_gray_alpha"] = @(_pauseGrayAlpha);
    info[@"play_state"] = @(_playState);
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
