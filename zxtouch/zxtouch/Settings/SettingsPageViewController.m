//
//  SettingsPageViewController.m
//  zxtouch
//
//  Created by Jason on 2021/1/18.
//

#import "SettingsPageViewController.h"
#import "ScriptListTableCell.h"
#import "TouchIndicatorConfigurationViewController.h"
#import "NetSpeedConfigurationViewController.h"
#import "DebugFloatWindowViewController.h"
#import "FloatingMenuConfigurationViewController.h"
#import "Util.h"
#import "Socket.h"

#import "TableViewCellWithSwitch.h"
#import "TableViewCellWithSlider.h"
#import "TableViewCellWithEntry.h"

#import "GCDWebServer.h"
#import "GCDWebServerDataResponse.h"

#import <dlfcn.h>
#import <objc/runtime.h>
#import "Config.h"
#import "ConfigManager.h"
#import "RemoteDashboardServer.h"

#define SETTING_CELL_SWITCH 0
#define SETTING_CELL_ENTRY 1
#define SETTING_CELL_SEGMENT 2

#define ZX_ACTION_SMART_TOGGLE @"smart_toggle"
#define ZX_ACTION_TOGGLE_PANEL @"toggle_panel"
#define ZX_ACTION_STOP_SCRIPT @"stop_script"
#define ZX_ACTION_TOGGLE_RECORDING @"toggle_recording"
#define ZX_ACTION_RUN_SCRIPT @"run_script"

#define ZX_TRIGGER_VOLUME_UP @"volume_up"
#define ZX_TRIGGER_VOLUME_DOWN @"volume_down"
#define ZX_TRIGGER_HOME @"home"

static UIImage *ZXSettingsSymbol(NSString *name) {
    if (@available(iOS 13.0, *)) {
        return [UIImage systemImageNamed:name];
    }
    return nil;
}

@interface SettingsPageViewController ()
{
    GCDWebServer* _webServer;
}
@end

@implementation SettingsPageViewController
{
    NSArray *sections;
    NSArray<NSArray*> *cellsForEachSection;
    ConfigManager *configManager;
}

// 界面外观：直接存 UIUserInterfaceStyle（0跟随系统 1浅色 2深色）
- (UIUserInterfaceStyle)savedAppearanceMode {
    id configValue = [configManager getValueFromKey:@"appearance_mode"];
    if (configValue) {
        return (UIUserInterfaceStyle)[configValue integerValue];
    }

    // 旧版本只有「深色模式」开关，迁移成 深色/浅色 两档
    id legacyValue = [configManager getValueFromKey:@"dark_mode"];
    BOOL dark = legacyValue ? [legacyValue boolValue]
                            : [[NSUserDefaults standardUserDefaults] boolForKey:@"dark_mode"];
    UIUserInterfaceStyle mode = dark ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
    [configManager updateKey:@"appearance_mode" forValue:@(mode)];
    [configManager save];
    return mode;
}

- (void)applyAppearanceMode:(UIUserInterfaceStyle)mode {
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *win in ((UIWindowScene *)scene).windows) {
                win.overrideUserInterfaceStyle = mode;
            }
        }
    }
}

// 命令必须以 \r\n 结尾，否则 tweak 端不会派发；也不在主线程等回复（会卡死被系统杀掉）
- (void)sendTweakCommandAsync:(NSString *)command {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        Socket *socket = [[Socket alloc] init];
        if ([socket connect:@"127.0.0.1" byPort:6000] == 0) {
            [socket send:[command stringByAppendingString:@"\r\n"]];
            [socket close];
        }
    });
}

- (NSString *)triggerActionTitle:(NSString *)action {
    if ([action isEqualToString:ZX_ACTION_TOGGLE_PANEL]) return @"显示/隐藏选项面板";
    if ([action isEqualToString:ZX_ACTION_STOP_SCRIPT]) return @"终止脚本";
    if ([action isEqualToString:ZX_ACTION_TOGGLE_RECORDING]) return @"开始/停止录制";
    if ([action isEqualToString:ZX_ACTION_RUN_SCRIPT]) return @"运行默认脚本";
    return @"智能切换";
}

- (NSString *)triggerTitle:(NSString *)triggerKey {
    if ([triggerKey isEqualToString:ZX_TRIGGER_VOLUME_UP]) return @"音量加";
    if ([triggerKey isEqualToString:ZX_TRIGGER_HOME]) return @"主屏幕按钮";
    return @"音量减";
}

- (NSMutableDictionary *)triggerConfigForKey:(NSString *)triggerKey {
    NSMutableDictionary *allTriggers = [[configManager getValueFromKey:@"trigger_configs"] mutableCopy];
    NSDictionary *existing = [allTriggers isKindOfClass:[NSDictionary class]] ? allTriggers[triggerKey] : nil;
    if ([existing isKindOfClass:[NSDictionary class]]) return [existing mutableCopy];

    if ([triggerKey isEqualToString:ZX_TRIGGER_VOLUME_DOWN]) {
        BOOL enabled = YES;
        if ([configManager getValueFromKey:@"double_click_volume_show_popup"])
            enabled = [[configManager getValueFromKey:@"double_click_volume_show_popup"] boolValue];
        return [@{
            @"enabled": @(enabled),
            @"count": @(2),
            @"action": [configManager getValueFromKey:@"double_click_volume_action"] ?: ZX_ACTION_SMART_TOGGLE,
            @"script": [configManager getValueFromKey:@"double_click_volume_script"] ?: @""
        } mutableCopy];
    }

    return [@{@"enabled": @(NO), @"count": @(2), @"action": ZX_ACTION_SMART_TOGGLE, @"script": @""} mutableCopy];
}

