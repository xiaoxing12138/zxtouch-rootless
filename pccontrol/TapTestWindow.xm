#import "TapTestWindow.h"
#import "Screen.h"
#import "FloatingMenu.h"        // 复用 FMPassthroughWindow + preferredWindowScene

static FMPassthroughWindow *_testWindow = nil;
static UIView *_testRootView = nil;
static UILabel *_infoLabel = nil;
static NSMutableArray<NSDictionary *> *_tapRecords = nil;

@implementation TapTestWindow

+ (void)show
{
    ZXSafeMainAsync(^{
        @try {
            if (_testWindow) {
                _testWindow.hidden = NO;
                [self _refreshInfo];
                return;
            }
            _tapRecords = [NSMutableArray array];

            CGRect screenBounds = [Screen getBounds];
            CGFloat canvasW = MIN(CGRectGetWidth(screenBounds), CGRectGetHeight(screenBounds));
            CGFloat canvasH = MAX(CGRectGetWidth(screenBounds), CGRectGetHeight(screenBounds));
            CGRect portraitFrame = CGRectMake(0, 0, canvasW, canvasH);

            UIWindowScene *scene = [FloatingMenu preferredWindowScene];
            if (scene) {
                _testWindow = [[FMPassthroughWindow alloc] initWithWindowScene:scene];
            } else {
                _testWindow = [[FMPassthroughWindow alloc] initWithFrame:portraitFrame];
            }
            _testWindow.portraitFrame = portraitFrame;
            _testWindow.frame = portraitFrame;
            _testWindow.windowLevel = UIWindowLevelAlert + 3;
            _testWindow.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.08f]; // 极淡红色，确认窗口可见
            _testWindow.userInteractionEnabled = YES;
            _testWindow.autoresizingMask = UIViewAutoresizingNone;

            UIViewController *root = [[UIViewController alloc] init];
            _testRootView = [[UIView alloc] initWithFrame:portraitFrame];
            _testRootView.backgroundColor = [UIColor clearColor];
            root.view = _testRootView;
            _testWindow.rootViewController = root;

            // 顶部信息 label
            _infoLabel = [[UILabel alloc] init];
            _infoLabel.numberOfLines = 0;
            _infoLabel.font = [UIFont systemFontOfSize:12];
            _infoLabel.textColor = [UIColor whiteColor];
            _infoLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.75f];
            _infoLabel.layer.cornerRadius = 6;
            _infoLabel.layer.masksToBounds = YES;
            _infoLabel.textAlignment = NSTextAlignmentLeft;
            [_testRootView addSubview:_infoLabel];

            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
                                           initWithTarget:self action:@selector(_handleTap:)];
            tap.numberOfTapsRequired = 1;
            tap.allowableMovement = 50;
            [_testRootView addGestureRecognizer:tap];

            _testWindow.hidden = NO;
            [self _refreshInfo];
        } @catch (NSException *exception) {
            ZXLogUIException(exception);
        }
    });
}

+ (void)hide
{
    ZXSafeMainAsync(^{
        @try {
            if (_testWindow) {
                _testWindow.hidden = YES;
                _testWindow.rootViewController = nil;
                _testWindow = nil;
                _testRootView = nil;
                _infoLabel = nil;
            }
        } @catch (NSException *exception) {
            ZXLogUIException(exception);
        }
    });
}

+ (BOOL)isVisible
{
    return _testWindow && !_testWindow.hidden;
}

+ (void)clearRecords
{
    ZXSafeMainAsync(^{
        [_tapRecords removeAllObjects];
        [self _refreshInfo];
    });
}

+ (NSArray<NSDictionary *> *)tapRecords
{
    __block NSArray *result = nil;
    void (^gather)(void) = ^{
        result = [_tapRecords copy];
    };
    if ([NSThread isMainThread]) {
        gather();
    } else {
        dispatch_sync(dispatch_get_main_queue(), gather);
    }
    return result ?: @[];
}

