//
//  FloatingMenuConfigurationViewController.m
//  zxtouch
//
//  Created by ZXTouch on 2026/10/1.
//

#import "FloatingMenuConfigurationViewController.h"
#import "TableViewCellWithSwitch.h"
#import "TableViewCellWithSlider.h"
#import "Config.h"
#import "Util.h"
#import "Socket.h"

static NSString *kCfgEnabled = @"floating_menu_enabled";
static NSString *kCfgEdge    = @"floating_menu_edge";     // 1=右 0=左
static NSString *kCfgYRatio  = @"floating_menu_y_ratio"; // 0..1
static NSString *kCfgDotSize = @"floating_menu_dot_size"; // 32..80 pt
static NSString *kCfgMenuBgAlpha = @"floating_menu_menu_bg_alpha"; // 0..1

// 圆点大小范围（与 tweak 端 kFMDotMinSize / kFMDotMaxSize 保持一致）
static const float kDotSizeMin     = 32.0f;
static const float kDotSizeMax     = 80.0f;
static const float kDotSizeDefault = 48.0f;

// 菜单黑底透明度（与 tweak 端 kFMMenuDefaultBgAlpha 保持一致）
static const float kMenuBgAlphaDefault = 0.92f;

// 「外观」分组行号
typedef NS_ENUM(NSInteger, AppearanceRow) {
    AppearanceRowDotSize     = 0,
    AppearanceRowMenuBgAlpha = 1
};

@interface FloatingMenuConfigurationViewController ()

@end

@implementation FloatingMenuConfigurationViewController
{
    NSMutableDictionary *_config;
    Socket *_springBoardSocket;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"控制按钮悬浮窗";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

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

    UINib *switchNib = [UINib nibWithNibName:@"TableViewCellWithSwitch" bundle:nil];
    [_tableView registerNib:switchNib forCellReuseIdentifier:@"SwitchCell"];

    UINib *sliderNib = [UINib nibWithNibName:@"TableViewCellWithSlider" bundle:nil];
    [_tableView registerNib:sliderNib forCellReuseIdentifier:@"SliderCell"];

    _springBoardSocket = [[Socket alloc] init];
    [_springBoardSocket connect:@"127.0.0.1" byPort:6000];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _config = [NSMutableDictionary dictionaryWithContentsOfFile:SPRINGBOARD_CONFIG_PATH];
    if (!_config) _config = [NSMutableDictionary dictionary];
    [_tableView reloadData];
}

#pragma mark - 读写配置

- (void)saveConfig {
    if (![_config writeToFile:SPRINGBOARD_CONFIG_PATH atomically:YES]) {
        [Util showAlertBoxWithOneOption:self title:@"错误" message:@"无法保存设置。" buttonString:@"确定"];
    }
}

- (void)reloadTweak {
    [_springBoardSocket send:@"32;;3\r\n"];
}

#pragma mark - 开关

- (void)switchEnabled:(id)sender {
    UISwitch *s = (UISwitch *)sender;
    _config[kCfgEnabled] = @([s isOn]);
    [self saveConfig];
    int action = [s isOn] ? 1 : 0;
    NSString *cmd = [NSString stringWithFormat:@"32;;%d\r\n", action];
    [_springBoardSocket send:cmd];
}

#pragma mark - 吸附边

- (void)edgeSegmentChanged:(UISegmentedControl *)seg {
    _config[kCfgEdge] = @(seg.selectedSegmentIndex); // 0=左 1=右
    [self saveConfig];
    [self reloadTweak];
}

#pragma mark - 纵向比例

- (void)yRatioValueChanged:(id)sender {
    UISlider *slider = (UISlider *)sender;
    // 显示实时数值
    UIView *view = slider;
    while (view && ![view isKindOfClass:[TableViewCellWithSlider class]]) {
        view = view.superview;
    }
    if ([view isKindOfClass:[TableViewCellWithSlider class]]) {
        ((TableViewCellWithSlider *)view).value.text = [NSString stringWithFormat:@"%.2f", slider.value];
    }
    // 拖动过程中只写 plist，松手才 reload
    _config[kCfgYRatio] = @(slider.value);
    [self saveConfig];
}

#pragma mark - 圆点大小

- (void)dotSizeValueChanged:(id)sender {
    UISlider *slider = (UISlider *)sender;
    float stepped = roundf(slider.value);
    [slider setValue:stepped animated:NO];
    // 显示实时数值
    UIView *view = slider;
    while (view && ![view isKindOfClass:[TableViewCellWithSlider class]]) {
        view = view.superview;
    }
    if ([view isKindOfClass:[TableViewCellWithSlider class]]) {
        ((TableViewCellWithSlider *)view).value.text = [NSString stringWithFormat:@"%.0f pt", stepped];
    }
    // 拖动过程中只写 plist，松手才 reload
    _config[kCfgDotSize] = @((NSInteger)stepped);
    [self saveConfig];
}

#pragma mark - 菜单黑底透明度

