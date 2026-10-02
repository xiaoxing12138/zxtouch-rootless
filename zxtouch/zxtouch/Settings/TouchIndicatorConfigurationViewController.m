//
//  TouchIndicatorConfigurationViewController.m
//  zxtouch
//
//  触摸指示器 + 坐标悬浮窗合并设置页。
//  坐标悬浮窗的坐标来自触摸指示器的采集通道：指示器没开时它永远不刷新，
//  所以指示器关闭时「坐标悬浮窗」段整段隐藏，并把坐标悬浮窗一并关闭。
//

#import "TouchIndicatorConfigurationViewController.h"
#import "TableViewCellWithSwitch.h"
#import "TableViewCellWithSlider.h"
#import "Config.h"
#import "Util.h"
#import "Socket.h"

// 触摸圆点大小范围与默认值（与 tweak 端 INDICATOR_VIEW_DEFAULT_SIZE 保持一致）
#define DOT_SIZE_MIN 8
#define DOT_SIZE_MAX 80
#define DOT_SIZE_DEFAULT 60

// 坐标悬浮窗配置键（与 tweak 端 TouchCoordinateIndicator.xm 对应）
static NSString * const kCfgCoordEnabled   = @"touch_coord_enabled";
static NSString * const kCfgCoordCorner    = @"touch_coord_corner";     // 0右上 1左上 2左下 3右下
static NSString * const kCfgCoordFontSize  = @"touch_coord_font_size";
static NSString * const kCfgCoordMarginX   = @"touch_coord_margin_x";
static NSString * const kCfgCoordMarginY   = @"touch_coord_margin_y";
static NSString * const kCfgCoordBgColor   = @"touch_coord_bg_color";
static NSString * const kCfgCoordBgAlpha   = @"touch_coord_bg_alpha";
static NSString * const kCfgCoordTextColor = @"touch_coord_text_color";
static NSString * const kCfgCoordHideIdle  = @"touch_coord_hide_when_idle";
static NSString * const kCfgCoordMultiMode = @"touch_coord_multi_mode";

// 坐标悬浮窗默认值与范围（与 tweak 端一致）
static const float kCoordFontMin         = 8.0f;
static const float kCoordFontMax         = 20.0f;
static const float kCoordFontDefault     = 11.0f;
static const float kCoordMarginXMax      = 500.0f;
static const float kCoordMarginYMax      = 200.0f;
static const float kCoordMarginDefault   = 10.0f;
static const float kCoordBgAlphaDefault  = 0.4f;
static NSString * const kCoordBgColorDefault   = @"#000000";
static NSString * const kCoordTextColorDefault = @"#FFFFFF";
static const NSInteger kCoordMultiDefault = 1;   // 0第一个 1最后一个 2全部

typedef NS_ENUM(NSInteger, ZXSection) {
    ZXSectionIndicator  = 0,  // 触摸指示器（圆点）
    ZXSectionCoordinate = 1   // 坐标悬浮窗（指示器关闭时整段隐藏）
};

typedef NS_ENUM(NSInteger, IndicatorRow) {
    IndicatorRowSwitch    = 0,  // 触摸指示器开关
    IndicatorRowShowCoord,      // 显示坐标（圆点旁的小标签）
    IndicatorRowDotColor,       // 圆点颜色
    IndicatorRowDotAlpha,       // 不透明度
    IndicatorRowDotSize         // 圆点大小
};

typedef NS_ENUM(NSInteger, CoordRow) {
    CoordRowSwitch = 0,
    CoordRowCorner,
    CoordRowFont,
    CoordRowMarginX,
    CoordRowMarginY,
    CoordRowBgColor,
    CoordRowBgAlpha,
    CoordRowTextColor,
    CoordRowHideIdle,
    CoordRowMultiMode
};

static NSArray<NSArray<NSString *> *> *ZXDotColorPresets(void) {
    return @[@[@"红色", @"#FF0000"], @[@"蓝色", @"#0000FF"], @[@"绿色", @"#00FF00"],
             @[@"白色", @"#FFFFFF"], @[@"黑色", @"#000000"], @[@"橙色", @"#FF8000"],
             @[@"黄色", @"#FFFF00"]];
}

