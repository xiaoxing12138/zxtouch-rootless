//
//  TouchIndicatorConfigurationViewController.h
//  zxtouch
//
//  Created by Jason on 2021/1/19.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// 触摸指示器 + 坐标悬浮窗合并设置页（tableView 全部由代码搭建，不再走 storyboard）
@interface TouchIndicatorConfigurationViewController : UIViewController<UITableViewDelegate, UITableViewDataSource>
@property (strong, nonatomic) UITableView *tableView;

@end

NS_ASSUME_NONNULL_END
