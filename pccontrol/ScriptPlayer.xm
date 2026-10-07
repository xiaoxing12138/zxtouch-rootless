#import "ScriptPlayer.h"
#include <roothide.h>
#include "Play.h"
#include "SocketServer.h"
#include "Process.h"
#include "Task.h"
#include "AlertBox.h"
#include "Config.h"
#include "Common.h"
#import "ScriptFunctions.h"
#import <sys/stat.h>
#include <errno.h>
#include <unistd.h>
#include <signal.h>

static BOOL isPlaying = false;

static NSString *ZXShellQuote(NSString *value)
{
    if (!value) return @"''";
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static NSString *ZXFirstExecutablePath(NSArray<NSString *> *candidates)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in candidates) {
        if (path.length > 0 && [fm isExecutableFileAtPath:path]) {
            return path;
        }
    }
    return nil;
}

static NSString *ZXPythonPath(void)
{
    // Prefer specific versions before the generic `python3` symlink. If a
    // previous install of ZXTouch (or another package) pointed `python3` at a
    // broken interpreter (e.g. Procursus 3.7 whose libpython lives at a path
    // dyld can't resolve on rootless), a versioned binary is more likely to
    // actually load. 3.7 is dropped entirely — it aborts at dyld on 15+.
    return ZXFirstExecutablePath(@[
        jbroot(@"/usr/bin/python3.12"),
        jbroot(@"/usr/bin/python3.11"),
        jbroot(@"/usr/bin/python3.10"),
        jbroot(@"/usr/bin/python3.9"),
        jbroot(@"/usr/bin/python3.8"),
        jbroot(@"/usr/bin/python3"),
        @"/var/jb/usr/bin/python3.12",
        @"/var/jb/usr/bin/python3.11",
        @"/var/jb/usr/bin/python3.10",
        @"/var/jb/usr/bin/python3.9",
        @"/var/jb/usr/bin/python3.8",
        @"/var/jb/usr/bin/python3",
        @"/usr/bin/python3.12",
        @"/usr/bin/python3.11",
        @"/usr/bin/python3.10",
        @"/usr/bin/python3.9",
        @"/usr/bin/python3.8",
        @"/usr/bin/python3"
    ]);
}

static NSString *ZXShellPath(void)
{
    return ZXFirstExecutablePath(@[
        jbroot(@"/bin/sh"),
        jbroot(@"/usr/bin/sh"),
        @"/var/jb/bin/sh",
        @"/var/jb/usr/bin/sh",
        @"/bin/sh",
        @"/usr/bin/sh"
    ]) ?: @"/bin/sh";
}

static NSString *ZXPythonModulePath(void)
{
    // The zxtouch module ships under /usr/share/zxtouch/python and the postinst
    // also copies it into every installed Python's site/dist-packages. Include
    // the share path unconditionally so scripts still find `import zxtouch`
    // even if the copy step skipped a Python version installed later.
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSString *path in @[
        jbroot(@"/usr/share/zxtouch/python"),
        jbroot(@"/usr/lib/python3/site-packages"),
        jbroot(@"/usr/lib/python3/dist-packages"),
        @"/var/jb/usr/share/zxtouch/python",
        @"/var/jb/usr/lib/python3/site-packages",
        @"/var/jb/usr/lib/python3/dist-packages",
        @"/usr/lib/python3/site-packages",
        @"/usr/lib/python3/dist-packages"
    ]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [paths addObject:path];
        }
    }
    return [paths componentsJoinedByString:@":"];
}

@implementation ScriptPlayer
{
    int repeatTime;
    float interval;
    float speed;
    NSString* scriptBundlePath;
    int currentScriptType; // -1 no task has specified; 0 not playing but has upcoming task; 1 raw file playing; 2 py file playing
    NSTimer *replayTimer;
    Boolean scriptPlayForceStop;
    volatile sig_atomic_t scriptStopRequested;
    volatile sig_atomic_t scriptPauseRequested;
    pid_t pythonProcessGroup;
    Boolean switchAppBeforePlaying;
    int _completedRuns;
}