static NSArray<NSArray<NSString *> *> *ZXCoordColorPresets(void) {
    return @[@[@"黑色", @"#000000"], @[@"白色", @"#FFFFFF"], @[@"红色", @"#FF3B30"],
             @[@"绿色", @"#34C759"], @[@"蓝色", @"#007AFF"], @[@"橙色", @"#FF9500"]];
}

// "#RRGGBB" → @[@(r), @(g), @(b)]（0-255），非法输入回落黑色
static NSArray<NSNumber *> *ZXRGBFromHex(NSString *hex) {
    NSString *value = [hex isKindOfClass:[NSString class]] ? [hex uppercaseString] : @"";
    if ([value hasPrefix:@"#"]) value = [value substringFromIndex:1];
    unsigned int rgb = 0;
    if (value.length != 6 || ![[NSScanner scannerWithString:value] scanHexInt:&rgb]) {
        return @[@0, @0, @0];
    }
    return @[@((rgb >> 16) & 0xFF), @((rgb >> 8) & 0xFF), @(rgb & 0xFF)];
}

@implementation TouchIndicatorConfigurationViewController
{
    NSMutableDictionary *config;   // 整个 config.plist：touch_indicator 段 + 坐标窗扁平键
    Socket *springBoardSocket;
    BOOL isShowing;                // 触摸指示器是否开启
    BOOL coordEnabled;
    NSInteger coordCorner;
    float coordFontSize;
    float coordMarginX;
    float coordMarginY;
    NSString *coordBgColorHex;
    float coordBgAlpha;
    NSString *coordTextColorHex;
    BOOL coordHideWhenIdle;
    NSInteger coordMultiMode;
    NSArray<NSString *> *cornerTitles;
    NSArray<NSString *> *multiModeTitles;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"触摸指示器与坐标窗";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    cornerTitles = @[@"右上", @"左上", @"左下", @"右下"];
    multiModeTitles = @[@"第一个触点", @"最后一个触点", @"全部触点"];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    _tableView.tableFooterView = [[UIView alloc] init];
    [self.view addSubview:_tableView];

    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    [_tableView registerNib:[UINib nibWithNibName:@"TableViewCellWithSwitch" bundle:nil] forCellReuseIdentifier:@"SwitchCell"];
    [_tableView registerNib:[UINib nibWithNibName:@"TableViewCellWithSlider" bundle:nil] forCellReuseIdentifier:@"SliderCell"];

    // 先建连，loadConfig 里可能要把坐标悬浮窗一并关掉
    springBoardSocket = [[Socket alloc] init];
    [springBoardSocket connect:@"127.0.0.1" byPort:6000];

    [self loadConfig];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadConfig];
    [_tableView reloadData];
}

#pragma mark - 配置读写

- (NSMutableDictionary *)touchConfig {
    NSMutableDictionary *touch = config[@"touch_indicator"];
    if (![touch isKindOfClass:[NSMutableDictionary class]]) {
        touch = [NSMutableDictionary dictionary];
        config[@"touch_indicator"] = touch;
    }
    return touch;
}

- (NSMutableDictionary *)dotColorConfig {
    NSMutableDictionary *touch = [self touchConfig];
    NSMutableDictionary *color = touch[@"color"];
    if (![color isKindOfClass:[NSMutableDictionary class]]) {
        color = [NSMutableDictionary dictionaryWithDictionary:
                 @{@"alpha": @(TOUCH_INDICATOR_DEFAULT_ALPHA), @"r": @(255), @"g": @(0), @"b": @(0)}];
        touch[@"color"] = color;
    }
    return color;
}

- (NSString *)dotColorHex {
    NSDictionary *color = [self dotColorConfig];
    return [NSString stringWithFormat:@"#%02X%02X%02X",
            [color[@"r"] intValue] & 0xFF, [color[@"g"] intValue] & 0xFF, [color[@"b"] intValue] & 0xFF];
}

