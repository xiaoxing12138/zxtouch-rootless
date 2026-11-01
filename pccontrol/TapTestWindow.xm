#import "TapTestWindow.h"
#import "Screen.h"
#import "Touch.h"
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
static UIButton *_calButton = nil;
static UIView *_cornerMarkers[4] = { nil, nil, nil, nil };

static NSMutableArray<NSDictionary *> *_tapRecords = nil;
static int _currentStep = 0;   // 已记录的步数
static const int kTotalSteps = 12;   // 3 方向 × 4 角
static int _currentOrientationIdx = -1;  // 当前方向在引导流程中的下标 (0..2)
static int _currentCornerIdx = -1;       // 当前要引导的角下标 (0..3)

// 自动注入偏移测量：请求点与落点都存「原始帧像素」，和脚本坐标同一进制
static NSMutableArray *_calRequests = nil;
static NSMutableArray *_calActuals = nil;
static NSInteger _calNext = 0;
static BOOL _calRunning = NO;

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

// 单指触摸载荷：事件数(1) + 类型(1) + 手指号(2) + x*10(5) + y*10(5)，坐标是触摸指示器上的像素
static void ttSendTouch(int type, CGPoint point)
{
    char payload[24];
    snprintf(payload, sizeof(payload), "1%d%02d%05d%05d", type, 1,
             (int)(point.x * 10.0 + 0.5), (int)(point.y * 10.0 + 0.5));
    performTouchFromRawData((UInt8 *)payload);
}

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

            // 左下角：测偏移（自动注入 5 个点，量「请求坐标 → 实际落点」）
            _calButton = [UIButton buttonWithType:UIButtonTypeSystem];
            _calButton.frame = CGRectMake(15, canvasH - 2*btnH - 25, btnW, btnH);
            [_calButton setTitle:@"测偏移" forState:UIControlStateNormal];
            [_calButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            _calButton.backgroundColor = [UIColor colorWithRed:0.2f green:0.45f blue:0.85f alpha:0.95f];
            _calButton.layer.cornerRadius = 8;
            [_calButton addTarget:self action:@selector(_onCalibrateTapped) forControlEvents:UIControlEventTouchUpInside];
            [_testInnerView addSubview:_calButton];

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
                _calRunning = NO;
                _calRequests = nil;
                _calActuals = nil;
                _calNext = 0;
                _testWindow.hidden = YES;
                _testWindow.rootViewController = nil;
                _testWindow = nil;
                _testRootView = nil;
                _infoLabel = nil;
                _closeButton = nil;
                _exportButton = nil;
                _calButton = nil;
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

#pragma mark - 注入偏移测量

+ (void)_onCalibrateTapped { [self _startCalibration]; }

// 注入 5 个已知的原始帧像素点，看它们实际落在哪 —— 这是「设 x120 实际点 x130」唯一的客观量法。
// 落点用 locationInView:nil（设备竖屏点数空间）× scale 还原成原始帧像素，和请求点同进制。
+ (void)_startCalibration
{
    if (_calRunning) return;

    if (!ZXTouchSenderReady()) {
        [self _setInfoText:@"⚠️ 触摸 ID 还没抓到\n先用手指在屏幕上点几下，再点「测偏移」"];
        return;
    }

    CGSize pixel = ZXScreenPixelSize();
    if (pixel.width < 10 || pixel.height < 10) {
        [self _setInfoText:@"⚠️ 拿不到屏幕像素尺寸"];
        return;
    }

    // 避开底部三个按钮（它们在竖屏点 699~797 那条带里）
    static const CGFloat kFx[5] = { 0.12f, 0.88f, 0.50f, 0.12f, 0.88f };
    static const CGFloat kFy[5] = { 0.12f, 0.12f, 0.50f, 0.78f, 0.78f };
    _calRequests = [NSMutableArray array];
    _calActuals = [NSMutableArray array];
    for (int i = 0; i < 5; i++) {
        [_calRequests addObject:[NSValue valueWithCGPoint:CGPointMake(kFx[i] * pixel.width, kFy[i] * pixel.height)]];
        [_calActuals addObject:[NSNull null]];
    }
    _calNext = 0;
    _calRunning = YES;
    [self _setInfoText:@"📐 正在测注入偏移…\n自动点 5 下，请勿用手触屏"];
    [self _calInjectNext];
}

+ (void)_calInjectNext
{
    if (!_calRunning) return;

    if (_calNext >= (NSInteger)_calRequests.count) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self _finishCalibration];
        });
        return;
    }

    CGPoint framePoint = [_calRequests[_calNext] CGPointValue];
    CGPoint indicator = ZXIndicatorPointFromFramePoint(framePoint);
    ttSendTouch(TOUCH_DOWN, indicator);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.04 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ttSendTouch(TOUCH_UP, indicator);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!_calRunning) return;
            _calNext++;
            [self _calInjectNext];
        });
    });
}

