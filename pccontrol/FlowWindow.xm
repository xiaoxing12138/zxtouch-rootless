//
//  FlowWindow.xm
//  小新Lap 可视化流程编辑器（内容挂在选项面板里，自己不弹窗）
//

#import "FlowWindow.h"
#import "FunctionWindow.h"    // 同一张面板：编辑器不再自己开窗口
#import "FlowScript.h"
#import "PickOverlay.h"
#import "AlertBox.h"
#import "Common.h"

#import <math.h>   // llround / fabs

#define FW_ROW_H    45.0f
#define FW_GAP      8.0f
#define FW_DELETE_W 88.0f   // 左滑露出来的「删除」宽度
#define FW_CELL_H   54.0f   // 「添加步骤」子浮窗里一个类型格的高度

// 页面种类（参数编辑 / 设置都在子浮窗里，不再是页面）
static NSString * const kPageList = @"list";   // 步骤列表（整条流程 / 成立时 / 不成立时）

#pragma mark - 配色

// 一种颜色给一深一浅两份，跟着面板窗口的 overrideUserInterfaceStyle 切
static UIColor *fwColor(uint32_t light, uint32_t dark)
{
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        uint32_t v = (traits.userInterfaceStyle == UIUserInterfaceStyleDark) ? dark : light;
        return [UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0
                               green:((v >> 8) & 0xFF) / 255.0
                                blue:(v & 0xFF) / 255.0 alpha:1];
    }];
}

// 每种步骤一个色：左边色条、图标底、子浮窗的格子都用它
static UIColor *fwTypeColor(NSString *kind)
{
    if ([kind isEqualToString:kFlowTap])       return fwColor(0x2F6BFF, 0x5A9BFF);
    if ([kind isEqualToString:kFlowSwipe])     return fwColor(0x7B4DFF, 0xA98BFF);
    if ([kind isEqualToString:kFlowWait])      return fwColor(0xB87700, 0xFFB84D);
    if ([kind isEqualToString:kFlowToast])     return fwColor(0x0E9F8A, 0x2ED3B7);
    if ([kind isEqualToString:kFlowColor])     return fwColor(0xD9551F, 0xFF8F5E);
    if ([kind isEqualToString:kFlowFindColor]) return fwColor(0xC22E7A, 0xF0559B);
    if ([kind isEqualToString:kFlowImage])     return fwColor(0x1B8F49, 0x35C46B);
    return fwColor(0x4C8DFF, 0x6EA8FF);
}

// 参数按语义分组，声明顺序仍然是字段自己的声明顺序
static NSArray<NSDictionary<NSString *, id> *> *fwGroupsForKind(NSString *kind)
{
    if ([kind isEqualToString:kFlowTap]) return @[
        @{ @"title": @"位置", @"keys": @[ @"X", @"Y" ] },
        @{ @"title": @"点按", @"keys": @[ @"Count", @"Interval", @"Hold" ] },
    ];
    if ([kind isEqualToString:kFlowSwipe]) return @[
        @{ @"title": @"起点", @"keys": @[ @"X1", @"Y1" ] },
        @{ @"title": @"终点", @"keys": @[ @"X2", @"Y2" ] },
        @{ @"title": @"滑动时长", @"keys": @[ @"Duration" ] },
    ];
    if ([kind isEqualToString:kFlowWait]) return @[ @{ @"title": @"时间", @"keys": @[ @"Seconds" ] } ];
    if ([kind isEqualToString:kFlowToast]) return @[ @{ @"title": @"提示", @"keys": @[ @"Text", @"Seconds" ] } ];
    if ([kind isEqualToString:kFlowColor]) return @[
        @{ @"title": @"位置", @"keys": @[ @"X", @"Y" ] },
        @{ @"title": @"颜色", @"keys": @[ @"Color", @"Tolerance" ] },
    ];
    if ([kind isEqualToString:kFlowFindColor]) return @[
        @{ @"title": @"区域", @"keys": @[ @"X1", @"Y1", @"X2", @"Y2" ] },
        @{ @"title": @"颜色", @"keys": @[ @"Color", @"Tolerance" ] },
    ];
    if ([kind isEqualToString:kFlowImage]) return @[
        @{ @"title": @"模板", @"keys": @[ @"Template" ] },
        @{ @"title": @"匹配", @"keys": @[ @"Threshold" ] },
    ];
    return @[];
}

#pragma mark - 定时设置（和 App 的 ScheduleSettingsViewController / 引擎 Schedule.xm 键值一一对应）

static NSString * const kScheduleKey     = @"Schedule";
static NSString * const kStartMode       = @"StartMode";
static NSString * const kStartTime       = @"StartTime";
static NSString * const kWeekdays        = @"Weekdays";
static NSString * const kEndMode         = @"EndMode";
static NSString * const kDurationMinutes = @"DurationMinutes";
static NSString * const kEndTime         = @"EndTime";

static NSString * const kModeManual   = @"manual";
static NSString * const kModeDaily    = @"daily";
static NSString * const kModeDuration = @"duration";

/// 把「9:5」「09:30」「9：30」都理成「09:30」；不是合法时刻就返回 nil
static NSString *fwNormalizeTime(NSString *text)
{
    NSString *raw = [[text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                     stringByReplacingOccurrencesOfString:@"：" withString:@":"];
    NSArray<NSString *> *parts = [raw componentsSeparatedByString:@":"];
    if (parts.count != 2) return nil;
    NSInteger hour = parts[0].integerValue;
    NSInteger minute = parts[1].integerValue;
    if (parts[0].length == 0 || parts[1].length == 0) return nil;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return nil;
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)hour, (long)minute];
}

/// 每次改动都立刻写进脚本包的 info.plist；全手动 = Schedule 键整个拿掉，调度器直接跳过
static void fwPersistSchedule(NSString *bundlePath, NSString *startMode, NSString *startTime,
                              NSArray<NSNumber *> *weekdays, NSString *endMode,
                              NSInteger durationMinutes, NSString *endTime)
{
    NSString *infoPath = [bundlePath stringByAppendingPathComponent:@"info.plist"];
    NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:infoPath];
    NSMutableDictionary *info = [existing isKindOfClass:[NSDictionary class]] ? [existing mutableCopy]
                                                                              : [NSMutableDictionary dictionary];

    NSMutableDictionary *schedule = [NSMutableDictionary dictionary];
    if ([startMode isEqualToString:kModeDaily]) {
        schedule[kStartMode] = kModeDaily;
        schedule[kStartTime] = fwNormalizeTime(startTime) ?: @"09:00";
        schedule[kWeekdays] = [weekdays copy];          // 空数组 = 每天
    }
    if ([endMode isEqualToString:kModeDuration]) {
        schedule[kEndMode] = kModeDuration;
        schedule[kDurationMinutes] = @(MAX(1, durationMinutes));
    } else if ([endMode isEqualToString:kModeDaily]) {
        schedule[kEndMode] = kModeDaily;
        schedule[kEndTime] = fwNormalizeTime(endTime) ?: @"23:00";
    }

    if (schedule.count == 0) [info removeObjectForKey:kScheduleKey];
    else info[kScheduleKey] = schedule;

    if (![info writeToFile:infoPath atomically:YES]) {
        showAlertBox(@"错误", @"无法写入 info.plist。", 999);
    }
}

