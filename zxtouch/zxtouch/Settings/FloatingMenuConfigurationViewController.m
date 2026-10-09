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
static NSString *kCfgDotIcon = @"floating_menu_dot_icon"; // 1=App图标 2=自定义图片
static NSString *kCfgAutoEdge    = @"floating_menu_auto_edge";           // 菜单收起后自动收边
static NSString *kCfgEdgeVisible = @"floating_menu_edge_visible_ratio";  // 收边后圆点可见比例 0.1..1.0
static NSString *kCfgEdgeDelay   = @"floating_menu_auto_edge_delay";     // 收起后延迟多少秒 0..7

// 选项面板（功能页）背景，全局生效：颜色 + 透明度 + 自定义图片
// 图片落盘到共享目录，配置里只存文件名（tweak 端不访问相册）
static NSString *kCfgPanelBgColor = @"floating_menu_panel_bg_color";     // #RRGGBB，缺省 = 跟随系统
static NSString *kCfgPanelBgAlpha = @"floating_menu_panel_bg_alpha";     // 0..1
static NSString *kCfgPanelBgImage = @"floating_menu_panel_bg_image";     // 文件名，空 = 不用图
static NSString * const kPanelBgCustomFile = @"fm_panel_bg_custom.png";
static const float kPanelBgAlphaDefault = 1.0f;

// 圆点图标来源（与 tweak 端 kFMDotIconMode* 保持一致）：只有 App 图标 / 自定义图片
static const NSInteger kDotIconModeApp    = 1;
static const NSInteger kDotIconModeCustom = 2;

// 自定义图片 PNG 落盘到共享目录（与 tweak 读的路径同名），tweak 端不访问相册
static NSString * const kDotIconCustomFile = @"fm_dot_icon_custom.png";

static NSString *FMDotIconDir(void)
{
    return [SPRINGBOARD_CONFIG_PATH stringByDeletingLastPathComponent];
}

// 圆点大小范围（与 tweak 端 kFMDotMinSize / kFMDotMaxSize 保持一致）
static const float kDotSizeMin     = 32.0f;
static const float kDotSizeMax     = 80.0f;
static const float kDotSizeDefault = 48.0f;

// 菜单黑底透明度（与 tweak 端 kFMMenuDefaultBgAlpha 保持一致）
static const float kMenuBgAlphaDefault = 0.92f;

typedef NS_ENUM(NSInteger, FMSection) {
    FMSectionSwitch         = 0,  // 开关
    FMSectionPosition       = 1,  // 吸附边 + 纵向位置
    FMSectionAutoEdge       = 2,  // 自动收边 + 收边后可见比例
    FMSectionAppearance     = 3,  // 圆点大小 + 菜单黑底透明度
    FMSectionMenuAppearance = 4,  // 菜单按钮大小/间距/标签字号/图标留白/圆点-菜单间距
    FMSectionDotIcon        = 5,  // 圆点图标来源
    FMSectionColors         = 6,  // 颜色（圆点/按钮背景、图标、标签文字）
    FMSectionPause          = 7,  // 暂停显示（文字/字号/颜色/变灰深度）
    FMSectionPanelBg        = 8   // 选项面板背景（颜色/透明度/自定义图片）
};

// 「选项面板背景」分组行号
typedef NS_ENUM(NSInteger, PanelBgRow) {
    PanelBgRowColor = 0,  // 背景颜色
    PanelBgRowAlpha,      // 背景透明度
    PanelBgRowImage       // 自定义背景图片
};

// 「自动收边」分组行号
typedef NS_ENUM(NSInteger, AutoEdgeRow) {
    AutoEdgeRowSwitch = 0,  // 菜单收起后自动收边
    AutoEdgeRowDelay,       // 收起后延迟秒数 0..7
    AutoEdgeRowVisible      // 收边后圆点可见比例
};

// 「暂停显示」分组行号
typedef NS_ENUM(NSInteger, PauseRow) {
    PauseRowText  = 0,  // 暂停文字（点按输入）
    PauseRowFont  = 1,  // 文字字号
    PauseRowColor = 2,  // 文字颜色
    PauseRowGray  = 3   // 圆点变灰深度
};

// 「圆点图标」分组行号
typedef NS_ENUM(NSInteger, DotIconRow) {
    DotIconRowSource = 0,  // 图标来源（点按循环）
    DotIconRowRepick = 1   // 重新选择图片（仅自定义模式显示）
};

/*
 * 颜色项定义表（配置键 / 标题 / 默认色）。
 * 默认值必须与 tweak 端 kFM*ColorDefault 保持一致。
 */
