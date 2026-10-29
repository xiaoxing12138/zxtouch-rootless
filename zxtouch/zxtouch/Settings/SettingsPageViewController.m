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

#import <QuartzCore/QuartzCore.h>

#define SETTING_CELL_SWITCH 0
#define SETTING_CELL_ENTRY 1
#define SETTING_CELL_SEGMENT 2

#define ZX_ACTION_SMART_TOGGLE @"smart_toggle"
#define ZX_ACTION_TOGGLE_PANEL @"toggle_panel"
#define ZX_ACTION_STOP_SCRIPT @"stop_script"
#define ZX_ACTION_TOGGLE_RECORDING @"toggle_recording"
#define ZX_ACTION_RUN_SCRIPT @"run_script"
#define ZX_ACTION_RUN_CURRENT_SCRIPT @"run_current_script"

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

@interface ZXInfoPageViewController : UIViewController
- (UIView *)cardAt:(CGFloat)y width:(CGFloat)w margin:(CGFloat)margin inScroll:(UIScrollView *)scroll;
- (void)finishCard:(UIView *)card y:(CGFloat *)y height:(CGFloat)height margin:(CGFloat)margin width:(CGFloat)w;
- (UILabel *)addText:(NSString *)text font:(UIFont *)font color:(UIColor *)color card:(UIView *)card y:(CGFloat *)y width:(CGFloat)w wrap:(BOOL)wrap;
- (CGFloat)addLink:(NSString *)title card:(UIView *)card y:(CGFloat)y width:(CGFloat)w action:(SEL)action;
- (void)copyQQGroup;
- (void)openBilibili;
- (void)showUpdateHint;
@end

@interface ZXUpdateCheckViewController : ZXInfoPageViewController
@end

@interface ZXCommunityViewController : ZXInfoPageViewController
@end

@interface ZXClickTestViewController : UIViewController
@end

#pragma mark - Python 依赖检测结果浮窗（加宽 / 居左 / 结论置顶 / 不显示长路径）

@interface ZXPythonCheckPanel : UIViewController
@property (nonatomic, copy) NSString *fullReport;
- (void)setVerdict:(NSString *)verdict usable:(BOOL)usable;
- (void)setBodyText:(NSString *)body;
@end

@implementation ZXPythonCheckPanel
{
    UIView *_card;
    UILabel *_titleLabel;
    UILabel *_verdictLabel;
    UIScrollView *_scroll;
    UILabel *_bodyLabel;
    UIButton *_copyButton;
    UIButton *_closeButton;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.5];

    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.backgroundColor = [UIColor colorWithRed:0.10 green:0.11 blue:0.14 alpha:1.0];
    _card.layer.cornerRadius = 14.0;
    _card.layer.masksToBounds = YES;
    [self.view addSubview:_card];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.text = @"Python 依赖检测";
    _titleLabel.font = [UIFont boldSystemFontOfSize:18];
    _titleLabel.textColor = [UIColor whiteColor];
    _titleLabel.textAlignment = NSTextAlignmentLeft;
    [_card addSubview:_titleLabel];

    _verdictLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _verdictLabel.text = @"正在检测…";
    _verdictLabel.font = [UIFont boldSystemFontOfSize:17];
    _verdictLabel.textColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.25 alpha:1.0];
    _verdictLabel.numberOfLines = 0;
    _verdictLabel.textAlignment = NSTextAlignmentLeft;
    [_card addSubview:_verdictLabel];

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scroll.showsVerticalScrollIndicator = YES;
    _scroll.alwaysBounceVertical = YES;
    [_card addSubview:_scroll];

    _bodyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _bodyLabel.text = @"正在连接 SpringBoard 进程，请稍候…";
    _bodyLabel.font = [UIFont fontWithName:@"Menlo" size:12.5] ?: [UIFont systemFontOfSize:12.5];
    _bodyLabel.textColor = [UIColor colorWithWhite:0.93 alpha:1.0];
    _bodyLabel.numberOfLines = 0;
    _bodyLabel.textAlignment = NSTextAlignmentLeft;
    [_scroll addSubview:_bodyLabel];

    _copyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_copyButton setTitle:@"复制完整结果" forState:UIControlStateNormal];
    [_copyButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _copyButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    _copyButton.backgroundColor = [UIColor colorWithRed:0.10 green:0.52 blue:0.82 alpha:1.0];
    _copyButton.layer.cornerRadius = 9.0;
    _copyButton.layer.masksToBounds = YES;
    [_copyButton addTarget:self action:@selector(copyTapped) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:_copyButton];

    _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_closeButton setTitle:@"关闭" forState:UIControlStateNormal];
    [_closeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _closeButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    _closeButton.backgroundColor = [UIColor colorWithWhite:0.24 alpha:1.0];
    _closeButton.layer.cornerRadius = 9.0;
    _closeButton.layer.masksToBounds = YES;
    [_closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:_closeButton];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize vs = self.view.bounds.size;
    CGFloat cardW = MIN(vs.width - 28.0, 680.0);
    CGFloat cardH = MIN(vs.height - 56.0, 900.0);
    _card.frame = CGRectMake((vs.width - cardW) / 2.0, (vs.height - cardH) / 2.0, cardW, cardH);

    CGFloat pad = 20.0;
    CGFloat w = cardW - pad * 2.0;
    CGFloat cy = pad;

    _titleLabel.frame = CGRectMake(pad, cy, w, 24.0);
    cy += 30.0;

    CGSize verdictSize = [_verdictLabel sizeThatFits:CGSizeMake(w, CGFLOAT_MAX)];
    _verdictLabel.frame = CGRectMake(pad, cy, w, ceil(verdictSize.height));
    cy += ceil(verdictSize.height) + 12.0;

    CGFloat btnH = 40.0;
    CGFloat btnBottom = cardH - pad - btnH;
    _closeButton.frame = CGRectMake(pad + w - 100.0, btnBottom, 100.0, btnH);
    _copyButton.frame = CGRectMake(pad + w - 100.0 - 10.0 - 150.0, btnBottom, 150.0, btnH);

    CGFloat scrollH = MAX(btnBottom - 12.0 - cy, 60.0);
    _scroll.frame = CGRectMake(pad, cy, w, scrollH);
    CGSize bodySize = [_bodyLabel sizeThatFits:CGSizeMake(w, CGFLOAT_MAX)];
    _bodyLabel.frame = CGRectMake(0.0, 0.0, w, ceil(bodySize.height));
    _scroll.contentSize = CGSizeMake(w, ceil(bodySize.height) + 2.0);
}

- (void)setVerdict:(NSString *)verdict usable:(BOOL)usable {
    _verdictLabel.text = verdict;
    _verdictLabel.textColor = usable
        ? [UIColor colorWithRed:0.20 green:0.85 blue:0.40 alpha:1.0]
        : [UIColor colorWithRed:1.0 green:0.32 blue:0.28 alpha:1.0];
    [_verdictLabel setNeedsLayout];
    [self.view setNeedsLayout];
}

- (void)setBodyText:(NSString *)body {
    _bodyLabel.text = body;
    [_bodyLabel setNeedsLayout];
    [self.view setNeedsLayout];
}

- (void)copyTapped {
    NSString *text = _fullReport.length > 0 ? _fullReport : _bodyLabel.text;
    [UIPasteboard generalPasteboard].string = text ?: @"";
    [_copyButton setTitle:@"已复制 ✓" forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self->_copyButton setTitle:@"复制完整结果" forState:UIControlStateNormal];
    });
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

#pragma mark - 快捷键设置页

static NSString *ZXShortcutTriggerName(NSString *key)
{
    return [key isEqualToString:ZX_TRIGGER_VOLUME_UP] ? @"音量加" : @"音量减";
}

