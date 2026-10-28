#import "ZXImageCropViewController.h"

@implementation ZXImageCropViewController
{
    UIView *_stage;
    UIImageView *_imageView;
    UILabel *_hint;
    UIButton *_cancelBtn;
    UIButton *_doneBtn;
    CGFloat _baseScale;
    CGFloat _zoom;
    CGPoint _offset;
    CGSize _stageSize;
    BOOL _ready;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _canvasAspect = 1.0f;
        _outputMaxSide = 512.0f;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];

    _stage = [[UIView alloc] init];
    _stage.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1];
    _stage.clipsToBounds = YES;
    [self.view addSubview:_stage];

    _imageView = [[UIImageView alloc] init];
    _imageView.image = self.sourceImage;
    _imageView.userInteractionEnabled = NO;
    [_stage addSubview:_imageView];

    [_stage addGestureRecognizer:[[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinch:)]];
    [_stage addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)]];

    _hint = [[UILabel alloc] init];
    _hint.numberOfLines = 2;
    _hint.textAlignment = NSTextAlignmentCenter;
    _hint.font = [UIFont systemFontOfSize:13];
    _hint.textColor = [UIColor whiteColor];
    _hint.text = self.hintText.length ? self.hintText : @"双指缩放，单指拖动";
    [self.view addSubview:_hint];

    _cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_cancelBtn setTitle:@"取消" forState:UIControlStateNormal];
    [_cancelBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _cancelBtn.titleLabel.font = [UIFont systemFontOfSize:16];
    _cancelBtn.backgroundColor = [UIColor colorWithWhite:0.3 alpha:1];
    _cancelBtn.layer.cornerRadius = 10;
    [_cancelBtn addTarget:self action:@selector(handleCancel) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_cancelBtn];

    _doneBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_doneBtn setTitle:@"完成" forState:UIControlStateNormal];
    [_doneBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _doneBtn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _doneBtn.backgroundColor = [UIColor colorWithRed:0 green:0.48 blue:1 alpha:1];
    _doneBtn.layer.cornerRadius = 10;
    [_doneBtn addTarget:self action:@selector(handleDone) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_doneBtn];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    CGFloat availW = MAX(w - 48.0f, 80.0f);
    CGFloat availH = MAX(h - 220.0f, 80.0f);

    CGFloat sw = availW;
    CGFloat sh = availH;
    if (self.circleMask) {
        sw = sh = MIN(availW, availH);
    } else {
        CGFloat aspect = (self.canvasAspect > 0.05f) ? self.canvasAspect : 1.0f;
        sh = MIN(availH, availW / aspect);
        sw = sh * aspect;
    }

    BOOL resized = !CGSizeEqualToSize(_stageSize, CGSizeMake(sw, sh));
    _stageSize = CGSizeMake(sw, sh);
    _stage.frame = CGRectMake((w - sw) / 2.0f, (h - sh) / 2.0f - 24.0f, sw, sh);
    _stage.layer.cornerRadius = self.circleMask ? sw / 2.0f : 10.0f;
    _hint.frame = CGRectMake(20, CGRectGetMinY(_stage.frame) - 52.0f, w - 40, 44);
    _cancelBtn.frame = CGRectMake(w / 2.0f - 110.0f, CGRectGetMaxY(_stage.frame) + 24.0f, 100, 44);
    _doneBtn.frame = CGRectMake(w / 2.0f + 10.0f, CGRectGetMaxY(_stage.frame) + 24.0f, 100, 44);

    CGSize img = self.sourceImage.size;
    if (!_ready && img.width > 0 && img.height > 0) {
        _ready = YES;
        _zoom = 1.0f;
        _offset = CGPointZero;
        _baseScale = MAX(sw / img.width, sh / img.height);
    } else if (resized && _ready) {
        _baseScale = MAX(sw / MAX(img.width, 1.0f), sh / MAX(img.height, 1.0f));
    }
    [self applyFrame];
}

- (void)applyFrame
{
    if (!_ready) return;
    CGSize img = self.sourceImage.size;
    CGFloat dw = img.width * _baseScale * _zoom;
    CGFloat dh = img.height * _baseScale * _zoom;
    CGFloat maxX = MAX(0.0f, (dw - _stageSize.width) / 2.0f);
    CGFloat maxY = MAX(0.0f, (dh - _stageSize.height) / 2.0f);
    _offset.x = MIN(MAX(_offset.x, -maxX), maxX);
    _offset.y = MIN(MAX(_offset.y, -maxY), maxY);
    _imageView.frame = CGRectMake((_stageSize.width - dw) / 2.0f + _offset.x,
                                  (_stageSize.height - dh) / 2.0f + _offset.y, dw, dh);
}

- (void)handlePinch:(UIPinchGestureRecognizer *)g
{
    if (!_ready) return;
    if (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged) {
        CGFloat next = _zoom * g.scale;
        _zoom = MIN(MAX(next, 1.0f), 8.0f);
        g.scale = 1.0f;
        [self applyFrame];
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)g
{
    if (!_ready) return;
    if (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:_stage];
        _offset.x += t.x;
        _offset.y += t.y;
        [g setTranslation:CGPointZero inView:_stage];
        [self applyFrame];
    }
}

- (UIImage *)renderCroppedImage
{
    if (!_ready || _stageSize.width <= 0 || _stageSize.height <= 0) return self.sourceImage;
    CGFloat maxSide = self.outputMaxSide > 0 ? self.outputMaxSide : 512.0f;
    CGSize out;
    if (self.circleMask) {
        out = CGSizeMake(maxSide, maxSide);
    } else {
        CGFloat scale = maxSide / MAX(_stageSize.width, _stageSize.height);
        out = CGSizeMake(floor(_stageSize.width * scale), floor(_stageSize.height * scale));
    }
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:out];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGContextScaleCTM(c, out.width / self->_stageSize.width, out.height / self->_stageSize.height);
        if (self.circleMask) {
            UIBezierPath *circle = [UIBezierPath bezierPathWithOvalInRect:
                                    CGRectMake(0, 0, self->_stageSize.width, self->_stageSize.height)];
            [circle addClip];
        }
        [self->_imageView.image drawInRect:self->_imageView.frame];
    }];
}

- (void)handleCancel
{
    [self dismissViewControllerAnimated:YES completion:^{
        if (self.onCancel) self.onCancel();
    }];
}

- (void)handleDone
{
    UIImage *out = [self renderCroppedImage];
    [self dismissViewControllerAnimated:YES completion:^{
        if (self.onFinish) self.onFinish(out);
    }];
}

@end
