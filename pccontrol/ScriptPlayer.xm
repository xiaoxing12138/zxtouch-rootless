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
#import <sys/socket.h>
#import <sys/un.h>
#include <errno.h>
#include <unistd.h>
#include <signal.h>
#include <spawn.h>
#include <fcntl.h>
#include <time.h>
#include <stdlib.h>

static BOOL isPlaying = false;

static int zx_run_launchctl_bootstrap(void)
{
    const char *plist = "/var/jb/Library/LaunchAgents/com.zjx.zxrunner.plist";
    const char *launchctl_paths[] = {
        "/var/jb/usr/bin/launchctl",
        "/usr/bin/launchctl",
        NULL
    };
    for (int i = 0; launchctl_paths[i]; i++) {
        char *const argv[] = { (char *)launchctl_paths[i], (char *)"bootstrap", (char *)"gui/501", (char *)plist, NULL };
        pid_t pid = 0;
        int err = posix_spawn(&pid, launchctl_paths[i], NULL, NULL, argv, NULL);
        if (err == 0) {
            int st = 0;
            waitpid(pid, &st, 0);
            if (WIFEXITED(st) && WEXITSTATUS(st) == 0) return 0;
        }
    }
    return -1;
}

static NSString *ZXPythonPath(void)
{
    NSArray<NSString *> *candidates = @[
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
    ];
    for (NSString *path in candidates) {
        if (path.length > 0 && access(path.UTF8String, X_OK) == 0) {
            return path;
        }
    }
    for (NSString *path in candidates) {
        if (path.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
            return path;
        }
    }
    return nil;
}

