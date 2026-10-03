//
//  Util.h
//  zxtouch
//
//  Created by Jason on 2021/1/16.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface Util : NSObject
+ (void)showAlertBoxWithOneOption:(UIViewController*)vc title:(NSString*)aTitle message:(NSString*)aMessage buttonString:(NSString*)aBts;
/// 给插件发一条命令（自动补 \r\n）并返回响应；连不上返回 nil
+ (NSString *)sendEngineCommand:(NSString*)command;
@end

NS_ASSUME_NONNULL_END