- (BOOL)saveConfig {
    if ([config writeToFile:SPRINGBOARD_CONFIG_PATH atomically:YES]) {
        return YES;
    }
    [Util showAlertBoxWithOneOption:self title:@"错误" message:@"无法写入配置文件。" buttonString:@"确定"];
    return NO;
}

- (void)loadConfig {
    config = [NSMutableDictionary dictionaryWithContentsOfFile:SPRINGBOARD_CONFIG_PATH];
    if (!config) config = [NSMutableDictionary dictionary];

    // 触摸指示器：补齐缺失项后再读回
    NSMutableDictionary *touch = [self touchConfig];
    NSMutableDictionary *color = [self dotColorConfig];
    if (!touch[@"show"]) touch[@"show"] = @(NO);
    if (!touch[@"show_coordinates"]) touch[@"show_coordinates"] = @(YES);
    if (!touch[@"dot_size"]) touch[@"dot_size"] = @(DOT_SIZE_DEFAULT);
    if (!color[@"alpha"]) color[@"alpha"] = @(TOUCH_INDICATOR_DEFAULT_ALPHA);
    isShowing = [touch[@"show"] boolValue];

    // 坐标悬浮窗
    coordEnabled = config[kCfgCoordEnabled] ? [config[kCfgCoordEnabled] boolValue] : NO;
    coordCorner = config[kCfgCoordCorner] ? [config[kCfgCoordCorner] integerValue] : 0;
    if (coordCorner < 0 || coordCorner >= (NSInteger)cornerTitles.count) coordCorner = 0;

    coordFontSize = config[kCfgCoordFontSize] ? [config[kCfgCoordFontSize] floatValue] : kCoordFontDefault;
    if (coordFontSize < kCoordFontMin || coordFontSize > kCoordFontMax) coordFontSize = kCoordFontDefault;

    coordMarginX = config[kCfgCoordMarginX] ? [config[kCfgCoordMarginX] floatValue] : kCoordMarginDefault;
    if (coordMarginX < 0 || coordMarginX > kCoordMarginXMax) coordMarginX = kCoordMarginDefault;
    coordMarginY = config[kCfgCoordMarginY] ? [config[kCfgCoordMarginY] floatValue] : kCoordMarginDefault;
    if (coordMarginY < 0 || coordMarginY > kCoordMarginYMax) coordMarginY = kCoordMarginDefault;

    NSString *bg = config[kCfgCoordBgColor];
    coordBgColorHex = [bg isKindOfClass:[NSString class]] ? bg : kCoordBgColorDefault;
    NSString *text = config[kCfgCoordTextColor];
    coordTextColorHex = [text isKindOfClass:[NSString class]] ? text : kCoordTextColorDefault;

    coordBgAlpha = config[kCfgCoordBgAlpha] ? [config[kCfgCoordBgAlpha] floatValue] : kCoordBgAlphaDefault;
    if (coordBgAlpha < 0 || coordBgAlpha > 1) coordBgAlpha = kCoordBgAlphaDefault;

    coordHideWhenIdle = config[kCfgCoordHideIdle] ? [config[kCfgCoordHideIdle] boolValue] : NO;

    coordMultiMode = config[kCfgCoordMultiMode] ? [config[kCfgCoordMultiMode] integerValue] : kCoordMultiDefault;
    if (coordMultiMode < 0 || coordMultiMode >= (NSInteger)multiModeTitles.count) coordMultiMode = kCoordMultiDefault;

    // 指示器没开 → 坐标悬浮窗没有数据来源，连同保存值一起关掉
    if (!isShowing && coordEnabled) {
        coordEnabled = NO;
        config[kCfgCoordEnabled] = @(NO);
        [self sendCoordEnabled:NO];
    }

    [config writeToFile:SPRINGBOARD_CONFIG_PATH atomically:YES];
}

#pragma mark - 通知 tweak

- (void)sendCoordEnabled:(BOOL)enabled {
    [springBoardSocket send:[NSString stringWithFormat:@"42;;%d\r\n", enabled ? 1 : 0]];
}

// 只让坐标悬浮窗重新读配置（位置/边距/字号/颜色/隐藏/多点模式），不动总开关
- (void)reloadCoordConfig {
    [springBoardSocket send:@"42;;3\r\n"];
}

