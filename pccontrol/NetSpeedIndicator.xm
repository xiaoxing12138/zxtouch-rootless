#import "NetSpeedIndicator.h"
#import "Screen.h"
#import "Common.h"

#include <ifaddrs.h>
#include <net/if.h>
#include <string.h>
#import <notify.h>

#define kNetSpeedPaddingX 6.0f
#define kNetSpeedPaddingY 2.0f
#define kNetSpeedCornerRadius 4.0f
#define kNetSpeedDefaultFontSize 11.0f
#define kNetSpeedDefaultMargin 10.0f

// 配置键（common.plist）
static NSString *const kCfgEnabled     = @"net_speed_indicator_enabled";
static NSString *const kCfgCorner      = @"net_speed_corner";        // 0右上 1左上 2左下 3右下
static NSString *const kCfgMargin      = @"net_speed_margin";        // 距屏幕边缘 pt
static NSString *const kCfgFontSize    = @"net_speed_font_size";    // 字号 pt
static NSString *const kCfgPauseOff    = @"net_speed_pause_screen_off";

static UIWindow *_netSpeedWindow = nil;
static UILabel *_netSpeedLabel = nil;
static NSTimer *_netSpeedTimer = nil;
static BOOL _netSpeedEnabled = NO;
static uint64_t _lastRxBytes = 0;
static uint64_t _lastTxBytes = 0;
static BOOL _firstSample = YES;

// 可配置参数
static int _cfgCorner = 0;
static CGFloat _cfgMargin = kNetSpeedDefaultMargin;
static CGFloat _cfgFontSize = kNetSpeedDefaultFontSize;
static BOOL _cfgPauseScreenOff = YES;

// 屏幕开关状态（com.apple.iokit.hid.displayStatus: 1 亮屏 0 灭屏）
static BOOL _screenIsOn = YES;
static int _screenNotifyToken = -1;       // notify_get_state 用
static uintptr_t _screenNotifyReg = 0;    // notify_register_dispatch 用
static BOOL _screenNotifyRegistered = NO;

// 上次应用的方向，用于检测变化
static int _lastAppliedOrientation = -1;

