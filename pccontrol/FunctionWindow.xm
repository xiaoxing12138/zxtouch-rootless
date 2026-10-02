#import "FunctionWindow.h"
#import "FloatingMenu.h"      // FMPassthroughWindow + preferredWindowScene
#import "Common.h"            // ZXSafeMainAsync / getScriptsFolder
#import "ScriptFunctions.h"
#import "AlertBox.h"
#import "Play.h"
#import <UIKit/UIKit.h>

#define FN_BTN_H     40.0f
#define FN_TOP_H     49.0f
#define FN_CARD_W    540.0f   // 卡片宽度：要装下「名称 + 4 个参数框 + 开关」一整行（屏幕不够宽时按屏宽自动缩）
#define FN_NAME_W    104.0f   // 功能名宽度：能站下 7 个中文字（14pt 字号）

// window 内空白区域透传：只有真正落在卡片子视图上的触摸才拦截，
// 卡片外的点击落到下层 App。
@interface FNPassthroughView : UIView
@end

@implementation FNPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}
@end

@interface FNRootViewController : UIViewController
@end

@implementation FNRootViewController
- (void)loadView {
    FNPassthroughView *root = [[FNPassthroughView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    root.backgroundColor = [UIColor clearColor];
    self.view = root;
}
@end

static UIButton *fnMakeButton(NSString *title, UIColor *color) {
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

static UIImage *fnSymbol(NSString *name) {
    if (@available(iOS 13.0, *)) {
        return [UIImage systemImageNamed:name];
    }
    return nil;
}

@implementation FunctionWindow
{
    UIWindow        *_window;
    UIView          *_cardView;
    UIScrollView    *_functionScrollView;
    UIButton        *_functionScriptBtn;
    UIButton        *_closeBtn;
    UIButton        *_saveBtn;
    UIButton        *_runBtn;

    NSArray<NSString *>        *_functionNames;
    NSMutableArray<UISwitch *> *_functionSwitches;
    NSString                   *_functionScriptPath;
    NSMutableDictionary<NSString *, NSString *> *_functionOptionValues;  // 选项名 → 当前值
    // 功能名 → 参数名 → 当前值（x/y/延迟/次数 这些，声明了才在面板上出现）
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSString *> *> *_functionParamValues;
    BOOL                        _pickingScript;   // 正在挑「功能」页要用的脚本
    BOOL                        _shown;
    CGFloat                     _contentHeight;   // 卡片中间滚动区的内容高度（用于自适应卡片高度）
}

+ (instancetype)shared {
    static FunctionWindow *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[FunctionWindow alloc] init];
    });
    return shared;
}

- (id)init {
    self = [super init];
    if (self) {
        _functionOptionValues = [NSMutableDictionary dictionary];
        _functionParamValues = [NSMutableDictionary dictionary];
        _pickingScript = NO;
        _shown = NO;
        _contentHeight = 0;
    }
    return self;
}

#pragma mark - window / 卡片构建

- (void)ensureWindow {
    if (_window) return;
    [self buildWindow];
}

