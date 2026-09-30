//
//  NetSpeedConfigurationViewController.m
//  zxtouch
//
//  网速指示器设置详情页（位置 / 字号 / 边距 / 息屏暂停）
//

#import "NetSpeedConfigurationViewController.h"
#import "TableViewCellWithSwitch.h"
#import "TableViewCellWithSlider.h"
#import "Config.h"
#import "ConfigManager.h"
#import "Socket.h"

// 配置键（与 SpringBoard 端 tweak 的 common config 对应，文件为 SPRINGBOARD_CONFIG_PATH）
static NSString * const kNetSpeedCornerKey        = @"net_speed_corner";
static NSString * const kNetSpeedFontSizeKey      = @"net_speed_font_size";
static NSString * const kNetSpeedMarginKey        = @"net_speed_margin";
static NSString * const kNetSpeedPauseScreenOffKey = @"net_speed_pause_screen_off";

// 默认值
static const NSInteger kNetSpeedDefaultCorner    = 0;      // 0=右上 1=左上 2=左下 3=右下
static const float     kNetSpeedDefaultFontSize  = 11.0f;  // 8.0 - 20.0，步长 0.5
static const NSInteger kNetSpeedDefaultMargin    = 10;     // 4 - 60 pt，步长 1
static const BOOL      kNetSpeedDefaultPauseOff  = YES;

typedef NS_ENUM(NSInteger, NetSpeedSection) {
    NetSpeedSectionDisplay = 0,  // 显示
    NetSpeedSectionPower   = 1,  // 省电
    NetSpeedSectionAbout   = 2   // 关于
};

typedef NS_ENUM(NSInteger, NetSpeedDisplayRow) {
    NetSpeedDisplayRowCorner = 0,  // 位置
    NetSpeedDisplayRowFont   = 1,  // 字号
    NetSpeedDisplayRowMargin = 2   // 边距
};

static const NSInteger kAboutTextLabelTag = 9001;

@interface NetSpeedConfigurationViewController ()

@end

@implementation NetSpeedConfigurationViewController
{
    ConfigManager *configManager;
    NSInteger cornerPosition;
    float fontSize;
    NSInteger margin;
    BOOL pauseScreenOff;
    NSArray<NSString *> *cornerTitles;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"网速指示器";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    cornerTitles = @[@"右上", @"左上", @"左下", @"右下"];

    // 该页面不使用 storyboard/xib， tableView 全部以代码搭建（cell 仍复用现有 nib）
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
    // 每次出现都重新读文件，避免显示陈旧值
    [self loadConfig];
    [_tableView reloadData];
}

#pragma mark - 配置读写

- (void)loadConfig {
    configManager = [[ConfigManager alloc] initWithPath:SPRINGBOARD_CONFIG_PATH];

    NSNumber *cornerValue = [configManager getValueFromKey:kNetSpeedCornerKey];
    cornerPosition = cornerValue ? [cornerValue integerValue] : kNetSpeedDefaultCorner;
    if (cornerPosition < 0 || cornerPosition >= (NSInteger)cornerTitles.count) {
        cornerPosition = kNetSpeedDefaultCorner;
    }

    NSNumber *fontSizeValue = [configManager getValueFromKey:kNetSpeedFontSizeKey];
    fontSize = fontSizeValue ? [fontSizeValue floatValue] : kNetSpeedDefaultFontSize;
    if (fontSize < 8.0f || fontSize > 20.0f) {
        fontSize = kNetSpeedDefaultFontSize;
    }

    NSNumber *marginValue = [configManager getValueFromKey:kNetSpeedMarginKey];
    margin = marginValue ? [marginValue integerValue] : kNetSpeedDefaultMargin;
    if (margin < 4 || margin > 60) {
        margin = kNetSpeedDefaultMargin;
    }

    NSNumber *pauseValue = [configManager getValueFromKey:kNetSpeedPauseScreenOffKey];
    pauseScreenOff = pauseValue ? [pauseValue boolValue] : kNetSpeedDefaultPauseOff;
}

- (void)persistKey:(NSString *)key value:(id)value {
    [configManager updateKey:key forValue:value];
    [configManager save];
}

// 通知 SpringBoard 端 tweak 重新加载配置（31;;3 = 重新加载配置）
- (void)notifyTweak {
    Socket *socket = [[Socket alloc] init];
    if ([socket connect:@"127.0.0.1" byPort:6000] == 0) {
        [socket send:@"31;;3\r\n"];
        [socket close];
    }
}

#pragma mark - 控件事件

- (void)pauseScreenOffChanged:(UISwitch *)s {
    pauseScreenOff = [s isOn];
    [self persistKey:kNetSpeedPauseScreenOffKey value:@(pauseScreenOff)];
    [self notifyTweak];
}

- (void)fontSizeChanged:(UISlider *)slider {
    float stepped = 0.5f * roundf(slider.value / 0.5f);
    [slider setValue:stepped animated:NO];
    fontSize = stepped;

    TableViewCellWithSlider *cell = [self.tableView cellForRowAtIndexPath:
        [NSIndexPath indexPathForRow:NetSpeedDisplayRowFont inSection:NetSpeedSectionDisplay]];
    cell.value.text = [NSString stringWithFormat:@"%.1f", stepped];

    [self persistKey:kNetSpeedFontSizeKey value:@(stepped)];
}