- (void)saveTriggerConfig:(NSMutableDictionary *)trigger forKey:(NSString *)triggerKey {
    NSMutableDictionary *allTriggers = [[configManager getValueFromKey:@"trigger_configs"] mutableCopy];
    if (![allTriggers isKindOfClass:[NSMutableDictionary class]]) allTriggers = [NSMutableDictionary dictionary];
    allTriggers[triggerKey] = trigger;
    [configManager updateKey:@"trigger_configs" forValue:allTriggers];

    if ([triggerKey isEqualToString:ZX_TRIGGER_VOLUME_DOWN]) {
        [configManager updateKey:@"double_click_volume_show_popup" forValue:trigger[@"enabled"]];
        [configManager updateKey:@"double_click_volume_action" forValue:trigger[@"action"]];
        [configManager updateKey:@"double_click_volume_script" forValue:trigger[@"script"]];
    }
    [configManager save];
    [self reloadSettingsModel];
}

- (NSString *)triggerSummaryForKey:(NSString *)triggerKey {
    NSDictionary *trigger = [self triggerConfigForKey:triggerKey];
    if (![trigger[@"enabled"] boolValue]) return @"关闭";
    NSString *actionTitle = [self triggerActionTitle:trigger[@"action"]];
    NSString *script = trigger[@"script"];
    if ([trigger[@"action"] isEqualToString:ZX_ACTION_RUN_SCRIPT] && [script length] > 0) {
        actionTitle = [NSString stringWithFormat:@"运行 %@", [[script lastPathComponent] stringByDeletingPathExtension]];
    }
    return [NSString stringWithFormat:@"%@次点击 → %@", trigger[@"count"], actionTitle];
}