+ (void)_calRecordActual:(CGPoint)actual
{
    // 按「离哪个请求点最近」配对，少来一个也不会把后面的数据全部错位
    NSInteger best = -1;
    CGFloat bestD = CGFLOAT_MAX;
    for (NSInteger i = 0; i < (NSInteger)_calActuals.count; i++) {
        if (![_calActuals[i] isKindOfClass:[NSNull class]]) continue;
        CGPoint req = [_calRequests[i] CGPointValue];
        CGFloat dx = req.x - actual.x, dy = req.y - actual.y;
        CGFloat d = dx*dx + dy*dy;
        if (d < bestD) { bestD = d; best = i; }
    }
    if (best >= 0) _calActuals[best] = [NSValue valueWithCGPoint:actual];
}

+ (void)_finishCalibration
{
    _calRunning = NO;

    NSMutableString *text = [NSMutableString stringWithString:@"📐 注入精度（请求 → 实际）\n"];
    NSInteger got = 0;
    double sumDX = 0, sumDY = 0;
    double maxReqX = 0, maxReqY = 0, ratioX = 1, ratioY = 1;
    for (NSInteger i = 0; i < (NSInteger)_calRequests.count; i++) {
        if (![_calActuals[i] isKindOfClass:[NSValue class]]) continue;
        got++;
        CGPoint req = [_calRequests[i] CGPointValue];
        CGPoint act = [_calActuals[i] CGPointValue];
        sumDX += act.x - req.x;
        sumDY += act.y - req.y;
        [text appendFormat:@"(%.0f,%.0f)→(%.0f,%.0f) %+.0f,%+.0f\n",
         req.x, req.y, act.x, act.y, act.x - req.x, act.y - req.y];
        if (req.x > maxReqX) { maxReqX = req.x; ratioX = act.x / req.x; }
        if (req.y > maxReqY) { maxReqY = req.y; ratioY = act.y / req.y; }
    }

    if (got == 0) {
        [self _setInfoText:@"❌ 注入的点击一个都没回来\n触摸 ID 可能已失效，先点几下屏幕再测"];
        return;
    }

    double avgX = sumDX / got, avgY = sumDY / got;
    [text appendFormat:@"\n平均偏 %+.1f,%+.1f 像素（%ld/%d 点到）\n比例 x %.4f  y %.4f",
     avgX, avgY, (long)got, (int)_calRequests.count, ratioX, ratioY];

    BOOL precise = (fabs(avgX) <= 3.0 && fabs(avgY) <= 3.0 &&
                    fabs(ratioX - 1.0) <= 0.003 && fabs(ratioY - 1.0) <= 0.003);
    if (precise) {
        [text appendString:@"\n✅ 准（≤3 像素）"];
    } else {
        [text appendFormat:@"\n⚠️ 有偏移：设 x=%.0f 会点到 %.0f", maxReqX, maxReqX * ratioX];
    }

    UIPasteboard.generalPasteboard.string = text;
    [self _setInfoText:text];
}

#pragma mark - 触摸处理（简化版：无方向校验，点一次记一次）

+ (void)_handleTap:(UITapGestureRecognizer *)tap
{
    // 先确保 rootView.frame = window.bounds（方向变化后可能没及时更新）
    CGRect wb = _testWindow.bounds;
    if (!CGRectEqualToRect(_testRootView.frame, wb)) {
        _testRootView.frame = wb;
    }

    CGPoint screenPt = [tap locationInView:nil];         // 设备竖屏点数空间

    // 测偏移中：这一击是注入回来的，只记落点，不进四角记录
    if (_calRunning) {
        CGFloat scale = [Screen getScale];
        if (scale <= 0) scale = 1;
        [self _calRecordActual:CGPointMake(screenPt.x * scale, screenPt.y * scale)];
        return;
    }

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

+ (void)_setInfoText:(NSString *)text
{
    if (!_infoLabel) return;
    _infoLabel.text = text;
    CGFloat width = _testWindow.portraitFrame.size.width;
    if (width <= 0) width = 375;
    CGSize fit = [_infoLabel sizeThatFits:CGSizeMake(MIN(340, width - 20), CGFLOAT_MAX)];
    _infoLabel.frame = CGRectMake(10, 10, fit.width + 16, fit.height + 12);
}

+ (void)_flashInfo:(NSString *)text
{
    [self _setInfoText:text];
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
            @"点左下角【测偏移】自动量注入精度（设的坐标 vs 实际落点）",
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
    [self _setInfoText:text];
}

@end
