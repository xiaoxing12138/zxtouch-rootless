//
//  DebugFloatWindowViewController.m
//  zxtouch
//
//  悬浮窗调试信息页面 —— 通过 socket 命令 40 实时查询 SpringBoard 端
//  两个悬浮窗（网速窗 + 悬浮控制按钮）的位置、尺寸、方向、窗口状态等。
//

#import "DebugFloatWindowViewController.h"
#import "Socket.h"

@interface DebugFloatWindowViewController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<NSMutableArray<NSDictionary *> *> *sections; // 两个 section，每个 section 是可变的 key-value 行数组
@property (nonatomic, strong) UILabel *statusLabel;      // 顶部状态提示（"上次刷新时间 / 刷新失败"）
@property (nonatomic, strong) UISwitch *autoRefreshSwitch;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, strong) NSDictionary *lastRawJSON; // 缓存最后一次原始 JSON，用于复制

@end

@implementation DebugFloatWindowViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"悬浮窗调试";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    _sections = [NSMutableArray arrayWithObjects:[NSMutableArray array], [NSMutableArray array], nil];
    _lastRawJSON = nil;

    // 顶部工具栏
    UIView *toolbar = [[UIView alloc] init];
    toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    toolbar.backgroundColor = [UIColor systemBackgroundColor];
    [self.view addSubview:toolbar];

    UILabel *autoLabel = [[UILabel alloc] init];
    autoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    autoLabel.text = @"自动刷新";
    autoLabel.font = [UIFont systemFontOfSize:14];
    [toolbar addSubview:autoLabel];

    _autoRefreshSwitch = [[UISwitch alloc] init];
    _autoRefreshSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    _autoRefreshSwitch.onTintColor = [UIColor systemBlueColor];
    [_autoRefreshSwitch addTarget:self action:@selector(autoRefreshChanged:) forControlEvents:UIControlEventValueChanged];
    [toolbar addSubview:_autoRefreshSwitch];

    UIButton *refreshBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    refreshBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [refreshBtn setTitle:@"立即刷新" forState:UIControlStateNormal];
    [refreshBtn addTarget:self action:@selector(handleRefresh) forControlEvents:UIControlEventTouchUpInside];
    [toolbar addSubview:refreshBtn];

    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    copyBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [copyBtn setTitle:@"复制JSON" forState:UIControlStateNormal];
    [copyBtn addTarget:self action:@selector(handleCopy) forControlEvents:UIControlEventTouchUpInside];
    [toolbar addSubview:copyBtn];

    _statusLabel = [[UILabel alloc] init];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.font = [UIFont systemFontOfSize:12];
    _statusLabel.textColor = [UIColor secondaryLabelColor];
    _statusLabel.text = @"未连接";
    [toolbar addSubview:_statusLabel];

    // 工具栏约束
    [NSLayoutConstraint activateConstraints:@[
        [toolbar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [toolbar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [toolbar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [toolbar.heightAnchor constraintEqualToConstant:96],

        [autoLabel.topAnchor constraintEqualToAnchor:toolbar.topAnchor constant:12],
        [autoLabel.leadingAnchor constraintEqualToAnchor:toolbar.leadingAnchor constant:16],

        [_autoRefreshSwitch.centerYAnchor constraintEqualToAnchor:autoLabel.centerYAnchor],
        [_autoRefreshSwitch.leadingAnchor constraintEqualToAnchor:autoLabel.trailingAnchor constant:8],

        [refreshBtn.centerYAnchor constraintEqualToAnchor:autoLabel.centerYAnchor],
        [refreshBtn.trailingAnchor constraintEqualToAnchor:toolbar.trailingAnchor constant:-16],

        [copyBtn.centerYAnchor constraintEqualToAnchor:autoLabel.centerYAnchor],
        [copyBtn.trailingAnchor constraintEqualToAnchor:refreshBtn.leadingAnchor constant:-8],

        [_statusLabel.topAnchor constraintEqualToAnchor:autoLabel.bottomAnchor constant:10],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:toolbar.leadingAnchor constant:16],
        [_statusLabel.trailingAnchor constraintEqualToAnchor:toolbar.trailingAnchor constant:-16],
    ]];

    // 表格
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    _tableView.tableFooterView = [[UIView alloc] init];
    [self.view addSubview:_tableView];

    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:toolbar.bottomAnchor],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self handleRefresh];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_refreshTimer invalidate];
    _refreshTimer = nil;
}

