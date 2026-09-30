//
//  TouchCoordinateConfigurationViewController.m
//  zxtouch
//
//  触摸坐标悬浮窗设置详情页。
//  坐标数据来自「触摸指示器」的采集通道，因此需先开启触摸指示器才会刷新。
//

#import "TouchCoordinateConfigurationViewController.h"
#import "TableViewCellWithSwitch.h"
#import "TableViewCellWithSlider.h"
#import "Config.h"
#import "ConfigManager.h"
#import "Socket.h"

// 配置键（与 SpringBoard 端 tweak 的 common config 对应，文件为 SPRINGBOARD_CONFIG_PATH）
static NSString * const kCoordEnabledKey  = @"touch_coord_enabled";
static NSString * const kCoordCornerKey   = @"touch_coord_corner";
static NSString * const kCoordFontSizeKey = @"touch_coord_font_size";
static NSString * const kCoordMarginXKey  = @"touch_coord_margin_x";
static NSString * const kCoordMarginYKey  = @"touch_coord_margin_y";
static NSString * const kCoordBgColorKey  = @"touch_coord_bg_color";
static NSString * const kCoordBgAlphaKey  = @"touch_coord_bg_alpha";
static NSString * const kCoordTextColorKey = @"touch_coord_text_color";
static NSString * const kCoordHideIdleKey = @"touch_coord_hide_when_idle";
static NSString * const kCoordMultiModeKey = @"touch_coord_multi_mode";

// 默认值（与 tweak 端保持一致）
static const NSInteger kCoordDefaultCorner    = 0;      // 0=右上 1=左上 2=左下 3=右下
static const float     kCoordDefaultFontSize  = 11.0f;  // 8.0 - 20.0，步长 0.5
static const NSInteger kCoordDefaultMarginX   = 10;     // 0 - 500 pt
static const NSInteger kCoordDefaultMarginY   = 10;     // 0 - 200 pt
static NSString * const kCoordDefaultBgColor   = @"#000000";
static const float     kCoordDefaultBgAlpha    = 0.4f;  // 0.0 - 1.0，步长 0.05
static NSString * const kCoordDefaultTextColor = @"#FFFFFF";
static const BOOL      kCoordDefaultHideIdle   = NO;
static const NSInteger kCoordDefaultMultiMode  = 1;     // 0=第一个 1=最后一个 2=全部

typedef NS_ENUM(NSInteger, CoordSection) {
    CoordSectionSwitch  = 0,  // 总开关
    CoordSectionDisplay = 1,  // 显示
    CoordSectionBehavior = 2, // 行为
    CoordSectionAbout   = 3   // 关于
};

typedef NS_ENUM(NSInteger, CoordDisplayRow) {
    CoordDisplayRowCorner  = 0,  // 位置
    CoordDisplayRowFont    = 1,  // 字号
    CoordDisplayRowMarginX = 2,  // 水平边距
    CoordDisplayRowMarginY = 3,  // 垂直边距
    CoordDisplayRowBgColor = 4,  // 背景颜色
    CoordDisplayRowBgAlpha = 5,  // 背景透明度
    CoordDisplayRowTextColor = 6 // 文字颜色
};

typedef NS_ENUM(NSInteger, CoordBehaviorRow) {
    CoordBehaviorRowHideIdle = 0,  // 无触碰时隐藏
    CoordBehaviorRowMultiMode = 1  // 多点触碰显示
};

static const NSInteger kCoordAboutTextLabelTag = 9101;
static NSString * const kCoordAboutText = @"修改后立即生效。\n本悬浮窗的坐标来自「触摸指示器」的采集通道，请先在『设置 → 触摸指示器』中开启指示器，坐标才会刷新。\n显示单位为像素，与触摸指示器圆点右侧的小标签一致。";

@interface TouchCoordinateConfigurationViewController ()

@end

