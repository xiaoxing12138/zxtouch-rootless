#import "NetSpeedIndicator.h"
#import "FloatingMenu.h"    // FMPassthroughWindow + preferredWindowScene
#import "Screen.h"
#import "Common.h"

#include <ifaddrs.h>
#include <net/if.h>
#include <string.h>
#import <notify.h>

#define kNetSpeedCornerRadius 4.0f
#define kNetSpeedDefaultFontSize 11.0f
#define kNetSpeedDefaultMargin 10.0f

// 配置键（config.plist）
static NSString *const kCfgEnabled     = @"net_speed_indicator_enabled";
static NSString *const kCfgCorner      = @"net_speed_corner";        // 0右上 1左上 2左下 3右下
static NSString *const kCfgMarginX     = @"net_speed_margin_x";      // 视觉水平边距 pt
static NSString *const kCfgMarginY     = @"net_speed_margin_y";      // 视觉垂直边距 pt
static NSString *const kCfgMarginLegacy = @"net_speed_margin";       // 旧版单边距，仅作缺省回退
static NSString *const kCfgFontSize    = @"net_speed_font_size";
static NSString *const kCfgPauseOff    = @"net_speed_pause_screen_off";

static FMPassthroughWindow *_netSpeedWindow = nil;
static UIView   *_netSpeedContent = nil;  // 视觉坐标容器（跟随方向旋转）
static UILabel  *_netSpeedLabel = nil;
static NSTimer  *_netSpeedTimer = nil;
static BOOL _netSpeedEnabled = NO;
static uint64_t _lastRxBytes = 0;
static uint64_t _lastTxBytes = 0;
static BOOL _firstSample = YES;

// 可配置参数
static int _cfgCorner = 0;
static CGFloat _cfgMarginX = kNetSpeedDefaultMargin;
static CGFloat _cfgMarginY = kNetSpeedDefaultMargin;
static CGFloat _cfgFontSize = kNetSpeedDefaultFontSize;
static BOOL _cfgPauseScreenOff = YES;

// 屏幕开关状态（com.apple.iokit.hid.displayStatus: 1 亮屏 0 灭屏）
static BOOL _screenIsOn = YES;
static int _screenNotifyToken = -1;
static uintptr_t _screenNotifyReg = 0;
static BOOL _screenNotifyRegistered = NO;

// 上次应用的方向，用于检测变化
static int _lastAppliedOrientation = -1;

// 固定窗口宽度（只随字号变化，不随网速跳变）
static CGFloat netSpeedWinWidth(void)
{
    // 文案形如 ↑10.0M/↓10.0M，共 12 个字符
    return ceil(_cfgFontSize * 7.6f) + 10.0f;
}

static CGFloat netSpeedWinHeight(void)
{
    return ceil(_cfgFontSize) + 6.0f;
}

static inline NSString *formatSpeed(uint64_t bytesPerSecond)
{
    double value = (double)bytesPerSecond;
    if (value >= 1048576.0) {
        return [NSString stringWithFormat:@"%.1fM", value / 1048576.0];
    }
    // 不再显示 B：不足 1KB 一律按 0.xK 显示
    return [NSString stringWithFormat:@"%.1fK", value / 1024.0];
}

static void getTotalNetworkBytes(uint64_t *rxBytes, uint64_t *txBytes)
{
    *rxBytes = 0;
    *txBytes = 0;

    struct ifaddrs *addrs = NULL;
    if (getifaddrs(&addrs) != 0) {
        return;
    }

    for (struct ifaddrs *cursor = addrs; cursor != NULL; cursor = cursor->ifa_next) {
        if (!(cursor->ifa_flags & IFF_UP)) {
            continue;
        }
        if (strncmp(cursor->ifa_name, "lo0", 3) == 0) {
            continue;
        }
        if (!cursor->ifa_data) {
            continue;
        }
        struct if_data *data = (struct if_data *)cursor->ifa_data;
        *rxBytes += data->ifi_ibytes;
        *txBytes += data->ifi_obytes;
    }

    freeifaddrs(addrs);
}

