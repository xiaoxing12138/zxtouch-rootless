#import "TapTestWindow.h"
#import "Screen.h"
#import "Common.h"
#import "FloatingMenu.h"        // 复用 FMPassthroughWindow + preferredWindowScene

static FMPassthroughWindow *_testWindow = nil;
static UIView *_testRootView = nil;
static UILabel *_infoLabel = nil;
static UIButton *_closeButton = nil;
static UIButton *_resetButton = nil;
static UIView *_cornerMarkers[4] = { nil, nil, nil, nil };  // 四角标记（portrait 坐标系）

static NSMutableArray<NSDictionary *> *_tapRecords = nil;  // 按步骤记录

// 引导式测试：3 方向 × 4 角 = 12 步
// 方向顺序：Portrait → LandscapeLeft → LandscapeRight
// 每个方向内的角顺序：左上 → 右上 → 左下 → 右下
static const int kTotalSteps = 12;
static int _currentStep = 0;   // 0..11，-1 表示自由模式/未开始

static NSString *kOrientationNames[4] = {
    @"竖屏 Portrait",
    @"横屏左 LandscapeLeft",
    @"横屏右 LandscapeRight",
    @"竖屏倒 PortraitUpsideDown"
};
static UIInterfaceOrientation kStepOrientations[3] = {
    UIInterfaceOrientationPortrait,
    UIInterfaceOrientationLandscapeLeft,
    UIInterfaceOrientationLandscapeRight
};
static NSString *kCornerNames[4] = { @"左上", @"右上", @"左下", @"右下" };