- (void)buildWindow {
    // iOS 13+ 必须用 initWithWindowScene:，initWithFrame: 创建的窗口不会显示
    UIWindowScene *scene = [FloatingMenu preferredWindowScene];
    if (scene) {
        _window = [[FMPassthroughWindow alloc] initWithWindowScene:scene];
    } else {
        _window = [[FMPassthroughWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    }
    _window.windowLevel = UIWindowLevelAlert + 1;
    _window.backgroundColor = [UIColor clearColor];

    _window.rootViewController = [[FNRootViewController alloc] init];
    UIView *root = _window.rootViewController.view;

    // 居中卡片（frame 由 layoutCard 计算，autoresizing 保证旋转后仍居中）
    _cardView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, FN_CARD_W, 200)];
    _cardView.backgroundColor = [UIColor systemBackgroundColor];
    _cardView.layer.cornerRadius = 14;
    _cardView.layer.borderColor = [UIColor separatorColor].CGColor;
    _cardView.layer.borderWidth = 1;
    _cardView.clipsToBounds = YES;
    _cardView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin
                               | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [root addSubview:_cardView];

    // 顶行：当前脚本（点一下去挑脚本）+ 右上角 ✕
    _functionScriptBtn = fnMakeButton(@"脚本：", [UIColor systemBlueColor]);
    _functionScriptBtn.frame = CGRectMake(8, 6, FN_CARD_W - 8 - 40 - 6, 36);
    _functionScriptBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    _functionScriptBtn.titleLabel.adjustsFontSizeToFitWidth = YES;   // 脚本名长了缩字号
    _functionScriptBtn.titleLabel.minimumScaleFactor = 0.8;
    _functionScriptBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [_functionScriptBtn setImage:fnSymbol(@"list.bullet") forState:UIControlStateNormal];
    [_functionScriptBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        if (self->_pickingScript) {
            // 再点一下 = 放弃挑选，回到功能页
            self->_pickingScript = NO;
            [self reloadFunctionPage];
        } else {
            [self beginScriptPicking];
        }
    }] forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_functionScriptBtn];

    _closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _closeBtn.frame = CGRectMake(FN_CARD_W - 40, 6, 32, 36);
    _closeBtn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _closeBtn.backgroundColor = [UIColor secondarySystemBackgroundColor];
    _closeBtn.layer.cornerRadius = 8;
    [_closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [_closeBtn setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    [_closeBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        [self hide];   // ✕：只关闭，不额外存盘
    }] forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_closeBtn];

    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(0, FN_TOP_H - 1, FN_CARD_W, 1)];
    sep.backgroundColor = [UIColor separatorColor];
    sep.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_cardView addSubview:sep];

    // 中间：选项 + 功能（可滚动）
    _functionScrollView = [[UIScrollView alloc] initWithFrame:CGRectMake(0, FN_TOP_H, FN_CARD_W, 160)];
    _functionScrollView.backgroundColor = [UIColor clearColor];
    _functionScrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_cardView addSubview:_functionScrollView];

    // 顶行右侧：运行 / 保存（都在 ✕ 左边，位置在 layoutCard 里排）
    _runBtn = fnMakeButton(@"运行", [UIColor systemGreenColor]);
    _runBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _runBtn.backgroundColor = [UIColor.systemGreenColor colorWithAlphaComponent:0.14];
    [_runBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        [self runFunctionSelection];
    }] forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_runBtn];

    _saveBtn = fnMakeButton(@"保存", [UIColor systemBlueColor]);
    _saveBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [_saveBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        [self saveAndHide];   // 存「选项值 + 功能参数 + 功能勾选」再关闭
    }] forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_saveBtn];

    [self layoutCard];

    // 建好后先隐藏，等 show 时再显示
    _window.hidden = YES;

    // 旋转后居中 / 重排（卡片宽度取 FN_CARD_W 与屏幕宽度 - 40 的较小值，需按新尺寸重算）
    [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceOrientationDidChangeNotification
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            if (!self->_shown) return;
            [self persistAllValues];
            if (self->_pickingScript) [self reloadScriptPicker];
            else [self reloadFunctionPage];
        }];
}

- (CGFloat)cardWidth {
    CGFloat screenW = _window ? _window.bounds.size.width : [UIScreen mainScreen].bounds.size.width;
    if (screenW <= 0) screenW = 375.0f;
    CGFloat w = MIN(FN_CARD_W, screenW - 40.0f);
    if (w < 200.0f) w = MAX(screenW - 20.0f, 200.0f);
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

    // 高度按内容自适应，不超过屏幕高度的 72%（底部不再放按钮，高度就是 顶行 + 内容）
    CGFloat maxH = screenH * 0.72f;
    CGFloat cardH = FN_TOP_H + _contentHeight;
    if (cardH > maxH) cardH = maxH;
    CGFloat minH = FN_TOP_H + 60.0f;
    if (cardH < minH) cardH = minH;
    if (cardH > screenH - 40.0f) cardH = screenH - 40.0f;
    if (cardH < 100.0f) cardH = 100.0f;

    _cardView.frame = CGRectMake((screenW - cardW) / 2.0f, (screenH - cardH) / 2.0f, cardW, cardH);

    // 顶行从右往左排：✕ / 保存 / 运行，剩下的左边给脚本选择（约占卡片 1/3）
    CGFloat topY = 6.0f, topH = 36.0f, gap = 6.0f;
    CGFloat rightX = cardW - 8.0f;
    _closeBtn.frame = CGRectMake(rightX - 32.0f, topY, 32.0f, topH);
    rightX -= (32.0f + gap);
    _saveBtn.frame = CGRectMake(rightX - 64.0f, topY, 64.0f, topH);
    rightX -= (64.0f + gap);
    _runBtn.frame = CGRectMake(rightX - 64.0f, topY, 64.0f, topH);
    rightX -= (64.0f + gap);

    CGFloat scriptW = cardW / 3.0f;
    if (8.0f + scriptW > rightX - 6.0f) scriptW = MAX(rightX - 6.0f - 8.0f, 80.0f);
    _functionScriptBtn.frame = CGRectMake(8, topY, scriptW, topH);

    _functionScrollView.frame = CGRectMake(0, FN_TOP_H, cardW, MAX(cardH - FN_TOP_H, 0));
}

