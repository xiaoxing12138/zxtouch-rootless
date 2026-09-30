//
//  TouchIndicatorConfigurationViewController.m
//  zxtouch
//
//  Created by Jason on 2021/1/19.
//

#import "TouchIndicatorConfigurationViewController.h"
#import "TableViewCellWithSwitch.h"
#import "TableViewCellWithSlider.h"
#import "Config.h"
#import "Util.h"
#import "Socket.h"

// 触摸圆点直径（pt）允许范围与默认值，需与 tweak 端 INDICATOR_VIEW_DEFAULT_SIZE 保持一致
#define TOUCH_INDICATOR_DOT_SIZE_MIN 8
#define TOUCH_INDICATOR_DOT_SIZE_MAX 80
#define TOUCH_INDICATOR_DOT_SIZE_DEFAULT 60

@interface TouchIndicatorConfigurationViewController ()

@end

@implementation TouchIndicatorConfigurationViewController
{
    NSArray *colorStrs;
    NSArray *colors;
    BOOL isShowing;
    NSMutableDictionary *config;
    Socket *springBoardSocket;
}

- (NSMutableDictionary *)defaultTouchIndicatorConfig {
    return [@{
        @"show": @(NO),
        @"show_coordinates": @(YES),
        @"dot_size": @(TOUCH_INDICATOR_DOT_SIZE_DEFAULT),
        @"color": [@{
            @"alpha": @(TOUCH_INDICATOR_DEFAULT_ALPHA),
            @"r": @(255),
            @"g": @(0),
            @"b": @(0)
        } mutableCopy]
    } mutableCopy];
}

- (void)loadConfig {
    config = [NSMutableDictionary dictionaryWithContentsOfFile:SPRINGBOARD_CONFIG_PATH];
    if (!config) config = [NSMutableDictionary dictionary];

    NSDictionary *existingTouchConfig = config[@"touch_indicator"];
    NSMutableDictionary *touchConfig = [existingTouchConfig isKindOfClass:[NSDictionary class]] ? [existingTouchConfig mutableCopy] : [self defaultTouchIndicatorConfig];

    NSDictionary *existingColorConfig = touchConfig[@"color"];
    NSMutableDictionary *colorConfig = [existingColorConfig isKindOfClass:[NSDictionary class]] ? [existingColorConfig mutableCopy] : [NSMutableDictionary dictionary];
    if (!colorConfig[@"alpha"]) colorConfig[@"alpha"] = @(TOUCH_INDICATOR_DEFAULT_ALPHA);
    if (!colorConfig[@"r"]) colorConfig[@"r"] = @(255);
    if (!colorConfig[@"g"]) colorConfig[@"g"] = @(0);
    if (!colorConfig[@"b"]) colorConfig[@"b"] = @(0);

    if (!touchConfig[@"show"]) touchConfig[@"show"] = @(NO);
    if (!touchConfig[@"show_coordinates"]) touchConfig[@"show_coordinates"] = @(YES);
    if (!touchConfig[@"dot_size"]) touchConfig[@"dot_size"] = @(TOUCH_INDICATOR_DOT_SIZE_DEFAULT);
    touchConfig[@"color"] = colorConfig;
    config[@"touch_indicator"] = touchConfig;
    isShowing = [touchConfig[@"show"] boolValue];

    [config writeToFile:SPRINGBOARD_CONFIG_PATH atomically:YES];
}

- (NSMutableDictionary *)touchIndicatorConfig {
    NSMutableDictionary *touchConfig = config[@"touch_indicator"];
    if (![touchConfig isKindOfClass:[NSMutableDictionary class]]) {
        [self loadConfig];
        touchConfig = config[@"touch_indicator"];
    }
    return touchConfig;
}