static NSMutableDictionary *ZXShortcutLoadTrigger(ConfigManager *cm, NSString *key)
{
    NSMutableDictionary *all = [[cm getValueFromKey:@"trigger_configs"] mutableCopy];
    if (![all isKindOfClass:[NSMutableDictionary class]]) all = [NSMutableDictionary dictionary];
    NSDictionary *existing = all[key];
    NSMutableDictionary *trigger = [existing isKindOfClass:[NSDictionary class]] ? [existing mutableCopy] : nil;

    BOOL isDown = [key isEqualToString:ZX_TRIGGER_VOLUME_DOWN];
    if (!trigger) {
        BOOL enabled = NO;
        NSString *action = ZX_ACTION_SMART_TOGGLE;
        NSString *script = @"";
        if (isDown) {
            enabled = YES;
            id legacyEnabled = [cm getValueFromKey:@"double_click_volume_show_popup"];
            if (legacyEnabled) enabled = [legacyEnabled boolValue];
            action = [cm getValueFromKey:@"double_click_volume_action"] ?: ZX_ACTION_SMART_TOGGLE;
            script = [cm getValueFromKey:@"double_click_volume_script"] ?: @"";
        }
        trigger = [NSMutableDictionary dictionary];
        trigger[@"enabled"] = @(enabled);
        trigger[@"count"] = @(2);
        trigger[@"counts"] = [@{ @"2": [@{ @"action": action, @"script": script } mutableCopy] } mutableCopy];
    }

    if (![trigger[@"counts"] isKindOfClass:[NSDictionary class]]) {
        NSInteger count = [trigger[@"count"] integerValue];
        if (count < 1 || count > 5) count = 2;
        NSString *action = trigger[@"action"] ?: ZX_ACTION_SMART_TOGGLE;
        NSString *script = trigger[@"script"] ?: @"";
        trigger[@"counts"] = [@{ [NSString stringWithFormat:@"%ld", (long)count]: [@{ @"action": action, @"script": script } mutableCopy] } mutableCopy];
    }
    if (![trigger[@"enabled"] isKindOfClass:[NSNumber class]]) trigger[@"enabled"] = @(isDown);
    return trigger;
}

static void ZXShortcutSaveTrigger(ConfigManager *cm, NSString *key, NSDictionary *trigger)
{
    NSMutableDictionary *all = [[cm getValueFromKey:@"trigger_configs"] mutableCopy];
    if (![all isKindOfClass:[NSMutableDictionary class]]) all = [NSMutableDictionary dictionary];
    all[key] = trigger;
    [cm updateKey:@"trigger_configs" forValue:all];
    if ([key isEqualToString:ZX_TRIGGER_VOLUME_DOWN]) {
        [cm updateKey:@"double_click_volume_show_popup" forValue:(trigger[@"enabled"] ?: @YES)];
    }
    [cm save];
}

static NSString *ZXShortcutActionSummary(NSDictionary *entry)
{
    NSString *action = entry[@"action"];
    if ([action isEqualToString:ZX_ACTION_RUN_SCRIPT]) {
        NSString *scriptPath = [entry[@"script"] isKindOfClass:[NSString class]] ? entry[@"script"] : @"";
        NSString *name = [[scriptPath lastPathComponent] stringByDeletingPathExtension];
        return name.length ? [NSString stringWithFormat:@"运行指定脚本：%@", name] : @"运行指定脚本";
    }
    if ([action isEqualToString:ZX_ACTION_RUN_CURRENT_SCRIPT]) return @"运行当前选择的脚本";
    if ([action isEqualToString:ZX_ACTION_STOP_SCRIPT]) return @"停止运行脚本";
    if ([action isEqualToString:ZX_ACTION_TOGGLE_RECORDING]) return @"开始/停止录制";
    if ([action isEqualToString:ZX_ACTION_TOGGLE_PANEL]) return @"显示/隐藏选项面板（旧设置）";
    if ([action isEqualToString:ZX_ACTION_SMART_TOGGLE]) return @"智能切换（旧设置）";
    return @"未设置";
}