// 让触摸指示器重新读配置（颜色/不透明度/圆点大小）
- (void)reloadIndicatorConfig {
    if (isShowing) {
        [springBoardSocket send:@"262\r\n"];
    }
}

#pragma mark - 触摸指示器

- (void)indicatorSwitchChanged:(UISwitch *)s {
    isShowing = [s isOn];
    [self touchConfig][@"show"] = @(isShowing);
    [springBoardSocket send:isShowing ? @"261\r\n" : @"260\r\n"];

    if (!isShowing && coordEnabled) {
        coordEnabled = NO;
        config[kCfgCoordEnabled] = @(NO);
        [self sendCoordEnabled:NO];
    }

    if ([self saveConfig]) {
        [_tableView reloadData];   // 指示器关闭时整段隐藏「坐标悬浮窗」
    }
}

- (void)showCoordinatesChanged:(UISwitch *)s {
    [self touchConfig][@"show_coordinates"] = @([s isOn]);
    if ([self saveConfig]) [self reloadIndicatorConfig];
}

- (void)indicatorSliderChanged:(UISlider *)slider {
    NSInteger row = slider.tag;
    if (row == IndicatorRowDotAlpha) {
        float stepped = 0.1f * roundf(slider.value / 0.1f);
        [slider setValue:stepped animated:NO];
        [self dotColorConfig][@"alpha"] = @(stepped);
        [self sliderCellAtRow:row inSection:ZXSectionIndicator].value.text = [NSString stringWithFormat:@"%.1f", stepped];
        [self saveConfig];
        [self reloadIndicatorConfig];
    } else if (row == IndicatorRowDotSize) {
        NSInteger dotSize = (NSInteger)roundf(slider.value);
        if (dotSize < DOT_SIZE_MIN) dotSize = DOT_SIZE_MIN;
        if (dotSize > DOT_SIZE_MAX) dotSize = DOT_SIZE_MAX;
        [slider setValue:(float)dotSize animated:NO];
        [self touchConfig][@"dot_size"] = @(dotSize);
        [self sliderCellAtRow:row inSection:ZXSectionIndicator].value.text = [NSString stringWithFormat:@"%ld pt", (long)dotSize];
        [self saveConfig];
        [self reloadIndicatorConfig];
    }
}

#pragma mark - 坐标悬浮窗

- (void)coordSwitchChanged:(UISwitch *)s {
    coordEnabled = [s isOn];
    config[kCfgCoordEnabled] = @(coordEnabled);
    [self sendCoordEnabled:coordEnabled];
    [self saveConfig];
    // 关闭时本段只保留开关行
    [_tableView reloadData];
}

- (void)coordHideIdleChanged:(UISwitch *)s {
    coordHideWhenIdle = [s isOn];
    config[kCfgCoordHideIdle] = @(coordHideWhenIdle);
    if ([self saveConfig]) [self reloadCoordConfig];
}

- (void)coordSliderChanged:(UISlider *)slider {
    NSInteger row = slider.tag;
    NSString *key = nil;
    float stepped = roundf(slider.value);
    NSString *label = nil;

    if (row == CoordRowFont) {
        stepped = 0.5f * roundf(slider.value / 0.5f);
        coordFontSize = stepped;
        key = kCfgCoordFontSize;
        label = [NSString stringWithFormat:@"%.1f", stepped];
    } else if (row == CoordRowMarginX) {
        coordMarginX = stepped;
        key = kCfgCoordMarginX;
        label = [NSString stringWithFormat:@"%.0f pt", stepped];
    } else if (row == CoordRowMarginY) {
        coordMarginY = stepped;
        key = kCfgCoordMarginY;
        label = [NSString stringWithFormat:@"%.0f pt", stepped];
    } else if (row == CoordRowBgAlpha) {
        stepped = 0.05f * roundf(slider.value / 0.05f);
        coordBgAlpha = stepped;
        key = kCfgCoordBgAlpha;
        label = [NSString stringWithFormat:@"%.2f", stepped];
    }
    if (!key) return;

    [slider setValue:stepped animated:NO];
    config[key] = @(stepped);
    [self sliderCellAtRow:row inSection:ZXSectionCoordinate].value.text = label;
    [self saveConfig];   // 拖动过程中只写盘，松手时才通知 tweak
}