#pragma mark - 选项控件

// 输入框弹出键盘时，键盘上方的「完成」条
- (UIView *)optionKeyboardAccessory {
    UIToolbar *bar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UIBarButtonItem *space = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                          target:nil action:nil];
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                                             style:UIBarButtonItemStylePlain
                                                            target:self
                                                            action:@selector(dismissOptionKeyboard)];
    bar.items = @[space, done];
    return bar;
}

- (void)dismissOptionKeyboard {
    [_cardView endEditing:YES];
}

// 把当前选项值存回 plist（切脚本 / 关闭 / 运行 / 输入框失焦时调用）
- (void)persistOptionValues {
    if (_functionScriptPath.length == 0) return;
    if (_functionOptionValues.count == 0) return;
    ZXSaveScriptOptionValues(_functionScriptPath, _functionOptionValues);
}

// 把当前功能参数（x/y/延迟/次数）存回 plist
- (void)persistFunctionParamValues {
    if (_functionScriptPath.length == 0) return;
    if (_functionParamValues.count == 0) return;
    ZXSaveScriptFunctionParams(_functionScriptPath, _functionParamValues);
}

- (void)persistAllValues {
    [self persistOptionValues];
    [self persistFunctionParamValues];
}

// 当前开关勾了哪些功能（下标与 _functionNames 一一对应）
- (NSArray<NSString *> *)pickedFunctionNames {
    NSMutableArray<NSString *> *picked = [NSMutableArray array];
    for (NSUInteger i = 0; i < _functionSwitches.count && i < _functionNames.count; i++) {
        if (_functionSwitches[i].isOn) [picked addObject:_functionNames[i]];
    }
    return picked;
}

// 「保存」按钮：选项值 + 功能参数 + 功能勾选 全部写盘，再关闭
- (void)saveAndHide {
    [self persistAllValues];
    if (_functionScriptPath.length > 0 && _functionNames.count > 0) {
        ZXSaveScriptFunctionSelection(_functionScriptPath, [self pickedFunctionNames]);
    }
    [self hide];
}

- (void)optionEditingEnded {
    [self persistAllValues];
}

// 一格选项：左边名称，右边按类型给控件。cellW = 这一格的宽度（选项区一行放两格）
- (UIView *)buildOptionCell:(NSDictionary *)decl value:(NSString *)value width:(CGFloat)cellW {
    NSString *name = decl[@"name"];
    ZXOptionType type = (ZXOptionType)[decl[@"type"] integerValue];
    NSArray<NSString *> *choices = decl[@"choices"];
    NSString *initial = value.length ? value : @"";

    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cellW, 44)];
    row.backgroundColor = [UIColor secondarySystemBackgroundColor];
    row.layer.cornerRadius = 8;

    CGFloat labelW = 72.0f;   // 放得下「抬起延迟」「自动拾取」这种 4 个字
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(10, 0, labelW, 44)];
    label.text = name;
    label.font = [UIFont systemFontOfSize:14];
    label.textColor = [UIColor labelColor];
    [row addSubview:label];

    // 控件跟在名称后面，占满这一格剩下的宽度
    CGFloat ctrlX = 10 + labelW + 6;
    CGFloat ctrlW = cellW - ctrlX - 10;
    if (ctrlW < 50) ctrlW = 50;

    if (type == ZXOptionTypeNumber || type == ZXOptionTypeText) {
        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(ctrlX, 6, ctrlW, 32)];
        tf.font = [UIFont systemFontOfSize:14];
        tf.textColor = [UIColor labelColor];
        tf.backgroundColor = [UIColor systemBackgroundColor];
        tf.layer.cornerRadius = 8;
        tf.layer.borderColor = [UIColor separatorColor].CGColor;
        tf.layer.borderWidth = 1;
        tf.textAlignment = NSTextAlignmentLeft;   // 值紧跟标签，别贴到格子最右
        tf.keyboardType = (type == ZXOptionTypeNumber) ? UIKeyboardTypeDecimalPad : UIKeyboardTypeDefault;
        tf.inputAccessoryView = [self optionKeyboardAccessory];
        tf.text = initial;
        tf.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        UIView *padL = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 32)];
        tf.leftView = padL; tf.leftViewMode = UITextFieldViewModeAlways;
        UIView *padR = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 32)];
        tf.rightView = padR; tf.rightViewMode = UITextFieldViewModeAlways;
        [tf addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
            self->_functionOptionValues[name] = tf.text ?: @"";
        }] forControlEvents:UIControlEventEditingChanged];
        [tf addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
            [self optionEditingEnded];
        }] forControlEvents:UIControlEventEditingDidEnd];
        [row addSubview:tf];
    } else if (type == ZXOptionTypeDropdown) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(ctrlX, 6, ctrlW, 32);
        btn.titleLabel.font = [UIFont systemFontOfSize:14];
        btn.backgroundColor = [UIColor systemBackgroundColor];
        btn.layer.cornerRadius = 8;
        btn.layer.borderColor = [UIColor separatorColor].CGColor;
        btn.layer.borderWidth = 1;
        btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        btn.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [btn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        // 左对齐时标题是贴着框边的，前面留一个空格当内边距（跟输入框的 8pt 左内边距对齐）
        [btn setTitle:[NSString stringWithFormat:@" %@  ▾", initial] forState:UIControlStateNormal];

        // 用 UIMenu 做下拉：窗口是独立 UIWindow，弹 UIAlertController 会被限制在窗口尺寸里
        NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
        for (NSString *choice in choices) {
            [items addObject:[UIAction actionWithTitle:choice image:nil identifier:nil handler:^(__kindof UIAction *a) {
                self->_functionOptionValues[name] = choice;
                [btn setTitle:[NSString stringWithFormat:@" %@  ▾", choice] forState:UIControlStateNormal];
                [self optionEditingEnded];
            }]];
        }
        btn.menu = [UIMenu menuWithTitle:@"" children:items];
        btn.showsMenuAsPrimaryAction = YES;
        [row addSubview:btn];
    } else {
        UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:choices];
        seg.frame = CGRectMake(ctrlX, 6, ctrlW, 32);
        NSInteger idx = [choices indexOfObject:initial];
        seg.selectedSegmentIndex = (idx == NSNotFound) ? 0 : idx;
        seg.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [seg addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
            NSInteger i = seg.selectedSegmentIndex;
            if (i >= 0 && i < (NSInteger)choices.count) self->_functionOptionValues[name] = choices[i];
            [self optionEditingEnded];
        }] forControlEvents:UIControlEventValueChanged];
        [row addSubview:seg];
    }

    return row;
}