static NSArray<NSString *> *ZXShortcutScriptPaths(void)
{
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

@interface ZXShortcutSettingsViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@end

@implementation ZXShortcutSettingsViewController
{
    UITableView *_table;
    ConfigManager *_cm;
    NSArray<NSString *> *_keys;
    NSMutableDictionary *_triggers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"快捷键";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    _keys = @[ZX_TRIGGER_VOLUME_UP, ZX_TRIGGER_VOLUME_DOWN];
    _triggers = [NSMutableDictionary dictionary];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    _table.translatesAutoresizingMaskIntoConstraints = NO;
    _table.dataSource = self;
    _table.delegate = self;
    _table.backgroundColor = [UIColor systemGroupedBackgroundColor];
    _table.tableFooterView = [[UIView alloc] init];
    _table.rowHeight = 54.0;
    [self.view addSubview:_table];

    [NSLayoutConstraint activateConstraints:@[
        [_table.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    UINib *switchNib = [UINib nibWithNibName:@"TableViewCellWithSwitch" bundle:nil];
    [_table registerNib:switchNib forCellReuseIdentifier:@"SwitchCell"];
    UINib *entryNib = [UINib nibWithNibName:@"TableViewCellWithEntry" bundle:nil];
    [_table registerNib:entryNib forCellReuseIdentifier:@"EntryCell"];

    [self reloadTriggers];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadTriggers];
    [_table reloadData];
}

- (void)reloadTriggers {
    _cm = [[ConfigManager alloc] initWithPath:SPRINGBOARD_CONFIG_PATH];
    for (NSString *key in _keys) {
        _triggers[key] = ZXShortcutLoadTrigger(_cm, key);
    }
}

- (void)sendReload {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        Socket *socket = [[Socket alloc] init];
        if ([socket connect:@"127.0.0.1" byPort:6000] == 0) {
            [socket send:@"901\r\n"];
            [socket close];
        }
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)_keys.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 6;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSString *key = _keys[section];
    return [NSString stringWithFormat:@"%@（连按 %@ 键）", ZXShortcutTriggerName(key), ZXShortcutTriggerName(key)];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == (NSInteger)_keys.count - 1) {
        return @"只有最后停下来的点击数会触发；没设置的次数点几次都不会执行动作。";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *key = _keys[indexPath.section];
    NSMutableDictionary *trigger = _triggers[key];

    if (indexPath.row == 0) {
        TableViewCellWithSwitch *cell = [tableView dequeueReusableCellWithIdentifier:@"SwitchCell" forIndexPath:indexPath];
        [cell setTitleText:[NSString stringWithFormat:@"启用%@快捷键", ZXShortcutTriggerName(key)]];
        [cell setBtnInitStatus:[trigger[@"enabled"] boolValue]];
        [cell.switchBtn removeTarget:self action:@selector(shortcutSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.switchBtn.tag = indexPath.section;
        [cell.switchBtn addTarget:self action:@selector(shortcutSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        return cell;
    }

    TableViewCellWithEntry *cell = [tableView dequeueReusableCellWithIdentifier:@"EntryCell" forIndexPath:indexPath];
    NSArray<NSString *> *cn = @[@"一", @"二", @"三", @"四", @"五"];
    NSInteger count = indexPath.row;
    NSString *countKey = [NSString stringWithFormat:@"%ld", (long)count];
    NSDictionary *entry = trigger[@"counts"][countKey];
    [cell.title setText:[NSString stringWithFormat:@"点%@次触发", cn[count - 1]]];
    [cell.subTitle setText:(entry ? ZXShortcutActionSummary(entry) : @"未设置（点这一行设置）")];
    return cell;
}

- (void)shortcutSwitchChanged:(UISwitch *)sender {
    NSInteger section = sender.tag;
    if (section < 0 || section >= (NSInteger)_keys.count) return;
    NSString *key = _keys[section];
    NSMutableDictionary *trigger = _triggers[key];
    trigger[@"enabled"] = @([sender isOn]);
    ZXShortcutSaveTrigger(_cm, key, trigger);
    [self sendReload];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row == 0) return;

    NSInteger section = indexPath.section;
    NSInteger count = indexPath.row;
    NSString *key = _keys[section];
    NSArray<NSString *> *cn = @[@"一", @"二", @"三", @"四", @"五"];
    NSString *title = [NSString stringWithFormat:@"%@ · 点%@次触发", ZXShortcutTriggerName(key), cn[count - 1]];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
        message:@"选择这一步要执行的动作。"
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"运行指定脚本…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf pickScriptForSection:section count:count fromCell:[tableView cellForRowAtIndexPath:indexPath]];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"运行当前选择的脚本" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf setAction:ZX_ACTION_RUN_CURRENT_SCRIPT script:nil section:section count:count];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"停止运行脚本" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf setAction:ZX_ACTION_STOP_SCRIPT script:nil section:section count:count];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"开始/停止录制" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf setAction:ZX_ACTION_TOGGLE_RECORDING script:nil section:section count:count];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"清除此设置" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [weakSelf clearActionForSection:section count:count];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        pop.sourceView = cell;
        pop.sourceRect = cell.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)pickScriptForSection:(NSInteger)section count:(NSInteger)count fromCell:(UITableViewCell *)cell {
    NSArray<NSString *> *scripts = ZXShortcutScriptPaths();
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"运行指定脚本"
        message:(scripts.count ? @"选择此触发要运行的脚本。" : @"未找到任何 .bdl 脚本。")
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSString *script in scripts) {
        NSString *name = [[script lastPathComponent] stringByDeletingPathExtension];
        [sheet addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [weakSelf setAction:ZX_ACTION_RUN_SCRIPT script:script section:section count:count];
        }]];
        if (sheet.actions.count >= 20) break;
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop) {
        pop.sourceView = cell;
        pop.sourceRect = cell.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (NSMutableDictionary *)countsForSection:(NSInteger)section {
    NSString *key = _keys[section];
    NSMutableDictionary *trigger = _triggers[key];
    NSDictionary *existing = trigger[@"counts"];
    NSMutableDictionary *counts = [existing isKindOfClass:[NSDictionary class]] ? [existing mutableCopy] : [NSMutableDictionary dictionary];
    trigger[@"counts"] = counts;
    return counts;
}

- (void)setAction:(NSString *)action script:(NSString *)script section:(NSInteger)section count:(NSInteger)count {
    NSString *key = _keys[section];
    NSMutableDictionary *trigger = _triggers[key];
    NSMutableDictionary *counts = [self countsForSection:section];
    counts[[NSString stringWithFormat:@"%ld", (long)count]] = [@{ @"action": action, @"script": script ?: @"" } mutableCopy];
    trigger[@"enabled"] = @(YES);
    ZXShortcutSaveTrigger(_cm, key, trigger);
    [self sendReload];
    [_table reloadData];
}

- (void)clearActionForSection:(NSInteger)section count:(NSInteger)count {
    NSString *key = _keys[section];
    NSMutableDictionary *trigger = _triggers[key];
    NSMutableDictionary *counts = [self countsForSection:section];
    [counts removeObjectForKey:[NSString stringWithFormat:@"%ld", (long)count]];
    ZXShortcutSaveTrigger(_cm, key, trigger);
    [self sendReload];
    [_table reloadData];
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
    if ([title containsString:@"检测更新"]) return @"arrow.down.circle";
    if ([title containsString:@"交流"] || [title containsString:@"声明"]) return @"doc.text";
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
    
    sections = @[@"远程管理", @"控制", @"工具", @"脚本", @"外观", @"检测", @"关于小新Lap"];
    configManager = [[ConfigManager alloc] initWithPath:SPRINGBOARD_CONFIG_PATH];
    BOOL doubleClickPopup = YES;
    if ([configManager getValueFromKey:@"double_click_volume_show_popup"])
    {
        doubleClickPopup = [[configManager getValueFromKey:@"double_click_volume_show_popup"] boolValue];
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
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"控制按钮悬浮窗", @"secondary_title": @"开关 / 吸附边 / 纵向位置（也可手动拖动）", @"row_click_handler": NSStringFromSelector(@selector(handleFloatingMenuEntryTap:))}
        ],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"网速悬浮窗", @"secondary_title": @"开关 / 位置 / 字号 / 边距", @"row_click_handler": NSStringFromSelector(@selector(handleNetSpeedSettingsTap:))}
        ],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"快捷键", @"secondary_title": [self shortcutSummary], @"row_click_handler": NSStringFromSelector(@selector(handleShortcutEntryTap:))},
            @{@"type": @(SETTING_CELL_SWITCH), @"title": @"脚本完成弹窗", @"switch_click_handler": NSStringFromSelector(@selector(handleScriptFinishedPopupToggle:)), @"switch_init_status": @(showFinishedPopup)},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"示例脚本", @"secondary_title": EXAMPLE_SCRIPTS_PATH, @"row_click_handler": NSStringFromSelector(@selector(handleExamplesTap:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"脚本注册表", @"secondary_title": SCRIPT_REGISTRY_PATH, @"row_click_handler": NSStringFromSelector(@selector(handleRegistryTap:))}
        ],
        @[
            @{@"type": @(SETTING_CELL_SEGMENT), @"title": @"界面外观", @"segment_titles": @[@"深色", @"浅色", @"跟随系统"], @"segment_selected": @(appearanceMode), @"segment_click_handler": NSStringFromSelector(@selector(handleAppearanceChanged:))}
        ],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"点击测试", @"secondary_title": @"记录点击位置、次数与点击频率", @"row_click_handler": NSStringFromSelector(@selector(handleClickTestTap:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"悬浮窗调试", @"secondary_title": @"查看当前位置/方向/变换矩阵等", @"row_click_handler": NSStringFromSelector(@selector(handleDebugFloatWindowTap:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"屏幕坐标测试", @"secondary_title": @"旋转屏幕点四角，验证坐标系映射", @"row_click_handler": NSStringFromSelector(@selector(handleTapTestWindowTap:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"Python 依赖检测", @"secondary_title": @"检查 python3 是否存在、能否运行、模块路径", @"row_click_handler": NSStringFromSelector(@selector(handlePythonCheckTap:))}
        ],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"检测更新", @"secondary_title": [NSString stringWithFormat:@"当前版本 v%@，点击检查是否有新版本", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @""], @"row_click_handler": NSStringFromSelector(@selector(handleUpdateCheckTap:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"交流与免责声明", @"secondary_title": @"QQ 交流群 / bilibili / 开源声明 / 免责声明", @"row_click_handler": NSStringFromSelector(@selector(handleCommunityTap:))}
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

    sections = @[@"远程管理", @"控制", @"工具", @"脚本", @"外观", @"检测", @"关于小新Lap"];
    cellsForEachSection = @[
        [self remoteManagementCells],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"触摸指示器", @"secondary_title": @"圆点与坐标悬浮窗", @"row_click_handler": NSStringFromSelector(@selector(handleTouchIndicatorWithEntryCellInstance:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"控制按钮悬浮窗", @"secondary_title": @"开关 / 吸附边 / 纵向位置（也可手动拖动）", @"row_click_handler": NSStringFromSelector(@selector(handleFloatingMenuEntryTap:))}
        ],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"网速悬浮窗", @"secondary_title": @"开关 / 位置 / 字号 / 边距", @"row_click_handler": NSStringFromSelector(@selector(handleNetSpeedSettingsTap:))}
        ],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"快捷键", @"secondary_title": [self shortcutSummary], @"row_click_handler": NSStringFromSelector(@selector(handleShortcutEntryTap:))},
            @{@"type": @(SETTING_CELL_SWITCH), @"title": @"脚本完成弹窗", @"switch_click_handler": NSStringFromSelector(@selector(handleScriptFinishedPopupToggle:)), @"switch_init_status": @(showFinishedPopup)},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"示例脚本", @"secondary_title": EXAMPLE_SCRIPTS_PATH, @"row_click_handler": NSStringFromSelector(@selector(handleExamplesTap:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"脚本注册表", @"secondary_title": SCRIPT_REGISTRY_PATH, @"row_click_handler": NSStringFromSelector(@selector(handleRegistryTap:))}
        ],
        @[
            @{@"type": @(SETTING_CELL_SEGMENT), @"title": @"界面外观", @"segment_titles": @[@"深色", @"浅色", @"跟随系统"], @"segment_selected": @(appearanceMode), @"segment_click_handler": NSStringFromSelector(@selector(handleAppearanceChanged:))}
        ],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"点击测试", @"secondary_title": @"记录点击位置、次数与点击频率", @"row_click_handler": NSStringFromSelector(@selector(handleClickTestTap:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"悬浮窗调试", @"secondary_title": @"查看当前位置/方向/变换矩阵等", @"row_click_handler": NSStringFromSelector(@selector(handleDebugFloatWindowTap:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"屏幕坐标测试", @"secondary_title": @"旋转屏幕点四角，验证坐标系映射", @"row_click_handler": NSStringFromSelector(@selector(handleTapTestWindowTap:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"Python 依赖检测", @"secondary_title": @"检查 python3 是否存在、能否运行、模块路径", @"row_click_handler": NSStringFromSelector(@selector(handlePythonCheckTap:))}
        ],
        @[
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"检测更新", @"secondary_title": [NSString stringWithFormat:@"当前版本 v%@，点击检查是否有新版本", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @""], @"row_click_handler": NSStringFromSelector(@selector(handleUpdateCheckTap:))},
            @{@"type": @(SETTING_CELL_ENTRY), @"title": @"交流与免责声明", @"secondary_title": @"QQ 交流群 / bilibili / 开源声明 / 免责声明", @"row_click_handler": NSStringFromSelector(@selector(handleCommunityTap:))}
        ]
    ];
    [_tableView reloadData];
}

- (void)handleScriptFinishedPopupToggle:(UISwitch*)s {
    // Controls the "Script Finished" popup the tweak shows when a script ends.
    // Stored in the SpringBoard config so Play.xm can read it; defaults to on so
    // existing installs keep their current behaviour.
    [configManager updateKey:@"show_script_finished_popup" forValue:@([s isOn])];
    [configManager save];
}

- (NSString *)shortcutSummary {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *key in @[ZX_TRIGGER_VOLUME_UP, ZX_TRIGGER_VOLUME_DOWN]) {
        NSDictionary *trigger = ZXShortcutLoadTrigger(configManager, key);
        [parts addObject:[NSString stringWithFormat:@"%@：%@", ZXShortcutTriggerName(key),
                         [trigger[@"enabled"] boolValue] ? @"开" : @"关"]];
    }
    return [parts componentsJoinedByString:@"，"];
}

- (void)handleShortcutEntryTap:(id)cell {
    ZXShortcutSettingsViewController *vc = [[ZXShortcutSettingsViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
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

- (void)handleUpdateCheckTap:(TableViewCellWithEntry*)cell {
    ZXUpdateCheckViewController *vc = [[ZXUpdateCheckViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)handleCommunityTap:(TableViewCellWithEntry*)cell {
    ZXCommunityViewController *vc = [[ZXCommunityViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)handleClickTestTap:(TableViewCellWithEntry*)cell {
    ZXClickTestViewController *vc = [[ZXClickTestViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
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

static BOOL ZXExitZero(id value) {
    if ([value isKindOfClass:[NSNumber class]]) return [value integerValue] == 0;
    if ([value isKindOfClass:[NSString class]]) return [value isEqualToString:@"0"];
    return NO;
}

static NSString *ZXExitText(id value) {
    if (value == nil) return @"?";
    return [NSString stringWithFormat:@"%@", value];
}


- (void)handlePythonCheckTap:(TableViewCellWithEntry*)cell {
    ZXPythonCheckPanel *panel = [[ZXPythonCheckPanel alloc] init];
    [self presentViewController:panel animated:YES completion:nil];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        Socket *socket = [[Socket alloc] init];
        BOOL ok = ([socket connect:@"127.0.0.1" byPort:6000] == 0);
        if (ok) {
            [socket setTimeout:30];
            [socket send:@"45\r\n"];
        }
        NSString *raw = ok ? [socket recvUntilCRLF] : nil;
        if (ok) [socket close];

        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *appVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
            if (appVersion.length == 0) appVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"";

            // full：复制给用户的完整结果（含全部路径细节）
            NSMutableString *full = [NSMutableString string];
            // panelText：浮窗正文（只放能判断可用性的结论，不放长路径）
            NSMutableString *panelText = [NSMutableString string];
            NSString *verdictText = @"正在检测…";
            BOOL usable = NO;

            [full appendFormat:@"时间：%@\n", [NSDate date]];
            [full appendFormat:@"App：小新Lap v%@\n\n", appVersion.length ? appVersion : @"?"];

            if (!ok) {
                verdictText = @"❌ 检测失败：连不上 SpringBoard";
                [panelText setString:@"无法连接 SpringBoard 进程（Socket 失败）。\n请确认连点器已安装并已重启桌面。"];
                [full appendString:@"无法连接 SpringBoard 进程（Socket 失败）。"];
            } else if (raw.length == 0) {
                verdictText = @"❌ 检测失败：tweak 无返回";
                [panelText setString:@"未收到 tweak 返回结果。\n请确认连点器 tweak 已在 SpringBoard 中生效。"];
                [full appendString:@"未收到 tweak 返回结果。"];
            } else {
                NSString *jsonStr = raw;
                if ([jsonStr hasSuffix:@"\r\n"]) jsonStr = [jsonStr substringToIndex:jsonStr.length - 2];
                NSError *jerr = nil;
                NSData *data = [jsonStr dataUsingEncoding:NSUTF8StringEncoding];
                NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data] options:0 error:&jerr];

                if (jerr || ![dict isKindOfClass:[NSDictionary class]]) {
                    verdictText = @"❌ 检测失败：数据解析错误";
                    [panelText setString:[NSString stringWithFormat:@"返回数据解析失败：%@", jerr.localizedDescription ?: @"类型错误"]];
                    [full appendFormat:@"返回数据解析失败：%@\n\n原始数据：\n%@", jerr.localizedDescription ?: @"类型错误", raw];
                } else {
                    NSDictionary *dev = [dict[@"device_info"] isKindOfClass:[NSDictionary class]] ? dict[@"device_info"] : nil;
                    NSDictionary *bat = [dict[@"battery"] isKindOfClass:[NSDictionary class]] ? dict[@"battery"] : nil;
                    NSDictionary *jb  = [dict[@"jailbreak"] isKindOfClass:[NSDictionary class]] ? dict[@"jailbreak"] : nil;
                    NSDictionary *inst = [dict[@"install"] isKindOfClass:[NSDictionary class]] ? dict[@"install"] : nil;
                    NSDictionary *prA = [dict[@"spawn_probe_A_shell"] isKindOfClass:[NSDictionary class]] ? dict[@"spawn_probe_A_shell"] : nil;
                    NSDictionary *prB = [dict[@"spawn_probe_B_direct"] isKindOfClass:[NSDictionary class]] ? dict[@"spawn_probe_B_direct"] : nil;
                    NSDictionary *daemon = [dict[@"daemon_probe"] isKindOfClass:[NSDictionary class]] ? dict[@"daemon_probe"] : nil;

                    NSString *daemonExit = [daemon[@"python_spawn_exit"] isKindOfClass:[NSString class]] ? daemon[@"python_spawn_exit"] : @"";
                    BOOL springboardOK = ZXExitZero(prA[@"exit"]) || ZXExitZero(prB[@"exit"]);
                    BOOL daemonOK = [daemonExit isEqualToString:@"0"];
                    usable = springboardOK || daemonOK;
                    verdictText = usable ? @"✅ 本机可用连点器" : @"❌ 本机暂不可用连点器";

                    double ramGB = [dev[@"ram_bytes"] doubleValue] / 1073741824.0;
                    double batHealth = [bat[@"health_percent"] doubleValue];
                    double batCurrent = [bat[@"current_percent"] doubleValue];
                    NSArray *jbTools = [jb[@"tools"] isKindOfClass:[NSArray class]] ? jb[@"tools"] : @[];
                    NSArray *jbMarkers = [jb[@"bootstrap_markers"] isKindOfClass:[NSArray class]] ? jb[@"bootstrap_markers"] : @[];

                    // ---------- 浮窗正文 ----------
                    [panelText appendString:@"【设备】\n"];
                    [panelText appendFormat:@"机型：%@\n", dev[@"marketing"] ?: @"?"];
                    [panelText appendFormat:@"标识：%@\n", dev[@"machine"] ?: @"?"];
                    [panelText appendFormat:@"系统：iOS %@\n", dev[@"system"] ?: @"?"];
                    [panelText appendFormat:@"内存：%.1f GB（%@ 核）\n", ramGB, dev[@"cores"] ?: @"?"];
                    [panelText appendFormat:@"屏幕：%@ × %@ pt\n",
                     [NSString stringWithFormat:@"%.0f", [dev[@"screen_points_w"] doubleValue]],
                     [NSString stringWithFormat:@"%.0f", [dev[@"screen_points_h"] doubleValue]]];
                    if (inst[@"dylib_time"]) [panelText appendFormat:@"连点器安装：%@\n", inst[@"dylib_time"]];
                    if ([bat[@"available"] boolValue] || batCurrent >= 0) {
                        [panelText appendString:@"电池："];
                        if ([bat[@"available"] boolValue]) {
                            [panelText appendFormat:@"健康 %.0f%%、循环 %@ 次", batHealth, bat[@"cycle_count"] ?: @"?"];
                            if (batCurrent >= 0) [panelText appendFormat:@"、当前 %.0f%%", batCurrent];
                        } else if (batCurrent >= 0) {
                            [panelText appendFormat:@"当前 %.0f%%", batCurrent];
                        }
                        if ([bat[@"charging"] boolValue]) [panelText appendString:@"、充电中"];
                        [panelText appendString:@"\n"];
                    }

                    [panelText appendString:@"\n【越狱】\n"];
                    [panelText appendFormat:@"类型：%@\n", jb[@"type"] ?: @"?"];
                    if (jbTools.count > 0) [panelText appendFormat:@"越狱工具：%@\n", [jbTools componentsJoinedByString:@"、"]];
                    if (jbMarkers.count > 0) [panelText appendFormat:@"Bootstrap：%@\n", [jbMarkers componentsJoinedByString:@"、"]];

                    [panelText appendString:@"\n【运行环境】\n"];
                    [panelText appendFormat:@"SpringBoard 直跑 Python：%@\n", springboardOK ? @"✅ 可用" : @"❌ 不可用"];
                    [panelText appendFormat:@"守护进程 zxrunner：%@\n",
                     daemon ? ([daemon[@"socket_connect_ok"] boolValue] ? @"✅ 已连接" : @"❌ 未连接") : @"❌ 无数据"];
                    [panelText appendFormat:@"守护进程代跑 Python：%@\n",
                     daemonOK ? @"✅ 成功" : (daemonExit.length > 0 ? [NSString stringWithFormat:@"❌ exit=%@", daemonExit] : @"❌ 无结果")];

                    // ---------- 完整结果（剪贴板）----------
                    [full appendString:@"【结论】\n"];
                    [full appendFormat:@"  %@（SpringBoard 直跑=%@，守护进程代跑=%@）\n",
                     usable ? @"本机可用连点器" : @"本机暂不可用连点器",
                     springboardOK ? @"可用" : @"不可用",
                     daemonOK ? @"成功" : @"失败"];
                    [full appendString:@"\n【设备信息】\n"];
                    [full appendFormat:@"  机型：%@ （%@）\n", dev[@"marketing"] ?: @"?", dev[@"machine"] ?: @"?"];
                    [full appendFormat:@"  设备名：%@\n", dev[@"name"] ?: @"?"];
                    [full appendFormat:@"  系统：iOS %@  核心数：%@\n", dev[@"system"] ?: @"?", dev[@"cores"] ?: @"?"];
                    [full appendFormat:@"  内存：%.1f GB\n", ramGB];
                    [full appendFormat:@"  屏幕：%.0f × %.0f pt（%.0f × %.0f px，@%.0fx）\n",
                     [dev[@"screen_points_w"] doubleValue], [dev[@"screen_points_h"] doubleValue],
                     [dev[@"screen_pixels_w"] doubleValue], [dev[@"screen_pixels_h"] doubleValue],
                     [dev[@"screen_scale"] doubleValue]];
                    if (inst[@"dylib_time"]) [full appendFormat:@"  连点器安装（tweak）：%@\n", inst[@"dylib_time"]];
                    if (inst[@"dylib_path"]) [full appendFormat:@"  tweak 路径：%@\n", inst[@"dylib_path"]];
                    if (inst[@"app_time"]) [full appendFormat:@"  App 安装：%@\n", inst[@"app_time"]];
                    if (inst[@"app_path"]) [full appendFormat:@"  App 路径：%@\n", inst[@"app_path"]];

                    [full appendString:@"\n【电池】\n"];
                    if ([bat[@"available"] boolValue]) {
                        [full appendFormat:@"  健康度：%.1f%%（满容量 %@ / 设计容量 %@）\n",
                         batHealth, bat[@"max_capacity"] ?: @"?", bat[@"design_capacity"] ?: @"?"];
                        [full appendFormat:@"  循环次数：%@\n", bat[@"cycle_count"] ?: @"?"];
                    } else {
                        [full appendString:@"  无法读取循环次数 / 容量（IOKit 不可用）\n"];
                    }
                    [full appendFormat:@"  当前电量：%@%@\n",
                     batCurrent >= 0 ? [NSString stringWithFormat:@"%.0f%%", batCurrent] : @"未知",
                     [bat[@"charging"] boolValue] ? @"（充电中）" : @""];

                    [full appendString:@"\n【越狱】\n"];
                    [full appendFormat:@"  类型：%@\n", jb[@"type"] ?: @"?"];
                    [full appendFormat:@"  jbroot 前缀：%@\n", jb[@"jbroot_prefix"] ?: @""];
                    [full appendFormat:@"  /var/jb → %@\n", jb[@"varjb_target"] ?: @""];
                    if (jbMarkers.count > 0) [full appendFormat:@"  bootstrap 标记：%@\n", [jbMarkers componentsJoinedByString:@"、"]];
                    if (jbTools.count > 0) [full appendFormat:@"  越狱工具：%@\n", [jbTools componentsJoinedByString:@"、"]];

                    NSString *found = dict[@"found_path"] ?: @"";
                    [full appendString:@"\n【Python】\n"];
                    if (found.length > 0) {
                        [full appendFormat:@"  首选路径：%@\n", found];
                        NSString *ver = dict[@"version"];
                        if (ver.length > 0) [full appendFormat:@"  版本：%@\n", ver];
                    } else {
                        [full appendString:@"  全部候选不可用（access / posix_spawn 均 EPERM）\n"];
                    }

                    if (prA || prB) {
                        [full appendString:@"\n执行链路对比（SpringBoard 进程内）：\n"];
                        [full appendFormat:@"  A  shell间接  sh -c '<python> --version' → exit=%@\n     输出：%@\n", ZXExitText(prA[@"exit"]), [prA[@"output"] length] ? prA[@"output"] : @"(无)"];
                        [full appendFormat:@"  B  直接exec   posix_spawn(python)     → exit=%@\n     输出：%@\n", ZXExitText(prB[@"exit"]), [prB[@"output"] length] ? prB[@"output"] : @"(无)"];
                    }

                    NSString *jbPrefix = dict[@"jbroot_prefix"];
                    NSString *varjb = dict[@"varjb_target"];
                    NSString *tweakPath = dict[@"tweak_path"];
                    if (jbPrefix.length || varjb.length || tweakPath.length) {
                        [full appendString:@"\n越狱目录：\n"];
                        if (jbPrefix.length) [full appendFormat:@"  tweak 安装位置：%@\n", jbPrefix];
                        if (varjb.length) [full appendFormat:@"  /var/jb → %@\n", varjb];
                        if (tweakPath.length) [full appendFormat:@"  pccontrol.dylib：%@\n", tweakPath];
                    }

                    NSArray *cands = dict[@"candidates"];
                    NSArray *probes = [dict[@"probes"] isKindOfClass:[NSArray class]] ? dict[@"probes"] : @[];
                    if ([cands isKindOfClass:[NSArray class]]) {
                        [full appendString:@"\n候选路径：\n"];
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
                            [full appendFormat:@"%@\n", line];
                            for (NSDictionary *pr in probes) {
                                if ([pr isKindOfClass:[NSDictionary class]] && [pr[@"path"] isEqualToString:p]) {
                                    NSString *out = pr[@"output"];
                                    [full appendFormat:@"      试跑 exit=%@ 输出：%@\n", ZXExitText(pr[@"exit"]), out.length ? out : @"(无输出)"];
                                    break;
                                }
                            }
                        }
                    }

                    NSDictionary *dq = dict[@"dpkg_query"];
                    if ([dq isKindOfClass:[NSDictionary class]] && dq.count > 0) {
                        [full appendString:@"\ndpkg python3 包记录：\n"];
                        for (NSString *k in dq) {
                            NSString *out = dq[k];
                            [full appendFormat:@"  [%@]\n    %@\n", k, out.length ? out : @"(无)"];
                        }
                    }

                    NSArray *scope = [dict[@"sandbox_scope_probe"] isKindOfClass:[NSArray class]] ? dict[@"sandbox_scope_probe"] : nil;
                    if (scope.count > 0) {
                        [full appendString:@"\nSpringBoard 沙盒 exec 范围：\n"];
                        for (NSDictionary *s in scope) {
                            if (![s isKindOfClass:[NSDictionary class]]) continue;
                            NSString *sp = s[@"path"] ?: @"";
                            BOOL ex2 = [s[@"exists"] boolValue];
                            BOOL acc2 = [s[@"access_X_OK"] boolValue];
                            NSString *spawn = s[@"posix_spawn"] ?: @"";
                            if (!ex2) {
                                [full appendFormat:@"  ❌ %@  不存在\n", sp];
                            } else if (acc2) {
                                [full appendFormat:@"  ✅ %@  access=0  %@\n", sp, spawn];
                            } else {
                                NSNumber *en2 = s[@"access_errno"];
                                [full appendFormat:@"  ❌ %@  access=EPERM errno=%@  %@\n", sp, en2 ?: @0, spawn];
                            }
                        }
                    }

                    NSArray *mods = dict[@"module_paths_found"];
                    if (mods.count > 0) {
                        [full appendString:@"\nzxtouch 模块路径：\n"];
                        for (NSString *m in mods) [full appendFormat:@"  %@\n", m];
                    }

                    NSDictionary *imp = dict[@"module_import"];
                    if ([imp isKindOfClass:[NSDictionary class]]) {
                        [full appendFormat:@"\nzxtouch import 实测：exit=%@\n  输出：%@\n",
                         ZXExitText(imp[@"exit"]), [imp[@"output"] length] ? imp[@"output"] : @"(无)"];
                    }

                    if (daemon) {
                        [full appendString:@"\n守护进程 zxrunner：\n"];
                        [full appendFormat:@"  plist  %@  %@\n",
                         daemon[@"plist_path"] ?: @"?",
                         [daemon[@"plist_exists"] boolValue] ? @"存在" : @"不存在"];
                        [full appendFormat:@"  二进制  %@  exists=%@  access(X_OK)=%@%@\n",
                         daemon[@"bin_path"] ?: @"?",
                         [daemon[@"bin_exists"] boolValue] ? @"Y" : @"N",
                         [daemon[@"bin_access_X_OK"] boolValue] ? @"Y" : @"N",
                         [daemon[@"bin_exists"] boolValue] && ![daemon[@"bin_access_X_OK"] boolValue]
                            ? [NSString stringWithFormat:@" errno=%@", daemon[@"bin_access_errno"]]
                            : @""];
                        BOOL sExists = [daemon[@"socket_exists"] boolValue];
                        BOOL sConn = [daemon[@"socket_connect_ok"] boolValue];
                        NSString *sReply = daemon[@"socket_ping_reply"];
                        [full appendFormat:@"  socket  %@  存在=%@  连接=%@%@\n",
                         daemon[@"socket_path"] ?: @"?",
                         sExists ? @"Y" : @"N",
                         sConn ? @"Y" : @"N",
                         sConn ? @"" : [NSString stringWithFormat:@" errno=%@(%@)",
                                        daemon[@"socket_connect_errno"] ?: @0,
                                        ZXPythonErrnoName([daemon[@"socket_connect_errno"] intValue])]];
                        if (sConn) {
                            [full appendFormat:@"  真实握手  %@  ping 回复：%@\n",
                             sReply.length > 0 ? @"✅ 通了" : @"⚠️ 已连上但无回复",
                             sReply.length > 0 ? sReply : @"(空)"];
                        } else {
                            [full appendString:@"  真实握手  ❌ 不通\n"];
                        }
                        NSString *dpErr = daemon[@"python_spawn_error"];
                        if (daemonExit.length > 0) {
                            NSString *dpOut = daemon[@"python_spawn_output"];
                            [full appendFormat:@"  守护进程代跑  %@ --version → exit=%@\n     输出：%@\n",
                             daemon[@"python_spawn_path"] ?: @"?", daemonExit,
                             [dpOut length] ? dpOut : @"(无输出)"];
                        } else if ([dpErr isKindOfClass:[NSString class]] && dpErr.length > 0) {
                            [full appendFormat:@"  守护进程代跑 python  ❌ %@\n", dpErr];
                        }
                        [full appendString:[daemon[@"probe_exists"] boolValue]
                            ? @"  launchd probe  已生成\n"
                            : @"  launchd probe  未生成\n"];
                    }
                }
            }

            [full appendString:@"\n（完整检测数据已复制到剪贴板，可再点「复制完整结果」重试）"];
            [panelText appendString:@"\n完整数据（含全部路径）已复制到剪贴板。"];

            panel.fullReport = full;
            [panel setVerdict:verdictText usable:usable];
            [panel setBodyText:panelText];
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
    return 28;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return 6;
}

@end

#pragma mark - 检测更新 / 交流与免责声明（公共卡片页）

static NSString * const kZXQQGroup     = @"558715113";
static NSString * const kZXBilibiliURL = @"https://space.bilibili.com/1036605484";

static NSString *ZXAboutDisclaimerText(void) {
    return @"本软件（小新Lap）全功能免费，禁止倒卖、转售或二次打包收费；"
            "仅可用于学习交流与自动化测试，禁止用于任何违法违规用途，"
            "请勿在游戏、金融等对公平性或安全性有要求的场景中违规使用。"
            "使用本软件产生的一切后果由使用者自行承担，开发者不承担任何责任。"
            "请自觉遵守当地法律法规，如不同意本声明请立即停止使用并卸载本软件。";
}

static NSString *ZXAboutNoticeText(void) {
    return @"本软件（小新Lap）基于开源项目 ZXTouch 二次修改，仅供学习与交流使用，"
            "代码与功能均已按需调整，此处仅声明来源。";
}

static NSArray<NSString *> *ZXLatestVersionURLs(void) {
    return @[ @"https://api.github.com/repos/xiaoxing12138/zxtouch-rootless/releases/latest",
              @"https://cdn.jsdelivr.net/gh/xiaoxing12138/zxtouch-rootless@main/version.json",
              @"https://raw.githubusercontent.com/xiaoxing12138/zxtouch-rootless/main/version.json" ];
}

static NSString *ZXCleanVersion(NSString *raw) {
    NSMutableString *result = [NSMutableString string];
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if ((c >= '0' && c <= '9') || c == '.') [result appendFormat:@"%C", c];
    }
    return result;
}

static BOOL ZXVersionIsNewer(NSString *remote, NSString *current) {
    NSString *a = ZXCleanVersion(remote);
    NSString *b = ZXCleanVersion(current);
    if (a.length == 0) return NO;
    NSArray<NSString *> *left = [a componentsSeparatedByString:@"."];
    NSArray<NSString *> *right = [b componentsSeparatedByString:@"."];
    NSUInteger count = MAX(left.count, right.count);
    for (NSUInteger i = 0; i < count; i++) {
        NSInteger x = i < left.count ? left[i].integerValue : 0;
        NSInteger y = i < right.count ? right[i].integerValue : 0;
        if (x != y) return x > y;
    }
    return NO;
}

static void ZXFetchVersionFromURLs(NSArray<NSString *> *urls, NSUInteger index,
                                   void (^completion)(NSString *version, NSError *error)) {
    if (index >= urls.count) {
        completion(nil, [NSError errorWithDomain:@"小新Lap" code:1
                                        userInfo:@{ NSLocalizedDescriptionKey: @"网络请求失败" }]);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urls[index]]];
    request.timeoutInterval = 10;
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [request setValue:@"xiaoxinlap" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *version = nil;
        if (data.length > 0) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            if ([json isKindOfClass:[NSDictionary class]]) {
                id value = json[@"version"];
                if ([value isKindOfClass:[NSString class]]) version = value;
                else if ([value isKindOfClass:[NSNumber class]]) version = [value stringValue];
                if (version.length == 0) {
                    id tag = json[@"tag_name"];
                    if ([tag isKindOfClass:[NSString class]]) {
                        version = tag;
                        if ([version hasPrefix:@"v"] || [version hasPrefix:@"V"]) {
                            version = [version substringFromIndex:1];
                        }
                    }
                }
            }
            if (version.length == 0) {
                NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (text.length > 0 && text.length < 32) version = text;
            }
        }
        if (version.length > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(version, nil); });
        } else {
            ZXFetchVersionFromURLs(urls, index + 1, completion);
        }
    }] resume];
}

static void ZXFetchLatestVersion(BOOL useCache, void (^completion)(NSString *version, NSError *error)) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (useCache) {
        NSString *cached = [defaults stringForKey:@"ZXLatestVersion"];
        NSDate *checkedAt = [defaults objectForKey:@"ZXLatestVersionCheckedAt"];
        if (cached.length > 0 && [checkedAt isKindOfClass:[NSDate class]] && -[checkedAt timeIntervalSinceNow] < 6 * 3600) {
            completion(cached, nil);
            return;
        }
    }
    ZXFetchVersionFromURLs(ZXLatestVersionURLs(), 0, ^(NSString *version, NSError *error) {
        if (version.length > 0) {
            NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
            [d setObject:version forKey:@"ZXLatestVersion"];
            [d setObject:[NSDate date] forKey:@"ZXLatestVersionCheckedAt"];
            [d synchronize];
        }
        completion(version, error);
    });
}

@implementation ZXInfoPageViewController

- (UIView *)cardAt:(CGFloat)y width:(CGFloat)w margin:(CGFloat)margin inScroll:(UIScrollView *)scroll {
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(margin, y, w, 10)];
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 12;
    [scroll addSubview:card];
    return card;
}

- (void)finishCard:(UIView *)card y:(CGFloat *)y height:(CGFloat)height margin:(CGFloat)margin width:(CGFloat)w {
    card.frame = CGRectMake(margin, *y, w, height);
    *y += height + 12.0f;
}

- (UILabel *)addText:(NSString *)text font:(UIFont *)font color:(UIColor *)color
                card:(UIView *)card y:(CGFloat *)y width:(CGFloat)w wrap:(BOOL)wrap {
    CGFloat height = 22.0f;
    if (wrap) {
        CGRect rect = [text boundingRectWithSize:CGSizeMake(w - 28, CGFLOAT_MAX)
                                         options:NSStringDrawingUsesLineFragmentOrigin
                                      attributes:@{ NSFontAttributeName: font } context:nil];
        height = ceil(rect.size.height) + 2.0f;
    }
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(14, *y, w - 28, height)];
    label.text = text;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = wrap ? 0 : 1;
    label.adjustsFontSizeToFitWidth = !wrap;
    label.minimumScaleFactor = 0.75;
    [card addSubview:label];
    *y += height + 4.0f;
    return label;
}

- (CGFloat)addLink:(NSString *)title card:(UIView *)card y:(CGFloat)y width:(CGFloat)w action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(14, y, w - 28, 32);
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:14];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:button];
    return 36.0f;
}

