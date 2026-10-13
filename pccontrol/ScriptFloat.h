#ifndef SCRIPT_FLOAT_H
#define SCRIPT_FLOAT_H

#import <UIKit/UIKit.h>
#include <stdint.h>

#define ZX_SCRIPT_INJECT_FIELD 0xB00FF
#define ZX_SCRIPT_INJECT_VALUE 1

void ZXScriptInjectionNote(uint64_t timeStamp);
BOOL ZXEventIsScriptInjection(UIEvent *event);
BOOL ZXScriptFloatHitTestScreenPoint(CGPoint point);

@interface ScriptFloat : NSObject

+ (void)reloadConfig;
+ (NSDictionary *)ballConfigForScriptPath:(NSString *)scriptPath;
+ (void)setBallEnabled:(BOOL)enabled forScriptPath:(NSString *)scriptPath;
+ (void)setBallLocked:(BOOL)locked forScriptPath:(NSString *)scriptPath;
+ (void)setBallIconMode:(NSInteger)mode forScriptPath:(NSString *)scriptPath;
+ (void)refreshPlayState;

@end

#endif