// 一行放两个选项（左一格右一格），最后落单的就只占左半
- (UIView *)buildOptionPairRow:(NSArray<NSDictionary *> *)decls
                        values:(NSArray<NSString *> *)values
                         width:(CGFloat)pw {
    CGFloat rowW = pw - 8;
    CGFloat gap = 6.0f;
    CGFloat cellW = (rowW - gap) / 2.0f;

    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(4, 0, rowW, 44)];
    row.backgroundColor = [UIColor clearColor];
    row.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    for (NSUInteger i = 0; i < decls.count && i < 2; i++) {
        UIView *cell = [self buildOptionCell:decls[i] value:values[i] width:cellW];
        cell.frame = CGRectMake(i * (cellW + gap), 0, cellW, 44);
        [row addSubview:cell];
    }
    return row;
}

// 一行功能：名称（左，固定宽）+ 参数（在名称与开关之间居中）+ 开关（右，固定位）
// 参数有两种，声明里就能看出来：
//   数字     「x=333」        → 小字标签 + 输入框
//   下拉     「范围=全部提醒|仅提醒白蛋|仅提醒黑蛋」 → 一个下拉按钮（值里带 | 就是下拉）
// 参数区整体居中，所以每行的开关都落在同一条竖线上，参数也不会挤在名字旁边。
- (UIView *)buildFunctionRow:(NSDictionary *)decl
                        isOn:(BOOL)isOn
                       saved:(NSDictionary<NSString *, NSString *> *)saved
                       width:(CGFloat)pw
                      switch:(UISwitch **)outSwitch
                      height:(CGFloat *)outHeight {
    NSString *funcName = decl[@"name"];
    NSArray<NSString *> *keys = decl[@"paramOrder"] ?: @[];

    CGFloat rowW = pw - 8;
    CGFloat rowH = 46.0f;
    CGFloat pad = 10.0f;
    CGFloat nameW = FN_NAME_W;    // 够放 7 个中文字
    CGFloat switchW = 51.0f;
    CGFloat capW = 26.0f;         // 参数名小字（x / 延迟 / 次数…）的宽度
    CGFloat capGap = 4.0f;
    CGFloat gap = 6.0f;
    CGFloat midX = pad + nameW + 10;                  // 参数区可用的左边界
    CGFloat midW = rowW - midX - switchW - pad - 10;  // 参数区可用宽度
    if (midW < 60.0f) midW = 60.0f;

    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(4, 0, rowW, rowH)];
    row.backgroundColor = [UIColor secondarySystemBackgroundColor];
    row.layer.cornerRadius = 8;
    row.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(pad, 0, nameW, rowH)];
    label.text = funcName;
    label.font = [UIFont systemFontOfSize:14];
    label.textColor = [UIColor labelColor];
    label.adjustsFontSizeToFitWidth = YES;   // 超长的名字缩字号，不留省略号
    label.minimumScaleFactor = 0.8;
    [row addSubview:label];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(rowW - pad - switchW, (rowH - 31) / 2.0f, switchW, 31)];
    sw.on = isOn;
    sw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [row addSubview:sw];
    if (outSwitch) *outSwitch = sw;

    if (keys.count > 0) {
        NSMutableDictionary<NSString *, NSString *> *store = _functionParamValues[funcName];
        if (!store) {
            store = [NSMutableDictionary dictionary];
            _functionParamValues[funcName] = store;
        }

        // 第一遍：定每个参数控件的宽度。数字框平分剩下的地方（封顶 56，够放 4 位数），下拉按最长选项定宽
        NSMutableArray<NSArray<NSString *> *> *choicesOf = [NSMutableArray array];
        NSMutableArray<NSNumber *> *widths = [NSMutableArray array];
        CGFloat fixedW = 0;
        NSUInteger numCount = 0;
        for (NSString *key in keys) {
            NSString *declared = decl[@"params"][key] ?: @"";
            NSArray<NSString *> *choices = [declared componentsSeparatedByString:@"|"];
            if ([declared rangeOfString:@"|"].location != NSNotFound) {
                CGFloat w = 96.0f;
                for (NSString *c in choices) {
                    CGFloat cw = [c sizeWithAttributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:13] }].width + 34.0f;
                    if (cw > w) w = cw;
                }
                [choicesOf addObject:choices];
                [widths addObject:@(w)];
                fixedW += w;
            } else {
                [choicesOf addObject:@[]];
                [widths addObject:@(0)];   // 第二遍再补
                fixedW += capW + capGap;
                numCount += 1;
            }
        }
        CGFloat fieldW = 56.0f;
        if (numCount > 0) {
            fieldW = (midW - fixedW - gap * (keys.count - 1)) / (CGFloat)numCount;
            fieldW = MIN(56.0f, fieldW);
            if (fieldW < 30.0f) fieldW = 30.0f;
        }

        CGFloat totalW = fixedW + fieldW * numCount + gap * (keys.count - 1);
        CGFloat fx = midX + (midW - totalW) / 2.0f;   // 整块参数居中
        if (fx < midX) fx = midX;

        // 第二遍：摆控件
        for (NSUInteger i = 0; i < keys.count; i++) {
            NSString *key = keys[i];
            NSArray<NSString *> *choices = choicesOf[i];
            NSString *value = saved[key];
            CGFloat ctrlW = choices.count > 0 ? [widths[i] doubleValue] : fieldW;

            if (choices.count > 0) {
                // 下拉参数：存的值得是候选项之一，不是就用第一个（声明里那串带 | 的只是候选表）
                if (![choices containsObject:value ?: @""]) value = choices[0];
                store[key] = value;

                UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
                btn.frame = CGRectMake(fx, (rowH - 30) / 2.0f, ctrlW, 30);
                btn.titleLabel.font = [UIFont systemFontOfSize:13];
                btn.titleLabel.adjustsFontSizeToFitWidth = YES;
                btn.titleLabel.minimumScaleFactor = 0.8;
                btn.backgroundColor = [UIColor systemBackgroundColor];
                btn.layer.cornerRadius = 6;
                btn.layer.borderColor = [UIColor separatorColor].CGColor;
                btn.layer.borderWidth = 1;
                [btn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
                [btn setTitle:[NSString stringWithFormat:@"%@  ▾", value] forState:UIControlStateNormal];

                NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
                for (NSString *choice in choices) {
                    [items addObject:[UIAction actionWithTitle:choice image:nil identifier:nil handler:^(__kindof UIAction *a) {
                        store[key] = choice;
                        [btn setTitle:[NSString stringWithFormat:@"%@  ▾", choice] forState:UIControlStateNormal];
                        [self persistAllValues];
                    }]];
                }
                btn.menu = [UIMenu menuWithTitle:@"" children:items];
                btn.showsMenuAsPrimaryAction = YES;
                [row addSubview:btn];
            } else {
                if (value.length == 0) value = decl[@"params"][key];
                if (value.length == 0) value = @"";
                store[key] = value;

                UILabel *cap = [[UILabel alloc] initWithFrame:CGRectMake(fx, 0, capW, rowH)];
                cap.text = key;   // x / y / 延迟 / 次数
                cap.font = [UIFont systemFontOfSize:11];
                cap.textColor = [UIColor secondaryLabelColor];
                cap.textAlignment = NSTextAlignmentRight;
                [row addSubview:cap];

                UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(fx + capW + capGap, (rowH - 30) / 2.0f, ctrlW, 30)];
                tf.font = [UIFont systemFontOfSize:13];
                tf.textColor = [UIColor labelColor];
                tf.backgroundColor = [UIColor systemBackgroundColor];
                tf.layer.cornerRadius = 6;
                tf.layer.borderColor = [UIColor separatorColor].CGColor;
                tf.layer.borderWidth = 1;
                tf.textAlignment = NSTextAlignmentCenter;
                tf.keyboardType = UIKeyboardTypeDecimalPad;
                tf.adjustsFontSizeToFitWidth = YES;
                tf.minimumFontSize = 9;
                tf.inputAccessoryView = [self optionKeyboardAccessory];
                tf.text = value;
                [tf addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
                    store[key] = tf.text ?: @"";
                }] forControlEvents:UIControlEventEditingChanged];
                [tf addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
                    [self persistAllValues];
                }] forControlEvents:UIControlEventEditingDidEnd];
                [row addSubview:tf];
            }

            fx += ctrlW + gap;
        }
    }

    if (outHeight) *outHeight = rowH;
    return row;
}