- (void)copyQQGroup {
    [UIPasteboard generalPasteboard].string = kZXQQGroup;
    [Util showAlertBoxWithOneOption:self title:@"QQ 交流群"
        message:[NSString stringWithFormat:@"群号 %@ 已复制到剪贴板。", kZXQQGroup]
        buttonString:@"确定"];
}

- (void)openBilibili {
    NSURL *url = [NSURL URLWithString:kZXBilibiliURL];
    if (!url) return;
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)showUpdateHint {
    [UIPasteboard generalPasteboard].string = kZXQQGroup;
    [Util showAlertBoxWithOneOption:self title:@"有新版本"
        message:[NSString stringWithFormat:@"请加入 QQ 交流群 %@ 获取最新版本文件。\n\n（群号已复制到剪贴板）", kZXQQGroup]
        buttonString:@"确定"];
}

@end

#pragma mark - 检测更新

@implementation ZXUpdateCheckViewController {
    UILabel  *_latestLabel;
    UIButton *_checkButton;
    UIButton *_updateButton;
    NSString *_currentVersion;
}

- (void)handleCheckUpdateTap:(UIButton *)sender {
    (void)sender;
    [self checkForUpdate];
}

- (void)checkForUpdate {
    _latestLabel.textColor = [UIColor secondaryLabelColor];
    _latestLabel.text = @"最新版本：检测中…";
    _updateButton.hidden = YES;

    __weak typeof(self) weakSelf = self;
    ZXFetchLatestVersion(NO, ^(NSString *version, NSError *error) {
        ZXUpdateCheckViewController *s = weakSelf;
        if (!s) return;
        if (version.length == 0) {
            s->_latestLabel.text = @"最新版本：获取失败（请检查网络后重试）";
            return;
        }
        if (ZXVersionIsNewer(version, s->_currentVersion)) {
            s->_latestLabel.text = [NSString stringWithFormat:@"最新版本：v%@", version];
            s->_latestLabel.textColor = [UIColor systemRedColor];
            s->_updateButton.hidden = NO;
        } else {
            s->_latestLabel.text = [NSString stringWithFormat:@"最新版本：v%@（已是最新）", version];
        }
    });
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"检测更新";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];

    _currentVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";

    CGFloat margin = 16.0f;
    CGFloat w = self.view.bounds.size.width - margin * 2;
    CGFloat y = 16.0f;
    CGFloat cy = 0.0f;

    UIView *versionCard = [self cardAt:y width:w margin:margin inScroll:scroll];
    cy = 14.0f;
    [self addText:@"小新Lap" font:[UIFont systemFontOfSize:20 weight:UIFontWeightBold]
            color:[UIColor labelColor] card:versionCard y:&cy width:w wrap:NO];
    [self addText:[NSString stringWithFormat:@"当前版本：v%@", _currentVersion]
             font:[UIFont systemFontOfSize:14] color:[UIColor secondaryLabelColor]
             card:versionCard y:&cy width:w wrap:NO];

    // 版本行：左侧「最新版本：…」，右侧常显的「检测更新」按钮
    CGFloat versionRowH = 30.0f;
    UIView *versionRow = [[UIView alloc] initWithFrame:CGRectMake(14, cy, w - 28, versionRowH)];
    _latestLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, MAX(versionRow.frame.size.width - 88.0f, 60.0f), versionRowH)];
    _latestLabel.text = @"最新版本：检测中…";
    _latestLabel.font = [UIFont systemFontOfSize:14];
    _latestLabel.textColor = [UIColor secondaryLabelColor];
    _latestLabel.adjustsFontSizeToFitWidth = YES;
    _latestLabel.minimumScaleFactor = 0.7;
    [versionRow addSubview:_latestLabel];

    _checkButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _checkButton.frame = CGRectMake(versionRow.frame.size.width - 84.0f, (versionRowH - 28.0f) / 2.0f, 84.0f, 28.0f);
    _checkButton.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.12];
    _checkButton.layer.cornerRadius = 8;
    _checkButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [_checkButton setTitle:@"检测更新" forState:UIControlStateNormal];
    [_checkButton addTarget:self action:@selector(handleCheckUpdateTap:) forControlEvents:UIControlEventTouchUpInside];
    [versionRow addSubview:_checkButton];
    [versionCard addSubview:versionRow];
    cy += versionRowH + 4.0f;

    [self addText:@"如有新版本，请加入 QQ 交流群获取最新版本文件。"
             font:[UIFont systemFontOfSize:13] color:[UIColor secondaryLabelColor]
             card:versionCard y:&cy width:w wrap:YES];
    cy += 2;
    _updateButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _updateButton.frame = CGRectMake(14, cy, w - 28, 34);
    _updateButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [_updateButton setTitle:@"有新版本，点击查看获取方式" forState:UIControlStateNormal];
    _updateButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [_updateButton addTarget:self action:@selector(showUpdateHint) forControlEvents:UIControlEventTouchUpInside];
    _updateButton.hidden = YES;
    [versionCard addSubview:_updateButton];
    cy += 38;
    [self finishCard:versionCard y:&y height:cy + 6 margin:margin width:w];

    UIView *contactCard = [self cardAt:y width:w margin:margin inScroll:scroll];
    cy = 14.0f;
    [self addText:@"交流" font:[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]
            color:[UIColor labelColor] card:contactCard y:&cy width:w wrap:NO];
    cy += [self addLink:[NSString stringWithFormat:@"QQ 交流群：%@（点击复制群号）", kZXQQGroup]
                   card:contactCard y:cy width:w action:@selector(copyQQGroup)];
    cy += [self addLink:@"bilibili：小新Lap（点击打开主页）" card:contactCard y:cy width:w
                 action:@selector(openBilibili)];
    [self finishCard:contactCard y:&y height:cy + 6 margin:margin width:w];

    scroll.contentSize = CGSizeMake(w + margin * 2, y + 20);

    [self checkForUpdate];
}

