#import "FloatingMenu.h"
#import "Common.h"
#import "Screen.h"
#import "Play.h"
#import "Toast.h"
#import "AlertBox.h"
#import "Process.h"
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

#define kFMDotSize        48.0f
#define kFMDotRadius      (kFMDotSize / 2.0f)
#define kFMItemWidth      72.0f
#define kFMItemHeight     36.0f
#define kFMItemGap        8.0f
#define kFMDotMenuGap     10.0f
#define kFMSlideDist      14.0f
#define kFMAnim           0.18

#define kFMCfgEnabled     @"floating_menu_enabled"
#define kFMCfgEdge        @"floating_menu_edge"       // 1=贴视觉右边(默认) 0=左边
#define kFMCfgYRatio      @"floating_menu_y_ratio"   // 纵向位置 0..1
#define kFMCfgScript      @"floating_menu_script"
#define kFMZXTouchBID     @"com.zjx.zxtouch"

#pragma mark - 透传视图 / 根控制器

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
    // 与 1.0.2 旧版网速窗（位置验证正确）一致的角度
    switch (orientation) {
        case UIInterfaceOrientationLandscapeLeft:
            return CGAffineTransformMakeRotation(M_PI_2);
        case UIInterfaceOrientationLandscapeRight:
            return CGAffineTransformMakeRotation(-M_PI_2);
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
    UIWindow                 *_window;
    UIView                   *_content;
    UIButton                 *_dotButton;
    NSMutableArray<UIButton *> *_menuButtons; // 启动 / 设置 / 返回
    NSTimer                  *_watchTimer;

    BOOL     _enabled;
    BOOL     _expanded;
    BOOL     _dragging;
    BOOL     _observing;
    NSInteger _menuUp;        // 1 = 菜单按钮排在圆点上方；-1 = 下方；0 = 收起
    int      _edge;           // 1 右 / 0 左
    CGFloat  _yRatio;         // 圆点纵向位置比例
    int      _lastOrientation;

    CGPoint  _dragStartVisual;
    NSString *_scriptPath;
}

- (void)applyGeometry;
- (void)expandMenu;
- (void)collapseMenu;

@end

@implementation FloatingMenu

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
    CGFloat w, h;
    [self canvasPortraitWidth:&w height:&h];
    int o = [self currentOrientation];
    BOOL landscape = (o == UIInterfaceOrientationLandscapeLeft ||
                      o == UIInterfaceOrientationLandscapeRight);
    if (visW) { *visW = landscape ? h : w; }
    if (visH) { *visH = landscape ? w : h; }
    if (portrait) { *portrait = CGRectMake(0, 0, w, h); }
}

