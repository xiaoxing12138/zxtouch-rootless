//
//  PickOverlay.xm
//  小新Lap 悬浮取点器
//
//  见 PickOverlay.h 的说明。窗口跟着方向转，屏幕点 × 缩放 = 触摸指示器坐标。
//

#import "PickOverlay.h"
#import "FloatingMenu.h"      // FMPassthroughWindow / preferredWindowScene
#import "Common.h"            // ZXSafeMainAsync
#import "Screen.h"            // 抓帧 / 取色 / 坐标换算
#import "AlertBox.h"

NSString * const kPickStart = @"start";
NSString * const kPickEnd = @"end";
NSString * const kPickRect = @"rect";
NSString * const kPickHex = @"hex";
NSString * const kPickTemplate = @"template";

#define PK_RING_R     14.0f
#define PK_GRAB_SIZE  120.0f    // 十字的触摸热区：比十字本身大得多，手指可以从下方抓住拖动，不挡视线
#define PK_BAR_H      40.0f

#pragma mark - 透传根视图 / 画布

@interface PKRootView : UIView
@end

@implementation PKRootView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;   // 空白处一律穿给下面的游戏
}
@end

@interface PKRootViewController : UIViewController
@end

@implementation PKRootViewController
- (void)loadView {
    PKRootView *v = [[PKRootView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    v.backgroundColor = [UIColor clearColor];
    self.view = v;
}
@end

// 画布：点模式下只画十字、完全透传；框选模式下自己接收拖动
@interface PKCanvasView : UIView
@property (nonatomic, assign) BOOL interactive;
@property (nonatomic, assign) BOOL showsCrosshair;
@property (nonatomic, assign) BOOL showsRect;
@property (nonatomic, assign) CGPoint crosshair;
@property (nonatomic, assign) CGRect pickedRect;
@end

@implementation PKCanvasView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.interactive) return nil;
    return [super hitTest:point withEvent:event];
}

- (void)setShowsCrosshair:(BOOL)showsCrosshair { _showsCrosshair = showsCrosshair; [self setNeedsDisplay]; }
- (void)setShowsRect:(BOOL)showsRect { _showsRect = showsRect; [self setNeedsDisplay]; }
- (void)setCrosshair:(CGPoint)crosshair { _crosshair = crosshair; [self setNeedsDisplay]; }
- (void)setPickedRect:(CGRect)pickedRect { _pickedRect = pickedRect; [self setNeedsDisplay]; }

- (void)drawRect:(CGRect)bounds {
    if (_showsRect) {
        CGRect r = _pickedRect;
        [[UIColor colorWithWhite:0 alpha:0.5] setFill];
        if (r.size.width < 1 || r.size.height < 1) {
            UIRectFill(bounds);          // 还没开始框：整屏压暗
        } else {
            // 四个矩形拼出「框外压暗」
            UIRectFill(CGRectMake(0, 0, bounds.size.width, CGRectGetMinY(r)));
            UIRectFill(CGRectMake(0, CGRectGetMaxY(r), bounds.size.width, bounds.size.height - CGRectGetMaxY(r)));
            UIRectFill(CGRectMake(0, CGRectGetMinY(r), CGRectGetMinX(r), r.size.height));
            UIRectFill(CGRectMake(CGRectGetMaxX(r), CGRectGetMinY(r),
                                  bounds.size.width - CGRectGetMaxX(r), r.size.height));
            UIBezierPath *edge = [UIBezierPath bezierPathWithRect:r];
            edge.lineWidth = 2;
            [[UIColor systemYellowColor] setStroke];
            [edge stroke];
        }
    }

    if (!_showsCrosshair) return;
    CGPoint c = _crosshair;
    CGFloat r = PK_RING_R;
    // 圆圈里面是空的 —— 正中间那个像素不能被挡住，取色要读它
    UIBezierPath *ring = [UIBezierPath bezierPathWithArcCenter:c radius:r startAngle:0 endAngle:M_PI * 2 clockwise:YES];
    ring.lineWidth = 4;
    [[UIColor colorWithWhite:0 alpha:0.55] setStroke];
    [ring stroke];
    ring.lineWidth = 2;
    [[UIColor whiteColor] setStroke];
    [ring stroke];

    UIBezierPath *ticks = [UIBezierPath bezierPath];
    [ticks moveToPoint:CGPointMake(c.x - r - 13, c.y)]; [ticks addLineToPoint:CGPointMake(c.x - r - 3, c.y)];
    [ticks moveToPoint:CGPointMake(c.x + r + 3, c.y)];  [ticks addLineToPoint:CGPointMake(c.x + r + 13, c.y)];
    [ticks moveToPoint:CGPointMake(c.x, c.y - r - 13)]; [ticks addLineToPoint:CGPointMake(c.x, c.y - r - 3)];
    [ticks moveToPoint:CGPointMake(c.x, c.y + r + 3)];  [ticks addLineToPoint:CGPointMake(c.x, c.y + r + 13)];
    ticks.lineWidth = 4;
    [[UIColor colorWithWhite:0 alpha:0.55] setStroke];
    [ticks stroke];
    ticks.lineWidth = 2;
    [[UIColor whiteColor] setStroke];
    [ticks stroke];
}
@end

