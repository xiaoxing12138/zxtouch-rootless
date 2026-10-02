//
//  ScreenPickerViewController.m
//  小新Lap 可视化脚本
//

#import "ScreenPickerViewController.h"
#import "Socket.h"

#import <math.h>

// 引擎任务号：回传「未转正的原始竖屏帧 JPEG + 当前方向」
static const NSInteger kTaskScreenshotRaw = 43;

#pragma mark - 覆盖层（十字线 / 框选矩形）

@interface ZXPickerOverlayView : UIView
@property (nonatomic) CGPoint point;   // 视图坐标下的十字线中心
@property (nonatomic) CGRect rect;     // 视图坐标下的框
@property (nonatomic) BOOL showsRect;
@end

@implementation ZXPickerOverlayView

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;
    }
    return self;
}

- (void)drawRect:(CGRect)bounds
{
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetLineWidth(ctx, 1.0);

    if (self.showsRect) {
        CGRect rect = self.rect;
        if (rect.size.width < 1 || rect.size.height < 1) return;

        // 框外用半透明黑压暗、框内保持原色，一眼能看出选了什么
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0 alpha:0.55].CGColor);
        CGContextAddRect(ctx, bounds);
        CGContextAddRect(ctx, rect);
        CGContextEOFillPath(ctx);

        CGContextSetStrokeColorWithColor(ctx, UIColor.systemYellowColor.CGColor);
        CGContextSetLineWidth(ctx, 2.0);
        CGContextStrokeRect(ctx, rect);
        return;
    }

    CGContextSetStrokeColorWithColor(ctx, UIColor.systemYellowColor.CGColor);
    CGContextMoveToPoint(ctx, 0, self.point.y);
    CGContextAddLineToPoint(ctx, bounds.size.width, self.point.y);
    CGContextMoveToPoint(ctx, self.point.x, 0);
    CGContextAddLineToPoint(ctx, self.point.x, bounds.size.height);
    CGContextStrokePath(ctx);

    CGContextSetLineWidth(ctx, 2.0);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(self.point.x - 12, self.point.y - 12, 24, 24));
    CGContextMoveToPoint(ctx, self.point.x - 22, self.point.y);
    CGContextAddLineToPoint(ctx, self.point.x + 22, self.point.y);
    CGContextMoveToPoint(ctx, self.point.x, self.point.y - 22);
    CGContextAddLineToPoint(ctx, self.point.x, self.point.y + 22);
    CGContextStrokePath(ctx);
}

- (void)setPoint:(CGPoint)point { _point = point; [self setNeedsDisplay]; }
- (void)setRect:(CGRect)rect { _rect = rect; [self setNeedsDisplay]; }
- (void)setShowsRect:(BOOL)showsRect { _showsRect = showsRect; [self setNeedsDisplay]; }

@end

#pragma mark - 取点

@interface ScreenPickerViewController () <UIGestureRecognizerDelegate>

@property (nonatomic) FlowPickMode mode;
@property (nonatomic, copy, nullable) NSString *suggestedTemplate;
@property (nonatomic, copy) void (^completion)(CGRect, NSString *, NSString *);

@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) ZXPickerOverlayView *overlay;
@property (nonatomic, strong) UILabel *infoLabel;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;

@property (nonatomic, strong, nullable) UIImage *rawImage;   // 原始竖屏帧
@property (nonatomic, strong, nullable) UIImage *shownImage; // 转正后的显示图
@property (nonatomic) CGRect imageFrame;                     // 显示图在 imageView 里占的实际范围
@property (nonatomic) CGSize indicatorSize;                  // 当前方向的像素尺寸
@property (nonatomic) NSInteger displayOrientation;          // 1/2/3/4

// 选中状态一律以「指示器坐标」为准，视图坐标每次重算，避免旋转/布局后错位
@property (nonatomic) CGPoint pickedIndicator;
@property (nonatomic) CGRect pickedIndicatorRect;
@property (nonatomic) BOOL hasPicked;
@property (nonatomic) CGPoint dragStart;   // 框选起点（视图坐标）