// 一行排 3 个「只有开关」的功能（名称 + 开关，没参数框），省地方
- (UIView *)buildCompactFunctionRow:(NSArray<NSDictionary *> *)decls
                               isOn:(NSArray<NSNumber *> *)isOn
                              width:(CGFloat)pw
                           switches:(NSMutableArray<UISwitch *> *)outSwitches
                             height:(CGFloat *)outHeight {
    CGFloat rowW = pw - 8;
    CGFloat rowH = 44.0f;
    CGFloat gap = 6.0f;
    CGFloat cellW = (rowW - gap * 2) / 3.0f;

    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(4, 0, rowW, rowH)];
    row.backgroundColor = [UIColor clearColor];
    row.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    for (NSUInteger i = 0; i < decls.count && i < 3; i++) {
        NSDictionary *decl = decls[i];
        UIView *cell = [[UIView alloc] initWithFrame:CGRectMake(i * (cellW + gap), 0, cellW, rowH)];
        cell.backgroundColor = [UIColor secondarySystemBackgroundColor];
        cell.layer.cornerRadius = 8;
        cell.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [row addSubview:cell];

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(8, 0, cellW - 8 - 51 - 6, rowH)];
        label.text = decl[@"name"];
        label.font = [UIFont systemFontOfSize:14];
        label.textColor = [UIColor labelColor];
        label.adjustsFontSizeToFitWidth = YES;   // 名字长了缩字号，不留省略号
        label.minimumScaleFactor = 0.8;
        [cell addSubview:label];

        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(cellW - 8 - 51, (rowH - 31) / 2.0f, 51, 31)];
        sw.on = [isOn[i] boolValue];
        [cell addSubview:sw];
        [outSwitches addObject:sw];
    }

    if (outHeight) *outHeight = rowH;
    return row;
}