static NSArray<NSDictionary *> *FMColorSpecs(void) {
    static NSArray<NSDictionary *> *specs = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        specs = @[
            @{@"key": @"floating_menu_dot_bg_color",   @"title": @"圆点背景色",   @"default": @"#14141C"},
            @{@"key": @"floating_menu_menu_btn_color", @"title": @"按钮背景色",   @"default": @"#1F1F1F"},
            @{@"key": @"floating_menu_icon_color",     @"title": @"图标颜色",     @"default": @"#FFFFFF"},
            @{@"key": @"floating_menu_label_color",    @"title": @"标签文字颜色", @"default": @"#FFFFFF"}
        ];
    });
    return specs;
}

// 颜色候选（另有「手动输入十六进制」可选任意颜色）
static NSArray<NSArray<NSString *> *> *FMColorPresets(void) {
    return @[
        @[@"白色", @"#FFFFFF"], @[@"黑色", @"#000000"], @[@"红色", @"#FF3B30"],
        @[@"绿色", @"#34C759"], @[@"蓝色", @"#007AFF"], @[@"橙色", @"#FF9500"]
    ];
}

/*
 * 「暂停显示」定义表（key / 标题 / 默认值，滑块项另带 min/max）。
 * 默认值与范围必须与 tweak 端 FloatingMenu.xm 的 kFMPause* 宏保持一致。
 */
static NSArray<NSDictionary *> *FMPauseSpecs(void) {
    static NSArray<NSDictionary *> *specs = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        specs = @[
            @{@"key": @"floating_menu_pause_text",       @"title": @"暂停文字",   @"default": @"已暂停"},
            @{@"key": @"floating_menu_pause_font_size",  @"title": @"文字字号",   @"min": @6.0f,  @"max": @16.0f, @"default": @9.0f},
            @{@"key": @"floating_menu_pause_text_color", @"title": @"文字颜色",   @"default": @"#FFFFFF"},
            @{@"key": @"floating_menu_pause_gray_alpha", @"title": @"圆点变灰深度", @"min": @0.0f, @"max": @1.0f,  @"default": @0.55f}
        ];
    });
    return specs;
}

// 「外观」分组行号
typedef NS_ENUM(NSInteger, AppearanceRow) {
    AppearanceRowDotSize     = 0,
    AppearanceRowMenuBgAlpha = 1
};

/*
 * 菜单外观滑块定义表（key / 标题 / 最小 / 最大 / 默认值）。
 * 范围与默认值必须与 tweak 端 FloatingMenu.xm 的 kFMMenu* 宏保持一致。
 * 用表驱动避免为 5 个几乎相同的滑块各写一份 cell 配置 + 回调。
 */
static NSArray<NSDictionary *> *FMMenuAppearanceSpecs(void) {
    static NSArray<NSDictionary *> *specs = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        specs = @[
            @{@"key": @"floating_menu_menu_size",       @"title": @"按钮大小",      @"min": @32.0f, @"max": @72.0f, @"default": @36.0f},
            @{@"key": @"floating_menu_menu_gap",        @"title": @"按钮间距",      @"min": @0.0f,  @"max": @24.0f, @"default": @8.0f},
            @{@"key": @"floating_menu_label_font_size", @"title": @"标签字号",      @"min": @9.0f,  @"max": @18.0f, @"default": @12.0f},
            @{@"key": @"floating_menu_icon_inset",      @"title": @"图标圆内留白",  @"min": @0.0f,  @"max": @10.0f, @"default": @5.0f},
            @{@"key": @"floating_menu_panel_gap",       @"title": @"圆点到菜单间距", @"min": @0.0f,  @"max": @40.0f, @"default": @8.0f}
        ];
    });
    return specs;
}

@interface FloatingMenuConfigurationViewController () <UIImagePickerControllerDelegate, UINavigationControllerDelegate>

@end

@implementation FloatingMenuConfigurationViewController
{
    NSMutableDictionary *_config;
    Socket *_springBoardSocket;
    BOOL _pickingPanelBg;   // 选图回调要知道这次选的是圆点图标还是面板背景图
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
    // 关闭时只保留开关这一行，其余参数分组整段隐藏
    [_tableView reloadData];
}

#pragma mark - 自动收边

- (void)autoEdgeSwitchChanged:(UISwitch *)s {
    _config[kCfgAutoEdge] = @([s isOn]);
    [self saveConfig];
    [_tableView reloadData];   // 关闭时把「显示比例」滑块一起收掉
    [self reloadTweak];
}