- (NSArray<NSString *> *)availableScriptPaths {
    NSMutableArray *paths = [NSMutableArray array];
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtPath:SCRIPTS_PATH];
    NSString *relative = nil;
    while ((relative = [enumerator nextObject])) {
        if ([[relative pathExtension] isEqualToString:@"bdl"]) {
            [paths addObject:[SCRIPTS_PATH stringByAppendingPathComponent:relative]];
            [enumerator skipDescendants];
        }
    }
    return [paths sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

- (NSString *)iconNameForCellTitle:(NSString *)title {
    if ([title containsString:@"服务器"]) return @"globe";
    if ([title containsString:@"网速"]) return @"speedometer";
    if ([title containsString:@"触摸"]) return @"hand.tap";
    if ([title containsString:@"双击"]) return @"bolt.badge.clock";
    if ([title containsString:@"音量"]) return @"speaker.wave.2";
    if ([title containsString:@"默认触发"]) return @"play.square.stack";
    if ([title containsString:@"切换App"]) return @"arrow.triangle.2.circlepath";
    if ([title containsString:@"示例"]) return @"folder";
    if ([title containsString:@"注册表"]) return @"list.bullet.rectangle";
    if ([title containsString:@"外观"]) return @"circle.lefthalf.filled";
    if ([title containsString:@"调试"]) return @"wrench.and.screwdriver";
    if ([title containsString:@"小新"]) return @"info.circle";
    return @"gearshape";
}

- (NSArray<NSDictionary *> *)remoteManagementCells {
    BOOL enabled = ZXRemoteDashboardIsEnabled();
    NSMutableArray *cells = [NSMutableArray arrayWithObject:@{
        @"type": @(SETTING_CELL_SWITCH),
        @"title": @"服务器",
        @"switch_click_handler": NSStringFromSelector(@selector(handleWebServerWithSwitchCellInstance:)),
        @"switch_init_status": @(enabled)
    }];
    if (enabled) {
        [cells addObject:@{
            @"type": @(SETTING_CELL_ENTRY),
            @"title": @"网页面板地址",
            @"secondary_title": @"点击查看并复制",
            @"row_click_handler": NSStringFromSelector(@selector(handleDashboardURLTap:))
        }];
    }
    return cells;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    self.title = @"设置";
    
    sections = @[@"远程管理", @"控制", @"工具", @"自动操作", @"脚本", @"外观", @"关于小新Lap", @"Python 依赖检测"];
    configManager = [[ConfigManager alloc] initWithPath:SPRINGBOARD_CONFIG_PATH];
    BOOL doubleClickPopup = YES;
    if ([configManager getValueFromKey:@"double_click_volume_show_popup"])
    {
        doubleClickPopup = [[configManager getValueFromKey:@"double_click_volume_show_popup"] boolValue];
    }
    
    BOOL switchAppBeforeRunScript = YES;
    if ([configManager getValueFromKey:@"switch_app_before_run_script"])
    {
        switchAppBeforeRunScript = [[configManager getValueFromKey:@"switch_app_before_run_script"] boolValue];
    }

    BOOL showFinishedPopup = YES;
    if ([configManager getValueFromKey:@"show_script_finished_popup"])
    {
        showFinishedPopup = [[configManager getValueFromKey:@"show_script_finished_popup"] boolValue];
    }

    UIUserInterfaceStyle appearanceMode = [self savedAppearanceMode];

    BOOL netSpeedIndicator = NO;
    if ([configManager getValueFromKey:@"net_speed_indicator_enabled"])
    {
        netSpeedIndicator = [[configManager getValueFromKey:@"net_speed_indicator_enabled"] boolValue];
    }

    BOOL floatingMenu = NO;
    if ([configManager getValueFromKey:@"floating_menu_enabled"])
    {
        floatingMenu = [[configManager getValueFromKey:@"floating_menu_enabled"] boolValue];
    }

    // [@{"type": ?, @"title": ?, @"content": ?, ... more depends on the cell type}]
    //
    cellsForEachSection = @[
        [self remoteManagementCells],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"触摸指示器", @"secondary_title": @"圆点与坐标悬浮窗", @"row_click_handler": NSStringFromSelector(@selector(handleTouchIndicatorWithEntryCellInstance:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"控制按钮悬浮窗", @"secondary_title": @"开关 / 吸附边 / 纵向位置（也可手动拖动）", @"row_click_handler": NSStringFromSelector(@selector(handleFloatingMenuEntryTap:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"悬浮窗调试", @"secondary_title": @"查看当前位置/方向/变换矩阵等", @"row_click_handler": NSStringFromSelector(@selector(handleDebugFloatWindowTap:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"屏幕坐标测试", @"secondary_title": @"旋转屏幕点四角，验证坐标系映射", @"row_click_handler": NSStringFromSelector(@selector(handleTapTestWindowTap:))}
        ],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"网速悬浮窗", @"secondary_title": @"开关 / 位置 / 字号 / 边距", @"row_click_handler": NSStringFromSelector(@selector(handleNetSpeedSettingsTap:))}
        ],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"音量加", @"secondary_title": [self triggerSummaryForKey:ZX_TRIGGER_VOLUME_UP], @"trigger_key": ZX_TRIGGER_VOLUME_UP, @"row_click_handler": NSStringFromSelector(@selector(handleTriggerTap:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"音量减", @"secondary_title": [self triggerSummaryForKey:ZX_TRIGGER_VOLUME_DOWN], @"trigger_key": ZX_TRIGGER_VOLUME_DOWN, @"row_click_handler": NSStringFromSelector(@selector(handleTriggerTap:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"主屏幕按钮", @"secondary_title": [self triggerSummaryForKey:ZX_TRIGGER_HOME], @"trigger_key": ZX_TRIGGER_HOME, @"row_click_handler": NSStringFromSelector(@selector(handleTriggerTap:))}
        ],
        @[
            @{@"type": @(SETTING_CELL_SWITCH), @"title": @"运行脚本前切换App", @"switch_click_handler": NSStringFromSelector(@selector(handleSwitchAppBeforePlaying:)), @"switch_init_status": @(switchAppBeforeRunScript)},
            @{@"type": @(SETTING_CELL_SWITCH), @"title": @"脚本完成弹窗", @"switch_click_handler": NSStringFromSelector(@selector(handleScriptFinishedPopupToggle:)), @"switch_init_status": @(showFinishedPopup)},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"示例脚本", @"secondary_title": EXAMPLE_SCRIPTS_PATH, @"row_click_handler": NSStringFromSelector(@selector(handleExamplesTap:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"脚本注册表", @"secondary_title": SCRIPT_REGISTRY_PATH, @"row_click_handler": NSStringFromSelector(@selector(handleRegistryTap:))}
        ],
        @[
            @{@"type": @(SETTING_CELL_SEGMENT), @"title": @"界面外观", @"segment_titles": @[@"深色", @"浅色", @"跟随系统"], @"segment_selected": @(appearanceMode), @"segment_click_handler": NSStringFromSelector(@selector(handleAppearanceChanged:))}
        ],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"小新Lap", @"secondary_title": [NSString stringWithFormat:@"v%@ · 基于开源 ZXTouch 二次修改", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @""], @"row_click_handler": NSStringFromSelector(@selector(handleCreditsTap:))}
        ],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"Python 依赖检测", @"secondary_title": @"检查 python3 是否存在、能否运行、模块路径", @"row_click_handler": NSStringFromSelector(@selector(handlePythonCheckTap:))}
        ]
    ];
     
    UINib *SwitchCellNib = [UINib nibWithNibName:@"TableViewCellWithSwitch" bundle:nil];
    [_tableView registerNib:SwitchCellNib forCellReuseIdentifier:@"SwitchCell"];

    UINib *entryCellNib = [UINib nibWithNibName:@"TableViewCellWithEntry" bundle:nil];
    [_tableView registerNib:entryCellNib forCellReuseIdentifier:@"EntryCell"];
    [_tableView registerNib:entryCellNib forCellReuseIdentifier:@"SegmentCell"];
    
    _tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    _tableView.tableFooterView = [[UIView alloc] init];
    _tableView.rowHeight = 54;
    _tableView.separatorInset = UIEdgeInsetsMake(0, 52, 0, 0);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (configManager) {
        [self reloadSettingsModel];
    }
}

- (void)reloadSettingsModel {
    configManager = [[ConfigManager alloc] initWithPath:SPRINGBOARD_CONFIG_PATH];
    BOOL doubleClickPopup = YES;
    if ([configManager getValueFromKey:@"double_click_volume_show_popup"])
        doubleClickPopup = [[configManager getValueFromKey:@"double_click_volume_show_popup"] boolValue];
    BOOL switchAppBeforeRunScript = YES;
    if ([configManager getValueFromKey:@"switch_app_before_run_script"])
        switchAppBeforeRunScript = [[configManager getValueFromKey:@"switch_app_before_run_script"] boolValue];
    BOOL showFinishedPopup = YES;
    if ([configManager getValueFromKey:@"show_script_finished_popup"])
    {
        showFinishedPopup = [[configManager getValueFromKey:@"show_script_finished_popup"] boolValue];
    }

    UIUserInterfaceStyle appearanceMode = [self savedAppearanceMode];

    BOOL netSpeedIndicator = NO;
    if ([configManager getValueFromKey:@"net_speed_indicator_enabled"])
        netSpeedIndicator = [[configManager getValueFromKey:@"net_speed_indicator_enabled"] boolValue];

    BOOL floatingMenu = NO;
    if ([configManager getValueFromKey:@"floating_menu_enabled"])
        floatingMenu = [[configManager getValueFromKey:@"floating_menu_enabled"] boolValue];

    sections = @[@"远程管理", @"控制", @"工具", @"自动操作", @"脚本", @"外观", @"关于小新Lap", @"Python 依赖检测"];
    cellsForEachSection = @[
        [self remoteManagementCells],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"触摸指示器", @"secondary_title": @"圆点与坐标悬浮窗", @"row_click_handler": NSStringFromSelector(@selector(handleTouchIndicatorWithEntryCellInstance:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"控制按钮悬浮窗", @"secondary_title": @"开关 / 吸附边 / 纵向位置（也可手动拖动）", @"row_click_handler": NSStringFromSelector(@selector(handleFloatingMenuEntryTap:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"悬浮窗调试", @"secondary_title": @"查看当前位置/方向/变换矩阵等", @"row_click_handler": NSStringFromSelector(@selector(handleDebugFloatWindowTap:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"屏幕坐标测试", @"secondary_title": @"旋转屏幕点四角，验证坐标系映射", @"row_click_handler": NSStringFromSelector(@selector(handleTapTestWindowTap:))}
        ],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"网速悬浮窗", @"secondary_title": @"开关 / 位置 / 字号 / 边距", @"row_click_handler": NSStringFromSelector(@selector(handleNetSpeedSettingsTap:))}
        ],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"音量加", @"secondary_title": [self triggerSummaryForKey:ZX_TRIGGER_VOLUME_UP], @"trigger_key": ZX_TRIGGER_VOLUME_UP, @"row_click_handler": NSStringFromSelector(@selector(handleTriggerTap:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"音量减", @"secondary_title": [self triggerSummaryForKey:ZX_TRIGGER_VOLUME_DOWN], @"trigger_key": ZX_TRIGGER_VOLUME_DOWN, @"row_click_handler": NSStringFromSelector(@selector(handleTriggerTap:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"主屏幕按钮", @"secondary_title": [self triggerSummaryForKey:ZX_TRIGGER_HOME], @"trigger_key": ZX_TRIGGER_HOME, @"row_click_handler": NSStringFromSelector(@selector(handleTriggerTap:))}
        ],
        @[
            @{@"type": @(SETTING_CELL_SWITCH), @"title": @"运行脚本前切换App", @"switch_click_handler": NSStringFromSelector(@selector(handleSwitchAppBeforePlaying:)), @"switch_init_status": @(switchAppBeforeRunScript)},
            @{@"type": @(SETTING_CELL_SWITCH), @"title": @"脚本完成弹窗", @"switch_click_handler": NSStringFromSelector(@selector(handleScriptFinishedPopupToggle:)), @"switch_init_status": @(showFinishedPopup)},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"示例脚本", @"secondary_title": EXAMPLE_SCRIPTS_PATH, @"row_click_handler": NSStringFromSelector(@selector(handleExamplesTap:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"脚本注册表", @"secondary_title": SCRIPT_REGISTRY_PATH, @"row_click_handler": NSStringFromSelector(@selector(handleRegistryTap:))}
        ],
        @[
            @{@"type": @(SETTING_CELL_SEGMENT), @"title": @"界面外观", @"segment_titles": @[@"深色", @"浅色", @"跟随系统"], @"segment_selected": @(appearanceMode), @"segment_click_handler": NSStringFromSelector(@selector(handleAppearanceChanged:))}
        ],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"小新Lap", @"secondary_title": [NSString stringWithFormat:@"v%@ · 基于开源 ZXTouch 二次修改", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @""], @"row_click_handler": NSStringFromSelector(@selector(handleCreditsTap:))}
        ],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"Python 依赖检测", @"secondary_title": @"检查 python3 是否存在、能否运行、模块路径", @"row_click_handler": NSStringFromSelector(@selector(handlePythonCheckTap:))}
        ]
    ];
    [_tableView reloadData];
}

- (void)handleSwitchAppBeforePlaying:(UISwitch*)s {
    if ([s isOn])
    {
        [configManager updateKey:@"switch_app_before_run_script" forValue:@(true)];
        [configManager save];
    }
    else
    {
        [configManager updateKey:@"switch_app_before_run_script" forValue:@(false)];
        [configManager save];
    }
    
    [self sendTweakCommandAsync:@"902"];
}

- (void)handleScriptFinishedPopupToggle:(UISwitch*)s {
    // Controls the "Script Finished" popup the tweak shows when a script ends.
    // Stored in the SpringBoard config so Play.xm can read it; defaults to on so
    // existing installs keep their current behaviour.
    [configManager updateKey:@"show_script_finished_popup" forValue:@([s isOn])];
    [configManager save];
}

- (void)handlePopupWindowDoubleClick:(UISwitch*)s {
    if ([s isOn])
    {
        [configManager updateKey:@"double_click_volume_show_popup" forValue:@(true)];
        [configManager save];
    }
    else
    {
        [configManager updateKey:@"double_click_volume_show_popup" forValue:@(false)];
        [configManager save];
    }
    [self sendTweakCommandAsync:@"901"];
}

- (void)setVolumeAction:(NSString *)action {
    [configManager updateKey:@"double_click_volume_action" forValue:action];
    [configManager save];
    [self reloadSettingsModel];
}

- (NSString *)triggerKeyFromCell:(TableViewCellWithEntry *)cell {
    if ([cell.title.text isEqualToString:@"音量加"]) return ZX_TRIGGER_VOLUME_UP;
    if ([cell.title.text isEqualToString:@"主屏幕按钮"]) return ZX_TRIGGER_HOME;
    return ZX_TRIGGER_VOLUME_DOWN;
}

- (void)setAction:(NSString *)action forTrigger:(NSString *)triggerKey {
    NSMutableDictionary *trigger = [self triggerConfigForKey:triggerKey];
    trigger[@"enabled"] = @(YES);
    trigger[@"action"] = action;
    [self saveTriggerConfig:trigger forKey:triggerKey];
}

- (void)setCount:(NSInteger)count forTrigger:(NSString *)triggerKey {
    NSMutableDictionary *trigger = [self triggerConfigForKey:triggerKey];
    trigger[@"enabled"] = @(YES);
    trigger[@"count"] = @(count);
    [self saveTriggerConfig:trigger forKey:triggerKey];
}

- (void)chooseScriptForTrigger:(NSString *)triggerKey fromCell:(UITableViewCell *)cell {
    NSArray<NSString *> *scripts = [self availableScriptPaths];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"运行脚本"
        message:scripts.count ? @"请选择此触发要运行的脚本。" : @"未找到任何 .bdl 脚本。"
        preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSString *script in scripts) {
        NSString *title = [[script lastPathComponent] stringByDeletingPathExtension];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            NSMutableDictionary *trigger = [self triggerConfigForKey:triggerKey];
            trigger[@"enabled"] = @(YES);
            trigger[@"action"] = ZX_ACTION_RUN_SCRIPT;
            trigger[@"script"] = script;
            [self saveTriggerConfig:trigger forKey:triggerKey];
        }]];
        if (sheet.actions.count >= 18) break;
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"手动输入路径..." style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self handleTriggerScriptTap:(TableViewCellWithEntry *)cell];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop) {
        pop.sourceView = cell;
        pop.sourceRect = cell.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)handleTriggerTap:(TableViewCellWithEntry*)cell {
    NSString *triggerKey = [self triggerKeyFromCell:cell];
    NSMutableDictionary *trigger = [self triggerConfigForKey:triggerKey];
    NSString *title = [self triggerTitle:triggerKey];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
        message:[NSString stringWithFormat:@"当前设置：%@", [self triggerSummaryForKey:triggerKey]]
        preferredStyle:UIAlertControllerStyleActionSheet];

    if ([trigger[@"enabled"] boolValue]) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"停用此触发" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            NSMutableDictionary *updated = [self triggerConfigForKey:triggerKey];
            updated[@"enabled"] = @(NO);
            [self saveTriggerConfig:updated forKey:triggerKey];
        }]];
    } else {
        [sheet addAction:[UIAlertAction actionWithTitle:@"启用此触发" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            NSMutableDictionary *updated = [self triggerConfigForKey:triggerKey];
            updated[@"enabled"] = @(YES);
            [self saveTriggerConfig:updated forKey:triggerKey];
        }]];
    }

    for (NSInteger count = 1; count <= 5; count++) {
        [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%ld 次点击", (long)count] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self setCount:count forTrigger:triggerKey];
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"运行脚本..." style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self chooseScriptForTrigger:triggerKey fromCell:cell];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"显示/隐藏选项面板" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self setAction:ZX_ACTION_TOGGLE_PANEL forTrigger:triggerKey];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"终止脚本" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self setAction:ZX_ACTION_STOP_SCRIPT forTrigger:triggerKey];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"开始/停止录制" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self setAction:ZX_ACTION_TOGGLE_RECORDING forTrigger:triggerKey];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"智能切换" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self setAction:ZX_ACTION_SMART_TOGGLE forTrigger:triggerKey];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop) {
        pop.sourceView = cell;
        pop.sourceRect = cell.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)handleVolumeActionTap:(TableViewCellWithEntry*)cell {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"触发动作"
        message:@"请选择双击音量减事件要执行的动作。"
        preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:@"智能切换" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self setVolumeAction:ZX_ACTION_SMART_TOGGLE];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"显示/隐藏选项面板" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self setVolumeAction:ZX_ACTION_TOGGLE_PANEL];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"终止脚本" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self setVolumeAction:ZX_ACTION_STOP_SCRIPT];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"开始/停止录制" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self setVolumeAction:ZX_ACTION_TOGGLE_RECORDING];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"运行默认脚本" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self setVolumeAction:ZX_ACTION_RUN_SCRIPT];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop) {
        pop.sourceView = cell;
        pop.sourceRect = cell.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)handleTriggerScriptTap:(TableViewCellWithEntry*)cell {
    NSString *triggerKey = [self triggerKeyFromCell:cell];
    NSMutableDictionary *trigger = [self triggerConfigForKey:triggerKey];
    NSString *current = trigger[@"script"] ?: @"";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"默认触发脚本"
        message:@"粘贴要由此触发运行的 .bdl 脚本路径。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"/var/mobile/Library/ZXTouch/scripts/example.bdl";
        textField.text = current;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"清除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSMutableDictionary *updated = [self triggerConfigForKey:triggerKey];
        updated[@"script"] = @"";
        [self saveTriggerConfig:updated forKey:triggerKey];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *path = alert.textFields.firstObject.text ?: @"";
        NSMutableDictionary *updated = [self triggerConfigForKey:triggerKey];
        updated[@"enabled"] = @(YES);
        updated[@"action"] = ZX_ACTION_RUN_SCRIPT;
        updated[@"script"] = path;
        [self saveTriggerConfig:updated forKey:triggerKey];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)handleWebServerWithSwitchCellInstance:(UISwitch*)s {
    if (![s isOn]) {
        ZXRemoteDashboardSetEnabled(NO);
        [self reloadSettingsModel];
        return;
    }

    if (!ZXRemoteDashboardSetEnabled(YES)) {
        [s setOn:NO animated:YES];
        NSString *dashboardError = ZXRemoteDashboardLastError();
        [Util showAlertBoxWithOneOption:self title:@"无法打开网页面板"
            message:dashboardError.length ? dashboardError : @"无法启动本地网页面板。"
            buttonString:@"确定"];
        return;
    }

    [Util showAlertBoxWithOneOption:self title:@"远程网页面板"
        message:[NSString stringWithFormat:@"请在连接同一 Wi-Fi 的设备上打开以下地址：\n\n%@", ZXRemoteDashboardURL()]
        buttonString:@"确定"];
    [self reloadSettingsModel];
}