- (void)addSectionLabel:(NSString *)text width:(CGFloat)pw atY:(CGFloat)y {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12, y, pw - 24, 18)];
    label.text = text;
    label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    label.textColor = [UIColor secondaryLabelColor];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_functionScrollView addSubview:label];
}

#pragma mark - 内容刷新

- (void)reloadFunctionPage {
    if (!_window) return;
    CGFloat pw = [self cardWidth];

    NSString *title = _functionScriptPath.length
        ? [[_functionScriptPath lastPathComponent] stringByDeletingPathExtension]
        : @"（点这里选脚本）";
    [_functionScriptBtn setTitle:[NSString stringWithFormat:@"脚本：%@", title] forState:UIControlStateNormal];

    [_cardView endEditing:YES];
    for (UIView *v in _functionScrollView.subviews) [v removeFromSuperview];
    _functionSwitches = [NSMutableArray array];
    _functionOptionValues = [NSMutableDictionary dictionary];
    _functionParamValues = [NSMutableDictionary dictionary];

    BOOL hasScript = _functionScriptPath.length > 0;
    NSArray<NSDictionary *> *decls = hasScript ? (ZXScriptOptionDeclarations(_functionScriptPath) ?: @[]) : @[];
    NSArray<NSDictionary *> *funcDecls = hasScript ? (ZXScriptFunctionDeclarations(_functionScriptPath) ?: @[]) : @[];
    NSMutableArray<NSString *> *funcNames = [NSMutableArray array];
    for (NSDictionary *d in funcDecls) [funcNames addObject:d[@"name"]];
    _functionNames = funcNames;
    NSDictionary<NSString *, NSString *> *saved = hasScript ? ZXScriptOptionValues(_functionScriptPath) : @{};
    NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *savedParams =
        hasScript ? ZXScriptFunctionParams(_functionScriptPath) : @{};

    CGFloat y = 4;

    // 用户要求：功能勾选区在上，选项区挪到面板最下面
    if (_functionNames.count > 0) {
        [self addSectionLabel:@"功能" width:pw atY:y];
        y += 22;

        NSArray<NSString *> *selected = hasScript ? ZXScriptFunctionSelection(_functionScriptPath) : nil;

        // 先把功能按行分组（顺序不变，勾选序号才对得上）：
        // 带参数的自己占一整行；只有开关的攒够 3 个排一行
        NSMutableArray<NSArray<NSDictionary *> *> *rowGroups = [NSMutableArray array];
        NSMutableArray<NSDictionary *> *batch = [NSMutableArray array];
        for (NSDictionary *decl in funcDecls) {
            BOOL hasParams = [(decl[@"paramOrder"] ?: @[]) count] > 0;
            if (hasParams) {
                if (batch.count > 0) { [rowGroups addObject:[batch copy]]; [batch removeAllObjects]; }
                [rowGroups addObject:@[decl]];
            } else {
                [batch addObject:decl];
                if (batch.count == 3) { [rowGroups addObject:[batch copy]]; [batch removeAllObjects]; }
            }
        }
        if (batch.count > 0) [rowGroups addObject:[batch copy]];

        for (NSArray<NSDictionary *> *group in rowGroups) {
            BOOL hasParams = [(group[0][@"paramOrder"] ?: @[]) count] > 0;
            NSMutableArray<NSNumber *> *ons = [NSMutableArray array];
            for (NSDictionary *decl in group) {
                NSString *n = decl[@"name"];
                [ons addObject:@((selected == nil) ? YES : [selected containsObject:n])];
            }

            UIView *row = nil;
            CGFloat rowH = 0;
            if (hasParams) {
                UISwitch *sw = nil;
                row = [self buildFunctionRow:group[0]
                                        isOn:[ons[0] boolValue]
                                       saved:savedParams[group[0][@"name"]]
                                       width:pw
                                      switch:&sw
                                      height:&rowH];
                [_functionSwitches addObject:sw];
            } else {
                NSMutableArray<UISwitch *> *sws = [NSMutableArray array];
                row = [self buildCompactFunctionRow:group isOn:ons width:pw switches:sws height:&rowH];
                [_functionSwitches addObjectsFromArray:sws];
            }
            row.frame = CGRectMake(4, y, pw - 8, rowH);
            [_functionScrollView addSubview:row];
            y += rowH + 6;
        }
        y += 4;
    }

    if (decls.count > 0) {
        [self addSectionLabel:@"选项" width:pw atY:y];
        y += 22;

        // 选项一行放两个
        for (NSUInteger i = 0; i < decls.count; i += 2) {
            NSMutableArray<NSDictionary *> *pair = [NSMutableArray array];
            NSMutableArray<NSString *> *pairValues = [NSMutableArray array];
            for (NSUInteger j = i; j < i + 2 && j < decls.count; j++) {
                NSDictionary *decl = decls[j];
                NSString *name = decl[@"name"];
                NSString *value = saved[name];
                if (value.length == 0) value = decl[@"default"];
                if (value.length == 0) value = @"";
                _functionOptionValues[name] = value;
                [pair addObject:decl];
                [pairValues addObject:value];
            }

            UIView *row = [self buildOptionPairRow:pair values:pairValues width:pw];
            row.frame = CGRectMake(4, y, pw - 8, 44);
            [_functionScrollView addSubview:row];
            y += 44 + 6;
        }
    }

    if (decls.count == 0 && _functionNames.count == 0) {
        UILabel *empty = [[UILabel alloc] initWithFrame:CGRectMake(12, 16, pw - 24, 90)];
        empty.numberOfLines = 0;
        empty.font = [UIFont systemFontOfSize:12];
        empty.textColor = [UIColor secondaryLabelColor];
        empty.text = @"这个脚本还没有声明功能或选项。\n在脚本里加一行\n「# @功能 攻击 x=100 y=200」或\n「# @选项 名称 数字 默认=0」\n就会出现（写了哪些参数就出几个输入框）。";
        empty.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [_functionScrollView addSubview:empty];
        y = 110;
    }

    _functionScrollView.contentSize = CGSizeMake(pw, y + 4);
    [_functionScrollView setContentOffset:CGPointZero animated:NO];
    _contentHeight = y + 8;
    [self layoutCard];
}

