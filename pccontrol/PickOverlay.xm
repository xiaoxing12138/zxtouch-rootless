//
//  PickOverlay.xm
//  小新Lap 悬浮取点器
//
//  见 PickOverlay.h 的说明。窗口跟着方向转，屏幕点 × 缩放 = 触摸指示器坐标。
//

#import "PickOverlay.h"
#import "FloatingMenu.h"      // FMPassthroughWindow / preferredWindowScene
#import "Common.h"            // ZXSafeMainAsync / ZXPalette
#import "Screen.h"            // 抓帧 / 坐标换算
#import "AlertBox.h"

#import <math.h>

NSString * const kPickStart = @"start";
NSString * const kPickEnd = @"end";
NSString * const kPickRect = @"rect";
NSString * const kPickHex = @"hex";
NSString * const kPickTemplate = @"template";

#define PK_RING_R     15.0f     // 选择器圆环半径
#define PK_GRAB_R     160.0f    // 手指落点离选择器多近算「抓住它」，再远就当成点空白
#define PK_MAG_PX     33        // 放大预览覆盖的指示器像素（奇数 → 正中那格就是选中的像素）
#define PK_MAG_SIZE   84.0f
#define PK_PANEL_W    272.0f
#define PK_PAD        8.0f
#define PK_GAP        6.0f
#define PK_HEAD_H     30.0f
#define PK_FOOT_H     40.0f
#define PK_READ_H     26.0f     // 读数行（点 / 路径模式一行够）
#define PK_READ_H2    40.0f     // 框选模式要两行放区域数字
#define PK_COLOR_H    20.0f     // 颜色块那一行
#define PK_CTRL_H     104.0f    // 微调盘 + 放大预览那一块
#define PK_NUDGE_CELL 34.0f

static UInt8 *PKCopyPixels(UIImage *image, size_t *outW, size_t *outH, size_t *outStride);

static UIButton *pkMakeButton(NSString *title, UIColor *color)
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    b.backgroundColor = [ZXPalette(ZXPalField) colorWithAlphaComponent:0.9];
    b.layer.cornerRadius = 8;
    b.layer.borderWidth = 1;
    b.layer.borderColor = [color colorWithAlphaComponent:0.75f].CGColor;
    [b setTitleColor:color forState:UIControlStateNormal];
    return b;
}

#pragma mark - 透传根视图

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

#pragma mark - 画选择器 / 轨迹

// 选中点：圆环 + 圆内十字。四段短线都指向圆心、正中留 2pt 空隙，
// 圆心那颗像素始终不被挡住（取色读的就是它）。
static void PKDrawSelector(CGPoint c, UIColor *tint, BOOL active)
{
    CGFloat r = PK_RING_R;
    UIBezierPath *ring = [UIBezierPath bezierPathWithArcCenter:c radius:r startAngle:0 endAngle:M_PI * 2 clockwise:YES];
    ring.lineWidth = 6; [[UIColor colorWithWhite:0 alpha:0.5] setStroke]; [ring stroke];
    ring.lineWidth = active ? 3 : 2;
    [(active ? tint : [tint colorWithAlphaComponent:0.65f]) setStroke];
    [ring stroke];

    CGFloat gap = 2, len = r - 5;
    UIBezierPath *cross = [UIBezierPath bezierPath];
    [cross moveToPoint:CGPointMake(c.x - len, c.y)]; [cross addLineToPoint:CGPointMake(c.x - gap, c.y)];
    [cross moveToPoint:CGPointMake(c.x + gap, c.y)]; [cross addLineToPoint:CGPointMake(c.x + len, c.y)];
    [cross moveToPoint:CGPointMake(c.x, c.y - len)]; [cross addLineToPoint:CGPointMake(c.x, c.y - gap)];
    [cross moveToPoint:CGPointMake(c.x, c.y + gap)]; [cross addLineToPoint:CGPointMake(c.x, c.y + len)];
    cross.lineWidth = 5; [[UIColor colorWithWhite:0 alpha:0.55] setStroke]; [cross stroke];
    cross.lineWidth = 2.5; [[UIColor whiteColor] setStroke]; [cross stroke];
}

static void PKDrawTag(CGPoint c, NSString *text, UIColor *bg)
{
    NSDictionary *attrs = @{ NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold],
                             NSForegroundColorAttributeName: [UIColor whiteColor] };
    CGSize ts = [text sizeWithAttributes:attrs];
    CGRect box = CGRectMake(c.x - (ts.width + 14) / 2.0f, c.y - PK_RING_R - 26, ts.width + 14, 18);
    [bg setFill];
    [[UIBezierPath bezierPathWithRoundedRect:box cornerRadius:9] fill];
    [text drawAtPoint:CGPointMake(box.origin.x + 7, box.origin.y + 3) withAttributes:attrs];
}

