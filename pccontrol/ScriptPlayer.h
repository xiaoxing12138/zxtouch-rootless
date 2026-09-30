#ifndef SCRIPT_PLAYER_H
#define SCRIPT_PLAYER_H

#import <Foundation/Foundation.h>

@interface ScriptPlayer : NSObject

- (void)setRepeatTime:(int)rt;
- (void)setInterval:(float)intv;
- (void)setSpeed:(float)sp;
- (void)setPath:(NSString*)path;
- (void)forceStop:(NSError**)error;
- (void)setSwitchApp:(BOOL)value;

- (id)initWithPath:(NSString*)path;

- (int)play:(NSError**)error;
- (BOOL)isPlaying;

// 暂停/继续：raw 脚本在播放循环里等待，py 脚本对整个进程组发 SIGSTOP/SIGCONT
- (BOOL)isPaused;
- (void)pause;
- (void)resume;
- (NSString*)getCurrentBundlePath;
- (int)getCompletedRuns;

@end

#endif