// 挑脚本模式：列出脚本目录里所有 .bdl 供选择
- (void)reloadScriptPicker {
    if (!_window) return;
    CGFloat pw = [self cardWidth];

    [_cardView endEditing:YES];
    for (UIView *v in _functionScrollView.subviews) [v removeFromSuperview];

    NSString *base = getScriptsFolder();
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:base];
    for (NSString *rel in en) {
        if ([[rel pathExtension] isEqualToString:@"bdl"]) {
            [paths addObject:[base stringByAppendingPathComponent:rel]];
        }
    }
    [paths sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

    CGFloat y = 6;
    for (NSString *path in paths) {
        UIButton *btn = fnMakeButton(@"", [UIColor labelColor]);
        [btn setTitle:[[path lastPathComponent] stringByDeletingPathExtension] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:13];
        btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        btn.frame = CGRectMake(8, y, pw - 16, FN_BTN_H);
        [btn setImage:fnSymbol(@"play.fill") forState:UIControlStateNormal];
        btn.tintColor = [UIColor labelColor];
        [btn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
            [self selectFunctionScript:path];
        }] forControlEvents:UIControlEventTouchUpInside];
        [_functionScrollView addSubview:btn];
        y += FN_BTN_H + 6;
    }

    if (paths.count == 0) {
        UILabel *empty = [[UILabel alloc] initWithFrame:CGRectMake(12, 16, pw - 24, 40)];
        empty.numberOfLines = 0;
        empty.font = [UIFont systemFontOfSize:12];
        empty.textColor = [UIColor secondaryLabelColor];
        empty.text = @"脚本目录里还没有 .bdl 文件。";
        [_functionScrollView addSubview:empty];
        y = 60;
    }

    _functionScrollView.contentSize = CGSizeMake(pw, y + 4);
    [_functionScrollView setContentOffset:CGPointZero animated:NO];
    _contentHeight = y + 8;
    [self layoutCard];
}