// 圆点在视觉坐标系的中心
- (CGPoint)dotVisualPoint
{
    CGFloat visW, visH;
    [self visualWidth:&visW height:&visH portrait:NULL];
    CGFloat y = _yRatio * visH;
    y = MIN(MAX(y, kFMDotRadius + 2.0f), visH - kFMDotRadius - 2.0f);
    CGFloat x = (_edge == 0) ? kFMDotRadius : (visW - kFMDotRadius);
    return CGPointMake(x, y);
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
    CGRect portrait;
    [self visualWidth:NULL height:NULL portrait:&portrait];

    UIWindowScene *scene = [FloatingMenu preferredWindowScene];
    if (scene) {
        _window = [[UIWindow alloc] initWithWindowScene:scene];
        _window.frame = portrait;
    } else {
        _window = [[UIWindow alloc] initWithFrame:portrait];
    }
    _window.windowLevel = UIWindowLevelStatusBar + 2;
    _window.backgroundColor = [UIColor clearColor];
    _window.userInteractionEnabled = YES;
    _window.autoresizingMask = UIViewAutoresizingNone;

    FMRootViewController *root = [[FMRootViewController alloc] init];
    UIView *rootView = root.view; // 触发 loadView，得到全屏透传视图
    rootView.frame = portrait;
    _window.rootViewController = root;

    // _content 也必须是透传视图：它占满全屏，若用普通 UIView，所有触摸都会命中它而无法落到下层 app
    _content = [[FMPassthroughView alloc] initWithFrame:portrait];
    _content.backgroundColor = [UIColor clearColor];
    [rootView addSubview:_content];

    // 圆点
    _dotButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _dotButton.frame = CGRectMake(0, 0, kFMDotSize, kFMDotSize);
    _dotButton.backgroundColor = [UIColor colorWithRed:20.0f / 255.0f
                                                green:20.0f / 255.0f
                                                 blue:28.0f / 255.0f
                                                alpha:0.82f];
    _dotButton.layer.cornerRadius = kFMDotRadius;
    _dotButton.titleLabel.font = [UIFont systemFontOfSize:22.0f weight:UIFontWeightBold];
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

    // 菜单按钮（固定顺序：启动 / 设置 / 返回，展开时沿纵向排列）
    _menuButtons = [NSMutableArray arrayWithCapacity:3];
    NSArray<NSString *> *titles = @[@"启动", @"设置", @"返回"];
    for (NSString *title in titles) {
        UIButton *item = [UIButton buttonWithType:UIButtonTypeCustom];
        item.frame = CGRectMake(0, 0, kFMItemWidth, kFMItemHeight);
        item.backgroundColor = [UIColor colorWithRed:20.0f / 255.0f
                                               green:20.0f / 255.0f
                                                blue:28.0f / 255.0f
                                               alpha:0.88f];
        item.layer.cornerRadius = kFMItemHeight / 2.0f;
        item.titleLabel.font = [UIFont systemFontOfSize:15.0f weight:UIFontWeightSemibold];
        [item setTitle:title forState:UIControlStateNormal];
        [item setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        item.hidden = YES;
        item.alpha = 0.0f;
        [_content addSubview:item];
        [_menuButtons addObject:item];
    }
    [_menuButtons[0] addTarget:self action:@selector(actionStart) forControlEvents:UIControlEventTouchUpInside];
    [_menuButtons[1] addTarget:self action:@selector(actionSettings) forControlEvents:UIControlEventTouchUpInside];
    [_menuButtons[2] addTarget:self action:@selector(actionBack) forControlEvents:UIControlEventTouchUpInside];

    _lastOrientation = [self currentOrientation];
    [self applyGeometry];

    _window.hidden = NO;
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
    BOOL landscape = (orientation == UIInterfaceOrientationLandscapeLeft ||
                      orientation == UIInterfaceOrientationLandscapeRight);
    _lastOrientation = orientation;

    // 1) 容器归位 + 视觉尺寸 + 旋转
    _content.transform = CGAffineTransformIdentity;
    if (landscape) {
        _content.bounds = CGRectMake(0, 0, portrait.size.height, portrait.size.width);
    } else {
        _content.bounds = CGRectMake(0, 0, portrait.size.width, portrait.size.height);
    }
    _content.center = CGPointMake(portrait.size.width / 2.0f, portrait.size.height / 2.0f);

    CGPoint dot = [self dotVisualPoint];

    if (!_expanded) {
        // 2a) 收起态：圆点贴边半隐藏
        for (UIButton *item in _menuButtons) {
            item.hidden = YES;
            item.alpha = 0.0f;
        }
        _dotButton.transform = CGAffineTransformIdentity;
        _dotButton.frame = CGRectMake(dot.x - kFMDotRadius, dot.y - kFMDotRadius,
                                      kFMDotSize, kFMDotSize);
    } else {
        // 2b) 展开态：菜单列在圆点靠屏幕内侧，纵向朝空间足的一侧
        // 横向：贴右 → 按钮在圆点左边；贴左 → 在右边
        CGFloat itemCenterX;
        if (_edge == 0) {
            itemCenterX = kFMDotRadius + kFMDotMenuGap + kFMItemWidth / 2.0f;
        } else {
            itemCenterX = visW - kFMDotRadius - kFMDotMenuGap - kFMItemWidth / 2.0f;
        }

        // 纵向：三个按钮总高 124，离圆点最近的「启动」中心距圆点中心 52
        CGFloat menuSpan = kFMItemHeight * 3.0f + kFMItemGap * 2.0f; // 124
        if (!_dragging) {
            CGFloat needUp = dot.y - kFMDotRadius - kFMDotMenuGap - menuSpan; // 上方剩余
            CGFloat needDownBottom = dot.y + kFMDotRadius + kFMDotMenuGap + menuSpan;
            if (needUp >= 6.0f) {
                _menuUp = 1;
            } else if (needDownBottom <= visH - 6.0f) {
                _menuUp = -1;
            } else {
                // 两侧都紧张时选剩余多的一侧，并做夹取
                _menuUp = (needUp >= (visH - needDownBottom)) ? 1 : -1;
            }
        }

        CGFloat nearest = dot.y + (_menuUp > 0 ? -52.0f : 52.0f); // 启动中心
        CGFloat centers[3];
        centers[0] = nearest;
        centers[1] = nearest + (_menuUp > 0 ? -44.0f : 44.0f);
        centers[2] = nearest + (_menuUp > 0 ? -88.0f : 88.0f);
        for (NSUInteger i = 0; i < 3; i++) {
            centers[i] = MIN(MAX(centers[i], kFMItemHeight / 2.0f + 4.0f),
                             visH - kFMItemHeight / 2.0f - 4.0f);
        }

        _dotButton.transform = CGAffineTransformIdentity;
        _dotButton.frame = CGRectMake(dot.x - kFMDotRadius, dot.y - kFMDotRadius,
                                      kFMDotSize, kFMDotSize);
        for (NSUInteger i = 0; i < _menuButtons.count; i++) {
            UIButton *item = _menuButtons[i];
            item.hidden = NO;
            item.frame = CGRectMake(itemCenterX - kFMItemWidth / 2.0f,
                                    centers[i] - kFMItemHeight / 2.0f,
                                    kFMItemWidth, kFMItemHeight);
        }
    }

    _content.transform = fmTransformForOrientation(orientation);
}

#pragma mark 展开 / 收起

- (void)expandMenu
{
    if (_expanded || !_window) {
        return;
    }
    _expanded = YES;
    _menuUp = 1;
    [self applyGeometry];

    for (UIButton *item in _menuButtons) {
        item.alpha = 0.0f;
        item.transform = CGAffineTransformMakeTranslation((_edge == 0 ? -1 : 1) * kFMSlideDist, 0);
    }
    [UIView animateWithDuration:kFMAnim
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        for (UIButton *item in self->_menuButtons) {
            item.alpha = 1.0f;
            item.transform = CGAffineTransformIdentity;
        }
    } completion:nil];
}

