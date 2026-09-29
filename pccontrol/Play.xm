#include "Play.h"
#include "SocketServer.h"
#include "Process.h"
#include "Task.h"
#include "AlertBox.h"
#include "Config.h"
#import "ScriptPlayer.h"
#include "Common.h"
#import <CoreFoundation/CoreFoundation.h>

static BOOL switchAppBeforeRunScript = true;
ScriptPlayer *scriptPlayer;
static float currentRunSpeed = 1.0f;

void initScriptPlayer()
{
    scriptPlayer = [[ScriptPlayer alloc] init];
}

void updateSwtichAppBeforeRunScript(BOOL value)
{
    switchAppBeforeRunScript = value;
}

int playScript(UInt8* path, NSError **error)
{
    if (!scriptPlayer)
    {
        NSLog(@"com.zjx.springboard: Unable to run the script. Internal error. scriptPlayer is null.");
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;Unable to run the script. Internal error. scriptPlayer is null.\r\n"}];
        return -1;
    }
    // read config file to get repeat time etc
    int repeatTime = 0;
    float sleepBetweenRun = 0;
    float playSpeed = 1.0f;
    
    NSLog(@"com.zjx.springboard: path: %s", path);
    NSDictionary *config = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:SCRIPT_PLAY_CONFIG_PATH])
        config = [[NSDictionary alloc] initWithContentsOfFile:SCRIPT_PLAY_CONFIG_PATH];

    if (config)
    {
        // App-launched scripts only use per-script settings written by the app.
        // Floating panel settings are handled separately so they do not leak.
        NSDictionary *individualConfigs = config[@"individual_configs"];
        NSDictionary *scriptInfo = [individualConfigs valueForKey:[NSString stringWithFormat:@"%s", path]];

        if (scriptInfo)
        {
            repeatTime = [scriptInfo[@"repeat_times"] intValue];
            sleepBetweenRun = [scriptInfo[@"interval"] floatValue];
            float sp = [scriptInfo[@"speed"] floatValue];
            if (sp > 0) playSpeed = sp;
        }
    }

    return playScriptWithSettings(path, repeatTime, playSpeed, sleepBetweenRun, error);
}

int playScriptWithSettings(UInt8* path, int repeatTime, float playSpeed, float sleepBetweenRun, NSError **error)
{
    if (!scriptPlayer)
    {
        NSLog(@"com.zjx.springboard: Unable to run the script. Internal error. scriptPlayer is null.");
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;Unable to run the script. Internal error. scriptPlayer is null.\r\n"}];
        return -1;
    }
    if (playSpeed <= 0) playSpeed = 1.0f;
    currentRunSpeed = playSpeed;

    [scriptPlayer setPath:[NSString stringWithFormat:@"%s", path]];
    [scriptPlayer setRepeatTime:repeatTime];
    [scriptPlayer setSpeed:playSpeed];
    [scriptPlayer setInterval:sleepBetweenRun];
    [scriptPlayer setSwitchApp:switchAppBeforeRunScript];

    [scriptPlayer play:error];

    return 0;
}


void stopScriptPlaying(NSError **error)
{
    [scriptPlayer forceStop:error];
}

BOOL isScriptPlaying()
{
    return scriptPlayer && [scriptPlayer isPlaying];
}

void playHasStoppedCallBack()
{
    // Users can turn the "Script Finished" popup off in the app's settings
    // (Script -> Script Finished Popup). Absent key means on, so existing
    // installs keep the previous behaviour.
    NSDictionary *tweakCfg = [[NSDictionary alloc] initWithContentsOfFile:@"/var/mobile/Library/ZXTouch/config/tweak/config.plist"];
    id showFinishedPopup = tweakCfg[@"show_script_finished_popup"];
    if (showFinishedPopup != nil && ![showFinishedPopup boolValue]) {
        NSLog(@"com.zjx.springboard: Script Finished popup disabled in settings.");
        return;
    }

    if (CFAbsoluteTimeGetCurrent() - lastAlertBoxRequestTime() < 4.0) {
        NSLog(@"com.zjx.springboard: skipping Script Finished popup because script recently showed an alert.");
        return;
    }

    NSString *bundlePath = [scriptPlayer getCurrentBundlePath];
    NSString *scriptName = (bundlePath.length > 0) ? [[bundlePath lastPathComponent] stringByDeletingPathExtension] : @"Unknown";
    int completedRuns = [scriptPlayer getCompletedRuns];

    NSString *msg = [NSString stringWithFormat:@"Script: %@\nSpeed: %.1f×\nPlayed: %d time(s)",
                     scriptName, currentRunSpeed, completedRuns];
    showAlertBox(@"Script Finished", msg, 0);
}
