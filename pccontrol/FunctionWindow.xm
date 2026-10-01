#import "FunctionWindow.h"
#import "FloatingMenu.h"      // FMPassthroughWindow + preferredWindowScene
#import "Common.h"            // ZXSafeMainAsync / getScriptsFolder
#import "ScriptFunctions.h"
#import "AlertBox.h"
#import "Play.h"
#import <UIKit/UIKit.h>

#define FN_BTN_H     40.0f
#define FN_TOP_H     49.0f
#define FN_BOTTOM_H  56.0f
#define FN_CARD_W    340.0f

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
    UIButton        *_allBtn;
    UIButton        *_noneBtn;
    UIButton        *_runBtn;

    NSArray<NSString *>        *_functionNames;
    NSMutableArray<UISwitch *> *_functionSwitches;
    NSString                   *_functionScriptPath;
    NSMutableDictionary<NSString *, NSString *> *_functionOptionValues;  // 选项名 → 当前值
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
        [self hide];
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

    // 底部：全选 / 全不选 / 运行
    _allBtn = fnMakeButton(@"全选", [UIColor systemBlueColor]);
    _allBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    [_allBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        [self setAllFunctionSwitches:YES];
    }] forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_allBtn];

    _noneBtn = fnMakeButton(@"全不选", [UIColor secondaryLabelColor]);
    _noneBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    [_noneBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        [self setAllFunctionSwitches:NO];
    }] forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_noneBtn];

    _runBtn = fnMakeButton(@"运行", [UIColor systemGreenColor]);
    _runBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _runBtn.backgroundColor = [UIColor.systemGreenColor colorWithAlphaComponent:0.14];
    [_runBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        [self runFunctionSelection];
    }] forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_runBtn];

    [self layoutCard];

    // 建好后先隐藏，等 show 时再显示
    _window.hidden = YES;

    // 旋转后居中 / 重排（卡片宽度取 340 与屏幕宽度 - 40 的较小值，需按新尺寸重算）
    [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceOrientationDidChangeNotification
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            if (!self->_shown) return;
            [self persistOptionValues];
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

    // 高度按内容自适应，不超过屏幕高度的 72%
    CGFloat maxH = screenH * 0.72f;
    CGFloat cardH = FN_TOP_H + _contentHeight + FN_BOTTOM_H;
    if (cardH > maxH) cardH = maxH;
    CGFloat minH = FN_TOP_H + FN_BOTTOM_H + 60.0f;
    if (cardH < minH) cardH = minH;
    if (cardH > screenH - 40.0f) cardH = screenH - 40.0f;
    if (cardH < 100.0f) cardH = 100.0f;

    _cardView.frame = CGRectMake((screenW - cardW) / 2.0f, (screenH - cardH) / 2.0f, cardW, cardH);

    _functionScriptBtn.frame = CGRectMake(8, 6, cardW - 8 - 40 - 6, 36);
    _closeBtn.frame = CGRectMake(cardW - 40, 6, 32, 36);
    _functionScrollView.frame = CGRectMake(0, FN_TOP_H, cardW, MAX(cardH - FN_TOP_H - FN_BOTTOM_H, 0));

    CGFloat margin = 8.0f;
    CGFloat spacing = 8.0f;
    CGFloat bw = (cardW - margin * 2 - spacing * 2) / 3.0f;
    CGFloat by = cardH - FN_BOTTOM_H + 8.0f;
    _allBtn.frame = CGRectMake(margin, by, bw, 40);
    _noneBtn.frame = CGRectMake(margin + bw + spacing, by, bw, 40);
    _runBtn.frame = CGRectMake(margin + (bw + spacing) * 2, by, bw, 40);
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

- (void)optionEditingEnded {
    [self persistOptionValues];
}

// 一行选项：左边名称，右边按类型给控件
- (UIView *)buildOptionRow:(NSDictionary *)decl value:(NSString *)value width:(CGFloat)pw {
    NSString *name = decl[@"name"];
    ZXOptionType type = (ZXOptionType)[decl[@"type"] integerValue];
    NSArray<NSString *> *choices = decl[@"choices"];
    NSString *initial = value.length ? value : @"";

    CGFloat rowW = pw - 8;
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(4, 0, rowW, 44)];
    row.backgroundColor = [UIColor secondarySystemBackgroundColor];
    row.layer.cornerRadius = 8;
    row.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    CGFloat labelW = MAX(rowW * 0.42f, 64);
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(10, 0, labelW, 44)];
    label.text = name;
    label.font = [UIFont systemFontOfSize:14];
    label.textColor = [UIColor labelColor];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [row addSubview:label];

    CGFloat ctrlX = 10 + labelW + 6;
    CGFloat ctrlW = rowW - ctrlX - 10;
    if (ctrlW < 50) ctrlW = 50;

    if (type == ZXOptionTypeNumber || type == ZXOptionTypeText) {
        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(ctrlX, 6, ctrlW, 32)];
        tf.font = [UIFont systemFontOfSize:14];
        tf.textColor = [UIColor labelColor];
        tf.backgroundColor = [UIColor systemBackgroundColor];
        tf.layer.cornerRadius = 8;
        tf.layer.borderColor = [UIColor separatorColor].CGColor;
        tf.layer.borderWidth = 1;
        tf.textAlignment = NSTextAlignmentRight;
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
        btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
        btn.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [btn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        [btn setTitle:[NSString stringWithFormat:@"%@  ▾", initial] forState:UIControlStateNormal];

        // 用 UIMenu 做下拉：窗口是独立 UIWindow，弹 UIAlertController 会被限制在窗口尺寸里
        NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
        for (NSString *choice in choices) {
            [items addObject:[UIAction actionWithTitle:choice image:nil identifier:nil handler:^(__kindof UIAction *a) {
                self->_functionOptionValues[name] = choice;
                [btn setTitle:[NSString stringWithFormat:@"%@  ▾", choice] forState:UIControlStateNormal];
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

    BOOL hasScript = _functionScriptPath.length > 0;
    NSArray<NSDictionary *> *decls = hasScript ? (ZXScriptOptionDeclarations(_functionScriptPath) ?: @[]) : @[];
    _functionNames = hasScript ? (ZXScriptFunctionNames(_functionScriptPath) ?: @[]) : @[];
    NSDictionary<NSString *, NSString *> *saved = hasScript ? ZXScriptOptionValues(_functionScriptPath) : @{};

    CGFloat y = 4;

    if (decls.count > 0) {
        [self addSectionLabel:@"选项" width:pw atY:y];
        y += 22;

        for (NSDictionary *decl in decls) {
            NSString *name = decl[@"name"];
            NSString *value = saved[name];
            if (value.length == 0) value = decl[@"default"];
            if (value.length == 0) value = @"";
            _functionOptionValues[name] = value;

            UIView *row = [self buildOptionRow:decl value:value width:pw];
            row.frame = CGRectMake(4, y, pw - 8, 44);
            [_functionScrollView addSubview:row];
            y += 44 + 6;
        }
        y += 4;
    }

    if (_functionNames.count > 0) {
        [self addSectionLabel:@"功能" width:pw atY:y];
        y += 22;

        NSArray<NSString *> *selected = hasScript ? ZXScriptFunctionSelection(_functionScriptPath) : nil;
        CGFloat rowW = pw - 8;
        CGFloat switchW = 51;
        CGFloat labelW = MAX(rowW - 10 - switchW - 12, 60);

        for (NSString *funcName in _functionNames) {
            UIView *row = [[UIView alloc] initWithFrame:CGRectMake(4, y, rowW, 46)];
            row.backgroundColor = [UIColor secondarySystemBackgroundColor];
            row.layer.cornerRadius = 8;
            row.autoresizingMask = UIViewAutoresizingFlexibleWidth;

            UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(10, 0, labelW, 46)];
            label.text = funcName;
            label.font = [UIFont systemFontOfSize:14];
            label.textColor = [UIColor labelColor];
            label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            [row addSubview:label];

            UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(rowW - 10 - switchW, 8, switchW, 31)];
            sw.on = (selected == nil) ? YES : [selected containsObject:funcName];
            sw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
            [row addSubview:sw];
            [_functionSwitches addObject:sw];

            [_functionScrollView addSubview:row];
            y += 46 + 6;
        }
    }

    if (decls.count == 0 && _functionNames.count == 0) {
        UILabel *empty = [[UILabel alloc] initWithFrame:CGRectMake(12, 16, pw - 24, 90)];
        empty.numberOfLines = 0;
        empty.font = [UIFont systemFontOfSize:12];
        empty.textColor = [UIColor secondaryLabelColor];
        empty.text = @"这个脚本还没有声明功能或选项。\n在脚本里加一行\n「# @功能 名称」或\n「# @选项 名称 数字 默认=0」\n就会出现。";
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
    [self persistOptionValues];
    _pickingScript = NO;
    _functionScriptPath = [path copy];
    ZXSaveLastFunctionScriptPath(_functionScriptPath);
    [self reloadFunctionPage];
}

#pragma mark - 运行

- (void)setAllFunctionSwitches:(BOOL)on {
    for (UISwitch *sw in _functionSwitches) [sw setOn:on animated:YES];
}

- (void)runFunctionSelection {
    if (_functionScriptPath.length == 0) {
        showAlertBox(@"提示", @"请先点顶部的「脚本」选一个脚本。", 2);
        return;
    }

    [_cardView endEditing:YES];
    [self persistOptionValues];

    NSMutableArray<NSString *> *picked = [NSMutableArray array];
    for (NSUInteger i = 0; i < _functionSwitches.count && i < _functionNames.count; i++) {
        if (_functionSwitches[i].isOn) [picked addObject:_functionNames[i]];
    }
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

- (void)hide {
    _shown = NO;
    ZXSafeMainAsync(^{
        if (!self->_window) return;
        [self->_cardView endEditing:YES];
        [self persistOptionValues];
        self->_window.hidden = YES;
    });
}

- (BOOL)isShown { return _shown; }

@end