- (void)saveConfigAndReloadIndicator:(BOOL)reload {
    if (![config writeToFile:SPRINGBOARD_CONFIG_PATH atomically:YES]) {
        [Util showAlertBoxWithOneOption:self title:@"错误" message:@"无法保存触摸指示器设置。" buttonString:@"确定"];
        return;
    }
    if (reload && isShowing) {
        [springBoardSocket send:@"262\r\n"];
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view from its nib.
    self.title = @"触摸指示器";
    
    colorStrs = @[@"红色", @"蓝色", @"绿色", @"白色", @"黑色", @"橙色", @"黄色"];
    colors = @[[UIColor redColor], [UIColor blueColor], [UIColor greenColor], [UIColor whiteColor], [UIColor blackColor], [UIColor orangeColor], [UIColor yellowColor]];
    
    UINib *SwitchCellNib = [UINib nibWithNibName:@"TableViewCellWithSwitch" bundle:nil];
    [_tableView registerNib:SwitchCellNib forCellReuseIdentifier:@"SwitchCell"];
    
    UINib *sliderCellNib = [UINib nibWithNibName:@"TableViewCellWithSlider" bundle:nil];
    [_tableView registerNib:sliderCellNib forCellReuseIdentifier:@"SliderCell"];
    
    [self loadConfig];
    
    springBoardSocket = [[Socket alloc] init];
    [springBoardSocket connect:@"127.0.0.1" byPort:6000];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadConfig];
    [_tableView reloadData];
}

- (void)switchCoordinatesStatus:(id)sender {
    UISwitch *s = (UISwitch*)sender;
    [self touchIndicatorConfig][@"show_coordinates"] = @([s isOn]);
    [self saveConfigAndReloadIndicator:YES];
}

- (void)alphaValueChanged:(id)sender {
    UISlider *slider = (UISlider*)sender;
    float interval = 0.1f;//set this
    [slider setValue:interval*floorf((slider.value/interval)+0.5f) animated:NO];
    
    if (!config)
    {
        [Util showAlertBoxWithOneOption:self title:@"错误" message:@"错误：配置文件不存在。请进入\"设置 - 修复配置\"修复此问题。" buttonString:@"确定"];
        return;
    }
    
    NSMutableDictionary *colorConfig = [self touchIndicatorConfig][@"color"];
    colorConfig[@"alpha"] = @(slider.value);
    [self saveConfigAndReloadIndicator:YES];
}

- (NSInteger)clampedDotSizeFromSlider:(UISlider *)slider {
    NSInteger dotSize = (NSInteger)(slider.value + 0.5f);
    if (dotSize < TOUCH_INDICATOR_DOT_SIZE_MIN) dotSize = TOUCH_INDICATOR_DOT_SIZE_MIN;
    if (dotSize > TOUCH_INDICATOR_DOT_SIZE_MAX) dotSize = TOUCH_INDICATOR_DOT_SIZE_MAX;
    return dotSize;
}

- (void)dotSizeValueChanged:(id)sender {
    @try {
        UISlider *slider = (UISlider *)sender;
        NSInteger dotSize = [self clampedDotSizeFromSlider:slider];
        [slider setValue:(float)dotSize animated:NO];

        // 实时显示「圆点大小：XX pt」
        UIView *view = slider;
        while (view && ![view isKindOfClass:[TableViewCellWithSlider class]]) {
            view = view.superview;
        }
        if ([view isKindOfClass:[TableViewCellWithSlider class]]) {
            ((TableViewCellWithSlider *)view).value.text = [NSString stringWithFormat:@"%ld pt", (long)dotSize];
        }

        if (!config)
        {
            [Util showAlertBoxWithOneOption:self title:@"错误" message:@"错误：配置文件不存在。请进入\"设置 - 修复配置\"修复此问题。" buttonString:@"确定"];
            return;
        }

        // 拖动过程中只写配置 plist，松手时才发 socket reload，避免频繁发指令
        [self touchIndicatorConfig][@"dot_size"] = @(dotSize);
        if (![config writeToFile:SPRINGBOARD_CONFIG_PATH atomically:YES])
        {
            [Util showAlertBoxWithOneOption:self title:@"错误" message:@"无法保存圆点大小设置。" buttonString:@"确定"];
        }
    }
    @catch (NSException *exception) {
        NSLog(@"dotSizeValueChanged exception: %@", exception);
    }
}

