//
//  ScriptListTableCell.h
//  zxtouch
//
//  Created by Jason on 2020/12/14.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ScriptListTableCell : UITableViewCell
@property (weak, nonatomic) IBOutlet UILabel *scriptTitle;
@property (weak, nonatomic) IBOutlet UIButton *playButton;
@property (strong, nonatomic) IBOutlet UIImageView *iconImage;
@property (weak, nonatomic) UIViewController* parentViewController;
@property (nonatomic, copy, nullable) void (^onLongPress)(void);
@property (nonatomic, copy, nullable) void (^onRowTap)(void);

- (void) setPropertyWithPath:(NSString*)path;

@end

NS_ASSUME_NONNULL_END
