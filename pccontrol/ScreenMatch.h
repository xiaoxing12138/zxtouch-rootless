#ifndef SCREEN_MATCH_H
#define SCREEN_MATCH_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// outBestScore：传非空指针时，写回本次匹配扫到的最高分（成功失败都写）
CGRect screenMatchFromRawData(UInt8 *eventData, NSError **error, float *outBestScore);

@interface ScreenMatch : NSObject
+ (CGRect)matchCurrentScreenWithTemplate:(NSString*)templatePath maxTryTimes:(int)mtt acceptableValue:(float)av scaleRation:(float)sr error:(NSError**)err bestScore:(float*)outBestScore;
@end

#endif