@end

#pragma mark - 交流与免责声明

@implementation ZXCommunityViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"交流与免责声明";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];

    CGFloat margin = 16.0f;
    CGFloat w = self.view.bounds.size.width - margin * 2;
    CGFloat y = 16.0f;
    CGFloat cy = 0.0f;

    UIView *contactCard = [self cardAt:y width:w margin:margin inScroll:scroll];
    cy = 14.0f;
    [self addText:@"交流" font:[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]
            color:[UIColor labelColor] card:contactCard y:&cy width:w wrap:NO];
    cy += [self addLink:[NSString stringWithFormat:@"QQ 交流群：%@（点击复制群号）", kZXQQGroup]
                   card:contactCard y:cy width:w action:@selector(copyQQGroup)];
    cy += [self addLink:@"bilibili：小新Lap（点击打开主页）" card:contactCard y:cy width:w
                 action:@selector(openBilibili)];
    [self finishCard:contactCard y:&y height:cy + 6 margin:margin width:w];

    UIView *noticeCard = [self cardAt:y width:w margin:margin inScroll:scroll];
    cy = 14.0f;
    [self addText:@"开源声明" font:[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]
            color:[UIColor labelColor] card:noticeCard y:&cy width:w wrap:NO];
    [self addText:ZXAboutNoticeText() font:[UIFont systemFontOfSize:13]
            color:[UIColor secondaryLabelColor] card:noticeCard y:&cy width:w wrap:YES];
    [self finishCard:noticeCard y:&y height:cy + 8 margin:margin width:w];

    UIView *disclaimerCard = [self cardAt:y width:w margin:margin inScroll:scroll];
    cy = 14.0f;
    [self addText:@"免责声明" font:[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]
            color:[UIColor labelColor] card:disclaimerCard y:&cy width:w wrap:NO];
    [self addText:ZXAboutDisclaimerText() font:[UIFont systemFontOfSize:13]
            color:[UIColor secondaryLabelColor] card:disclaimerCard y:&cy width:w wrap:YES];
    [self finishCard:disclaimerCard y:&y height:cy + 8 margin:margin width:w];

    scroll.contentSize = CGSizeMake(w + margin * 2, y + 20);
}

