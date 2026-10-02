#include "Play.h"
#include "SocketServer.h"
#include "Process.h"
#include "Task.h"
#include "AlertBox.h"
#include "Config.h"
#import "ScriptPlayer.h"
#import "FloatingMenu.h"
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
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;无法运行脚本：内部错误，scriptPlayer 为空。\r\n"}];
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
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;无法运行脚本：内部错误，scriptPlayer 为空。\r\n"}];
        return -1;
    }
    if (playSpeed <= 0) playSpeed = 1.0f;
    currentRunSpeed = playSpeed;

    // %s decodes the raw bytes as MacRoman, which mangles every non-ASCII
    // script name into something the filesystem cannot find. Decode as UTF-8
    // so non-English script names resolve.
    [scriptPlayer setPath:[NSString stringWithUTF8String:(const char *)path]];
    [scriptPlayer setRepeatTime:repeatTime];
    [scriptPlayer setSpeed:playSpeed];
    [scriptPlayer setInterval:sleepBetweenRun];
    [scriptPlayer setSwitchApp:switchAppBeforeRunScript];

    [scriptPlayer play:error];

    // 启动悬浮窗旋转光圈特效
    ZXSafeMainAsync(^{ [FloatingMenu startRunningSpinner]; });

    return 0;
}


void stopScriptPlaying(NSError **error)
{
    ZXSafeMainAsync(^{
        [FloatingMenu stopRunningSpinner];
        [FloatingMenu setScriptIdle];
    });
    [scriptPlayer forceStop:error];
}

BOOL isScriptPlaying()
{
    return scriptPlayer && [scriptPlayer isPlaying];
}

BOOL isScriptPaused()
{
    return scriptPlayer && [scriptPlayer isPaused];
}

void pauseScriptPlaying()
{
    [scriptPlayer pause];
}

void resumeScriptPlaying()
{
    [scriptPlayer resume];
}

NSString* ZXCurrentScriptBundlePath()
{
    if (!scriptPlayer) return nil;
    if (![scriptPlayer isPlaying]) return nil;
    return [scriptPlayer getCurrentBundlePath];
}

void playHasStoppedCallBack()
{
    // 脚本结束 → 停旋转光圈（必须最先执行，确保任何提前 return 都不会漏掉）
    ZXSafeMainAsync(^{
        [FloatingMenu stopRunningSpinner];
        // 此处 isPlaying 还没被 clear() 置 false，只能强制回「未运行」态
        [FloatingMenu setScriptIdle];
    });

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
    NSString *scriptName = (bundlePath.length > 0) ? [[bundlePath lastPathComponent] stringByDeletingPathExtension] : @"未知";
    int completedRuns = [scriptPlayer getCompletedRuns];

    NSString *msg = [NSString stringWithFormat:@"脚本：%@\n播放速度：%.1f×\n已播放：%d 次",
                     scriptName, currentRunSpeed, completedRuns];
    showAlertBox(@"脚本运行完成", msg, 0);
}