@end

@implementation ScreenPickerViewController

- (instancetype)initWithMode:(FlowPickMode)mode
           suggestedTemplate:(NSString *)templateName
                  completion:(void (^)(CGRect, NSString *, NSString *))completion
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _mode = mode;
        _suggestedTemplate = [templateName copy];
        _completion = [completion copy];
        _displayOrientation = 1;
    }
    return self;
}

- (BOOL)prefersStatusBarHidden { return YES; }

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    self.imageView = [[UIImageView alloc] initWithFrame:CGRectZero];
    self.imageView.contentMode = UIViewContentModeScaleAspectFit;
    self.imageView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.imageView];

    self.overlay = [[ZXPickerOverlayView alloc] initWithFrame:CGRectZero];
    self.overlay.translatesAutoresizingMaskIntoConstraints = NO;
    self.overlay.showsRect = (self.mode == FlowPickModeRect || self.mode == FlowPickModeTemplate);
    [self.view addSubview:self.overlay];

    UIButton *cancel = [self barButton:@"取消" action:@selector(cancelTapped)];
    UIButton *refresh = [self barButton:@"重新截图" action:@selector(refreshTapped)];
    UIButton *confirm = [self barButton:@"确定" action:@selector(confirmTapped)];
    confirm.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];

    UIView *topBar = [[UIView alloc] initWithFrame:CGRectZero];
    topBar.translatesAutoresizingMaskIntoConstraints = NO;
    topBar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    for (UIButton *button in @[cancel, refresh, confirm]) [topBar addSubview:button];
    [self.view addSubview:topBar];

    self.hintLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.hintLabel.textColor = UIColor.whiteColor;
    self.hintLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.hintLabel.textAlignment = NSTextAlignmentCenter;
    self.hintLabel.numberOfLines = 2;
    [self.view addSubview:self.hintLabel];

    self.infoLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.infoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.infoLabel.textColor = UIColor.systemYellowColor;
    self.infoLabel.font = [UIFont monospacedSystemFontOfSize:16 weight:UIFontWeightSemibold];
    self.infoLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.infoLabel];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.color = UIColor.whiteColor;
    [self.spinner startAnimating];
    [self.view addSubview:self.spinner];

    for (UIView *view in @[self.imageView, self.overlay, topBar, self.hintLabel, self.infoLabel]) {
        [view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor].active = YES;
        [view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor].active = YES;
    }
    [NSLayoutConstraint activateConstraints:@[
        [topBar.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [topBar.heightAnchor constraintEqualToConstant:52],
        [self.hintLabel.topAnchor constraintEqualToAnchor:topBar.bottomAnchor constant:8],
        [self.imageView.topAnchor constraintEqualToAnchor:self.hintLabel.bottomAnchor constant:8],
        [self.imageView.bottomAnchor constraintEqualToAnchor:self.infoLabel.topAnchor constant:-8],
        [self.overlay.topAnchor constraintEqualToAnchor:self.imageView.topAnchor],
        [self.overlay.bottomAnchor constraintEqualToAnchor:self.imageView.bottomAnchor],
        [self.infoLabel.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8],
        [self.infoLabel.heightAnchor constraintEqualToConstant:24],
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [cancel.leadingAnchor constraintEqualToAnchor:topBar.leadingAnchor constant:16],
        [cancel.centerYAnchor constraintEqualToAnchor:topBar.centerYAnchor constant:8],
        [refresh.centerXAnchor constraintEqualToAnchor:topBar.centerXAnchor],
        [refresh.centerYAnchor constraintEqualToAnchor:topBar.centerYAnchor constant:8],
        [confirm.trailingAnchor constraintEqualToAnchor:topBar.trailingAnchor constant:-16],
        [confirm.centerYAnchor constraintEqualToAnchor:topBar.centerYAnchor constant:8],
    ]];

    [self updateHint];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    [self.view addGestureRecognizer:tap];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    pan.delegate = self;
    [self.view addGestureRecognizer:pan];

    [self fetchScreenshot];
}