#define ORIENTATION_INDEX(o) ((o) == UIInterfaceOrientationPortrait ? 0 : \
                              (o) == UIInterfaceOrientationLandscapeLeft ? 1 : \
                              (o) == UIInterfaceOrientationLandscapeRight ? 2 : 3)

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
            _currentStep = 0;

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
            _testWindow.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.05f];
            _testWindow.userInteractionEnabled = YES;
            _testWindow.autoresizingMask = UIViewAutoresizingNone;

            UIViewController *root = [[UIViewController alloc] init];
            _testRootView = [[UIView alloc] initWithFrame:portraitFrame];
            _testRootView.backgroundColor = [UIColor clearColor];
            root.view = _testRootView;
            _testWindow.rootViewController = root;

            // 四个角的标记（往里挪 80pt，避开右下角的关闭/重置按钮区域）
            CGSize markerSize = CGSizeMake(40, 40);
            CGFloat inset = 95;  // 离屏幕边缘 95pt
            CGPoint markerPos[4] = {
                CGPointMake(inset, inset),                                        // 左上
                CGPointMake(canvasW - inset - markerSize.width, inset),          // 右上
                CGPointMake(inset, canvasH - inset - markerSize.height),         // 左下
                CGPointMake(canvasW - inset - markerSize.width,
                            canvasH - inset - markerSize.height)                     // 右下
            };
            for (int i = 0; i < 4; i++) {
                UIView *m = [[UIView alloc] initWithFrame:CGRectMake(markerPos[i].x, markerPos[i].y, markerSize.width, markerSize.height)];
                m.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.3f];
                m.layer.cornerRadius = markerSize.width / 2;
                m.layer.borderWidth = 2;
                m.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.8f].CGColor;
                m.userInteractionEnabled = NO;
                [_testRootView addSubview:m];
                _cornerMarkers[i] = m;
            }

            // 顶部信息 label
            _infoLabel = [[UILabel alloc] init];
            _infoLabel.numberOfLines = 0;
            _infoLabel.font = [UIFont systemFontOfSize:13];
            _infoLabel.textColor = [UIColor whiteColor];
            _infoLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82f];
            _infoLabel.layer.cornerRadius = 8;
            _infoLabel.layer.masksToBounds = YES;
            _infoLabel.textAlignment = NSTextAlignmentLeft;
            [_testRootView addSubview:_infoLabel];

            // 关闭按钮（右下角，固定 portrait 坐标）
            CGFloat btnW = 140, btnH = 44;
            _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
            _closeButton.frame = CGRectMake(canvasW - btnW - 15, canvasH - btnH - 15, btnW, btnH);
            [_closeButton setTitle:@"关闭测试" forState:UIControlStateNormal];
            [_closeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            _closeButton.backgroundColor = [UIColor colorWithRed:0.85f green:0.25f blue:0.25f alpha:0.95f];
            _closeButton.layer.cornerRadius = 8;
            [_closeButton addTarget:self action:@selector(_onCloseTapped) forControlEvents:UIControlEventTouchUpInside];
            [_testRootView addSubview:_closeButton];

            // 重置按钮（关闭按钮左边）
            _resetButton = [UIButton buttonWithType:UIButtonTypeSystem];
            _resetButton.frame = CGRectMake(canvasW - 2*btnW - 30, canvasH - btnH - 15, btnW, btnH);
            [_resetButton setTitle:@"重置步骤" forState:UIControlStateNormal];
            [_resetButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            _resetButton.backgroundColor = [UIColor colorWithRed:0.3f green:0.5f blue:0.85f alpha:0.95f];
            _resetButton.layer.cornerRadius = 8;
            [_resetButton addTarget:self action:@selector(_onResetTapped) forControlEvents:UIControlEventTouchUpInside];
            [_testRootView addSubview:_resetButton];

            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
                                           initWithTarget:self action:@selector(_handleTap:)];
            tap.numberOfTapsRequired = 1;
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
                _closeButton = nil;
                _resetButton = nil;
                for (int i = 0; i < 4; i++) _cornerMarkers[i] = nil;
                _currentStep = -1;
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
        _currentStep = 0;
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

#pragma mark - 按钮事件

+ (void)_onCloseTapped
{
    [self hide];
}

+ (void)_onResetTapped
{
    [self clearRecords];
}

#pragma mark - 引导步骤

// 步骤 N → 目标方向 index (0..2)
+ (int)_orientationIndexForStep:(int)step
{
    return step / 4;
}

// 步骤 N → 目标角 index (0..3)
+ (int)_cornerIndexForStep:(int)step
{
    return step % 4;
}

// 给定 window 坐标，判断最接近哪个角
+ (int)_detectCornerFromWindowPoint:(CGPoint)pt canvasW:(CGFloat)w canvasH:(CGFloat)h
{
    // 四个角的 window 坐标（portrait 固定坐标系）
    CGPoint corners[4] = {
        CGPointMake(0, 0),
        CGPointMake(w, 0),
        CGPointMake(0, h),
        CGPointMake(w, h)
    };
    int best = 0;
    CGFloat bestDist = CGFLOAT_MAX;
    for (int i = 0; i < 4; i++) {
        CGFloat dx = pt.x - corners[i].x;
        CGFloat dy = pt.y - corners[i].y;
        CGFloat d = dx*dx + dy*dy;
        if (d < bestDist) { bestDist = d; best = i; }
    }
    return best;
}

+ (void)_handleTap:(UITapGestureRecognizer *)tap
{
    CGPoint screenPt = [tap locationInView:nil];
    CGPoint winPt = [tap locationInView:_testWindow];
    CGPoint rootPt = [tap locationInView:_testRootView];

    CGRect wf = _testWindow.frame;
    CGRect rootBounds = _testRootView.bounds;
    CGFloat canvasW = wf.size.width;
    CGFloat canvasH = wf.size.height;
    int orientation = [Screen getScreenOrientation];

    // 方向名
    NSString *oriName = @"Portrait";
    switch (orientation) {
        case UIInterfaceOrientationLandscapeLeft:  oriName = @"LandscapeLeft"; break;
        case UIInterfaceOrientationLandscapeRight: oriName = @"LandscapeRight"; break;
        case UIInterfaceOrientationPortraitUpsideDown: oriName = @"PortraitUpsideDown"; break;
        default: oriName = @"Portrait"; break;
    }

    if (_currentStep < 0 || _currentStep >= kTotalSteps) {
        // 自由模式或已完成：只记录，不推进
        NSDictionary *record = @{
            @"orientation": @(orientation),
            @"orientation_name": oriName,
            @"screen_bounds_w": @([Screen getBounds].size.width),
            @"screen_bounds_h": @([Screen getBounds].size.height),
            @"window_frame_w": @(canvasW),
            @"window_frame_h": @(canvasH),
            @"tap_screen_x": @(screenPt.x),
            @"tap_screen_y": @(screenPt.y),
            @"tap_window_x": @(winPt.x),
            @"tap_window_y": @(winPt.y),
            @"tap_root_x": @(rootPt.x),
            @"tap_root_y": @(rootPt.y),
            @"corner": @([self _detectCornerFromWindowPoint:winPt canvasW:canvasW canvasH:canvasH]),
        };
        [_tapRecords addObject:record];
        [self _refreshInfo];
        return;
    }

    // 引导模式：检查方向是否匹配
    int targetOriIdx = [self _orientationIndexForStep:_currentStep];
    int currentOriIdx = ORIENTATION_INDEX(orientation);
    if (currentOriIdx != targetOriIdx) {
        // 方向不匹配，不记录，提示用户旋转
        [self _flashInfo:[NSString stringWithFormat:
            @"❌ 当前方向：%@\n👉 请先旋转到：%@\n\n（按钮在右下角：关闭测试 / 重置步骤）",
            kOrientationNames[currentOriIdx], kOrientationNames[targetOriIdx]]];
        return;
    }

    // 方向匹配 → 记录这一步
    int targetCorner = [self _cornerIndexForStep:_currentStep];
    NSDictionary *record = @{
        @"step": @(_currentStep + 1),
        @"orientation": @(orientation),
        @"orientation_name": oriName,
        @"target_orientation_index": @(targetOriIdx),
        @"target_orientation_name": kOrientationNames[targetOriIdx],
        @"target_corner_index": @(targetCorner),
        @"target_corner_name": kCornerNames[targetCorner],
        @"screen_bounds_w": @([Screen getBounds].size.width),
        @"screen_bounds_h": @([Screen getBounds].size.height),
        @"window_frame_w": @(canvasW),
        @"window_frame_h": @(canvasH),
        @"tap_screen_x": @(screenPt.x),
        @"tap_screen_y": @(screenPt.y),
        @"tap_window_x": @(winPt.x),
        @"tap_window_y": @(winPt.y),
        @"tap_root_x": @(rootPt.x),
        @"tap_root_y": @(rootPt.y),
    };
    [_tapRecords addObject:record];
    _currentStep++;
    [self _refreshInfo];
}

// 临时闪烁提示（方向不匹配时用）
+ (void)_flashInfo:(NSString *)text
{
    if (!_infoLabel) return;
    _infoLabel.text = text;
    [_infoLabel sizeToFit];
    CGFloat labelW = MIN(_infoLabel.frame.size.width + 16, 500);
    CGFloat labelH = _infoLabel.frame.size.height + 12;
    _infoLabel.frame = CGRectMake(10, 10, labelW, labelH);
    // 1.5 秒后刷新回正常显示
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self _refreshInfo];
    });
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

    NSString *text;

    if (_currentStep < 0) {
        text = @"测试已结束。点右下角'重置步骤'重新开始。";
    } else if (_currentStep >= kTotalSteps) {
        // 全部 12 步完成 → 显示汇总
        NSMutableArray *lines = [NSMutableArray arrayWithObject:@"✅ 12 步全部完成！"];
        [lines addObject:[NSString stringWithFormat:@"📐 当前方向：%@", oriName]];
        [lines addObject:@""];
        for (NSDictionary *rec in _tapRecords) {
            [lines addObject:[NSString stringWithFormat:
                @"%@-%@: win(%.0f,%.0f)",
                rec[@"target_orientation_name"],
                rec[@"target_corner_name"],
                [rec[@"tap_window_x"] floatValue],
                [rec[@"tap_window_y"] floatValue]]];
        }
        text = [lines componentsJoinedByString:@"\n"];
    } else {
        int targetOriIdx = [self _orientationIndexForStep:_currentStep];
        int targetCornerIdx = [self _cornerIndexForStep:_currentStep];
        int curOriIdx = ORIENTATION_INDEX(orientation);
        NSString *dirMark = (curOriIdx == targetOriIdx) ? @"✅" : @"🔄";

        text = [NSString stringWithFormat:
            @"📍 步骤 %d / %d\n"
            @"%@ 请旋转到：%@\n"
            @"👆 然后点击：%@\n"
            @"\n"
            @"📱 screen bounds: %.0f × %.0f\n"
            @"🪟 window frame: %.0f × %.0f\n"
            @"🧭 当前方向: %@ %@",
            _currentStep + 1, kTotalSteps,
            dirMark, kOrientationNames[targetOriIdx],
            kCornerNames[targetCornerIdx],
            sb.size.width, sb.size.height,
            wf.size.width, wf.size.height,
            oriName,
            (curOriIdx == targetOriIdx) ? @"（已匹配，可以点击）" : @"（方向不对，请先旋转）"];
    }

    _infoLabel.text = text;
    [_infoLabel sizeToFit];

    CGFloat labelW = MIN(_infoLabel.frame.size.width + 16, 500);
    CGFloat labelH = _infoLabel.frame.size.height + 12;
    _infoLabel.frame = CGRectMake(10, 10, labelW, labelH);
}

@end
