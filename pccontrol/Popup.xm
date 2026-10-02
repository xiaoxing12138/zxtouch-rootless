#import "Popup.h"
#include <roothide.h>
#import "Screen.h"
#import "Record.h"
#include "Play.h"
#include "AlertBox.h"
#include "Toast.h"
#include "Common.h"
#include "Config.h"
#import "ScriptFunctions.h"
#import "FunctionWindow.h"
#import <UIKit/UIKit.h>

#define BTN_H 40
#define SETTINGS_KEY_REPEAT  @"repeat_times"
#define SETTINGS_KEY_SPEED   @"speed"
#define SETTINGS_KEY_INTERVAL @"interval"
#define SETTINGS_KEY_ENABLED @"settings_enabled"

static UIButton* makeBtn(NSString *title, UIColor *color) {
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

static UIImage *panelSymbol(NSString *name) {
    if (@available(iOS 13.0, *)) {
        return [UIImage systemImageNamed:name];
    }
    return nil;
}

static void styleIconButton(UIButton *button, NSString *symbolName, UIColor *color) {
    UIImage *image = panelSymbol(symbolName);
    if (image) {
        [button setImage:image forState:UIControlStateNormal];
        button.tintColor = color;
    }
    button.backgroundColor = [UIColor secondarySystemBackgroundColor];
    button.layer.cornerRadius = 8;
}

@implementation PopupWindow
{
    UIWindow       *_window;
    UIScrollView   *_scriptScrollView;
    UIButton       *_gearBtn;
    int             _repeatCount;
    float           _speed;
    float           _interval;
    BOOL            _settingsVisible;  // whether to show settings dialog before playing
    BOOL            isShown;
}

- (id) init {
    self = [super init];
    if (self) {
        _repeatCount = 0;
        _speed = 1.0f;
        _interval = 0.0f;
        _settingsVisible = NO;
        isShown = NO;
        [self buildWindow];
    }
    return self;
}

- (void) buildWindow {
    ZXSafeMainAsync(^{
        CGRect sb = [UIScreen mainScreen].bounds;
        CGFloat shortSide = MIN(sb.size.width, sb.size.height);
        CGFloat longSide  = MAX(sb.size.width, sb.size.height);
        CGFloat pw = shortSide * 0.65f;
        pw = MAX(pw, 220); pw = MIN(pw, 320);
        CGFloat ph = longSide * 0.55f;
        ph = MAX(ph, 280); ph = MIN(ph, 420);
        CGFloat cx = CGRectGetMidX(sb) - pw/2;
        CGFloat cy = CGRectGetMidY(sb) - ph/2;

        UIWindowScene *scene = (UIWindowScene *)[[UIApplication sharedApplication].connectedScenes anyObject];
        if (scene) {
            _window = [[UIWindow alloc] initWithWindowScene:scene];
            _window.frame = CGRectMake(cx, cy, pw, ph);
        } else {
            _window = [[UIWindow alloc] initWithFrame:CGRectMake(cx, cy, pw, ph)];
        }
        _window.windowLevel = UIWindowLevelAlert + 1;
        _window.autoresizingMask = UIViewAutoresizingNone; // prevent auto-stretch on rotation

        UIViewController *rvc = [[UIViewController alloc] init];
        rvc.view.backgroundColor = [UIColor systemBackgroundColor];
        rvc.view.layer.cornerRadius = 14;
        rvc.view.layer.borderColor = [UIColor separatorColor].CGColor;
        rvc.view.layer.borderWidth = 1;
        rvc.view.clipsToBounds = YES;
        _window.rootViewController = rvc;
        UIView *cv = rvc.view;

        // Header
        UILabel *ttl = [[UILabel alloc] initWithFrame:CGRectMake(12,8,pw-176,30)];
        ttl.text = @"小新Lap 控制面板"; ttl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        ttl.textColor = [UIColor labelColor]; [cv addSubview:ttl];

        // 功能勾选页入口：关闭本面板，改为弹出独立的功能页窗口
        UIButton *funcBtn = makeBtn(@"功能", [UIColor systemBlueColor]);
        funcBtn.frame = CGRectMake(pw-126, 8, 44, 32);
        [funcBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
            [self hide];
            [[FunctionWindow shared] show];
        }] forControlEvents:UIControlEventTouchUpInside];
        [cv addSubview:funcBtn];

        // ⚙️ toggle — tap to enable/disable "ask settings before play"
        _gearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        [_gearBtn setTitle:@"⚙️" forState:UIControlStateNormal];
        _gearBtn.frame = CGRectMake(pw-80, 6, 36, 36);
        [_gearBtn setTitle:@"" forState:UIControlStateNormal];
        styleIconButton(_gearBtn, @"slider.horizontal.3", [UIColor systemBlueColor]);
        [_gearBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
            _settingsVisible = !_settingsVisible;
            [self updateSettingsButtonAppearance];
            [self saveSettings:_repeatCount speed:_speed interval:_interval enabled:_settingsVisible];
        }] forControlEvents:UIControlEventTouchUpInside];
        [cv addSubview:_gearBtn];

        // Close button
        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
        closeBtn.frame = CGRectMake(pw-42, 6, 36, 36);
        [closeBtn setTitle:@"" forState:UIControlStateNormal];
        styleIconButton(closeBtn, @"xmark", [UIColor secondaryLabelColor]);
        [closeBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
            [self hide];
        }] forControlEvents:UIControlEventTouchUpInside];
        [cv addSubview:closeBtn];

        [cv addSubview:[self makeSepAt:CGRectMake(0,46,pw,1)]];

        // REC / STOP buttons
        CGFloat btnW = (pw - 24) / 2;
        UIButton *recBtn = makeBtn(@"录制", [UIColor systemRedColor]);
        recBtn.frame = CGRectMake(8, 54, btnW, BTN_H);
        [recBtn setTitle:@"录制" forState:UIControlStateNormal];
        [recBtn setImage:panelSymbol(@"record.circle.fill") forState:UIControlStateNormal];
        recBtn.tintColor = [UIColor systemRedColor];
        recBtn.backgroundColor = [UIColor.systemRedColor colorWithAlphaComponent:0.12];
        [recBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
            [self recordingStart];
        }] forControlEvents:UIControlEventTouchUpInside];
        [cv addSubview:recBtn];

        UIButton *stopBtn = makeBtn(@"停止", [UIColor secondaryLabelColor]);
        stopBtn.frame = CGRectMake(pw/2+4, 54, btnW, BTN_H);
        [stopBtn setImage:panelSymbol(@"stop.fill") forState:UIControlStateNormal];
        stopBtn.tintColor = [UIColor secondaryLabelColor];
        [stopBtn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
            [self stopAction];
        }] forControlEvents:UIControlEventTouchUpInside];
        [cv addSubview:stopBtn];

        [cv addSubview:[self makeSepAt:CGRectMake(0, 54+BTN_H+8, pw, 1)]];

        // Scripts label — shows hint when settings mode on
        UILabel *sl = [[UILabel alloc] initWithFrame:CGRectMake(12, 54+BTN_H+14, pw-20, 18)];
        sl.text = @"脚本"; sl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        sl.textColor = [UIColor secondaryLabelColor]; [cv addSubview:sl];

        // Script scroll view
        CGFloat scrollTop = 54+BTN_H+36;
        _scriptScrollView = [[UIScrollView alloc] initWithFrame:CGRectMake(0,scrollTop,pw,ph-scrollTop-8)];
        _scriptScrollView.backgroundColor = [UIColor clearColor];
        [cv addSubview:_scriptScrollView];

        // Reposition on rotation
        [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceOrientationDidChangeNotification
            object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
                if (isShown) [self repositionWindow];
            }];
    });
}

