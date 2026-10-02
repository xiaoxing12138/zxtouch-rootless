#ifndef PLAY_H
#define PLAY_H

#import <Foundation/Foundation.h>

int playScript(UInt8* path, NSError** error);
int playScriptWithSettings(UInt8* path, int repeatTime, float playSpeed, float interval, NSError** error);
void playFromRawFile(NSString* filePath, NSString* foregroundApp, NSError **err);
void playFromPythonFile(NSString* filePath, NSString* foregroundApp, NSError **err);
void stopScriptPlaying(NSError **error);
BOOL isScriptPlaying();
BOOL isScriptPaused();
void pauseScriptPlaying();
void resumeScriptPlaying();
void playHasStoppedCallBack();
void initScriptPlayer();
// 当前正在播放的脚本包绝对路径；没在播放返回 nil。定时调度器靠它判断「该停谁」。
NSString* ZXCurrentScriptBundlePath();

#endif