static inline NSString *formatSpeed(uint64_t bytesPerSecond)
{
    double value = (double)bytesPerSecond;
    if (value >= 1048576.0) {
        return [NSString stringWithFormat:@"%.1fM", value / 1048576.0];
    } else if (value >= 1024.0) {
        return [NSString stringWithFormat:@"%.1fK", value / 1024.0];
    } else {
        return [NSString stringWithFormat:@"%lluB", bytesPerSecond];
    }
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
        // 优先前台活跃的 window scene
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

/*
 * 当前界面方向。优先读 windowScene.interfaceOrientation（iPadOS 13+ 可靠），
 * 拿不到再回落到 SpringBoard 私有接口 _frontMostAppOrientation。
 */
static int zxCurrentOrientation(void)
{
    @try {
        UIWindowScene *scene = zxActiveWindowScene();
        if (scene) {
            UIInterfaceOrientation o = scene.interfaceOrientation;
            if (o != UIInterfaceOrientationUnknown) {
                return (int)o;
            }
        }
    } @catch (NSException *exception) {
        ZXLogUIException(exception);
    }
    int fallback = [Screen getScreenOrientation];
    return fallback > 0 ? fallback : UIInterfaceOrientationPortrait;
}

static CGAffineTransform zxTransformForOrientation(int orientation)
{
    // UIView transform 正值在 UIKit(y 轴向下) 坐标中视觉为顺时针。
    switch (orientation) {
        case UIInterfaceOrientationLandscapeRight:   // home 指示条在右，视觉顺时针 90°
            return CGAffineTransformMakeRotation(M_PI_2);
        case UIInterfaceOrientationLandscapeLeft:    // home 指示条在左，视觉逆时针 90°
            return CGAffineTransformMakeRotation(-M_PI_2);
        case UIInterfaceOrientationPortraitUpsideDown:
            return CGAffineTransformMakeRotation(M_PI);
        default:
            return CGAffineTransformIdentity;
    }
}

/*
 * window 挂在 SpringBoard 的固定竖屏坐标空间里，通过手动旋转适配方向。
 * 先在「视觉坐标系」（宽始终沿视觉水平方向）按所选角点算位置，再逆变换
 * 回竖屏坐标，保证四角选择在任何方向下都正确。必须主线程调用。
 */
static void updateNetSpeedWindowGeometry(void)
{
    if (!_netSpeedWindow || !_netSpeedLabel) {
        return;
    }

    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGFloat canvasW = MIN(CGRectGetWidth(screenBounds), CGRectGetHeight(screenBounds)); // 短边（竖屏宽）
    CGFloat canvasH = MAX(CGRectGetWidth(screenBounds), CGRectGetHeight(screenBounds)); // 长边（竖屏高）
    if (canvasW <= 0 || canvasH <= 0) {
        return;
    }

    CGSize contentSize = [_netSpeedLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
    if (contentSize.width < 1 || contentSize.height < 1) {
        contentSize = CGSizeMake(80, 16);
    }
    CGFloat winW = contentSize.width + kNetSpeedPaddingX * 2;
    CGFloat winH = contentSize.height + kNetSpeedPaddingY * 2;

    int orientation = zxCurrentOrientation();
    BOOL landscape = (orientation == UIInterfaceOrientationLandscapeLeft ||
                      orientation == UIInterfaceOrientationLandscapeRight);

    // 视觉坐标系尺寸
    CGFloat visW = landscape ? canvasH : canvasW;
    CGFloat visH = landscape ? canvasW : canvasH;

    // 视觉坐标系下的中心（按用户选的角点 + 边距）
    CGFloat vx = 0, vy = 0;
    switch (_cfgCorner) {
        case 1: // 左上
            vx = _cfgMargin + winW / 2;
            vy = _cfgMargin + winH / 2;
            break;
        case 2: // 左下
            vx = _cfgMargin + winW / 2;
            vy = visH - _cfgMargin - winH / 2;
            break;
        case 3: // 右下
            vx = visW - _cfgMargin - winW / 2;
            vy = visH - _cfgMargin - winH / 2;
            break;
        default: // 0 右上
            vx = visW - _cfgMargin - winW / 2;
            vy = _cfgMargin + winH / 2;
            break;
    }

    // 视觉坐标 → 竖屏 window 坐标
    CGFloat cx = vx, cy = vy;
    switch (orientation) {
        case UIInterfaceOrientationLandscapeRight:   // 视觉顺时针 90°：x = vy, y = H - vx
            cx = vy;
            cy = canvasH - vx;
            break;
        case UIInterfaceOrientationLandscapeLeft:    // 视觉逆时针 90°：x = W - vy, y = vx
            cx = canvasW - vy;
            cy = vx;
            break;
        case UIInterfaceOrientationPortraitUpsideDown:
            cx = canvasW - vx;
            cy = canvasH - vy;
            break;
        default:
            break;
    }

    // 边界夹取
    cx = MAX(winW / 2, MIN(canvasW - winW / 2, cx));
    cy = MAX(winH / 2, MIN(canvasH - winH / 2, cy));

    _netSpeedWindow.transform = CGAffineTransformIdentity;
    _netSpeedWindow.frame = CGRectMake(cx - winW / 2, cy - winH / 2, winW, winH);
    _netSpeedLabel.frame = CGRectMake(kNetSpeedPaddingX, kNetSpeedPaddingY,
                                      contentSize.width, contentSize.height);
    _netSpeedWindow.transform = zxTransformForOrientation(orientation);
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

            // 每秒顺便校正方向（iPad 上方向通知不可靠，轮询最稳）
            int orientation = zxCurrentOrientation();
            if (orientation != _lastAppliedOrientation) {
                updateNetSpeedWindowGeometry();
            } else if (_netSpeedLabel) {
                // 文案变化后宽度可能改变（M/K/B 位数变化），重新布局
                updateNetSpeedWindowGeometry();
            }
        } @catch (NSException *exception) {
            ZXLogUIException(exception);
        }
    }]);
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
    UIWindowScene *scene = zxActiveWindowScene();

    CGRect frame = CGRectMake(0, 0, 80, 18);
    if (scene) {
        _netSpeedWindow = [[UIWindow alloc] initWithWindowScene:scene];
        _netSpeedWindow.frame = frame;
    } else {
        _netSpeedWindow = [[UIWindow alloc] initWithFrame:frame];
    }

    _netSpeedWindow.windowLevel = UIWindowLevelStatusBar + 1;
    _netSpeedWindow.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.4f];
    _netSpeedWindow.layer.cornerRadius = kNetSpeedCornerRadius;
    _netSpeedWindow.layer.masksToBounds = YES;
    _netSpeedWindow.userInteractionEnabled = NO;

    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = [UIColor clearColor];
    _netSpeedWindow.rootViewController = root;

    _netSpeedLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _netSpeedLabel.font = [UIFont systemFontOfSize:_cfgFontSize];
    _netSpeedLabel.textColor = [UIColor whiteColor];
    _netSpeedLabel.shadowColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.85f];
    _netSpeedLabel.shadowOffset = CGSizeMake(0, 1);
    _netSpeedLabel.backgroundColor = [UIColor clearColor];
    _netSpeedLabel.textAlignment = NSTextAlignmentCenter;
    _netSpeedLabel.text = @"\u21910.0M/\u21930.0M";
    [_netSpeedWindow addSubview:_netSpeedLabel];

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

    _cfgMargin = config[kCfgMargin] ? [config[kCfgMargin] doubleValue] : kNetSpeedDefaultMargin;
    if (_cfgMargin < 4) _cfgMargin = 4;
    if (_cfgMargin > 60) _cfgMargin = 60;

    _cfgFontSize = config[kCfgFontSize] ? [config[kCfgFontSize] doubleValue] : kNetSpeedDefaultFontSize;
    if (_cfgFontSize < 8) _cfgFontSize = 8;
    if (_cfgFontSize > 20) _cfgFontSize = 20;

    _cfgPauseScreenOff = config[kCfgPauseOff] ? [config[kCfgPauseOff] boolValue] : YES;
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
                if (!_netSpeedWindow) {
                    createNetSpeedWindow();
                } else {
                    // 字号可能改变，更新字体后重布局
                    _netSpeedLabel.font = [UIFont systemFontOfSize:_cfgFontSize];
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

@end

NSString *handleNetSpeedIndicatorTaskWithRawData(UInt8 *eventData, NSError **error)
{
    NSString *response = nil;
    @autoreleasepool {
        NSString *data = [NSString stringWithUTF8String:(const char *)eventData] ?: @"";
        NSArray *parts = [data componentsSeparatedByString:@";;"];
        int action = [parts count] > 1 ? [parts[1] intValue] : 2;

        if (action == 2) {
            response = [NSString stringWithFormat:@"0;;%d\r\n", [NetSpeedIndicator isEnabled] ? 1 : 0];
            *error = nil;
            return response;
        }

        if (action == 3) {
            // 只重新加载配置（角点/边距/字号/息屏开关等），不改变总开关
            [NetSpeedIndicator reloadConfig];
            response = @"0\r\n";
            *error = nil;
            return response;
        }

        if (action != 0 && action != 1) {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999
                                     userInfo:@{NSLocalizedDescriptionKey:@"-1;;数据格式应为 \"enabled\"（1=开启, 0=关闭, 2=查询, 3=重新加载配置）\r\n"}];
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
        *error = nil;
    }
    return response;
}