- (BOOL)isPlaying {
    return isPlaying;
}

- (BOOL)isPaused {
    return isPlaying && scriptPauseRequested != 0;
}

- (void)pause {
    if (!isPlaying || scriptPauseRequested) {
        return;
    }
    scriptPauseRequested = 1;
    // py 脚本跑在独立进程组里，冻结整个进程组（含 shell 管道）才能真正停住
    if (currentScriptType == 2 && pythonProcessGroup > 0) {
        kill(-pythonProcessGroup, SIGSTOP);
    }
}

- (void)resume {
    if (!scriptPauseRequested) {
        return;
    }
    scriptPauseRequested = 0;
    if (currentScriptType == 2 && pythonProcessGroup > 0) {
        kill(-pythonProcessGroup, SIGCONT);
    }
}

- (int)getCompletedRuns {
    return _completedRuns;
}

- (NSString*)getCurrentBundlePath {
    if (!scriptBundlePath)
    {
        return @"";
    }
    return scriptBundlePath;
}

- (void)setPath:(NSString*)path {
    if (isPlaying)
    {
        NSLog(@"com.zjx.springboard: cannot change script path because a script is playing.");
        return;
    }
    scriptBundlePath = path;
}

- (void)setRepeatTime:(int)rt {
    if (isPlaying)
    {
        NSLog(@"com.zjx.springboard: cannot change repeat time because a script is playing.");
        return;
    }
    repeatTime = rt;
}

- (void)setInterval:(float)intv {
    if (isPlaying)
    {
        NSLog(@"com.zjx.springboard: cannot change interval because a script is playing.");
        return;
    }
    interval = intv;
}

- (void)setSpeed:(float)sp {
    if (isPlaying)
    {
        NSLog(@"com.zjx.springboard: cannot change speed because a script is playing.");
        return;
    }
    speed = sp;
}

- (void)setSwitchApp:(BOOL)value {
    if (isPlaying)
    {
        NSLog(@"com.zjx.springboard: cannot change speed because a script is playing.");
        return;
    }
    switchAppBeforePlaying = value;
}


- (id)init {
    self = [super init];
    if (self)
    {
        [self clear];
        scriptStopRequested = 0;
        scriptPauseRequested = 0;
        pythonProcessGroup = 0;
    }
    return self;
}

- (id)initWithPath:(NSString*)path {
    self = [super init];
    if (self)
    {
        scriptBundlePath = path;
        currentScriptType = -1;
        scriptStopRequested = 0;
        scriptPauseRequested = 0;
        pythonProcessGroup = 0;
    }
    return self;
}

-(int)runScript:(NSError**)error {
    scriptStopRequested = 0;
    scriptPauseRequested = 0;
    pythonProcessGroup = 0;

    if (!scriptBundlePath)
    {
        NSLog(@"com.zjx.springboard: Unable to run the script. ScriptBundlePath not set.");
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;无法运行脚本：未设置脚本包路径。\r\n"}];
        return -1;
    }

    BOOL isDir;
    if (![[NSFileManager defaultManager] fileExistsAtPath:scriptBundlePath isDirectory:&isDir] || !isDir)
    {
        NSLog(@"com.zjx.springboard: Unable to run the script. Path not found or it is not a directory.");
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;无法运行脚本：找不到路径，或该路径不是文件夹。\r\n"}];
        return -1;
    }

    // read info.plist into dictionary
    NSString *infoFilePath = [NSString stringWithFormat:@"%@/info.plist", scriptBundlePath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:infoFilePath isDirectory:&isDir])
    {
        NSLog(@"com.zjx.springboard: Unable to run the script. Info.plist not found.");
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;无法运行脚本：未找到 Info.plist。\r\n"}];
        return -1;
    }
    NSDictionary *scriptInfo = [NSDictionary dictionaryWithContentsOfFile:infoFilePath];
    // get entry file extension
    NSString *entryFileName = scriptInfo[@"Entry"];
    NSString *fileExtension = [entryFileName pathExtension];

    NSString *foregroundApp = scriptInfo[@"FrontApp"];

    NSString *entryFilePath = [scriptBundlePath stringByAppendingPathComponent:entryFileName];
    NSLog(@"com.zjx.sprinboard: currently playing: %@. Repeat time: %d", entryFilePath, repeatTime);
    

    if ([fileExtension isEqualToString:@"raw"])
    {
        currentScriptType = 1;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            NSError *err = nil;
            [self playFromRawFile:entryFilePath foregroundApp:foregroundApp err:&err];
        }); 
    }
    else if ([fileExtension isEqualToString:@"py"])
    {
        currentScriptType = 2;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            NSError *err = nil;
            [self playFromPythonFile:entryFilePath foregroundApp:foregroundApp err:&err];
        });
        
    }
}