@end

#pragma mark - 点击测试

@interface ZXInkMark : NSObject
@property (nonatomic) BOOL isDot;
@property (nonatomic, strong) NSMutableArray<NSValue *> *points;
@property (nonatomic) CFTimeInterval born;
@end

@implementation ZXInkMark
@end

static const CFTimeInterval kZXInkHold    = 1.0;
static const CFTimeInterval kZXInkErase   = 0.6;
static const CFTimeInterval kZXInkFreqWin = 3.0;

@interface ZXInkView : UIView
@property (nonatomic, readonly) NSInteger tapCount;
@property (nonatomic, readonly) CGPoint lastPoint;
@property (nonatomic, readonly) NSInteger recentTaps;
@property (nonatomic, readonly) NSInteger ratePerMinute;
@property (nonatomic, copy) void (^statusDidChange)(void);
@end

@implementation ZXInkView {
    NSMutableArray<ZXInkMark *> *_marks;
    ZXInkMark *_activeMark;
    NSMutableArray<NSNumber *> *_tapTimes;
    CADisplayLink *_link;
    NSInteger _tapCount;
    CGPoint _lastPoint;
    NSInteger _recentTaps;
    NSInteger _ratePerMinute;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _marks = [NSMutableArray array];
        _tapTimes = [NSMutableArray array];
        self.backgroundColor = [UIColor systemBackgroundColor];
        self.multipleTouchEnabled = NO;
        _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
        [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)dealloc {
    [_link invalidate];
}

- (NSInteger)tapCount { return _tapCount; }
- (CGPoint)lastPoint { return _lastPoint; }
- (NSInteger)recentTaps { return _recentTaps; }
- (NSInteger)ratePerMinute { return _ratePerMinute; }

- (void)tick {
    CFTimeInterval now = CACurrentMediaTime();
    while (_tapTimes.count > 0 && now - _tapTimes.firstObject.doubleValue > kZXInkFreqWin) {
        [_tapTimes removeObjectAtIndex:0];
    }
    NSInteger recent = (NSInteger)_tapTimes.count;
    NSInteger rate = (NSInteger)llround(recent / kZXInkFreqWin * 60.0);
    BOOL dirty = NO;
    if (recent != _recentTaps || rate != _ratePerMinute) {
        _recentTaps = recent;
        _ratePerMinute = rate;
        dirty = YES;
    }

    CFTimeInterval life = kZXInkHold + kZXInkErase;
    BOOL hadMarks = _marks.count > 0;
    NSMutableArray *keep = [NSMutableArray arrayWithCapacity:_marks.count];
    for (ZXInkMark *m in _marks) {
        if (m == _activeMark) { [keep addObject:m]; continue; }
        if (now - m.born >= life) { dirty = YES; continue; }
        [keep addObject:m];
    }
    _marks = keep;

    if (hadMarks || _marks.count > 0) [self setNeedsDisplay];
    if (dirty && self.statusDidChange) self.statusDidChange();
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = touches.anyObject;
    CGPoint p = [t locationInView:self];
    _tapCount += 1;
    _lastPoint = p;
    [_tapTimes addObject:@(CACurrentMediaTime())];

    ZXInkMark *mark = [ZXInkMark new];
    mark.isDot = YES;
    mark.born = 0.0;
    mark.points = [NSMutableArray arrayWithObject:[NSValue valueWithCGPoint:p]];
    [_marks addObject:mark];
    _activeMark = mark;

    [self setNeedsDisplay];
    if (self.statusDidChange) self.statusDidChange();
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_activeMark) return;
    UITouch *t = touches.anyObject;
    CGPoint p = [t locationInView:self];
    _activeMark.isDot = NO;
    [_activeMark.points addObject:[NSValue valueWithCGPoint:p]];
    _lastPoint = p;
    [self setNeedsDisplay];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_activeMark) _activeMark.born = CACurrentMediaTime();
    _activeMark = nil;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_activeMark) _activeMark.born = CACurrentMediaTime();
    _activeMark = nil;
}