// 单个箭头：沿 angle 方向指的实心三角，带深色描边，压在轨迹线上也看得清
static void PKDrawArrowHead(CGPoint p, CGFloat angle)
{
    CGFloat s = 9;
    UIBezierPath *tri = [UIBezierPath bezierPath];
    [tri moveToPoint:CGPointMake(p.x + cos(angle) * s, p.y + sin(angle) * s)];
    [tri addLineToPoint:CGPointMake(p.x + cos(angle + 2.5f) * s, p.y + sin(angle + 2.5f) * s)];
    [tri addLineToPoint:CGPointMake(p.x + cos(angle - 2.5f) * s, p.y + sin(angle - 2.5f) * s)];
    [tri closePath];
    [[UIColor whiteColor] setFill];
    [tri fill];
    tri.lineWidth = 3;
    [[UIColor colorWithWhite:0 alpha:0.55] setStroke];
    [tri stroke];
}

// 滑动轨迹：起终点之间一条线 + 沿线摆几个箭头，箭头只放中段，避开两个圆环
static void PKDrawTrail(CGPoint a, CGPoint b)
{
    CGFloat dx = b.x - a.x, dy = b.y - a.y;
    CGFloat len = sqrt(dx * dx + dy * dy);
    if (len < 8) return;

    UIBezierPath *line = [UIBezierPath bezierPath];
    [line moveToPoint:a];
    [line addLineToPoint:b];
    line.lineCapStyle = kCGLineCapRound;
    line.lineWidth = 8; [[UIColor colorWithWhite:0 alpha:0.4] setStroke]; [line stroke];
    line.lineWidth = 3; [[UIColor colorWithWhite:1 alpha:0.9] setStroke]; [line stroke];

    CGFloat angle = atan2(dy, dx);
    const CGFloat ts[] = { 0.24f, 0.38f, 0.5f, 0.62f, 0.76f };
    for (int i = 0; i < 5; i++) {
        PKDrawArrowHead(CGPointMake(a.x + dx * ts[i], a.y + dy * ts[i]), angle);
    }
}

#pragma mark - 画布

// 画布完全不参与命中（触摸全交给上面那层 catcher），只负责把选择器 / 轨迹 / 框画出来
@interface PKCanvasView : UIView
@property (nonatomic, assign) FlowPickMode mode;
@property (nonatomic, assign) CGPoint startPoint;
@property (nonatomic, assign) CGPoint endPoint;
@property (nonatomic, assign) CGPoint crosshair;
@property (nonatomic, assign) BOOL activeIsEnd;
@property (nonatomic, assign) CGRect pickedRect;
@property (nonatomic, assign) BOOL hasRect;
@end

@implementation PKCanvasView

- (void)setMode:(FlowPickMode)mode { _mode = mode; [self setNeedsDisplay]; }
- (void)setStartPoint:(CGPoint)p { _startPoint = p; [self setNeedsDisplay]; }
- (void)setEndPoint:(CGPoint)p { _endPoint = p; [self setNeedsDisplay]; }
- (void)setCrosshair:(CGPoint)p { _crosshair = p; [self setNeedsDisplay]; }
- (void)setActiveIsEnd:(BOOL)v { _activeIsEnd = v; [self setNeedsDisplay]; }
- (void)setPickedRect:(CGRect)r { _pickedRect = r; [self setNeedsDisplay]; }
- (void)setHasRect:(BOOL)v { _hasRect = v; [self setNeedsDisplay]; }

- (void)drawRect:(CGRect)bounds {
    if (_mode == FlowPickModeRect || _mode == FlowPickModeTemplate) {
        CGRect r = _pickedRect;
        [[UIColor colorWithWhite:0 alpha:0.5] setFill];
        if (!_hasRect || r.size.width < 1 || r.size.height < 1) {
            UIRectFill(bounds);          // 还没开始框：整屏压暗
            return;
        }
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
        return;
    }

    if (_mode == FlowPickModePath) {
        PKDrawTrail(_startPoint, _endPoint);
        PKDrawSelector(_startPoint, ZXPalette(ZXPalAccent), !_activeIsEnd);
        PKDrawSelector(_endPoint, [UIColor systemOrangeColor], _activeIsEnd);
        PKDrawTag(_startPoint, @"起点", ZXPalette(ZXPalAccent));
        PKDrawTag(_endPoint, @"终点", [UIColor systemOrangeColor]);
        return;
    }

    PKDrawSelector(_crosshair, ZXPalette(ZXPalAccent), YES);
}

@end

#pragma mark - 放大预览

// 把准心周围 PK_MAG_PX 个像素放大铺满整块：正中那格描出来，一眼看到选的是哪颗像素。
// 靠近画面边缘时只画能取到的部分，正中那格永远在正中。
@interface PKMagnifierView : UIView
- (void)setSourceImage:(CGImageRef)source;
- (void)setCenterPoint:(CGPoint)center;   // 指示器坐标
@end

@implementation PKMagnifierView {
    CGImageRef _source;
    CGPoint    _center;
}

- (void)setSourceImage:(CGImageRef)source {
    if (_source == source) return;
    if (_source) CGImageRelease(_source);
    _source = source ? CGImageRetain(source) : NULL;
    [self setNeedsDisplay];
}

- (void)setCenterPoint:(CGPoint)center {
    _center = center;
    [self setNeedsDisplay];
}

- (void)dealloc {
    if (_source) CGImageRelease(_source);
}