#pragma mark - 列表行

// 列表里的一行：左滑露出「删除」，长按弹「复制到下方」，右侧把手按住直接拖动排序
@interface FWStepRowView : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView   *content;     // 会被左右平移的那层
@property (nonatomic, strong) UILabel  *numberLabel; // 排序时要重编号
@property (nonatomic, strong) UIButton *deleteBtn;
@property (nonatomic, strong) UIView   *dragHandle;  // 右侧把手（自己挂 pan，有 translationInView 可用）
@property (nonatomic, weak)   NSDictionary *step;    // 排序时靠它把视图和数据对上
@property (nonatomic) BOOL swipeEnabled;             // 能左滑删除
@property (nonatomic) BOOL dragEnabled;              // 把手能拖动排序
@property (nonatomic, copy) void (^onTap)(void);
@property (nonatomic, copy) void (^onDelete)(void);
@property (nonatomic, copy) void (^onCopy)(void);
@property (nonatomic, copy) void (^onDragBegan)(void);
@property (nonatomic, copy) void (^onDragMoved)(CGFloat dy);
@property (nonatomic, copy) void (^onDragEnded)(void);
@end

@implementation FWStepRowView {
    BOOL    _open;          // 删除按钮是不是已经露出来
    CGFloat _panStartX;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // 行自己就是圆角容器：左滑时拽出去的那层被裁掉，删除块正好填满右边
        self.layer.cornerRadius = 12;
        self.clipsToBounds = YES;

        _deleteBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        _deleteBtn.backgroundColor = ZXPalette(ZXPalDanger);
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
        _content.backgroundColor = ZXPalette(ZXPalRow);
        _content.layer.cornerRadius = 12;
        [self addSubview:_content];

        // 长按弹「复制到下方」；点按要等长按失败才算数，不然一松手两个都触发
        UILongPressGestureRecognizer *press =
            [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handlePress:)];
        press.minimumPressDuration = 0.45;
        [self addGestureRecognizer:press];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
        [tap requireGestureRecognizerToFail:press];
        [_content addGestureRecognizer:tap];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        pan.delegate = self;
        [self addGestureRecognizer:pan];
    }
    return self;
}

// 右侧把手：按住直接上下拖（不用先长按），图标本体只负责显示
- (void)installDragHandle {
    if (_dragHandle) return;
    _dragHandle = [[UIView alloc] init];
    _dragHandle.userInteractionEnabled = YES;
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"line.3.horizontal"]];
    icon.tintColor = ZXPalette(ZXPalSub);
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tag = 7;
    [_dragHandle addSubview:icon];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleDragPan:)];
    [_dragHandle addGestureRecognizer:pan];
    [_content addSubview:_dragHandle];   // 跟着 content 走，左滑时一起让开
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _deleteBtn.frame = CGRectMake(self.bounds.size.width - FW_DELETE_W, 0, FW_DELETE_W, self.bounds.size.height);
    // 平移中（transform 非单位矩阵）不能碰 frame，UIKit 会算错
    if (CGAffineTransformIsIdentity(_content.transform)) _content.frame = self.bounds;
    _dragHandle.frame = CGRectMake(self.bounds.size.width - 34.0f, 0, 34.0f, self.bounds.size.height);
    UIView *icon = [_dragHandle viewWithTag:7];
    icon.frame = CGRectMake((34.0f - 16.0f) / 2.0f, (self.bounds.size.height - 16.0f) / 2.0f, 16, 16);
}

// 按下去给一点反馈：整行压暗一档，抬手 / 被手势抢走就还原
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    [UIView animateWithDuration:0.1 animations:^{ self->_content.alpha = 0.68f; }];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    [self resetPressFeedback];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    [self resetPressFeedback];
}
- (void)resetPressFeedback {
    [UIView animateWithDuration:0.16 animations:^{ self->_content.alpha = 1.0f; }];
}

// 露着「删除」时点一下 = 收回来，不触发进参数
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

// 长按 = 弹「复制到下方」小菜单（落在把手上不算，把手是拖排序的）
- (void)handlePress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (self.dragEnabled && [g locationInView:self].x > self.bounds.size.width - 34.0f) return;
    if (self.onCopy) self.onCopy();
}

// 把手上的拖动排序：Began 即拿起，松手落下
- (void)handleDragPan:(UIPanGestureRecognizer *)g {
    if (!self.dragEnabled) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        [self setOpen:NO animated:NO];
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
        if (self.onDragMoved) self.onDragMoved([g translationInView:self.superview].y);
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
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
        // 把手那条竖条留给拖动排序，别在这里触发左滑
        if (self.dragEnabled && [g locationInView:self].x > self.bounds.size.width - 34.0f) return NO;
        CGPoint v = [(UIPanGestureRecognizer *)g velocityInView:self];
        return fabs(v.x) > fabs(v.y);   // 竖直方向留给列表自己滚
    }
    return YES;
}
@end

@interface FlowWindow ()
@end

static FlowWindow *_fwShared = nil;

@implementation FlowWindow {
    __weak id<FlowEditorHost> _host;
    __weak UIScrollView      *_scroll;      // 面板的内容区，由 FunctionWindow 提供
    CGFloat                   _pw;          // 行宽基准

    NSString                    *_bundlePath;
    NSMutableDictionary         *_flow;
    NSMutableArray<NSMutableDictionary *> *_stack;
    BOOL                         _handwritten;   // main.py 是手写的，改动会覆盖它

    NSMutableArray<FWStepRowView *> *_rows;      // 当前这一页的步骤行（排序要用）
    CGFloat                      _rowsTop;       // 第一行的 y（排序时算目标位置）
    FWStepRowView               *_dragRow;
    NSInteger                    _dragIndex;
    CGFloat                      _dragStartY;

    BOOL                         _animateTransition;   // 换页时淡入 + 上移

    // 子浮窗（添加步骤 / 编辑参数 / 设置）：挂在窗口根的整屏容器上，屏幕中间
    UIView                      *_subDim;        // 遮罩 + 卡片
    UIScrollView                *_subScroll;     // 卡片里的内容区
    void (^_subRebuilder)(void);                 // 取点回来后重建子浮窗内容
}

