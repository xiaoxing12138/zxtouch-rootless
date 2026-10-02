#import "TouchCoordinateIndicator.h"
#import <math.h>
#import "FloatingMenu.h"    // FMPassthroughWindow + preferredWindowScene
#import "Screen.h"
#import "Common.h"

#define kCoordCornerRadius 4.0f
#define kCoordDefaultFontSize 11.0f
#define kCoordDefaultMargin 10.0f

// 配置键（config.plist，与网速悬浮窗一样用扁平键）
static NSString *const kCfgEnabled     = @"touch_coord_enabled";
static NSString *const kCfgCorner      = @"touch_coord_corner";        // 0右上 1左上 2左下 3右下
static NSString *const kCfgMarginX     = @"touch_coord_margin_x";      // 视觉水平边距 pt
static NSString *const kCfgMarginY     = @"touch_coord_margin_y";      // 视觉垂直边距 pt
static NSString *const kCfgFontSize    = @"touch_coord_font_size";
static NSString *const kCfgBgColor     = @"touch_coord_bg_color";      // "#RRGGBB"
static NSString *const kCfgBgAlpha     = @"touch_coord_bg_alpha";      // 0.0 - 1.0
static NSString *const kCfgTextColor   = @"touch_coord_text_color";    // "#RRGGBB"
static NSString *const kCfgHideIdle    = @"touch_coord_hide_when_idle";
static NSString *const kCfgMultiMode   = @"touch_coord_multi_mode";    // 0第一个 1最后一个 2全部

// 多点触碰显示模式
#define kCoordMultiFirst 0
#define kCoordMultiLast  1
#define kCoordMultiAll   2

// 空闲占位文案
static NSString *const kCoordIdleText = @"(--, --)";

static FMPassthroughWindow *_coordWindow = nil;
static UIView  *_coordContent = nil;   // 与 window.bounds 等大的透明容器（不旋转）
static UILabel *_coordLabel = nil;
static BOOL _coordEnabled = NO;

// 可配置参数
static int _cfgCorner = 0;
static CGFloat _cfgMarginX = kCoordDefaultMargin;
static CGFloat _cfgMarginY = kCoordDefaultMargin;
static CGFloat _cfgFontSize = kCoordDefaultFontSize;
static CGFloat _cfgBgAlpha = 0.4f;
static NSString *_cfgBgColorHex = @"#000000";
static NSString *_cfgTextColorHex = @"#FFFFFF";
static BOOL _cfgHideWhenIdle = NO;
static int _cfgMultiMode = kCoordMultiLast;

// 当前活跃触点：index → 像素坐标点
static NSMutableDictionary<NSNumber *, NSValue *> *_activeTouches = nil;
// 最近一次有动作（按下/移动）的触点 index，"最后一个"模式优先显示它
static int _lastActiveIndex = -1;

static CGFloat coordLabelWidth(void)
{
    // 文案形如 (2360, 1640)，最长 12 个字符，与网速窗一样按字号估宽，保证宽度稳定
    return ceil(_cfgFontSize * 7.6f) + 10.0f;
}

static CGFloat coordLineHeight(void)
{
    return ceil(_cfgFontSize * 1.2f) + 2.0f;
}