- (UIView*) makeSepAt:(CGRect)r {
    UIView *s = [[UIView alloc] initWithFrame:r];
    s.backgroundColor = [UIColor separatorColor];
    return s;
}

- (void) updateSettingsButtonAppearance {
    if (!_gearBtn) return;
    _gearBtn.backgroundColor = _settingsVisible ?
        [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.25] :
        [UIColor secondarySystemBackgroundColor];
}

// 界面外观：0跟随系统 1浅色 2深色。旧配置只有 dark_mode 布尔值，按 深色/浅色 迁移。
NSInteger ZXAppearanceModeFromConfig(NSDictionary *config) {
    if (config[@"appearance_mode"]) {
        return [config[@"appearance_mode"] integerValue];
    }
    return config[@"dark_mode"] ? ([config[@"dark_mode"] boolValue] ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight)
                                : UIUserInterfaceStyleLight;
}

void applyPanelAppearanceMode(NSInteger mode) {
    extern PopupWindow *popupWindow;
    if (popupWindow) {
        ZXSafeMainAsync(^{
            [popupWindow setAppearanceMode:mode];
        });
    }
}



- (void) repositionWindow {
    ZXSafeMainAsync(^{
        CGRect sb = [UIScreen mainScreen].bounds;
        CGFloat shortSide = MIN(sb.size.width, sb.size.height);
        CGFloat longSide  = MAX(sb.size.width, sb.size.height);
        CGFloat pw = shortSide * 0.65f;
        pw = MAX(pw, 220); pw = MIN(pw, 320);
        CGFloat ph = longSide * 0.55f;
        ph = MAX(ph, 280); ph = MIN(ph, 420);
        CGFloat cx = CGRectGetMidX(sb) - pw/2;
        CGFloat cy = CGRectGetMidY(sb) - ph/2;
        _window.frame = CGRectMake(cx, cy, pw, ph);
        // Resize scrollview to fill to the bottom of the new window height
        if (_scriptScrollView) {
            CGFloat scrollTop = _scriptScrollView.frame.origin.y;
            _scriptScrollView.frame = CGRectMake(0, scrollTop, pw, ph - scrollTop - 8);
        }
    });
}