- (UIButton *)barButton:(NSString *)title action:(SEL)action
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:17];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)updateHint
{
    switch (self.mode) {
        case FlowPickModePoint:
            self.hintLabel.text = @"在图上点一下要点的位置";
            break;
        case FlowPickModeColor:
            self.hintLabel.text = @"在图上点一下要判断的位置，颜色会一起取走";
            break;
        case FlowPickModeRect:
            self.hintLabel.text = @"在图上拖一个框，圈出要查找的区域";
            break;
        case FlowPickModeTemplate:
            self.hintLabel.text = @"在图上拖一个框，框住要识别的图标或按钮\n框得越紧越准，别把会动的背景框进去";
            break;
        default:
            self.hintLabel.text = @"";
            break;
    }
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    [self updateImageFrame];
}

#pragma mark - 截图

- (void)refreshTapped
{
    [self fetchScreenshot];
}

- (void)fetchScreenshot
{
    self.hasPicked = NO;
    self.pickedIndicator = CGPointZero;
    self.pickedIndicatorRect = CGRectZero;
    self.overlay.rect = CGRectZero;
    [self updateInfoLabel];
    self.overlay.hidden = YES;
    self.spinner.hidden = NO;
    [self.spinner startAnimating];
    self.infoLabel.text = @"正在截图…";

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSDictionary *result = [self captureRawFrameWithError:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            self.spinner.hidden = YES;
            if (!result) {
                self.infoLabel.text = @"";
                [self showError:error.localizedDescription ?: @"截图失败。"];
                return;
            }
            self.rawImage = result[@"image"];
            [self applyRotationForOrientation:[result[@"orientation"] integerValue]];
            [self updateImageFrame];
            self.overlay.hidden = NO;
            [self updateInfoLabel];
        });
    });
}

- (nullable NSDictionary *)captureRawFrameWithError:(NSError **)error
{
    Socket *socket = [[Socket alloc] init];
    if ([socket connect:@"127.0.0.1" byPort:6000] != 0) {
        if (error) *error = [self error:@"小新Lap 服务不可用，请确认插件已生效。"];
        return nil;
    }

    [socket send:[NSString stringWithFormat:@"%ld\r\n", (long)kTaskScreenshotRaw]];
    NSString *header = [socket recvLine];
    if (header.length == 0) {
        [socket close];
        if (error) *error = [self error:@"引擎没有响应截图请求。"];
        return nil;
    }

    NSArray<NSString *> *fields = [[header stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]
                                   componentsSeparatedByString:@";;"];
    if (fields.count < 4 || ![fields[0] isEqualToString:@"0"]) {
        NSString *message = fields.count >= 2 ? fields[1] : @"截图失败";
        [socket close];
        if (error) *error = [self error:message];
        return nil;
    }

    NSInteger length = [fields[2] integerValue];
    NSInteger orientation = [fields[3] integerValue];
    NSData *data = [socket recvData:length];
    [socket close];

    UIImage *image = data.length ? [UIImage imageWithData:data] : nil;
    if (!image) {
        if (error) *error = [self error:@"收到的截图数据不完整。"];
        return nil;
    }
    return @{ @"image": image, @"orientation": @(orientation) };
}