- (void)coordSliderTouchUp:(UISlider *)slider {
    [self reloadCoordConfig];
}

- (TableViewCellWithSlider *)sliderCellAtRow:(NSInteger)row inSection:(NSInteger)section {
    return [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:section]];
}

#pragma mark - 颜色选择

- (BOOL)isValidHexColor:(NSString *)value {
    if (![value isKindOfClass:[NSString class]]) return NO;
    NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([trimmed hasPrefix:@"#"]) trimmed = [trimmed substringFromIndex:1];
    if (trimmed.length != 6 && trimmed.length != 3) return NO;
    NSCharacterSet *hexSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    return [trimmed rangeOfCharacterFromSet:[hexSet invertedSet]].location == NSNotFound;
}

- (void)presentColorPickerForTitle:(NSString *)title
                           current:(NSString *)current
                          presets:(NSArray<NSArray<NSString *> *> *)presets
                            anchor:(UIView *)anchor
                         onPicked:(void (^)(NSString *hex))onPicked {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
        message:[NSString stringWithFormat:@"当前：%@", current]
        preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSArray<NSString *> *pair in presets) {
        [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@  %@", pair.firstObject, pair.lastObject]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) { onPicked(pair.lastObject); }]];
    }

    __weak TouchIndicatorConfigurationViewController *weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"手动输入十六进制..." style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
            message:@"请输入十六进制颜色，例如 #FF0000"
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
            textField.placeholder = @"#RRGGBB";
            textField.text = current;
            textField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
            textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            NSString *input = alert.textFields.firstObject.text ?: @"";
            TouchIndicatorConfigurationViewController *strongSelf = weakSelf;
            if (!strongSelf || ![strongSelf isValidHexColor:input]) return;
            onPicked([input uppercaseString]);
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop) {
        // iPad 上必须锚在被点的那个 cell：锚到 tableView.bounds 时会带上滚动偏移，
        // 锚点跑到可视区外，action sheet 弹不出来（表现为「点颜色没反应」）
        pop.sourceView = anchor ?: self.tableView;
        pop.sourceRect = anchor ? anchor.bounds : self.tableView.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)pickDotColorAtIndexPath:(NSIndexPath *)indexPath {
    __weak TouchIndicatorConfigurationViewController *weakSelf = self;
    [self presentColorPickerForTitle:@"圆点颜色" current:[self dotColorHex] presets:ZXDotColorPresets()
                              anchor:[self.tableView cellForRowAtIndexPath:indexPath]
                            onPicked:^(NSString *hex) {
        TouchIndicatorConfigurationViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        NSArray<NSNumber *> *rgb = ZXRGBFromHex(hex);
        NSMutableDictionary *color = [strongSelf dotColorConfig];
        color[@"r"] = rgb[0];
        color[@"g"] = rgb[1];
        color[@"b"] = rgb[2];
        [strongSelf saveConfig];
        [strongSelf reloadIndicatorConfig];
        [strongSelf.tableView reloadData];
    }];
}

- (void)pickCoordColorForKey:(NSString *)key title:(NSString *)title indexPath:(NSIndexPath *)indexPath {
    BOOL isBg = [key isEqualToString:kCfgCoordBgColor];
    NSString *current = isBg ? coordBgColorHex : coordTextColorHex;
    __weak TouchIndicatorConfigurationViewController *weakSelf = self;
    [self presentColorPickerForTitle:title current:current presets:ZXCoordColorPresets()
                              anchor:[self.tableView cellForRowAtIndexPath:indexPath]
                            onPicked:^(NSString *hex) {
        TouchIndicatorConfigurationViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->config[key] = hex;
        if (isBg) strongSelf->coordBgColorHex = hex; else strongSelf->coordTextColorHex = hex;
        [strongSelf saveConfig];
        [strongSelf reloadCoordConfig];
        [strongSelf.tableView reloadData];
    }];
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;   // 触摸指示器 + 坐标悬浮窗（两段入口开关始终可见）
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    // 开关关闭时该段只留开关这一行，参数全隐藏
    return section == ZXSectionIndicator ? (isShowing ? 5 : 1) : (coordEnabled ? 10 : 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == ZXSectionIndicator ? @"触摸指示器" : @"坐标悬浮窗";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == ZXSectionCoordinate) {
        if (!isShowing) return @"需先开启触摸指示器，坐标窗才有数据来源。";
        if (coordEnabled) return @"坐标取自触摸指示器的采集通道，显示单位与圆点旁的小标签一致。";
    }
    return nil;
}

