//
//  NetSpeedConfigurationViewController.h
//  zxtouch
//
//  网速指示器设置详情页（位置 / 字号 / 边距 / 息屏暂停）
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface NetSpeedConfigurationViewController : UIViewController<UITableViewDelegate, UITableViewDataSource>
@property (strong, nonatomic) UITableView *tableView;

@end

NS_ASSUME_NONNULL_END