- (NSError *)error:(NSString *)message
{
    return [NSError errorWithDomain:@"小新Lap" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - 转正

/*
 引擎回传的帧永远是「竖屏物理像素」那张（宽 = 短边 w，高 = 长边 h）。
 转成用户眼里的样子，用的是和触摸换算完全同一套几何关系：

   方向 1（竖屏）   帧 = (显示x, 显示y)
   方向 2（倒竖屏） 帧 = (w - 显示x, h - 显示y)   → 图转 180°
   方向 3（横屏右） 帧 = (w - 显示y, 显示x)       → 图转 90° 逆时针
   方向 4（横屏左） 帧 = (显示y, h - 显示x)       → 图转 90° 顺时针

 转好之后，图上任意一点的像素坐标正好等于「触摸指示器」坐标 —— 用户点哪儿，脚本就写哪儿。
*/
- (void)applyRotationForOrientation:(NSInteger)orientation
{
    UIImage *raw = self.rawImage;
    if (!raw) return;

    if (orientation < 1 || orientation > 4) orientation = 1;
    self.displayOrientation = orientation;

    CGSize size = raw.size; // JPEG 解出来 scale = 1，size 就是像素尺寸
    if (orientation == 1) {
        self.shownImage = raw;
        self.indicatorSize = size;
        self.imageView.image = raw;
        return;
    }

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

    self.shownImage = result ?: raw;
    self.indicatorSize = self.shownImage.size;
    self.imageView.image = self.shownImage;
}

- (void)updateImageFrame
{
    UIImage *image = self.shownImage;
    CGRect bounds = self.imageView.bounds;
    if (!image || image.size.width <= 0 || image.size.height <= 0 ||
        bounds.size.width <= 0 || bounds.size.height <= 0) {
        self.imageFrame = CGRectZero;
        return;
    }
    CGFloat scale = MIN(bounds.size.width / image.size.width, bounds.size.height / image.size.height);
    CGSize fitted = CGSizeMake(image.size.width * scale, image.size.height * scale);
    self.imageFrame = CGRectMake(CGRectGetMidX(bounds) - fitted.width / 2.0,
                                 CGRectGetMidY(bounds) - fitted.height / 2.0,
                                 fitted.width, fitted.height);

    // overlay 与 imageView 同框，imageFrame 可直接当视图坐标用
    [self refreshOverlay];
}

- (void)refreshOverlay
{
    if (!self.hasPicked) {
        // 还没选就什么都不画：十字线默认停在 (0,0)，会挂在图上左上角像根毛刺
        self.overlay.point = CGPointMake(-1000, -1000);
        self.overlay.rect = CGRectZero;
        return;
    }
    self.overlay.point = [self viewPointFromIndicator:self.pickedIndicator];
    self.overlay.rect = [self viewRectFromIndicator:self.pickedIndicatorRect];
}

#pragma mark - 坐标互转

/// 屏幕上的点（self.view 坐标）→ 指示器坐标
- (CGPoint)indicatorPointFromViewPoint:(CGPoint)viewPoint
{
    if (self.imageFrame.size.width <= 0 || self.imageFrame.size.height <= 0) return CGPointZero;
    CGPoint local = [self.view convertPoint:viewPoint toView:self.imageView];
    CGFloat x = (local.x - self.imageFrame.origin.x) / self.imageFrame.size.width * self.indicatorSize.width;
    CGFloat y = (local.y - self.imageFrame.origin.y) / self.imageFrame.size.height * self.indicatorSize.height;
    return CGPointMake(x, y);
}

/// 指示器坐标 → 屏幕上的点
- (CGPoint)viewPointFromIndicator:(CGPoint)indicator
{
    if (self.indicatorSize.width <= 0 || self.indicatorSize.height <= 0) return CGPointZero;
    CGPoint inImageView = CGPointMake(self.imageFrame.origin.x +
                                      indicator.x / self.indicatorSize.width * self.imageFrame.size.width,
                                      self.imageFrame.origin.y +
                                      indicator.y / self.indicatorSize.height * self.imageFrame.size.height);
    return [self.imageView convertPoint:inImageView toView:self.view];
}

/// 屏幕坐标下的矩形 → 指示器坐标下的矩形（顺便夹进屏幕内）
- (CGRect)indicatorRectFromViewRect:(CGRect)viewRect
{
    CGPoint a = [self indicatorPointFromViewPoint:CGPointMake(CGRectGetMinX(viewRect), CGRectGetMinY(viewRect))];
    CGPoint b = [self indicatorPointFromViewPoint:CGPointMake(CGRectGetMaxX(viewRect), CGRectGetMaxY(viewRect))];
    CGFloat maxX = self.indicatorSize.width, maxY = self.indicatorSize.height;
    CGFloat x0 = MAX(0, MIN(maxX, MIN(a.x, b.x)));
    CGFloat y0 = MAX(0, MIN(maxY, MIN(a.y, b.y)));
    CGFloat x1 = MAX(0, MIN(maxX, MAX(a.x, b.x)));
    CGFloat y1 = MAX(0, MIN(maxY, MAX(a.y, b.y)));
    return CGRectMake(x0, y0, x1 - x0, y1 - y0);
}

- (CGRect)viewRectFromIndicator:(CGRect)rect
{
    if (rect.size.width <= 0 || rect.size.height <= 0) return CGRectZero;
    CGPoint a = [self viewPointFromIndicator:CGPointMake(CGRectGetMinX(rect), CGRectGetMinY(rect))];
    CGPoint b = [self viewPointFromIndicator:CGPointMake(CGRectGetMaxX(rect), CGRectGetMaxY(rect))];
    return CGRectMake(MIN(a.x, b.x), MIN(a.y, b.y), fabs(b.x - a.x), fabs(b.y - a.y));
}

/// 指示器坐标 → 原始竖屏帧像素坐标
- (CGPoint)framePointFromIndicatorPoint:(CGPoint)point shortSide:(CGFloat)w longSide:(CGFloat)h
{
    switch (self.displayOrientation) {
        case 2: return CGPointMake(w - point.x, h - point.y);
        case 3: return CGPointMake(w - point.y, point.x);
        case 4: return CGPointMake(point.y, h - point.x);
        default: return point;
    }
}

#pragma mark - 手势

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch
{
    return ![touch.view isKindOfClass:[UIButton class]];   // 顶栏按钮优先
}

- (void)handleTap:(UITapGestureRecognizer *)gesture
{
    if (!self.shownImage) return;
    if (self.mode == FlowPickModeRect || self.mode == FlowPickModeTemplate) return;
    if (self.imageFrame.size.width <= 0) return;

    CGPoint point = [gesture locationInView:self.view];
    if (!CGRectContainsPoint(self.imageFrame, [self.view convertPoint:point toView:self.imageView])) return;

    self.pickedIndicator = [self indicatorPointFromViewPoint:point];
    self.hasPicked = YES;
    self.overlay.point = point;
    [self updateInfoLabel];
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture
{
    if (!self.shownImage) return;
    if (self.mode != FlowPickModeRect && self.mode != FlowPickModeTemplate) return;

    CGPoint point = [gesture locationInView:self.view];

    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.dragStart = point;
        self.pickedIndicatorRect = CGRectZero;
    }

    if (gesture.state == UIGestureRecognizerStateBegan || gesture.state == UIGestureRecognizerStateChanged) {
        CGRect viewRect = CGRectMake(MIN(self.dragStart.x, point.x), MIN(self.dragStart.y, point.y),
                                     fabs(point.x - self.dragStart.x), fabs(point.y - self.dragStart.y));
        self.pickedIndicatorRect = [self indicatorRectFromViewRect:viewRect];
        self.hasPicked = (viewRect.size.width >= 8 && viewRect.size.height >= 8);
        [self refreshOverlay];
    } else if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
        if (!self.hasPicked) self.pickedIndicatorRect = CGRectZero;
        [self refreshOverlay];
    }
    [self updateInfoLabel];
}

- (void)updateInfoLabel
{
    if (self.mode == FlowPickModeRect || self.mode == FlowPickModeTemplate) {
        if (!self.hasPicked) {
            self.infoLabel.text = @"还没框选";
            return;
        }
        CGRect rect = self.pickedIndicatorRect;
        self.infoLabel.text = [NSString stringWithFormat:@"区域 (%ld, %ld)  宽 %ld 高 %ld",
                               (long)llround(CGRectGetMinX(rect)), (long)llround(CGRectGetMinY(rect)),
                               (long)llround(rect.size.width), (long)llround(rect.size.height)];
        return;
    }

    if (!self.hasPicked) {
        self.infoLabel.text = @"还没选点";
        return;
    }

    NSString *text = [NSString stringWithFormat:@"坐标 %ld, %ld",
                      (long)llround(self.pickedIndicator.x), (long)llround(self.pickedIndicator.y)];
    if (self.mode == FlowPickModeColor) {
        NSString *hex = [self hexColorAtIndicatorPoint:self.pickedIndicator];
        text = [text stringByAppendingFormat:@"   颜色 #%@", hex ?: @"----"];
    }
    self.infoLabel.text = text;
}

#pragma mark - 读像素颜色

/// 从**原始竖屏帧**读颜色，避开转正重采样带来的偏差
- (nullable NSString *)hexColorAtIndicatorPoint:(CGPoint)indicator
{
    UIImage *raw = self.rawImage;
    if (!raw || raw.size.width <= 0 || raw.size.height <= 0) return nil;

    CGFloat w = MIN(raw.size.width, raw.size.height);   // 短边
    CGFloat h = MAX(raw.size.width, raw.size.height);   // 长边
    CGPoint frame = [self framePointFromIndicatorPoint:indicator shortSide:w longSide:h];

    NSInteger px = MAX(0, MIN((NSInteger)raw.size.width - 1, (NSInteger)llround(frame.x)));
    NSInteger py = MAX(0, MIN((NSInteger)raw.size.height - 1, (NSInteger)llround(frame.y)));

    CGImageRef cgImage = raw.CGImage;
    if (!cgImage) return nil;
    CGImageRef pixel = CGImageCreateWithImageInRect(cgImage, CGRectMake(px, py, 1, 1));
    if (!pixel) return nil;

    unsigned char bytes[4] = {0, 0, 0, 0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(bytes, 1, 1, 8, 4, space,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!ctx) {
        CGImageRelease(pixel);
        return nil;
    }
    CGContextDrawImage(ctx, CGRectMake(0, 0, 1, 1), pixel);
    CGContextRelease(ctx);
    CGImageRelease(pixel);

    return [NSString stringWithFormat:@"%02X%02X%02X", bytes[0], bytes[1], bytes[2]];
}

#pragma mark - 完成

- (void)cancelTapped
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)confirmTapped
{
    if (!self.shownImage) return;

    CGRect result = CGRectZero;
    NSString *hex = nil;
    NSString *template = nil;

    if (self.mode == FlowPickModeRect || self.mode == FlowPickModeTemplate) {
        if (!self.hasPicked) {
            [self showError:@"请先在图上拖一个框。"];
            return;
        }
        CGRect rect = self.pickedIndicatorRect;
        if (rect.size.width < 2 || rect.size.height < 2) {
            [self showError:@"框太小了，请重新框选。"];
            return;
        }
        if (self.mode == FlowPickModeTemplate) {
            template = [self saveTemplateFromCurrentRect];
            if (!template) {
                [self showError:@"模板保存失败，请重试。"];
                return;
            }
        }
        result = CGRectMake(llround(CGRectGetMinX(rect)), llround(CGRectGetMinY(rect)),
                            llround(rect.size.width), llround(rect.size.height));
    } else {
        if (!self.hasPicked) {
            [self showError:@"请先在图上点一下位置。"];
            return;
        }
        CGPoint point = self.pickedIndicator;
        if (self.mode == FlowPickModeColor) hex = [self hexColorAtIndicatorPoint:point];
        result = CGRectMake(llround(point.x), llround(point.y), 1, 1);
    }

    // 必须等本页完全关掉再回调：回调里要弹「改参数」的窗，本页还在就会被顶掉
    void (^completion)(CGRect, NSString *, NSString *) = self.completion;
    [self dismissViewControllerAnimated:YES completion:^{
        if (completion) completion(result, hex, template);
    }];
}

#pragma mark - 模板存盘

/*
 显示图上的框 → 原始帧上的矩形 → 从原始帧抠图存 PNG。
 引擎永远拿竖屏原始帧做匹配，模板也必须是原帧里的样子。
*/
- (nullable NSString *)saveTemplateFromCurrentRect
{
    UIImage *raw = self.rawImage;
    if (!raw) return nil;

    CGFloat w = MIN(raw.size.width, raw.size.height);
    CGFloat h = MAX(raw.size.width, raw.size.height);
    CGRect displayRect = self.pickedIndicatorRect;

    // 四个角各自映射到帧坐标，再取外接矩形：90° / 180° 旋转下框仍是轴对齐的
    CGPoint corners[4] = {
        CGPointMake(CGRectGetMinX(displayRect), CGRectGetMinY(displayRect)),
        CGPointMake(CGRectGetMaxX(displayRect), CGRectGetMinY(displayRect)),
        CGPointMake(CGRectGetMinX(displayRect), CGRectGetMaxY(displayRect)),
        CGPointMake(CGRectGetMaxX(displayRect), CGRectGetMaxY(displayRect)),
    };
    CGFloat minX = CGFLOAT_MAX, minY = CGFLOAT_MAX, maxX = -CGFLOAT_MAX, maxY = -CGFLOAT_MAX;
    for (int i = 0; i < 4; i++) {
        CGPoint frame = [self framePointFromIndicatorPoint:corners[i] shortSide:w longSide:h];
        minX = MIN(minX, frame.x); maxX = MAX(maxX, frame.x);
        minY = MIN(minY, frame.y); maxY = MAX(maxY, frame.y);
    }

    NSInteger fx = (NSInteger)floor(minX);
    NSInteger fy = (NSInteger)floor(minY);
    NSInteger fw = (NSInteger)ceil(maxX - minX);
    NSInteger fh = (NSInteger)ceil(maxY - minY);
    fx = MAX(0, MIN((NSInteger)raw.size.width - 1, fx));
    fy = MAX(0, MIN((NSInteger)raw.size.height - 1, fy));
    fw = MAX(1, MIN((NSInteger)raw.size.width - fx, fw));
    fh = MAX(1, MIN((NSInteger)raw.size.height - fy, fh));

    CGImageRef cgImage = raw.CGImage;
    if (!cgImage) return nil;
    CGImageRef cropped = CGImageCreateWithImageInRect(cgImage, CGRectMake(fx, fy, fw, fh));
    if (!cropped) return nil;

    UIImage *template = [UIImage imageWithCGImage:cropped scale:1.0 orientation:UIImageOrientationUp];
    CGImageRelease(cropped);
    NSData *png = UIImagePNGRepresentation(template);
    if (!png) return nil;

    NSFileManager *manager = [NSFileManager defaultManager];
    if (![manager fileExistsAtPath:kFlowTemplateFolder]) {
        [manager createDirectoryAtPath:kFlowTemplateFolder withIntermediateDirectories:YES attributes:nil error:NULL];
    }

    NSString *name = self.suggestedTemplate;
    if (name.length == 0) name = [self nextAvailableTemplateName];
    NSString *path = [kFlowTemplateFolder stringByAppendingPathComponent:name];
    if (![png writeToFile:path atomically:YES]) return nil;
    return name;
}

- (NSString *)nextAvailableTemplateName
{
    NSFileManager *manager = [NSFileManager defaultManager];
    for (NSInteger index = 1; index < 1000; index++) {
        NSString *name = [NSString stringWithFormat:@"tpl%ld.png", (long)index];
        if (![manager fileExistsAtPath:[kFlowTemplateFolder stringByAppendingPathComponent:name]]) return name;
    }
    return [NSString stringWithFormat:@"tpl%u.png", arc4random_uniform(100000)];
}

#pragma mark - 提示

- (void)showError:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"取坐标"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