// play the script
- (int)play:(NSError**)error
{
    if (isPlaying)
    {
        NSLog(@"com.zjx.springboard: Unable to run the script. Another script is currently running.");
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;无法运行脚本：当前已有另一个脚本正在运行。\r\n"}];
        return -1;
    }
    _completedRuns = 0;
    [self runScript:error];
}


-(void)playFromRawFile:(NSString*) filePath foregroundApp:(NSString*)foregroundApp err:(NSError**)err
{
    isPlaying = true;
    if (switchAppBeforePlaying)
    {
        bringAppForeground(foregroundApp);
    }

    FILE *file = fopen([filePath UTF8String], "r");

    if (!file)
    {
        showAlertBox(@"错误", [NSString stringWithFormat:@"无法播放此脚本，小新Lap 无法打开该文件。文件路径：%@", filePath], 999);
        isPlaying = false;
        return;
    }
    
    char buffer[256];
    int taskType;
    int sleepTime;
    
    BOOL stoppedByUser = NO;
    while (YES)
    {
        if (scriptPlayForceStop)
        {
            scriptPlayForceStop = false;
            stoppedByUser = YES;
            break;
        }
        // 暂停：原地等待（50ms 轮询），期间仍能响应停止
        while (scriptPauseRequested && !scriptPlayForceStop)
        {
            usleep(50 * 1000);
        }
        if (scriptPlayForceStop)
        {
            scriptPlayForceStop = false;
            stoppedByUser = YES;
            break;
        }
        if (fgets(buffer, sizeof(char)*256, file) == NULL)
        {
            break;
        }
        if (speed > 0 && speed != 1)
        {
            // check whether need to speed up
            int type, sleepTime;
            sscanf(buffer, "%2d", &type);
            if (type == TASK_USLEEP)
            {
                sscanf(buffer, "%2d%d", &type, &sleepTime);
                sleepTime = sleepTime / speed; // truncate the float part
                processTask((UInt8*)[[NSString stringWithFormat:@"18%d", sleepTime] UTF8String], NULL);
            }
            else
            {
                processTask((UInt8*)buffer, NULL);
            }
        }
        else
        {
            processTask((UInt8*)buffer, NULL);
        }

    }
    fclose(file);

    if (!stoppedByUser) [self playHasStopped];
}