- (void)handleDashboardURLTap:(TableViewCellWithEntry *)cell {
    NSString *url = ZXRemoteDashboardURL();
    UIPasteboard.generalPasteboard.string = url;
    [Util showAlertBoxWithOneOption:self title:@"网页面板地址"
        message:[NSString stringWithFormat:@"%@\n\n已复制到剪贴板。", url]
        buttonString:@"确定"];
}

- (void)handleNetSpeedIndicatorToggle:(UISwitch*)s {
    BOOL enabled = [s isOn];
    [configManager updateKey:@"net_speed_indicator_enabled" forValue:@(enabled)];
    [configManager save];

    // Notify SpringBoard tweak via socket (command 31)
    Socket *socket = [[Socket alloc] init];
    if ([socket connect:@"127.0.0.1" byPort:6000] == 0) {
        NSString *cmd = [NSString stringWithFormat:@"31;;%d\r\n", enabled ? 1 : 0];
        [socket send:cmd];
        [socket close];
    }
}

- (void)handleNetSpeedSettingsTap:(TableViewCellWithEntry *)cell {
    NetSpeedConfigurationViewController *vc = [[NetSpeedConfigurationViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)handleFloatingMenuEntryTap:(TableViewCellWithEntry *)cell {
    FloatingMenuConfigurationViewController *vc = [[FloatingMenuConfigurationViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)handleDebugFloatWindowTap:(TableViewCellWithEntry *)cell {
    DebugFloatWindowViewController *vc = [[DebugFloatWindowViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)handleTapTestWindowTap:(TableViewCellWithEntry *)cell {
    // 发送 41;;1 打开 SpringBoard 全屏坐标测试窗口
    Socket *socket = [[Socket alloc] init];
    if ([socket connect:@"127.0.0.1" byPort:6000] == 0) {
        [socket send:@"41;;1\r\n"];
        [socket close];
        [Util showAlertBoxWithOneOption:self
            title:@"屏幕坐标测试窗口已打开"
            message:@"全屏淡红色背景窗口已出现。\n旋转屏幕后点击四角，记录每个方向下的屏幕坐标、window 坐标、root 坐标，用于验证悬浮窗坐标系映射是否正确。\n\n再次点'屏幕坐标测试'可关闭。"
            buttonString:@"确定"];
    } else {
        [Util showAlertBoxWithOneOption:self
            title:@"无法连接"
            message:@"请确认悬浮控制按钮已开启（已向 SpringBoard 注入 tweak）。"
            buttonString:@"确定"];
    }
}

- (void)handleAppearanceChanged:(UISegmentedControl *)seg {
    // 段序 深色 / 浅色 / 跟随系统 对应 UIUserInterfaceStyle 2 / 1 / 0
    UIUserInterfaceStyle mode = (UIUserInterfaceStyle)(2 - seg.selectedSegmentIndex);
    [configManager updateKey:@"appearance_mode" forValue:@(mode)];
    [configManager save];

    [self applyAppearanceMode:mode];

    // 通知 SpringBoard 让控制面板一起切换（命令 903）
    [self sendTweakCommandAsync:@"903"];
}

- (void)handleCreditsTap:(TableViewCellWithEntry*)cell {
    // Show a brief about alert
    [Util showAlertBoxWithOneOption:self title:@"小新Lap"
        message:@"本软件基于开源项目 ZXTouch 二次修改，非原作者发布。\n"
                @"原项目：https://github.com/Epic0001/zxtouchrootless\n"
                @"最初来源：xuan32546/IOS13-SimulateTouch\n\n"
                @"二改版本名：小新Lap（iOS 15-17 无根越狱移植）"
        buttonString:@"确定"];
}

static NSString *ZXPythonErrnoName(int e) {
    switch (e) {
        case 1:  return @"EPERM";
        case 2:  return @"ENOENT";
        case 13: return @"EACCES权限不足";
        case 20: return @"ENOTDIR";
        case 40: return @"ELOOP";
        default: return @"?";
    }
}

- (void)handlePythonCheckTap:(TableViewCellWithEntry*)cell {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Python 依赖检测"
        message:@"正在检测，请稍候..."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        Socket *socket = [[Socket alloc] init];
        BOOL ok = ([socket connect:@"127.0.0.1" byPort:6000] == 0);
        if (ok) {
            [socket send:@"45\r\n"];
        }
        NSString *raw = ok ? [socket recv:32768] : nil;
        if (ok) [socket close];

        // 格式化诊断结果
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableString *report = [NSMutableString string];

            // App 版本号（从小新Lap App 自身的 bundle 拿，不是 SpringBoard 的）
            NSString *appVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
            if (appVersion.length == 0) appVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"";

            // 设备基础信息（SettingsPageViewController 跑在小新Lap App 进程里，能拿到 UIDevice）
            UIDevice *dev = [UIDevice currentDevice];
            NSString *deviceName = dev.model ?: @"";
            NSString *osVersion = dev.systemVersion ?: @"";

            [report appendFormat:@"时间：%@\n", [NSDate date]];
            [report appendFormat:@"App：小新Lap v%@\n", appVersion.length ? appVersion : @"?"];
            [report appendFormat:@"设备：%@  iOS %@\n", deviceName, osVersion];
            [report appendFormat:@"进程 uid=501（SpringBoard）\n"];
            [report appendString:@"\n"];

            if (!ok) {
                [report appendString:@"无法连接 SpringBoard 进程（Socket 失败）。"];
            } else if (raw.length == 0) {
                [report appendString:@"未收到 tweak 返回结果。"];
            } else {
                NSString *jsonStr = raw;
                if ([jsonStr hasSuffix:@"\r\n"]) jsonStr = [jsonStr substringToIndex:jsonStr.length - 2];
                NSError *jerr = nil;
                NSData *data = [jsonStr dataUsingEncoding:NSUTF8StringEncoding];
                NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data] options:0 error:&jerr];

                if (jerr || ![dict isKindOfClass:[NSDictionary class]]) {
                    [report appendFormat:@"返回数据解析失败：%@\n\n原始数据：\n%@", jerr.localizedDescription ?: @"类型错误", raw];
                } else {
                    NSString *found = dict[@"found_path"] ?: @"";
                    if (found.length > 0) {
                        [report appendFormat:@"找到：%@\n", found];
                        NSString *ver = dict[@"version"];
                        if (ver.length > 0) [report appendFormat:@"版本：%@\n", ver];
                    } else {
                        [report appendString:@"全部候选不可用（access / posix_spawn 均 EPERM）\n"];
                    }

                    // 执行链路探针
                    NSDictionary *prA = dict[@"spawn_probe_A_shell"];
                    NSDictionary *prB = dict[@"spawn_probe_B_direct"];
                    if (prA || prB) {
                        [report appendString:@"\n执行链路对比（SpringBoard 进程内）：\n"];
                        [report appendFormat:@"  A  shell间接  sh -c 'python3.9 --version' → exit=%@\n", prA[@"exit"] ?: @"?"];
                        [report appendFormat:@"  B  直接exec   posix_spawn(python3.9)       → exit=%@\n", prB[@"exit"] ?: @"?"];
                    }

                    // 环境信息
                    NSString *jbPrefix = dict[@"jbroot_prefix"];
                    NSString *varjb = dict[@"varjb_target"];
                    NSString *tweakPath = dict[@"tweak_path"];
                    if (jbPrefix.length || varjb.length || tweakPath.length) {
                        [report appendString:@"\n越狱目录：\n"];
                        if (jbPrefix.length) [report appendFormat:@"  tweak 安装位置：%@\n", jbPrefix];
                        if (varjb.length) [report appendFormat:@"  /var/jb → %@\n", varjb];
                        if (tweakPath.length) [report appendFormat:@"  pccontrol.dylib：%@\n", tweakPath];
                    }

                    // 各候选路径
                    NSArray *cands = dict[@"candidates"];
                    NSArray *probes = [dict[@"probes"] isKindOfClass:[NSArray class]] ? dict[@"probes"] : @[];
                    if ([cands isKindOfClass:[NSArray class]]) {
                        [report appendString:@"\n候选路径：\n"];
                        for (NSDictionary *c in cands) {
                            NSString *p = c[@"path"];
                            BOOL ex = [c[@"exists"] boolValue];
                            BOOL xc = [c[@"executable"] boolValue];
                            NSMutableString *line = [NSMutableString stringWithFormat:@"  %@", p];
                            NSString *mode = c[@"mode"];
                            if (mode.length) [line appendFormat:@" [mode %@]", mode];
                            if ([c[@"symlink"] boolValue]) [line appendFormat:@" link→%@", c[@"link_target"] ?: @"?"];
                            if (!ex) [line appendString:@" 不存在"];
                            else if (xc) [line appendString:@"  ✅ 可执行"];
                            else {
                                NSNumber *en = c[@"exec_errno"];
                                [line appendFormat:@"  ❌ access=EPERM errno=%@(%@)", en ?: @0, ZXPythonErrnoName(en.intValue)];
                            }
                            [report appendFormat:@"%@\n", line];
                            for (NSDictionary *pr in probes) {
                                if ([pr isKindOfClass:[NSDictionary class]] && [pr[@"path"] isEqualToString:p]) {
                                    NSString *out = pr[@"output"];
                                    [report appendFormat:@"      试跑 exit=%@ 输出：%@\n", pr[@"exit"], out.length ? out : @"(无输出)"];
                                    break;
                                }
                            }
                        }
                    }

                    // dpkg
                    NSDictionary *dq = dict[@"dpkg_query"];
                    if ([dq isKindOfClass:[NSDictionary class]] && dq.count > 0) {
                        [report appendString:@"\ndpkg python3 包记录：\n"];
                        for (NSString *k in dq) {
                            NSString *out = dq[k];
                            [report appendFormat:@"  [%@]\n    %@\n", k, out.length ? out : @"(无)"];
                        }
                    }

                    // 沙盒范围探针
                    NSArray *scope = [dict[@"sandbox_scope_probe"] isKindOfClass:[NSArray class]] ? dict[@"sandbox_scope_probe"] : nil;
                    if (scope.count > 0) {
                        [report appendString:@"\nSpringBoard 沙盒 exec 范围：\n"];
                        for (NSDictionary *s in scope) {
                            if (![s isKindOfClass:[NSDictionary class]]) continue;
                            NSString *sp = s[@"path"] ?: @"";
                            BOOL ex2 = [s[@"exists"] boolValue];
                            BOOL acc2 = [s[@"access_X_OK"] boolValue];
                            NSString *spawn = s[@"posix_spawn"] ?: @"";
                            if (!ex2) {
                                [report appendFormat:@"  ❌ %@  不存在\n", sp];
                            } else if (acc2) {
                                [report appendFormat:@"  ✅ %@  access=0  %@\n", sp, spawn];
                            } else {
                                NSNumber *en2 = s[@"access_errno"];
                                [report appendFormat:@"  ❌ %@  access=EPERM errno=%@  %@\n", sp, en2 ?: @0, spawn];
                            }
                        }
                    }

                    // 模块路径
                    NSArray *mods = dict[@"module_paths_found"];
                    if (mods.count > 0) {
                        [report appendString:@"\nzxtouch 模块路径：\n"];
                        for (NSString *m in mods) [report appendFormat:@"  %@\n", m];
                    }
                }
            }

            // 复制到剪贴板
            [UIPasteboard generalPasteboard].string = report;

            // 直接在已弹出的 alert 上就地更新内容。
            // 不能再 present 第二个 alert —— 上一个还没消失时系统会静默丢弃，
            // 表现为一直停在“正在检测，请稍候...”。
            NSString *body = [report stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
            alert.message = [body stringByAppendingString:@"\n\n（以上内容已自动复制到剪贴板）"];
        });
    });
}

- (void)handleExamplesTap:(TableViewCellWithEntry*)cell {
    NSArray *examples = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:EXAMPLE_SCRIPTS_PATH error:nil];
    NSString *message = [NSString stringWithFormat:@"已安装 %lu 个内置示例脚本，位于：\n%@", (unsigned long)examples.count, EXAMPLE_SCRIPTS_PATH];
    [Util showAlertBoxWithOneOption:self title:@"示例脚本" message:message buttonString:@"确定"];
}