- (void)drawRect:(CGRect)bounds {
    if (!_source) return;
    CGFloat side = PK_MAG_PX;
    CGFloat cell = bounds.size.width / side;
    CGRect want = CGRectMake(_center.x - (side - 1) / 2.0f, _center.y - (side - 1) / 2.0f, side, side);
    CGRect have = CGRectMake(0, 0, CGImageGetWidth(_source), CGImageGetHeight(_source));
    CGRect got = CGRectIntersection(want, have);
    if (CGRectIsNull(got) || got.size.width < 1 || got.size.height < 1) return;

    CGImageRef sub = CGImageCreateWithImageInRect(_source, got);
    if (sub) {
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
        CGRect dest = CGRectMake((got.origin.x - want.origin.x) * cell, (got.origin.y - want.origin.y) * cell,
                                 got.size.width * cell, got.size.height * cell);
        // CGImage 原点在左下、UIKit 在左上：就地翻一下再画，否则预览上下颠倒
        CGContextSaveGState(ctx);
        CGContextTranslateCTM(ctx, dest.origin.x, dest.origin.y + dest.size.height);
        CGContextScaleCTM(ctx, 1, -1);
        CGContextDrawImage(ctx, CGRectMake(0, 0, dest.size.width, dest.size.height), sub);
        CGContextRestoreGState(ctx);
        CGImageRelease(sub);
    }

    UIBezierPath *box = [UIBezierPath bezierPathWithRect:CGRectMake((bounds.size.width - cell) / 2.0f,
                                                                   (bounds.size.height - cell) / 2.0f, cell, cell)];
    box.lineWidth = 3; [[UIColor colorWithWhite:0 alpha:0.75] setStroke]; [box stroke];
    box.lineWidth = 1.5; [[UIColor whiteColor] setStroke]; [box stroke];
}

@end

#pragma mark - 微调按钮

// 点一下走一步；按住不动就连续走，8 步之后自动加速（1px → 5px），省得一直戳
@interface PKNudgeView : UIView
@property (nonatomic, copy) void (^onStep)(BOOL fast);
- (void)stop;
@end

@implementation PKNudgeView {
    NSTimer  *_timer;
    NSInteger _count;
}

- (instancetype)initWithSymbol:(NSString *)symbol {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        self.backgroundColor = ZXPalette(ZXPalField);
        self.layer.cornerRadius = 8;
        self.layer.borderWidth = 1;
        self.layer.borderColor = ZXPalette(ZXPalLine).CGColor;

        UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
        icon.tintColor = ZXPalette(ZXPalText);
        icon.contentMode = UIViewContentModeScaleAspectFit;
        icon.tag = 1;
        [self addSubview:icon];

        // minimumPressDuration = 0：按下即 Began、抬手即 Ended，单击和长按用同一套
        UILongPressGestureRecognizer *g = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handle:)];
        g.minimumPressDuration = 0;
        g.allowableMovement = 30;
        [self addGestureRecognizer:g];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self viewWithTag:1].frame = CGRectInset(self.bounds, 9, 9);
}

- (void)handle:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        _count = 0;
        self.backgroundColor = ZXPalette(ZXPalRow);
        [self tick];
        __weak typeof(self) weakSelf = self;
        _timer = [NSTimer timerWithTimeInterval:0.06 repeats:YES block:^(NSTimer *t) { [weakSelf tick]; }];
        [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled ||
               g.state == UIGestureRecognizerStateFailed) {
        [self stop];
    }
}

- (void)tick {
    _count++;
    if (self.onStep) self.onStep(_count > 8);
}

- (void)stop {
    [_timer invalidate];
    _timer = nil;
    self.backgroundColor = ZXPalette(ZXPalField);
}

@end

#pragma mark - 取点器

@interface PickOverlay ()
@end

static PickOverlay *_pkShared = nil;