-(void) playFromPythonFile:(NSString*) filePath foregroundApp:(NSString*) foregroundApp err:(NSError**) err
{
    isPlaying = true;

    if (switchAppBeforePlaying)
    {
        bringAppForeground(foregroundApp);
    }
    
    NSString *pythonPath = ZXPythonPath();
    if (!pythonPath)
    {
        showAlertBox(@"未安装 Python",
                     @"小新Lap 在此设备上找不到可用的 python3。\n\n请打开 Sileo，安装 Procursus 源中的“python3”软件包，然后重新安装 小新Lap，以便注册新的解释器。",
                     999);
        isPlaying = false;
        return;
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath])
    {
        showAlertBox(@"错误", [NSString stringWithFormat:@"无法播放此脚本：在 .bdl 文件夹中找不到脚本文件。脚本路径：%@", filePath], 999);
        isPlaying = false;
        return;
    }
    // Ensure output log file exists so the >> redirect doesn't fail
    NSString *outputLog = @"/var/mobile/Library/ZXTouch/coreutils/ScriptRuntime/output";
    if (![[NSFileManager defaultManager] fileExistsAtPath:outputLog])
        [@"" writeToFile:outputLog atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSString *dateWrapper = @"/var/mobile/Library/ZXTouch/coreutils/ScriptRuntime/add_datetime.sh";
    NSString *shellPath = ZXShellPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:dateWrapper]) {
        NSString *wrapper = [NSString stringWithFormat:@"#!%@\nOUTPUT=/var/mobile/Library/ZXTouch/coreutils/ScriptRuntime/output\nDATE=/var/jb/usr/bin/date\nif [ ! -x \"$DATE\" ]; then DATE=/usr/bin/date; fi\nif [ ! -x \"$DATE\" ]; then DATE=/bin/date; fi\necho \"$($DATE '+%%m-%%d-%%Y %%T'): 开始运行脚本，路径: $1\" >> \"$OUTPUT\"\nwhile IFS= read -r line; do\n    echo \"$($DATE '+%%m-%%d-%%Y %%T'): $line\" >> \"$OUTPUT\"\ndone\n", shellPath];
        [wrapper writeToFile:dateWrapper atomically:YES encoding:NSUTF8StringEncoding error:nil];
        chmod(dateWrapper.UTF8String, 0755);
    }

    NSString *scriptDir = [filePath stringByDeletingLastPathComponent];
    NSString *statusFile = @"/var/mobile/Library/ZXTouch/coreutils/ScriptRuntime/last_python_status";
    NSString *pythonModulePath = ZXPythonModulePath();
    // 功能勾选 + 选项（形如 ZX_OPTS_FILE=... ZX_FUNCS=0,2 ）必须在解释器之前设置，脚本用 os.environ 读取
    NSString *selectionEnv = ZXScriptEnvPrefix(scriptBundlePath);
    NSString *envPrefix = pythonModulePath.length > 0 ? [NSString stringWithFormat:@"PYTHONPATH=%@ ", ZXShellQuote(pythonModulePath)] : @"";
    envPrefix = [selectionEnv stringByAppendingString:envPrefix];
    NSString *commandToRun = [NSString stringWithFormat:@"rm -f %@; (cd %@ && %@%@ -u %@ 2>&1; echo $? > %@) | %@ %@ %@; exit $(cat %@ 2>/dev/null || echo 1)",
                              ZXShellQuote(statusFile),
                              ZXShellQuote(scriptDir),
                              envPrefix,
                              ZXShellQuote(pythonPath),
                              ZXShellQuote(filePath),
                              ZXShellQuote(statusFile),
                              ZXShellQuote(shellPath),
                              ZXShellQuote(dateWrapper),
                              ZXShellQuote(filePath),
                              ZXShellQuote(statusFile)];
    NSLog(@"com.zjx.springboard: command to run for running py file %@", commandToRun);

    int shellExitCode = system2Cancelable([commandToRun UTF8String], NULL, NULL,
                                          &pythonProcessGroup, &scriptStopRequested);
    BOOL stoppedByUser = scriptStopRequested != 0;
    scriptStopRequested = 0;
    NSString *statusText = [NSString stringWithContentsOfFile:statusFile encoding:NSUTF8StringEncoding error:nil];
    int pythonExitCode = statusText ? [statusText intValue] : shellExitCode;
    if (!stoppedByUser && pythonExitCode != 0) {
        NSString *title = @"脚本错误";
        NSString *message;
        NSString *logTail = [NSString stringWithContentsOfFile:outputLog encoding:NSUTF8StringEncoding error:nil] ?: @"";
        BOOL dyldLibpythonMissing = [logTail rangeOfString:@"Library not loaded" options:0].location != NSNotFound &&
                                    [logTail rangeOfString:@"libpython" options:0].location != NSNotFound;
        if (statusText == nil && shellExitCode < 0) {
            // system2 failed before python could run — spawn was denied or the
            // shell was unusable. Common on semi-jailbreaks with stripped
            // entitlements. Check Console.app for `system2` NSLog output.
            title = @"脚本无法启动";
            message = @"小新Lap 无法启动 shell 来运行脚本（posix_spawn 失败）。\n\n请打开 Console.app（或 `oslog`），搜索 `com.zjx.springboard: system2` 查看具体错误。";
        } else if (pythonExitCode == 134 && dyldLibpythonMissing) {
            // 134 = SIGABRT. Dyld couldn't find libpython — the interpreter
            // was linked against a path that doesn't exist on this JB (classic
            // Procursus python3.7 on rootless).
            title = @"Python 解释器已损坏";
            message = @"已安装的 python3 启动时中止，因为 dyld 找不到它的 libpython 动态库。\n\n请在 Sileo（Procursus）中安装“python3”软件包（3.9 或更新版本），然后重新安装 小新Lap，使其重新选择可用的解释器。";
        } else {
            message = [NSString stringWithFormat:@"Python 脚本异常退出，退出码 %d。请打开日志查看详细报错。", pythonExitCode];
        }
        NSLog(@"com.zjx.springboard: %@ — %@", title, message);
        showAlertBox(title, message, 999);
    }
    if (!stoppedByUser) [self playHasStopped];
}