static UIButton *pkMakeButton(NSString *title, UIColor *color) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    b.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.85];
    b.layer.cornerRadius = 8;
    b.layer.borderWidth = 1;
    b.layer.borderColor = color.CGColor;
    [b setTitleColor:color forState:UIControlStateNormal];
    return b;
}

#pragma mark - 取点器

@interface PickOverlay ()
@end

static PickOverlay *_pkShared = nil;

@implementation PickOverlay {
    UIWindow     *_window;
    PKRootView   *_root;
    PKCanvasView *_canvas;
    UIImageView  *_freezeView;
    UIView       *_handle;      // 十字的拖动热区（隐形）
    UIView       *_bar;
    UILabel      *_readout;
    UIButton     *_confirmBtn;
    UIButton     *_cancelBtn;
    UIButton     *_recaptureBtn;

    FlowPickMode  _mode;
    void (^_completion)(NSDictionary *);
    void (^_cancelHandler)(void);

    UIImage  *_rawFrame;        // 未转正的原始竖屏帧（独立位图，不受之后抓屏影响）
    UIImage  *_shownFrame;      // 转正后显示用的图
    CGRect    _imageFrame;      // 显示图（或点模式下的整屏）在 root 坐标系里的位置

    CGPoint   _crosshair;       // root 坐标
    CGPoint   _grabCrosshair;   // 抓手按下时的十字位置
    CGPoint   _grabFinger;
    CGPoint   _rectStart;       // 框选起点（root 坐标）
    CGPoint   _rectEnd;
    CGRect    _pickedRectView;
    BOOL      _hasRect;
    NSString *_liveHex;         // 取色模式下十字中心读到的颜色
    CFAbsoluteTime _lastColorRead;
}

+ (instancetype)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ _pkShared = [[PickOverlay alloc] init]; });
    return _pkShared;
}

+ (void)presentWithMode:(FlowPickMode)mode
             completion:(void (^)(NSDictionary *))completion
                 cancel:(void (^)(void))cancel
{
    ZXSafeMainAsync(^{
        [[self shared] presentMode:mode completion:completion cancel:cancel];
    });
}

+ (void)dismiss {
    ZXSafeMainAsync(^{
        [[self shared] teardown];
    });
}

+ (BOOL)isShown {
    return _pkShared && _pkShared->_window != nil;
}

#pragma mark - 建窗