- (void)edgeVisibleValueChanged:(UISlider *)slider {
    float stepped = roundf(slider.value * 100.0f) / 100.0f;
    [slider setValue:stepped animated:NO];
    UIView *view = slider;
    while (view && ![view isKindOfClass:[TableViewCellWithSlider class]]) {
        view = view.superview;
    }
    if ([view isKindOfClass:[TableViewCellWithSlider class]]) {
        ((TableViewCellWithSlider *)view).value.text = [NSString stringWithFormat:@"%.0f%%", stepped * 100.0f];
    }
    // 拖动过程中只写 plist，松手才 reload
    _config[kCfgEdgeVisible] = @(stepped);
    [self saveConfig];
}

- (void)autoEdgeDelayValueChanged:(UISlider *)slider {
    float stepped = roundf(slider.value * 10.0f) / 10.0f;   // 0.1 秒一档
    [slider setValue:stepped animated:NO];
    UIView *view = slider;
    while (view && ![view isKindOfClass:[TableViewCellWithSlider class]]) {
        view = view.superview;
    }
    if ([view isKindOfClass:[TableViewCellWithSlider class]]) {
        ((TableViewCellWithSlider *)view).value.text = [NSString stringWithFormat:@"%.1f秒", stepped];
    }
    // 拖动过程中只写 plist，松手才 reload
    _config[kCfgEdgeDelay] = @(stepped);
    [self saveConfig];
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

#pragma mark - 菜单外观（表驱动）

- (void)menuAppearanceSliderChanged:(UISlider *)slider {
    NSArray<NSDictionary *> *specs = FMMenuAppearanceSpecs();
    NSInteger row = slider.tag;
    if (row < 0 || row >= (NSInteger)specs.count) {
        return;
    }
    NSDictionary *spec = specs[row];

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
    _config[spec[@"key"]] = @((NSInteger)stepped);
    [self saveConfig];
}

// 任意滑块松手后统一通知 tweak 重载配置
- (void)sliderTouchUp:(id)sender {
    [self reloadTweak];
}

#pragma mark - 暂停显示（表驱动）

- (NSString *)pauseText {
    NSString *text = _config[@"floating_menu_pause_text"];
    if (![text isKindOfClass:[NSString class]] || text.length == 0) {
        return @"已暂停";
    }
    return text;
}

- (void)pauseSliderChanged:(UISlider *)slider {
    NSArray<NSDictionary *> *specs = FMPauseSpecs();
    NSInteger row = slider.tag;
    if (row < 0 || row >= (NSInteger)specs.count) {
        return;
    }
    NSDictionary *spec = specs[row];
    BOOL isAlpha = (row == PauseRowGray);

    float stepped = isAlpha ? roundf(slider.value * 100.0f) / 100.0f : roundf(slider.value);
    [slider setValue:stepped animated:NO];

    // 显示实时数值
    UIView *view = slider;
    while (view && ![view isKindOfClass:[TableViewCellWithSlider class]]) {
        view = view.superview;
    }
    if ([view isKindOfClass:[TableViewCellWithSlider class]]) {
        ((TableViewCellWithSlider *)view).value.text = isAlpha
            ? [NSString stringWithFormat:@"%.2f", stepped]
            : [NSString stringWithFormat:@"%.0f pt", stepped];
    }

    // 拖动过程中只写 plist，松手才 reload
    _config[spec[@"key"]] = @(stepped);
    [self saveConfig];
}

// 暂停文字：弹输入框；圆点很小，留空则回落到默认「已暂停」
- (void)presentPauseTextEditor {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"暂停文字"
        message:@"脚本暂停时叠加在圆点上的文字"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = [self pauseText];
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak FloatingMenuConfigurationViewController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        FloatingMenuConfigurationViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        NSString *input = alert.textFields.firstObject.text ?: @"";
        strongSelf->_config[@"floating_menu_pause_text"] = input;
        [strongSelf saveConfig];
        [strongSelf reloadTweak];
        [strongSelf->_tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)pickPauseTextColorAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *spec = FMPauseSpecs()[PauseRowColor];
    NSString *current = [self colorHexForKey:spec[@"key"] defaultHex:spec[@"default"]];
    __weak FloatingMenuConfigurationViewController *weakSelf = self;
    [self presentColorPickerForTitle:spec[@"title"] current:current presets:FMColorPresets()
                              anchor:[self.tableView cellForRowAtIndexPath:indexPath]
                            onPicked:^(NSString *hex) {
        FloatingMenuConfigurationViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_config[spec[@"key"]] = hex;
        [strongSelf saveConfig];
        [strongSelf reloadTweak];
        [strongSelf->_tableView reloadData];
    }];
}

#pragma mark - 圆点图标

- (NSInteger)dotIconMode {
    NSNumber *value = _config[kCfgDotIcon];
    NSInteger mode = value ? [value integerValue] : kDotIconModeApp;
    // 只允许「App 图标 / 自定义图片」；旧配置里的 0(字母Z)、1(App) 都归到 App
    if (mode != kDotIconModeCustom) mode = kDotIconModeApp;
    return mode;
}

- (NSString *)dotIconModeTitle {
    return ([self dotIconMode] == kDotIconModeCustom) ? @"自定义图片" : @"App 图标";
}

// 圆点最大 80pt，先把图片缩到 240pt 以内再存，避免往共享目录塞原图
- (NSData *)pngDataForDotIcon:(UIImage *)image {
    if (!image) return nil;
    CGSize src = image.size;
    if (src.width <= 0 || src.height <= 0) return nil;
    CGFloat scale = MIN(1.0f, 240.0f / MAX(src.width, src.height));
    CGSize dst = CGSizeMake(floor(src.width * scale), floor(src.height * scale));
    UIGraphicsBeginImageContextWithOptions(dst, NO, 1.0f);
    [image drawInRect:CGRectMake(0, 0, dst.width, dst.height)];
    UIImage *scaled = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return UIImagePNGRepresentation(scaled ?: image);
}

- (BOOL)writeDotIconData:(NSData *)data fileName:(NSString *)fileName {
    if (!data) return NO;
    return [data writeToFile:[FMDotIconDir() stringByAppendingPathComponent:fileName] atomically:YES];
}

- (void)presentDotIconPicker {
    if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary]) {
        [Util showAlertBoxWithOneOption:self title:@"错误" message:@"照片图库不可用。" buttonString:@"确定"];
        return;
    }
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.delegate = self;
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:picker animated:YES completion:nil];
}

