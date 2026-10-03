//
//  FlowWindow.xm
//  小新Lap 可视化脚本编辑器（悬浮卡片）
//

#import "FlowWindow.h"
#import "FloatingMenu.h"      // FMPassthroughWindow / preferredWindowScene
#import "Common.h"            // ZXSafeMainAsync
#import "FlowScript.h"
#import "PickOverlay.h"
#import "AlertBox.h"

#define FW_TOP_H   49.0f
#define FW_CARD_W  560.0f
#define FW_ROW_H   46.0f
#define FW_GAP     6.0f
#define FW_DELETE_W 80.0f   // 左滑露出来的「删除」宽度

// 页面种类
static NSString * const kPageList    = @"list";     // 步骤列表（整条流程 / 成立时 / 不成立时）
static NSString * const kPageTypes   = @"types";    // 「添加步骤」的候选类型
static NSString * const kPageParams  = @"params";   // 某一步的参数
static NSString * const kPagePreview = @"preview";  // 生成出来的 Python 源码

@interface FWRootView : UIView
@end

@implementation FWRootView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;   // 卡片外面穿给下面的游戏
}
@end

@interface FWRootViewController : UIViewController
@end

@implementation FWRootViewController
- (void)loadView {
    FWRootView *root = [[FWRootView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    root.backgroundColor = [UIColor clearColor];
    self.view = root;
}
@end

// 列表里的一行：左滑露出「删除」，长按拿起后上下拖动换顺序
@interface FWStepRowView : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView   *content;     // 会被左右平移的那层（序号 + 图标 + 文字）
@property (nonatomic, strong) UILabel  *numberLabel;
@property (nonatomic, strong) UIButton *deleteBtn;
@property (nonatomic, weak)   NSDictionary *step;    // 排序时靠它把视图和数据对上
@property (nonatomic) BOOL swipeEnabled;             // 能左滑删除
@property (nonatomic) BOOL dragEnabled;              // 能长按排序
@property (nonatomic, copy) void (^onTap)(void);
@property (nonatomic, copy) void (^onDelete)(void);
@property (nonatomic, copy) void (^onDragBegan)(void);
@property (nonatomic, copy) void (^onDragMoved)(CGFloat dy);
@property (nonatomic, copy) void (^onDragEnded)(void);
@end

@implementation FWStepRowView {
    BOOL    _open;          // 删除按钮是不是已经露出来
    CGFloat _panStartX;
    BOOL    _dragging;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // 行自己就是圆角容器：左滑时拽出去的那层被裁掉，删除块正好填满右边
        self.layer.cornerRadius = 8;
        self.clipsToBounds = YES;

        _deleteBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        _deleteBtn.backgroundColor = [UIColor systemRedColor];
        _deleteBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        [_deleteBtn setTitle:@"删除" forState:UIControlStateNormal];
        [_deleteBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _deleteBtn.hidden = YES;
        __weak typeof(self) weakSelf = self;
        [_deleteBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
            FWStepRowView *row = weakSelf;
            if (row && row.onDelete) row.onDelete();
        }] forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_deleteBtn];

        _content = [[UIView alloc] initWithFrame:self.bounds];
        _content.backgroundColor = [UIColor secondarySystemBackgroundColor];
        _content.layer.cornerRadius = 8;
        [self addSubview:_content];

        [_content addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)]];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        pan.delegate = self;
        [self addGestureRecognizer:pan];

        UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handlePress:)];
        press.minimumPressDuration = 0.35;
        press.delegate = self;
        [self addGestureRecognizer:press];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _deleteBtn.frame = CGRectMake(self.bounds.size.width - FW_DELETE_W, 0, FW_DELETE_W, self.bounds.size.height);
    // 平移中（transform 非单位矩阵）不能碰 frame，UIKit 会算错
    if (CGAffineTransformIsIdentity(_content.transform)) _content.frame = self.bounds;
}

// 露着「删除」时点一下 = 收回来，不触发进参数页
- (void)handleTap {
    if (_open) { [self setOpen:NO animated:YES]; return; }
    if (self.onTap) self.onTap();
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    if (!self.swipeEnabled) return;
    if (g.state == UIGestureRecognizerStateBegan) _panStartX = _content.transform.tx;
    CGFloat x = _panStartX + [g translationInView:self].x;
    if (x > 0) x = 0;
    if (x < -FW_DELETE_W) x = -FW_DELETE_W;
    _deleteBtn.hidden = (x > -1.0f);
    _content.transform = CGAffineTransformMakeTranslation(x, 0);
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        [self setOpen:(x < -FW_DELETE_W / 2.0f) animated:YES];
    }
}