static UIWindowScene *zxActiveWindowScene(void)
{
    @try {
        NSSet *scenes = [UIApplication sharedApplication].connectedScenes;
        for (UIScene *scene in scenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] &&
                scene.activationState == UISceneActivationStateForegroundActive) {
                return (UIWindowScene *)scene;
            }
        }
        for (UIScene *scene in scenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                return (UIWindowScene *)scene;
            }
        }
    } @catch (NSException *exception) {
        ZXLogUIException(exception);
    }
    return nil;
}

// 方向统一以最前台 app 为准（与触摸指示器、1.0.2 旧版一致）
static int zxCurrentOrientation(void)
{
    int orientation = [Screen getScreenOrientation];
    switch (orientation) {
        case UIInterfaceOrientationPortrait:
        case UIInterfaceOrientationPortraitUpsideDown:
        case UIInterfaceOrientationLandscapeLeft:
        case UIInterfaceOrientationLandscapeRight:
            return orientation;
        default:
            return UIInterfaceOrientationPortrait;
    }
}

// content 旋转角度：以竖屏 window 为基准，把 content 整体旋到当前方向，
// 使 content 内的「视觉坐标」(0,0) 始终落在视觉左上角。
// 推导：content bounds 旋成横屏尺寸后，(0,0) 相对 center 旋转后必须落到
// 视觉左上角对应的竖屏坐标，只有以下角度满足。
static CGAffineTransform zxTransformForOrientation(int orientation)
{
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

// label 自身的旋转：让文字在横屏下「朝下读」（标题朝下、阅读方向从上到下）。
// 用户要求横屏文字朝下显示，且按用户视角是「逆时针旋转一下」。
// iOS y 向下坐标系中「用户视角逆时针」= 数学正方向，对应 +角度。
// 当前 content 旋 -π/2 时文字方向 = 视觉上方（标题朝左），
// 让 label 再旋 +π/2（用户视角逆时针 90°），合成 = 0，
// 文字方向变成视觉右方、标题朝上 —— 即正常横屏方向，相对原「朝左」状态
// 用户视觉上是逆时针转了 90°，符合「朝下」描述。
static CGAffineTransform zxLabelTransformForOrientation(int orientation)
{
    switch (orientation) {
        case UIInterfaceOrientationLandscapeLeft:
            // content = -π/2，label = +π/2 → 合成 0，文字朝右、标题朝上
            return CGAffineTransformMakeRotation(M_PI_2);
        case UIInterfaceOrientationLandscapeRight:
            // content = +π/2，label = -π/2 → 合成 0
            return CGAffineTransformMakeRotation(-M_PI_2);
        case UIInterfaceOrientationPortraitUpsideDown:
            return CGAffineTransformIdentity;
        default:
            return CGAffineTransformIdentity;
    }
}

/*
 * 窗口模型（与触摸指示器同源，已在本机长期验证稳定）：
 *   - UIWindow 占满「竖屏固定坐标空间」（短边宽、长边高），window 本身不旋转，
 *     userInteractionEnabled = NO，完全不拦截触摸；
 *   - 内部 _netSpeedContent 容器按当前方向整体旋转，容器内一律使用
 *     「视觉坐标系」（原点始终是视觉左上角），所以四角定位只需视觉坐标，
 *     不再做容易出错的逆变换。
 * 必须主线程调用。
 */
static void updateNetSpeedWindowGeometry(void)
{
    if (!_netSpeedWindow || !_netSpeedLabel || !_netSpeedContent) {
        return;
    }

    CGRect screenBounds = [Screen getBounds];
    CGFloat canvasW = MIN(CGRectGetWidth(screenBounds), CGRectGetHeight(screenBounds));
    CGFloat canvasH = MAX(CGRectGetWidth(screenBounds), CGRectGetHeight(screenBounds));
    if (canvasW <= 0 || canvasH <= 0) {
        return;
    }

    // 简化：visW/visH 直接用 window.bounds（横屏 1180×820 / 竖屏 820×1180），
    // 不需要方向交换，不需要 portrait 容器，不需要 transform。
    CGRect wb = _netSpeedWindow.bounds;
    CGFloat visW = wb.size.width;
    CGFloat visH = wb.size.height;

    int orientation = zxCurrentOrientation();
    CGFloat winW = netSpeedWinWidth();
    CGFloat winH = netSpeedWinHeight();

    // 按用户选的角点 + X/Y 边距计算 label 中心
    CGFloat vx = 0, vy = 0;
    switch (_cfgCorner) {
        case 1: // 左上
            vx = _cfgMarginX + winW / 2.0f;
            vy = _cfgMarginY + winH / 2.0f;
            break;
        case 2: // 左下
            vx = _cfgMarginX + winW / 2.0f;
            vy = visH - _cfgMarginY - winH / 2.0f;
            break;
        case 3: // 右下
            vx = visW - _cfgMarginX - winW / 2.0f;
            vy = visH - _cfgMarginY - winH / 2.0f;
            break;
        default: // 0 右上
            vx = visW - _cfgMarginX - winW / 2.0f;
            vy = _cfgMarginY + winH / 2.0f;
            break;
    }

    // content 直接填满 window.bounds，不旋转
    _netSpeedContent.frame = wb;
    _netSpeedContent.transform = CGAffineTransformIdentity;

    // label 直接放在 window 像素坐标里，不旋转（水平文字横屏竖屏都正）
    _netSpeedLabel.frame = CGRectMake(vx - winW / 2.0f, vy - winH / 2.0f, winW, winH);
    _netSpeedLabel.transform = CGAffineTransformIdentity;

    _lastAppliedOrientation = orientation;
}

static void stopNetSpeedTimer(void)
{
    if (_netSpeedTimer) {
        [_netSpeedTimer invalidate];
        _netSpeedTimer = nil;
    }
}

static void startNetSpeedTimer(void)
{
    if (_netSpeedTimer) {
        return;
    }
    _firstSample = YES;
    _netSpeedTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                     repeats:YES
                                                       block:^(NSTimer *timer) {
        @try {
            uint64_t rx = 0, tx = 0;
            getTotalNetworkBytes(&rx, &tx);

            if (_firstSample) {
                _lastRxBytes = rx;
                _lastTxBytes = tx;
                _firstSample = NO;
            } else {
                uint64_t rxSpeed = rx >= _lastRxBytes ? rx - _lastRxBytes : 0;
                uint64_t txSpeed = tx >= _lastTxBytes ? tx - _lastTxBytes : 0;
                _lastRxBytes = rx;
                _lastTxBytes = tx;

                NSString *text = [NSString stringWithFormat:@"\u2191%@/\u2193%@",
                                  formatSpeed(txSpeed), formatSpeed(rxSpeed)];
                if (_netSpeedLabel) {
                    _netSpeedLabel.text = text;
                }
            }

            // 宽度已固定，只有方向变化时才重新布局
            int orientation = zxCurrentOrientation();
            if (orientation != _lastAppliedOrientation) {
                ZXSafeMainAsync(^{
                    @try {
                        updateNetSpeedWindowGeometry();
                    } @catch (NSException *exception) {
                        ZXLogUIException(exception);
                    }
                });
            }
        } @catch (NSException *exception) {
            ZXLogUIException(exception);
        }
    }];
}