#pragma mark - 刷新逻辑

- (void)autoRefreshChanged:(UISwitch *)s {
    if (s.isOn) {
        [self startAutoRefresh];
    } else {
        [self stopAutoRefresh];
    }
}

- (void)startAutoRefresh {
    [_refreshTimer invalidate];
    _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(handleRefresh) userInfo:nil repeats:YES];
}

- (void)stopAutoRefresh {
    [_refreshTimer invalidate];
    _refreshTimer = nil;
}

- (void)handleRefresh {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSDictionary *result = [self queryDebugInfo];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!result) {
                self->_statusLabel.text = @"连接 SpringBoard 失败，确认插件已加载";
                self->_statusLabel.textColor = [UIColor systemRedColor];
                return;
            }
            self->_lastRawJSON = result;
            self->_statusLabel.text = [NSString stringWithFormat:@"已刷新 %@", [self nowString]];
            self->_statusLabel.textColor = [UIColor secondaryLabelColor];
            [self rebuildSectionsFromJSON:result];
            [self.tableView reloadData];
        });
    });
}

- (void)handleCopy {
    if (!_lastRawJSON) {
        [self toast:@"暂无数据"];
        return;
    }
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:_lastRawJSON options:NSJSONWritingPrettyPrinted error:&err];
    if (err || !data) {
        [self toast:@"序列化失败"];
        return;
    }
    NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    UIPasteboard.generalPasteboard.string = str;
    [self toast:@"已复制到剪贴板"];
}

- (NSString *)nowString {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm:ss";
    });
    return [fmt stringFromDate:[NSDate date]];
}

- (void)toast:(NSString *)msg {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:msg preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [alert dismissViewControllerAnimated:YES completion:nil];
    });
}

#pragma mark - Socket 查询