- (void)setOpen:(BOOL)open animated:(BOOL)animated {
    _open = open;
    _deleteBtn.hidden = !open;
    void (^apply)(void) = ^{
        self->_content.transform = CGAffineTransformMakeTranslation(open ? -FW_DELETE_W : 0, 0);
    };
    if (animated) [UIView animateWithDuration:0.18 animations:apply];
    else apply();
}

- (void)handlePress:(UILongPressGestureRecognizer *)g {
    if (!self.dragEnabled) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        [self setOpen:NO animated:NO];
        _dragging = YES;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.3f;
        self.layer.shadowOffset = CGSizeMake(0, 3);
        self.layer.shadowRadius = 8;
        [UIView animateWithDuration:0.12 animations:^{
            self.transform = CGAffineTransformMakeScale(1.03f, 1.03f);
            self.alpha = 0.95f;
        }];
        if (self.onDragBegan) self.onDragBegan();
    } else if (g.state == UIGestureRecognizerStateChanged) {
        if (_dragging && self.onDragMoved) self.onDragMoved([g translationInView:self.superview].y);
    } else if (_dragging) {
        _dragging = NO;
        self.layer.shadowOpacity = 0;
        [UIView animateWithDuration:0.12 animations:^{
            self.transform = CGAffineTransformIdentity;
            self.alpha = 1.0f;
        }];
        if (self.onDragEnded) self.onDragEnded();
    }
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if ([g isKindOfClass:[UIPanGestureRecognizer class]]) {
        if (!self.swipeEnabled) return NO;
        CGPoint v = [(UIPanGestureRecognizer *)g velocityInView:self];
        return fabs(v.x) > fabs(v.y);   // 竖直方向留给列表自己滚
    }
    if ([g isKindOfClass:[UILongPressGestureRecognizer class]]) return self.dragEnabled;
    return YES;
}
@end

static UIButton *fwMakeButton(NSString *title, UIColor *color) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    b.backgroundColor = [UIColor secondarySystemBackgroundColor];
    b.layer.cornerRadius = 8;
    b.layer.borderColor = color.CGColor;
    b.layer.borderWidth = 1;
    [b setTitleColor:color forState:UIControlStateNormal];
    return b;
}

@interface FlowWindow ()
@end

static FlowWindow *_fwShared = nil;

@implementation FlowWindow {
    UIWindow     *_window;
    UIView       *_cardView;
    UIScrollView *_scroll;
    UITextView   *_previewView;
    UILabel      *_titleLabel;
    UIButton     *_backBtn;
    UIButton     *_previewBtn;
    UIButton     *_saveBtn;
    UIButton     *_closeBtn;

    NSString                    *_bundlePath;
    NSMutableDictionary         *_flow;
    NSMutableArray<NSMutableDictionary *> *_stack;
    BOOL                         _handwritten;   // main.py 是手写的，保存会用流程覆盖它
    CGFloat                      _contentHeight;

    NSMutableArray<FWStepRowView *> *_rows;      // 当前这一页的步骤行（长按排序要用）
    CGFloat                      _rowsTop;       // 第一行的 y（排序时算目标位置）
    FWStepRowView               *_dragRow;
    NSInteger                    _dragIndex;
    CGFloat                      _dragStartY;
}

+ (instancetype)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ _fwShared = [[FlowWindow alloc] init]; });
    return _fwShared;
}

#pragma mark - 打开 / 新建

- (void)openBundle:(NSString *)bundlePath {
    ZXSafeMainAsync(^{
        if (bundlePath.length == 0) return;
        self->_bundlePath = [bundlePath copy];
        if ([FlowScript bundleHasFlow:bundlePath]) {
            self->_flow = [FlowScript loadFlowFromBundle:bundlePath];
            self->_handwritten = NO;
        } else {
            self->_flow = [FlowScript emptyFlow];
            // 手写脚本开进编辑器：第一次改动会覆盖 main.py，先说一声
            self->_handwritten = ![FlowScript bundleHasGeneratedScript:bundlePath];
        }
        if (!self->_flow) self->_flow = [FlowScript emptyFlow];

        self->_stack = [NSMutableArray array];
        [self->_stack addObject:[self rootPage]];
        [self show];
        if (self->_handwritten) {
            showAlertBox(@"提示", @"这个脚本的 main.py 是手写的，在这里保存会用流程覆盖它。", 3);
        }
    });
}

- (void)createBundleAtPath:(NSString *)bundlePath {
    ZXSafeMainAsync(^{
        NSError *error = nil;
        if (![FlowScript createVisualScriptAtPath:bundlePath error:&error]) {
            showAlertBox(@"错误", error.localizedDescription ?: @"创建失败。", 999);
            return;
        }
        [self openBundle:bundlePath];
    });
}

- (NSMutableDictionary *)rootPage {
    NSString *name = [[_bundlePath lastPathComponent] stringByDeletingPathExtension];
    return [@{ @"kind": kPageList,
               @"isRoot": @YES,
               @"title": name.length ? name : @"可视化脚本",
               @"steps": _flow[@"Steps"] } mutableCopy];
}