static BOOL timerShouldRun(void)
{
    if (!_netSpeedEnabled) {
        return NO;
    }
    if (_cfgPauseScreenOff && !_screenIsOn) {
        return NO;
    }
    return YES;
}

static void applyTimerState(void)
{
    if (timerShouldRun()) {
        startNetSpeedTimer();
    } else {
        stopNetSpeedTimer();
    }
}

static void registerScreenStateNotification(void)
{
    if (_screenNotifyRegistered) {
        return;
    }
    _screenNotifyRegistered = YES;

    uint64_t initial = 1;
    notify_register_dispatch("com.apple.iokit.hid.displayStatus",
                             (int *)&_screenNotifyReg,
                             dispatch_get_main_queue(),
                             ^(int token) {
        uint64_t state = 1;
        notify_get_state(token, &state);
        _screenIsOn = (state != 0);
        @try {
            applyTimerState();
            // 亮屏恢复后立即校正一次位置和文案
            if (_screenIsOn && _netSpeedWindow) {
                updateNetSpeedWindowGeometry();
            }
        } @catch (NSException *exception) {
            ZXLogUIException(exception);
        }
    });
    _screenNotifyToken = (int)_screenNotifyReg;
    if (notify_get_state(_screenNotifyToken, &initial) == NOTIFY_STATUS_OK) {
        _screenIsOn = (initial != 0);
    }
}