@implementation PickOverlay {
    UIWindow         *_window;
    PKRootView       *_root;
    UIImageView      *_freezeView;
    PKCanvasView     *_canvas;
    UIView           *_catcher;        // 全屏触摸层（在画布之上、面板之下）
    UIView           *_panel;
    UIView           *_header;
    UILabel          *_tagLabel;       // 路径模式：当前在动的是起点还是终点
    UILabel          *_xLabel;
    UILabel          *_yLabel;
    UIView           *_swatch;
    UILabel          *_hexLabel;
    PKMagnifierView  *_mag;
    PKNudgeView      *_up, *_down, *_left, *_right;
    UIButton         *_confirmBtn, *_cancelBtn, *_recaptureBtn;

    FlowPickMode  _mode;
    void (^_completion)(NSDictionary *);
    void (^_cancelHandler)(void);

    UIImage  *_rawFrame;        // 未转正的原始竖屏帧（独立位图，不受之后抓屏影响）
    UIImage  *_shownFrame;      // 转正后显示用的图（像素坐标 = 指示器坐标）
    CGRect    _imageFrame;      // 显示图在 root 坐标系里的位置
    UInt8    *_pixels;          // _shownFrame 的 BGRA 拷贝：冻屏后取色 / 预览都读它
    size_t    _pixelW, _pixelH, _pixelStride;

    CGPoint   _crosshair;       // Point / Color 模式的准心（root 坐标）
    CGPoint   _start, _end;     // Path 模式的两个选择器
    BOOL      _activeIsEnd;
    CGPoint   _grabOffset;      // 手指相对选择器的偏移：抓住后按位移走，手指不挡住选择器

    CGPoint   _rectStart, _rectEnd;
    CGRect    _pickedRectView;
    BOOL      _hasRect;

    CGPoint   _panelOrigin;
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
    _grabOffset = CGPointZero;
    _activeIsEnd = NO;

    UIWindowScene *scene = [FloatingMenu preferredWindowScene];
    if (scene) _window = [[FMPassthroughWindow alloc] initWithWindowScene:scene];
    else _window = [[FMPassthroughWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    _window.windowLevel = UIWindowLevelAlert + 2;   // 在编辑器卡片之上、弹窗之下
    _window.backgroundColor = [UIColor clearColor];
    _window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _window.rootViewController = [[PKRootViewController alloc] init];
    _root = (PKRootView *)_window.rootViewController.view;

    // 抓屏抓的是屏幕上「此刻合成出来」的那一帧。调用方的卡片刚被隐藏，
    // 这一次合成还没提交上去，这一轮立刻抓会把卡片本身烤进冻结帧。
    // 等两帧（~0.13s）再抓，顺便把帧缓存作废，保证抓到的是干净的新画面。
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.13 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        PickOverlay *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_window) return;
        [Screen invalidateFrame];
        if (![strongSelf captureFreezeFrame]) {
            [strongSelf teardown];
            showAlertBox(@"错误", @"抓屏失败，取点打不开，请重试。", 2);
            if (cancel) cancel();
            return;
        }
        [strongSelf buildOverlayViews];
        strongSelf->_window.hidden = NO;
        // window 刚创建时 bounds 可能还是 0，等下一帧 scene 摆正后再量
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!strongSelf->_window) return;
            [strongSelf layoutOverlay];
        });
    });
}

// 冻帧拿到之后才铺画面：底图 + 画布 + 触摸层 + 小面板
- (void)buildOverlayViews {
    _freezeView = [[UIImageView alloc] initWithFrame:_root.bounds];
    _freezeView.contentMode = UIViewContentModeScaleToFill;
    _freezeView.image = _shownFrame;
    [_root addSubview:_freezeView];

    _canvas = [[PKCanvasView alloc] initWithFrame:_root.bounds];
    _canvas.backgroundColor = [UIColor clearColor];
    _canvas.mode = _mode;
    _canvas.userInteractionEnabled = NO;
    [_root addSubview:_canvas];

    _catcher = [[UIView alloc] initWithFrame:_root.bounds];
    _catcher.backgroundColor = [UIColor clearColor];
    [_catcher addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)]];
    // 轻点（没拖动，pan 不会起手）：单选模式把准心挪到手指处，路径模式切起点/终点
    [_catcher addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)]];
    [_root addSubview:_catcher];

    [self buildPanel];
    [_mag setSourceImage:_shownFrame.CGImage];
    [_root addSubview:_panel];
}

#pragma mark - 小面板

- (void)buildPanel {
    _panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, PK_PANEL_W, 260)];
    _panel.backgroundColor = [ZXPalette(ZXPalCard) colorWithAlphaComponent:0.96];
    _panel.layer.cornerRadius = 14;
    _panel.layer.borderWidth = 1;
    _panel.layer.borderColor = ZXPalette(ZXPalLine).CGColor;
    _panel.layer.shadowColor = [UIColor blackColor].CGColor;
    _panel.layer.shadowOpacity = 0.35f;
    _panel.layer.shadowRadius = 12;
    _panel.layer.shadowOffset = CGSizeMake(0, 4);

    // 顶条：拖它挪面板。面板上的按钮各自响应触摸，拖动只从这条起手，不跟它们抢
    _header = [[UIView alloc] initWithFrame:CGRectZero];
    _header.backgroundColor = [UIColor clearColor];
    [_header addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanelPan:)]];
    [_panel addSubview:_header];

    UIImageView *grip = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"line.3.horizontal"]];
    grip.tintColor = ZXPalette(ZXPalSub);
    grip.tag = 1;
    [_header addSubview:grip];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.text = @"取点";
    title.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    title.textColor = ZXPalette(ZXPalText);
    title.tag = 2;
    [_header addSubview:title];

    _recaptureBtn = pkMakeButton(@"重截", ZXPalette(ZXPalAccent));
    [_recaptureBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        [self recaptureTapped];
    }] forControlEvents:UIControlEventTouchUpInside];
    [_header addSubview:_recaptureBtn];

    _tagLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _tagLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    _tagLabel.hidden = YES;
    [_panel addSubview:_tagLabel];

    _xLabel = [self makeReadoutLabel];
    _yLabel = [self makeReadoutLabel];
    [_panel addSubview:_xLabel];
    [_panel addSubview:_yLabel];

    _swatch = [[UIView alloc] initWithFrame:CGRectZero];
    _swatch.layer.cornerRadius = 4;
    _swatch.layer.borderWidth = 1;
    _swatch.layer.borderColor = ZXPalette(ZXPalLine).CGColor;
    [_panel addSubview:_swatch];

    _hexLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _hexLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    _hexLabel.textColor = ZXPalette(ZXPalSub);
    [_panel addSubview:_hexLabel];

    _mag = [[PKMagnifierView alloc] initWithFrame:CGRectZero];
    _mag.backgroundColor = [UIColor blackColor];
    _mag.layer.cornerRadius = 8;
    _mag.layer.borderWidth = 1;
    _mag.layer.borderColor = ZXPalette(ZXPalLine).CGColor;
    _mag.clipsToBounds = YES;
    [_panel addSubview:_mag];

    _up = [self makeNudge:@"chevron.up" dx:0 dy:-1];
    _down = [self makeNudge:@"chevron.down" dx:0 dy:1];
    _left = [self makeNudge:@"chevron.left" dx:-1 dy:0];
    _right = [self makeNudge:@"chevron.right" dx:1 dy:0];

    _cancelBtn = pkMakeButton(@"取消", ZXPalette(ZXPalDanger));
    [_cancelBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        [self cancelTapped];
    }] forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_cancelBtn];

    _confirmBtn = pkMakeButton(@"确定", ZXPalette(ZXPalAccent));
    [_confirmBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        [self confirmTapped];
    }] forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_confirmBtn];
}