- (void)collapseMenu
{
    if (!_expanded || !_window) {
        return;
    }
    NSInteger edge = _edge;
    [UIView animateWithDuration:kFMAnim
                     animations:^{
        for (UIButton *item in self->_menuButtons) {
            item.alpha = 0.0f;
            item.transform = CGAffineTransformMakeTranslation((edge == 0 ? -1 : 1) * kFMSlideDist, 0);
        }
    } completion:^(BOOL finished) {
        self->_expanded = NO;
        for (UIButton *item in self->_menuButtons) {
            item.hidden = YES;
            item.alpha = 0.0f;
            item.transform = CGAffineTransformIdentity;
        }
        [self applyGeometry];
    }];
}

- (void)toggleMenu
{
    if (_expanded) {
        [self collapseMenu];
    } else {
        [self expandMenu];
    }
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

    if (pan.state == UIGestureRecognizerStateBegan) {
        _dragging = YES;
        _dragStartVisual = [self dotVisualPoint];
        // 拖动开始即把菜单收起，避免视觉干扰
        if (_expanded) {
            for (UIButton *item in _menuButtons) {
                item.hidden = YES;
                item.alpha = 0.0f;
            }
            _expanded = NO;
        }
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        // translationInView 已扣除 contentView 的旋转，拿到的是视觉位移
        CGPoint t = [pan translationInView:_content];
        CGFloat x = MIN(MAX(_dragStartVisual.x + t.x, kFMDotRadius), visW - kFMDotRadius);
        CGFloat y = MIN(MAX(_dragStartVisual.y + t.y, kFMDotRadius + 2.0f), visH - kFMDotRadius - 2.0f);

        _content.transform = CGAffineTransformIdentity;
        _dotButton.frame = CGRectMake(x - kFMDotRadius, y - kFMDotRadius, kFMDotSize, kFMDotSize);
        _content.transform = fmTransformForOrientation([self currentOrientation]);
    } else if (pan.state == UIGestureRecognizerStateEnded ||
               pan.state == UIGestureRecognizerStateCancelled ||
               pan.state == UIGestureRecognizerStateFailed) {
        CGPoint t = [pan translationInView:_content];
        CGFloat x = MIN(MAX(_dragStartVisual.x + t.x, kFMDotRadius), visW - kFMDotRadius);
        CGFloat y = MIN(MAX(_dragStartVisual.y + t.y, kFMDotRadius + 2.0f), visH - kFMDotRadius - 2.0f);

        // 吸附：离哪条竖边近贴哪条，圆点中心压在边线上 → 正好露出一半
        int newEdge = (x < visW / 2.0f) ? 0 : 1;
        _dragging = NO;
        _edge = newEdge;
        _yRatio = y / visH;

        fmPersistKeys(@{
            kFMCfgEdge: @(newEdge),
            kFMCfgYRatio: @(_yRatio)
        });

        [self applyGeometry];
    }
}