static UIColor *coordColorFromHex(NSString *hex, CGFloat alpha)
{
    if (![hex isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSString *value = [hex stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([value hasPrefix:@"#"]) {
        value = [value substringFromIndex:1];
    }
    if (value.length == 3) {
        // #RGB → #RRGGBB
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

// 当前应该显示的行（每行一个 "(x, y)"）。返回空数组表示空闲且需要隐藏。
static NSArray<NSString *> *coordDisplayLines(void)
{
    NSArray<NSNumber *> *keys = [[_activeTouches allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];

    if (keys.count == 0) {
        if (_cfgHideWhenIdle) {
            return lines;
        }
        [lines addObject:kCoordIdleText];
        return lines;
    }

    if (_cfgMultiMode == kCoordMultiAll) {
        for (NSNumber *key in keys) {
            CGPoint point = [_activeTouches[key] CGPointValue];
            [lines addObject:[NSString stringWithFormat:@"(%d, %d)", (int)llround(point.x), (int)llround(point.y)]];
        }
        return lines;
    }

    NSNumber *targetKey = nil;
    if (_cfgMultiMode == kCoordMultiFirst) {
        targetKey = keys.firstObject;
    } else {
        if (_lastActiveIndex >= 0 && _activeTouches[@(_lastActiveIndex)] != nil) {
            targetKey = @(_lastActiveIndex);
        } else {
            targetKey = keys.lastObject;
        }
    }

    NSValue *value = _activeTouches[targetKey] ?: _activeTouches[keys.firstObject];
    if (value == nil) {
        return lines;
    }
    CGPoint point = [value CGPointValue];
    [lines addObject:[NSString stringWithFormat:@"(%d, %d)", (int)llround(point.x), (int)llround(point.y)]];
    return lines;
}

/*
 * 窗口模型与网速悬浮窗完全一致：
 *   - UIWindow 占满当前方向的可见区域（横屏 1180×820），window 本身不旋转，
 *     userInteractionEnabled = NO，不拦截触摸；
 *   - 内部 _coordContent 直接填满 window.bounds，不做任何旋转；
 *   - 一律使用「window 像素坐标」定位，四角定位只需当前方向的可见宽高。
 * 必须主线程调用。
 */
static void updateCoordGeometry(void)
{
    if (!_coordWindow || !_coordLabel || !_coordContent) {
        return;
    }

    CGRect wb = _coordWindow.bounds;
    CGFloat visW = wb.size.width;
    CGFloat visH = wb.size.height;
    if (visW <= 0 || visH <= 0) {
        return;
    }

    NSArray<NSString *> *lines = coordDisplayLines();
    _coordLabel.hidden = (lines.count == 0);
    _coordLabel.text = [lines componentsJoinedByString:@"\n"];

    CGFloat winW = coordLabelWidth();
    CGFloat lineHeight = coordLineHeight();
    CGFloat textHeight = MAX(1, (CGFloat)lines.count) * lineHeight;
    CGFloat winH = textHeight + 6.0f;

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

    _coordContent.frame = wb;
    _coordContent.transform = CGAffineTransformIdentity;

    _coordLabel.frame = CGRectMake(vx - winW / 2.0f, vy - winH / 2.0f, winW, winH);
    _coordLabel.transform = CGAffineTransformIdentity;
}

static void coordStoreTouch(int index, CGFloat xPx, CGFloat yPx)
{
    if (!_activeTouches) {
        _activeTouches = [NSMutableDictionary dictionary];
    }
    _activeTouches[@(index)] = [NSValue valueWithCGPoint:CGPointMake(xPx, yPx)];
    _lastActiveIndex = index;
    updateCoordGeometry();
}

static void coordRemoveTouch(int index)
{
    if (!_activeTouches) {
        return;
    }
    [_activeTouches removeObjectForKey:@(index)];
    updateCoordGeometry();
}

static void createCoordWindow(void)
{
    CGRect screenBounds = [Screen getBounds];
    CGFloat canvasW = MIN(CGRectGetWidth(screenBounds), CGRectGetHeight(screenBounds));
    CGFloat canvasH = MAX(CGRectGetWidth(screenBounds), CGRectGetHeight(screenBounds));
    if (canvasW <= 0 || canvasH <= 0) {
        canvasW = 375.0f;
        canvasH = 667.0f;
    }
    CGRect portraitFrame = CGRectMake(0, 0, canvasW, canvasH);

    UIWindowScene *scene = [FloatingMenu preferredWindowScene];
    if (scene) {
        _coordWindow = [[FMPassthroughWindow alloc] initWithWindowScene:scene];
    } else {
        _coordWindow = [[FMPassthroughWindow alloc] initWithFrame:portraitFrame];
    }
    _coordWindow.windowLevel = UIWindowLevelStatusBar + 1;
    _coordWindow.userInteractionEnabled = NO;   // 不拦截触摸

    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = [UIColor clearColor];
    _coordWindow.rootViewController = root;

    _coordContent = [[UIView alloc] init];
    _coordContent.backgroundColor = [UIColor clearColor];
    _coordContent.userInteractionEnabled = NO;
    _coordContent.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root.view addSubview:_coordContent];

    _coordLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, coordLabelWidth(), coordLineHeight() + 6.0f)];
    _coordLabel.font = [UIFont systemFontOfSize:_cfgFontSize];
    _coordLabel.textColor = coordColorFromHex(_cfgTextColorHex, 1.0f) ?: [UIColor whiteColor];
    _coordLabel.shadowColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.85f];
    _coordLabel.shadowOffset = CGSizeMake(0, 1);
    _coordLabel.backgroundColor = coordColorFromHex(_cfgBgColorHex, _cfgBgAlpha) ?: [UIColor colorWithRed:0 green:0 blue:0 alpha:_cfgBgAlpha];
    _coordLabel.layer.cornerRadius = kCoordCornerRadius;
    _coordLabel.layer.masksToBounds = YES;
    _coordLabel.textAlignment = NSTextAlignmentCenter;
    _coordLabel.numberOfLines = 0;
    _coordLabel.adjustsFontSizeToFitWidth = NO;
    _coordLabel.text = kCoordIdleText;
    [_coordContent addSubview:_coordLabel];

    updateCoordGeometry();

    _coordWindow.hidden = NO;
}

static void destroyCoordWindow(void)
{
    if (_activeTouches) {
        [_activeTouches removeAllObjects];
    }
    _lastActiveIndex = -1;
    if (_coordWindow) {
        _coordWindow.hidden = YES;
        _coordWindow.rootViewController = nil;
        _coordWindow = nil;
        _coordContent = nil;
        _coordLabel = nil;
    }
}

static void applyCoordAppearance(void)
{
    if (!_coordLabel) {
        return;
    }
    _coordLabel.font = [UIFont systemFontOfSize:_cfgFontSize];
    _coordLabel.textColor = coordColorFromHex(_cfgTextColorHex, 1.0f) ?: [UIColor whiteColor];
    _coordLabel.backgroundColor = coordColorFromHex(_cfgBgColorHex, _cfgBgAlpha) ?: [UIColor colorWithRed:0 green:0 blue:0 alpha:_cfgBgAlpha];
}

static NSDictionary *readCoordConfig(void)
{
    NSString *configPath = getCommonConfigFilePath();
    NSDictionary *config = [[NSDictionary alloc] initWithContentsOfFile:configPath];
    return config ?: @{};
}

static void applyCoordConfigParams(NSDictionary *config)
{
    _cfgCorner = config[kCfgCorner] ? [config[kCfgCorner] intValue] : 0;
    if (_cfgCorner < 0 || _cfgCorner > 3) _cfgCorner = 0;

    _cfgMarginX = config[kCfgMarginX] ? [config[kCfgMarginX] doubleValue] : kCoordDefaultMargin;
    _cfgMarginY = config[kCfgMarginY] ? [config[kCfgMarginY] doubleValue] : kCoordDefaultMargin;
    if (_cfgMarginX < 0) _cfgMarginX = 0;
    if (_cfgMarginX > 500) _cfgMarginX = 500;
    if (_cfgMarginY < 0) _cfgMarginY = 0;
    if (_cfgMarginY > 200) _cfgMarginY = 200;

    _cfgFontSize = config[kCfgFontSize] ? [config[kCfgFontSize] doubleValue] : kCoordDefaultFontSize;
    if (_cfgFontSize < 8) _cfgFontSize = 8;
    if (_cfgFontSize > 20) _cfgFontSize = 20;

    if ([config[kCfgBgColor] isKindOfClass:[NSString class]]) _cfgBgColorHex = config[kCfgBgColor];
    if ([config[kCfgTextColor] isKindOfClass:[NSString class]]) _cfgTextColorHex = config[kCfgTextColor];

    _cfgBgAlpha = config[kCfgBgAlpha] ? [config[kCfgBgAlpha] doubleValue] : 0.4f;
    if (_cfgBgAlpha < 0) _cfgBgAlpha = 0;
    if (_cfgBgAlpha > 1) _cfgBgAlpha = 1;

    _cfgHideWhenIdle = config[kCfgHideIdle] ? [config[kCfgHideIdle] boolValue] : NO;

    _cfgMultiMode = config[kCfgMultiMode] ? [config[kCfgMultiMode] intValue] : kCoordMultiLast;
    if (_cfgMultiMode < 0 || _cfgMultiMode > 2) _cfgMultiMode = kCoordMultiLast;
}

@implementation TouchCoordinateIndicator

+ (void)setEnabled:(BOOL)enabled
{
    _coordEnabled = enabled;

    ZXSafeMainAsync(^{
        @try {
            applyCoordConfigParams(readCoordConfig());
            if (enabled) {
                if (!_coordWindow) {
                    createCoordWindow();
                } else {
                    applyCoordAppearance();
                    _coordWindow.hidden = NO;
                    updateCoordGeometry();
                }
            } else {
                destroyCoordWindow();
            }
        } @catch (NSException *exception) {
            ZXLogUIException(exception);
        }
    });
}

+ (BOOL)isEnabled
{
    return _coordEnabled;
}

+ (void)reloadConfig
{
    ZXSafeMainAsync(^{
        @try {
            NSDictionary *config = readCoordConfig();
            _coordEnabled = config[kCfgEnabled] ? [config[kCfgEnabled] boolValue] : NO;
            applyCoordConfigParams(config);

            if (_coordEnabled) {
                if (!_coordWindow) {
                    createCoordWindow();
                } else {
                    applyCoordAppearance();
                    _coordWindow.hidden = NO;
                    updateCoordGeometry();
                }
            } else {
                destroyCoordWindow();
            }
        } @catch (NSException *exception) {
            ZXLogUIException(exception);
        }
    });
}

+ (void)touchBeganWithIndex:(int)index xPx:(CGFloat)xPx yPx:(CGFloat)yPx
{
    if (!_coordEnabled) {
        return;
    }
    ZXSafeMainAsync(^{
        @try {
            if (_coordWindow) coordStoreTouch(index, xPx, yPx);
        } @catch (NSException *exception) {
            ZXLogUIException(exception);
        }
    });
}

+ (void)touchMovedWithIndex:(int)index xPx:(CGFloat)xPx yPx:(CGFloat)yPx
{
    if (!_coordEnabled) {
        return;
    }
    ZXSafeMainAsync(^{
        @try {
            if (_coordWindow) coordStoreTouch(index, xPx, yPx);
        } @catch (NSException *exception) {
            ZXLogUIException(exception);
        }
    });
}

+ (void)touchEndedWithIndex:(int)index
{
    if (!_coordEnabled) {
        return;
    }
    ZXSafeMainAsync(^{
        @try {
            if (_coordWindow) coordRemoveTouch(index);
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
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[@"enabled"] = @(_coordEnabled);
            info[@"cfg_corner"] = @(_cfgCorner);
            info[@"cfg_margin_x"] = @(_cfgMarginX);
            info[@"cfg_margin_y"] = @(_cfgMarginY);
            info[@"cfg_font_size"] = @(_cfgFontSize);
            info[@"cfg_bg_color"] = _cfgBgColorHex ?: @"";
            info[@"cfg_bg_alpha"] = @(_cfgBgAlpha);
            info[@"cfg_text_color"] = _cfgTextColorHex ?: @"";
            info[@"cfg_hide_when_idle"] = @(_cfgHideWhenIdle);
            info[@"cfg_multi_mode"] = @(_cfgMultiMode);
            info[@"active_touch_count"] = @(_activeTouches.count);

            CGRect screenBounds = [Screen getBounds];
            info[@"screen_bounds_w"] = @(CGRectGetWidth(screenBounds));
            info[@"screen_bounds_h"] = @(CGRectGetHeight(screenBounds));

            if (!_coordWindow) {
                info[@"window_exists"] = @(NO);
                result = [info copy];
                return;
            }

            CGRect winFrame = _coordWindow.frame;
            info[@"window_exists"] = @(YES);
            info[@"window_hidden"] = @(_coordWindow.hidden);
            info[@"window_frame_x"] = @(winFrame.origin.x);
            info[@"window_frame_y"] = @(winFrame.origin.y);
            info[@"window_frame_w"] = @(winFrame.size.width);
            info[@"window_frame_h"] = @(winFrame.size.height);

            if (_coordContent) {
                CGAffineTransform ct = _coordContent.transform;
                info[@"content_transform_a"] = @(ct.a);
                info[@"content_transform_b"] = @(ct.b);
                info[@"content_transform_c"] = @(ct.c);
                info[@"content_transform_d"] = @(ct.d);
                info[@"content_bounds_w"] = @(_coordContent.bounds.size.width);
                info[@"content_bounds_h"] = @(_coordContent.bounds.size.height);
            }

            if (_coordLabel) {
                CGRect lf = _coordLabel.frame;
                CGPoint labelCenter = [_coordLabel convertPoint:CGPointMake(lf.size.width / 2.0f, lf.size.height / 2.0f) toView:nil];
                info[@"label_frame_x"] = @(lf.origin.x);
                info[@"label_frame_y"] = @(lf.origin.y);
                info[@"label_frame_w"] = @(lf.size.width);
                info[@"label_frame_h"] = @(lf.size.height);
                info[@"label_center_x_in_window"] = @(labelCenter.x);
                info[@"label_center_y_in_window"] = @(labelCenter.y);
                info[@"label_hidden"] = @(_coordLabel.hidden);
                info[@"label_text"] = _coordLabel.text ?: @"";
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

NSString *handleTouchCoordinateTaskWithRawData(UInt8 *eventData, NSError **error)
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
            response = [NSString stringWithFormat:@"0;;%d\r\n", [TouchCoordinateIndicator isEnabled] ? 1 : 0];
            if (error) {
                *error = nil;
            }
            return response;
        }

        if (action == 3) {
            // 只重新加载配置（位置/边距/字号/颜色/空闲隐藏/多点模式），不改变总开关
            [TouchCoordinateIndicator reloadConfig];
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
        [TouchCoordinateIndicator setEnabled:enabled];

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