+ (instancetype)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ _fwShared = [[FlowWindow alloc] init]; });
    return _fwShared;
}

- (void)setHost:(id<FlowEditorHost>)host { _host = host; }

#pragma mark - 载入 / 实时落盘

- (void)loadBundle:(NSString *)bundlePath {
    if (bundlePath.length == 0) return;
    _bundlePath = [bundlePath copy];
    if ([FlowScript bundleHasFlow:bundlePath]) {
        _flow = [FlowScript loadFlowFromBundle:bundlePath];
        _handwritten = NO;
    } else {
        _flow = [FlowScript emptyFlow];
        // 手写脚本开进编辑器：改动会实时覆盖 main.py，先说一声
        _handwritten = ![FlowScript bundleHasGeneratedScript:bundlePath];
    }
    if (!_flow) _flow = [FlowScript emptyFlow];

    _stack = [NSMutableArray array];
    [_stack addObject:[self rootPage]];
    _animateTransition = YES;
    [self refresh];
    if (_handwritten) {
        showAlertBox(@"提示", @"这个脚本的 main.py 是手写的，这里的每次修改都会实时覆盖它。", 3);
    }
}

// 实时落盘：每次改动（字段、添加、删除、排序、取点、循环参数）都调它，静默写 flow.plist + 重新生成 main.py
- (void)autosave {
    if (_bundlePath.length == 0 || !_flow) return;
    NSError *error = nil;
    if (![FlowScript saveFlow:_flow toBundle:_bundlePath error:&error] ||
        ![FlowScript writeGeneratedScriptForFlow:_flow toBundle:_bundlePath error:&error]) {
        showAlertBox(@"错误", error.localizedDescription ?: @"保存失败。", 999);
    }
}

- (NSMutableDictionary *)rootPage {
    NSString *name = [[_bundlePath lastPathComponent] stringByDeletingPathExtension];
    return [@{ @"kind": kPageList,
               @"isRoot": @YES,
               @"title": name.length ? name : @"可视化脚本",
               @"steps": _flow[@"Steps"] } mutableCopy];
}

#pragma mark - 页面栈

- (NSMutableArray *)currentSteps {
    id steps = _stack.lastObject[@"steps"];
    return [steps isKindOfClass:[NSMutableArray class]] ? steps : nil;
}

- (void)pushPage:(NSDictionary *)page {
    _animateTransition = YES;
    [_stack addObject:[page mutableCopy]];
    [self refresh];
}

- (void)goBack {
    if (_stack.count > 1) {
        _animateTransition = YES;
        [_stack removeLastObject];
    }
    [self refresh];
}

- (void)pushBranchPageForStep:(NSMutableDictionary *)step key:(NSString *)key title:(NSString *)title {
    if (![step[key] isKindOfClass:[NSMutableArray class]]) step[key] = [NSMutableArray array];
    [self pushPage:@{ @"kind": kPageList, @"title": title, @"steps": step[key], @"branch": @YES }];
}

// 加一步：落盘后直接在子浮窗里打开它的参数
- (void)addStepOfKind:(NSString *)kind {
    NSMutableArray *steps = [self currentSteps];
    if (!steps) return;
    NSMutableDictionary *step = [FlowScript newStepOfKind:kind];
    if (!step) return;
    [steps addObject:step];
    [self autosave];
    [self refresh];
    [self showParamsSubForStep:step parentSteps:steps];
}

#pragma mark - 把手拖动排序

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
        row.numberLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)i + 1];
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
    [self autosave];   // 新顺序落盘
    [self refresh];    // 重建一遍最省事（顺带恢复行的缩放和阴影）
}

// 左滑删除：从当前这一页的数组里摘掉这一步
- (void)deleteStep:(NSMutableDictionary *)step {
    NSMutableArray *steps = [self currentSteps];
    if (!steps) return;
    NSUInteger index = [steps indexOfObjectIdenticalTo:step];
    if (index == NSNotFound) return;
    [steps removeObjectAtIndex:index];
    [self autosave];
    [self refresh];
}

// 长按行的菜单：复制到下方
- (void)showCopyMenuForRow:(FWStepRowView *)row step:(NSMutableDictionary *)step {
    __weak typeof(self) weakSelf = self;
    ZXShowMiniMenuNearView(row, @[ @{
        @"title": @"复制到下方",
        @"icon": @"doc.on.doc",
        @"action": ^{
            FlowWindow *strongSelf = weakSelf;
            if (!strongSelf) return;
            NSMutableArray *steps = [strongSelf currentSteps];
            NSUInteger index = [steps indexOfObjectIdenticalTo:step];
            if (index == NSNotFound) return;
            NSMutableDictionary *copy = [FlowScript mutableStepFromStep:step];
            if (!copy) return;
            [steps insertObject:copy atIndex:index + 1];
            [strongSelf autosave];
            [strongSelf refresh];
        },
    } ]);
}

#pragma mark - 取点

// 取点器要盖在游戏上，面板和子浮窗都先让开；取完再放回来
- (void)beginPickingForStep:(NSMutableDictionary *)step type:(FlowStepType *)type {
    [_scroll endEditing:YES];
    [_subScroll endEditing:YES];
    [_host flowHostSetCardHidden:YES];
    _subDim.hidden = YES;   // 子浮窗也会被烤进冻结帧

    __weak typeof(self) weakSelf = self;
    [PickOverlay presentWithMode:type.pickMode completion:^(NSDictionary *result) {
        FlowWindow *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf applyPickResult:result toStep:step type:type];
        [strongSelf autosave];
        [strongSelf->_host flowHostSetCardHidden:NO];
        strongSelf->_subDim.hidden = NO;
        [strongSelf refresh];
        // 子浮窗还开着（参数页）就重建一遍，让「从屏幕取…」那行的回显更新
        if (strongSelf->_subDim && strongSelf->_subRebuilder) strongSelf->_subRebuilder();
    } cancel:^{
        FlowWindow *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf->_host flowHostSetCardHidden:NO];
        strongSelf->_subDim.hidden = NO;
    }];
}