#pragma mark - 窗口

- (void)ensureWindow {
    if (_window) return;

    // iOS 13+ 必须用 initWithWindowScene:，initWithFrame: 创建的窗口不会显示
    UIWindowScene *scene = [FloatingMenu preferredWindowScene];
    if (scene) _window = [[FMPassthroughWindow alloc] initWithWindowScene:scene];
    else _window = [[FMPassthroughWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    _window.windowLevel = UIWindowLevelAlert + 1;
    _window.backgroundColor = [UIColor clearColor];
    _window.rootViewController = [[FWRootViewController alloc] init];

    _cardView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, FW_CARD_W, 300)];
    _cardView.backgroundColor = [UIColor systemBackgroundColor];
    _cardView.layer.cornerRadius = 14;
    _cardView.layer.borderColor = [UIColor separatorColor].CGColor;
    _cardView.layer.borderWidth = 1;
    _cardView.clipsToBounds = YES;
    [_window.rootViewController.view addSubview:_cardView];

    _backBtn = fwMakeButton(@"← 返回", [UIColor systemBlueColor]);
    _backBtn.hidden = YES;
    [_backBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        [self popPage];
    }] forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_backBtn];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 6, 200, 36)];
    _titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _titleLabel.textColor = [UIColor labelColor];
    _titleLabel.adjustsFontSizeToFitWidth = YES;
    _titleLabel.minimumScaleFactor = 0.75;
    [_cardView addSubview:_titleLabel];

    _previewBtn = fwMakeButton(@"预览", [UIColor systemTealColor]);
    [_previewBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        [self pushPage:@{ @"kind": kPagePreview, @"title": @"生成的 main.py" }];
    }] forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_previewBtn];

    _saveBtn = fwMakeButton(@"保存", [UIColor systemBlueColor]);
    [_saveBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        [self saveAndHide];
    }] forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_saveBtn];

    _closeBtn = fwMakeButton(@"✕", [UIColor secondaryLabelColor]);
    [_closeBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        [self hide];   // ✕ 只关闭、不存盘
    }] forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_closeBtn];

    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(0, FW_TOP_H - 1, FW_CARD_W, 1)];
    sep.backgroundColor = [UIColor separatorColor];
    sep.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_cardView addSubview:sep];

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, FW_TOP_H, FW_CARD_W, 200)];
    _scroll.backgroundColor = [UIColor clearColor];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_cardView addSubview:_scroll];

    _previewView = [[UITextView alloc] initWithFrame:CGRectMake(0, FW_TOP_H, FW_CARD_W, 200)];
    _previewView.editable = NO;
    _previewView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _previewView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    _previewView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    _previewView.hidden = YES;
    _previewView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_cardView addSubview:_previewView];

    [self layoutCard];
    _window.hidden = YES;

    [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceOrientationDidChangeNotification
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            [self layoutCard];
        }];
}

- (CGFloat)cardWidth {
    CGFloat screenW = _window ? _window.bounds.size.width : [UIScreen mainScreen].bounds.size.width;
    if (screenW <= 0) screenW = 375.0f;
    CGFloat w = MIN(FW_CARD_W, screenW - 40.0f);
    if (w < 240.0f) w = MAX(screenW - 20.0f, 240.0f);
    if (w > screenW) w = screenW;
    return w;
}

- (void)layoutCard {
    if (!_window || !_cardView) return;
    CGFloat screenW = _window.bounds.size.width;
    CGFloat screenH = _window.bounds.size.height;
    if (screenW <= 0) screenW = [UIScreen mainScreen].bounds.size.width;
    if (screenH <= 0) screenH = [UIScreen mainScreen].bounds.size.height;

    CGFloat cardW = [self cardWidth];
    CGFloat maxH = screenH * 0.78f;
    CGFloat cardH = FW_TOP_H + _contentHeight;
    if (cardH > maxH) cardH = maxH;
    if (cardH < FW_TOP_H + 90.0f) cardH = FW_TOP_H + 90.0f;
    if (cardH > screenH - 40.0f) cardH = screenH - 40.0f;
    if (cardH < 120.0f) cardH = 120.0f;

    // 靠右摆：编辑时左边尽量露着游戏画面
    CGFloat originX = screenW - cardW - 20.0f;
    if (originX < 10.0f) originX = 10.0f;
    _cardView.frame = CGRectMake(originX, (screenH - cardH) / 2.0f, cardW, cardH);

    CGFloat topY = 6, topH = 36, gap = 6, rightX = cardW - 8;
    _closeBtn.frame = CGRectMake(rightX - 32, topY, 32, topH);
    rightX -= 32 + gap;
    _saveBtn.frame = CGRectMake(rightX - 64, topY, 64, topH);
    rightX -= 64 + gap;
    _previewBtn.frame = CGRectMake(rightX - 56, topY, 56, topH);
    rightX -= 56 + gap;

    CGFloat titleX = 12;
    if (!_backBtn.hidden) {
        _backBtn.frame = CGRectMake(8, topY, 72, topH);
        titleX = 88;
    }
    _titleLabel.frame = CGRectMake(titleX, topY, MAX(rightX - titleX - 6, 60), topH);

    _scroll.frame = CGRectMake(0, FW_TOP_H, cardW, MAX(cardH - FW_TOP_H, 0));
    _previewView.frame = _scroll.frame;
}