// 「图标来源」点按在两种之间切换：App 图标 ↔ 自定义图片
- (void)cycleDotIconMode {
    BOOL toCustom = ([self dotIconMode] == kDotIconModeApp);
    _config[kCfgDotIcon] = @(toCustom ? kDotIconModeCustom : kDotIconModeApp);
    [self saveConfig];
    [_tableView reloadData];
    if (toCustom) {
        [self presentDotIconPicker];   // 选完图在回调里 reloadTweak；取消则回退 App 图标
    } else {
        [self reloadTweak];
    }
}

#pragma mark - 选图回调

- (void)imagePickerController:(UIImagePickerController *)picker
didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    if (_pickingPanelBg) {
        _pickingPanelBg = NO;
        NSData *bgData = [self pngDataForPanelBg:info[UIImagePickerControllerOriginalImage]];
        BOOL saved = bgData && [bgData writeToFile:[FMDotIconDir() stringByAppendingPathComponent:kPanelBgCustomFile]
                                        atomically:YES];
        if (saved) _config[kCfgPanelBgImage] = kPanelBgCustomFile;
        [self saveConfig];
        [picker dismissViewControllerAnimated:YES completion:^{
            [self reloadTweak];
            [self->_tableView reloadData];
            if (!saved) {
                [Util showAlertBoxWithOneOption:self title:@"错误"
                                        message:@"无法保存所选图片。"
                                   buttonString:@"确定"];
            }
        }];
        return;
    }

    NSData *data = [self pngDataForDotIcon:info[UIImagePickerControllerOriginalImage]];
    BOOL saved = [self writeDotIconData:data fileName:kDotIconCustomFile];
    _config[kCfgDotIcon] = @(saved ? kDotIconModeCustom : kDotIconModeApp);
    [self saveConfig];
    [picker dismissViewControllerAnimated:YES completion:^{
        [self reloadTweak];
        [self->_tableView reloadData];
        if (!saved) {
            [Util showAlertBoxWithOneOption:self title:@"错误"
                                    message:@"无法保存所选图片，已恢复为 App 图标。"
                               buttonString:@"确定"];
        }
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    if (_pickingPanelBg) {
        _pickingPanelBg = NO;
        [picker dismissViewControllerAnimated:YES completion:^{
            [self->_tableView reloadData];
        }];
        return;
    }
    // 自定义图片还没落地就退出 → 回到 App 图标，避免出现「选了自定义但没有图」的状态
    NSString *customPath = [FMDotIconDir() stringByAppendingPathComponent:kDotIconCustomFile];
    if ([self dotIconMode] == kDotIconModeCustom &&
        ![[NSFileManager defaultManager] fileExistsAtPath:customPath]) {
        _config[kCfgDotIcon] = @(kDotIconModeApp);
        [self saveConfig];
    }
    [self reloadTweak];   // 取消也要同步一次：上面可能刚从自定义回退成 App 图标
    [picker dismissViewControllerAnimated:YES completion:^{
        [self->_tableView reloadData];
    }];
}

#pragma mark - 选项面板背景

- (NSString *)panelBgImageName {
    NSString *name = _config[kCfgPanelBgImage];
    if (![name isKindOfClass:[NSString class]]) return @"";
    return [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// 背景图整屏铺，留到 1200px 就够清晰了，避免往共享目录塞原图
- (NSData *)pngDataForPanelBg:(UIImage *)image {
    if (!image) return nil;
    CGSize src = image.size;
    if (src.width <= 0 || src.height <= 0) return nil;
    CGFloat scale = MIN(1.0f, 1200.0f / MAX(src.width, src.height));
    CGSize dst = CGSizeMake(floor(src.width * scale), floor(src.height * scale));
    UIGraphicsBeginImageContextWithOptions(dst, NO, 1.0f);
    [image drawInRect:CGRectMake(0, 0, dst.width, dst.height)];
    UIImage *scaled = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return UIImagePNGRepresentation(scaled ?: image);
}

- (void)presentPanelBgPicker {
    if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary]) {
        [Util showAlertBoxWithOneOption:self title:@"错误" message:@"照片图库不可用。" buttonString:@"确定"];
        return;
    }
    _pickingPanelBg = YES;
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.delegate = self;
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)clearPanelBgImage {
    [[NSFileManager defaultManager] removeItemAtPath:
        [FMDotIconDir() stringByAppendingPathComponent:kPanelBgCustomFile] error:NULL];
    [_config removeObjectForKey:kCfgPanelBgImage];
    [self saveConfig];
    [self reloadTweak];
    [_tableView reloadData];
}

- (void)panelBgImageTapped:(NSIndexPath *)indexPath {
    if ([self panelBgImageName].length == 0) {
        [self presentPanelBgPicker];
        return;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"自定义背景图片"
        message:@"已经设置了一张背景图" preferredStyle:UIAlertControllerStyleActionSheet];
    __weak FloatingMenuConfigurationViewController *weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"重新选择" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) { [weakSelf presentPanelBgPicker]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"清除（不用图）" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *action) { [weakSelf clearPanelBgImage]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop) {
        // 同颜色选择：iPad 上必须锚在被点的 cell，锚到 tableView.bounds 会带上滚动偏移
        UIView *anchor = [self.tableView cellForRowAtIndexPath:indexPath];
        pop.sourceView = anchor ?: self.tableView;
        pop.sourceRect = anchor ? anchor.bounds : self.tableView.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)panelBgAlphaValueChanged:(UISlider *)slider {
    float stepped = roundf(slider.value * 100.0f) / 100.0f;
    [slider setValue:stepped animated:NO];
    UIView *view = slider;
    while (view && ![view isKindOfClass:[TableViewCellWithSlider class]]) {
        view = view.superview;
    }
    if ([view isKindOfClass:[TableViewCellWithSlider class]]) {
        ((TableViewCellWithSlider *)view).value.text = [NSString stringWithFormat:@"%.2f", stepped];
    }
    // 拖动过程中只写 plist，松手才 reload
    _config[kCfgPanelBgAlpha] = @(stepped);
    [self saveConfig];
}

- (void)pickPanelBgColorAtIndexPath:(NSIndexPath *)indexPath {
    NSString *current = [self colorHexForKey:kCfgPanelBgColor defaultHex:@"#FFFFFF"];
    __weak FloatingMenuConfigurationViewController *weakSelf = self;
    [self presentColorPickerForTitle:@"面板背景颜色" current:current presets:FMColorPresets()
                              anchor:[self.tableView cellForRowAtIndexPath:indexPath]
                            onPicked:^(NSString *hex) {
        FloatingMenuConfigurationViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_config[kCfgPanelBgColor] = hex;
        [strongSelf saveConfig];
        [strongSelf reloadTweak];
        [strongSelf->_tableView reloadData];
    }];
}

#pragma mark - 颜色

- (NSString *)colorHexForKey:(NSString *)key defaultHex:(NSString *)defaultHex {
    NSString *hex = _config[key];
    return [hex isKindOfClass:[NSString class]] ? hex : defaultHex;
}

- (BOOL)isValidHexColor:(NSString *)value {
    if (![value isKindOfClass:[NSString class]]) return NO;
    NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([trimmed hasPrefix:@"#"]) trimmed = [trimmed substringFromIndex:1];
    if (trimmed.length != 6 && trimmed.length != 3) return NO;
    NSCharacterSet *hexSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    return [trimmed rangeOfCharacterFromSet:[hexSet invertedSet]].location == NSNotFound;
}

// 预设色候选 + 手动输入十六进制（与「触摸坐标悬浮窗」页的取色方式保持一致）
- (void)presentColorPickerForTitle:(NSString *)title
                           current:(NSString *)current
                          presets:(NSArray<NSArray<NSString *> *> *)presets
                            anchor:(UIView *)anchor
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
        // iPad 上必须锚在被点的那个 cell：锚到 tableView.bounds 时会带上滚动偏移，
        // 锚点跑到可视区外，action sheet 弹不出来（表现为「点颜色没反应」）
        pop.sourceView = anchor ?: self.tableView;
        pop.sourceRect = anchor ? anchor.bounds : self.tableView.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)pickColorAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *spec = FMColorSpecs()[indexPath.row];
    NSString *current = [self colorHexForKey:spec[@"key"] defaultHex:spec[@"default"]];
    __weak FloatingMenuConfigurationViewController *weakSelf = self;
    [self presentColorPickerForTitle:spec[@"title"] current:current presets:FMColorPresets()
                              anchor:[self.tableView cellForRowAtIndexPath:indexPath]
                            onPicked:^(NSString *hex) {
        FloatingMenuConfigurationViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_config[spec[@"key"]] = hex;
        [strongSelf saveConfig];
        [strongSelf reloadTweak];
        [strongSelf->_tableView reloadData];
    }];
}