- (void)applyPickResult:(NSDictionary *)result toStep:(NSMutableDictionary *)step type:(FlowStepType *)type {
    NSArray<NSString *> *targets = type.pickTargets;
    if (targets.count == 0) return;

    if (type.pickMode == FlowPickModePoint || type.pickMode == FlowPickModePath ||
        type.pickMode == FlowPickModeRect) {
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

// 取点按钮右侧的回显：已经取到的值
- (NSString *)pickDetailForStep:(NSDictionary *)step type:(FlowStepType *)type {
    NSArray<NSString *> *t = type.pickTargets;
    NSString *(^v)(NSUInteger) = ^NSString *(NSUInteger i) {
        return (i < t.count) ? [FlowScript textForValue:step[t[i]]] : @"";
    };
    switch (type.pickMode) {
        case FlowPickModePoint:
            return [NSString stringWithFormat:@"%@, %@", v(0), v(1)];
        case FlowPickModeColor:
            return [NSString stringWithFormat:@"%@, %@   #%@", v(0), v(1),
                    [FlowScript textForValue:step[@"Color"]]];
        case FlowPickModePath:
            return [NSString stringWithFormat:@"%@,%@ → %@,%@", v(0), v(1), v(2), v(3)];
        case FlowPickModeRect:
            return [NSString stringWithFormat:@"%@,%@ → %@,%@", v(0), v(1), v(2), v(3)];
        case FlowPickModeTemplate: {
            NSString *name = v(0);
            return name.length ? name : @"还没框选";
        }
        default:
            return nil;
    }
}

#pragma mark - 行控件

// 列表里的一行：序号 + 左侧色条 + 图标底 + 标题 / 细节 + 右侧把手
// deletable = 能左滑删除，sortable = 右侧把手拖动排序
- (FWStepRowView *)makeStepRow:(NSString *)title
                        detail:(NSString *)detail
                         index:(NSInteger)index
                        symbol:(NSString *)symbol
                         color:(UIColor *)color
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

    if (index >= 0) {
        UILabel *number = [[UILabel alloc] initWithFrame:CGRectMake(8, 0, 20, FW_ROW_H)];
        number.text = [NSString stringWithFormat:@"%ld", (long)index + 1];
        number.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
        number.textColor = ZXPalette(ZXPalSub);
        number.textAlignment = NSTextAlignmentCenter;
        [row.content addSubview:number];
        row.numberLabel = number;
    }

    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(34, 8, 3, FW_ROW_H - 16)];
    bar.backgroundColor = color;
    bar.layer.cornerRadius = 1.5;
    [row.content addSubview:bar];

    UIView *tile = [[UIView alloc] initWithFrame:CGRectMake(45, (FW_ROW_H - 26) / 2.0f, 26, 26)];
    tile.backgroundColor = [color colorWithAlphaComponent:0.16];
    tile.layer.cornerRadius = 8;
    [row.content addSubview:tile];

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.tintColor = color;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.frame = CGRectInset(tile.bounds, 5, 5);
    [tile addSubview:icon];

    CGFloat textX = 79.0f;
    CGFloat textW = MAX(w - textX - (sortable ? 34.0f : 12.0f), 60.0f);
    UILabel *main = [[UILabel alloc] initWithFrame:CGRectMake(textX, detail.length ? 3 : 0,
                                                              textW, detail.length ? 18 : FW_ROW_H)];
    main.text = title;
    main.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    main.textColor = ZXPalette(ZXPalText);
    main.adjustsFontSizeToFitWidth = YES;
    main.minimumScaleFactor = 0.8;
    [row.content addSubview:main];

    if (detail.length > 0) {
        UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(textX, 22, textW, 14)];
        sub.text = detail;
        sub.font = [UIFont systemFontOfSize:11];
        sub.textColor = ZXPalette(ZXPalSub);
        sub.adjustsFontSizeToFitWidth = YES;
        sub.minimumScaleFactor = 0.75;
        [row.content addSubview:sub];
    }

    if (sortable) [row installDragHandle];
    return row;
}

// 一整行的按钮：标题左对齐 + 右侧细节
// primary = 主操作（青绿底 + 青绿描边），否则就是一张普通卡片
- (UIView *)makeActionRow:(NSString *)title
                   detail:(NSString *)detail
                    color:(UIColor *)color
                  primary:(BOOL)primary
                    width:(CGFloat)w
                   action:(void (^)(void))action
{
    UIButton *row = [UIButton buttonWithType:UIButtonTypeSystem];
    CGFloat rowH = FW_ROW_H - 10.0f;
    row.frame = CGRectMake(0, 0, w, rowH);
    row.backgroundColor = primary ? [color colorWithAlphaComponent:0.16] : ZXPalette(ZXPalRow);
    row.layer.cornerRadius = 10;
    row.layer.borderWidth = 1;
    row.layer.borderColor = (primary ? [color colorWithAlphaComponent:0.55] : ZXPalette(ZXPalLine)).CGColor;

    // 标题和右侧细节都自己摆：按钮自带的 titleLabel 没法定宽，窄面板上会和细节叠字
    CGFloat detailW = (detail.length > 0) ? MAX(w * 0.52f, 90.0f) : 0;
    UILabel *main = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, MAX(w - 28 - detailW - 8, 60), rowH)];
    main.text = title;
    main.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    main.textColor = primary ? color : ZXPalette(ZXPalText);
    main.adjustsFontSizeToFitWidth = YES;
    main.minimumScaleFactor = 0.75;
    main.userInteractionEnabled = NO;
    [row addSubview:main];

    if (detail.length > 0) {
        UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(w - 14 - detailW, 0, detailW, rowH)];
        sub.text = detail;
        sub.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
        sub.textColor = primary ? color : ZXPalette(ZXPalValue);
        sub.textAlignment = NSTextAlignmentRight;
        sub.adjustsFontSizeToFitWidth = YES;
        sub.minimumScaleFactor = 0.7;
        sub.userInteractionEnabled = NO;
        [row addSubview:sub];
    }

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
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, FW_ROW_H - 10.0f)];
    row.backgroundColor = ZXPalette(ZXPalRow);
    row.layer.cornerRadius = 10;
    row.layer.borderWidth = 1;
    row.layer.borderColor = ZXPalette(ZXPalLine).CGColor;

    CGFloat labelW = MIN(150.0f, w * 0.46f);
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, labelW, row.frame.size.height)];
    label.text = title;
    label.font = [UIFont systemFontOfSize:13];
    label.textColor = ZXPalette(ZXPalSub);
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.75;
    [row addSubview:label];

    CGFloat fieldX = 12 + labelW + 6;
    CGFloat fieldH = row.frame.size.height - 12.0f;
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(fieldX, 6, MAX(w - fieldX - 12, 60), fieldH)];
    field.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    field.textColor = ZXPalette(ZXPalValue);
    field.tintColor = ZXPalette(ZXPalAccent);
    field.backgroundColor = ZXPalette(ZXPalField);
    field.layer.cornerRadius = 8;
    field.layer.borderColor = ZXPalette(ZXPalLine).CGColor;
    field.layer.borderWidth = 1;
    field.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    field.keyboardType = integer ? UIKeyboardTypeDecimalPad : UIKeyboardTypeDefault;
    field.inputAccessoryView = [self keyboardAccessory];
    field.textAlignment = NSTextAlignmentLeft;
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
    [_scroll endEditing:YES];
    [_subScroll endEditing:YES];
}