#pragma mark - 私有

+ (void)_handleTap:(UITapGestureRecognizer *)tap
{
    CGPoint screenPt = [tap locationInView:nil];       // 屏幕坐标（跟随当前方向）
    CGPoint winPt = [tap locationInView:_testWindow];  // window 坐标
    CGPoint rootPt = [tap locationInView:_testRootView]; // root 坐标（和 window 一样）

    CGRect wf = _testWindow.frame;
    CGRect rootBounds = _testRootView.bounds;
    int orientation = [Screen getScreenOrientation];

    NSString *oriName = @"Portrait";
    switch (orientation) {
        case UIInterfaceOrientationLandscapeLeft:  oriName = @"LandscapeLeft"; break;
        case UIInterfaceOrientationLandscapeRight: oriName = @"LandscapeRight"; break;
        case UIInterfaceOrientationPortraitUpsideDown: oriName = @"PortraitUpsideDown"; break;
        default: oriName = @"Portrait"; break;
    }

    NSDictionary *record = @{
        @"orientation": @(orientation),
        @"orientation_name": oriName,
        @"screen_bounds_w": @([Screen getBounds].size.width),
        @"screen_bounds_h": @([Screen getBounds].size.height),
        @"window_frame_w": @(wf.size.width),
        @"window_frame_h": @(wf.size.height),
        @"window_frame_x": @(wf.origin.x),
        @"window_frame_y": @(wf.origin.y),
        @"root_bounds_w": @(rootBounds.size.width),
        @"root_bounds_h": @(rootBounds.size.height),
        @"tap_screen_x": @(screenPt.x),
        @"tap_screen_y": @(screenPt.y),
        @"tap_window_x": @(winPt.x),
        @"tap_window_y": @(winPt.y),
        @"tap_root_x": @(rootPt.x),
        @"tap_root_y": @(rootPt.y),
    };
    [_tapRecords addObject:record];
    [self _refreshInfo];
}

+ (void)_refreshInfo
{
    if (!_testWindow || !_infoLabel) return;

    int orientation = [Screen getScreenOrientation];
    CGRect sb = [Screen getBounds];
    CGRect wf = _testWindow.frame;

    NSString *oriName = @"Portrait";
    switch (orientation) {
        case UIInterfaceOrientationLandscapeLeft:  oriName = @"LandscapeLeft"; break;
        case UIInterfaceOrientationLandscapeRight: oriName = @"LandscapeRight"; break;
        case UIInterfaceOrientationPortraitUpsideDown: oriName = @"PortraitUpsideDown"; break;
        default: oriName = @"Portrait"; break;
    }

    NSDictionary *last = _tapRecords.lastObject;
    NSString *lastStr = @"(暂无点击)";
    if (last) {
        lastStr = [NSString stringWithFormat:@"screen(%.0f,%.0f) win(%.0f,%.0f)",
                   [last[@"tap_screen_x"] floatValue],
                   [last[@"tap_screen_y"] floatValue],
                   [last[@"tap_window_x"] floatValue],
                   [last[@"tap_window_y"] floatValue]];
    }

    NSString *text = [NSString stringWithFormat:
        @"📐 方向: %@ (%d)\n"
        @"📱 screen bounds: %.0f × %.0f\n"
        @"🪟 window frame: %.0f × %.0f\n"
        @"👆 点击数: %lu  最近: %@",
        oriName, orientation,
        sb.size.width, sb.size.height,
        wf.size.width, wf.size.height,
        (unsigned long)_tapRecords.count,
        lastStr];

    _infoLabel.text = text;
    [_infoLabel sizeToFit];

    // 贴左上角（window 是 portrait 固定坐标系，所以永远是 (10,10)）
    CGFloat labelW = MIN(_infoLabel.frame.size.width + 12, 400);
    CGFloat labelH = _infoLabel.frame.size.height + 8;
    _infoLabel.frame = CGRectMake(10, 10, labelW, labelH);
}

@end
