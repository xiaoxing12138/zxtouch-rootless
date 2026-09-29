#import "NetSpeedIndicator.h"
#import "Screen.h"
#import "Common.h"

#include <ifaddrs.h>
#include <net/if.h>
#include <string.h>
#include <dispatch/dispatch.h>

#define kNetSpeedIndicatorPaddingX 6.0f
#define kNetSpeedIndicatorPaddingY 2.0f
#define kNetSpeedIndicatorFontSize 11.0f
#define kNetSpeedIndicatorCornerRadius 4.0f
#define kNetSpeedIndicatorMargin 10.0f

static UIWindow *_netSpeedWindow = nil;
static UILabel *_netSpeedLabel = nil;
static NSTimer *_netSpeedTimer = nil;
static id _netSpeedOrientationObserver = nil;
static BOOL _netSpeedEnabled = NO;
static uint64_t _lastRxBytes = 0;
static uint64_t _lastTxBytes = 0;
static BOOL _firstSample = YES;

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

static CGAffineTransform transformForOrientation(int orientation)
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

/*
 * The window lives in a portrait-fixed coordinate space (same model as the
 * touch indicator). Position + rotation are derived manually so the label
 * always sits at the visual top-right corner with upright text. Must be
 * called on the main thread.
 */
static void updateNetSpeedWindowGeometry(void)
{
    if (!_netSpeedWindow || !_netSpeedLabel) {
        return;
    }

    CGRect bounds = [Screen getBounds];
    CGFloat canvasW = MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    CGFloat canvasH = MAX(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    if (canvasW <= 0 || canvasH <= 0) {
        return;
    }

    CGSize contentSize = [_netSpeedLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
    if (contentSize.width < 1 || contentSize.height < 1) {
        contentSize = CGSizeMake(80, 16);
    }

    CGFloat winW = contentSize.width + kNetSpeedIndicatorPaddingX * 2;
    CGFloat winH = contentSize.height + kNetSpeedIndicatorPaddingY * 2;

    int orientation = [Screen getScreenOrientation];
    CGPoint center;
    switch (orientation) {
        case UIInterfaceOrientationLandscapeLeft:
            center = CGPointMake(kNetSpeedIndicatorMargin + winH / 2,
                                 canvasH - kNetSpeedIndicatorMargin - winW / 2);
            break;
        case UIInterfaceOrientationLandscapeRight:
            center = CGPointMake(canvasW - kNetSpeedIndicatorMargin - winH / 2,
                                 kNetSpeedIndicatorMargin + winW / 2);
            break;
        case UIInterfaceOrientationPortraitUpsideDown:
            center = CGPointMake(kNetSpeedIndicatorMargin + winW / 2,
                                 canvasH - kNetSpeedIndicatorMargin - winH / 2);
            break;
        default: // portrait (also covers unknown orientations)
            center = CGPointMake(canvasW - kNetSpeedIndicatorMargin - winW / 2,
                                 kNetSpeedIndicatorMargin + winH / 2);
            break;
    }

    // frame must be set while the transform is identity
    _netSpeedWindow.transform = CGAffineTransformIdentity;
    _netSpeedWindow.frame = CGRectMake(center.x - winW / 2, center.y - winH / 2, winW, winH);
    _netSpeedLabel.frame = CGRectMake(kNetSpeedIndicatorPaddingX, kNetSpeedIndicatorPaddingY,
                                      contentSize.width, contentSize.height);
    _netSpeedWindow.transform = transformForOrientation(orientation);
}

static void sampleNetSpeed(void)
{
    uint64_t rx = 0, tx = 0;
    getTotalNetworkBytes(&rx, &tx);

    if (_firstSample) {
        _lastRxBytes = rx;
        _lastTxBytes = tx;
        _firstSample = NO;
        return;
    }

    uint64_t rxSpeed = rx >= _lastRxBytes ? rx - _lastRxBytes : 0;
    uint64_t txSpeed = tx >= _lastTxBytes ? tx - _lastTxBytes : 0;
    _lastRxBytes = rx;
    _lastTxBytes = tx;

    NSString *text = [NSString stringWithFormat:@"\u2191%@/\u2193%@", formatSpeed(txSpeed), formatSpeed(rxSpeed)];

    ZXSafeMainAsync(^{
        @try {
            if (_netSpeedLabel) {
                _netSpeedLabel.text = text;
                updateNetSpeedWindowGeometry();
            }
        } @catch (NSException *exception) {
            ZXLogUIException(exception);
        }
    });
}

static void createNetSpeedWindow(void)
{
    UIWindowScene *scene = nil;
    @try {
        scene = (UIWindowScene *)[[UIApplication sharedApplication].connectedScenes anyObject];
    } @catch (NSException *exception) {
        ZXLogUIException(exception);
    }

    CGRect frame = CGRectMake(0, 0, 80, 18);
    if (scene) {
        // A scene-less UIWindow is fatal from iOS 17 on (see Record.xm / ScriptPlayer.xm).
        _netSpeedWindow = [[UIWindow alloc] initWithWindowScene:scene];
        _netSpeedWindow.frame = frame;
    } else {
        _netSpeedWindow = [[UIWindow alloc] initWithFrame:frame];
    }

    _netSpeedWindow.windowLevel = UIWindowLevelStatusBar + 1;
    _netSpeedWindow.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.4f];
    _netSpeedWindow.layer.cornerRadius = kNetSpeedIndicatorCornerRadius;
    _netSpeedWindow.layer.masksToBounds = YES;
    _netSpeedWindow.userInteractionEnabled = NO;

    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = [UIColor clearColor];
    _netSpeedWindow.rootViewController = root;

    _netSpeedLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _netSpeedLabel.font = [UIFont systemFontOfSize:kNetSpeedIndicatorFontSize];
    _netSpeedLabel.textColor = [UIColor whiteColor];
    _netSpeedLabel.shadowColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.8f];
    _netSpeedLabel.shadowOffset = CGSizeMake(0, 1);
    _netSpeedLabel.backgroundColor = [UIColor clearColor];
    _netSpeedLabel.textAlignment = NSTextAlignmentCenter;
    _netSpeedLabel.text = @"\u21910.0M/\u21930.0M";
    [_netSpeedWindow addSubview:_netSpeedLabel];

    updateNetSpeedWindowGeometry();

    _netSpeedWindow.hidden = NO;
}