@implementation TouchCoordinateConfigurationViewController
{
    ConfigManager *configManager;
    BOOL enabled;
    NSInteger cornerPosition;
    float fontSize;
    NSInteger marginX;
    NSInteger marginY;
    NSString *bgColorHex;
    float bgAlpha;
    NSString *textColorHex;
    BOOL hideWhenIdle;
    NSInteger multiMode;
    NSArray<NSString *> *cornerTitles;
    NSArray<NSString *> *multiModeTitles;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"触摸坐标悬浮窗";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    cornerTitles = @[@"右上", @"左上", @"左下", @"右下"];
    multiModeTitles = @[@"第一个触点", @"最后一个触点", @"全部触点"];

    // 该页面不使用 storyboard/xib，tableView 全部以代码搭建（cell 仍复用现有 nib）
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

    UINib *switchCellNib = [UINib nibWithNibName:@"TableViewCellWithSwitch" bundle:nil];
    [_tableView registerNib:switchCellNib forCellReuseIdentifier:@"SwitchCell"];

    UINib *sliderCellNib = [UINib nibWithNibName:@"TableViewCellWithSlider" bundle:nil];
    [_tableView registerNib:sliderCellNib forCellReuseIdentifier:@"SliderCell"];

    [self loadConfig];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadConfig];
    [_tableView reloadData];
}

#pragma mark - 配置读写

- (void)loadConfig {
    configManager = [[ConfigManager alloc] initWithPath:SPRINGBOARD_CONFIG_PATH];

    NSNumber *enabledValue = [configManager getValueFromKey:kCoordEnabledKey];
    enabled = enabledValue ? [enabledValue boolValue] : NO;

    NSNumber *cornerValue = [configManager getValueFromKey:kCoordCornerKey];
    cornerPosition = cornerValue ? [cornerValue integerValue] : kCoordDefaultCorner;
    if (cornerPosition < 0 || cornerPosition >= (NSInteger)cornerTitles.count) {
        cornerPosition = kCoordDefaultCorner;
    }

    NSNumber *fontSizeValue = [configManager getValueFromKey:kCoordFontSizeKey];
    fontSize = fontSizeValue ? [fontSizeValue floatValue] : kCoordDefaultFontSize;
    if (fontSize < 8.0f || fontSize > 20.0f) {
        fontSize = kCoordDefaultFontSize;
    }

    NSNumber *marginXValue = [configManager getValueFromKey:kCoordMarginXKey];
    marginX = marginXValue ? [marginXValue integerValue] : kCoordDefaultMarginX;
    if (marginX < 0 || marginX > 500) {
        marginX = kCoordDefaultMarginX;
    }

    NSNumber *marginYValue = [configManager getValueFromKey:kCoordMarginYKey];
    marginY = marginYValue ? [marginYValue integerValue] : kCoordDefaultMarginY;
    if (marginY < 0 || marginY > 200) {
        marginY = kCoordDefaultMarginY;
    }

    NSString *bgValue = [configManager getValueFromKey:kCoordBgColorKey];
    bgColorHex = [bgValue isKindOfClass:[NSString class]] ? bgValue : kCoordDefaultBgColor;

    NSNumber *bgAlphaValue = [configManager getValueFromKey:kCoordBgAlphaKey];
    bgAlpha = bgAlphaValue ? [bgAlphaValue floatValue] : kCoordDefaultBgAlpha;
    if (bgAlpha < 0.0f || bgAlpha > 1.0f) {
        bgAlpha = kCoordDefaultBgAlpha;
    }

    NSString *textValue = [configManager getValueFromKey:kCoordTextColorKey];
    textColorHex = [textValue isKindOfClass:[NSString class]] ? textValue : kCoordDefaultTextColor;

    NSNumber *hideIdleValue = [configManager getValueFromKey:kCoordHideIdleKey];
    hideWhenIdle = hideIdleValue ? [hideIdleValue boolValue] : kCoordDefaultHideIdle;

    NSNumber *multiValue = [configManager getValueFromKey:kCoordMultiModeKey];
    multiMode = multiValue ? [multiValue integerValue] : kCoordDefaultMultiMode;
    if (multiMode < 0 || multiMode >= (NSInteger)multiModeTitles.count) {
        multiMode = kCoordDefaultMultiMode;
    }
}

- (void)persistKey:(NSString *)key value:(id)value {
    [configManager updateKey:key forValue:value];
    [configManager save];
}

// 通知 SpringBoard 端 tweak 重新加载配置（42;;3 = 重新加载配置）
- (void)notifyTweak {
    Socket *socket = [[Socket alloc] init];
    if ([socket connect:@"127.0.0.1" byPort:6000] == 0) {
        [socket send:@"42;;3\r\n"];
        [socket close];
    }
}

#pragma mark - 控件事件

- (void)enabledChanged:(UISwitch *)s {
    enabled = [s isOn];
    [self persistKey:kCoordEnabledKey value:@(enabled)];

    Socket *socket = [[Socket alloc] init];
    if ([socket connect:@"127.0.0.1" byPort:6000] == 0) {
        NSString *cmd = [NSString stringWithFormat:@"42;;%d\r\n", enabled ? 1 : 0];
        [socket send:cmd];
        [socket close];
    }
}

