#ifndef NET_SPEED_INDICATOR_H
#define NET_SPEED_INDICATOR_H

#import <UIKit/UIKit.h>

@interface NetSpeedIndicator : NSObject

+ (void)setEnabled:(BOOL)enabled;
+ (BOOL)isEnabled;
+ (void)reloadConfig;

@end

NSString *handleNetSpeedIndicatorTaskWithRawData(UInt8 *eventData, NSError **error);

#endif