- (void)presentMode:(FlowPickMode)mode
         completion:(void (^)(NSDictionary *))completion
             cancel:(void (^)(void))cancel
{
    [self teardown];

    _mode = mode;
    _completion = [completion copy];
    _cancelHandler = [cancel copy];
    _hasRect = NO;
    _pickedRectView = CGRectZero;
    _crosshair = CGPointZero;
    _liveHex = nil;
    _lastColorRead = 0;

    BOOL rectMode = (mode == FlowPickModeRect || mode == FlowPickModeTemplate);

    UIWindowScene *scene = [FloatingMenu preferredWindowScene];
    if (scene) _window = [[FMPassthroughWindow alloc] initWithWindowScene:scene];
    else _window = [[FMPassthroughWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    _window.windowLevel = UIWindowLevelAlert + 2;   // 在编辑器卡片之上、弹窗之下
    _window.backgroundColor = [UIColor clearColor];
    _window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _window.rootViewController = [[PKRootViewController alloc] init];
    _root = (PKRootView *)_window.rootViewController.view;

    _freezeView = [[UIImageView alloc] initWithFrame:_root.bounds];
    _freezeView.contentMode = UIViewContentModeScaleToFill;
    _freezeView.hidden = !rectMode;
    [_root addSubview:_freezeView];

    _canvas = [[PKCanvasView alloc] initWithFrame:_root.bounds];
    _canvas.backgroundColor = [UIColor clearColor];
    _canvas.showsCrosshair = !rectMode;
    _canvas.showsRect = rectMode;
    _canvas.interactive = rectMode;
    _canvas.userInteractionEnabled = rectMode;   // 点模式下不参与命中，画十字照样画
    [_canvas addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleRectPan:)]];
    [_root addSubview:_canvas];

    // 十字的抓手：隐形，只在热区内命中。必须加在顶栏下面，否则拖到屏幕顶部会抢走按钮的触摸
    _handle = [[UIView alloc] initWithFrame:CGRectMake(0, 0, PK_GRAB_SIZE, PK_GRAB_SIZE)];
    _handle.backgroundColor = [UIColor clearColor];
    _handle.hidden = rectMode;
    [_handle addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleCrosshairPan:)]];
    [_root addSubview:_handle];

    _bar = [[UIView alloc] initWithFrame:CGRectMake(8, 6, _root.bounds.size.width - 16, PK_BAR_H)];
    _bar.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.75];
    _bar.layer.cornerRadius = 10;
    [_root addSubview:_bar];

    _readout = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, _bar.bounds.size.width - 200, PK_BAR_H)];
    _readout.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold];
    _readout.textColor = [UIColor whiteColor];
    _readout.numberOfLines = 2;
    [_bar addSubview:_readout];

    _confirmBtn = pkMakeButton(@"确定", [UIColor systemGreenColor]);
    [_confirmBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        [self confirmTapped];
    }] forControlEvents:UIControlEventTouchUpInside];
    [_bar addSubview:_confirmBtn];

    _cancelBtn = pkMakeButton(@"取消", [UIColor systemRedColor]);
    [_cancelBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        [self cancelTapped];
    }] forControlEvents:UIControlEventTouchUpInside];
    [_bar addSubview:_cancelBtn];

    _recaptureBtn = pkMakeButton(@"重截", [UIColor systemBlueColor]);
    _recaptureBtn.hidden = !rectMode;
    [_recaptureBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        [self recaptureTapped];
    }] forControlEvents:UIControlEventTouchUpInside];
    [_bar addSubview:_recaptureBtn];

    _window.hidden = YES;
    // 先抓帧再显示窗口：抓屏抓的是屏幕上显示的东西，窗口一显示就会把自己的顶栏也截进去
    if (rectMode) [self captureFreezeFrame];

    _window.hidden = NO;
    // window 刚创建时 bounds 可能还是 0，等下一帧 scene 摆正后再量
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_window) return;
        [self layoutOverlay];
    });
}