- (UITableViewCell *)valueCellWithIdentifier:(NSString *)cellID
                                       title:(NSString *)title
                                      detail:(NSString *)detail
                                   accessory:(UITableViewCellAccessoryType)accessory {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cellID];
    }
    cell.textLabel.text = title;
    cell.detailTextLabel.text = detail;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = accessory;
    cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    return cell;
}

- (TableViewCellWithSwitch *)switchCellWithTitle:(NSString *)title
                                          action:(SEL)action
                                              on:(BOOL)on {
    TableViewCellWithSwitch *cell = [self.tableView dequeueReusableCellWithIdentifier:@"SwitchCell"];
    [cell setTitleText:title];
    [cell.switchBtn removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [cell.switchBtn addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [cell.switchBtn setOn:on];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    return cell;
}

- (TableViewCellWithSlider *)sliderCellWithTitle:(NSString *)title
                                             min:(float)min
                                             max:(float)max
                                           value:(float)value
                                       valueText:(NSString *)valueText
                                             row:(NSInteger)row {
    TableViewCellWithSlider *cell = [self.tableView dequeueReusableCellWithIdentifier:@"SliderCell"];
    cell.title.text = title;
    cell.slideBar.tag = row;
    cell.slideBar.minimumValue = min;
    cell.slideBar.maximumValue = max;
    cell.slideBar.continuous = YES;
    cell.slideBar.value = value;
    cell.value.text = valueText;
    [cell.slideBar removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == ZXSectionIndicator) {
        NSMutableDictionary *touch = [self touchConfig];
        switch (indexPath.row) {
            case IndicatorRowSwitch:
                return [self switchCellWithTitle:@"触摸指示器" action:@selector(indicatorSwitchChanged:) on:isShowing];
            case IndicatorRowShowCoord:
                return [self switchCellWithTitle:@"显示坐标" action:@selector(showCoordinatesChanged:)
                                              on:[touch[@"show_coordinates"] boolValue]];
            case IndicatorRowDotColor:
                return [self valueCellWithIdentifier:@"DotColorCell" title:@"圆点颜色"
                                              detail:[self dotColorHex]
                                           accessory:UITableViewCellAccessoryDisclosureIndicator];
            case IndicatorRowDotAlpha: {
                float alpha = [[self dotColorConfig][@"alpha"] floatValue];
                TableViewCellWithSlider *cell = [self sliderCellWithTitle:@"不透明度" min:0.0f max:1.0f
                                                                    value:alpha
                                                                valueText:[NSString stringWithFormat:@"%.1f", alpha]
                                                                      row:indexPath.row];
                [cell.slideBar addTarget:self action:@selector(indicatorSliderChanged:) forControlEvents:UIControlEventValueChanged];
                return cell;
            }
            default: {
                NSInteger dotSize = [touch[@"dot_size"] integerValue];
                if (dotSize < DOT_SIZE_MIN) dotSize = DOT_SIZE_MIN;
                if (dotSize > DOT_SIZE_MAX) dotSize = DOT_SIZE_MAX;
                TableViewCellWithSlider *cell = [self sliderCellWithTitle:@"圆点大小" min:DOT_SIZE_MIN max:DOT_SIZE_MAX
                                                                    value:(float)dotSize
                                                                valueText:[NSString stringWithFormat:@"%ld pt", (long)dotSize]
                                                                      row:indexPath.row];
                [cell.slideBar addTarget:self action:@selector(indicatorSliderChanged:) forControlEvents:UIControlEventValueChanged];
                return cell;
            }
        }
    }

    // 坐标悬浮窗
    switch (indexPath.row) {
        case CoordRowSwitch: {
            TableViewCellWithSwitch *cell = [self switchCellWithTitle:@"坐标悬浮窗" action:@selector(coordSwitchChanged:) on:coordEnabled];
            cell.switchBtn.enabled = isShowing;   // 指示器没开时坐标没有数据来源
            return cell;
        }
        case CoordRowCorner:
            return [self valueCellWithIdentifier:@"CornerCell" title:@"位置" detail:cornerTitles[coordCorner]
                                       accessory:UITableViewCellAccessoryDisclosureIndicator];
        case CoordRowBgColor:
            return [self valueCellWithIdentifier:@"BgColorCell" title:@"背景颜色" detail:coordBgColorHex
                                       accessory:UITableViewCellAccessoryDisclosureIndicator];
        case CoordRowTextColor:
            return [self valueCellWithIdentifier:@"TextColorCell" title:@"文字颜色" detail:coordTextColorHex
                                       accessory:UITableViewCellAccessoryDisclosureIndicator];
        case CoordRowHideIdle:
            return [self switchCellWithTitle:@"无触碰时隐藏" action:@selector(coordHideIdleChanged:) on:coordHideWhenIdle];
        case CoordRowMultiMode:
            return [self valueCellWithIdentifier:@"MultiModeCell" title:@"多点触碰显示" detail:multiModeTitles[coordMultiMode]
                                       accessory:UITableViewCellAccessoryDisclosureIndicator];
        default: {
            NSString *title = @"字号", *valueText = nil;
            float min = kCoordFontMin, max = kCoordFontMax, value = coordFontSize;
            if (indexPath.row == CoordRowMarginX) {
                title = @"水平边距"; min = 0.0f; max = kCoordMarginXMax; value = coordMarginX;
                valueText = [NSString stringWithFormat:@"%.0f pt", value];
            } else if (indexPath.row == CoordRowMarginY) {
                title = @"垂直边距"; min = 0.0f; max = kCoordMarginYMax; value = coordMarginY;
                valueText = [NSString stringWithFormat:@"%.0f pt", value];
            } else if (indexPath.row == CoordRowBgAlpha) {
                title = @"背景透明度"; min = 0.0f; max = 1.0f; value = coordBgAlpha;
                valueText = [NSString stringWithFormat:@"%.2f", value];
            } else {
                valueText = [NSString stringWithFormat:@"%.1f", value];
            }
            TableViewCellWithSlider *cell = [self sliderCellWithTitle:title min:min max:max
                                                                value:value valueText:valueText row:indexPath.row];
            [cell.slideBar addTarget:self action:@selector(coordSliderChanged:) forControlEvents:UIControlEventValueChanged];
            [cell.slideBar addTarget:self action:@selector(coordSliderTouchUp:)
                    forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
            return cell;
        }
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 44.0f;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == ZXSectionIndicator) {
        if (indexPath.row == IndicatorRowDotColor) {
            [self pickDotColorAtIndexPath:indexPath];
        }
        return;
    }

    switch (indexPath.row) {
        case CoordRowCorner:   // 点按循环：右上 → 左上 → 左下 → 右下
            coordCorner = (coordCorner + 1) % cornerTitles.count;
            config[kCfgCoordCorner] = @(coordCorner);
            if ([self saveConfig]) [self reloadCoordConfig];
            [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
            break;
        case CoordRowBgColor:
            [self pickCoordColorForKey:kCfgCoordBgColor title:@"背景颜色" indexPath:indexPath];
            break;
        case CoordRowTextColor:
            [self pickCoordColorForKey:kCfgCoordTextColor title:@"文字颜色" indexPath:indexPath];
            break;
        case CoordRowMultiMode:   // 点按循环：第一个 → 最后一个 → 全部
            coordMultiMode = (coordMultiMode + 1) % multiModeTitles.count;
            config[kCfgCoordMultiMode] = @(coordMultiMode);
            if ([self saveConfig]) [self reloadCoordConfig];
            [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
            break;
        default:
            break;
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

@end