- (void)marginChanged:(UISlider *)slider {
    float stepped = roundf(slider.value);
    [slider setValue:stepped animated:NO];
    margin = (NSInteger)stepped;

    TableViewCellWithSlider *cell = [self.tableView cellForRowAtIndexPath:
        [NSIndexPath indexPathForRow:NetSpeedDisplayRowMargin inSection:NetSpeedSectionDisplay]];
    cell.value.text = [NSString stringWithFormat:@"%ld", (long)margin];

    [self persistKey:kNetSpeedMarginKey value:@((NSInteger)stepped)];
}

// 滑块松手时再通知一次，避免拖动过程中频繁建立 socket 连接
- (void)sliderTouchFinished:(UISlider *)slider {
    [self notifyTweak];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;  // 显示 / 省电 / 关于
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == NetSpeedSectionDisplay) return 3;  // 位置 / 字号 / 边距
    if (section == NetSpeedSectionPower)   return 1;  // 息屏时暂停刷新
    return 1;                                         // 关于说明行
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *result;

    if (indexPath.section == NetSpeedSectionDisplay && indexPath.row == NetSpeedDisplayRowCorner) {
        // 位置：标准单元格，点按在 右上/左上/左下/右下 之间循环
        static NSString *cellID = @"CornerCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
        if (cell == nil) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cellID];
        }
        cell.textLabel.text = @"位置";
        cell.detailTextLabel.text = cornerTitles[cornerPosition];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        result = cell;
    }
    else if (indexPath.section == NetSpeedSectionDisplay && indexPath.row == NetSpeedDisplayRowFont) {
        TableViewCellWithSlider *cell = [tableView dequeueReusableCellWithIdentifier:@"SliderCell"];
        if (cell == nil) {
            cell = [[TableViewCellWithSlider alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"SliderCell"];
        }
        cell.title.text = @"字号";
        cell.slideBar.minimumValue = 8.0f;
        cell.slideBar.maximumValue = 20.0f;
        cell.slideBar.continuous = YES;
        [cell.slideBar removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
        [cell.slideBar addTarget:self action:@selector(fontSizeChanged:) forControlEvents:UIControlEventValueChanged];
        [cell.slideBar addTarget:self action:@selector(sliderTouchFinished:)
               forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        cell.slideBar.value = fontSize;
        cell.value.text = [NSString stringWithFormat:@"%.1f", fontSize];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        result = cell;
    }
    else if (indexPath.section == NetSpeedSectionDisplay && indexPath.row == NetSpeedDisplayRowMargin) {
        TableViewCellWithSlider *cell = [tableView dequeueReusableCellWithIdentifier:@"SliderCell"];
        if (cell == nil) {
            cell = [[TableViewCellWithSlider alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"SliderCell"];
        }
        cell.title.text = @"边距";
        cell.slideBar.minimumValue = 4.0f;
        cell.slideBar.maximumValue = 60.0f;
        cell.slideBar.continuous = YES;
        [cell.slideBar removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
        [cell.slideBar addTarget:self action:@selector(marginChanged:) forControlEvents:UIControlEventValueChanged];
        [cell.slideBar addTarget:self action:@selector(sliderTouchFinished:)
               forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        cell.slideBar.value = margin;
        cell.value.text = [NSString stringWithFormat:@"%ld", (long)margin];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        result = cell;
    }
    else if (indexPath.section == NetSpeedSectionPower) {
        TableViewCellWithSwitch *cell = [tableView dequeueReusableCellWithIdentifier:@"SwitchCell"];
        if (cell == nil) {
            cell = [[TableViewCellWithSwitch alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"SwitchCell"];
        }
        [cell setTitleText:@"息屏时暂停刷新"];
        [cell.switchBtn removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
        [cell.switchBtn addTarget:self action:@selector(pauseScreenOffChanged:) forControlEvents:UIControlEventValueChanged];
        [cell.switchBtn setOn:pauseScreenOff];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        result = cell;
    }
    else {
        // 关于：只读多行说明
        static NSString *cellID = @"AboutCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
        if (cell == nil) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellID];
            UILabel *label = [[UILabel alloc] init];
            label.translatesAutoresizingMaskIntoConstraints = NO;
            label.numberOfLines = 0;
            label.font = [UIFont systemFontOfSize:13];
            label.textColor = [UIColor secondaryLabelColor];
            label.tag = kAboutTextLabelTag;
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
        UILabel *label = (UILabel *)[cell.contentView viewWithTag:kAboutTextLabelTag];
        label.text = @"修改后立即生效。网速窗总开关在设置 → 控制 → 网速指示器。";
        result = cell;
    }

    return result;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    // 位置行点按循环：右上 -> 左上 -> 左下 -> 右下 -> 右上
    if (indexPath.section == NetSpeedSectionDisplay && indexPath.row == NetSpeedDisplayRowCorner) {
        cornerPosition = (cornerPosition + 1) % cornerTitles.count;
        [self persistKey:kNetSpeedCornerKey value:@(cornerPosition)];
        [self notifyTweak];
        [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == NetSpeedSectionAbout) {
        NSString *text = @"修改后立即生效。网速窗总开关在设置 → 控制 → 网速指示器。";
        CGRect rect = [text boundingRectWithSize:CGSizeMake(tableView.bounds.size.width - 32.0f, CGFLOAT_MAX)
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

    if (section == NetSpeedSectionDisplay)      title.text = @"显示";
    else if (section == NetSpeedSectionPower)   title.text = @"省电";
    else                                        title.text = @"关于";

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
    if (section == NetSpeedSectionPower) {
        return @"息屏时悬浮窗不可见，暂停采样可减少少量后台活动。";
    }
    return nil;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

@end