- (void)layoutOverlay {
    CGRect b = _root.bounds;
    if (b.size.width <= 0 || b.size.height <= 0) return;

    _canvas.frame = b;
    _freezeView.frame = b;

    CGFloat top = _root.safeAreaInsets.top;
    if (top < 6) top = 6;
    CGFloat inset = MIN(8.0f, b.size.width / 20.0f);
    _bar.frame = CGRectMake(inset, top, b.size.width - inset * 2, PK_BAR_H);

    // 顶栏右侧从右往左排：取消 / 确定 /（框选时）重截
    CGFloat gap = 6, rightX = _bar.bounds.size.width - 8;
    _cancelBtn.frame = CGRectMake(rightX - 52, 5, 52, PK_BAR_H - 10);
    rightX -= 52 + gap;
    _confirmBtn.frame = CGRectMake(rightX - 52, 5, 52, PK_BAR_H - 10);
    rightX -= 52 + gap;
    if (_recaptureBtn.isHidden) {
        _readout.frame = CGRectMake(12, 0, rightX - 12, PK_BAR_H);
    } else {
        _recaptureBtn.frame = CGRectMake(rightX - 52, 5, 52, PK_BAR_H - 10);
        rightX -= 52 + gap;
        _readout.frame = CGRectMake(12, 0, rightX - 12, PK_BAR_H);
    }

    if (_shownFrame) [self updateImageFrame];
    else _imageFrame = b;   // 点模式：整屏就是「指示器空间」

    if (_crosshair.x <= 0 && _crosshair.y <= 0) {
        _crosshair = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
    }
    [self moveCrosshairTo:_crosshair];
    [self updateReadout];
}

#pragma mark - 坐标

// 屏幕上的一点（root 坐标）→ 触摸指示器坐标。窗口跟着方向转，所以只用缩放、没有旋转
- (CGPoint)indicatorFromView:(CGPoint)p {
    CGSize space = [self pickSpaceSize];
    CGRect f = _imageFrame;
    if (f.size.width <= 0 || f.size.height <= 0) return CGPointZero;
    return CGPointMake((p.x - f.origin.x) / f.size.width * space.width,
                       (p.y - f.origin.y) / f.size.height * space.height);
}

- (CGSize)pickSpaceSize {
    if (_shownFrame) return _shownFrame.size;   // 转正后的图像素 = 指示器坐标
    CGFloat s = [UIScreen mainScreen].scale;
    if (s <= 0) s = 1;
    return CGSizeMake(_root.bounds.size.width * s, _root.bounds.size.height * s);
}

- (void)moveCrosshairTo:(CGPoint)p {
    CGRect b = _root.bounds;
    CGFloat pad = PK_RING_R;
    p.x = MAX(pad, MIN(b.size.width - pad, p.x));
    p.y = MAX(pad, MIN(b.size.height - pad, p.y));
    _crosshair = p;
    _canvas.crosshair = p;
    _handle.frame = CGRectMake(p.x - PK_GRAB_SIZE / 2.0f, p.y - PK_GRAB_SIZE / 2.0f, PK_GRAB_SIZE, PK_GRAB_SIZE);
}

#pragma mark - 手势

- (void)handleCrosshairPan:(UIPanGestureRecognizer *)g {
    CGPoint p = [g locationInView:_root];
    if (g.state == UIGestureRecognizerStateBegan) {
        _grabCrosshair = _crosshair;
        _grabFinger = p;
        return;
    }
    if (g.state == UIGestureRecognizerStateChanged) {
        // 按位移拖动：手指可以从十字下面一点的位置抓住它，看得见再对准
        [self moveCrosshairTo:CGPointMake(_grabCrosshair.x + (p.x - _grabFinger.x),
                                          _grabCrosshair.y + (p.y - _grabFinger.y))];
        [self updateReadout];
    }
}