- (UILabel *)makeReadoutLabel {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
    label.textColor = ZXPalette(ZXPalText);
    return label;
}

// 微调一格：dx/dy 是方向，按下去先慢慢走、久了自动加速
- (PKNudgeView *)makeNudge:(NSString *)symbol dx:(CGFloat)dx dy:(CGFloat)dy {
    PKNudgeView *v = [[PKNudgeView alloc] initWithFrame:CGRectZero];
    __weak typeof(self) weakSelf = self;
    v.onStep = ^(BOOL fast) { [weakSelf nudgeDX:dx * (fast ? 5 : 1) dy:dy * (fast ? 5 : 1)]; };
    [_panel addSubview:v];
    return v;
}

- (UIView *)subviewWithTag:(NSInteger)tag in:(UIView *)parent {
    for (UIView *v in parent.subviews) {
        if (v.tag == tag) return v;
    }
    return nil;
}

- (void)layoutPanel {
    BOOL rectMode = (_mode == FlowPickModeRect || _mode == FlowPickModeTemplate);
    BOOL multi = (_mode == FlowPickModePath);
    CGFloat readH = rectMode ? PK_READ_H2 : PK_READ_H;
    CGFloat colorH = rectMode ? 0 : PK_COLOR_H + 4;
    CGFloat ctrlH = rectMode ? 0 : PK_CTRL_H + PK_GAP;
    CGFloat h = PK_PAD + PK_HEAD_H + PK_GAP + readH + colorH + ctrlH + PK_GAP + PK_FOOT_H + PK_PAD;

    CGRect b = _root.bounds;
    if (_panelOrigin.x <= 0 && _panelOrigin.y <= 0) {
        _panelOrigin = CGPointMake(14, b.size.height - h - 14);
    }
    _panelOrigin.x = MAX(PK_PAD, MIN(b.size.width - PK_PANEL_W - PK_PAD, _panelOrigin.x));
    _panelOrigin.y = MAX(PK_PAD, MIN(b.size.height - h - PK_PAD, _panelOrigin.y));
    _panel.frame = CGRectMake(_panelOrigin.x, _panelOrigin.y, PK_PANEL_W, h);

    CGFloat w = PK_PANEL_W - PK_PAD * 2;
    CGFloat y = PK_PAD;
    _header.frame = CGRectMake(PK_PAD, y, w, PK_HEAD_H);
    [self subviewWithTag:1 in:_header].frame = CGRectMake(0, 9, 12, 12);
    [self subviewWithTag:2 in:_header].frame = CGRectMake(16, 6, 80, 18);
    _recaptureBtn.frame = CGRectMake(w - 54, 3, 54, PK_HEAD_H - 6);
    y += PK_HEAD_H + PK_GAP;

    _tagLabel.frame = multi ? CGRectMake(PK_PAD, y + 4, 40, 18) : CGRectZero;
    CGFloat readX = multi ? PK_PAD + 40 : PK_PAD;
    CGFloat readW = PK_PANEL_W - PK_PAD - readX;
    if (rectMode) {
        _xLabel.frame = CGRectMake(readX, y, readW, 18);
        _yLabel.frame = CGRectMake(readX, y + 20, readW, 18);
    } else {
        CGFloat half = (readW - PK_GAP) / 2.0f;
        _xLabel.frame = CGRectMake(readX, y + 3, half, 20);
        _yLabel.frame = CGRectMake(readX + half + PK_GAP, y + 3, half, 20);
    }
    y += readH;

    if (!rectMode) {
        _swatch.frame = CGRectMake(PK_PAD, y + 2, 14, 14);
        _hexLabel.frame = CGRectMake(PK_PAD + 20, y, 110, 18);
        y += colorH;

        // 微调盘：上排只放「上」，下排左 / 下 / 右
        CGFloat cell = PK_NUDGE_CELL, gap = 3;
        CGFloat padY = (PK_CTRL_H - (cell * 2 + gap)) / 2.0f;
        _up.frame = CGRectMake(PK_PAD + cell + gap, y + padY, cell, cell);
        _left.frame = CGRectMake(PK_PAD, y + padY + cell + gap, cell, cell);
        _down.frame = CGRectMake(PK_PAD + cell + gap, y + padY + cell + gap, cell, cell);
        _right.frame = CGRectMake(PK_PAD + (cell + gap) * 2, y + padY + cell + gap, cell, cell);
        _mag.frame = CGRectMake(PK_PANEL_W - PK_PAD - PK_MAG_SIZE, y + (PK_CTRL_H - PK_MAG_SIZE) / 2.0f,
                                PK_MAG_SIZE, PK_MAG_SIZE);
        y += ctrlH;
    }

    CGFloat btnW = (w - PK_GAP) / 2.0f;
    _cancelBtn.frame = CGRectMake(PK_PAD, y + PK_GAP, btnW, PK_FOOT_H);
    _confirmBtn.frame = CGRectMake(PK_PAD + btnW + PK_GAP, y + PK_GAP, btnW, PK_FOOT_H);

    _swatch.hidden = rectMode;
    _hexLabel.hidden = rectMode;
    _mag.hidden = rectMode;
    for (PKNudgeView *v in @[ _up, _down, _left, _right ]) v.hidden = rectMode;
}