- (void)show {
    ZXSafeMainAsync(^{
        [self ensureWindow];
        if (!self->_window) return;
        [self reload];
        self->_window.hidden = NO;
        // window 刚建时 bounds 可能是 0，等 scene 摆正后再量一次
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self->_window) return;
            [self layoutCard];
        });
    });
}

- (void)hide {
    ZXSafeMainAsync(^{
        if (!self->_window) return;
        [self->_cardView endEditing:YES];
        self->_window.hidden = YES;
    });
}

- (BOOL)isShown {
    return _window != nil && !_window.hidden;
}

#pragma mark - 页面栈

- (NSMutableArray *)currentSteps {
    id steps = _stack.lastObject[@"steps"];
    return [steps isKindOfClass:[NSMutableArray class]] ? steps : nil;
}

- (void)pushPage:(NSDictionary *)page {
    [_stack addObject:[page mutableCopy]];
    [self reload];
}

- (void)popPage {
    if (_stack.count > 1) [_stack removeLastObject];
    [self reload];
}

- (void)pushParamsPageForStep:(NSMutableDictionary *)step {
    FlowStepType *type = [FlowScript typeForKind:step[@"Kind"]];
    [self pushPage:@{ @"kind": kPageParams, @"title": type.title ?: @"步骤", @"step": step }];
}

- (void)pushBranchPageForStep:(NSMutableDictionary *)step key:(NSString *)key title:(NSString *)title {
    if (![step[key] isKindOfClass:[NSMutableArray class]]) step[key] = [NSMutableArray array];
    [self pushPage:@{ @"kind": kPageList, @"title": title, @"steps": step[key], @"branch": @YES }];
}

- (void)pushTypesPage {
    BOOL branch = [_stack.lastObject[@"branch"] boolValue];
    [self pushPage:@{ @"kind": kPageTypes, @"title": @"添加步骤", @"branch": @(branch) }];
}

- (void)addStepOfKind:(NSString *)kind {
    if (_stack.count < 2) return;
    NSMutableArray *steps = _stack[_stack.count - 2][@"steps"];
    if (![steps isKindOfClass:[NSMutableArray class]]) return;
    NSMutableDictionary *step = [FlowScript newStepOfKind:kind];
    if (!step) return;

    [steps addObject:step];
    [_stack removeLastObject];   // 类型选择页换成参数页
    [self pushPage:@{ @"kind": kPageParams, @"title": [FlowScript typeForKind:kind].title ?: @"步骤", @"step": step }];
}

#pragma mark - 长按拖动排序

- (FWStepRowView *)rowForStep:(NSDictionary *)step {
    for (FWStepRowView *row in _rows) {
        if (row.step == step) return row;
    }
    return nil;
}

// 按数据数组的顺序把行摆回各自的位置（被拖的那行不碰，它跟着手指走）
- (void)layoutRowsExcept:(FWStepRowView *)skip {
    NSMutableArray *steps = [self currentSteps];
    if (!steps) return;
    CGFloat stepH = FW_ROW_H + FW_GAP;
    for (NSUInteger i = 0; i < steps.count; i++) {
        FWStepRowView *row = [self rowForStep:steps[i]];
        if (!row) continue;
        row.numberLabel.text = [NSString stringWithFormat:@"%lu.", (unsigned long)i + 1];
        if (row == skip) continue;
        row.frame = CGRectMake(row.frame.origin.x, _rowsTop + i * stepH, row.frame.size.width, FW_ROW_H);
    }
}

- (void)beginDragRow:(FWStepRowView *)row {
    NSMutableArray *steps = [self currentSteps];
    if (!row || !steps) return;
    NSUInteger index = [steps indexOfObjectIdenticalTo:row.step];
    if (index == NSNotFound) return;
    _dragRow = row;
    _dragIndex = (NSInteger)index;
    // 从数据算起始位置，别读 row.frame：这时候行上已经挂了缩放，frame 是缩放后的外框
    _dragStartY = _rowsTop + _dragIndex * (FW_ROW_H + FW_GAP);
    _scroll.scrollEnabled = NO;   // 排序期间别让列表跟着滚
    [_scroll bringSubviewToFront:row];
}