- (void)drawMark:(ZXInkMark *)mark inContext:(CGContextRef)ctx fromIndex:(NSUInteger)start alpha:(CGFloat)alpha {
    UIColor *color = [[UIColor systemBlueColor] colorWithAlphaComponent:alpha];
    CGContextSetStrokeColorWithColor(ctx, color.CGColor);
    CGContextSetFillColorWithColor(ctx, color.CGColor);
    CGContextSetLineWidth(ctx, 4.0);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);

    NSArray<NSValue *> *pts = mark.points;
    if (mark.isDot || pts.count <= 1) {
        CGPoint p = pts.lastObject.CGPointValue;
        CGContextFillEllipseInRect(ctx, CGRectMake(p.x - 6.0, p.y - 6.0, 12.0, 12.0));
        return;
    }
    if (start >= pts.count) return;
    if (start == pts.count - 1) {
        CGPoint p = pts.lastObject.CGPointValue;
        CGContextFillEllipseInRect(ctx, CGRectMake(p.x - 3.0, p.y - 3.0, 6.0, 6.0));
        return;
    }
    CGMutablePathRef path = CGPathCreateMutable();
    CGPoint first = pts[start].CGPointValue;
    CGPathMoveToPoint(path, NULL, first.x, first.y);
    for (NSUInteger i = start + 1; i < pts.count; i++) {
        CGPoint p = pts[i].CGPointValue;
        CGPathAddLineToPoint(path, NULL, p.x, p.y);
    }
    CGContextAddPath(ctx, path);
    CGContextStrokePath(ctx);
    CGPathRelease(path);
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CFTimeInterval now = CACurrentMediaTime();
    for (ZXInkMark *m in _marks) {
        if (m.born <= 0.0) {
            [self drawMark:m inContext:ctx fromIndex:0 alpha:1.0];
            continue;
        }
        CFTimeInterval age = now - m.born;
        if (age < kZXInkHold) {
            [self drawMark:m inContext:ctx fromIndex:0 alpha:1.0];
        } else {
            CGFloat p = (CGFloat)((age - kZXInkHold) / kZXInkErase);
            if (p >= 1.0) continue;
            NSUInteger n = m.points.count;
            if (m.isDot || n <= 1) {
                [self drawMark:m inContext:ctx fromIndex:0 alpha:(CGFloat)(1.0 - p)];
            } else {
                NSUInteger start = (NSUInteger)(p * (CGFloat)n);
                if (start >= n - 1) {
                    [self drawMark:m inContext:ctx fromIndex:n - 1 alpha:(CGFloat)(1.0 - p)];
                } else {
                    [self drawMark:m inContext:ctx fromIndex:start alpha:1.0];
                }
            }
        }
    }
}