#pragma mark - 脚本选择

- (void)beginScriptPicking {
    [_cardView endEditing:YES];
    _pickingScript = YES;
    [self reloadScriptPicker];
}

- (void)selectFunctionScript:(NSString *)path {
    [_cardView endEditing:YES];
    [self persistAllValues];
    _pickingScript = NO;
    _functionScriptPath = [path copy];
    ZXSaveLastFunctionScriptPath(_functionScriptPath);
    [self reloadFunctionPage];
}

#pragma mark - 运行

- (void)runFunctionSelection {
    if (_functionScriptPath.length == 0) {
        showAlertBox(@"提示", @"请先点顶部的「脚本」选一个脚本。", 2);
        return;
    }

    [_cardView endEditing:YES];
    [self persistAllValues];

    NSArray<NSString *> *picked = [self pickedFunctionNames];
    // 只有声明了功能的脚本才要求至少勾一个（只声明选项的脚本可以直接运行）
    if (_functionNames.count > 0 && picked.count == 0) {
        showAlertBox(@"提示", @"请至少勾选一个功能。", 2);
        return;
    }

    ZXSaveScriptFunctionSelection(_functionScriptPath, picked);
    ZXSaveLastFunctionScriptPath(_functionScriptPath);

    NSString *scriptPath = [_functionScriptPath copy];
    [self hide];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *err = nil;
        playScriptWithSettings((UInt8 *)[scriptPath UTF8String], 0, 1.0f, 0.0f, &err);
        if (err) showAlertBox(@"错误", [err localizedDescription], 999);
    });
}

#pragma mark - 显示 / 隐藏

- (void)show {
    _shown = YES;
    ZXSafeMainAsync(^{
        [self ensureWindow];
        if (!self->_window) return;

        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL valid = self->_functionScriptPath.length > 0 && [fm fileExistsAtPath:self->_functionScriptPath];
        if (!valid) {
            NSString *last = ZXLastFunctionScriptPath();
            if (last.length > 0 && [fm fileExistsAtPath:last]) {
                self->_functionScriptPath = last;
                valid = YES;
            }
        }
        if (!valid) self->_functionScriptPath = ZXFirstScriptPathWithFunctions();

        self->_pickingScript = NO;
        [self reloadFunctionPage];
        self->_window.hidden = NO;

        // window 刚创建时 bounds 可能是 CGRectZero，layoutCard 会退回用 UIScreen.bounds；
        // 等下一帧 scene 把 bounds 摆正后再量一次，保证卡片居中（本项目踩过的坑）
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self->_shown) return;
            [self layoutCard];
        });
    });
}

// 关闭面板。「保存」走 saveAndHide；✕ 直接调这里，不额外存盘
- (void)hide {
    _shown = NO;
    ZXSafeMainAsync(^{
        if (!self->_window) return;
        [self->_cardView endEditing:YES];
        self->_window.hidden = YES;
    });
}

- (BOOL)isShown { return _shown; }

@end