- (void)hideIdleChanged:(UISwitch *)s {
    hideWhenIdle = [s isOn];
    [self persistKey:kCoordHideIdleKey value:@(hideWhenIdle)];
    [self notifyTweak];
}

- (void)fontSizeChanged:(UISlider *)slider {
    float stepped = 0.5f * roundf(slider.value / 0.5f);
    [slider setValue:stepped animated:NO];
    fontSize = stepped;

    TableViewCellWithSlider *cell = [self.tableView cellForRowAtIndexPath:
        [NSIndexPath indexPathForRow:CoordDisplayRowFont inSection:CoordSectionDisplay]];
    cell.value.text = [NSString stringWithFormat:@"%.1f", stepped];

    [self persistKey:kCoordFontSizeKey value:@(stepped)];
}

- (void)marginXChanged:(UISlider *)slider {
    float stepped = roundf(slider.value);
    [slider setValue:stepped animated:NO];
    marginX = (NSInteger)stepped;

    TableViewCellWithSlider *cell = [self.tableView cellForRowAtIndexPath:
        [NSIndexPath indexPathForRow:CoordDisplayRowMarginX inSection:CoordSectionDisplay]];
    cell.value.text = [NSString stringWithFormat:@"%ld pt", (long)marginX];

    [self persistKey:kCoordMarginXKey value:@((NSInteger)stepped)];
}

- (void)marginYChanged:(UISlider *)slider {
    float stepped = roundf(slider.value);
    [slider setValue:stepped animated:NO];
    marginY = (NSInteger)stepped;

    TableViewCellWithSlider *cell = [self.tableView cellForRowAtIndexPath:
        [NSIndexPath indexPathForRow:CoordDisplayRowMarginY inSection:CoordSectionDisplay]];
    cell.value.text = [NSString stringWithFormat:@"%ld pt", (long)marginY];

    [self persistKey:kCoordMarginYKey value:@((NSInteger)stepped)];
}

- (void)bgAlphaChanged:(UISlider *)slider {
    float stepped = 0.05f * roundf(slider.value / 0.05f);
    [slider setValue:stepped animated:NO];
    bgAlpha = stepped;

    TableViewCellWithSlider *cell = [self.tableView cellForRowAtIndexPath:
        [NSIndexPath indexPathForRow:CoordDisplayRowBgAlpha inSection:CoordSectionDisplay]];
    cell.value.text = [NSString stringWithFormat:@"%.2f", stepped];

    [self persistKey:kCoordBgAlphaKey value:@(stepped)];
}

// 滑块松手时再通知一次，避免拖动过程中频繁建立 socket 连接
- (void)sliderTouchFinished:(UISlider *)slider {
    [self notifyTweak];
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
                        onPicked:(void (^)(NSString *))onPicked {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
        message:[NSString stringWithFormat:@"当前：%@", current]
        preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSArray<NSString *> *pair in presets) {
        NSString *name = pair.firstObject;
        NSString *hex = pair.lastObject;
        [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@  %@", name, hex]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            onPicked(hex);
        }]];
    }

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
            if (![self isValidHexColor:input]) {
                return;
            }
            onPicked([input uppercaseString]);
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop) {
        pop.sourceView = self.tableView;
        pop.sourceRect = self.tableView.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)pickBgColor:(UITableViewCell *)cell {
    NSArray *presets = @[
        @[@"黑色", @"#000000"], @[@"白色", @"#FFFFFF"], @[@"红色", @"#FF3B30"],
        @[@"绿色", @"#34C759"], @[@"蓝色", @"#007AFF"], @[@"橙色", @"#FF9500"]
    ];
    __weak TouchCoordinateConfigurationViewController *weakSelf = self;
    [self presentColorPickerForTitle:@"背景颜色" current:bgColorHex presets:presets onPicked:^(NSString *hex) {
        TouchCoordinateConfigurationViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->bgColorHex = hex;
        [strongSelf persistKey:kCoordBgColorKey value:hex];
        [strongSelf notifyTweak];
        [strongSelf.tableView reloadData];
    }];
}

