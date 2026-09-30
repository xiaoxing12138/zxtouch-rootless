#import "FloatingMenu.h"
#import "Common.h"
#import "Screen.h"
#import "Play.h"
#import "Toast.h"
#import "AlertBox.h"
#import <objc/message.h>
#include <roothide.h>

/*
 * 按键精灵式悬浮控制按钮
 * ----------------------
 * 坐标空间模型与 NetSpeedIndicator.xm 完全一致：
 *   - 保存/计算一律使用「竖屏固定坐标空间」（短边为宽、长边为高）；
 *   - UIWindow 的 frame 按竖屏空间摆放，再按当前方向对 window 整体做
 *     CGAffineTransform 旋转，圆点在任意方向下都显示在预期位置；
 *   - 方向来源用 [Screen getScreenOrientation]（读最前台 app 方向，
 *     iPad 上比 scene.interfaceOrientation / 状态栏通知可靠），每秒轮询
 *     一次检测变化，状态栏方向通知作为辅助；
 *   - window 只包住「圆点 + 展开菜单」，不全屏、不加遮罩，菜单外的触摸
 *     全部透传给普通 app，避免把设备点进安全模式。
 */

#define kFloatingDotSize       48.0f
#define kFloatingDotCorner     24.0f
#define kFloatingEdgeMargin    8.0f
#define kFloatingMenuWidth     72.0f
#define kFloatingMenuItemH     36.0f
#define kFloatingMenuItemGap   8.0f
#define kFloatingMenuDotGap    10.0f
#define kFloatingMenuAnim      0.18
// 3 个按钮 + 两个按钮间隙 + 按钮与圆点间隙 + 圆点
#define kFloatingMenuHeight    (kFloatingMenuItemH * 3.0f + kFloatingMenuItemGap * 2.0f + kFloatingMenuDotGap + kFloatingDotSize)
// 展开后圆点中心相对 window 中心的纵向偏移（window 高 182，圆点 48）
#define kFloatingCenterYOffset (kFloatingMenuHeight / 2.0f - kFloatingDotSize / 2.0f)
#define kFloatingSlideDist     14.0f

#define kFloatingCfgEnabled    @"floating_menu_enabled"
#define kFloatingCfgPosX       @"floating_menu_x"
#define kFloatingCfgPosY       @"floating_menu_y"
#define kFloatingCfgScript     @"floating_menu_script"
#define kFloatingZXTouchBID    @"com.zjx.zxtouch"

static FloatingMenu *_fmShared = nil;

#pragma mark - C helpers