#pragma mark - 子浮窗（屏幕中间：添加步骤 / 编辑参数 / 设置都走这里）

// builder 往内容区铺控件（x 从 8 开始，宽 width），返回内容总高度；卡片高度按内容夹到一屏以内
- (void)showSubWithTitle:(NSString *)title builder:(CGFloat (^)(UIScrollView *content, CGFloat width))builder {
    [self dismissSubAnimated:NO];
    UIView *host = [_host flowHostOverlayContainer];
    if (!host || !builder) return;

    CGFloat hostW = MAX(host.bounds.size.width, 240.0f);
    CGFloat hostH = MAX(host.bounds.size.height, 320.0f);
    CGFloat cardW = MIN(hostW - 72.0f, 400.0f);
    CGFloat titleH = 46.0f;

    UIView *dim = [[UIView alloc] initWithFrame:host.bounds];

    // 轻遮罩：还能看见后面的主流程（点外面 = 关掉）。铺满按钮当遮罩，不和面板上的按钮抢触摸
    UIButton *backdrop = [UIButton buttonWithType:UIButtonTypeCustom];
    backdrop.frame = dim.bounds;
    backdrop.backgroundColor = [UIColor colorWithWhite:0 alpha:0.15];
    [backdrop addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        [self dismissSubAnimated:YES];
    }] forControlEvents:UIControlEventTouchUpInside];
    [dim addSubview:backdrop];

    UIView *card = [[UIView alloc] init];
    card.backgroundColor = ZXPalette(ZXPalCard);
    card.layer.cornerRadius = 14;
    card.layer.borderWidth = 1;
    card.layer.borderColor = ZXPalette(ZXPalLine).CGColor;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.25f;
    card.layer.shadowRadius = 14;
    card.layer.shadowOffset = CGSizeMake(0, 4);
    card.clipsToBounds = YES;
    [dim addSubview:card];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, cardW - 28 - 40, titleH)];
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    titleLabel.textColor = ZXPalette(ZXPalText);
    [card addSubview:titleLabel];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(cardW - 40, (titleH - 28) / 2.0f, 28, 28);
    close.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    close.backgroundColor = ZXPalette(ZXPalField);
    close.layer.cornerRadius = 14;
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:ZXPalette(ZXPalSub) forState:UIControlStateNormal];
    [close addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        [self dismissSubAnimated:YES];
    }] forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:close];

    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(0, titleH - 1, cardW, 1)];
    sep.backgroundColor = ZXPalette(ZXPalLine);
    [card addSubview:sep];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    [card addSubview:scroll];

    _subDim = dim;
    _subScroll = scroll;

    CGFloat contentH = builder(scroll, cardW - 16.0f);
    CGFloat bodyH = MIN(contentH + 4.0f, hostH - 140.0f - titleH);
    if (bodyH < 60.0f) bodyH = 60.0f;
    CGFloat cardH = titleH + bodyH;
    card.frame = CGRectMake((hostW - cardW) / 2.0f, (hostH - cardH) / 2.0f, cardW, cardH);
    scroll.frame = CGRectMake(0, titleH, cardW, bodyH);
    scroll.contentSize = CGSizeMake(cardW, contentH + 4.0f);

    [host addSubview:dim];
    dim.alpha = 0;
    card.transform = CGAffineTransformMakeScale(0.92f, 0.92f);
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        dim.alpha = 1;
        card.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)dismissSubAnimated:(BOOL)animated {
    UIView *dim = _subDim;
    _subDim = nil;
    _subScroll = nil;
    _subRebuilder = nil;
    if (!dim) return;
    if (!animated) {
        [dim removeFromSuperview];
        return;
    }
    [UIView animateWithDuration:0.15 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        dim.alpha = 0;
    } completion:^(BOOL finished) {
        [dim removeFromSuperview];
    }];
}

// 面板整体收起（点 ✕ / 隐藏）时把子浮窗一起收掉，否则它会飘在游戏上
- (void)hideOverlays {
    [self dismissSubAnimated:NO];
}

// 子浮窗里铺一行的帮手：x=8，往下排
- (CGFloat)subAddRow:(UIView *)row y:(CGFloat)y {
    row.frame = CGRectMake(8, y, row.frame.size.width, row.frame.size.height);
    [_subScroll addSubview:row];
    return y + row.frame.size.height + FW_GAP;
}

- (CGFloat)subAddSection:(NSString *)text width:(CGFloat)w y:(CGFloat)y {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12, y, w - 8, 18)];
    label.text = text;
    label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    label.textColor = ZXPalette(ZXPalSub);
    [_subScroll addSubview:label];
    return y + 24;
}

#pragma mark - 子浮窗：添加步骤