- (void) populateScrollView:(NSArray<NSDictionary*>*)items {
    for (UIView *v in _scriptScrollView.subviews) [v removeFromSuperview];
    CGFloat pw = _window.frame.size.width;
    if (pw < 10) pw = 260;
    CGFloat y = 4;
    for (NSDictionary *item in items) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        [btn setTitle:item[@"label"] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:13];
        btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        btn.frame = CGRectMake(8, y, pw - 16, BTN_H);
        btn.backgroundColor = [UIColor secondarySystemBackgroundColor];
        btn.layer.cornerRadius = 8;
        btn.layer.borderColor = [UIColor separatorColor].CGColor;
        btn.layer.borderWidth = 1;
        NSString *action = item[@"action"];
        if ([action isEqualToString:@"folder"]) {
            [btn setImage:panelSymbol(@"folder.fill") forState:UIControlStateNormal];
            btn.tintColor = [UIColor systemBlueColor];
            [btn setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
            NSString *fp = item[@"path"], *fn = item[@"folderName"];
            [btn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
                [self showFolder:fp name:fn];
            }] forControlEvents:UIControlEventTouchUpInside];
        } else if ([action isEqualToString:@"back"]) {
            [btn setImage:panelSymbol(@"chevron.left") forState:UIControlStateNormal];
            btn.tintColor = [UIColor systemOrangeColor];
            [btn setTitleColor:[UIColor systemOrangeColor] forState:UIControlStateNormal];
            [btn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
                [self refreshScriptList];
            }] forControlEvents:UIControlEventTouchUpInside];
        } else {
            [btn setImage:panelSymbol(@"play.fill") forState:UIControlStateNormal];
            btn.tintColor = [UIColor labelColor];
            NSString *fullPath = item[@"path"];
            [btn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
                if (_settingsVisible) {
                    UIAlertController *alert = [UIAlertController
                        alertControllerWithTitle:@"播放设置"
                        message:item[@"label"]
                        preferredStyle:UIAlertControllerStyleAlert];
                    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
                        tf.placeholder = @"重复次数（如 3）";
                        tf.keyboardType = UIKeyboardTypeNumberPad;
                        tf.text = _repeatCount > 0 ? [NSString stringWithFormat:@"%d", _repeatCount] : @"";
                    }];
                    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
                        tf.placeholder = @"播放速度（如 1.0）";
                        tf.keyboardType = UIKeyboardTypeDecimalPad;
                        tf.text = [NSString stringWithFormat:@"%.1f", _speed];
                    }];
                    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
                        tf.placeholder = @"运行间隔（秒，如 0）";
                        tf.keyboardType = UIKeyboardTypeDecimalPad;
                        tf.text = _interval > 0 ? [NSString stringWithFormat:@"%.1f", _interval] : @"";
                    }];
                    [alert addAction:[UIAlertAction actionWithTitle:@"运行" style:UIAlertActionStyleDefault handler:^(UIAlertAction *aa) {
                        NSString *repeatStr  = alert.textFields[0].text;
                        NSString *speedStr   = alert.textFields[1].text;
                        NSString *intervalStr = alert.textFields[2].text;
                        int repeat   = (repeatStr.length > 0)   ? [repeatStr intValue]      : 0;
                        float sp     = (speedStr.length > 0)    ? [speedStr floatValue]     : 1.0f;
                        float intv   = (intervalStr.length > 0) ? [intervalStr floatValue]  : 0.0f;
                        if (sp <= 0) sp = 1.0f;
                        _repeatCount = repeat; _speed = sp; _interval = intv;
                        [self hide];
                        [self saveSettings:_repeatCount speed:_speed interval:_interval];
                        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                            NSError *err = nil;
                            playScriptWithSettings((UInt8*)[fullPath UTF8String], repeat, sp, intv, &err);
                            if (err) showAlertBox(@"错误", [err localizedDescription], 999);
                        });
                    }]];
                    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
                    ZXSafeMainAsync(^{
                        [_window.rootViewController presentViewController:alert animated:YES completion:nil];
                    });
                } else {
                    // Direct play
                    [self hide];
                    [self saveSettings:_repeatCount speed:_speed interval:_interval enabled:NO];
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                        NSError *err = nil;
                        playScriptWithSettings((UInt8*)[fullPath UTF8String], 0, 1.0f, 0.0f, &err);
                        if (err) showAlertBox(@"错误", [err localizedDescription], 999);
                    });
                }
            }] forControlEvents:UIControlEventTouchUpInside];
        }
        [_scriptScrollView addSubview:btn];
        y += BTN_H + 6;
    }
    _scriptScrollView.contentSize = CGSizeMake(pw, y + 4);
    [_scriptScrollView setContentOffset:CGPointZero animated:NO];
}