- (void)moveDragRow:(FWStepRowView *)row dy:(CGFloat)dy {
    if (!row || row != _dragRow) return;
    NSMutableArray *steps = [self currentSteps];
    if (!steps || steps.count == 0) return;

    CGFloat stepH = FW_ROW_H + FW_GAP;
    CGFloat y = _dragStartY + dy;
    CGFloat maxY = (CGFloat)(steps.count - 1) * stepH;
    if (y < 0) y = 0;
    if (y > maxY) y = maxY;
    // 拖动中 row 上有缩放 transform，不能碰 frame，只能改 center
    row.center = CGPointMake(row.center.x, y + FW_ROW_H / 2.0f);

    NSInteger target = (NSInteger)llround(y / stepH);
    if (target < 0) target = 0;
    if (target > (NSInteger)steps.count - 1) target = (NSInteger)steps.count - 1;
    if (target == _dragIndex) return;

    NSMutableDictionary *moved = steps[_dragIndex];
    [steps removeObjectAtIndex:_dragIndex];
    [steps insertObject:moved atIndex:target];
    _dragIndex = target;
    [self layoutRowsExcept:row];
}

- (void)endDragRow {
    _dragRow = nil;
    _scroll.scrollEnabled = YES;
    [self reload];   // 数据已经是新顺序了，重建一遍最省事（顺带恢复行的缩放和阴影）
}

// 左滑删除：从当前这一页的数组里摘掉这一步
- (void)deleteStep:(NSMutableDictionary *)step {
    NSMutableArray *steps = [self currentSteps];
    if (!steps) return;
    NSUInteger index = [steps indexOfObjectIdenticalTo:step];
    if (index == NSNotFound) return;
    [steps removeObjectAtIndex:index];
    [self reload];
}

- (void)deleteCurrentStep {
    if (_stack.count < 2) return;
    NSMutableDictionary *step = _stack.lastObject[@"step"];
    NSMutableArray *steps = _stack[_stack.count - 2][@"steps"];
    if (!step || ![steps isKindOfClass:[NSMutableArray class]]) return;
    [steps removeObjectIdenticalTo:step];
    [self popPage];
}

#pragma mark - 保存

- (void)saveAndHide {
    [_cardView endEditing:YES];
    NSError *error = nil;
    if (![FlowScript saveFlow:_flow toBundle:_bundlePath error:&error] ||
        ![FlowScript writeGeneratedScriptForFlow:_flow toBundle:_bundlePath error:&error]) {
        showAlertBox(@"错误", error.localizedDescription ?: @"保存失败。", 999);
        return;
    }
    showAlertBox(@"小新Lap", @"已保存，并重新生成了 main.py。", 1);
    [self hide];
}

#pragma mark - 取点

// 取点器要盖在游戏上，编辑器先让开；取完再把卡片放回来
- (void)beginPickingForStep:(NSMutableDictionary *)step type:(FlowStepType *)type {
    [_cardView endEditing:YES];
    _cardView.hidden = YES;

    __weak typeof(self) weakSelf = self;
    [PickOverlay presentWithMode:type.pickMode completion:^(NSDictionary *result) {
        FlowWindow *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf applyPickResult:result toStep:step type:type];
        strongSelf->_cardView.hidden = NO;
        [strongSelf layoutCard];
        [strongSelf reload];
    } cancel:^{
        FlowWindow *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_cardView.hidden = NO;
        [strongSelf layoutCard];
    }];
}

- (void)applyPickResult:(NSDictionary *)result toStep:(NSMutableDictionary *)step type:(FlowStepType *)type {
    NSArray<NSString *> *targets = type.pickTargets;
    if (targets.count == 0) return;

    if (type.pickMode == FlowPickModePoint || type.pickMode == FlowPickModeRect) {
        // 起点 / 终点分开写：滑动要的是方向，不能被外接矩形抹掉
        CGPoint start = [result[kPickStart] CGPointValue];
        CGPoint end = [result[kPickEnd] CGPointValue];
        NSArray<NSNumber *> *values = @[ @(llround(start.x)), @(llround(start.y)),
                                         @(llround(end.x)), @(llround(end.y)) ];
        for (NSUInteger i = 0; i < targets.count && i < values.count; i++) {
            step[targets[i]] = values[i];
        }
    } else if (type.pickMode == FlowPickModeColor) {
        CGPoint point = [result[kPickStart] CGPointValue];
        step[targets[0]] = @(llround(point.x));
        if (targets.count > 1) step[targets[1]] = @(llround(point.y));
        if ([result[kPickHex] length] > 0) step[@"Color"] = result[kPickHex];
    } else if (type.pickMode == FlowPickModeTemplate) {
        if ([result[kPickTemplate] length] > 0) step[targets[0]] = result[kPickTemplate];
    }
}