- (NSDictionary *)queryDebugInfo {
    Socket *socket = [[Socket alloc] init];
    if ([socket connect:@"127.0.0.1" byPort:6000] != 0) {
        [socket close];
        return nil;
    }
    [socket send:@"40;;all\r\n"];
    NSString *raw = [socket recv:8192];
    [socket close];

    if (!raw || raw.length == 0) {
        return nil;
    }
    // 去掉末尾 \r\n
    NSString *jsonStr = raw;
    if ([jsonStr hasSuffix:@"\r\n"]) {
        jsonStr = [jsonStr substringToIndex:jsonStr.length - 2];
    }
    if ([jsonStr hasPrefix:@"-1;;"]) {
        return nil;
    }
    NSError *err = nil;
    NSData *data = [jsonStr dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data] options:0 error:&err];
    if (err || ![dict isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    return dict;
}

#pragma mark - 数据格式化

- (void)rebuildSectionsFromJSON:(NSDictionary *)json {
    [_sections[0] removeAllObjects];
    [_sections[1] removeAllObjects];

    NSDictionary *ns = json[@"net_speed"];
    NSDictionary *fm = json[@"floating_menu"];

    if ([ns isKindOfClass:[NSDictionary class]]) {
        [_sections[0] addObjectsFromArray:[self netSpeedRows:ns]];
    } else {
        [_sections[0] addObject:@{@"k": @"状态", @"v": @"未开启 / 未创建"}];
    }

    if ([fm isKindOfClass:[NSDictionary class]]) {
        [_sections[1] addObjectsFromArray:[self floatingMenuRows:fm]];
    } else {
        [_sections[1] addObject:@{@"k": @"状态", @"v": @"未开启 / 未创建"}];
    }
}

- (NSString *)orientationName:(NSDictionary *)dict {
    NSString *name = dict[@"orientation_name"];
    if (name.length > 0) return name;
    id o = dict[@"orientation"];
    if ([o respondsToSelector:@selector(integerValue)]) {
        int v = [o integerValue];
        switch (v) {
            case 1: return @"Portrait";
            case 2: return @"PortraitUpsideDown";
            case 3: return @"LandscapeLeft";
            case 4: return @"LandscapeRight";
            default: return [NSString stringWithFormat:@"unknown(%d)", v];
        }
    }
    return @"-";
}

- (NSArray<NSDictionary *> *)netSpeedRows:(NSDictionary *)d {
    NSMutableArray *rows = [NSMutableArray array];

    [rows addObject:@{@"k": @"启用", @"v": [self boolText:d[@"enabled"]]}];
    [rows addObject:@{@"k": @"屏幕方向", @"v": [self orientationName:d]}];
    [rows addObject:@{@"k": @"屏幕分辨率", @"v": [NSString stringWithFormat:@"%@ × %@ pt",
                                                    d[@"screen_bounds_w"] ?: @"?",
                                                    d[@"screen_bounds_h"] ?: @"?"]}];
    [rows addObject:@{@"k": @"画布(w/h)", @"v": [NSString stringWithFormat:@"%@ × %@",
                                                  d[@"canvas_w"] ?: @"?",
                                                  d[@"canvas_h"] ?: @"?"]}];
    [rows addObject:@{@"k": @"配置角点", @"v": [self cornerName:[d[@"cfg_corner"] integerValue]]}];
    [rows addObject:@{@"k": @"水平边距", @"v": [NSString stringWithFormat:@"%@ pt", d[@"cfg_margin_x"] ?: @"?"]}];
    [rows addObject:@{@"k": @"垂直边距", @"v": [NSString stringWithFormat:@"%@ pt", d[@"cfg_margin_y"] ?: @"?"]}];
    [rows addObject:@{@"k": @"字号", @"v": [NSString stringWithFormat:@"%@", d[@"cfg_font_size"] ?: @"?"]}];

    if (![d[@"window_exists"] boolValue]) {
        [rows addObject:@{@"k": @"—", @"v": d[@"note"] ?: @"window 未创建"}];
        return rows;
    }

    [rows addObject:@{@"k": @"window hidden", @"v": [self boolText:d[@"window_hidden"]]}];
    [rows addObject:@{@"k": @"window frame", @"v": [NSString stringWithFormat:@"(%@, %@, %@, %@)",
                                                     d[@"window_frame_x"] ?: @"?", d[@"window_frame_y"] ?: @"?",
                                                     d[@"window_frame_w"] ?: @"?", d[@"window_frame_h"] ?: @"?"]}];
    [rows addObject:@{@"k": @"content 变换", @"v": [self matrixText:d prefix:@"content_transform_"]}];
    [rows addObject:@{@"k": @"content bounds", @"v": [NSString stringWithFormat:@"%@ × %@",
                                                       d[@"content_bounds_w"] ?: @"?",
                                                       d[@"content_bounds_h"] ?: @"?"]}];
    [rows addObject:@{@"k": @"label frame", @"v": [NSString stringWithFormat:@"(%@, %@, %@, %@)",
                                                    d[@"label_frame_x"] ?: @"?", d[@"label_frame_y"] ?: @"?",
                                                    d[@"label_frame_w"] ?: @"?", d[@"label_frame_h"] ?: @"?"]}];
    [rows addObject:@{@"k": @"label 变换", @"v": [self matrixText:d prefix:@"label_transform_"]}];
    [rows addObject:@{@"k": @"label center(窗口坐标)", @"v": [NSString stringWithFormat:@"(%@, %@)",
                                                               d[@"label_center_x_in_window"] ?: @"?",
                                                               d[@"label_center_y_in_window"] ?: @"?"]}];
    [rows addObject:@{@"k": @"文字", @"v": d[@"label_text"] ?: @"-"}];

    return rows;
}

- (NSArray<NSDictionary *> *)floatingMenuRows:(NSDictionary *)d {
    NSMutableArray *rows = [NSMutableArray array];

    [rows addObject:@{@"k": @"启用", @"v": [self boolText:d[@"enabled"]]}];
    [rows addObject:@{@"k": @"展开状态", @"v": [self boolText:d[@"expanded"]]}];
    [rows addObject:@{@"k": @"吸附边", @"v": d[@"edge_name"] ?: @"?"}];
    [rows addObject:@{@"k": @"纵向比例", @"v": [NSString stringWithFormat:@"%@", d[@"y_ratio"] ?: @"?"]}];
    [rows addObject:@{@"k": @"上一次方向", @"v": [self orientationNameFromInt:d[@"last_orientation"]]}];
    [rows addObject:@{@"k": @"视觉尺寸", @"v": [NSString stringWithFormat:@"%@ × %@",
                                                 d[@"visual_w"] ?: @"?",
                                                 d[@"visual_h"] ?: @"?"]}];
    [rows addObject:@{@"k": @"圆点视觉坐标", @"v": [NSString stringWithFormat:@"(%@, %@)",
                                                    d[@"dot_visual_x"] ?: @"?",
                                                    d[@"dot_visual_y"] ?: @"?"]}];

    if (![d[@"window_exists"] boolValue]) {
        [rows addObject:@{@"k": @"—", @"v": d[@"note"] ?: @"window 未创建"}];
        return rows;
    }

    [rows addObject:@{@"k": @"window hidden", @"v": [self boolText:d[@"window_hidden"]]}];
    [rows addObject:@{@"k": @"window frame", @"v": [NSString stringWithFormat:@"(%@, %@, %@, %@)",
                                                     d[@"window_frame_x"] ?: @"?", d[@"window_frame_y"] ?: @"?",
                                                     d[@"window_frame_w"] ?: @"?", d[@"window_frame_h"] ?: @"?"]}];
    [rows addObject:@{@"k": @"content 变换", @"v": [self matrixText:d prefix:@"content_transform_"]}];
    [rows addObject:@{@"k": @"content bounds", @"v": [NSString stringWithFormat:@"%@ × %@",
                                                       d[@"content_bounds_w"] ?: @"?",
                                                       d[@"content_bounds_h"] ?: @"?"]}];
    [rows addObject:@{@"k": @"圆点 frame", @"v": [NSString stringWithFormat:@"(%@, %@, %@, %@)",
                                                   d[@"dot_frame_x"] ?: @"?", d[@"dot_frame_y"] ?: @"?",
                                                   d[@"dot_frame_w"] ?: @"?", d[@"dot_frame_h"] ?: @"?"]}];
    [rows addObject:@{@"k": @"圆点 center(rootView)", @"v": [NSString stringWithFormat:@"(%@, %@)",
                                                             d[@"dot_center_in_root_x"] ?: @"?",
                                                             d[@"dot_center_in_root_y"] ?: @"?"]}];
    [rows addObject:@{@"k": @"圆点 center(window)", @"v": [NSString stringWithFormat:@"(%@, %@)",
                                                           d[@"dot_center_in_window_x"] ?: @"?",
                                                           d[@"dot_center_in_window_y"] ?: @"?"]}];

    return rows;
}

- (NSString *)boolText:(id)val {
    if ([val respondsToSelector:@selector(boolValue)]) {
        return [val boolValue] ? @"是" : @"否";
    }
    return val ?: @"-";
}

- (NSString *)cornerName:(int)c {
    switch (c) {
        case 0: return @"右上";
        case 1: return @"左上";
        case 2: return @"左下";
        case 3: return @"右下";
        default: return [NSString stringWithFormat:@"?(%d)", c];
    }
}

- (NSString *)orientationNameFromInt:(id)val {
    if (![val respondsToSelector:@selector(integerValue)]) return @"-";
    int v = [val integerValue];
    switch (v) {
        case 1: return @"Portrait";
        case 2: return @"PortraitUpsideDown";
        case 3: return @"LandscapeLeft";
        case 4: return @"LandscapeRight";
        default: return [NSString stringWithFormat:@"unknown(%d)", v];
    }
}

- (NSString *)matrixText:(NSDictionary *)d prefix:(NSString *)prefix {
    id a = d[[prefix stringByAppendingString:@"a"]] ?: @"-";
    id b = d[[prefix stringByAppendingString:@"b"]] ?: @"-";
    id c = d[[prefix stringByAppendingString:@"c"]] ?: @"-";
    id d2 = d[[prefix stringByAppendingString:@"d"]] ?: @"-";
    return [NSString stringWithFormat:@"[%@, %@; %@, %@]", a, b, c, d2];
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"网速悬浮窗" : @"悬浮控制按钮";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _sections[section].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"DebugCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cellID];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    NSDictionary *row = _sections[indexPath.section][indexPath.row];
    cell.textLabel.text = row[@"k"];
    cell.detailTextLabel.text = row[@"v"];
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByWordWrapping;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    cell.textLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self tableView:tableView cellForRowAtIndexPath:indexPath];
    NSDictionary *row = _sections[indexPath.section][indexPath.row];
    NSString *val = row[@"v"] ?: @"";
    // 估算 detail 高度
    CGFloat maxDetailW = tableView.bounds.size.width - 160;
    if (maxDetailW <= 0) maxDetailW = 200;
    CGSize sz = [val boundingRectWithSize:CGSizeMake(maxDetailW, CGFLOAT_MAX)
                                   options:NSStringDrawingUsesLineFragmentOrigin
                                attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:12]}
                                   context:nil].size;
    return MAX(44, ceil(sz.height) + 16);
}

@end