#pragma mark - UITableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    // 关掉开关时整页只留开关行
    return [_config[kCfgEnabled] boolValue] ? 9 : 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case FMSectionSwitch:     return 1;  // 开关
        case FMSectionPosition:   return 2;  // 吸附边 + 纵向位置
        case FMSectionAutoEdge:   return [_config[kCfgAutoEdge] boolValue] ? 3 : 1;  // 开关（+ 延迟 + 显示比例）
        case FMSectionAppearance: return 2;  // 圆点大小 + 菜单黑底透明度
        case FMSectionDotIcon:    return ([self dotIconMode] == kDotIconModeCustom) ? 2 : 1;
        case FMSectionColors:     return (NSInteger)FMColorSpecs().count;
        case FMSectionPause:      return (NSInteger)FMPauseSpecs().count;
        case FMSectionMenuAppearance: return (NSInteger)FMMenuAppearanceSpecs().count;
        case FMSectionPanelBg:    return 3;  // 背景颜色 + 背景透明度 + 自定义背景图片
        default:                  return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case FMSectionSwitch:     return @"开关";
        case FMSectionPosition:   return @"位置";
        case FMSectionAutoEdge:   return @"自动收边";
        case FMSectionAppearance: return @"外观";
        case FMSectionMenuAppearance: return @"菜单外观";
        case FMSectionDotIcon:    return @"圆点图标";
        case FMSectionColors:     return @"颜色";
        case FMSectionPause:      return @"暂停显示";
        case FMSectionPanelBg:    return @"选项面板背景（全局）";
        default:                  return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == FMSectionSwitch) {
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

    // 「位置」row 0：吸附边 — 用 Entry cell 包装一个 segment
    if (indexPath.section == FMSectionPosition && indexPath.row == 0) {
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

    // 「自动收边」：开关 + 收边后圆点可见比例（关掉开关时比例行隐藏）
    if (indexPath.section == FMSectionAutoEdge) {
        if (indexPath.row == AutoEdgeRowSwitch) {
            TableViewCellWithSwitch *cell = [tableView dequeueReusableCellWithIdentifier:@"SwitchCell" forIndexPath:indexPath];
            [cell setTitleText:@"菜单收起后自动收边"];
            [cell.switchBtn removeTarget:nil action:NULL forControlEvents:UIControlEventValueChanged];
            [cell.switchBtn addTarget:self action:@selector(autoEdgeSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            [cell.switchBtn setOn:[_config[kCfgAutoEdge] boolValue]];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
        if (indexPath.row == AutoEdgeRowDelay) {
            TableViewCellWithSlider *cell = [tableView dequeueReusableCellWithIdentifier:@"SliderCell" forIndexPath:indexPath];
            cell.slideBar.continuous = YES;
            [cell.slideBar removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
            [cell.slideBar addTarget:self action:@selector(autoEdgeDelayValueChanged:) forControlEvents:UIControlEventValueChanged];
            [cell.slideBar addTarget:self action:@selector(sliderTouchUp:)
                    forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
            float delay = _config[kCfgEdgeDelay] ? [_config[kCfgEdgeDelay] floatValue] : 4.0f;
            if (delay < 0.0f || delay > 7.0f) delay = 4.0f;
            cell.title.text = @"收起后延迟";
            cell.slideBar.minimumValue = 0.0f;
            cell.slideBar.maximumValue = 7.0f;
            cell.slideBar.value = delay;
            cell.value.text = [NSString stringWithFormat:@"%.1f秒", delay];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
        TableViewCellWithSlider *cell = [tableView dequeueReusableCellWithIdentifier:@"SliderCell" forIndexPath:indexPath];
        cell.slideBar.continuous = YES;
        [cell.slideBar removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
        [cell.slideBar addTarget:self action:@selector(edgeVisibleValueChanged:) forControlEvents:UIControlEventValueChanged];
        [cell.slideBar addTarget:self action:@selector(sliderTouchUp:)
                forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        float visible = _config[kCfgEdgeVisible] ? [_config[kCfgEdgeVisible] floatValue] : 0.6f;
        if (visible < 0.1f || visible > 1.0f) visible = 0.6f;
        cell.title.text = @"贴边后显示比例";
        cell.slideBar.minimumValue = 0.1f;
        cell.slideBar.maximumValue = 1.0f;
        cell.slideBar.value = visible;
        cell.value.text = [NSString stringWithFormat:@"%.0f%%", visible * 100.0f];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    // 「圆点图标」：row 0 点按循环切换来源；自定义模式下多一行「重新选择图片」
    if (indexPath.section == FMSectionDotIcon) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"DotIconCell"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"DotIconCell"];
        }
        if (indexPath.row == DotIconRowSource) {
            cell.textLabel.text = @"图标来源";
            cell.detailTextLabel.text = [self dotIconModeTitle];
            cell.accessoryType = UITableViewCellAccessoryNone;
        } else {
            cell.textLabel.text = @"重新选择图片";
            cell.detailTextLabel.text = @"";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        return cell;
    }

    // 「颜色」：四行颜色，点按弹出取色（预设 + 手动十六进制）
    if (indexPath.section == FMSectionColors) {
        NSDictionary *spec = FMColorSpecs()[indexPath.row];
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ColorCell"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"ColorCell"];
        }
        cell.textLabel.text = spec[@"title"];
        cell.detailTextLabel.text = [self colorHexForKey:spec[@"key"] defaultHex:spec[@"default"]];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    // 「暂停显示」：文本行（暂停文字 / 文字颜色）走 Value1 + 箭头，其余两行走滑块
    if (indexPath.section == FMSectionPause &&
        (indexPath.row == PauseRowText || indexPath.row == PauseRowColor)) {
        NSDictionary *spec = FMPauseSpecs()[indexPath.row];
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PauseTextCell"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"PauseTextCell"];
        }
        cell.textLabel.text = spec[@"title"];
        cell.detailTextLabel.text = (indexPath.row == PauseRowText)
            ? [self pauseText]
            : [self colorHexForKey:spec[@"key"] defaultHex:spec[@"default"]];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    // 「选项面板背景」：颜色 / 自定义图片走 Value1 + 箭头，透明度走下面的滑块
    if (indexPath.section == FMSectionPanelBg && indexPath.row != PanelBgRowAlpha) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PanelBgCell"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"PanelBgCell"];
        }
        if (indexPath.row == PanelBgRowColor) {
            NSString *hex = _config[kCfgPanelBgColor];
            cell.textLabel.text = @"背景颜色";
            cell.detailTextLabel.text = ([hex isKindOfClass:[NSString class]] && hex.length > 0) ? hex : @"跟随系统";
        } else {
            cell.textLabel.text = @"自定义背景图片";
            cell.detailTextLabel.text = ([self panelBgImageName].length > 0) ? @"已设置" : @"未设置";
        }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    // 滑块：位置-纵向位置 / 外观-圆点大小·菜单黑底透明度 / 菜单外观·暂停显示-表驱动多项
    TableViewCellWithSlider *cell = [tableView dequeueReusableCellWithIdentifier:@"SliderCell" forIndexPath:indexPath];
    cell.slideBar.continuous = YES;
    [cell.slideBar removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];

    SEL changedSelector = @selector(yRatioValueChanged:);
    if (indexPath.section == FMSectionAppearance) {
        changedSelector = (indexPath.row == AppearanceRowDotSize) ? @selector(dotSizeValueChanged:)
                                                                  : @selector(menuBgAlphaValueChanged:);
    } else if (indexPath.section == FMSectionMenuAppearance) {
        changedSelector = @selector(menuAppearanceSliderChanged:);
    } else if (indexPath.section == FMSectionPause) {
        changedSelector = @selector(pauseSliderChanged:);
    } else if (indexPath.section == FMSectionPanelBg) {
        changedSelector = @selector(panelBgAlphaValueChanged:);
    }
    [cell.slideBar addTarget:self action:changedSelector forControlEvents:UIControlEventValueChanged];
    [cell.slideBar addTarget:self action:@selector(sliderTouchUp:)
            forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];

    if (indexPath.section == FMSectionMenuAppearance) {
        // 表驱动：按钮大小 / 按钮间距 / 标签字号 / 图标圆内留白 / 圆点到菜单间距
        NSDictionary *spec = FMMenuAppearanceSpecs()[indexPath.row];
        float minV = [spec[@"min"] floatValue];
        float maxV = [spec[@"max"] floatValue];
        float value = _config[spec[@"key"]] ? [_config[spec[@"key"]] floatValue] : [spec[@"default"] floatValue];
        if (value < minV || value > maxV) value = [spec[@"default"] floatValue];
        cell.title.text = spec[@"title"];
        cell.slideBar.tag = indexPath.row;
        cell.slideBar.minimumValue = minV;
        cell.slideBar.maximumValue = maxV;
        cell.slideBar.value = value;
        cell.value.text = [NSString stringWithFormat:@"%.0f pt", value];
    } else if (indexPath.section == FMSectionAppearance && indexPath.row == AppearanceRowDotSize) {
        float dotSize = _config[kCfgDotSize] ? [_config[kCfgDotSize] floatValue] : kDotSizeDefault;
        if (dotSize < kDotSizeMin || dotSize > kDotSizeMax) dotSize = kDotSizeDefault;
        cell.title.text = @"圆点大小";
        cell.slideBar.minimumValue = kDotSizeMin;
        cell.slideBar.maximumValue = kDotSizeMax;
        cell.slideBar.value = dotSize;
        cell.value.text = [NSString stringWithFormat:@"%.0f pt", dotSize];
    } else if (indexPath.section == FMSectionAppearance) {
        float bgAlpha = _config[kCfgMenuBgAlpha] ? [_config[kCfgMenuBgAlpha] floatValue] : kMenuBgAlphaDefault;
        if (bgAlpha < 0.0f || bgAlpha > 1.0f) bgAlpha = kMenuBgAlphaDefault;
        cell.title.text = @"菜单黑底透明度";
        cell.slideBar.minimumValue = 0.0f;
        cell.slideBar.maximumValue = 1.0f;
        cell.slideBar.value = bgAlpha;
        cell.value.text = [NSString stringWithFormat:@"%.2f", bgAlpha];
    } else if (indexPath.section == FMSectionPause) {
        // 表驱动：文字字号 / 圆点变灰深度
        NSDictionary *spec = FMPauseSpecs()[indexPath.row];
        float minV = [spec[@"min"] floatValue];
        float maxV = [spec[@"max"] floatValue];
        float value = _config[spec[@"key"]] ? [_config[spec[@"key"]] floatValue] : [spec[@"default"] floatValue];
        if (value < minV || value > maxV) value = [spec[@"default"] floatValue];
        cell.title.text = spec[@"title"];
        cell.slideBar.tag = indexPath.row;
        cell.slideBar.minimumValue = minV;
        cell.slideBar.maximumValue = maxV;
        cell.slideBar.value = value;
        cell.value.text = (indexPath.row == PauseRowGray)
            ? [NSString stringWithFormat:@"%.2f", value]
            : [NSString stringWithFormat:@"%.0f pt", value];
    } else if (indexPath.section == FMSectionPanelBg) {
        float alpha = _config[kCfgPanelBgAlpha] ? [_config[kCfgPanelBgAlpha] floatValue] : kPanelBgAlphaDefault;
        if (alpha < 0.0f || alpha > 1.0f) alpha = kPanelBgAlphaDefault;
        cell.title.text = @"背景透明度";
        cell.slideBar.minimumValue = 0.0f;
        cell.slideBar.maximumValue = 1.0f;
        cell.slideBar.value = alpha;
        cell.value.text = [NSString stringWithFormat:@"%.2f", alpha];
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

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == FMSectionDotIcon) {
        if (indexPath.row == DotIconRowSource) {
            [self cycleDotIconMode];
        } else {
            [self presentDotIconPicker];
        }
    } else if (indexPath.section == FMSectionColors) {
        [self pickColorAtIndexPath:indexPath];
    } else if (indexPath.section == FMSectionPause) {
        if (indexPath.row == PauseRowText) {
            [self presentPauseTextEditor];
        } else if (indexPath.row == PauseRowColor) {
            [self pickPauseTextColorAtIndexPath:indexPath];
        }
    } else if (indexPath.section == FMSectionPanelBg) {
        if (indexPath.row == PanelBgRowColor) {
            [self pickPanelBgColorAtIndexPath:indexPath];
        } else if (indexPath.row == PanelBgRowImage) {
            [self panelBgImageTapped:indexPath];
        }
    }
}

@end