- (void)layoutOverlay {
    CGRect b = _root.bounds;
    if (b.size.width <= 0 || b.size.height <= 0) return;

    _canvas.frame = b;
    _catcher.frame = b;
    [self updateImageFrame];

    if (_mode == FlowPickModePath) {
        if (_start.x <= 0 && _start.y <= 0) {
            _start = CGPointMake(b.size.width * 0.35f, b.size.height * 0.5f);
            _end = CGPointMake(b.size.width * 0.65f, b.size.height * 0.5f);
        }
    } else if (_crosshair.x <= 0 && _crosshair.y <= 0) {
        _crosshair = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
    }

    [self layoutPanel];
    [self pushGeometry];
}

#pragma mark - 坐标换算

// 屏幕上的点（root 坐标）→ 触摸指示器坐标。窗口跟着方向转，所以只用缩放、没有旋转
- (CGPoint)indicatorFromView:(CGPoint)p {
    CGSize space = [self pickSpaceSize];
    CGRect f = _imageFrame;
    if (f.size.width <= 0 || f.size.height <= 0) return CGPointZero;
    return CGPointMake((p.x - f.origin.x) / f.size.width * space.width,
                       (p.y - f.origin.y) / f.size.height * space.height);
}

- (CGSize)pickSpaceSize {
    // 冻帧之后：转正图的像素坐标就是指示器坐标
    if (_shownFrame) return _shownFrame.size;
    CGFloat s = [UIScreen mainScreen].scale;
    if (s <= 0) s = 1;
    return CGSizeMake(_root.bounds.size.width * s, _root.bounds.size.height * s);
}

// 指示器坐标下挪一个像素，在屏幕上等于多少点
- (CGFloat)viewPointsPerIndicatorPixel {
    CGSize space = [self pickSpaceSize];
    if (space.width <= 0 || _imageFrame.size.width <= 0) return 1;
    return _imageFrame.size.width / space.width;
}

- (CGPoint)clampViewPoint:(CGPoint)p {
    CGRect b = _root.bounds;
    CGFloat pad = PK_RING_R;
    return CGPointMake(MAX(pad, MIN(b.size.width - pad, p.x)), MAX(pad, MIN(b.size.height - pad, p.y)));
}

#pragma mark - 微调

- (void)nudgeDX:(CGFloat)dx dy:(CGFloat)dy {
    CGFloat k = [self viewPointsPerIndicatorPixel];
    if (_mode == FlowPickModePath) {
        CGPoint p = _activeIsEnd ? _end : _start;
        p = [self clampViewPoint:CGPointMake(p.x + dx * k, p.y + dy * k)];
        if (_activeIsEnd) _end = p; else _start = p;
    } else {
        _crosshair = [self clampViewPoint:CGPointMake(_crosshair.x + dx * k, _crosshair.y + dy * k)];
    }
    [self pushGeometry];
}

#pragma mark - 手势

- (void)handlePan:(UIPanGestureRecognizer *)g {
    CGPoint p = [g locationInView:_root];

    if (_mode == FlowPickModeRect || _mode == FlowPickModeTemplate) {
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
        _canvas.hasRect = _hasRect;
        [self updateReadout];
        return;
    }

    if (_mode == FlowPickModePath) {
        if (g.state == UIGestureRecognizerStateBegan) {
            // 就近抓住：离哪个选择器近就动哪个；两个都远就是想让当前那个挪到这儿来
            CGFloat ds = hypot(p.x - _start.x, p.y - _start.y);
            CGFloat de = hypot(p.x - _end.x, p.y - _end.y);
            BOOL near = (MIN(ds, de) <= PK_GRAB_R);
            if (near) _activeIsEnd = (de < ds);
            CGPoint anchor = _activeIsEnd ? _end : _start;
            _grabOffset = near ? CGPointMake(anchor.x - p.x, anchor.y - p.y) : CGPointZero;
            [self pushGeometry];       // 只点一下没拖动，也要把「当前在动哪个」画出来
            if (!near) {
                CGPoint np = [self clampViewPoint:p];
                if (_activeIsEnd) _end = np; else _start = np;
                [self pushGeometry];
            }
            return;
        }
        if (g.state != UIGestureRecognizerStateChanged) return;
        CGPoint np = [self clampViewPoint:CGPointMake(p.x + _grabOffset.x, p.y + _grabOffset.y)];
        if (_activeIsEnd) _end = np; else _start = np;
        [self pushGeometry];
        return;
    }

    // 点 / 取色：抓住就能按位移慢慢挪，点空白就直接落到手指那儿
    if (g.state == UIGestureRecognizerStateBegan) {
        BOOL near = (hypot(p.x - _crosshair.x, p.y - _crosshair.y) <= PK_GRAB_R);
        _grabOffset = near ? CGPointMake(_crosshair.x - p.x, _crosshair.y - p.y) : CGPointZero;
    } else if (g.state != UIGestureRecognizerStateChanged) {
        return;
    }
    _crosshair = [self clampViewPoint:CGPointMake(p.x + _grabOffset.x, p.y + _grabOffset.y)];
    [self pushGeometry];
}