- (void)dotSizeSliderTouchUp:(id)sender {
    @try {
        // 松手时按现有「改配置后 reload」的方式让 tweak 立即生效（262;;reload）
        [self saveConfigAndReloadIndicator:YES];
    }
    @catch (NSException *exception) {
        NSLog(@"dotSizeSliderTouchUp exception: %@", exception);
    }
}

- (void)switchTouchIndicatorStatus:(id)sender {
    UISwitch *s = (UISwitch*)sender;

    if (!config)
    {
        [Util showAlertBoxWithOneOption:self title:@"错误" message:@"错误：配置文件不存在。请进入\"设置 - 修复配置\"修复此问题。" buttonString:@"确定"];
    }
    
    // restart touch indicator if touch indicator is on
    if ([s isOn])
    {
        if (config)
            [self touchIndicatorConfig][@"show"] = @(YES);

        // turn on
        [springBoardSocket send:@"261\r\n"];
        
        isShowing = true;
    }
    else
    {
        if (config)
            [self touchIndicatorConfig][@"show"] = @(NO);

        // turn off
        [springBoardSocket send:@"260\r\n"];
        
        isShowing = false;
    }

    if (![config writeToFile:SPRINGBOARD_CONFIG_PATH atomically:YES])
    {
        [Util showAlertBoxWithOneOption:self title:@"错误" message:@"操作虽已成功，但无法写入配置文件。" buttonString:@"确定"];
    }
     
}