- (void) saveSettings:(int)repeat speed:(float)speed interval:(float)interval {
    [self saveSettings:repeat speed:speed interval:interval enabled:_settingsVisible];
}

- (void) saveSettings:(int)repeat speed:(float)speed interval:(float)interval enabled:(BOOL)enabled {
    NSMutableDictionary *config = [NSMutableDictionary dictionary];
    NSDictionary *existing = [[NSDictionary alloc] initWithContentsOfFile:SCRIPT_PLAY_CONFIG_PATH];
    if (existing) [config addEntriesFromDictionary:existing];
    config[@"panelPlaybackInfo"] = @{
        SETTINGS_KEY_REPEAT: @(repeat),
        SETTINGS_KEY_SPEED: @(speed),
        SETTINGS_KEY_INTERVAL: @(interval),
        SETTINGS_KEY_ENABLED: @(enabled)
    };
    [config writeToFile:SCRIPT_PLAY_CONFIG_PATH atomically:YES];
}

- (void) showFolder:(NSString*)folderPath name:(NSString*)name {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *contents = [[fm contentsOfDirectoryAtPath:folderPath error:nil]
                         sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSMutableArray *items = [NSMutableArray array];
    [items addObject:@{@"label": @"← 返回", @"action": @"back"}];
    for (NSString *n in contents) {
        if (![n hasSuffix:@".bdl"]) continue;
        NSString *path = [folderPath stringByAppendingPathComponent:n];
        [items addObject:@{@"label": [n substringToIndex:n.length-4], @"path": path, @"action": @"play"}];
    }
    ZXSafeMainAsync(^{ [self populateScrollView:items]; });
}

- (void) refreshScriptList {
    NSString *base = getScriptsFolder();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *top = [[fm contentsOfDirectoryAtPath:base error:nil]
                    sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *name in top) {
        NSString *path = [base stringByAppendingPathComponent:name];
        BOOL isDir = NO; [fm fileExistsAtPath:path isDirectory:&isDir];
        if ([name hasSuffix:@".bdl"]) {
            [items addObject:@{@"label": [name substringToIndex:name.length-4], @"path": path, @"action": @"play"}];
        } else if (isDir) {
            [items addObject:@{@"label": name, @"path": path, @"folderName": name, @"action": @"folder"}];
        }
    }
    ZXSafeMainAsync(^{ [self populateScrollView:items]; });
}

- (void) recordingStart {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self hide];
        NSError *err = nil;
        startRecording(0, &err);
        if (err) showAlertBox(@"错误", [NSString stringWithFormat:@"无法开始录制：%@", [err localizedDescription]], 999);
    });
}