static NSString *ZXPythonModulePath(void)
{
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
    int currentScriptType;
    NSTimer *replayTimer;
    Boolean scriptPlayForceStop;
    volatile sig_atomic_t scriptStopRequested;
    volatile sig_atomic_t scriptPauseRequested;
    pid_t pythonProcessGroup;
    Boolean switchAppBeforePlaying;
    int _completedRuns;
    CFRunLoopRef replayRunLoop;
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

    NSString *infoFilePath = [NSString stringWithFormat:@"%@/info.plist", scriptBundlePath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:infoFilePath isDirectory:&isDir])
    {
        NSLog(@"com.zjx.springboard: Unable to run the script. Info.plist not found.");
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;无法运行脚本：未找到 Info.plist。\r\n"}];
        return -1;
    }
    NSDictionary *scriptInfo = [NSDictionary dictionaryWithContentsOfFile:infoFilePath];
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
            int type, sleepTime;
            sscanf(buffer, "%2d", &type);
            if (type == TASK_USLEEP)
            {
                sscanf(buffer, "%2d%d", &type, &sleepTime);
                sleepTime = sleepTime / speed;
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
                     @"小新Lap 在此设备上找不到可用的 python3。\n\n请打开 Sileo，安装 Procursus 源中的 python3 软件包，然后重新安装 小新Lap，以便注册新的解释器。",
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

    NSString *outputLog = @"/var/mobile/Library/ZXTouch/coreutils/ScriptRuntime/output";
    if (![[NSFileManager defaultManager] fileExistsAtPath:outputLog])
        [@"" writeToFile:outputLog atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSString *statusFile = @"/var/mobile/Library/ZXTouch/coreutils/ScriptRuntime/last_python_status";
    [[NSFileManager defaultManager] removeItemAtPath:statusFile error:nil];

    NSString *scriptDir = [filePath stringByDeletingLastPathComponent];
    NSString *pythonModulePath = ZXPythonModulePath();
    NSString *selectionEnv = ZXScriptEnvPrefix(scriptBundlePath);

    // ── 1. 构造环境变量 ──
    // shell 链路（system2Cancelable）在 Dopamine 下 PATH 缺 /var/jb/usr/bin
    // 导致 probe A=127。现在完全绕开 shell，直接 posix_spawn python，
    // 用绝对路径拉解释器（probe B=0 已验证可行）。
    NSMutableArray<NSString *> *envVars = [NSMutableArray array];
    if (pythonModulePath.length > 0) {
        [envVars addObject:[NSString stringWithFormat:@"PYTHONPATH=%@", pythonModulePath]];
    }
    if (selectionEnv.length > 0) {
        NSArray<NSString *> *parts = [selectionEnv componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        for (NSString *part in parts) {
            if (part.length > 0 && [part containsString:@"="]) {
                [envVars addObject:part];
            }
        }
    }

    extern char **environ;
    int envCount = 0;
    while (environ && environ[envCount]) envCount++;

    NSMutableSet<NSString *> *ourKeys = [NSMutableSet set];
    for (NSString *ev in envVars) {
        NSRange eq = [ev rangeOfString:@"="];
        if (eq.location != NSNotFound)
            [ourKeys addObject:[ev substringToIndex:eq.location]];
    }

    int totalEnv = envCount + (int)envVars.count + 1;
    char **envp = (char **)malloc(sizeof(char *) * totalEnv);
    int eidx = 0;
    for (int i = 0; i < envCount; i++) {
        NSString *existing = [NSString stringWithUTF8String:environ[i]];
        NSRange eq = [existing rangeOfString:@"="];
        if (eq.location != NSNotFound && ![ourKeys containsObject:[existing substringToIndex:eq.location]]) {
            envp[eidx++] = environ[i];
        }
    }
    for (NSString *ev in envVars) {
        envp[eidx++] = (char *)ev.UTF8String;
    }
    envp[eidx] = NULL;

    // ── 2. posix_spawn python（无 shell 介入）──
    int p_stdout[2];
    if (pipe(p_stdout) == -1) {
        NSLog(@"com.zjx.springboard: pipe(stdout) failed: %s", strerror(errno));
        free(envp);
        isPlaying = false;
        return;
    }

    // chdir 到脚本目录（脚本内相对路径依赖此上下文）
    char prevCwd[PATH_MAX] = {0};
    getcwd(prevCwd, sizeof(prevCwd));
    if (chdir(scriptDir.UTF8String) != 0) {
        NSLog(@"com.zjx.springboard: chdir(%s) failed: %s", scriptDir.UTF8String, strerror(errno));
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&actions, p_stdout[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, p_stdout[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, p_stdout[0]);
    posix_spawn_file_actions_addclose(&actions, p_stdout[1]);

    posix_spawnattr_t attrs;
    posix_spawnattr_init(&attrs);
    sigset_t emptyset;
    sigemptyset(&emptyset);
    posix_spawnattr_setsigmask(&attrs, &emptyset);
    posix_spawnattr_setpgroup(&attrs, 0);  // python 自己当进程组长（kill(-pid) 可暂停/停止）
    posix_spawnattr_setflags(&attrs, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP);

    const char *argv[] = {
        pythonPath.UTF8String,
        "-u",
        filePath.UTF8String,
        NULL
    };

    pid_t pid = 0;
    int spawnErr = posix_spawn(&pid, pythonPath.UTF8String, &actions, &attrs, (char *const *)argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attrs);
    free(envp);

    if (prevCwd[0]) chdir(prevCwd);

    if (spawnErr != 0) {
        NSLog(@"com.zjx.springboard: posix_spawn(%s) failed: %s (%d)",
              pythonPath.UTF8String, strerror(spawnErr), spawnErr);
        close(p_stdout[0]); close(p_stdout[1]);
        free(envp);

        // iOS 18 Dopamine：SpringBoard sandbox 硬拦 exec /var/jb/*（probe 全 EPERM）。
        // 但 launchd 拉起的同 uid 进程 zxrunner 能 exec python（probe 已验证）。
        // fallback：连 zxrunner socket 让它替 SpringBoard posix_spawn python。
        if (spawnErr == EPERM || errno == EPERM) {
            NSLog(@"com.zjx.springboard: EPERM — trying zxrunner daemon socket fallback...");
            if (![self runPythonViaDaemon:pythonPath
                               scriptPath:filePath
                                  scriptDir:scriptDir
                                   envp:environ
                              extraEnv:envVars]) {
                showAlertBox(@"脚本无法启动（守护进程也不可用）",
                             [NSString stringWithFormat:@"小新Lap 在此设备上无法直接执行 Python。\n\n守护进程 zxrunner 未运行或无法启动。\n\n详情：%s", strerror(spawnErr)],
                             999);
                if (prevCwd[0]) chdir(prevCwd);
                isPlaying = false;
                return;
            }
            // daemon 路径成功的话，下面的 cleanup 已经在 runPythonViaDaemon 里做了
            return;
        }

        showAlertBox(@"脚本无法启动",
                     [NSString stringWithFormat:@"小新Lap 无法启动 Python（posix_spawn 失败：%s）。\n\n请打开 Console.app，搜索 com.zjx.springboard 查看详情。", strerror(spawnErr)],
                     999);
        if (prevCwd[0]) chdir(prevCwd);
        isPlaying = false;
        return;
    }

    pythonProcessGroup = pid;
    NSLog(@"com.zjx.springboard: spawned python %s (pid=%d)", pythonPath.UTF8String, pid);

    // ── 3. 父进程读 pipe，每行加 datetime 前缀写 outputLog ──
    close(p_stdout[1]);

    NSFileHandle *logHandle = [NSFileHandle fileHandleForWritingAtPath:outputLog];
    [logHandle seekToEndOfFile];

    // 开始标记
    time_t now = time(NULL);
    struct tm tmbuf;
    localtime_r(&now, &tmbuf);
    char dateBuf[32];
    strftime(dateBuf, sizeof(dateBuf), "%m-%d-%Y %H:%M:%S", &tmbuf);
    NSString *startLine = [NSString stringWithFormat:@"%s: 开始运行脚本，路径: %@\n", dateBuf, filePath];
    [logHandle writeData:[startLine dataUsingEncoding:NSUTF8StringEncoding]];

    char readBuf[4096];
    NSMutableData *pendingBuf = [NSMutableData data];

    while (!scriptStopRequested) {
        ssize_t n = read(p_stdout[0], readBuf, sizeof(readBuf));
        if (n <= 0) break;
        [pendingBuf appendBytes:readBuf length:n];

        NSUInteger start = 0;
        NSRange nl;
        while ((nl = [pendingBuf rangeOfData:[NSData dataWithBytes:"\n" length:1]
                                      options:0
                                        range:NSMakeRange(start, pendingBuf.length - start)]).location != NSNotFound) {
            NSData *lineData = [pendingBuf subdataWithRange:NSMakeRange(start, nl.location - start)];
            start = nl.location + 1;

            NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding]
                          ?: [[NSString alloc] initWithData:lineData encoding:NSASCIIStringEncoding]
                          ?: @"";
            time_t t2 = time(NULL);
            struct tm tm2;
            localtime_r(&t2, &tm2);
            strftime(dateBuf, sizeof(dateBuf), "%m-%d-%Y %H:%M:%S", &tm2);
            NSString *outLine = [NSString stringWithFormat:@"%s: %@\n", dateBuf, line];
            [logHandle writeData:[outLine dataUsingEncoding:NSUTF8StringEncoding]];
        }
        if (start > 0) [pendingBuf replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
    }

    //  flush 最后一段不完整行
    if (pendingBuf.length > 0) {
        NSString *line = [[NSString alloc] initWithData:pendingBuf encoding:NSUTF8StringEncoding]
                      ?: [[NSString alloc] initWithData:pendingBuf encoding:NSASCIIStringEncoding]
                      ?: @"";
        time_t t2 = time(NULL);
        struct tm tm2;
        localtime_r(&t2, &tm2);
        strftime(dateBuf, sizeof(dateBuf), "%m-%d-%Y %H:%M:%S", &tm2);
        NSString *outLine = [NSString stringWithFormat:@"%s: %@\n", dateBuf, line];
        [logHandle writeData:[outLine dataUsingEncoding:NSUTF8StringEncoding]];
    }

    close(p_stdout[0]);
    [logHandle closeFile];

    // ── 4. 回收子进程 ──
    BOOL stoppedByUser = scriptStopRequested != 0;
    scriptStopRequested = 0;

    int status = 0;
    int pythonExitCode = -1;

    if (stoppedByUser && pythonProcessGroup > 0) {
        kill(-pythonProcessGroup, SIGKILL);
    }

    pid_t wpid;
    while ((wpid = waitpid(pid, &status, 0)) == -1) {
        if (errno == EINTR) continue;
        NSLog(@"com.zjx.springboard: waitpid(pid=%d) failed: %s", pid, strerror(errno));
        break;
    }
    if (wpid > 0) {
        if (WIFEXITED(status)) pythonExitCode = WEXITSTATUS(status);
        else if (WIFSIGNALED(status)) pythonExitCode = 128 + WTERMSIG(status);
        NSLog(@"com.zjx.springboard: python exited code=%d (stoppedByUser=%d)", pythonExitCode, stoppedByUser);
    }
    pythonProcessGroup = 0;

    NSString *exitStr = [NSString stringWithFormat:@"%d", pythonExitCode];
    [exitStr writeToFile:statusFile atomically:YES encoding:NSUTF8StringEncoding error:nil];

    // ── 5. 错误处理 ──
    if (!stoppedByUser && pythonExitCode != 0) {
        NSString *title = @"脚本错误";
        NSString *message;
        NSString *logTail = [NSString stringWithContentsOfFile:outputLog encoding:NSUTF8StringEncoding error:nil] ?: @"";
        BOOL dyldLibpythonMissing = [logTail rangeOfString:@"Library not loaded" options:0].location != NSNotFound &&
                                    [logTail rangeOfString:@"libpython" options:0].location != NSNotFound;
        if (pythonExitCode == 134 && dyldLibpythonMissing) {
            title = @"Python 解释器已损坏";
            message = @"已安装的 python3 启动时中止，因为 dyld 找不到它的 libpython 动态库。\n\n请在 Sileo（Procursus）中安装 python3 软件包（3.9 或更新版本），然后重新安装 小新Lap，使其重新选择可用的解释器。";
        } else if (pythonExitCode < 0) {
            title = @"脚本无法启动";
            message = [NSString stringWithFormat:@"小新Lap 无法启动 Python（posix_spawn 异常，退出码 %d）。\n\n请打开 Console.app，搜索 com.zjx.springboard 查看详情。", pythonExitCode];
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
    if (!isPlaying) return;

    NSLog(@"com.zjx.springboard: script has finished");
    _completedRuns++;

    if (repeatTime != 0)
    {    
        NSLog(@"com.zjx.springboard: need replay. Replay time: %d", repeatTime);

        replayTimer = [NSTimer scheduledTimerWithTimeInterval:interval
         target:self selector:@selector(replay:) 
         userInfo:nil repeats:NO];
        repeatTime--;

        currentScriptType = 0;
        replayRunLoop = CFRunLoopGetCurrent();
        CFRunLoopRun();
        replayRunLoop = NULL;
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
        if (replayRunLoop) CFRunLoopStop(replayRunLoop);
        [self clear];
    }
    else if (currentScriptType == 1)
    {
        scriptPlayForceStop = true;
        [self clear];
    }
    else if (currentScriptType == 2)
    {
        scriptStopRequested = 1;
        pid_t processGroup = pythonProcessGroup;
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

// ── 通过 zxrunner daemon socket 执行 python ──
// 当 SpringBoard sandbox 硬拦 exec /var/jb/* 时（iOS 18 Dopamine），
// launchd 拉起的同 uid 进程 zxrunner 不受此限制，能 exec python。
// SpringBoard 通过 AF_UNIX socket 发命令给它。
#define ZXRUNNER_SOCKET_PATH "/tmp/zxrunner.sock"

- (BOOL)runPythonViaDaemon:(NSString *)pythonPath
                scriptPath:(NSString *)scriptPath
                   scriptDir:(NSString *)scriptDir
                    envp:(char **)envp
               extraEnv:(NSArray<NSString *> *)extraEnv
{
    // 0. 创建 output log
    NSString *outputLog = @"/var/mobile/Library/ZXTouch/coreutils/ScriptRuntime/output";
    if (![[NSFileManager defaultManager] fileExistsAtPath:outputLog])
        [@"" writeToFile:outputLog atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSFileHandle *logHandle = [NSFileHandle fileHandleForWritingAtPath:outputLog];
    [logHandle seekToEndOfFile];
    time_t now0 = time(NULL);
    struct tm tm0;
    localtime_r(&now0, &tm0);
    char dateBuf0[32];
    strftime(dateBuf0, sizeof(dateBuf0), "%m-%d-%Y %H:%M:%S", &tm0);
    NSString *startLine = [NSString stringWithFormat:@"%s: [daemon] 开始运行脚本，路径: %@\n", dateBuf0, scriptPath];
    [logHandle writeData:[startLine dataUsingEncoding:NSUTF8StringEncoding]];

    // 1. 连 socket（daemon 可能还没被拉起，第一次失败时 bootstrap + 重试一次）
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        NSLog(@"com.zjx.springboard: daemon socket() failed: %s", strerror(errno));
        return NO;
    }
    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, ZXRUNNER_SOCKET_PATH, sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"com.zjx.springboard: daemon connect(%s) failed: %s — trying launchctl bootstrap...", ZXRUNNER_SOCKET_PATH, strerror(errno));
        close(fd);
        // SpringBoard respring 不会触发 launchd 重新扫描 LaunchAgents 目录，
        // 需要显式 bootstrap 让 launchd 拉起 zxrunner。
        // SpringBoard tweak 身份是 mobile(uid=501)，对自己的 gui domain 有权限操作。
        int rc = zx_run_launchctl_bootstrap();
        NSLog(@"com.zjx.springboard: launchctl bootstrap returned %d", rc);
        // launchd 拉起进程 + bind socket 需要时间
        usleep(500000);
        fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) {
            NSLog(@"com.zjx.springboard: daemon socket() retry failed: %s", strerror(errno));
            return NO;
        }
        addr.sun_family = AF_UNIX;
        strncpy(addr.sun_path, ZXRUNNER_SOCKET_PATH, sizeof(addr.sun_path) - 1);
        if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
            NSLog(@"com.zjx.springboard: daemon connect retry(%s) failed: %s", ZXRUNNER_SOCKET_PATH, strerror(errno));
            close(fd);
            return NO;
        }
        NSLog(@"com.zjx.springboard: daemon bootstrap OK, connect retry succeeded");
    }

    // 2. 构造 env dict
    NSMutableDictionary *envDict = [NSMutableDictionary dictionary];
    if (envp) {
        for (char **p = envp; *p; p++) {
            NSString *pair = [NSString stringWithUTF8String:*p];
            NSRange eq = [pair rangeOfString:@"="];
            if (eq.location != NSNotFound) {
                NSString *k = [pair substringToIndex:eq.location];
                NSString *v = [pair substringFromIndex:eq.location + 1];
                envDict[k] = v;
            }
        }
    }
    for (NSString *ev in extraEnv) {
        NSRange eq = [ev rangeOfString:@"="];
        if (eq.location != NSNotFound) {
            envDict[[ev substringToIndex:eq.location]] = [ev substringFromIndex:eq.location + 1];
        }
    }

    // 3. 构造命令 JSON
    NSDictionary *cmd = @{
        @"cmd": @"spawn_python",
        @"path": pythonPath ?: @"",
        @"script": scriptPath ?: @"",
        @"cwd": scriptDir ?: @"",
        @"env": envDict,
        @"args": @[@"-u"]
    };
    NSError *jsonErr = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:cmd options:0 error:&jsonErr];
    if (jsonErr) {
        NSLog(@"com.zjx.springboard: daemon JSON 序列化失败: %@", jsonErr);
        close(fd);
        return NO;
    }
    NSMutableData *sendBuf = [NSMutableData dataWithData:jsonData];
    [sendBuf appendBytes:"\r\n" length:2];
    if (write(fd, sendBuf.bytes, sendBuf.length) != sendBuf.length) {
        NSLog(@"com.zjx.springboard: daemon write failed: %s", strerror(errno));
        close(fd);
        return NO;
    }

    NSLog(@"com.zjx.springboard: → zxrunner 命令已发送，等待响应...");

    // 4. 读响应流，每行一个 JSON
    char lineBuf[8192];
    int  linePos = 0;
    BOOL exited = NO;
    int  exitCode = -1;
    BOOL gotError = NO;

    while (!exited && !scriptStopRequested) {
        char ch;
        ssize_t nr = read(fd, &ch, 1);
        if (nr <= 0) break;

        if (ch == '\n') {
            if (linePos == 0) continue;
            // 去掉可能的 \r
            if (lineBuf[linePos - 1] == '\r') lineBuf[--linePos] = '\0';
            lineBuf[linePos] = '\0';

            NSData *lineData = [NSData dataWithBytes:lineBuf length:linePos];
            NSError *parseErr = nil;
            NSDictionary *resp = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:&parseErr];

            if (!parseErr && [resp isKindOfClass:[NSDictionary class]]) {
                NSString *type = resp[@"type"];
                if ([type isEqualToString:@"started"]) {
                    NSNumber *pid = resp[@"pid"];
                    NSLog(@"com.zjx.springboard: ← zxrunner started python pid=%d", pid.intValue);
                    pythonProcessGroup = pid.intValue;
                } else if ([type isEqualToString:@"stdout"] || [type isEqualToString:@"stderr"]) {
                    // 解义 JSON 字符串里的转义字符
                    NSString *data = resp[@"data"] ?: @"";
                    if (data.length > 0) {
                        // 加 datetime 前缀写 logHandle
                        time_t t2 = time(NULL);
                        struct tm tm2;
                        localtime_r(&t2, &tm2);
                        char dateBuf[32];
                        strftime(dateBuf, sizeof(dateBuf), "%m-%d-%Y %H:%M:%S", &tm2);
                        NSString *outLine = [NSString stringWithFormat:@"%s: %@\n", dateBuf, data];
                        [logHandle writeData:[outLine dataUsingEncoding:NSUTF8StringEncoding]];
                    }
                } else if ([type isEqualToString:@"exit"]) {
                    exitCode = [resp[@"code"] intValue];
                    exited = YES;
                    NSLog(@"com.zjx.springboard: ← zxrunner python exit=%d", exitCode);
                } else if ([type isEqualToString:@"error"]) {
                    NSLog(@"com.zjx.springboard: ← zxrunner error: %@", resp[@"msg"]);
                    gotError = YES;
                    exited = YES;
                }
            }
            linePos = 0;
        } else if (linePos < (int)sizeof(lineBuf) - 1) {
            lineBuf[linePos++] = ch;
        }
    }

    // 用户请求停止：daemon 会继续读 python stdout 直到 python 退出。
    // 但我们这边不关心了，直接关 socket。python 进程残留是 daemon 的事（需要后续加 kill 命令）。
    close(fd);

    isPlaying = NO;
    [logHandle closeFile];

    // 写 statusFile
    NSString *statusFile = @"/var/mobile/Library/ZXTouch/coreutils/ScriptRuntime/last_python_status";
    [[NSString stringWithFormat:@"%d", exitCode] writeToFile:statusFile atomically:YES encoding:NSUTF8StringEncoding error:nil];

    return YES;
}

@end