- (void)handleRectPan:(UIPanGestureRecognizer *)g {
    CGPoint p = [g locationInView:_root];
    if (g.state == UIGestureRecognizerStateBegan) {
        _rectStart = p;
        _rectEnd = p;
        _hasRect = NO;
        _pickedRectView = CGRectZero;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGRect b = _root.bounds;
        _rectEnd = CGPointMake(MAX(0, MIN(b.size.width, p.x)), MAX(0, MIN(b.size.height, p.y)));
        _pickedRectView = CGRectMake(MIN(_rectStart.x, _rectEnd.x), MIN(_rectStart.y, _rectEnd.y),
                                     fabs(_rectEnd.x - _rectStart.x), fabs(_rectEnd.y - _rectStart.y));
        _hasRect = (_pickedRectView.size.width >= 6 && _pickedRectView.size.height >= 6);
    } else {
        return;
    }
    _canvas.pickedRect = _pickedRectView;
    [self updateReadout];
}

#pragma mark - 读数

- (void)updateReadout {
    BOOL rectMode = (_mode == FlowPickModeRect || _mode == FlowPickModeTemplate);
    if (rectMode) {
        if (!_hasRect) {
            _readout.text = @"在画面上拖一个框";
            return;
        }
        CGRect ind = [self indicatorRectFromViewRect:_pickedRectView];
        _readout.text = [NSString stringWithFormat:@"区域 左 %ld  上 %ld  宽 %ld  高 %ld",
                         (long)llround(CGRectGetMinX(ind)), (long)llround(CGRectGetMinY(ind)),
                         (long)llround(ind.size.width), (long)llround(ind.size.height)];
        return;
    }

    CGPoint ind = [self indicatorFromView:_crosshair];
    NSString *text = [NSString stringWithFormat:@"坐标 %ld, %ld", (long)llround(ind.x), (long)llround(ind.y)];
    if (_mode == FlowPickModeColor) {
        // 抓一帧是有成本的，拖动时限制到 10Hz
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (_lastColorRead == 0 || now - _lastColorRead > 0.1) {
            _lastColorRead = now;
            _liveHex = [self hexAtIndicatorPoint:ind];
        }
        text = [text stringByAppendingFormat:@"   颜色 #%@", _liveHex ?: @"----"];
    }
    _readout.text = text;
}

- (CGRect)indicatorRectFromViewRect:(CGRect)viewRect {
    CGPoint a = [self indicatorFromView:CGPointMake(CGRectGetMinX(viewRect), CGRectGetMinY(viewRect))];
    CGPoint b = [self indicatorFromView:CGPointMake(CGRectGetMaxX(viewRect), CGRectGetMaxY(viewRect))];
    return CGRectMake(MIN(a.x, b.x), MIN(a.y, b.y), fabs(b.x - a.x), fabs(b.y - a.y));
}

// 从「当前实时帧」读像素颜色：BGRA 直读，避开转正重采样
- (NSString *)hexAtIndicatorPoint:(CGPoint)indicator {
    int stride = 0, w = 0, h = 0;
    const UInt8 *pixels = [Screen framePixelsWithStride:&stride width:&w height:&h];
    if (!pixels || w <= 0 || h <= 0) return nil;

    CGPoint f = ZXFramePointFromIndicatorPoint(indicator);
    NSInteger x = (NSInteger)llround(f.x), y = (NSInteger)llround(f.y);
    x = MAX(0, MIN(w - 1, x));
    y = MAX(0, MIN(h - 1, y));
    const UInt8 *p = pixels + (NSInteger)y * stride + (NSInteger)x * 4;
    return [NSString stringWithFormat:@"%02X%02X%02X", p[2], p[1], p[0]];   // BGRA
}

#pragma mark - 冻帧 / 模板