- (void) stopPlaying {
    if (!isScriptPlaying()) {
        // No script running — do nothing silently
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSError *err = nil;
        stopScriptPlaying(&err);
        // Don't show alert here — volume button handler shows it
    });
}

- (void) stopAction {
    // The Stop button is the only stop affordance in the panel, so it has to
    // mirror the hotkey handler and end a recording as well as a script.
    // It previously called -stopPlaying, which returns silently unless a script
    // is playing, so pressing Stop while recording did nothing at all and the
    // recording could only be ended with the hotkey.
    if (isRecordingStart())
    {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            stopRecording();
            showAlertBox(@"小新Lap", @"录制已停止并保存。", 1);
        });
        return;
    }

    [self stopPlaying];
}

- (void) setAppearanceMode:(NSInteger)mode {
    ZXSafeMainAsync(^{
        _window.overrideUserInterfaceStyle = (UIUserInterfaceStyle)mode;
    });
}

- (void) show {
    // 每次打开都回到脚本列表首页
    [self refreshScriptList];
    [self repositionWindow];
    ZXSafeMainAsync(^{
        // Apply dark mode from config each time the panel opens
        NSDictionary *cfg = [[NSDictionary alloc] initWithContentsOfFile:SCRIPT_PLAY_CONFIG_PATH];
        NSDictionary *panelInfo = cfg[@"panelPlaybackInfo"];
        if (panelInfo) {
            _repeatCount = [panelInfo[@"repeat_times"] intValue];
            float sp = [panelInfo[@"speed"] floatValue];
            _speed = sp > 0 ? sp : 1.0f;
            _interval = [panelInfo[@"interval"] floatValue];
            _settingsVisible = [panelInfo[SETTINGS_KEY_ENABLED] boolValue];
        } else {
            _settingsVisible = NO;
        }
        [self updateSettingsButtonAppearance];
        NSDictionary *tweakCfg = nil;
        NSString *configFilePath = [NSString stringWithFormat:@"/var/mobile/Library/ZXTouch/config/tweak/config.plist"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:configFilePath])
            tweakCfg = [[NSDictionary alloc] initWithContentsOfFile:configFilePath];
        NSInteger appearanceMode = ZXAppearanceModeFromConfig(tweakCfg);
        _window.overrideUserInterfaceStyle = (UIUserInterfaceStyle)appearanceMode;
        _window.hidden = NO;
    });
    isShown = YES;
}

- (void) hide {
    ZXSafeMainAsync(^{
        _window.hidden = YES;
    });
    isShown = NO;
}

- (BOOL) isShown { return isShown; }

@end
