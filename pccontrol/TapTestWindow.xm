#import "TapTestWindow.h"
#import "Screen.h"
#import "Common.h"
#import "FloatingMenu.h"

// 本地 FMPassthroughView（空白处穿透，marker/按钮可交互）
@interface TTPassthroughView : UIView
@end
@implementation TTPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}
@end

static FMPassthroughWindow *_testWindow = nil;
static UIView *_testRootView = nil;
static UIView *_testInnerView = nil;   // portrait 固定尺寸 + transform 旋转
static UILabel *_infoLabel = nil;
static UIButton *_closeButton = nil;
static UIButton *_exportButton = nil;
static UIView *_cornerMarkers[4] = { nil, nil, nil, nil };

static NSMutableArray<NSDictionary *> *_tapRecords = nil;
static int _currentStep = 0;   // 已记录的步数
static const int kTotalSteps = 12;   // 3 方向 × 4 角
static int _currentOrientationIdx = -1;  // 当前方向在引导流程中的下标 (0..2)
static int _currentCornerIdx = -1;       // 当前要引导的角下标 (0..3)

static NSString *kOrientationNames[3] = {
    @"竖屏 Portrait",
    @"横屏左 LandscapeLeft",
    @"横屏右 LandscapeRight"
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
            _currentOrientationIdx = 0;
            _currentCornerIdx = 0;

            CGRect screenBounds = [Screen getBounds];
            CGFloat canvasW = MIN(CGRectGetWidth(screenBounds), CGRectGetHeight(screenBounds));
            CGFloat canvasH = MAX(CGRectGetWidth(screenBounds), CGRectGetHeight(screenBounds));
            CGRect portraitFrame = CGRectMake(0, 0, canvasW, canvasH);

            UIWindowScene *scene = [FloatingMenu preferredWindowScene];
            _testWindow = scene
                ? [[FMPassthroughWindow alloc] initWithWindowScene:scene]
                : [[FMPassthroughWindow alloc] initWithFrame:portraitFrame];
            _testWindow.portraitFrame = portraitFrame;
            _testWindow.windowLevel = UIWindowLevelAlert + 3;
            _testWindow.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.05f];
            _testWindow.userInteractionEnabled = YES;
            // 不再硬锁 autoresizingMask，FMPassthroughWindow initWith* 里已设置灵活缩放

            UIViewController *root = [[UIViewController alloc] init];
            // outerView 填满 window.bounds（接收触摸）
            _testRootView = [[UIView alloc] init];
            _testRootView.backgroundColor = [UIColor clearColor];
            root.view = _testRootView;
            _testWindow.rootViewController = root;

            // innerContent：TTPassthroughView —— marker/按钮可交互，空白处穿透到 rootView（触发 tap 手势）
            _testInnerView = [[TTPassthroughView alloc] initWithFrame:portraitFrame];
            _testInnerView.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.08f];
            [_testRootView addSubview:_testInnerView];

            // 四个角 marker（portrait 固定坐标系定位）
            CGSize mSize = CGSizeMake(40, 40);
            CGPoint mPos[4] = {
                CGPointMake(15, 15),                                      // 左上
                CGPointMake(canvasW - 15 - mSize.width, 15),              // 右上
                CGPointMake(15, canvasH - 15 - mSize.height),             // 左下
                CGPointMake(canvasW - 15 - mSize.width, canvasH - 15 - mSize.height)
            };
            for (int i = 0; i < 4; i++) {
                UIView *m = [[UIView alloc] initWithFrame:CGRectMake(mPos[i].x, mPos[i].y, mSize.width, mSize.height)];
                m.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.3f];
                m.layer.cornerRadius = mSize.width / 2;
                m.layer.borderWidth = 2;
                m.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.8f].CGColor;
                m.userInteractionEnabled = NO;
                [_testInnerView addSubview:m];
                _cornerMarkers[i] = m;
            }

            // 顶部信息 label（portrait 坐标 10,10）
            _infoLabel = [[UILabel alloc] init];
            _infoLabel.numberOfLines = 0;
            _infoLabel.font = [UIFont systemFontOfSize:13];
            _infoLabel.textColor = [UIColor whiteColor];
            _infoLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82f];
            _infoLabel.layer.cornerRadius = 8;
            _infoLabel.layer.masksToBounds = YES;
            _infoLabel.textAlignment = NSTextAlignmentLeft;
            [_testInnerView addSubview:_infoLabel];

            // 右下角：关闭按钮（portrait 坐标 canvasW - btnW - 15, canvasH - btnH - 15）
            CGFloat btnW = 140, btnH = 44;
            _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
            _closeButton.frame = CGRectMake(canvasW - btnW - 15, canvasH - btnH - 15, btnW, btnH);
            [_closeButton setTitle:@"关闭" forState:UIControlStateNormal];
            [_closeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            _closeButton.backgroundColor = [UIColor colorWithRed:0.85f green:0.25f blue:0.25f alpha:0.95f];
            _closeButton.layer.cornerRadius = 8;
            [_closeButton addTarget:self action:@selector(_onCloseTapped) forControlEvents:UIControlEventTouchUpInside];
            [_testInnerView addSubview:_closeButton];

            // 关闭左边：获取结果按钮
            _exportButton = [UIButton buttonWithType:UIButtonTypeSystem];
            _exportButton.frame = CGRectMake(canvasW - 2*btnW - 30, canvasH - btnH - 15, btnW, btnH);
            [_exportButton setTitle:@"获取结果" forState:UIControlStateNormal];
            [_exportButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            _exportButton.backgroundColor = [UIColor colorWithRed:0.25f green:0.65f blue:0.3f alpha:0.95f];
            _exportButton.layer.cornerRadius = 8;
            [_exportButton addTarget:self action:@selector(_onExportTapped) forControlEvents:UIControlEventTouchUpInside];
            [_testInnerView addSubview:_exportButton];

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
                _exportButton = nil;
                for (int i = 0; i < 4; i++) _cornerMarkers[i] = nil;
                _currentStep = 0;
                _currentOrientationIdx = -1;
                _currentCornerIdx = -1;
            }
        } @catch (NSException *exception) {
            ZXLogUIException(exception);
        }
    });
}