- (void)showAddSheet {
    BOOL branch = [_stack.lastObject[@"branch"] boolValue];
    NSArray<FlowStepType *> *all = branch ? [FlowScript simpleStepTypes] : [FlowScript allStepTypes];
    NSMutableArray<FlowStepType *> *actions = [NSMutableArray array];
    NSMutableArray<FlowStepType *> *conditions = [NSMutableArray array];
    for (FlowStepType *type in all) {
        [(type.isCondition ? conditions : actions) addObject:type];
    }
    if (all.count == 0) return;

    NSMutableArray<NSDictionary *> *groups = [NSMutableArray array];
    if (actions.count > 0) [groups addObject:@{ @"title": @"触摸动作", @"types": actions }];
    if (conditions.count > 0) [groups addObject:@{ @"title": @"判断条件", @"types": conditions }];

    __weak typeof(self) weakSelf = self;
    [self showSubWithTitle:@"添加步骤" builder:^CGFloat(UIScrollView *content, CGFloat w) {
        CGFloat cellGap = 8.0f;
        CGFloat cellW = floor((w - cellGap) / 2.0f);
        CGFloat y = 8.0f;

        for (NSDictionary *group in groups) {
            UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12, y, w - 8, 18)];
            label.text = group[@"title"];
            label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
            label.textColor = ZXPalette(ZXPalSub);
            [content addSubview:label];
            y += 26.0f;

            NSArray<FlowStepType *> *types = group[@"types"];
            for (NSUInteger i = 0; i < types.count; i++) {
                FlowStepType *type = types[i];
                NSInteger col = (NSInteger)(i % 2);
                NSInteger line = (NSInteger)(i / 2);
                UIButton *cell = [UIButton buttonWithType:UIButtonTypeSystem];
                cell.frame = CGRectMake(8 + col * (cellW + cellGap), y + line * (FW_CELL_H + cellGap),
                                        cellW, FW_CELL_H);
                cell.backgroundColor = ZXPalette(ZXPalRow);
                cell.layer.cornerRadius = 12;
                cell.layer.borderWidth = 1;
                cell.layer.borderColor = ZXPalette(ZXPalLine).CGColor;

                UIColor *color = fwTypeColor(type.kind);
                UIView *tile = [[UIView alloc] initWithFrame:CGRectMake(12, (FW_CELL_H - 26) / 2.0f, 26, 26)];
                tile.backgroundColor = [color colorWithAlphaComponent:0.16];
                tile.layer.cornerRadius = 8;
                tile.userInteractionEnabled = NO;
                [cell addSubview:tile];

                UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:type.symbolName]];
                icon.tintColor = color;
                icon.contentMode = UIViewContentModeScaleAspectFit;
                icon.frame = CGRectInset(tile.bounds, 5, 5);
                [tile addSubview:icon];

                UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(46, 0, MAX(cellW - 54, 40), FW_CELL_H)];
                name.text = type.title;
                name.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
                name.textColor = ZXPalette(ZXPalText);
                name.adjustsFontSizeToFitWidth = YES;
                name.minimumScaleFactor = 0.8;
                name.userInteractionEnabled = NO;
                [cell addSubview:name];

                NSString *kind = type.kind;
                [cell addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
                    FlowWindow *strongSelf = weakSelf;
                    if (!strongSelf) return;
                    [strongSelf dismissSubAnimated:NO];
                    [strongSelf addStepOfKind:kind];
                }] forControlEvents:UIControlEventTouchUpInside];
                [content addSubview:cell];
            }
            NSInteger lines = (NSInteger)ceil((double)types.count / 2.0);
            y += lines * FW_CELL_H + (lines - 1) * cellGap + 14.0f;
        }
        return y;
    }];
}

#pragma mark - 子浮窗：某一步的参数

- (void)showParamsSubForStep:(NSMutableDictionary *)step parentSteps:(NSMutableArray *)parentSteps {
    FlowStepType *type = [FlowScript typeForKind:step[@"Kind"]];
    if (!type) return;

    __weak typeof(self) weakSelf = self;
    [self showSubWithTitle:type.title ?: @"步骤" builder:^CGFloat(UIScrollView *content, CGFloat w) {
        FlowWindow *strongSelf = weakSelf;
        if (!strongSelf) return 0.0f;
        CGFloat y = 8.0f;

        if (type.pickMode != FlowPickModeNone) {
            UIView *pick = [strongSelf makeActionRow:type.pickActionTitle
                                              detail:[strongSelf pickDetailForStep:step type:type]
                                               color:ZXPalette(ZXPalAccent) primary:YES width:w
                                              action:^{ [strongSelf beginPickingForStep:step type:type]; }];
            y = [strongSelf subAddRow:pick y:y];
        }

        NSArray<NSDictionary<NSString *, id> *> *groups = fwGroupsForKind(step[@"Kind"]);
        NSMutableSet<NSString *> *used = [NSMutableSet set];
        // 取点行已经承载了这些字段（坐标 / 模板名），下面不再重复铺输入框
        [used addObjectsFromArray:type.pickTargets];
        for (NSDictionary<NSString *, id> *group in groups) {
            NSMutableArray<FlowFieldSpec *> *specs = [NSMutableArray array];
            for (NSString *key in group[@"keys"]) {
                if ([used containsObject:key]) continue;
                FlowFieldSpec *spec = [strongSelf specForKey:key inType:type];
                if (spec) { [specs addObject:spec]; [used addObject:key]; }
            }
            if (specs.count == 0) continue;
            y += 4;
            y = [strongSelf subAddSection:group[@"title"] width:w y:y];
            for (FlowFieldSpec *spec in specs) {
                y = [strongSelf subAddRow:[strongSelf fieldRowForSpec:spec step:step width:w] y:y];
            }
        }
        // 兜底：分组表没列到的字段也要显示出来，别让参数凭空消失
        NSMutableArray<FlowFieldSpec *> *rest = [NSMutableArray array];
        for (FlowFieldSpec *spec in type.fields) {
            if (![used containsObject:spec.key]) [rest addObject:spec];
        }
        if (rest.count > 0) {
            y += 4;
            y = [strongSelf subAddSection:@"其他" width:w y:y];
            for (FlowFieldSpec *spec in rest) {
                y = [strongSelf subAddRow:[strongSelf fieldRowForSpec:spec step:step width:w] y:y];
            }
        }

        if (type.isCondition) {
            y += 6;
            y = [strongSelf subAddSection:@"成立 / 不成立时要做什么" width:w y:y];
            NSArray<NSString *> *keys = @[ @"Then", @"Else" ];
            NSArray<NSString *> *titles = @[ @"成立时", @"不成立时" ];
            for (NSInteger i = 0; i < 2; i++) {
                NSString *key = keys[i];
                NSArray *branchSteps = [step[key] isKindOfClass:[NSArray class]] ? step[key] : @[];
                NSString *detail = [NSString stringWithFormat:@"%lu 个动作", (unsigned long)branchSteps.count];
                NSString *branchTitle = titles[i];
                UIView *row = [strongSelf makeActionRow:branchTitle detail:detail color:ZXPalette(ZXPalText)
                                                primary:NO width:w
                                                 action:^{
                                                     FlowWindow *s = weakSelf;
                                                     if (!s) return;
                                                     [s dismissSubAnimated:NO];
                                                     [s pushBranchPageForStep:step key:key title:branchTitle];
                                                 }];
                y = [strongSelf subAddRow:row y:y];
            }
        }

        y += 8;
        UIView *deleteRow = [strongSelf makeActionRow:@"删除这一步" detail:nil color:ZXPalette(ZXPalDanger)
                                              primary:NO width:w
                                               action:^{
                                                   FlowWindow *s = weakSelf;
                                                   if (!s) return;
                                                   [parentSteps removeObjectIdenticalTo:step];
                                                   [s autosave];
                                                   [s dismissSubAnimated:NO];
                                                   [s refresh];
                                               }];
        y = [strongSelf subAddRow:deleteRow y:y];
        return y;
    }];

    // 取点回来后重建这个子浮窗（回显新坐标 / 新模板名）
    _subRebuilder = ^{
        FlowWindow *strongSelf = weakSelf;
        if (strongSelf) [strongSelf showParamsSubForStep:step parentSteps:parentSteps];
    };
}

#pragma mark - 子浮窗：设置（运行方式 + 定时，全都改完即存）

