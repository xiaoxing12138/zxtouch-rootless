#ifndef TEMPLATE_MATCH_H
#define TEMPLATE_MATCH_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface TemplateMatch : NSObject

// 最近一次匹配扫到的最高分（不论成功还是失败都有值），调用方拿它写日志
@property (nonatomic, readonly) float lastBestScore;

- (void)setAcceptableValue:(float)av;
- (void)setMaxTryTimes:(int)mtt;
- (void)setScaleRation:(float)sr;
- (CGRect)templateMatchWithCGImage:(CGImageRef)img templatePath:(NSString*)templatePath error:(NSError**)err;

@end

#endif