static void destroyNetSpeedWindow(void)
{
    if (_netSpeedTimer) {
        [_netSpeedTimer invalidate];
        _netSpeedTimer = nil;
    }
    if (_netSpeedOrientationObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_netSpeedOrientationObserver];
        _netSpeedOrientationObserver = nil;
    }
    if (_netSpeedWindow) {
        _netSpeedWindow.hidden = YES;
        _netSpeedWindow.rootViewController = nil;
        _netSpeedWindow = nil;
        _netSpeedLabel = nil;
    }
}

@implementation NetSpeedIndicator

+ (void)setEnabled:(BOOL)enabled
{
    _netSpeedEnabled = enabled;

    ZXSafeMainAsync(^{
        @try {
            if (enabled) {
                if (!_netSpeedWindow) {
                    createNetSpeedWindow();
                } else {
                    _netSpeedWindow.hidden = NO;
                    updateNetSpeedWindowGeometry();
                }

                if (!_netSpeedOrientationObserver) {
                    _netSpeedOrientationObserver =
                        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidChangeStatusBarOrientationNotification
                                                                          object:nil
                                                                           queue:[NSOperationQueue mainQueue]
                                                                      usingBlock:^(NSNotification *note) {
                        @try {
                            updateNetSpeedWindowGeometry();
                        } @catch (NSException *exception) {
                            ZXLogUIException(exception);
                        }
                    }];
                }

                if (!_netSpeedTimer) {
                    _firstSample = YES;
                    _netSpeedTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                     repeats:YES
                                                                       block:^(NSTimer *timer) {
                        @try {
                            sampleNetSpeed();
                        } @catch (NSException *exception) {
                            ZXLogUIException(exception);
                        }
                    }];
                }
            } else {
                destroyNetSpeedWindow();
            }
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
    NSString *configPath = getCommonConfigFilePath();
    NSDictionary *config = [[NSDictionary alloc] initWithContentsOfFile:configPath];
    BOOL enabled = NO;
    if (config && config[@"net_speed_indicator_enabled"]) {
        enabled = [config[@"net_speed_indicator_enabled"] boolValue];
    }
    [self setEnabled:enabled];
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

        if (action != 0 && action != 1) {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999
                                     userInfo:@{NSLocalizedDescriptionKey:@"-1;;数据格式应为 \"enabled\"（1=开启, 0=关闭, 2=查询）\r\n"}];
            return nil;
        }

        BOOL enabled = (action == 1);
        [NetSpeedIndicator setEnabled:enabled];

        NSString *configPath = getCommonConfigFilePath();
        NSMutableDictionary *config = [[NSMutableDictionary alloc] initWithContentsOfFile:configPath];
        if (!config) {
            config = [NSMutableDictionary dictionary];
        }
        config[@"net_speed_indicator_enabled"] = @(enabled);
        [config writeToFile:configPath atomically:YES];

        response = @"0\r\n";
        *error = nil;
    }
    return response;
}