static void createNetSpeedWindow(void)
{
    CGRect screenBounds = [Screen getBounds];
    CGFloat canvasW = MIN(CGRectGetWidth(screenBounds), CGRectGetHeight(screenBounds));
    CGFloat canvasH = MAX(CGRectGetWidth(screenBounds), CGRectGetHeight(screenBounds));
    if (canvasW <= 0 || canvasH <= 0) {
        canvasW = 375.0f;
        canvasH = 667.0f;
    }
    CGRect portraitFrame = CGRectMake(0, 0, canvasW, canvasH);

    // 2026-09-30 架构：window.frame 让 scene 管（跟随方向变全屏），
    // _netSpeedContent 保持 portrait 固定尺寸 + transform 旋转 + 居中。
    UIWindowScene *scene = [FloatingMenu preferredWindowScene];
    if (scene) {
        _netSpeedWindow = [[FMPassthroughWindow alloc] initWithWindowScene:scene];
    } else {
        _netSpeedWindow = [[FMPassthroughWindow alloc] initWithFrame:portraitFrame];
    }
    _netSpeedWindow.windowLevel = UIWindowLevelStatusBar + 1;
    _netSpeedWindow.userInteractionEnabled = NO;  // 关键：不拦截触摸，让事件穿透到下层

    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = [UIColor clearColor];
    _netSpeedWindow.rootViewController = root;

    // content：跟随 window.bounds，在 updateNetSpeedWindowGeometry 里每次确认 frame
    _netSpeedContent = [[UIView alloc] init];
    _netSpeedContent.backgroundColor = [UIColor clearColor];
    _netSpeedContent.userInteractionEnabled = NO;
    _netSpeedContent.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root.view addSubview:_netSpeedContent];

    CGFloat winW = netSpeedWinWidth();
    CGFloat winH = netSpeedWinHeight();
    _netSpeedLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, winW, winH)];
    _netSpeedLabel.font = [UIFont systemFontOfSize:_cfgFontSize];
    _netSpeedLabel.textColor = [UIColor whiteColor];
    _netSpeedLabel.shadowColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.85f];
    _netSpeedLabel.shadowOffset = CGSizeMake(0, 1);
    _netSpeedLabel.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.4f];
    _netSpeedLabel.layer.cornerRadius = kNetSpeedCornerRadius;
    _netSpeedLabel.layer.masksToBounds = YES;
    _netSpeedLabel.textAlignment = NSTextAlignmentCenter;
    _netSpeedLabel.adjustsFontSizeToFitWidth = NO;
    _netSpeedLabel.text = @"\u21910.0K/\u21930.0K";
    [_netSpeedContent addSubview:_netSpeedLabel];

    _lastAppliedOrientation = -1;
    updateNetSpeedWindowGeometry();

    _netSpeedWindow.hidden = NO;
}

static void destroyNetSpeedWindow(void)
{
    stopNetSpeedTimer();
    if (_netSpeedWindow) {
        _netSpeedWindow.hidden = YES;
        _netSpeedWindow.rootViewController = nil;
        _netSpeedWindow = nil;
        _netSpeedContent = nil;
        _netSpeedLabel = nil;
    }
}

static NSDictionary *readNetSpeedConfig(void)
{
    NSString *configPath = getCommonConfigFilePath();
    NSDictionary *config = [[NSDictionary alloc] initWithContentsOfFile:configPath];
    return config ?: @{};
}