- (void)handleRegistryTap:(TableViewCellWithEntry*)cell {
    NSDictionary *registry = [NSDictionary dictionaryWithContentsOfFile:SCRIPT_REGISTRY_PATH];
    NSString *version = registry[@"version"] ?: @"缺失";
    NSString *examplesPath = registry[@"examplesPath"] ?: EXAMPLE_SCRIPTS_PATH;
    NSArray *scripts = registry[@"scripts"] ?: @[];
    NSString *message = [NSString stringWithFormat:@"注册表版本：%@\n脚本数量：%lu\n示例路径：%@", version, (unsigned long)scripts.count, examplesPath];
    [Util showAlertBoxWithOneOption:self title:@"脚本注册表" message:message buttonString:@"确定"];
}

- (void)handleTouchIndicatorWithEntryCellInstance:(TableViewCellWithEntry*)cell {
    TouchIndicatorConfigurationViewController *vc = [[TouchIndicatorConfigurationViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}


//配置每个section(段）有多少row（行） cell
//默认只有一个section
-(NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{
    return cellsForEachSection[section].count;
}

-(NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return sections.count;
}

//每行显示什么东西
-(UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath{

    UITableViewCell *result;
    

    NSInteger indexInCurrentSection = indexPath.row;

    
    NSArray* cellList = cellsForEachSection[indexPath.section];

    NSDictionary *cellInfo = cellList[indexInCurrentSection];
    if ([cellInfo[@"type"] intValue] == SETTING_CELL_SWITCH)
    {
        static NSString *cellID = @"SwitchCell";

        TableViewCellWithSwitch *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
        
        //判断队列里面是否有这个cell 没有自己创建，有直接使用
        if (cell == nil) {
            //没有,创建一个
            cell = [[TableViewCellWithSwitch alloc]initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellID];
        }
        
        cell.title.text = cellInfo[@"title"];
        cell.title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        cell.iconView.image = ZXSettingsSymbol([self iconNameForCellTitle:cellInfo[@"title"]]);
        cell.iconView.tintColor = [UIColor systemBlueColor];
        cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        [cell.switchBtn removeTarget:nil action:NULL forControlEvents:UIControlEventValueChanged];
        [cell.switchBtn addTarget:self action:NSSelectorFromString(cellInfo[@"switch_click_handler"]) forControlEvents:UIControlEventValueChanged];
        [cell.switchBtn setOn:[cellInfo[@"switch_init_status"] boolValue]];
        
        result = cell;
    }
    else if ([cellInfo[@"type"] intValue] == SETTING_CELL_ENTRY)
    {
        static NSString *cellID = @"EntryCell";

        TableViewCellWithEntry *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
        
        //判断队列里面是否有这个cell 没有自己创建，有直接使用
        if (cell == nil) {
            //没有,创建一个
            NSLog(@"create a setting cell switch");
            cell = [[TableViewCellWithEntry alloc]initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellID];
        }
        
        cell.title.text = cellInfo[@"title"];
        cell.subTitle.text = cellInfo[@"secondary_title"];
        cell.title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        cell.subTitle.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        cell.subTitle.textColor = [UIColor secondaryLabelColor];
        cell.iconView.image = ZXSettingsSymbol([self iconNameForCellTitle:cellInfo[@"title"]]);
        cell.iconView.tintColor = [UIColor systemBlueColor];
        cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.clickHandler = cellInfo[@"row_click_handler"];
        
        result = cell;
    }
    else if ([cellInfo[@"type"] intValue] == SETTING_CELL_SEGMENT)
    {
        static NSString *cellID = @"SegmentCell";

        TableViewCellWithEntry *cell = [tableView dequeueReusableCellWithIdentifier:cellID];

        cell.title.text = cellInfo[@"title"];
        cell.subTitle.text = @"";
        cell.title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        cell.iconView.image = ZXSettingsSymbol([self iconNameForCellTitle:cellInfo[@"title"]]);
        cell.iconView.tintColor = [UIColor systemBlueColor];
        cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.clickHandler = nil;

        NSInteger mode = [cellInfo[@"segment_selected"] integerValue];
        if (mode < 0 || mode > 2) mode = 0;   // 0跟随系统 1浅色 2深色
        UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:cellInfo[@"segment_titles"]];
        seg.selectedSegmentIndex = 2 - mode;  // 段序：深色 / 浅色 / 跟随系统
        seg.translatesAutoresizingMaskIntoConstraints = NO;
        [seg addTarget:self action:NSSelectorFromString(cellInfo[@"segment_click_handler"]) forControlEvents:UIControlEventValueChanged];
        for (UIView *v in cell.contentView.subviews) {
            if ([v isKindOfClass:[UISegmentedControl class]]) [v removeFromSuperview];
        }
        [cell.contentView addSubview:seg];
        // 右对齐：贴 contentView 右边界。原先按 tableView.bounds 算 x，分组表格的 contentView 比
        // tableView 窄，最右侧「跟随系统」会超出屏幕；绑定到 contentView 才保证三段都在屏幕内。
        // 左边这条「别压到标题」也是必需约束，窄屏时分段控件会自动收窄而不是溢出。
        [NSLayoutConstraint activateConstraints:@[
            [seg.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-14],
            [seg.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [seg.leadingAnchor constraintGreaterThanOrEqualToAnchor:cell.title.trailingAnchor constant:12]
        ]];

        result = cell;
    }
    
    
    return result;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath{
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    UITableViewCell *cell = [_tableView cellForRowAtIndexPath:indexPath];
    if ([cell isKindOfClass:[TableViewCellWithEntry class]])
    {
        TableViewCellWithEntry *entry = (TableViewCellWithEntry*)cell;
        if (entry.clickHandler.length > 0) {
            [self performSelector:NSSelectorFromString(entry.clickHandler) withObject:entry];
        }
    }
}

// Override to support editing the table view.
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {

}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}


- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    UIView *resultView = [[UIView alloc] init];
    //view.backgroundColor = [UIColor greenColor];
    
    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    title.textColor = [UIColor secondaryLabelColor];

    title.text = sections[section];

    
    [resultView addSubview:title];
    
    [[title.leftAnchor constraintEqualToAnchor:resultView.leftAnchor constant:20] setActive:YES];
    [[title.bottomAnchor constraintEqualToAnchor:resultView.bottomAnchor constant:-5] setActive:YES];

    return resultView;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return 38;
}
/*
#pragma mark - Navigation

// In a storyboard-based application, you will often want to do a little preparation before navigation
- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    // Get the new view controller using [segue destinationViewController].
    // Pass the selected object to the new view controller.
}
*/

@end
