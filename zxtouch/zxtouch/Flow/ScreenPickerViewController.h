//
//  ScreenPickerViewController.h
//  小新Lap 可视化脚本
//
//  从设备上抓一张屏幕截图，摆正后铺满屏幕，让用户在图上点坐标 / 框区域 / 取颜色。
//
//  为什么能直接读到屏幕内容：App 通过 127.0.0.1:6000 向引擎要「未转正的原始竖屏帧」，
//  自己按当前方向把图转成用户看到的样子。转正之后的像素坐标就是「触摸指示器」坐标，
//  所以用户点哪儿，脚本里就写哪儿，不需要任何换算。
//
//  识图模板则相反：框选用的是转正后的图，但存盘要按原始竖屏帧抠出来，
//  这样引擎（永远拿竖屏帧做匹配）不用旋转、也不会有重采样损失。
//

#import <UIKit/UIKit.h>
#import "FlowScript.h"

NS_ASSUME_NONNULL_BEGIN

@interface ScreenPickerViewController : UIViewController

/// rect        ：指示器坐标下的点（宽高为 1）或区域
/// hexColor    ：仅 FlowPickModeColor，形如 "FF8800"
/// templateName：仅 FlowPickModeTemplate，已存好的模板文件名
- (instancetype)initWithMode:(FlowPickMode)mode
           suggestedTemplate:(nullable NSString *)templateName
                  completion:(void (^)(CGRect rect,
                                       NSString *_Nullable hexColor,
                                       NSString *_Nullable templateName))completion;

@end

NS_ASSUME_NONNULL_END