+ (BOOL)isVisible { return _testWindow && !_testWindow.hidden; }
+ (void)clearRecords {
    ZXSafeMainAsync(^{
        [_tapRecords removeAllObjects];
        _currentStep = 0;
        _currentOrientationIdx = 0;
        _currentCornerIdx = 0;
        [self _refreshInfo];
    });
}
+ (NSArray<NSDictionary *> *)tapRecords {
    __block NSArray *result = nil;
    void (^gather)(void) = ^{ result = [_tapRecords copy]; };
    if ([NSThread isMainThread]) { gather(); }
    else { dispatch_sync(dispatch_get_main_queue(), gather); }
    return result ?: @[];
}

#pragma mark - 按钮

+ (void)_onCloseTapped  { [self hide]; }

+ (void)_onExportTapped
{
    NSArray *records = [self tapRecords];
    NSDictionary *payload = @{
        @"total_steps": @(kTotalSteps),
        @"completed":   @(records.count),
        @"records":     records
    };
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted error:&err];
    NSString *json = err ? @"JSON 序列化失败" : [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

    UIPasteboard.generalPasteboard.string = json;
    [self _flashInfo:[NSString stringWithFormat:
        @"✅ 已复制 %d 条记录到剪贴板\n（JSON 可在悬浮窗调试页粘贴查看）",
        (int)records.count]];
}

#pragma mark - 触摸处理（简化版：无方向校验，点一次记一次）

+ (void)_handleTap:(UITapGestureRecognizer *)tap
{
    // 先确保 rootView.frame = window.bounds（方向变化后可能没及时更新）
    CGRect wb = _testWindow.bounds;
    if (!CGRectEqualToRect(_testRootView.frame, wb)) {
        _testRootView.frame = wb;
    }

    CGPoint screenPt = [tap locationInView:nil];         // 设备屏幕坐标
    CGPoint rootPt = [tap locationInView:_testRootView]; // rootView 坐标（= window 坐标，因为 rootView 填满 window.bounds）
    CGPoint winPt = rootPt;                              // 直接用 rootPt 作为 window 坐标
    CGRect wf = _testWindow.frame;
    int orientation = [Screen getScreenOrientation];

    NSString *oriName = @"Portrait";
    switch (orientation) {
        case UIInterfaceOrientationLandscapeLeft:  oriName = @"LandscapeLeft"; break;
        case UIInterfaceOrientationLandscapeRight: oriName = @"LandscapeRight"; break;
        case UIInterfaceOrientationPortraitUpsideDown: oriName = @"PortraitUpsideDown"; break;
        default: oriName = @"Portrait"; break;
    }

    // 自动检测点的是哪个角（根据 window 坐标距离四个 portrait 角点）
    CGSize sz = wf.size;
    CGPoint corners[4] = { CGPointZero, CGPointMake(sz.width, 0), CGPointMake(0, sz.height), CGPointMake(sz.width, sz.height) };
    int bestCorner = 0; CGFloat bestD = CGFLOAT_MAX;
    for (int i = 0; i < 4; i++) {
        CGFloat dx = winPt.x - corners[i].x, dy = winPt.y - corners[i].y;
        CGFloat d = dx*dx + dy*dy;
        if (d < bestD) { bestD = d; bestCorner = i; }
    }

    NSDictionary *record = @{
        @"step":                  @(_currentStep + 1),
        @"orientation":           @(orientation),
        @"orientation_name":      oriName,
        @"current_orientation_idx": @(ORIENTATION_INDEX(orientation)),
        @"detected_corner":       @(bestCorner),
        @"detected_corner_name":  kCornerNames[bestCorner],
        @"screen_bounds_w":       @([Screen getBounds].size.width),
        @"screen_bounds_h":       @([Screen getBounds].size.height),
        @"window_frame_w":        @(sz.width),
        @"window_frame_h":        @(sz.height),
        @"tap_screen_x":          @(screenPt.x),
        @"tap_screen_y":          @(screenPt.y),
        @"tap_window_x":          @(winPt.x),
        @"tap_window_y":          @(winPt.y),
        @"tap_root_x":            @(rootPt.x),
        @"tap_root_y":            @(rootPt.y),
    };
    [_tapRecords addObject:record];

    // 推进引导指针（用于 infoLabel 显示，不校验是否正确）
    if (_currentStep >= kTotalSteps) {
        // 已完成，继续点就自由追加
    } else {
        _currentStep++;
        _currentOrientationIdx = _currentStep / 4;
        _currentCornerIdx      = _currentStep % 4;
    }
    [self _refreshInfo];
}