// 轻点（手指没怎么动，pan 不会起手）：把选择器点到手指那儿
- (void)handleTap:(UITapGestureRecognizer *)g {
    if (_mode == FlowPickModeRect || _mode == FlowPickModeTemplate) return;
    CGPoint p = [g locationInView:_root];

    if (_mode == FlowPickModePath) {
        // 点在另一个选择器的圈里 = 切换当前在动哪个；点在别处 = 把当前这个挪过去
        BOOL nearStart = (hypot(p.x - _start.x, p.y - _start.y) <= PK_RING_R + 12);
        BOOL nearEnd = (hypot(p.x - _end.x, p.y - _end.y) <= PK_RING_R + 12);
        if (nearStart || nearEnd) {
            if (nearEnd) _activeIsEnd = YES;
            else _activeIsEnd = NO;
        } else {
            CGPoint np = [self clampViewPoint:p];
            if (_activeIsEnd) _end = np; else _start = np;
        }
        [self pushGeometry];
        return;
    }

    _crosshair = [self clampViewPoint:p];
    [self pushGeometry];
}

- (void)handlePanelPan:(UIPanGestureRecognizer *)g {
    CGPoint p = [g locationInView:_root];
    if (g.state == UIGestureRecognizerStateBegan) {
        _grabOffset = CGPointMake(_panelOrigin.x - p.x, _panelOrigin.y - p.y);
    } else if (g.state == UIGestureRecognizerStateChanged) {
        _panelOrigin = CGPointMake(p.x + _grabOffset.x, p.y + _grabOffset.y);
        [self layoutPanel];
    }
}

#pragma mark - 刷新画面 / 读数

- (void)pushGeometry {
    _canvas.crosshair = _crosshair;
    _canvas.startPoint = _start;
    _canvas.endPoint = _end;
    _canvas.activeIsEnd = _activeIsEnd;
    [self updateReadout];
}

- (void)updateReadout {
    BOOL rectMode = (_mode == FlowPickModeRect || _mode == FlowPickModeTemplate);
    if (rectMode) {
        if (!_hasRect) {
            _xLabel.text = @"在画面上拖一个框";
            _yLabel.text = @"";
            return;
        }
        CGRect ind = [self indicatorRectFromViewRect:_pickedRectView];
        _xLabel.text = [NSString stringWithFormat:@"左 %ld   上 %ld",
                        (long)llround(CGRectGetMinX(ind)), (long)llround(CGRectGetMinY(ind))];
        _yLabel.text = [NSString stringWithFormat:@"宽 %ld   高 %ld",
                        (long)llround(ind.size.width), (long)llround(ind.size.height)];
        return;
    }

    BOOL multi = (_mode == FlowPickModePath);
    CGPoint view = multi ? (_activeIsEnd ? _end : _start) : _crosshair;
    CGPoint ind = [self indicatorFromView:view];

    if (multi) {
        _tagLabel.text = _activeIsEnd ? @"终点" : @"起点";
        _tagLabel.textColor = _activeIsEnd ? [UIColor systemOrangeColor] : ZXPalette(ZXPalAccent);
    }
    // 取整之后再拿去取色 / 预览：显示的数和读到的那颗像素必须是同一颗
    CGPoint pixel = CGPointMake(llround(ind.x), llround(ind.y));
    _xLabel.text = [NSString stringWithFormat:@"X  %ld", (long)pixel.x];
    _yLabel.text = [NSString stringWithFormat:@"Y  %ld", (long)pixel.y];

    // 放大预览 / 颜色块都读冻帧，不读实时屏幕：画面冻住了，实时帧早就是别的内容了
    [_mag setCenterPoint:pixel];
    NSUInteger rgba = [self pixelAtIndicator:pixel];
    if (rgba == NSNotFound) {
        _swatch.backgroundColor = [UIColor clearColor];
        _hexLabel.text = @"----";
        return;
    }
    _swatch.backgroundColor = [UIColor colorWithRed:((rgba >> 16) & 0xFF) / 255.0
                                              green:((rgba >> 8) & 0xFF) / 255.0
                                               blue:(rgba & 0xFF) / 255.0 alpha:1];
    _hexLabel.text = [NSString stringWithFormat:@"#%06lX", (unsigned long)rgba];
}