- (void)replay:(NSTimer*)nstimer {
    NSLog(@"com.zjx.springboard: script is replaying...");
    NSError *err = nil;

    [self runScript:&err];

    CFRunLoopStop(CFRunLoopGetCurrent());
}

-(void) playHasStopped
{
    // If forceStop already called clear(), isPlaying is false — don't show finished popup
    if (!isPlaying) return;

    NSLog(@"com.zjx.springboard: script has finished");
    _completedRuns++;

    // check whether need to replay
    if (repeatTime != 0)
    {    
        NSLog(@"com.zjx.springboard: need replay. Replay time: %d", repeatTime);

        replayTimer = [NSTimer scheduledTimerWithTimeInterval:interval
         target:self selector:@selector(replay:) 
         userInfo:nil repeats:NO];
        repeatTime--;

        currentScriptType = 0;

        CFRunLoopRun();
    }
    else
    {
        playHasStoppedCallBack();
        [self clear];
    }



}

- (void)clear {
    repeatTime = 0;
    interval = 0.0f;
    speed = 1.0f;
    scriptBundlePath = nil;
    isPlaying = false;
    scriptPauseRequested = 0;
    currentScriptType = -1;
    //scriptPlayForceStop = false;

    if (replayTimer)
        [replayTimer invalidate];

    replayTimer = nil;
}

- (void)forceStop:(NSError**)error {
    if (currentScriptType == -1)
    {
        NSLog(@"com.zjx.springboard: Cannot stop playing script. No script is playing.");
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;无法终止脚本：当前没有正在运行的脚本。\r\n"}];
        return;
    }

    if (currentScriptType == 0)
    {
        [self clear];
    }
    else if (currentScriptType == 1)
    {
        // make stop to be true
        scriptPlayForceStop = true;
        [self clear];
    }
    else if (currentScriptType == 2)
    {
        scriptStopRequested = 1;
        pid_t processGroup = pythonProcessGroup;
        // 暂停中进程组是 SIGSTOP 状态，先 SIGCONT 唤醒再杀，避免留下停住的僵尸组
        if (scriptPauseRequested && processGroup > 0) {
            kill(-processGroup, SIGCONT);
        }
        scriptPauseRequested = 0;
        if (processGroup > 0 && kill(-processGroup, SIGKILL) != 0 && errno != ESRCH) {
            NSLog(@"com.zjx.springboard: failed to stop Python process group %d: errno %d",
                  processGroup, errno);
        }
        [self clear];
    }
    else
    {
        NSLog(@"com.zjx.springboard: unknown currently playing script type.");
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;无法终止脚本：当前运行的脚本类型未知。\r\n"}];
        return;
    }

}

@end