static void applyConfigParams(NSDictionary *config)
{
    _cfgCorner = config[kCfgCorner] ? [config[kCfgCorner] intValue] : 0;
    if (_cfgCorner < 0 || _cfgCorner > 3) _cfgCorner = 0;

    // 新版 X/Y 边距；未设置时回退旧版单一边距，再回退默认值
    CGFloat legacy = config[kCfgMarginLegacy] ? [config[kCfgMarginLegacy] doubleValue] : kNetSpeedDefaultMargin;
    _cfgMarginX = config[kCfgMarginX] ? [config[kCfgMarginX] doubleValue] : legacy;
    _cfgMarginY = config[kCfgMarginY] ? [config[kCfgMarginY] doubleValue] : legacy;
    if (_cfgMarginX < 4) _cfgMarginX = 4;
    if (_cfgMarginX > 500) _cfgMarginX = 500;
    if (_cfgMarginY < 4) _cfgMarginY = 4;
    if (_cfgMarginY > 200) _cfgMarginY = 200;

    _cfgFontSize = config[kCfgFontSize] ? [config[kCfgFontSize] doubleValue] : kNetSpeedDefaultFontSize;
    if (_cfgFontSize < 8) _cfgFontSize = 8;
    if (_cfgFontSize > 20) _cfgFontSize = 20;

    _cfgPauseScreenOff = config[kCfgPauseOff] ? [config[kCfgPauseOff] boolValue] : YES;
}

static void reloadAppearance(void)
{
    if (!_netSpeedWindow) {
        createNetSpeedWindow();
        return;
    }
    _netSpeedWindow.hidden = NO;
    if (_netSpeedLabel) {
        _netSpeedLabel.font = [UIFont systemFontOfSize:_cfgFontSize];
    }
    updateNetSpeedWindowGeometry();
}

@implementation NetSpeedIndicator

+ (void)setEnabled:(BOOL)enabled
{
    _netSpeedEnabled = enabled;

    ZXSafeMainAsync(^{
        @try {
            registerScreenStateNotification();
            applyConfigParams(readNetSpeedConfig());

            if (enabled) {
                if (!_netSpeedWindow) {
                    createNetSpeedWindow();
                } else {
                    _netSpeedWindow.hidden = NO;
                    updateNetSpeedWindowGeometry();
                }
            } else {
                destroyNetSpeedWindow();
            }
            applyTimerState();
        } @catch (NSException *exception) {
            ZXLogUIException(exception);
        }
    });
}

+ (BOOL)isEnabled
{
    return _netSpeedEnabled;
}

+ (void)reloadConfig
{
    ZXSafeMainAsync(^{
        @try {
            registerScreenStateNotification();
            NSDictionary *config = readNetSpeedConfig();
            _netSpeedEnabled = config[kCfgEnabled] ? [config[kCfgEnabled] boolValue] : NO;
            applyConfigParams(config);

            if (_netSpeedEnabled) {
                reloadAppearance();
            } else {
                destroyNetSpeedWindow();
            }
            applyTimerState();
        } @catch (NSException *exception) {
            ZXLogUIException(exception);
        }
    });
}