// 冻帧上某颗像素的 0xRRGGBB
- (NSUInteger)pixelAtIndicator:(CGPoint)indicator {
    if (!_pixels) return NSNotFound;
    NSInteger x = (NSInteger)llround(indicator.x), y = (NSInteger)llround(indicator.y);
    if (x < 0 || y < 0 || x >= (NSInteger)_pixelW || y >= (NSInteger)_pixelH) return NSNotFound;
    const UInt8 *p = _pixels + (size_t)y * _pixelStride + (size_t)x * 4;
    return ((NSUInteger)p[2] << 16) | ((NSUInteger)p[1] << 8) | p[0];   // BGRA
}

- (CGRect)indicatorRectFromViewRect:(CGRect)viewRect {
    CGPoint a = [self indicatorFromView:CGPointMake(CGRectGetMinX(viewRect), CGRectGetMinY(viewRect))];
    CGPoint b = [self indicatorFromView:CGPointMake(CGRectGetMaxX(viewRect), CGRectGetMaxY(viewRect))];
    return CGRectMake(MIN(a.x, b.x), MIN(a.y, b.y), fabs(b.x - a.x), fabs(b.y - a.y));
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
    if (!_shownFrame) _shownFrame = raw;

    free(_pixels);
    _pixels = PKCopyPixels(_shownFrame, &_pixelW, &_pixelH, &_pixelStride);
    if (!_pixels) return NO;

    _freezeView.image = _shownFrame;
    [_mag setSourceImage:_shownFrame.CGImage];
    return YES;
}

// 取一份 BGRA 像素副本：冻了屏之后取色 / 放大预览都得读这张不变的图
static UInt8 *PKCopyPixels(UIImage *image, size_t *outW, size_t *outH, size_t *outStride)
{
    CGImageRef cg = image.CGImage;
    if (!cg) return NULL;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w == 0 || h == 0) return NULL;

    size_t stride = w * 4;
    UInt8 *buf = malloc(h * stride);
    if (!buf) return NULL;

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, stride, space,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    if (!ctx) {
        free(buf);
        return NULL;
    }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    CGContextRelease(ctx);

    *outW = w;
    *outH = h;
    *outStride = stride;
    return buf;
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

// 重截：先把窗口隐掉再抓，否则自己的面板会被截进画面
- (void)recaptureTapped {
    [_up stop]; [_down stop]; [_left stop]; [_right stop];
    _window.alpha = 0;
    ZXSafeMainAsync(^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!self->_window) return;
            [self captureFreezeFrame];
            [self updateImageFrame];
            [self pushGeometry];
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
    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    if (_mode == FlowPickModeRect || _mode == FlowPickModeTemplate) {
        if (!_hasRect) {
            showAlertBox(@"提示", @"请先在画面上拖一个框。", 2);
            return;
        }
        NSInteger left = (NSInteger)llround([self indicatorFromView:_rectStart].x);
        NSInteger top = (NSInteger)llround([self indicatorFromView:_rectStart].y);
        NSInteger right = (NSInteger)llround([self indicatorFromView:_rectEnd].x);
        NSInteger bottom = (NSInteger)llround([self indicatorFromView:_rectEnd].y);
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
        CGPoint a = [self indicatorFromView:(_mode == FlowPickModePath ? _start : _crosshair)];
        CGPoint b = [self indicatorFromView:(_mode == FlowPickModePath ? _end : _crosshair)];
        CGPoint pa = CGPointMake(llround(a.x), llround(a.y));
        CGPoint pb = CGPointMake(llround(b.x), llround(b.y));
        result[kPickStart] = [NSValue valueWithCGPoint:pa];
        result[kPickEnd] = [NSValue valueWithCGPoint:pb];
        result[kPickRect] = [NSValue valueWithCGRect:CGRectMake(MIN(pa.x, pb.x), MIN(pa.y, pb.y),
                                                               fabs(pb.x - pa.x), fabs(pb.y - pa.y))];
        if (_mode == FlowPickModeColor) {
            NSUInteger rgba = [self pixelAtIndicator:pa];
            result[kPickHex] = (rgba == NSNotFound) ? @"" : [NSString stringWithFormat:@"%06lX", (unsigned long)rgba];
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
    [_up stop]; [_down stop]; [_left stop]; [_right stop];
    [_root endEditing:YES];
    _window.hidden = YES;
    _window.rootViewController = nil;
    for (UIView *v in [_root.subviews copy]) [v removeFromSuperview];
    _window = nil;
    _root = nil;
    _canvas = nil;
    _freezeView = nil;
    _catcher = nil;
    _panel = nil;
    _header = nil;
    _tagLabel = nil;
    _xLabel = nil;
    _yLabel = nil;
    _swatch = nil;
    _hexLabel = nil;
    [_mag setSourceImage:NULL];
    _mag = nil;
    _up = _down = _left = _right = nil;
    _confirmBtn = _cancelBtn = _recaptureBtn = nil;
    _rawFrame = nil;
    _shownFrame = nil;
    _imageFrame = CGRectZero;
    free(_pixels);
    _pixels = NULL;
    _pixelW = _pixelH = _pixelStride = 0;
    _panelOrigin = CGPointZero;
    _completion = nil;
    _cancelHandler = nil;
}

@end