- (void)menuBgAlphaValueChanged:(id)sender {
    UISlider *slider = (UISlider *)sender;
    float stepped = roundf(slider.value * 100.0f) / 100.0f;
    [slider setValue:stepped animated:NO];
    // 显示实时数值
    UIView *view = slider;
    while (view && ![view isKindOfClass:[TableViewCellWithSlider class]]) {
        view = view.superview;
    }
    if ([view isKindOfClass:[TableViewCellWithSlider class]]) {
        ((TableViewCellWithSlider *)view).value.text = [NSString stringWithFormat:@"%.2f", stepped];
    }
    // 拖动过程中只写 plist，松手才 reload
    _config[kCfgMenuBgAlpha] = @(stepped);
    [self saveConfig];
}

// 任意滑块松手后统一通知 tweak 重载配置
- (void)sliderTouchUp:(id)sender {
    [self reloadTweak];
}

#pragma mark - UITableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1; // 开关
    if (section == 1) return 2; // 吸附边 + 纵向比例
    return 2;                   // 外观：圆点大小 + 菜单黑底透明度
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"开关";
    if (section == 1) return @"位置";
    return @"外观";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        // 开关
        TableViewCellWithSwitch *cell = [tableView dequeueReusableCellWithIdentifier:@"SwitchCell" forIndexPath:indexPath];
        [cell setTitleText:@"控制按钮悬浮窗"];
        [cell.switchBtn removeTarget:nil action:NULL forControlEvents:UIControlEventValueChanged];
        [cell.switchBtn addTarget:self action:@selector(switchEnabled:) forControlEvents:UIControlEventValueChanged];
        BOOL enabled = [_config[kCfgEnabled] boolValue];
        [cell.switchBtn setOn:enabled];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    // section 1 row 0：吸附边 — 用 Entry cell 包装一个 segment
    if (indexPath.section == 1 && indexPath.row == 0) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"EdgeCell"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"EdgeCell"];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        cell.textLabel.text = @"吸附边";

        UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"左侧", @"右侧"]];
        seg.selectedSegmentIndex = [_config[kCfgEdge] intValue];
        seg.frame = CGRectMake(cell.contentView.bounds.size.width - 130, 6, 120, 32);
        seg.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [seg addTarget:self action:@selector(edgeSegmentChanged:) forControlEvents:UIControlEventValueChanged];

        // 移除旧的
        for (UIView *v in cell.contentView.subviews) {
            if ([v isKindOfClass:[UISegmentedControl class]]) [v removeFromSuperview];
        }
        [cell.contentView addSubview:seg];
        return cell;
    }

    // 滑块（section 1 row 1 = 纵向位置；section 2 = 外观：圆点大小 / 菜单黑底透明度）
    TableViewCellWithSlider *cell = [tableView dequeueReusableCellWithIdentifier:@"SliderCell" forIndexPath:indexPath];
    cell.slideBar.continuous = YES;
    [cell.slideBar removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];

    SEL changedSelector = @selector(yRatioValueChanged:);
    if (indexPath.section == 2) {
        changedSelector = (indexPath.row == AppearanceRowDotSize) ? @selector(dotSizeValueChanged:)
                                                                  : @selector(menuBgAlphaValueChanged:);
    }
    [cell.slideBar addTarget:self action:changedSelector forControlEvents:UIControlEventValueChanged];
    [cell.slideBar addTarget:self action:@selector(sliderTouchUp:)
            forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];

    if (indexPath.section == 2 && indexPath.row == AppearanceRowDotSize) {
        float dotSize = _config[kCfgDotSize] ? [_config[kCfgDotSize] floatValue] : kDotSizeDefault;
        if (dotSize < kDotSizeMin || dotSize > kDotSizeMax) dotSize = kDotSizeDefault;
        cell.title.text = @"圆点大小";
        cell.slideBar.minimumValue = kDotSizeMin;
        cell.slideBar.maximumValue = kDotSizeMax;
        cell.slideBar.value = dotSize;
        cell.value.text = [NSString stringWithFormat:@"%.0f pt", dotSize];
    } else if (indexPath.section == 2) {
        float bgAlpha = _config[kCfgMenuBgAlpha] ? [_config[kCfgMenuBgAlpha] floatValue] : kMenuBgAlphaDefault;
        if (bgAlpha < 0.0f || bgAlpha > 1.0f) bgAlpha = kMenuBgAlphaDefault;
        cell.title.text = @"菜单黑底透明度";
        cell.slideBar.minimumValue = 0.0f;
        cell.slideBar.maximumValue = 1.0f;
        cell.slideBar.value = bgAlpha;
        cell.value.text = [NSString stringWithFormat:@"%.2f", bgAlpha];
    } else {
        float ratio = [_config[kCfgYRatio] floatValue];
        cell.title.text = @"纵向位置";
        cell.slideBar.minimumValue = 0.0f;
        cell.slideBar.maximumValue = 1.0f;
        cell.slideBar.value = ratio;
        cell.value.text = [NSString stringWithFormat:@"%.2f", ratio];
    }
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

@end