+ (NSDictionary *)debugInfo
{
    __block NSDictionary *result = nil;
    void (^gather)(void) = ^{
        @try {
            int orientation = zxCurrentOrientation();
            NSString *oriName = @"Portrait";
            switch (orientation) {
                case UIInterfaceOrientationLandscapeLeft:  oriName = @"LandscapeLeft";  break;
                case UIInterfaceOrientationLandscapeRight: oriName = @"LandscapeRight"; break;
                case UIInterfaceOrientationPortraitUpsideDown: oriName = @"PortraitUpsideDown"; break;
                default: oriName = @"Portrait"; break;
            }

            CGRect screenBounds = [Screen getBounds];
            CGFloat canvasW = MIN(CGRectGetWidth(screenBounds), CGRectGetHeight(screenBounds));
            CGFloat canvasH = MAX(CGRectGetWidth(screenBounds), CGRectGetHeight(screenBounds));

            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[@"enabled"] = @(_netSpeedEnabled);
            info[@"orientation"] = @(orientation);
            info[@"orientation_name"] = oriName;
            info[@"screen_bounds_w"] = @(CGRectGetWidth(screenBounds));
            info[@"screen_bounds_h"] = @(CGRectGetHeight(screenBounds));
            info[@"canvas_w"] = @(canvasW);
            info[@"canvas_h"] = @(canvasH);
            info[@"cfg_corner"] = @(_cfgCorner);
            info[@"cfg_margin_x"] = @(_cfgMarginX);
            info[@"cfg_margin_y"] = @(_cfgMarginY);
            info[@"cfg_font_size"] = @(_cfgFontSize);

            if (!_netSpeedWindow) {
                info[@"window_exists"] = @(NO);
                info[@"note"] = @"window 尚未创建";
                result = [info copy];
                return;
            }

            CGRect winFrame = _netSpeedWindow.frame;
            BOOL winHidden = _netSpeedWindow.hidden;
            info[@"window_exists"] = @(YES);
            info[@"window_hidden"] = @(winHidden);
            info[@"window_frame_x"] = @(winFrame.origin.x);
            info[@"window_frame_y"] = @(winFrame.origin.y);
            info[@"window_frame_w"] = @(winFrame.size.width);
            info[@"window_frame_h"] = @(winFrame.size.height);

            if (_netSpeedContent) {
                CGAffineTransform ct = _netSpeedContent.transform;
                info[@"content_transform_a"] = @(ct.a);
                info[@"content_transform_b"] = @(ct.b);
                info[@"content_transform_c"] = @(ct.c);
                info[@"content_transform_d"] = @(ct.d);
                info[@"content_bounds_w"] = @(_netSpeedContent.bounds.size.width);
                info[@"content_bounds_h"] = @(_netSpeedContent.bounds.size.height);
            }

            if (_netSpeedLabel) {
                CGRect lf = _netSpeedLabel.frame;
                CGAffineTransform lt = _netSpeedLabel.transform;
                CGPoint labelCenter = [_netSpeedLabel convertPoint:CGPointMake(lf.size.width/2, lf.size.height/2) toView:nil];
                info[@"label_frame_x"] = @(lf.origin.x);
                info[@"label_frame_y"] = @(lf.origin.y);
                info[@"label_frame_w"] = @(lf.size.width);
                info[@"label_frame_h"] = @(lf.size.height);
                info[@"label_center_x_in_window"] = @(labelCenter.x);
                info[@"label_center_y_in_window"] = @(labelCenter.y);
                info[@"label_transform_a"] = @(lt.a);
                info[@"label_transform_b"] = @(lt.b);
                info[@"label_transform_c"] = @(lt.c);
                info[@"label_transform_d"] = @(lt.d);
                info[@"label_text"] = _netSpeedLabel.text ?: @"";
            }

            result = [info copy];
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

NSString *handleNetSpeedIndicatorTaskWithRawData(UInt8 *eventData, NSError **error)
{
    NSString *response = nil;
    @autoreleasepool {
        NSString *data = @"";
        if (eventData) {
            data = [NSString stringWithUTF8String:(const char *)eventData] ?: @"";
        }
        NSArray *parts = [data componentsSeparatedByString:@";;"];
        int action = [parts count] > 1 ? [parts[1] intValue] : 2;

        if (action == 2) {
            response = [NSString stringWithFormat:@"0;;%d\r\n", [NetSpeedIndicator isEnabled] ? 1 : 0];
            if (error) {
                *error = nil;
            }
            return response;
        }

        if (action == 3) {
            // 只重新加载配置（角点/边距/字号/息屏开关等），不改变总开关
            [NetSpeedIndicator reloadConfig];
            response = @"0\r\n";
            if (error) {
                *error = nil;
            }
            return response;
        }

        if (action != 0 && action != 1) {
            if (error) {
                *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999
                                     userInfo:@{NSLocalizedDescriptionKey:@"-1;;数据格式应为 \"enabled\"（1=开启, 0=关闭, 2=查询, 3=重新加载配置）\r\n"}];
            }
            return nil;
        }

        BOOL enabled = (action == 1);
        [NetSpeedIndicator setEnabled:enabled];

        NSString *configPath = getCommonConfigFilePath();
        NSMutableDictionary *config = [[NSMutableDictionary alloc] initWithContentsOfFile:configPath];
        if (!config) {
            config = [NSMutableDictionary dictionary];
        }
        config[kCfgEnabled] = @(enabled);
        [config writeToFile:configPath atomically:YES];

        response = @"0\r\n";
        if (error) {
            *error = nil;
        }
    }
    return response;
}