#pragma mark - 行控件

// 列表里的一行：序号（可选）+ 图标 + 大标题（+ 小字细节）
// deletable = 能左滑删除，sortable = 能长按拖动排序
- (FWStepRowView *)makeRowWithTitle:(NSString *)title
                             detail:(NSString *)detail
                              index:(NSInteger)index
                             symbol:(NSString *)symbol
                          deletable:(BOOL)deletable
                           sortable:(BOOL)sortable
                              width:(CGFloat)w
                              onTap:(void (^)(void))onTap
                           onDelete:(void (^)(void))onDelete
{
    FWStepRowView *row = [[FWStepRowView alloc] initWithFrame:CGRectMake(0, 0, w, FW_ROW_H)];
    row.swipeEnabled = deletable;
    row.dragEnabled = sortable;
    row.onTap = onTap;
    row.onDelete = onDelete;

    CGFloat left = 12.0f;
    if (index >= 0) {
        row.numberLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 0, 22, FW_ROW_H)];
        row.numberLabel.text = [NSString stringWithFormat:@"%ld.", (long)index + 1];
        row.numberLabel.font = [UIFont systemFontOfSize:12];
        row.numberLabel.textColor = [UIColor secondaryLabelColor];
        [row.content addSubview:row.numberLabel];
        left = 34.0f;
    }

    if (symbol.length > 0) {
        UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectMake(left, (FW_ROW_H - 17) / 2.0f, 17, 17)];
        icon.image = [UIImage systemImageNamed:symbol];
        icon.tintColor = [UIColor systemBlueColor];
        icon.contentMode = UIViewContentModeScaleAspectFit;
        [row.content addSubview:icon];
        left += 17.0f + 7.0f;
    }

    CGFloat textW = w - left - 12.0f;
    UILabel *main = [[UILabel alloc] initWithFrame:CGRectMake(left, detail.length > 0 ? 5 : 0, textW, detail.length > 0 ? 19 : FW_ROW_H)];
    main.text = title;
    main.font = [UIFont systemFontOfSize:14];
    main.textColor = [UIColor labelColor];
    main.adjustsFontSizeToFitWidth = YES;
    main.minimumScaleFactor = 0.8;
    [row.content addSubview:main];

    if (detail.length > 0) {
        UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(left, 24, textW, 16)];
        sub.text = detail;
        sub.font = [UIFont systemFontOfSize:11];
        sub.textColor = [UIColor secondaryLabelColor];
        sub.adjustsFontSizeToFitWidth = YES;
        sub.minimumScaleFactor = 0.8;
        [row.content addSubview:sub];
    }
    return row;
}

- (UIView *)makeActionRow:(NSString *)title color:(UIColor *)color width:(CGFloat)w action:(void (^)(void))action {
    UIButton *row = [UIButton buttonWithType:UIButtonTypeSystem];
    row.frame = CGRectMake(0, 0, w, FW_ROW_H);
    row.backgroundColor = [UIColor secondarySystemBackgroundColor];
    row.layer.cornerRadius = 8;
    row.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    row.titleLabel.font = [UIFont systemFontOfSize:14];
    // 左对齐时标题贴着框边，前面留一个空格当内边距
    [row setTitle:[NSString stringWithFormat:@"  %@", title] forState:UIControlStateNormal];
    [row setTitleColor:color forState:UIControlStateNormal];
    [row addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        if (action) action();
    }] forControlEvents:UIControlEventTouchUpInside];
    return row;
}

// 一行「标签 + 输入框」：步骤参数和循环设置共用
- (UIView *)makeValueRow:(NSString *)title
                   value:(id)value
                 integer:(BOOL)integer
                   width:(CGFloat)w
                onChange:(void (^)(NSString *text))onChange
{
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, FW_ROW_H)];
    row.backgroundColor = [UIColor secondarySystemBackgroundColor];
    row.layer.cornerRadius = 8;

    CGFloat labelW = MIN(170.0f, w * 0.42f);
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, labelW, FW_ROW_H)];
    label.text = title;
    label.font = [UIFont systemFontOfSize:13];
    label.textColor = [UIColor labelColor];
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.75;
    [row addSubview:label];

    CGFloat fieldX = 12 + labelW + 6;
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(fieldX, 7, MAX(w - fieldX - 12, 60), FW_ROW_H - 14)];
    field.font = [UIFont systemFontOfSize:14];
    field.textColor = [UIColor labelColor];
    field.backgroundColor = [UIColor systemBackgroundColor];
    field.layer.cornerRadius = 8;
    field.layer.borderColor = [UIColor separatorColor].CGColor;
    field.layer.borderWidth = 1;
    field.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    field.keyboardType = integer ? UIKeyboardTypeDecimalPad : UIKeyboardTypeDefault;
    field.inputAccessoryView = [self keyboardAccessory];
    field.text = [FlowScript textForValue:value];
    [field addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        if (onChange) onChange(field.text ?: @"");
    }] forControlEvents:UIControlEventEditingChanged];
    [row addSubview:field];
    return row;
}