//配置每个section(段）有多少row（行） cell
//默认只有一个section
-(NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{
    if (!config)
    {
        return 1;
    }
    return 4;  // show toggle, coordinates toggle, alpha slider, dot size slider
}

-(NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}

//每行显示什么东西
-(UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath{

    UITableViewCell *result;
    
    if (!config)
    {
        [Util showAlertBoxWithOneOption:self title:@"错误" message:@"错误：配置文件不存在。请进入\"设置 - 修复配置\"修复此问题。" buttonString:@"确定"];
    }
    
    if (indexPath.row == 0)
    {
        static NSString *cellID = @"SwitchCell";

        TableViewCellWithSwitch *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
        
        //判断队列里面是否有这个cell 没有自己创建，有直接使用
        if (cell == nil) {
            //没有,创建一个
            NSLog(@"create a setting cell switch");
            cell = [[TableViewCellWithSwitch alloc]initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellID];
        }
        
        [cell setTitleText:@"触摸指示器"];

        [cell.switchBtn removeTarget:nil action:NULL forControlEvents:UIControlEventValueChanged];
        [cell.switchBtn addTarget:self action:@selector(switchTouchIndicatorStatus:) forControlEvents:UIControlEventValueChanged];
        
        if ([[self touchIndicatorConfig][@"show"] boolValue])
        {
            [cell.switchBtn setOn:YES];
        }
        else
        {
            [cell.switchBtn setOn:NO];
        }
        
        result = cell;
    }
    else if (indexPath.row == 1)
    {
        TableViewCellWithSwitch *cell = [tableView dequeueReusableCellWithIdentifier:@"SwitchCell"];
        if (cell == nil) {
            cell = [[TableViewCellWithSwitch alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"SwitchCell"];
        }
        [cell setTitleText:@"显示坐标"];
        [cell.switchBtn removeTarget:nil action:NULL forControlEvents:UIControlEventValueChanged];
        [cell.switchBtn addTarget:self action:@selector(switchCoordinatesStatus:) forControlEvents:UIControlEventValueChanged];
        BOOL showCoords = [[self touchIndicatorConfig][@"show_coordinates"] boolValue];
        [cell.switchBtn setOn:showCoords];
        result = cell;
    }
    else if (indexPath.row == 2)
    {
        TableViewCellWithSlider *cell = [tableView dequeueReusableCellWithIdentifier:@"SliderCell"];
        
        //判断队列里面是否有这个cell 没有自己创建，有直接使用
        if (cell == nil) {
            //没有,创建一个
            NSLog(@"create a setting cell switch");
            cell = [[TableViewCellWithSlider alloc]initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"SliderCell"];
        }
        
        cell.title.text = @"不透明度";
        cell.slideBar.maximumValue = 1.0f;
        cell.slideBar.minimumValue = 0.0f;
        cell.slideBar.continuous = YES;
        [cell.slideBar removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
        [cell.slideBar addTarget:self
              action:@selector(alphaValueChanged:)
              forControlEvents:UIControlEventValueChanged];
        
        cell.slideBar.value = [[self touchIndicatorConfig][@"color"][@"alpha"] floatValue];
        cell.value.text = [NSString stringWithFormat:@"%.1f", cell.slideBar.value];

        result = cell;
    }
    else if (indexPath.row == 3)
    {
        TableViewCellWithSlider *cell = [tableView dequeueReusableCellWithIdentifier:@"SliderCell"];

        //判断队列里面是否有这个cell 没有自己创建，有直接使用
        if (cell == nil) {
            //没有,创建一个
            cell = [[TableViewCellWithSlider alloc]initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"SliderCell"];
        }

        cell.title.text = @"圆点大小";
        cell.slideBar.minimumValue = TOUCH_INDICATOR_DOT_SIZE_MIN;
        cell.slideBar.maximumValue = TOUCH_INDICATOR_DOT_SIZE_MAX;
        cell.slideBar.continuous = YES;
        [cell.slideBar removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
        // 拖动过程中实时写 plist 并刷新数值，松手时发 socket 让 tweak reload
        [cell.slideBar addTarget:self
                          action:@selector(dotSizeValueChanged:)
                forControlEvents:UIControlEventValueChanged];
        [cell.slideBar addTarget:self
                          action:@selector(dotSizeSliderTouchUp:)
                forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];

        NSInteger dotSize = [[self touchIndicatorConfig][@"dot_size"] integerValue];
        if (dotSize < TOUCH_INDICATOR_DOT_SIZE_MIN) dotSize = TOUCH_INDICATOR_DOT_SIZE_MIN;
        if (dotSize > TOUCH_INDICATOR_DOT_SIZE_MAX) dotSize = TOUCH_INDICATOR_DOT_SIZE_MAX;
        cell.slideBar.value = (float)dotSize;
        cell.value.text = [NSString stringWithFormat:@"%ld pt", (long)dotSize];

        result = cell;
    }
    result.selectionStyle = UITableViewCellSelectionStyleNone;

    return result;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath{
    //[tableView deselectRowAtIndexPath:indexPath animated:NO];
}

// Override to support editing the table view.
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {

}

- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)thePickerView {
     return 1;  // Or return whatever as you intend
}

- (NSInteger)pickerView:(UIPickerView *)thePickerView
numberOfRowsInComponent:(NSInteger)component {
     return colors.count;//Or, return as suitable for you...normally we use array for dynamic
}

- (NSString *)pickerView:(UIPickerView *)thePickerView
             titleForRow:(NSInteger)row forComponent:(NSInteger)component {
     return colorStrs[row];//Or, your suitable title; like Choice-a, etc.
}

- (void)pickerView:(UIPickerView *)pickerView didSelectRow:(NSInteger)row inComponent:(NSInteger)component {
    // write to configuration file

    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;

    [colors[row] getRed:&red green:&green blue:&blue alpha:&alpha];

    NSMutableDictionary *colorConfig = [self touchIndicatorConfig][@"color"];
    colorConfig[@"r"] = @(red*255);
    colorConfig[@"g"] = @(green*255);
    colorConfig[@"b"] = @(blue*255);
        
    if (![config writeToFile:SPRINGBOARD_CONFIG_PATH atomically:YES])
    {
        [Util showAlertBoxWithOneOption:self title:@"错误" message:@"无法设置颜色：不能写入配置文件。" buttonString:@"确定"];
        return;
    }

    
    // restart touch indicator if touch indicator is on
    if (isShowing)
    {
        [springBoardSocket send:@"262\r\n"]; // reload config
    }

}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
   return NO;
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
