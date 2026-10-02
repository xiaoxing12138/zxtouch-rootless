#ifndef TEMPLATE_MATCH_H
#define TEMPLATE_MATCH_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface TemplateMatch : NSObject

// 最近一次匹配扫到的最高分（不论成功还是失败都有值），调用方拿它写日志
@property (nonatomic, readonly) float lastBestScore;

// 最近一次匹配的分段耗时（毫秒），键：gray_ms / integral_ms / scan_ms，用 40;;perf 读回
+ (NSDictionary *)lastTiming;

- (void)setAcceptableValue:(float)av;
- (void)setMaxTryTimes:(int)mtt;
- (void)setScaleRation:(float)sr;
- (CGRect)templateMatchWithPixels:(const UInt8 *)pixels stride:(int)stride width:(size_t)imgW height:(size_t)imgH templatePath:(NSString*)templatePath error:(NSError**)err;

@end

#endif
