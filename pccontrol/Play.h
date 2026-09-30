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

#endif
