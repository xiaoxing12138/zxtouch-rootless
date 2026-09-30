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

@interface FloatingMenuConfigurationViewController ()

@end

@implementation FloatingMenuConfigurationViewController
{
    NSMutableDictionary *_config;
    Socket *_springBoardSocket;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"悬浮控制按钮";

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

- (void)yRatioSliderTouchUp:(id)sender {
    [self reloadTweak];
}

#pragma mark - UITableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1; // 开关
    return 2; // 吸附边 + 纵向比例
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"开关" : @"位置";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        // 开关
        TableViewCellWithSwitch *cell = [tableView dequeueReusableCellWithIdentifier:@"SwitchCell" forIndexPath:indexPath];
        [cell setTitleText:@"悬浮控制按钮"];
        [cell.switchBtn removeTarget:nil action:NULL forControlEvents:UIControlEventValueChanged];
        [cell.switchBtn addTarget:self action:@selector(switchEnabled:) forControlEvents:UIControlEventValueChanged];
        BOOL enabled = [_config[kCfgEnabled] boolValue];
        [cell.switchBtn setOn:enabled];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    // section 1
    if (indexPath.row == 0) {
        // 吸附边 — 用 Entry cell 包装一个 segment
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

    // 纵向比例滑块
    TableViewCellWithSlider *cell = [tableView dequeueReusableCellWithIdentifier:@"SliderCell" forIndexPath:indexPath];
    cell.title.text = @"纵向位置";
    cell.slideBar.minimumValue = 0.0f;
    cell.slideBar.maximumValue = 1.0f;
    cell.slideBar.continuous = YES;
    [cell.slideBar removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [cell.slideBar addTarget:self action:@selector(yRatioValueChanged:) forControlEvents:UIControlEventValueChanged];
    [cell.slideBar addTarget:self action:@selector(yRatioSliderTouchUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    float ratio = [_config[kCfgYRatio] floatValue];
    cell.slideBar.value = ratio;
    cell.value.text = [NSString stringWithFormat:@"%.2f", ratio];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

@end
