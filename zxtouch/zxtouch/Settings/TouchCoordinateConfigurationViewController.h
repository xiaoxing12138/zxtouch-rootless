//
//  TouchCoordinateConfigurationViewController.h
//  zxtouch
//
//  触摸坐标悬浮窗设置详情页（开关 / 位置 / 字号 / 边距 / 颜色 / 空闲隐藏 / 多点模式）
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TouchCoordinateConfigurationViewController : UIViewController<UITableViewDelegate, UITableViewDataSource>
@property (strong, nonatomic) UITableView *tableView;

@end

NS_ASSUME_NONNULL_END