#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZXImageCropViewController : UIViewController

@property (nonatomic, strong) UIImage *sourceImage;
@property (nonatomic, assign) BOOL circleMask;
@property (nonatomic, assign) CGFloat canvasAspect;
@property (nonatomic, assign) CGFloat outputMaxSide;
@property (nonatomic, copy, nullable) NSString *hintText;
@property (nonatomic, copy, nullable) void (^onFinish)(UIImage *cropped);
@property (nonatomic, copy, nullable) void (^onCancel)(void);

@end

NS_ASSUME_NONNULL_END