- (BOOL)captureFreezeFrame {
    CGImageRef cg = [Screen createScreenShotCGImageRef];
    if (!cg) return NO;

    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w == 0 || h == 0) return NO;

    // 立刻拷成独立位图：这张 CGImage 直接指着抓屏用的 IOSurface，下一次抓屏会把它整块覆盖
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(w, h), NO, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    UIImage *raw = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!raw) return NO;

    _rawFrame = raw;
    NSInteger orientation = [Screen getScreenOrientation];
    if (orientation < 1 || orientation > 4) orientation = 1;
    _shownFrame = [self rotatedImage:raw orientation:orientation];
    _freezeView.image = _shownFrame;
    return YES;
}

// 把竖屏原始帧转成用户眼里的方向：转好之后图上像素坐标正好等于触摸指示器坐标
- (UIImage *)rotatedImage:(UIImage *)raw orientation:(NSInteger)orientation {
    if (orientation == 1) return raw;

    CGSize size = raw.size;
    CGSize newSize = (orientation == 2) ? size : CGSizeMake(size.height, size.width);
    UIGraphicsBeginImageContextWithOptions(newSize, NO, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    switch (orientation) {
        case 2:
            CGContextTranslateCTM(ctx, size.width, size.height);
            CGContextRotateCTM(ctx, M_PI);
            break;
        case 3:
            CGContextTranslateCTM(ctx, 0, newSize.height);
            CGContextRotateCTM(ctx, -M_PI_2);
            break;
        case 4:
            CGContextTranslateCTM(ctx, newSize.width, 0);
            CGContextRotateCTM(ctx, M_PI_2);
            break;
        default:
            break;
    }
    [raw drawInRect:CGRectMake(0, 0, size.width, size.height)];
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result ?: raw;
}

- (void)updateImageFrame {
    UIImage *image = _shownFrame;
    CGRect b = _root.bounds;
    if (!image || image.size.width <= 0 || image.size.height <= 0 || b.size.width <= 0 || b.size.height <= 0) {
        _imageFrame = b;
        return;
    }
    CGFloat scale = MIN(b.size.width / image.size.width, b.size.height / image.size.height);
    CGSize fitted = CGSizeMake(image.size.width * scale, image.size.height * scale);
    _imageFrame = CGRectMake(CGRectGetMidX(b) - fitted.width / 2.0f,
                             CGRectGetMidY(b) - fitted.height / 2.0f,
                             fitted.width, fitted.height);
    _freezeView.frame = _imageFrame;
}

// 重截：先把窗口隐掉再抓，否则自己的顶栏会被截进画面
- (void)recaptureTapped {
    _window.alpha = 0;
    ZXSafeMainAsync(^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!self->_window) return;
            [self captureFreezeFrame];
            [self updateImageFrame];
            [self updateReadout];
            self->_window.alpha = 1;
        });
    });
}