#pragma mark 菜单动作

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
    [self collapseMenu];
    [self launchZXTouchApp];
}

#pragma mark 返回 ZXTouch app

// 使用 SpringBoard Services 私有函数 SBSLaunchApplicationWithIdentifier
// （与 Process.xm / ScriptPlayer.xm 的 bringAppForeground 同源，已在项目中验证可靠）
- (void)launchZXTouchApp
{
    NSString *bundleID = kFMZXTouchBID;
    void (^tryForeground)(void) = ^{
        @try {
            bringAppForeground(bundleID);
        } @catch (NSException *exception) {
            ZXLogUIException(exception);
        }
    };
    if ([NSThread isMainThread]) {
        tryForeground();
    } else {
        dispatch_sync(dispatch_get_main_queue(), tryForeground);
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
            if (!self->_enabled) {
                return;
            }
            // 自愈 1：window 丢了就重建（覆盖 scene 被系统拆除等极端情况）
            if (!self->_window) {
                [self buildWindow];
                return;
            }
            // 自愈 2：当前 scene 已断开/脱离时，才重新挂一个可用 scene
            @try {
                UIWindowScene *current = self->_window.windowScene;
                BOOL healthy = current &&
                    [[UIApplication sharedApplication].connectedScenes containsObject:current] &&
                    current.activationState != UISceneActivationStateUnattached;
                if (!healthy) {
                    UIWindowScene *scene = [FloatingMenu preferredWindowScene];
                    if (scene) {
                        self->_window.windowScene = scene;
                    }
                }
            } @catch (NSException *exception) {
                ZXLogUIException(exception);
            }
            // 自愈 3：被系统置 hidden 时恢复
            if (self->_window.hidden) {
                self->_window.hidden = NO;
            }
            // 方向变化时重新布局
            int orientation = [self currentOrientation];
            if (orientation != self->_lastOrientation) {
                [self applyGeometry];
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
                    UIWindowScene *scene = [FloatingMenu preferredWindowScene];
                    if (scene && self->_window.windowScene != scene) {
                        self->_window.windowScene = scene;
                    }
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
    BOOL enabled = NO;
    BOOL hasEdge = NO;
    int edge = 1;
    BOOL hasRatio = NO;
    CGFloat ratio = 0.5f;
    NSString *script = @"";

    @try {
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

            // 兼容旧版 floating_menu_x/y：存在且没有新键时，按 x 推断贴边
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
    } @catch (NSException *exception) {
        ZXLogUIException(exception);
    }

    _edge = (edge == 0) ? 0 : 1;
    _yRatio = MIN(MAX(hasRatio ? ratio : 0.5f, 0.02f), 0.98f);
    _scriptPath = script;

    [self setEnabled:enabled persist:NO];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
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

        if (action != 0 && action != 1) {
            if (error) {
                *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp"
                                             code:999
                                         userInfo:@{NSLocalizedDescriptionKey:@"-1;;数据格式应为 \"enabled\"（1=开启, 0=关闭, 2=查询）\r\n"}];
            }
            return nil;
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
