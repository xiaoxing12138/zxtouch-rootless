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

- (BOOL)darkModeEnabled {
    id configValue = [configManager getValueFromKey:@"dark_mode"];
    if (configValue) {
        return [configValue boolValue];
    }
    BOOL legacyValue = [[NSUserDefaults standardUserDefaults] boolForKey:@"dark_mode"];
    [configManager updateKey:@"dark_mode" forValue:@(legacyValue)];
    [configManager save];
    return legacyValue;
}

- (NSString *)triggerActionTitle:(NSString *)action {
    if ([action isEqualToString:ZX_ACTION_TOGGLE_PANEL]) return @"显示/隐藏控制面板";
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
    if ([title containsString:@"触摸"]) return @"hand.tap";
    if ([title containsString:@"双击"]) return @"bolt.badge.clock";
    if ([title containsString:@"音量"]) return @"speaker.wave.2";
    if ([title containsString:@"默认触发"]) return @"play.square.stack";
    if ([title containsString:@"切换App"]) return @"arrow.triangle.2.circlepath";
    if ([title containsString:@"示例"]) return @"folder";
    if ([title containsString:@"注册表"]) return @"list.bullet.rectangle";
    if ([title containsString:@"深色"]) return @"moon";
    if ([title containsString:@"调试"]) return @"wrench.and.screwdriver";
    if ([title containsString:@"ZXTouch"]) return @"info.circle";
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
    
    sections = @[@"远程管理", @"控制", @"自动操作", @"脚本", @"外观", @"关于"];
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

    BOOL darkMode = [self darkModeEnabled];

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
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"触摸指示器", @"secondary_title": @"", @"row_click_handler": NSStringFromSelector(@selector(handleTouchIndicatorWithEntryCellInstance:))},
            @{@"type": @(SETTING_CELL_SWITCH), @"title": @"双击下音量键打开控制面板", @"switch_click_handler": NSStringFromSelector(@selector(handlePopupWindowDoubleClick:)), @"switch_init_status": @(doubleClickPopup)},
            @{@"type": @(SETTING_CELL_SWITCH), @"title": @"网速指示器", @"switch_click_handler": NSStringFromSelector(@selector(handleNetSpeedIndicatorToggle:)), @"switch_init_status": @(netSpeedIndicator)},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"网速指示器设置", @"secondary_title": @"位置 / 字号 / 边距 / 息屏暂停", @"row_click_handler": NSStringFromSelector(@selector(handleNetSpeedSettingsTap:))},
            @{@"type": @(SETTING_CELL_SWITCH), @"title": @"悬浮控制按钮", @"switch_click_handler": NSStringFromSelector(@selector(handleFloatingMenuToggle:)), @"switch_init_status": @(floatingMenu)},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"悬浮窗调试", @"secondary_title": @"查看当前位置/方向/变换矩阵等", @"row_click_handler": NSStringFromSelector(@selector(handleDebugFloatWindowTap:))}
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
            @{@"type": @(SETTING_CELL_SWITCH), @"title": @"深色模式", @"switch_click_handler": NSStringFromSelector(@selector(handleDarkModeToggle:)), @"switch_init_status": @(darkMode)}
        ],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": [NSString stringWithFormat:@"ZXTouch %@", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"]], @"secondary_title": @"iOS 15-17 移植版，作者 Epic0001", @"row_click_handler": NSStringFromSelector(@selector(handleCreditsTap:))}
        ]
    ];
     
    UINib *SwitchCellNib = [UINib nibWithNibName:@"TableViewCellWithSwitch" bundle:nil];
    [_tableView registerNib:SwitchCellNib forCellReuseIdentifier:@"SwitchCell"];

    UINib *entryCellNib = [UINib nibWithNibName:@"TableViewCellWithEntry" bundle:nil];
    [_tableView registerNib:entryCellNib forCellReuseIdentifier:@"EntryCell"];
    
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

    BOOL darkMode = [self darkModeEnabled];

    BOOL netSpeedIndicator = NO;
    if ([configManager getValueFromKey:@"net_speed_indicator_enabled"])
        netSpeedIndicator = [[configManager getValueFromKey:@"net_speed_indicator_enabled"] boolValue];

    BOOL floatingMenu = NO;
    if ([configManager getValueFromKey:@"floating_menu_enabled"])
        floatingMenu = [[configManager getValueFromKey:@"floating_menu_enabled"] boolValue];

    sections = @[@"远程管理", @"控制", @"自动操作", @"脚本", @"外观", @"关于"];
    cellsForEachSection = @[
        [self remoteManagementCells],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"触摸指示器", @"secondary_title": @"", @"row_click_handler": NSStringFromSelector(@selector(handleTouchIndicatorWithEntryCellInstance:))},
            @{@"type": @(SETTING_CELL_SWITCH), @"title": @"双击下音量键打开控制面板", @"switch_click_handler": NSStringFromSelector(@selector(handlePopupWindowDoubleClick:)), @"switch_init_status": @(doubleClickPopup)},
            @{@"type": @(SETTING_CELL_SWITCH), @"title": @"网速指示器", @"switch_click_handler": NSStringFromSelector(@selector(handleNetSpeedIndicatorToggle:)), @"switch_init_status": @(netSpeedIndicator)},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"网速指示器设置", @"secondary_title": @"位置 / 字号 / 边距 / 息屏暂停", @"row_click_handler": NSStringFromSelector(@selector(handleNetSpeedSettingsTap:))},
            @{@"type": @(SETTING_CELL_SWITCH), @"title": @"悬浮控制按钮", @"switch_click_handler": NSStringFromSelector(@selector(handleFloatingMenuToggle:)), @"switch_init_status": @(floatingMenu)},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"悬浮窗调试", @"secondary_title": @"查看当前位置/方向/变换矩阵等", @"row_click_handler": NSStringFromSelector(@selector(handleDebugFloatWindowTap:))}
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
            @{@"type": @(SETTING_CELL_SWITCH), @"title": @"深色模式", @"switch_click_handler": NSStringFromSelector(@selector(handleDarkModeToggle:)), @"switch_init_status": @(darkMode)}
        ],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": [NSString stringWithFormat:@"ZXTouch %@", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"]], @"secondary_title": @"iOS 15-17 移植版，作者 Epic0001", @"row_click_handler": NSStringFromSelector(@selector(handleCreditsTap:))}
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
    
    Socket *socket = [[Socket alloc] init];
    [socket connect:@"127.0.0.1" byPort:6000];
    [socket send:@"902"];
    [socket recv:1024];
    [socket close];
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
    Socket *socket = [[Socket alloc] init];
    [socket connect:@"127.0.0.1" byPort:6000];
    [socket send:@"901"];
    [socket recv:1024];
    [socket close];
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
    [sheet addAction:[UIAlertAction actionWithTitle:@"显示/隐藏控制面板" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
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
    [sheet addAction:[UIAlertAction actionWithTitle:@"显示/隐藏控制面板" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
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

- (void)handleFloatingMenuToggle:(UISwitch*)s {
    BOOL enabled = [s isOn];
    [configManager updateKey:@"floating_menu_enabled" forValue:@(enabled)];
    [configManager save];

    // Notify SpringBoard tweak via socket (command 32)
    Socket *socket = [[Socket alloc] init];
    if ([socket connect:@"127.0.0.1" byPort:6000] == 0) {
        NSString *cmd = [NSString stringWithFormat:@"32;;%d\r\n", enabled ? 1 : 0];
        [socket send:cmd];
        [socket close];
    }
}

- (void)handleDebugFloatWindowTap:(TableViewCellWithEntry *)cell {
    DebugFloatWindowViewController *vc = [[DebugFloatWindowViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)handleDarkModeToggle:(UISwitch*)s {
    BOOL dark = [s isOn];
    [configManager updateKey:@"dark_mode" forValue:@(dark)];
    [configManager save];

    [[NSUserDefaults standardUserDefaults] setBool:dark forKey:@"dark_mode"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    // Apply to all app windows immediately (iOS 13+)
    if (@available(iOS 13.0, *)) {
        UIUserInterfaceStyle style = dark ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
        for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *win in ((UIWindowScene *)scene).windows) {
                    win.overrideUserInterfaceStyle = style;
                }
            }
        }
    }

    // Notify SpringBoard to apply dark mode to the panel (command 903)
    Socket *socket = [[Socket alloc] init];
    [socket connect:@"127.0.0.1" byPort:6000];
    [socket send:@"903"];
    [socket recv:1024];
    [socket close];
}

- (void)handleCreditsTap:(TableViewCellWithEntry*)cell {
    // Show a brief about alert
    [Util showAlertBoxWithOneOption:self title:@"ZXTouch Rootless"
        message:@"iOS 16 Rootless（Dopamine 越狱）移植版，作者 Epic0001\nhttps://github.com/Epic0001/zxtouchrootless"
        buttonString:@"确定"];
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
    if ([cell isSelected])
    {
        UIStoryboard *sb = [UIStoryboard storyboardWithName:@"SettingPages" bundle:nil];
        TouchIndicatorConfigurationViewController *touchIndicatorConfigurationViewController = [sb instantiateViewControllerWithIdentifier:@"TouchIndicatorConfigurationPage"];
        [self.navigationController pushViewController:touchIndicatorConfigurationViewController animated:YES];
        //[self.navigationController setTitle:@"Touch Indicator"];
    }

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
    
    
    return result;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath{
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    UITableViewCell *cell = [_tableView cellForRowAtIndexPath:indexPath];
    if ([cell isKindOfClass:[TableViewCellWithEntry class]])
    {
        TableViewCellWithEntry *entry = (TableViewCellWithEntry*)cell;
        [self performSelector:NSSelectorFromString(entry.clickHandler) withObject:entry];
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