- (void)showSettings {
    if (_bundlePath.length == 0 || !_flow) return;

    // 从 info.plist 读当前的定时设置（默认值和 App 的设置页一致）
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                          [_bundlePath stringByAppendingPathComponent:@"info.plist"]];
    NSDictionary *schedule = [info[kScheduleKey] isKindOfClass:[NSDictionary class]] ? info[kScheduleKey] : nil;

    __block NSString *startMode = [schedule[kStartMode] isEqual:kModeDaily] ? kModeDaily : kModeManual;
    __block NSString *startTime = fwNormalizeTime(schedule[kStartTime]) ?: @"09:00";
    __block NSMutableArray<NSNumber *> *weekdays = [NSMutableArray array];
    for (id value in schedule[kWeekdays]) {
        if ([value isKindOfClass:[NSNumber class]]) [weekdays addObject:value];
    }
    __block NSString *endMode = kModeManual;
    if ([schedule[kEndMode] isEqualToString:kModeDuration]) endMode = kModeDuration;
    else if ([schedule[kEndMode] isEqualToString:kModeDaily]) endMode = kModeDaily;
    __block NSInteger durationMinutes = [schedule[kDurationMinutes] integerValue] ?: 30;
    __block NSString *endTime = fwNormalizeTime(schedule[kEndTime]) ?: @"23:00";

    __weak typeof(self) weakSelf = self;
    void (^persist)(void) = ^{
        FlowWindow *strongSelf = weakSelf;
        if (!strongSelf) return;
        fwPersistSchedule(strongSelf->_bundlePath, startMode, startTime, weekdays,
                          endMode, durationMinutes, endTime);
    };

    [self showSubWithTitle:@"设置" builder:^CGFloat(UIScrollView *content, CGFloat w) {
        FlowWindow *strongSelf = weakSelf;
        if (!strongSelf) return 0.0f;
        CGFloat y = 8.0f;

        // ---- 运行方式：写 flow.plist（随流程一起生成 main.py）----
        y = [strongSelf subAddSection:@"运行方式" width:w y:y];
        UIView *loopTimes = [strongSelf makeValueRow:@"循环次数（0 = 一直循环）" value:strongSelf->_flow[@"LoopTimes"]
                                             integer:YES width:w
                                            onChange:^(NSString *text) {
                                                FlowWindow *s = weakSelf;
                                                if (!s) return;
                                                s->_flow[@"LoopTimes"] = [FlowScript valueFromText:text integer:YES];
                                                [s autosave];
                                            }];
        y = [strongSelf subAddRow:loopTimes y:y];
        UIView *loopInterval = [strongSelf makeValueRow:@"每轮之间停（秒）" value:strongSelf->_flow[@"LoopInterval"]
                                               integer:NO width:w
                                              onChange:^(NSString *text) {
                                                  FlowWindow *s = weakSelf;
                                                  if (!s) return;
                                                  s->_flow[@"LoopInterval"] = [FlowScript valueFromText:text integer:NO];
                                                  [s autosave];
                                              }];
        y = [strongSelf subAddRow:loopInterval y:y];

        // ---- 定时启动 ----
        y += 6;
        y = [strongSelf subAddSection:@"定时启动" width:w y:y];
        NSArray<NSString *> *startTitles = @[ @"手动", @"每天定时" ];
        NSArray<NSString *> *startModes = @[ kModeManual, kModeDaily ];
        for (NSInteger i = 0; i < 2; i++) {
            BOOL selected = [startMode isEqualToString:startModes[i]];
            NSString *mode = startModes[i];
            UIView *row = [strongSelf makeActionRow:startTitles[i] detail:(selected ? @"✓" : nil)
                                              color:ZXPalette(ZXPalAccent) primary:selected width:w
                                             action:^{
                                                 startMode = mode;
                                                 persist();
                                                 [weakSelf showSettings];   // 可见的行跟着模式变，重铺一遍
                                             }];
            y = [strongSelf subAddRow:row y:y];
        }
        if ([startMode isEqualToString:kModeDaily]) {
            UIView *timeRow = [strongSelf makeValueRow:@"启动时间（如 09:30）" value:startTime integer:NO width:w
                                              onChange:^(NSString *text) {
                                                  NSString *t = fwNormalizeTime(text);
                                                  if (!t) return;   // 不合法先不写，用户还在输
                                                  startTime = t;
                                                  persist();
                                              }];
            y = [strongSelf subAddRow:timeRow y:y];

            // 周日 ~ 周七个小圆块，选中亮色；一个都不选 = 每天
            y = [strongSelf subAddSection:@"重复（都不选 = 每天）" width:w y:y];
            NSArray<NSString *> *dayTitles = @[ @"日", @"一", @"二", @"三", @"四", @"五", @"六" ];
            CGFloat chipGap = 6.0f;
            CGFloat chipW = floor((w - chipGap * 6) / 7.0f);
            UIView *chipRow = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 32)];
            for (NSInteger i = 0; i < 7; i++) {
                NSNumber *day = @(i + 1);   // 1 = 周日
                BOOL on = [weekdays containsObject:day];
                UIButton *chip = [UIButton buttonWithType:UIButtonTypeSystem];
                chip.frame = CGRectMake(i * (chipW + chipGap), 0, chipW, 32);
                chip.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
                chip.layer.cornerRadius = 16;
                chip.layer.borderWidth = 1;
                [chip setTitle:dayTitles[i] forState:UIControlStateNormal];
                void (^paint)(UIButton *, BOOL) = ^(UIButton *c, BOOL isOn) {
                    c.backgroundColor = isOn ? [ZXPalette(ZXPalAccent) colorWithAlphaComponent:0.20] : ZXPalette(ZXPalField);
                    c.layer.borderColor = (isOn ? ZXPalette(ZXPalAccent) : ZXPalette(ZXPalLine)).CGColor;
                    [c setTitleColor:(isOn ? ZXPalette(ZXPalAccent) : ZXPalette(ZXPalSub)) forState:UIControlStateNormal];
                };
                paint(chip, on);
                [chip addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
                    BOOL nowOn = ![weekdays containsObject:day];
                    if (nowOn) [weekdays addObject:day]; else [weekdays removeObject:day];
                    paint(chip, nowOn);
                    persist();
                }] forControlEvents:UIControlEventTouchUpInside];
                [chipRow addSubview:chip];
            }
            y = [strongSelf subAddRow:chipRow y:y];
        }

        // ---- 定时结束 ----
        y += 6;
        y = [strongSelf subAddSection:@"定时结束" width:w y:y];
        NSArray<NSString *> *endTitles = @[ @"手动", @"跑够时长", @"到点停" ];
        NSArray<NSString *> *endModes = @[ kModeManual, kModeDuration, kModeDaily ];
        for (NSInteger i = 0; i < 3; i++) {
            BOOL selected = [endMode isEqualToString:endModes[i]];
            NSString *mode = endModes[i];
            UIView *row = [strongSelf makeActionRow:endTitles[i] detail:(selected ? @"✓" : nil)
                                              color:ZXPalette(ZXPalAccent) primary:selected width:w
                                             action:^{
                                                 endMode = mode;
                                                 persist();
                                                 [weakSelf showSettings];
                                             }];
            y = [strongSelf subAddRow:row y:y];
        }
        if ([endMode isEqualToString:kModeDuration]) {
            UIView *durRow = [strongSelf makeValueRow:@"跑够多少分钟" value:@(durationMinutes) integer:YES width:w
                                             onChange:^(NSString *text) {
                                                 NSInteger m = [[FlowScript valueFromText:text integer:YES] integerValue];
                                                 if (m <= 0) return;
                                                 durationMinutes = m;
                                                 persist();
                                             }];
            y = [strongSelf subAddRow:durRow y:y];
        } else if ([endMode isEqualToString:kModeDaily]) {
            UIView *endRow = [strongSelf makeValueRow:@"结束时间（如 23:00）" value:endTime integer:NO width:w
                                            onChange:^(NSString *text) {
                                                NSString *t = fwNormalizeTime(text);
                                                if (!t) return;
                                                endTime = t;
                                                persist();
                                            }];
            y = [strongSelf subAddRow:endRow y:y];
        }

        return y;
    }];

    // 模式切换后重铺 = 重新走一遍 showSettings（数据刚 persist 过，重读是一致的）
    _subRebuilder = ^{
        FlowWindow *strongSelf = weakSelf;
        if (strongSelf) [strongSelf showSettings];
    };
}