static CGAffineTransform fmTransformForOrientation(int orientation)
{
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
    // type: 1 error / 2 warning / 3 message / 4 success；position 1 底部
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
    UIButton                 *_dotButton;
    NSMutableArray<UIButton *> *_menuButtons; // 启动 / 设置 / 返回
    NSTimer                  *_watchTimer;

    BOOL     _enabled;
    BOOL     _expanded;
    BOOL     _isCollapsing;
    NSInteger _menuDirection;   //  1 = 菜单在圆点上方；-1 = 下方；0 = 收起
    BOOL     _dragging;
    BOOL     _observing;
    CGPoint  _dragStartDot;
    NSInteger _dragDirection;

    CGPoint  _dotPortrait;      // 竖屏坐标空间内圆点中心
    NSString *_scriptPath;      // 选中的 .bdl 绝对路径
    int      _lastOrientation;
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

#pragma mark 坐标工具

- (void)portraitCanvasWidth:(CGFloat *)width height:(CGFloat *)height
{
    CGRect bounds = [Screen getBounds];
    CGFloat w = MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    CGFloat h = MAX(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    if (w <= 0) { w = 375.0f; }
    if (h <= 0) { h = 667.0f; }
    if (width)  { *width = w; }
    if (height) { *height = h; }
}

// 圆点中心夹取（竖屏空间）。expandedDir 非 0 时，按展开方向保证整块菜单也在屏内。
- (CGPoint)clampDot:(CGPoint)p expandedDirection:(NSInteger)expandedDir
{
    CGFloat w, h;
    [self portraitCanvasWidth:&w height:&h];
    CGFloat r = kFloatingDotSize / 2.0f;

    CGFloat minX = kFloatingEdgeMargin + r;
    CGFloat maxX = w - kFloatingEdgeMargin - r;
    CGFloat minY = kFloatingEdgeMargin + r;
    CGFloat maxY = h - kFloatingEdgeMargin - r;

    if (expandedDir > 0) {
        // 菜单在上方：window 顶边 = p.y - 158
        minY = kFloatingEdgeMargin + kFloatingCenterYOffset + kFloatingMenuHeight / 2.0f;
    } else if (expandedDir < 0) {
        // 菜单在下方：window 底边 = p.y + 158
        maxY = h - kFloatingEdgeMargin - kFloatingCenterYOffset - kFloatingMenuHeight / 2.0f;
    }

    if (minY > maxY) { // 极小屏兜底
        minY = kFloatingEdgeMargin + r;
        maxY = h - kFloatingEdgeMargin - r;
    }

    p.x = MIN(MAX(p.x, minX), maxX);
    p.y = MIN(MAX(p.y, minY), maxY);
    return p;
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
    UIWindowScene *scene = [FloatingMenu preferredWindowScene];
    CGRect dotFrame = CGRectMake(0, 0, kFloatingDotSize, kFloatingDotSize);

    // scene-less UIWindow 在 iOS 17+ 会直接崩 SpringBoard（见 NetSpeedIndicator.xm）
    if (scene) {
        _window = [[UIWindow alloc] initWithWindowScene:scene];
    } else {
        _window = [[UIWindow alloc] initWithFrame:dotFrame];
    }
    _window.frame = dotFrame;
    _window.windowLevel = UIWindowLevelStatusBar + 2;
    _window.backgroundColor = [UIColor clearColor];
    _window.userInteractionEnabled = YES;
    _window.autoresizingMask = UIViewAutoresizingNone;
    _window.clipsToBounds = NO;

    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = [UIColor clearColor];
    root.view.frame = dotFrame;
    root.view.clipsToBounds = NO;
    root.view.multipleTouchEnabled = NO;
    _window.rootViewController = root;

    // 圆点
    _dotButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _dotButton.frame = dotFrame;
    _dotButton.backgroundColor = [UIColor colorWithRed:20.0f / 255.0f
                                                green:20.0f / 255.0f
                                                 blue:28.0f / 255.0f
                                                alpha:0.75f];
    _dotButton.layer.cornerRadius = kFloatingDotCorner;
    _dotButton.titleLabel.font = [UIFont systemFontOfSize:22.0f weight:UIFontWeightBold];
    [_dotButton setTitle:@"Z" forState:UIControlStateNormal];
    [_dotButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _dotButton.adjustsImageWhenHighlighted = NO;
    _dotButton.userInteractionEnabled = YES;
    [root.view addSubview:_dotButton];

    // 拖动（平移超过系统阈值才进入 began）与轻点互斥：拖动时不触发点击
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(handleDotPan:)];
    pan.maximumNumberOfTouches = 1;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(handleDotTap:)];
    [tap requireGestureRecognizerToFail:pan];
    [_dotButton addGestureRecognizer:pan];
    [_dotButton addGestureRecognizer:tap];

    // 展开菜单按钮（自下而上：启动 / 设置 / 返回）
    _menuButtons = [NSMutableArray arrayWithCapacity:3];
    NSArray<NSString *> *titles = @[@"启动", @"设置", @"返回"];
    for (NSString *title in titles) {
        UIButton *item = [UIButton buttonWithType:UIButtonTypeCustom];
        item.frame = CGRectMake(0, 0, kFloatingMenuWidth, kFloatingMenuItemH);
        item.backgroundColor = [UIColor colorWithRed:20.0f / 255.0f
                                               green:20.0f / 255.0f
                                                blue:28.0f / 255.0f
                                               alpha:0.78f];
        item.layer.cornerRadius = kFloatingMenuItemH / 2.0f;
        item.titleLabel.font = [UIFont systemFontOfSize:15.0f weight:UIFontWeightSemibold];
        [item setTitle:title forState:UIControlStateNormal];
        [item setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        item.hidden = YES;
        item.alpha = 0.0f;
        [root.view addSubview:item];
        [_menuButtons addObject:item];
    }
    [_menuButtons[0] addTarget:self action:@selector(actionStart) forControlEvents:UIControlEventTouchUpInside];
    [_menuButtons[1] addTarget:self action:@selector(actionSettings) forControlEvents:UIControlEventTouchUpInside];
    [_menuButtons[2] addTarget:self action:@selector(actionBack) forControlEvents:UIControlEventTouchUpInside];

    _lastOrientation = [Screen getScreenOrientation];
    [self applyGeometry];

    _window.hidden = NO;
}

#pragma mark 几何布局（必须主线程）

- (void)applyGeometry
{
    if (!_window) {
        return;
    }

    if (!_dragging) {
        _dotPortrait = [self clampDot:_dotPortrait expandedDirection:0];
    }
    CGPoint dot = _dotPortrait;

    int orientation = [Screen getScreenOrientation];
    if (orientation != UIInterfaceOrientationPortrait &&
        orientation != UIInterfaceOrientationPortraitUpsideDown &&
        orientation != UIInterfaceOrientationLandscapeLeft &&
        orientation != UIInterfaceOrientationLandscapeRight) {
        orientation = UIInterfaceOrientationPortrait;
    }
    _lastOrientation = orientation;

    // 旋转期间 frame 无意义，先归位 transform 再改 frame
    _window.transform = CGAffineTransformIdentity;

    UIView *rootView = _window.rootViewController.view;

    if (!_expanded) {
        _window.frame = CGRectMake(dot.x - kFloatingDotSize / 2.0f,
                                   dot.y - kFloatingDotSize / 2.0f,
                                   kFloatingDotSize, kFloatingDotSize);
        rootView.frame = _window.bounds;
        _dotButton.frame = CGRectMake(0, 0, kFloatingDotSize, kFloatingDotSize);
    } else {
        if (!_dragging) {
            // 上方放得下（window 顶边 >= margin）就朝上展开，否则朝下
            _menuDirection = (dot.y - (kFloatingCenterYOffset + kFloatingMenuHeight / 2.0f) >= kFloatingEdgeMargin) ? 1 : -1;
        }

        CGFloat centerY = (_menuDirection > 0) ? (dot.y - kFloatingCenterYOffset)
                                               : (dot.y + kFloatingCenterYOffset);
        _window.frame = CGRectMake(dot.x - kFloatingMenuWidth / 2.0f,
                                   centerY - kFloatingMenuHeight / 2.0f,
                                   kFloatingMenuWidth, kFloatingMenuHeight);
        rootView.frame = _window.bounds;

        CGFloat yPositions[3];
        if (_menuDirection > 0) {
            // 圆点贴底 (12,134)；按钮自下而上 启动 88 / 设置 44 / 返回 0
            _dotButton.frame = CGRectMake((kFloatingMenuWidth - kFloatingDotSize) / 2.0f,
                                          kFloatingMenuHeight - kFloatingDotSize,
                                          kFloatingDotSize, kFloatingDotSize);
            yPositions[0] = 88.0f;
            yPositions[1] = 44.0f;
            yPositions[2] = 0.0f;
        } else {
            // 圆点贴顶 (12,0)；按钮自上而下 启动 58 / 设置 102 / 返回 146
            _dotButton.frame = CGRectMake((kFloatingMenuWidth - kFloatingDotSize) / 2.0f,
                                          0,
                                          kFloatingDotSize, kFloatingDotSize);
            yPositions[0] = 58.0f;
            yPositions[1] = 102.0f;
            yPositions[2] = 146.0f;
        }
        for (NSUInteger i = 0; i < _menuButtons.count; i++) {
            [_menuButtons[i] setFrame:CGRectMake(0, yPositions[i],
                                                 kFloatingMenuWidth, kFloatingMenuItemH)];
        }
    }

    _window.transform = fmTransformForOrientation(orientation);
}

#pragma mark 展开 / 收起

- (void)expandMenu
{
    if (_expanded || !_window) {
        return;
    }
    _expanded = YES;
    _isCollapsing = NO;
    _menuDirection = (_dotPortrait.y - (kFloatingCenterYOffset + kFloatingMenuHeight / 2.0f) >= kFloatingEdgeMargin) ? 1 : -1;

    for (UIButton *item in _menuButtons) {
        item.hidden = NO;
        item.alpha = 0.0f;
        item.transform = CGAffineTransformMakeTranslation(0, _menuDirection > 0 ? kFloatingSlideDist : -kFloatingSlideDist);
    }
    [self applyGeometry];

    [UIView animateWithDuration:kFloatingMenuAnim
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
    _isCollapsing = YES;
    NSInteger direction = _menuDirection;
    [UIView animateWithDuration:kFloatingMenuAnim
                     animations:^{
        for (UIButton *item in self->_menuButtons) {
            item.alpha = 0.0f;
            item.transform = CGAffineTransformMakeTranslation(0, direction > 0 ? kFloatingSlideDist : -kFloatingSlideDist);
        }
    } completion:^(BOOL finished) {
        for (UIButton *item in self->_menuButtons) {
            item.hidden = YES;
            item.alpha = 0.0f;
            item.transform = CGAffineTransformIdentity;
        }
        self->_expanded = NO;
        self->_isCollapsing = NO;
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
    // translationInView: 会自动扣除 window 的旋转 transform，
    // 拿到的位移正好就是竖屏坐标空间下的位移。
    NSInteger frozenDir = _expanded ? _dragDirection : 0;

    if (pan.state == UIGestureRecognizerStateBegan) {
        _dragging = YES;
        _dragStartDot = _dotPortrait;
        _dragDirection = _menuDirection;
        frozenDir = _expanded ? _dragDirection : 0;
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [pan translationInView:_window];
        CGPoint p = CGPointMake(_dragStartDot.x + t.x, _dragStartDot.y + t.y);
        _dotPortrait = [self clampDot:p expandedDirection:frozenDir];
        [self applyGeometry];
    } else if (pan.state == UIGestureRecognizerStateEnded ||
               pan.state == UIGestureRecognizerStateCancelled ||
               pan.state == UIGestureRecognizerStateFailed) {
        CGPoint t = [pan translationInView:_window];
        CGPoint p = CGPointMake(_dragStartDot.x + t.x, _dragStartDot.y + t.y);
        _dotPortrait = [self clampDot:p expandedDirection:frozenDir];
        _dragging = NO;

        fmPersistKeys(@{
            kFloatingCfgPosX: @(_dotPortrait.x),
            kFloatingCfgPosY: @(_dotPortrait.y)
        });

        BOOL wasExpanded = _expanded;
        [self applyGeometry];
        // 拖动时菜单保持展开会造成语义混乱，松手后统一收起
        if (wasExpanded) {
            [self collapseMenu];
        }
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
            fmPersistKeys(@{ kFloatingCfgScript: full });
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

// 优先走 SpringBoard 私有接口 SBApplicationController（与 Process.xm 的切 app 思路同源，
// 但这里直接在 SpringBoard 进程内调用自己的单例，不需要 SpringBoardServices）
- (BOOL)tryPrivateOpenApp:(NSString *)bundleID
{
    __block BOOL succeeded = NO;
    void (^attempt)(void) = ^{
        @try {
            Class cls = NSClassFromString(@"SBApplicationController");
            if (cls) {
                id controller = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstance));
                SEL openSEL = @selector(openApplicationWithBundleID:);
                if (controller && [controller respondsToSelector:openSEL]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(controller, openSEL, bundleID);
                    succeeded = YES;
                }
            }
        } @catch (NSException *exception) {
            succeeded = NO;
            ZXLogUIException(exception);
        }
    };

    if ([NSThread isMainThread]) {
        attempt();
    } else {
        dispatch_sync(dispatch_get_main_queue(), attempt);
    }
    return succeeded;
}

- (void)launchZXTouchApp
{
    NSString *bundleID = kFloatingZXTouchBID;

    if ([self tryPrivateOpenApp:bundleID]) {
        return;
    }

    // fallback：rootless uiopen，再退到 rootless 的 open 命令（经 system2 的 /bin/sh -c 执行）
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            @try {
                NSString *command = nil;
                NSString *uiopen = jbroot(@"/usr/bin/uiopen");
                if (uiopen.length > 0 && [[NSFileManager defaultManager] isExecutableFileAtPath:uiopen]) {
                    command = [NSString stringWithFormat:@"\"%@\" %@", uiopen, bundleID];
                } else {
                    command = [NSString stringWithFormat:@"open %@", bundleID];
                }
                pid_t pid = system2([command UTF8String], NULL, NULL);
                if (pid < 0) {
                    ZXSafeMainAsync(^{
                        fmToast([NSString stringWithFormat:@"无法返回 ZXTouch（%@）", bundleID], 1);
                    });
                }
            } @catch (NSException *exception) {
                ZXLogUIException(exception);
            }
        }
    });
}

#pragma mark 旋转监听

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
    // 状态栏通知在 iPad 上不可靠，这里每秒轮询一次方向，变化时重新夹取/布局
    int orientation = [Screen getScreenOrientation];
    if (orientation != _lastOrientation) {
        ZXSafeMainAsync(^{
            @try {
                [self applyGeometry];
            } @catch (NSException *exception) {
                ZXLogUIException(exception);
            }
        });
    }
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
        fmPersistKeys(@{ kFloatingCfgEnabled: @(enabled) });
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
                    self->_dotButton = nil;
                    self->_menuButtons = nil;
                    self->_expanded = NO;
                    self->_isCollapsing = NO;
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
    BOOL hasPosition = NO;
    CGPoint savedPosition = CGPointZero;
    NSString *script = @"";

    @try {
        NSDictionary *config = [[NSDictionary alloc] initWithContentsOfFile:fmConfigPath()];
        if ([config isKindOfClass:[NSDictionary class]]) {
            enabled = [config[kFloatingCfgEnabled] boolValue];

            NSNumber *xValue = config[kFloatingCfgPosX];
            NSNumber *yValue = config[kFloatingCfgPosY];
            if ([xValue isKindOfClass:[NSNumber class]] && [yValue isKindOfClass:[NSNumber class]]) {
                savedPosition = CGPointMake([xValue doubleValue], [yValue doubleValue]);
                hasPosition = YES;
            }

            NSString *savedScript = config[kFloatingCfgScript];
            if ([savedScript isKindOfClass:[NSString class]]) {
                script = savedScript;
            }
        }
    } @catch (NSException *exception) {
        ZXLogUIException(exception);
    }

    CGFloat canvasW, canvasH;
    [self portraitCanvasWidth:&canvasW height:&canvasH];
    CGPoint defaultPosition = CGPointMake(canvasW - kFloatingEdgeMargin - kFloatingDotSize / 2.0f,
                                          canvasH / 2.0f);

    _scriptPath = script;
    _dotPortrait = hasPosition ? [self clampDot:savedPosition expandedDirection:0]
                               : defaultPosition;

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