// 显示图上的框 → 原始竖屏帧上的矩形 → 从原始帧抠图存 PNG
// 引擎永远拿竖屏原始帧做匹配，模板也必须是原帧里的样子
- (NSString *)saveTemplateFromIndicatorRect:(CGRect)indicatorRect {
    if (!_rawFrame) return nil;

    CGRect frameRect = ZXFrameRectFromIndicatorRect(indicatorRect);
    NSInteger w = (NSInteger)_rawFrame.size.width, h = (NSInteger)_rawFrame.size.height;
    NSInteger x = MAX(0, MIN(w - 1, (NSInteger)floor(CGRectGetMinX(frameRect))));
    NSInteger y = MAX(0, MIN(h - 1, (NSInteger)floor(CGRectGetMinY(frameRect))));
    NSInteger fw = MAX(1, MIN(w - x, (NSInteger)ceil(frameRect.size.width)));
    NSInteger fh = MAX(1, MIN(h - y, (NSInteger)ceil(frameRect.size.height)));

    CGImageRef cropped = CGImageCreateWithImageInRect(_rawFrame.CGImage, CGRectMake(x, y, fw, fh));
    if (!cropped) return nil;
    UIImage *templateImage = [UIImage imageWithCGImage:cropped scale:1.0 orientation:UIImageOrientationUp];
    CGImageRelease(cropped);
    NSData *png = UIImagePNGRepresentation(templateImage);
    if (!png) return nil;

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kFlowTemplateFolder]) {
        [fm createDirectoryAtPath:kFlowTemplateFolder withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    NSString *name = nil;
    for (NSInteger i = 1; i < 1000; i++) {
        NSString *candidate = [NSString stringWithFormat:@"tpl%ld.png", (long)i];
        if (![fm fileExistsAtPath:[kFlowTemplateFolder stringByAppendingPathComponent:candidate]]) {
            name = candidate;
            break;
        }
    }
    if (!name) name = [NSString stringWithFormat:@"tpl%u.png", arc4random_uniform(100000)];
    if (![png writeToFile:[kFlowTemplateFolder stringByAppendingPathComponent:name] atomically:YES]) return nil;
    return name;
}

#pragma mark - 完成 / 取消

- (void)confirmTapped {
    BOOL rectMode = (_mode == FlowPickModeRect || _mode == FlowPickModeTemplate);
    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    if (rectMode) {
        if (!_hasRect) {
            showAlertBox(@"提示", @"请先在画面上拖一个框。", 2);
            return;
        }
        NSInteger left = (NSInteger)llround([self indicatorFromView:_rectStart].x);
        NSInteger top = (NSInteger)llround([self indicatorFromView:_rectStart].y);
        NSInteger right = (NSInteger)llround([self indicatorFromView:_rectEnd].x);
        NSInteger bottom = (NSInteger)llround([self indicatorFromView:_rectEnd].y);
        // 起点 / 终点分开存：滑动要的是方向，不能被外接矩形抹掉
        result[kPickStart] = [NSValue valueWithCGPoint:CGPointMake(left, top)];
        result[kPickEnd] = [NSValue valueWithCGPoint:CGPointMake(right, bottom)];
        result[kPickRect] = [NSValue valueWithCGRect:CGRectMake(MIN(left, right), MIN(top, bottom),
                                                               labs(right - left), labs(bottom - top))];

        if (_mode == FlowPickModeTemplate) {
            NSString *name = [self saveTemplateFromIndicatorRect:[result[kPickRect] CGRectValue]];
            if (!name) {
                showAlertBox(@"错误", @"模板保存失败，请重试。", 2);
                return;
            }
            result[kPickTemplate] = name;
        }
    } else {
        CGPoint ind = [self indicatorFromView:_crosshair];
        CGPoint point = CGPointMake(llround(ind.x), llround(ind.y));
        result[kPickStart] = [NSValue valueWithCGPoint:point];
        result[kPickEnd] = [NSValue valueWithCGPoint:point];
        result[kPickRect] = [NSValue valueWithCGRect:CGRectMake(point.x, point.y, 1, 1)];
        if (_mode == FlowPickModeColor) {
            result[kPickHex] = [self hexAtIndicatorPoint:ind] ?: @"";
        }
    }

    void (^completion)(NSDictionary *) = _completion;
    [self teardown];
    if (completion) completion(result);
}

- (void)cancelTapped {
    void (^cancel)(void) = _cancelHandler;
    [self teardown];
    if (cancel) cancel();
}

- (void)teardown {
    if (!_window && !_root) return;
    [_root endEditing:YES];
    _window.hidden = YES;
    _window.rootViewController = nil;
    for (UIView *v in [_root.subviews copy]) [v removeFromSuperview];
    _window = nil;
    _root = nil;
    _canvas = nil;
    _freezeView = nil;
    _handle = nil;
    _bar = nil;
    _readout = nil;
    _confirmBtn = nil;
    _cancelBtn = nil;
    _recaptureBtn = nil;
    _rawFrame = nil;
    _shownFrame = nil;
    _imageFrame = CGRectZero;
    _completion = nil;
    _cancelHandler = nil;
}

@end