#pragma mark - 内容刷新

- (CGFloat)addRow:(UIView *)row y:(CGFloat)y {
    row.frame = CGRectMake(4, y, row.frame.size.width, row.frame.size.height);
    [_scroll addSubview:row];
    return y + row.frame.size.height + FW_GAP;
}

- (FlowFieldSpec *)specForKey:(NSString *)key inType:(FlowStepType *)type {
    for (FlowFieldSpec *spec in type.fields) {
        if ([spec.key isEqualToString:key]) return spec;
    }
    return nil;
}

- (UIView *)fieldRowForSpec:(FlowFieldSpec *)spec step:(NSMutableDictionary *)step width:(CGFloat)w {
    NSString *key = spec.key;
    BOOL integer = spec.integer;
    __weak typeof(self) weakSelf = self;
    return [self makeValueRow:spec.title value:step[key] integer:integer width:w
                     onChange:^(NSString *text) {
                         step[key] = [FlowScript valueFromText:text integer:integer];
                         [weakSelf autosave];   // 每敲一个字都落盘
                     }];
}

- (void)refresh {
    if (!_host) return;
    UIScrollView *scroll = [_host flowHostScrollView];
    if (!scroll) return;
    _scroll = scroll;
    _pw = [_host flowHostContentWidth];

    NSMutableDictionary *page = _stack.lastObject;
    if (!page) return;
    CGFloat rowW = _pw - 8;

    [scroll endEditing:YES];
    for (UIView *v in scroll.subviews) [v removeFromSuperview];
    _rows = [NSMutableArray array];   // 每次重建都清空：换页后旧行不该再被排序逻辑引用
    _dragRow = nil;

    BOOL isRoot = [page[@"isRoot"] boolValue];
    [_host flowHostSetNavigationTitle:page[@"title"] canGoBack:!isRoot];

    BOOL animate = _animateTransition;
    _animateTransition = NO;

    CGFloat y = 8;

    NSArray *steps = page[@"steps"];
    if (steps.count == 0) {
        UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(12, y, _pw - 24, 38)];
        hint.numberOfLines = 0;
        hint.font = [UIFont systemFontOfSize:12];
        hint.textColor = ZXPalette(ZXPalSub);
        hint.text = isRoot ? @"还没有步骤。点下面的「添加步骤」开始拼一条流程。"
                           : @"这一支还没有动作。";
        [_scroll addSubview:hint];
        y += 46;
    } else {
        _rowsTop = y;
        for (NSInteger i = 0; i < (NSInteger)steps.count; i++) {
            NSDictionary *step = steps[i];
            if (![step isKindOfClass:[NSDictionary class]]) continue;
            FlowStepType *type = [FlowScript typeForKind:step[@"Kind"]];
            __weak typeof(self) weakSelf = self;
            FWStepRowView *row = [self makeStepRow:[FlowScript summaryForStep:step]
                                            detail:[FlowScript detailForStep:step]
                                             index:i
                                            symbol:type.symbolName
                                             color:fwTypeColor(type.kind)
                                         deletable:YES
                                          sortable:YES
                                             width:rowW
                                             onTap:^{
                                                 [weakSelf showParamsSubForStep:(NSMutableDictionary *)step
                                                                   parentSteps:[weakSelf currentSteps]];
                                             }
                                          onDelete:^{
                                              [weakSelf deleteStep:(NSMutableDictionary *)step];
                                          }];
            __weak FWStepRowView *weakRow = row;   // 行持有 block、block 又持有行 → 这里必须弱引用，否则漏一组视图
            row.onCopy = ^{ [weakSelf showCopyMenuForRow:weakRow step:(NSMutableDictionary *)step]; };
            row.onDragBegan = ^{ [weakSelf beginDragRow:weakRow]; };
            row.onDragMoved = ^(CGFloat dy) { [weakSelf moveDragRow:weakRow dy:dy]; };
            row.onDragEnded = ^{ [weakSelf endDragRow]; };
            row.step = step;
            [_rows addObject:row];
            y = [self addRow:row y:y];
        }
    }

    UIView *add = [self makeActionRow:@"＋  添加步骤" detail:nil color:ZXPalette(ZXPalAccent) primary:YES
                                width:rowW action:^{ [self showAddSheet]; }];
    y = [self addRow:add y:y];

    scroll.contentSize = CGSizeMake(_pw, y + 8);
    [scroll setContentOffset:CGPointZero animated:NO];

    if (animate) {
        scroll.alpha = 0;
        scroll.transform = CGAffineTransformMakeTranslation(0, 8);
        [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            scroll.alpha = 1;
            scroll.transform = CGAffineTransformIdentity;
        } completion:nil];
    }
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

    // 编辑器就在选项面板里，所以「打开可视化编辑」= 让面板切到流程编辑模式
    if ([action isEqualToString:@"new"]) {
        [[FunctionWindow shared] createFlowScriptAtPath:path];
    } else {
        [[FunctionWindow shared] openFlowBundle:path];
    }
    return @"0\r\n";
}