- (void)pickTextColor:(UITableViewCell *)cell {
    NSArray *presets = @[
        @[@"白色", @"#FFFFFF"], @[@"黑色", @"#000000"], @[@"黄色", @"#FFEE00"],
        @[@"红色", @"#FF3B30"], @[@"绿色", @"#34C759"], @[@"蓝色", @"#007AFF"]
    ];
    __weak TouchCoordinateConfigurationViewController *weakSelf = self;
    [self presentColorPickerForTitle:@"文字颜色" current:textColorHex presets:presets onPicked:^(NSString *hex) {
        TouchCoordinateConfigurationViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->textColorHex = hex;
        [strongSelf persistKey:kCoordTextColorKey value:hex];
        [strongSelf notifyTweak];
        [strongSelf.tableView reloadData];
    }];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;  // 开关 / 显示 / 行为 / 关于
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == CoordSectionSwitch)   return 1;
    if (section == CoordSectionDisplay)  return 7;  // 位置/字号/水平边距/垂直边距/背景色/背景透明度/文字色
    if (section == CoordSectionBehavior) return 2;  // 无触碰时隐藏 / 多点触碰显示
    return 1;                                       // 关于说明行
}

- (void)configureSliderCell:(TableViewCellWithSlider *)cell
                      title:(NSString *)title
                        min:(float)min
                        max:(float)max
                      value:(float)value
                  valueText:(NSString *)valueText
                    changed:(SEL)changedSelector {
    cell.title.text = title;
    cell.slideBar.minimumValue = min;
    cell.slideBar.maximumValue = max;
    cell.slideBar.continuous = YES;
    [cell.slideBar removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [cell.slideBar addTarget:self action:changedSelector forControlEvents:UIControlEventValueChanged];
    [cell.slideBar addTarget:self action:@selector(sliderTouchFinished:)
           forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    cell.slideBar.value = value;
    cell.value.text = valueText;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
}

- (UITableViewCell *)valueCellWithIdentifier:(NSString *)cellID
                                       title:(NSString *)title
                                      detail:(NSString *)detail
                                   accessory:(UITableViewCellAccessoryType)accessory {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:cellID];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cellID];
    }
    cell.textLabel.text = title;
    cell.detailTextLabel.text = detail;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = accessory;
    cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == CoordSectionSwitch) {
        TableViewCellWithSwitch *cell = [tableView dequeueReusableCellWithIdentifier:@"SwitchCell"];
        if (cell == nil) {
            cell = [[TableViewCellWithSwitch alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"SwitchCell"];
        }
        [cell setTitleText:@"触摸坐标悬浮窗"];
        [cell.switchBtn removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
        [cell.switchBtn addTarget:self action:@selector(enabledChanged:) forControlEvents:UIControlEventValueChanged];
        [cell.switchBtn setOn:enabled];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        return cell;
    }

    if (indexPath.section == CoordSectionDisplay) {
        if (indexPath.row == CoordDisplayRowCorner) {
            return [self valueCellWithIdentifier:@"CornerCell" title:@"位置"
                                          detail:cornerTitles[cornerPosition]
                                       accessory:UITableViewCellAccessoryNone];
        }
        if (indexPath.row == CoordDisplayRowBgColor) {
            return [self valueCellWithIdentifier:@"BgColorCell" title:@"背景颜色"
                                          detail:bgColorHex
                                       accessory:UITableViewCellAccessoryDisclosureIndicator];
        }
        if (indexPath.row == CoordDisplayRowTextColor) {
            return [self valueCellWithIdentifier:@"TextColorCell" title:@"文字颜色"
                                          detail:textColorHex
                                       accessory:UITableViewCellAccessoryDisclosureIndicator];
        }

        TableViewCellWithSlider *cell = [tableView dequeueReusableCellWithIdentifier:@"SliderCell"];
        if (cell == nil) {
            cell = [[TableViewCellWithSlider alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"SliderCell"];
        }
        if (indexPath.row == CoordDisplayRowFont) {
            [self configureSliderCell:cell title:@"字号" min:8.0f max:20.0f value:fontSize
                            valueText:[NSString stringWithFormat:@"%.1f", fontSize]
                              changed:@selector(fontSizeChanged:)];
        } else if (indexPath.row == CoordDisplayRowMarginX) {
            [self configureSliderCell:cell title:@"水平边距" min:0.0f max:500.0f value:(float)marginX
                            valueText:[NSString stringWithFormat:@"%ld pt", (long)marginX]
                              changed:@selector(marginXChanged:)];
        } else if (indexPath.row == CoordDisplayRowMarginY) {
            [self configureSliderCell:cell title:@"垂直边距" min:0.0f max:200.0f value:(float)marginY
                            valueText:[NSString stringWithFormat:@"%ld pt", (long)marginY]
                              changed:@selector(marginYChanged:)];
        } else {
            [self configureSliderCell:cell title:@"背景透明度" min:0.0f max:1.0f value:bgAlpha
                            valueText:[NSString stringWithFormat:@"%.2f", bgAlpha]
                              changed:@selector(bgAlphaChanged:)];
        }
        return cell;
    }

    if (indexPath.section == CoordSectionBehavior) {
        if (indexPath.row == CoordBehaviorRowHideIdle) {
            TableViewCellWithSwitch *cell = [tableView dequeueReusableCellWithIdentifier:@"SwitchCell"];
            if (cell == nil) {
                cell = [[TableViewCellWithSwitch alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"SwitchCell"];
            }
            [cell setTitleText:@"无触碰时隐藏"];
            [cell.switchBtn removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
            [cell.switchBtn addTarget:self action:@selector(hideIdleChanged:) forControlEvents:UIControlEventValueChanged];
            [cell.switchBtn setOn:hideWhenIdle];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
            return cell;
        }
        return [self valueCellWithIdentifier:@"MultiModeCell" title:@"多点触碰显示"
                                      detail:multiModeTitles[multiMode]
                                   accessory:UITableViewCellAccessoryNone];
    }

    // 关于：只读多行说明
    static NSString *aboutCellID = @"AboutCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:aboutCellID];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:aboutCellID];
        UILabel *label = [[UILabel alloc] init];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.numberOfLines = 0;
        label.font = [UIFont systemFontOfSize:13];
        label.textColor = [UIColor secondaryLabelColor];
        label.tag = kCoordAboutTextLabelTag;
        [cell.contentView addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
            [label.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
            [label.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
            [label.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10]
        ]];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    }
    UILabel *aboutLabel = (UILabel *)[cell.contentView viewWithTag:kCoordAboutTextLabelTag];
    aboutLabel.text = kCoordAboutText;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == CoordSectionDisplay) {
        // 位置行点按循环：右上 -> 左上 -> 左下 -> 右下 -> 右上
        if (indexPath.row == CoordDisplayRowCorner) {
            cornerPosition = (cornerPosition + 1) % cornerTitles.count;
            [self persistKey:kCoordCornerKey value:@(cornerPosition)];
            [self notifyTweak];
            [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
        } else if (indexPath.row == CoordDisplayRowBgColor) {
            [self pickBgColor:[tableView cellForRowAtIndexPath:indexPath]];
        } else if (indexPath.row == CoordDisplayRowTextColor) {
            [self pickTextColor:[tableView cellForRowAtIndexPath:indexPath]];
        }
        return;
    }

    // 多点模式循环：第一个 -> 最后一个 -> 全部 -> 第一个
    if (indexPath.section == CoordSectionBehavior && indexPath.row == CoordBehaviorRowMultiMode) {
        multiMode = (multiMode + 1) % multiModeTitles.count;
        [self persistKey:kCoordMultiModeKey value:@(multiMode)];
        [self notifyTweak];
        [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == CoordSectionAbout) {
        CGRect rect = [kCoordAboutText boundingRectWithSize:CGSizeMake(tableView.bounds.size.width - 32.0f, CGFLOAT_MAX)
                                                    options:NSStringDrawingUsesLineFragmentOrigin
                                                 attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13]}
                                                    context:nil];
        return ceil(rect.size.height) + 20.0f;  // 上下各 10pt 间距
    }
    return 44.0f;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    UIView *headerView = [[UIView alloc] init];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    title.textColor = [UIColor secondaryLabelColor];

    if (section == CoordSectionSwitch)        title.text = @"开关";
    else if (section == CoordSectionDisplay)  title.text = @"显示";
    else if (section == CoordSectionBehavior) title.text = @"行为";
    else                                      title.text = @"关于";

    [headerView addSubview:title];
    [NSLayoutConstraint activateConstraints:@[
        [title.leftAnchor constraintEqualToAnchor:headerView.leftAnchor constant:20],
        [title.bottomAnchor constraintEqualToAnchor:headerView.bottomAnchor constant:-5]
    ]];

    return headerView;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return 38.0f;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == CoordSectionSwitch) {
        return @"坐标来自「触摸指示器」的采集通道，请先在『设置 → 触摸指示器』中开启指示器。";
    }
    if (section == CoordSectionBehavior) {
        return @"「全部触点」会在悬浮窗内按行显示每个正在触摸的手指。";
    }
    return nil;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

@end