@end

@implementation ZXClickTestViewController {
    ZXInkView *_ink;
    UIView *_hud;
    UILabel *_countLabel;
    UILabel *_coordLabel;
    UILabel *_freqLabel;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"点击测试";

    _ink = [[ZXInkView alloc] initWithFrame:self.view.bounds];
    _ink.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_ink];

    _hud = [[UIView alloc] initWithFrame:self.view.bounds];
    _hud.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _hud.userInteractionEnabled = NO;
    _hud.backgroundColor = [UIColor clearColor];
    [self.view addSubview:_hud];

    _countLabel = [[UILabel alloc] init];
    _countLabel.font = [UIFont monospacedDigitSystemFontOfSize:72 weight:UIFontWeightBold];
    _countLabel.textColor = [UIColor labelColor];
    _countLabel.textAlignment = NSTextAlignmentCenter;
    _countLabel.text = @"0";
    [_hud addSubview:_countLabel];

    _coordLabel = [[UILabel alloc] init];
    _coordLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    _coordLabel.textColor = [UIColor secondaryLabelColor];
    _coordLabel.textAlignment = NSTextAlignmentCenter;
    _coordLabel.text = @"当前坐标：(—, —)";
    [_hud addSubview:_coordLabel];

    _freqLabel = [[UILabel alloc] init];
    _freqLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    _freqLabel.textColor = [UIColor secondaryLabelColor];
    _freqLabel.textAlignment = NSTextAlignmentCenter;
    _freqLabel.text = @"最近 3 秒：0 次　预计每分钟：0 次";
    [_hud addSubview:_freqLabel];

    __weak typeof(self) weakSelf = self;
    _ink.statusDidChange = ^{
        ZXClickTestViewController *s = weakSelf;
        if (!s) return;
        [s refresh];
    };
    [self refresh];
}

- (void)refresh {
    _countLabel.text = [NSString stringWithFormat:@"%ld", (long)_ink.tapCount];
    _coordLabel.text = [NSString stringWithFormat:@"当前坐标：(%.0f, %.0f)",
                        _ink.lastPoint.x, _ink.lastPoint.y];
    _freqLabel.text = [NSString stringWithFormat:@"最近 3 秒：%ld 次　预计每分钟：%ld 次",
                       (long)_ink.recentTaps, (long)_ink.ratePerMinute];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    CGFloat top = self.view.safeAreaInsets.top + 20.0;
    _countLabel.frame = CGRectMake(0, top, w, 84.0);
    _coordLabel.frame = CGRectMake(0, CGRectGetMaxY(_countLabel.frame) + 4.0, w, 18.0);
    _freqLabel.frame = CGRectMake(0, CGRectGetMaxY(_coordLabel.frame) + 2.0, w, 18.0);
}

@end