// 键盘上方那条「完成」：数字键盘没有回车键
- (UIView *)keyboardAccessory {
    UIToolbar *bar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UIBarButtonItem *space = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                          target:nil action:nil];
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                                             style:UIBarButtonItemStylePlain
                                                            target:self
                                                            action:@selector(dismissKeyboard)];
    bar.items = @[space, done];
    return bar;
}

- (void)dismissKeyboard {
    [_cardView endEditing:YES];
}

#pragma mark - 内容刷新

- (CGFloat)addRow:(UIView *)row y:(CGFloat)y {
    row.frame = CGRectMake(4, y, row.frame.size.width, row.frame.size.height);
    [_scroll addSubview:row];
    return y + row.frame.size.height + FW_GAP;
}

- (void)addSectionLabel:(NSString *)text width:(CGFloat)pw y:(CGFloat)y {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12, y, pw - 24, 18)];
    label.text = text;
    label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    label.textColor = [UIColor secondaryLabelColor];
    [_scroll addSubview:label];
}

- (void)reload {
    if (!_window) return;
    NSMutableDictionary *page = _stack.lastObject;
    if (!page) return;
    NSString *kind = page[@"kind"];
    CGFloat pw = [self cardWidth];
    CGFloat rowW = pw - 8;

    [_cardView endEditing:YES];
    for (UIView *v in _scroll.subviews) [v removeFromSuperview];
    _rows = [NSMutableArray array];   // 每次重建都清空：换页后旧行不该再被排序逻辑引用
    _dragRow = nil;
    _scroll.hidden = NO;
    _previewView.hidden = YES;

    BOOL isRoot = [page[@"isRoot"] boolValue];
    _backBtn.hidden = isRoot;
    _previewBtn.hidden = !isRoot;
    _titleLabel.text = isRoot ? [NSString stringWithFormat:@"可视化编辑：%@", page[@"title"]] : page[@"title"];

    if ([kind isEqualToString:kPagePreview]) {
        _scroll.hidden = YES;
        _previewView.hidden = NO;
        _previewView.text = [FlowScript pythonSourceForFlow:_flow];
        [_previewView setContentOffset:CGPointZero animated:NO];
        _contentHeight = 0;
        [self layoutCard];
        return;
    }

    CGFloat y = 8;

    if ([kind isEqualToString:kPageList]) {
        NSArray *steps = page[@"steps"];
        if (steps.count == 0) {
            [self addSectionLabel:(isRoot ? @"还没有步骤。点下面「添加步骤」开始拼。" : @"这一支还没有动作。") width:pw y:y];
            y += 24;
        } else {
            _rowsTop = y;
            for (NSInteger i = 0; i < (NSInteger)steps.count; i++) {
                NSDictionary *step = steps[i];
                if (![step isKindOfClass:[NSDictionary class]]) continue;
                FlowStepType *type = [FlowScript typeForKind:step[@"Kind"]];
                FWStepRowView *row = [self makeRowWithTitle:[FlowScript summaryForStep:step]
                                                     detail:[FlowScript detailForStep:step]
                                                      index:i
                                                     symbol:type.symbolName
                                                  deletable:YES
                                                   sortable:YES
                                                      width:rowW
                                                      onTap:^{
                                                          [self pushParamsPageForStep:(NSMutableDictionary *)step];
                                                      }
                                                   onDelete:^{
                                                       [self deleteStep:(NSMutableDictionary *)step];
                                                   }];
                __weak typeof(self) weakSelf = self;
                __weak FWStepRowView *weakRow = row;   // 行持有 block、block 又持有行 → 这里必须弱引用，否则漏一组视图
                row.onDragBegan = ^{ [weakSelf beginDragRow:weakRow]; };
                row.onDragMoved = ^(CGFloat dy) { [weakSelf moveDragRow:weakRow dy:dy]; };
                row.onDragEnded = ^{ [weakSelf endDragRow]; };
                row.step = step;
                [_rows addObject:row];
                y = [self addRow:row y:y];
            }
        }

        UIView *add = [self makeActionRow:@"＋ 添加步骤" color:[UIColor systemBlueColor] width:rowW action:^{
            [self pushTypesPage];
        }];
        y = [self addRow:add y:y];

        if (isRoot) {
            y += 6;
            [self addSectionLabel:@"运行方式" width:pw y:y];
            y += 22;
            UIView *loopTimes = [self makeValueRow:@"循环次数（0 = 一直循环）" value:_flow[@"LoopTimes"] integer:YES width:rowW
                                          onChange:^(NSString *text) {
                                              self->_flow[@"LoopTimes"] = [FlowScript valueFromText:text integer:YES];
                                          }];
            y = [self addRow:loopTimes y:y];
            UIView *loopInterval = [self makeValueRow:@"每轮之间停（秒）" value:_flow[@"LoopInterval"] integer:NO width:rowW
                                             onChange:^(NSString *text) {
                                                 self->_flow[@"LoopInterval"] = [FlowScript valueFromText:text integer:NO];
                                             }];
            y = [self addRow:loopInterval y:y];
        }
    } else if ([kind isEqualToString:kPageTypes]) {
        NSArray<FlowStepType *> *types = [page[@"branch"] boolValue] ? [FlowScript simpleStepTypes]
                                                                    : [FlowScript allStepTypes];
        for (FlowStepType *type in types) {
            NSString *kindName = type.kind;
            // 用小字提示这一步大概要填什么，免得只看到「识色 / 找色 / 识图」分不清
            NSString *hint = [FlowScript summaryForStep:[FlowScript newStepOfKind:kindName]];
            FWStepRowView *row = [self makeRowWithTitle:type.title detail:hint index:-1
                                                 symbol:type.symbolName
                                              deletable:NO sortable:NO width:rowW
                                                  onTap:^{ [self addStepOfKind:kindName]; }
                                               onDelete:nil];
            y = [self addRow:row y:y];
        }
    } else if ([kind isEqualToString:kPageParams]) {
        NSMutableDictionary *step = page[@"step"];
        FlowStepType *type = [FlowScript typeForKind:step[@"Kind"]];
        if (!type) return;

        if (type.pickMode != FlowPickModeNone) {
            UIView *pick = [self makeActionRow:type.pickActionTitle color:[UIColor systemBlueColor] width:rowW action:^{
                [self beginPickingForStep:step type:type];
            }];
            y = [self addRow:pick y:y];
        }

        for (FlowFieldSpec *spec in type.fields) {
            NSString *key = spec.key;
            BOOL integer = spec.integer;
            UIView *row = [self makeValueRow:spec.title value:step[key] integer:integer width:rowW
                                    onChange:^(NSString *text) {
                                        step[key] = [FlowScript valueFromText:text integer:integer];
                                    }];
            y = [self addRow:row y:y];
        }

        if (type.isCondition) {
            y += 4;
            [self addSectionLabel:@"成立 / 不成立时要做什么" width:pw y:y];
            y += 22;
            NSArray<NSString *> *keys = @[ @"Then", @"Else" ];
            NSArray<NSString *> *titles = @[ @"成立时", @"不成立时" ];
            for (NSInteger i = 0; i < 2; i++) {
                NSString *key = keys[i];
                NSArray *actions = [step[key] isKindOfClass:[NSArray class]] ? step[key] : @[];
                NSString *title = [NSString stringWithFormat:@"%@（%lu 个动作）▸", titles[i], (unsigned long)actions.count];
                UIView *row = [self makeActionRow:title color:[UIColor labelColor] width:rowW action:^{
                    [self pushBranchPageForStep:step key:key title:titles[i]];
                }];
                y = [self addRow:row y:y];
            }
        }

        y += 6;
        UIView *deleteRow = [self makeActionRow:@"删除这一步" color:[UIColor systemRedColor] width:rowW action:^{
            [self deleteCurrentStep];
        }];
        y = [self addRow:deleteRow y:y];
    }

    _scroll.contentSize = CGSizeMake(pw, y + 4);
    [_scroll setContentOffset:CGPointZero animated:NO];
    _contentHeight = y + 8;
    [self layoutCard];
}

@end

#pragma mark - socket 任务 44

NSString *handleFlowEditorTaskWithRawData(UInt8 *eventData, NSError **error) {
    NSString *data = eventData ? [NSString stringWithUTF8String:(const char *)eventData] : @"";
    NSArray<NSString *> *parts = [data componentsSeparatedByString:@";;"];
    // 形如 ";;open;;/var/mobile/.../脚本.bdl"：parts[0] 是空的
    NSString *action = parts.count > 1 ? parts[1] : @"";
    NSMutableArray<NSString *> *rest = [NSMutableArray array];
    for (NSUInteger i = 2; i < parts.count; i++) {
        if (parts[i].length > 0) [rest addObject:parts[i]];
    }
    NSString *path = [rest componentsJoinedByString:@";;"];

    if (path.length == 0) {
        if (error) *error = [NSError errorWithDomain:@"小新Lap" code:1
                                            userInfo:@{ NSLocalizedDescriptionKey: @"没有指定脚本路径。" }];
        return nil;
    }

    if ([action isEqualToString:@"new"]) {
        [[FlowWindow shared] createBundleAtPath:path];
    } else {
        [[FlowWindow shared] openBundle:path];
    }
    return @"0\r\n";
}