+ (void)_flashInfo:(NSString *)text
{
    if (!_infoLabel) return;
    _infoLabel.text = text;
    [_infoLabel sizeToFit];
    CGFloat lw = MIN(_infoLabel.frame.size.width + 16, 500);
    CGFloat lh = _infoLabel.frame.size.height + 12;
    _infoLabel.frame = CGRectMake(10, 10, lw, lh);
}

+ (void)_refreshInfo
{
    if (!_testWindow || !_infoLabel) return;

    // 每次刷新时自动：rootView 填满 window + innerView 居中 + 旋转
    CGRect wb = _testWindow.bounds;
    if (!CGRectEqualToRect(_testRootView.frame, wb)) {
        _testRootView.frame = wb;
    }
    if (_testInnerView) {
        CGRect pf = _testWindow.portraitFrame;
        if (!CGRectIsEmpty(pf)) {
            _testInnerView.transform = CGAffineTransformIdentity;
            _testInnerView.frame = pf;
            _testInnerView.center = CGPointMake(CGRectGetMidX(wb), CGRectGetMidY(wb));
            int orientation = [Screen getScreenOrientation];
            CGAffineTransform t;
            switch (orientation) {
                case UIInterfaceOrientationLandscapeLeft:  t = CGAffineTransformMakeRotation(-M_PI_2); break;
                case UIInterfaceOrientationLandscapeRight: t = CGAffineTransformMakeRotation(M_PI_2); break;
                case UIInterfaceOrientationPortraitUpsideDown: t = CGAffineTransformMakeRotation(M_PI); break;
                default: t = CGAffineTransformIdentity; break;
            }
            _testInnerView.transform = t;
        }
    }

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
    if (_currentStep == 0) {
        text = [NSString stringWithFormat:
            @"📍 步骤 1 / %d\n"
            @"👉 请旋转到：%@\n"
            @"👆 然后点击：%@\n"
            @"\n📱 screen: %.0f×%.0f  🪟 window: %.0f×%.0f\n🧭 当前方向: %@",
            kTotalSteps,
            kOrientationNames[_currentOrientationIdx], kCornerNames[_currentCornerIdx],
            sb.size.width, sb.size.height, wf.size.width, wf.size.height,
            oriName];
    } else if (_currentStep >= kTotalSteps) {
        text = [NSString stringWithFormat:
            @"✅ 已记录 %d / %d 次点击！\n"
            @"\n点右下角【获取结果】把数据复制到剪贴板\n"
            @"然后在 App 设置页 → 悬浮窗调试 → 粘贴查看\n"
            @"或发 socket 41;;get 取回 JSON",
            (int)_tapRecords.count, kTotalSteps];
    } else {
        NSString *lastOri = [_tapRecords.lastObject objectForKey:@"orientation_name"] ?: @"";
        NSString *lastCor = [_tapRecords.lastObject objectForKey:@"detected_corner_name"] ?: @"";
        text = [NSString stringWithFormat:
            @"📍 已完成 %d / %d\n"
            @"🔜 下一步：%@ → 点 %@\n"
            @"\n✅ 上次记录: %@-%@\n📱 screen: %.0f×%.0f\n🪟 window: %.0f×%.0f\n🧭 当前方向: %@",
            _currentStep, kTotalSteps,
            kOrientationNames[_currentOrientationIdx], kCornerNames[_currentCornerIdx],
            lastOri, lastCor,
            sb.size.width, sb.size.height,
            wf.size.width, wf.size.height,
            oriName];
    }

    _infoLabel.text = text;
    [_infoLabel sizeToFit];
    CGFloat lw = MIN(_infoLabel.frame.size.width + 16, 500);
    CGFloat lh = _infoLabel.frame.size.height + 12;
    _infoLabel.frame = CGRectMake(10, 10, lw, lh);
}

@end
