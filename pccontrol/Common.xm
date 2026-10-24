#include "Common.h"
#include "Config.h"
#include "Play.h"
#include "Screen.h"
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonHMAC.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/utsname.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <spawn.h>
#include <errno.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <signal.h>

static const char *zxShellPath(void)
{
    const char *sh = jbroot("/bin/sh");
    if (sh && access(sh, X_OK) == 0) return sh;
    static const char *candidates[] = {
        "/var/jb/bin/sh",
        "/var/jb/usr/bin/sh",
        "/bin/sh",
        "/usr/bin/sh",
        NULL
    };
    for (int i = 0; candidates[i]; ++i) {
        if (access(candidates[i], X_OK) == 0) return candidates[i];
    }
    return NULL;
}

int zxWaitTimeout(pid_t pid, double timeoutSec, int *status)
{
    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    while (1) {
        int st = 0;
        pid_t r = waitpid(pid, &st, WNOHANG);
        if (r == pid) {
            if (status) *status = st;
            return 0;
        }
        if (r == -1) return -1;
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        double elapsed = (double)(now.tv_sec - t0.tv_sec) + (double)(now.tv_nsec - t0.tv_nsec) / 1e9;
        if (elapsed >= timeoutSec) return 1;
        usleep(50 * 1000);
    }
}

int call_system(const char *cmd)
{
    if (!cmd) return -1;
    const char *shellPath = zxShellPath();
    if (!shellPath) {
        NSLog(@"com.zjx.springboard: call_system: no usable sh (%s)", cmd);
        return -1;
    }
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawnattr_t attrs;
    posix_spawnattr_init(&attrs);
    sigset_t emptyset;
    sigemptyset(&emptyset);
    posix_spawnattr_setsigmask(&attrs, &emptyset);
    posix_spawnattr_setflags(&attrs, POSIX_SPAWN_SETSIGMASK);
    char * const argv[] = { (char *)"sh", (char *)"-c", (char *)cmd, NULL };
    extern char **environ;
    pid_t pid = 0;
    int spawnErr = posix_spawn(&pid, shellPath, &actions, &attrs, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attrs);
    if (spawnErr != 0) {
        NSLog(@"com.zjx.springboard: call_system posix_spawn(%s) failed: %s (%d)",
              shellPath, strerror(spawnErr), spawnErr);
        return -1;
    }
    int st = 0;
    int w = zxWaitTimeout(pid, 20.0, &st);
    if (w == 1) {
        kill(pid, SIGKILL);
        int st2 = 0;
        zxWaitTimeout(pid, 2.0, &st2);
        st = 9 << 8;
    } else if (w == -1) {
        return -1;
    }
    return st;
}


/*
Get device model name
*/
NSString* getDeviceName()
{
    struct utsname systemInfo;
    uname(&systemInfo);

    return [NSString stringWithCString:systemInfo.machine
                                encoding:NSUTF8StringEncoding];
}

/*
round up number by multiple of another number
*/
int roundUp(int numToRound, int multiple)
{
    if (multiple == 0)
        return numToRound;

    int remainder = numToRound % multiple;
    if (remainder == 0)
        return numToRound;

    return numToRound + multiple - remainder;
}

/*
Check whether current device is an iPad
*/
Boolean isIpad()
{
    if ( [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad )
    {
        return YES;
    }
    return NO;
}

/*
generate a random integer between min and max.

ONLY POSITIVE NUMBER IS SUPPORTED!
*/
int getRandomNumberInt(int min, int max)
{
	min = abs(min);
	max = abs(max);

	if (max < min)
	{
		NSLog(@"### com.zjx.springboard: Max is less than min in getRandomNumberInt(). max: %d, min: %d", max, min);
	}
	return arc4random_uniform(abs(max-min)) + min;
}

/*
generate a random float between min and max.

ONLY POSITIVE NUMBER IS SUPPORTED!
ONLY SUPPORTS TO UP TO 5 DIGIT.
*/
float getRandomNumberFloat(float min, float max)
{
	min = abs(min);
	max = abs(max);

	if (max < min)
	{
		NSLog(@"### com.zjx.springboard: Max is less than min in getRandomNumberFloat(). max: %f, min: %f", max, min);
	}

	
	return getRandomNumberInt((int)(min*10000), (int)(max*10000))/10000.0f;
}

/**
Get document root of springboard
*/
NSString* getDocumentRoot()
{
    //NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [NSString stringWithFormat:@"/var/mobile/Library/%s/" ,DOCUMENT_ROOT_FOLDER_NAME];
}

/**
Get scripts path
*/
NSString* getScriptsFolder()
{
    //NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [NSString stringWithFormat:@"%@/%s/", getDocumentRoot(), SCRIPT_FOLDER_NAME];
}

/**
Get config dir
*/
NSString *getConfigFilePath()
{
	return [getDocumentRoot() stringByAppendingPathComponent:@CONFIG_FOLDER_NAME];
}

NSString *getCommonConfigFilePath()
{
    return [getConfigFilePath() stringByAppendingPathComponent:@COMMON_CONFIG_NAME];
}

void swapCGFloat(CGFloat *a, CGFloat *b)
{
	CGFloat temp = *a;
	*a = *b;
	*b = temp;
}

// Spawn `/bin/sh -c command` via posix_spawn. Raw fork() is blocked by the
// sandbox in a SpringBoard-injected tweak on some jailbreaks (palera1n-rootless,
// certain roothide setups), which surfaces to users as "Python script exited
// with code -1" with an empty log. posix_spawn is the supported path.
pid_t system2(const char *command, int *infp, int *outfp)
{
    return system2Cancelable(command, infp, outfp, NULL, NULL);
}

pid_t system2Cancelable(const char *command, int *infp, int *outfp,
                        pid_t *processGroup, volatile sig_atomic_t *cancelRequested)
{
    int p_stdin[2] = {-1, -1};
    int p_stdout[2] = {-1, -1};
    if (processGroup) *processGroup = 0;

    if (pipe(p_stdin) == -1) {
        NSLog(@"com.zjx.springboard: system2 pipe(stdin) failed: %s", strerror(errno));
        return -1;
    }

    if (pipe(p_stdout) == -1) {
        NSLog(@"com.zjx.springboard: system2 pipe(stdout) failed: %s", strerror(errno));
        close(p_stdin[0]);
        close(p_stdin[1]);
        return -1;
    }

    const char *shellPath = jbroot("/bin/sh");
    if (!shellPath || access(shellPath, X_OK) != 0) {
        // jbroot() returned something unusable; try known rootless fallbacks.
        static const char *candidates[] = {
            "/var/jb/bin/sh",
            "/var/jb/usr/bin/sh",
            "/bin/sh",
            "/usr/bin/sh",
            NULL
        };
        shellPath = NULL;
        for (int i = 0; candidates[i]; ++i) {
            if (access(candidates[i], X_OK) == 0) { shellPath = candidates[i]; break; }
        }
        if (!shellPath) {
            NSLog(@"com.zjx.springboard: system2 could not locate a usable /bin/sh");
            close(p_stdin[0]); close(p_stdin[1]);
            close(p_stdout[0]); close(p_stdout[1]);
            return -1;
        }
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);

    // stdin: child reads from p_stdin[0]
    posix_spawn_file_actions_adddup2(&actions, p_stdin[0], STDIN_FILENO);
    posix_spawn_file_actions_addclose(&actions, p_stdin[0]);
    posix_spawn_file_actions_addclose(&actions, p_stdin[1]);

    if (outfp == NULL) {
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
        posix_spawn_file_actions_addclose(&actions, p_stdout[0]);
        posix_spawn_file_actions_addclose(&actions, p_stdout[1]);
    } else {
        posix_spawn_file_actions_adddup2(&actions, p_stdout[1], STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&actions, p_stdout[1], STDERR_FILENO);
        posix_spawn_file_actions_addclose(&actions, p_stdout[0]);
        posix_spawn_file_actions_addclose(&actions, p_stdout[1]);
    }

    posix_spawnattr_t attrs;
    posix_spawnattr_init(&attrs);
    // Reset signal handlers and clear any inherited signal mask so the shell
    // doesn't inherit SpringBoard's oddities.
    sigset_t emptyset;
    sigemptyset(&emptyset);
    posix_spawnattr_setsigmask(&attrs, &emptyset);
    short spawnFlags = POSIX_SPAWN_SETSIGMASK;
    if (processGroup) {
        // A dedicated process group lets ScriptPlayer stop the shell, Python,
        // and the log pipeline together without killing unrelated Python jobs.
        posix_spawnattr_setpgroup(&attrs, 0);
        spawnFlags |= POSIX_SPAWN_SETPGROUP;
    }
    posix_spawnattr_setflags(&attrs, spawnFlags);

    char * const argv[] = {
        (char *)"sh",
        (char *)"-c",
        (char *)command,
        NULL
    };
    extern char **environ;

    pid_t pid = 0;
    int spawnErr = posix_spawn(&pid, shellPath, &actions, &attrs, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attrs);

    if (spawnErr != 0) {
        NSLog(@"com.zjx.springboard: system2 posix_spawn(%s) failed: %s (%d)",
              shellPath, strerror(spawnErr), spawnErr);
        close(p_stdin[0]); close(p_stdin[1]);
        close(p_stdout[0]); close(p_stdout[1]);
        return -1;
    }
    if (processGroup) *processGroup = pid;
    if (cancelRequested && *cancelRequested) {
        kill(-pid, SIGKILL);
    }

    close(p_stdin[0]);
    close(p_stdout[1]);

    if (infp == NULL) {
        close(p_stdin[1]);
    } else {
        *infp = p_stdin[1];
    }

    if (outfp == NULL) {
        close(p_stdout[0]);
    } else {
        *outfp = p_stdout[0];
    }

    int status = 0;
    if (waitpid(pid, &status, 0) == -1) {
        NSLog(@"com.zjx.springboard: system2 waitpid failed: %s", strerror(errno));
        if (processGroup) *processGroup = 0;
        return -1;
    }
    if (processGroup) *processGroup = 0;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -1;
}

/*
Record a main-queue UI exception instead of letting it kill SpringBoard.

Two destinations on purpose: NSLog lands in the unified system log, while the
file stays on the device and can be pulled back over the socket channel the
tweak already exposes. Without that file the reason for the failure is lost,
which is how this tweak kept dropping devices into safe mode unnoticed.
*/
void ZXLogUIException(NSException *exception)
{
    NSLog(@"### com.zjx.springboard: uncaught exception in main-queue block: %@ -- %@\n%@",
          exception.name, exception.reason, [exception callStackSymbols]);

    @try {
        NSString *folder = @"/var/mobile/Library/ZXTouch";
        [[NSFileManager defaultManager] createDirectoryAtPath:folder
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];

        NSString *entry = [NSString stringWithFormat:@"[%@] %@ -- %@\n%@\n\n",
                           [NSDate date], exception.name, exception.reason,
                           [exception callStackSymbols]];
        NSData *data = [entry dataUsingEncoding:NSUTF8StringEncoding];
        NSString *path = [folder stringByAppendingPathComponent:@"pccontrol-ui-exceptions.log"];

        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle)
        {
            [handle seekToEndOfFile];
            [handle writeData:data];
            [handle closeFile];
        }
        else
        {
            [data writeToFile:path atomically:NO];
        }
    }
    @catch (NSException *ignored)
    {
        // Logging must never itself become the reason SpringBoard dies.
    }
}

#pragma mark - 键盘避让 / 数值步进器

// 键盘顶边（屏幕坐标）；<=0 表示键盘没出来
static CGFloat gZXKeyboardTop = 0;
static BOOL gZXKeyboardObserved = NO;

static void ZXEnsureKeyboardObserved(void)
{
    if (gZXKeyboardObserved) return;
    gZXKeyboardObserved = YES;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserverForName:UIKeyboardWillChangeFrameNotification object:nil
                         queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        CGRect frame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
        CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
        gZXKeyboardTop = (frame.origin.y < screenH - 1.0) ? frame.origin.y : 0;
    }];
    [center addObserverForName:UIKeyboardWillHideNotification object:nil
                         queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        gZXKeyboardTop = 0;
    }];
}

CGFloat ZXKeyboardTopForView(UIView *view)
{
    ZXEnsureKeyboardObserved();
    if (gZXKeyboardTop <= 0 || !view.window) return CGFLOAT_MAX;
    // 键盘 frame 是屏幕坐标，全屏窗口下和窗口坐标一致
    CGRect probe = [view convertRect:CGRectMake(0, gZXKeyboardTop, 1, 1) fromView:nil];
    return probe.origin.y;
}

UIView *ZXFirstResponderView(UIView *root)
{
    if (!root) return nil;
    if (root.isFirstResponder) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = ZXFirstResponderView(sub);
        if (found) return found;
    }
    return nil;
}

void ZXMakeWindowKeyIfNeeded(UIWindow *window)
{
    if (window && !window.isKeyWindow) [window makeKeyWindow];
}

// 点一下箭头：按当前值的量级选步长，改完触发 EditingChanged 让调用方落盘
static void ZXStepNumberField(UITextField *field, BOOL integer, double fixedStep, NSInteger direction)
{
    double value = field.text.doubleValue;
    double step;
    if (fixedStep > 0) {
        step = fixedStep;
    } else if (integer) {
        step = 1.0;
    } else {
        double magnitude = fabs(value);
        if (magnitude >= 100.0) step = 10.0;
        else if (magnitude >= 10.0) step = 1.0;
        else if (magnitude >= 1.0) step = 0.1;
        else step = 0.01;
    }
    value += step * direction;
    if (value < 0) value = 0;
    field.text = integer ? [NSString stringWithFormat:@"%.0f", value]
                         : [NSString stringWithFormat:@"%.4g", value];
    [field sendActionsForControlEvents:UIControlEventEditingChanged];
}

UIView *ZXMakeNumberStepperStep(UITextField *field, BOOL integer, double step)
{
    if (!field) return nil;
    const CGFloat width = 24.0f, half = 15.0f;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, half * 2)];
    box.backgroundColor = [UIColor clearColor];

    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:8 weight:UIImageSymbolWeightBold];
    NSArray<NSString *> *symbols = @[ @"chevron.up", @"chevron.down" ];
    for (NSInteger i = 0; i < 2; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(0, i * half, width, half);
        btn.tintColor = [UIColor secondaryLabelColor];
        [btn setImage:[UIImage systemImageNamed:symbols[i] withConfiguration:cfg]
             forState:UIControlStateNormal];
        NSInteger direction = (i == 0) ? 1 : -1;
        [btn addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
            ZXStepNumberField(field, integer, step, direction);
        }] forControlEvents:UIControlEventTouchUpInside];
        [box addSubview:btn];
    }
    return box;
}

UIView *ZXMakeNumberStepper(UITextField *field, BOOL integer)
{
    return ZXMakeNumberStepperStep(field, integer, 0);
}

// 键盘上方工具条：左侧实时显示「字段名: 当前值」（游戏式，浮窗被键盘挡住也能看见输入内容），
// 右侧「完成」收键盘。挂在输入框的 inputAccessoryView 上。
UIView *ZXFieldKeyboardAccessory(UITextField *field, NSString *title)
{
    if (!field) return nil;
    UIToolbar *bar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 220, 30)];
    label.font = [UIFont systemFontOfSize:13];
    label.textColor = [UIColor secondaryLabelColor];
    label.numberOfLines = 1;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.7;
    NSString *prefix = title.length ? [NSString stringWithFormat:@"%@：", title] : @"";
    void (^refresh)(void) = ^{
        label.text = [NSString stringWithFormat:@"%@%@", prefix, field.text.length ? field.text : @"（空）"];
    };
    refresh();
    // block 若强捕 field 会形成 field→action→field 自环泄漏，走 weak
    __weak UITextField *weakField = field;
    [field addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        UITextField *f = weakField;
        if (!f) return;
        label.text = [NSString stringWithFormat:@"%@%@", prefix, f.text.length ? f.text : @"（空）"];
    }] forControlEvents:UIControlEventEditingChanged];

    UIBarButtonItem *valueItem = [[UIBarButtonItem alloc] initWithCustomView:label];
    UIBarButtonItem *space = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                           target:nil action:nil];
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithPrimaryAction:
        [UIAction actionWithTitle:@"完成" image:nil identifier:nil handler:^(__kindof UIAction *a) {
            [weakField endEditing:YES];
        }]];
    bar.items = @[valueItem, space, done];
    return bar;
}

CGFloat ZXScrollResponderIntoView(UIView *responder, UIScrollView *scroll, CGFloat keyboardTop)
{
    if (!responder) return 0;
    UIWindow *window = responder.window;
    if (!window) return 0;

    // 1) 先滚动：把输入框滚进可见区（并尽量靠上，给键盘腾地方）
    CGFloat scrolled = 0;
    if (scroll && [responder isDescendantOfView:scroll]) {
        CGRect frame = [responder convertRect:responder.bounds toView:scroll];
        CGFloat offset = scroll.contentOffset.y;
        CGFloat visible = scroll.bounds.size.height;
        CGFloat target = offset;
        if (CGRectGetMaxY(frame) + 10.0 > offset + visible) target = CGRectGetMaxY(frame) + 10.0 - visible;
        if (frame.origin.y - 10.0 < target) target = frame.origin.y - 10.0;
        CGFloat maxOffset = MAX(scroll.contentSize.height - visible, 0);
        target = MIN(MAX(target, 0), maxOffset);
        if (fabs(target - offset) > 0.5) {
            [scroll setContentOffset:CGPointMake(scroll.contentOffset.x, target) animated:YES];
            scrolled = offset - target;   // 内容上移多少，输入框就跟着上移多少
        }
    }

    // 2) 滚完还挡着的话，返回还要把卡片上移多少
    if (keyboardTop >= CGFLOAT_MAX - 1.0) return 0;
    CGRect inWindow = [responder convertRect:responder.bounds toView:window];
    // 内容下滚 target-offset 后，输入框在窗口里上移 (target-offset)；scrolled = offset-target
    // 是个负数或 0，所以新底边 = 旧底边 + scrolled。这里曾误写成「- scrolled」，
    // 会把上移量双倍算进 overlap，导致整张卡片被顶过头（编辑中间的框也把底部全掀到键盘上）。
    CGFloat overlap = CGRectGetMaxY(inWindow) + scrolled + 8.0 - keyboardTop;
    return overlap > 0 ? overlap : 0;
}

#pragma mark - 面板配色

// 同一种颜色给一深一浅两份，窗口定了 overrideUserInterfaceStyle，取到的就是对应那套
static UIColor *ZXDynamicColor(uint32_t light, uint32_t dark)
{
    UIColor *l = [UIColor colorWithRed:((light >> 16) & 0xFF) / 255.0
                                 green:((light >> 8) & 0xFF) / 255.0
                                  blue:(light & 0xFF) / 255.0 alpha:1];
    UIColor *d = [UIColor colorWithRed:((dark >> 16) & 0xFF) / 255.0
                                 green:((dark >> 8) & 0xFF) / 255.0
                                  blue:(dark & 0xFF) / 255.0 alpha:1];
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return (traits.userInterfaceStyle == UIUserInterfaceStyleDark) ? d : l;
    }];
}

UIColor *ZXPalette(ZXPaletteRole role)
{
    static NSArray<UIColor *> *colors = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const uint32_t light[] = { 0xF2F3F5, 0xFFFFFF, 0xE3E5E9, 0x1C1F24, 0x6B7280, 0xF7F8FA, 0x0FA98F, 0xE5484D, 0xB26A00 };
        const uint32_t dark[]  = { 0x15171C, 0x1E2026, 0x2A2D35, 0xE8EAED, 0x8B909A, 0x12141A, 0x2ED3B7, 0xFF5A5F, 0xFFB84D };
        NSMutableArray *list = [NSMutableArray arrayWithCapacity:ZXPalValue + 1];
        for (NSInteger i = 0; i <= ZXPalValue; i++) [list addObject:ZXDynamicColor(light[i], dark[i])];
        colors = list;
    });
    if (role < 0 || role >= (NSInteger)colors.count) return colors[ZXPalText];
    return colors[role];
}

UIColor *ZXColorFromHex(NSString *hex)
{
    if (![hex isKindOfClass:[NSString class]] || hex.length == 0) return nil;
    NSString *value = [hex stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([value hasPrefix:@"#"]) value = [value substringFromIndex:1];
    if (value.length != 6) return nil;
    unsigned int rgb = 0;
    if (![[NSScanner scannerWithString:value] scanHexInt:&rgb]) return nil;
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0 alpha:1];
}

#pragma mark - 随行小菜单

// 不是 alert：一个贴在锚点旁边的小卡片 + 一层透明遮罩，点别处就散
void ZXShowMiniMenuNearView(UIView *anchor, NSArray<NSDictionary *> *items)
{
    UIWindow *window = anchor.window;
    if (!window || items.count == 0) return;
    UIView *root = window.rootViewController.view;
    if (!root) return;

    const CGFloat menuW = 172.0f, rowH = 40.0f, pad = 6.0f;
    CGFloat menuH = pad * 2 + rowH * items.count;

    UIView *dim = [[UIView alloc] initWithFrame:root.bounds];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    __weak UIView *weakDim = dim;

    // 铺满的按钮当遮罩：点外层必然只走它（容器挂 tap 手势会和按钮抢触摸，踩过）
    UIButton *backdrop = [UIButton buttonWithType:UIButtonTypeCustom];
    backdrop.frame = dim.bounds;
    backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [backdrop addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
        [weakDim removeFromSuperview];
    }] forControlEvents:UIControlEventTouchUpInside];
    [dim addSubview:backdrop];

    UIView *menu = [[UIView alloc] initWithFrame:CGRectMake(0, 0, menuW, menuH)];
    menu.backgroundColor = ZXPalette(ZXPalCard);
    menu.layer.cornerRadius = 12;
    menu.layer.borderWidth = 1;
    menu.layer.borderColor = ZXPalette(ZXPalLine).CGColor;
    menu.layer.shadowColor = [UIColor blackColor].CGColor;
    menu.layer.shadowOpacity = 0.3f;
    menu.layer.shadowRadius = 10;
    menu.layer.shadowOffset = CGSizeMake(0, 3);
    [dim addSubview:menu];

    for (NSUInteger i = 0; i < items.count; i++) {
        NSDictionary *item = items[i];
        UIButton *row = [UIButton buttonWithType:UIButtonTypeSystem];
        row.frame = CGRectMake(pad, pad + rowH * i, menuW - pad * 2, rowH);
        row.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;

        BOOL destructive = [item[@"destructive"] boolValue];
        UIColor *tint = destructive ? ZXPalette(ZXPalDanger) : ZXPalette(ZXPalText);
        NSString *icon = item[@"icon"];
        CGFloat textX = 10.0f;
        if (icon.length > 0) {
            UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:icon]];
            iv.tintColor = tint;
            iv.contentMode = UIViewContentModeScaleAspectFit;
            iv.frame = CGRectMake(10, (rowH - 16) / 2.0f, 16, 16);
            iv.userInteractionEnabled = NO;
            [row addSubview:iv];
            textX = 34.0f;
        }
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(textX, 0, menuW - pad * 2 - textX - 6, rowH)];
        label.text = item[@"title"];
        label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        label.textColor = tint;
        label.userInteractionEnabled = NO;
        [row addSubview:label];

        [row addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a) {
            [weakDim removeFromSuperview];
            dispatch_block_t action = item[@"action"];
            if (action) action();
        }] forControlEvents:UIControlEventTouchUpInside];
        [menu addSubview:row];
    }

    // 位置：默认锚点下方、水平向屏幕中间靠；出屏就翻到锚点上方 / 夹回屏内
    CGRect a = [anchor convertRect:anchor.bounds toView:root];
    CGFloat x = CGRectGetMidX(a) - menuW / 2.0f;
    x = MAX(8.0f, MIN(root.bounds.size.width - menuW - 8.0f, x));
    CGFloat y = CGRectGetMaxY(a) + 6.0f;
    if (y + menuH > root.bounds.size.height - 8.0f) y = CGRectGetMinY(a) - 6.0f - menuH;
    if (y < 8.0f) y = 8.0f;
    menu.frame = CGRectMake(x, y, menuW, menuH);

    menu.alpha = 0;
    menu.transform = CGAffineTransformMakeScale(0.92f, 0.92f);
    [root addSubview:dim];
    [UIView animateWithDuration:0.15 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        menu.alpha = 1;
        menu.transform = CGAffineTransformIdentity;
    } completion:nil];
}

#pragma mark - 单步动作共用实现

@interface AVSystemController : NSObject
+ (instancetype)sharedAVSystemController;
- (BOOL)setVolumeTo:(float)volume forCategory:(NSString *)category;
- (BOOL)getVolume:(float *)volume forCategory:(NSString *)category;
@end

// 老系统的 WiFi 开关；新系统上这个类已经没了，只为让编译器认识 setWiFiEnabled: 这个选择子
@interface ZXWiFiManager : NSObject
+ (instancetype)sharedInstance;
- (void)setWiFiEnabled:(BOOL)enabled;
@end

static NSError *ZXActionError(NSString *message)
{
    return [NSError errorWithDomain:@"小新Lap" code:1
                          userInfo:@{NSLocalizedDescriptionKey: message ?: @"执行失败"}];
}

static void ZXRunOnMainSync(dispatch_block_t block)
{
    if ([NSThread isMainThread]) block();
    else dispatch_sync(dispatch_get_main_queue(), block);
}

BOOL ZXGoHome(NSError **error)
{
    Class sbClass = objc_getClass("SpringBoard");
    if (!sbClass) {
        if (error) *error = ZXActionError(@"当前系统不支持返回主屏幕。");
        return NO;
    }

    __block BOOL done = NO;
    ZXRunOnMainSync(^{
        @try {
            SpringBoard *sb = (SpringBoard *)[sbClass sharedApplication];
            if ([sb respondsToSelector:@selector(_simulateHomeButtonPress)]) {
                [sb _simulateHomeButtonPress];
                done = YES;
            }
        } @catch (NSException *exception) {
            NSLog(@"com.zjx.springboard: ZXGoHome failed: %@", exception.reason);
        }
    });

    if (!done && error) *error = ZXActionError(@"返回主屏幕失败。");
    return done;
}

BOOL ZXKillApp(NSString *bundleIdentifier, NSError **error)
{
    if (bundleIdentifier.length == 0) {
        if (error) *error = ZXActionError(@"没有指定要关闭的 App。");
        return NO;
    }

    Class ctrlClass = objc_getClass("SBApplicationController");
    if (!ctrlClass) {
        if (error) *error = ZXActionError(@"当前系统不支持关闭 App。");
        return NO;
    }

    __block pid_t pid = 0;
    ZXRunOnMainSync(^{
        @try {
            id ctrl = [ctrlClass sharedInstance];
            SBApplication *app = nil;
            if ([ctrl respondsToSelector:@selector(applicationWithBundleIdentifier:)]) {
                app = [ctrl applicationWithBundleIdentifier:bundleIdentifier];
            }
            if (!app && [ctrl respondsToSelector:@selector(allApplications)]) {
                for (SBApplication *candidate in [ctrl allApplications]) {
                    if ([[candidate bundleIdentifier] isEqualToString:bundleIdentifier]) {
                        app = candidate;
                        break;
                    }
                }
            }
            pid = app.pid;
        } @catch (NSException *exception) {
            NSLog(@"com.zjx.springboard: ZXKillApp lookup failed: %@", exception.reason);
        }
    });

    if (pid <= 0) {
        if (error) *error = ZXActionError(@"这个 App 当前没在运行。");
        return NO;
    }
    if (kill(pid, SIGKILL) != 0) {
        if (error) *error = ZXActionError([NSString stringWithFormat:@"关闭失败（pid %d, errno %d）。", pid, errno]);
        return NO;
    }
    return YES;
}

NSArray<NSDictionary *> *ZXInstalledApplications(void)
{
    NSMutableArray *result = [NSMutableArray array];
    Class ctrlClass = objc_getClass("SBApplicationController");
    if (!ctrlClass) return result;

    ZXRunOnMainSync(^{
        @try {
            id ctrl = [ctrlClass sharedInstance];
            for (SBApplication *app in [ctrl allApplications]) {
                NSString *bundle = nil;
                if ([app respondsToSelector:@selector(bundleIdentifier)]) bundle = [app bundleIdentifier];
                if (bundle.length == 0 && [app respondsToSelector:@selector(displayIdentifier)]) {
                    bundle = [app displayIdentifier];
                }
                if (bundle.length == 0) continue;
                NSString *name = [app respondsToSelector:@selector(displayName)] ? [app displayName] : nil;
                if (name.length == 0) name = bundle;
                [result addObject:@{ @"bundle": bundle, @"name": name, @"system": @([bundle hasPrefix:@"com.apple."]) }];
            }
        } @catch (NSException *exception) {
            NSLog(@"com.zjx.springboard: ZXInstalledApplications failed: %@", exception.reason);
        }
    });

    return [result sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
}

static NSString *ZXMarketingNameForMachine(NSString *machine)
{
    static NSDictionary<NSString *, NSString *> *table = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            @"iPad1,1": @"iPad（第1代）",
            @"iPad2,1": @"iPad 2", @"iPad2,2": @"iPad 2", @"iPad2,3": @"iPad 2", @"iPad2,4": @"iPad 2",
            @"iPad2,5": @"iPad mini", @"iPad2,6": @"iPad mini", @"iPad2,7": @"iPad mini",
            @"iPad3,1": @"iPad（第3代）", @"iPad3,2": @"iPad（第3代）", @"iPad3,3": @"iPad（第3代）",
            @"iPad3,4": @"iPad（第4代）", @"iPad3,5": @"iPad（第4代）", @"iPad3,6": @"iPad（第4代）",
            @"iPad4,1": @"iPad Air", @"iPad4,2": @"iPad Air", @"iPad4,3": @"iPad Air",
            @"iPad4,4": @"iPad mini 2", @"iPad4,5": @"iPad mini 2", @"iPad4,6": @"iPad mini 2",
            @"iPad4,7": @"iPad mini 3", @"iPad4,8": @"iPad mini 3", @"iPad4,9": @"iPad mini 3",
            @"iPad5,1": @"iPad mini 4", @"iPad5,2": @"iPad mini 4",
            @"iPad5,3": @"iPad Air 2", @"iPad5,4": @"iPad Air 2",
            @"iPad6,3": @"iPad Pro（9.7 英寸）", @"iPad6,4": @"iPad Pro（9.7 英寸）",
            @"iPad6,7": @"iPad Pro（12.9 英寸）", @"iPad6,8": @"iPad Pro（12.9 英寸）",
            @"iPad6,11": @"iPad（第5代）", @"iPad6,12": @"iPad（第5代）",
            @"iPad7,1": @"iPad Pro（12.9 英寸，第2代）", @"iPad7,2": @"iPad Pro（12.9 英寸，第2代）",
            @"iPad7,3": @"iPad Pro（10.5 英寸）", @"iPad7,4": @"iPad Pro（10.5 英寸）",
            @"iPad7,5": @"iPad（第6代）", @"iPad7,6": @"iPad（第6代）",
            @"iPad7,11": @"iPad（第7代）", @"iPad7,12": @"iPad（第7代）",
            @"iPad8,1": @"iPad Pro（11 英寸）", @"iPad8,2": @"iPad Pro（11 英寸）",
            @"iPad8,3": @"iPad Pro（11 英寸）", @"iPad8,4": @"iPad Pro（11 英寸）",
            @"iPad8,5": @"iPad Pro（12.9 英寸，第3代）", @"iPad8,6": @"iPad Pro（12.9 英寸，第3代）",
            @"iPad8,7": @"iPad Pro（12.9 英寸，第3代）", @"iPad8,8": @"iPad Pro（12.9 英寸，第3代）",
            @"iPad8,9": @"iPad Pro（11 英寸，第2代）", @"iPad8,10": @"iPad Pro（11 英寸，第2代）",
            @"iPad8,11": @"iPad Pro（12.9 英寸，第4代）", @"iPad8,12": @"iPad Pro（12.9 英寸，第4代）",
            @"iPad11,1": @"iPad mini（第5代）", @"iPad11,2": @"iPad mini（第5代）",
            @"iPad11,3": @"iPad Air（第3代）", @"iPad11,4": @"iPad Air（第3代）",
            @"iPad11,6": @"iPad（第8代）", @"iPad11,7": @"iPad（第8代）",
            @"iPad12,1": @"iPad（第9代）", @"iPad12,2": @"iPad（第9代）",
            @"iPad13,1": @"iPad Air（第4代）", @"iPad13,2": @"iPad Air（第4代）",
            @"iPad13,4": @"iPad Pro（11 英寸，第3代）", @"iPad13,5": @"iPad Pro（11 英寸，第3代）",
            @"iPad13,6": @"iPad Pro（11 英寸，第3代）", @"iPad13,7": @"iPad Pro（11 英寸，第3代）",
            @"iPad13,8": @"iPad Pro（12.9 英寸，第5代）", @"iPad13,9": @"iPad Pro（12.9 英寸，第5代）",
            @"iPad13,10": @"iPad Pro（12.9 英寸，第5代）", @"iPad13,11": @"iPad Pro（12.9 英寸，第5代）",
            @"iPad13,16": @"iPad Air（第5代）", @"iPad13,17": @"iPad Air（第5代）",
            @"iPad13,18": @"iPad（第10代）", @"iPad13,19": @"iPad（第10代）",
            @"iPad14,1": @"iPad mini（第6代）", @"iPad14,2": @"iPad mini（第6代）",
            @"iPad14,3": @"iPad Pro（11 英寸，第4代）", @"iPad14,4": @"iPad Pro（11 英寸，第4代）",
            @"iPad14,5": @"iPad Pro（12.9 英寸，第6代）", @"iPad14,6": @"iPad Pro（12.9 英寸，第6代）",
            @"iPad14,8": @"iPad Air 11 英寸（M2）", @"iPad14,9": @"iPad Air 11 英寸（M2）",
            @"iPad14,10": @"iPad Air 13 英寸（M2）", @"iPad14,11": @"iPad Air 13 英寸（M2）",
            @"iPad16,1": @"iPad mini（A17 Pro）", @"iPad16,2": @"iPad mini（A17 Pro）",
            @"iPad16,3": @"iPad Pro 11 英寸（M4）", @"iPad16,4": @"iPad Pro 11 英寸（M4）",
            @"iPad16,5": @"iPad Pro 13 英寸（M4）", @"iPad16,6": @"iPad Pro 13 英寸（M4）",

            @"iPhone1,1": @"iPhone", @"iPhone1,2": @"iPhone 3G", @"iPhone2,1": @"iPhone 3GS",
            @"iPhone3,1": @"iPhone 4", @"iPhone3,2": @"iPhone 4", @"iPhone3,3": @"iPhone 4",
            @"iPhone4,1": @"iPhone 4S",
            @"iPhone5,1": @"iPhone 5", @"iPhone5,2": @"iPhone 5",
            @"iPhone5,3": @"iPhone 5c", @"iPhone5,4": @"iPhone 5c",
            @"iPhone6,1": @"iPhone 5s", @"iPhone6,2": @"iPhone 5s",
            @"iPhone7,1": @"iPhone 6 Plus", @"iPhone7,2": @"iPhone 6",
            @"iPhone8,1": @"iPhone 6s", @"iPhone8,2": @"iPhone 6s Plus", @"iPhone8,4": @"iPhone SE（第1代）",
            @"iPhone9,1": @"iPhone 7", @"iPhone9,2": @"iPhone 7 Plus", @"iPhone9,3": @"iPhone 7", @"iPhone9,4": @"iPhone 7 Plus",
            @"iPhone10,1": @"iPhone 8", @"iPhone10,2": @"iPhone 8 Plus", @"iPhone10,3": @"iPhone X",
            @"iPhone10,4": @"iPhone 8", @"iPhone10,5": @"iPhone 8 Plus", @"iPhone10,6": @"iPhone X",
            @"iPhone11,2": @"iPhone XS", @"iPhone11,4": @"iPhone XS Max", @"iPhone11,6": @"iPhone XS Max", @"iPhone11,8": @"iPhone XR",
            @"iPhone12,1": @"iPhone 11", @"iPhone12,3": @"iPhone 11 Pro", @"iPhone12,5": @"iPhone 11 Pro Max", @"iPhone12,8": @"iPhone SE（第2代）",
            @"iPhone13,1": @"iPhone 12 mini", @"iPhone13,2": @"iPhone 12", @"iPhone13,3": @"iPhone 12 Pro", @"iPhone13,4": @"iPhone 12 Pro Max",
            @"iPhone14,2": @"iPhone 13 Pro", @"iPhone14,3": @"iPhone 13 Pro Max", @"iPhone14,4": @"iPhone 13 mini",
            @"iPhone14,5": @"iPhone 13", @"iPhone14,6": @"iPhone SE（第3代）",
            @"iPhone14,7": @"iPhone 14", @"iPhone14,8": @"iPhone 14 Plus",
            @"iPhone15,2": @"iPhone 14 Pro", @"iPhone15,3": @"iPhone 14 Pro Max",
            @"iPhone15,4": @"iPhone 15", @"iPhone15,5": @"iPhone 15 Plus",
            @"iPhone16,1": @"iPhone 15 Pro", @"iPhone16,2": @"iPhone 15 Pro Max",
            @"iPhone17,1": @"iPhone 16 Pro", @"iPhone17,2": @"iPhone 16 Pro Max",
            @"iPhone17,3": @"iPhone 16", @"iPhone17,4": @"iPhone 16 Plus", @"iPhone17,5": @"iPhone 16e",
        };
    });
    NSString *name = machine.length > 0 ? table[machine] : nil;
    if (name.length > 0) return name;
    return machine.length > 0 ? machine : @"未知";
}

NSDictionary *ZXDeviceSummary(void)
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    struct utsname info;
    NSString *machine = @"";
    if (uname(&info) == 0) {
        machine = [NSString stringWithCString:info.machine encoding:NSUTF8StringEncoding] ?: @"";
    }
    d[@"machine"] = machine;
    d[@"marketing"] = ZXMarketingNameForMachine(machine);
    d[@"model"] = [UIDevice currentDevice].model ?: @"";
    d[@"name"] = [UIDevice currentDevice].name ?: @"";
    d[@"system"] = [UIDevice currentDevice].systemVersion ?: @"";
    d[@"ram_bytes"] = @([NSProcessInfo processInfo].physicalMemory);
    d[@"cores"] = @([NSProcessInfo processInfo].activeProcessorCount);

    __block CGSize size = CGSizeZero;
    __block CGFloat scale = 1.0;
    ZXRunOnMainSync(^{
        UIScreen *screen = [UIScreen mainScreen];
        size = screen.bounds.size;
        scale = screen.scale;
    });
    d[@"screen_points_w"] = @(size.width);
    d[@"screen_points_h"] = @(size.height);
    d[@"screen_scale"] = @(scale);
    d[@"screen_pixels_w"] = @(size.width * scale);
    d[@"screen_pixels_h"] = @(size.height * scale);
    return d;
}

NSDictionary *ZXBatterySummary(void)
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"available"] = @NO;

    io_service_t svc = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching("AppleSmartBattery"));
    if (svc) {
        CFMutableDictionaryRef props = NULL;
        if (IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
            NSDictionary *p = (__bridge_transfer NSDictionary *)props;
            d[@"available"] = @YES;
            NSNumber *cycles = p[@"CycleCount"];
            NSNumber *design = p[@"DesignCapacity"];
            NSNumber *maxCap = p[@"NominalChargeCapacity"] ?: p[@"AppleRawMaxCapacity"] ?: p[@"MaxCapacity"];
            if (cycles) d[@"cycle_count"] = cycles;
            if (design) d[@"design_capacity"] = design;
            if (maxCap) d[@"max_capacity"] = maxCap;
            double designVal = [design doubleValue];
            double maxVal = [maxCap doubleValue];
            if (designVal > 0 && maxVal > 0) d[@"health_percent"] = @(maxVal / designVal * 100.0);
        }
        IOObjectRelease(svc);
    }

    UIDevice *dev = [UIDevice currentDevice];
    [dev setBatteryMonitoringEnabled:YES];
    double level = dev.batteryLevel;
    d[@"current_percent"] = (level >= 0) ? @(level * 100.0) : @(-1);
    d[@"charging"] = @(dev.batteryState == UIDeviceBatteryStateCharging || dev.batteryState == UIDeviceBatteryStateFull);
    return d;
}

NSDictionary *ZXJailbreakSummary(void)
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];

    char buf[PATH_MAX];
    ssize_t n = readlink("/var/jb", buf, sizeof(buf) - 1);
    if (n > 0) {
        d[@"varjb_target"] = [[NSString alloc] initWithBytes:buf length:(NSUInteger)n encoding:NSUTF8StringEncoding] ?: @"";
    } else {
        d[@"varjb_target"] = @"";
    }

    NSString *prefixProbe = jbroot(@"/__zx_probe__");
    NSString *prefix = @"";
    if ([prefixProbe hasSuffix:@"/__zx_probe__"]) {
        prefix = [prefixProbe substringToIndex:prefixProbe.length - (NSUInteger)strlen("/__zx_probe__")];
    }
    d[@"jbroot_prefix"] = prefix ?: @"";
    d[@"type"] = (prefix.length > 0) ? @"rootless（无根）" : @"rootful（有根）";

    NSArray<NSString *> *markers = @[
        @"/var/jb/.procursus_strapped",
        @"/var/jb/.installed_palera1n",
        @"/var/jb/.installed_odyssey",
        @"/var/jb/.installed_dopamine",
        @"/var/jb/.installed_unc0ver",
        @"/var/jb/.installed_checkra1n",
        @"/var/jb/basebin/jbctl",
    ];
    NSMutableArray<NSString *> *foundMarkers = [NSMutableArray array];
    for (NSString *marker in markers) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:marker]) {
            [foundMarkers addObject:marker.lastPathComponent];
        }
    }
    d[@"bootstrap_markers"] = foundMarkers;

    NSMutableArray<NSString *> *tools = [NSMutableArray array];
    NSArray<NSDictionary *> *toolsMap = @[
        @{ @"name": @"Sileo", @"parts": @[ @"Sileo.app", @"org.coolstar.SileoStore" ] },
        @{ @"name": @"Zebra", @"parts": @[ @"Zebra.app", @"xyz.willy.Zebra" ] },
        @{ @"name": @"Dopamine", @"parts": @[ @"Dopamine.app", @"com.opa334.Dopamine" ] },
        @{ @"name": @"TrollStore", @"parts": @[ @"TrollStore.app", @"com.opa334.TrollStore" ] },
        @{ @"name": @"palera1n", @"parts": @[ @"palera1n.app", @"com.palera1n.palera1n" ] },
    ];
    NSArray<NSString *> *appDirs = @[ jbroot(@"/Applications"), @"/Applications", @"/var/jb/Applications" ];
    for (NSDictionary *entry in toolsMap) {
        BOOL hit = NO;
        for (NSString *part in entry[@"parts"]) {
            if ([part hasSuffix:@".app"]) {
                for (NSString *dir in appDirs) {
                    NSString *full = [dir stringByAppendingPathComponent:part];
                    if ([[NSFileManager defaultManager] fileExistsAtPath:full]) { hit = YES; break; }
                }
            } else if (objc_getClass("SBApplicationController")) {
                Class ctrlClass = objc_getClass("SBApplicationController");
                __block BOOL found = NO;
                ZXRunOnMainSync(^{
                    @try {
                        id ctrl = [ctrlClass sharedInstance];
                        if ([ctrl respondsToSelector:@selector(applicationWithBundleIdentifier:)]) {
                            found = ([ctrl applicationWithBundleIdentifier:part] != nil);
                        }
                    } @catch (NSException *e) { }
                });
                if (found) { hit = YES; }
            }
            if (hit) break;
        }
        if (hit) [tools addObject:entry[@"name"]];
    }
    d[@"tools"] = tools;
    return d;
}

static NSString *ZXFileBirthTimeString(NSString *path)
{
    struct stat st;
    if (stat(path.UTF8String, &st) != 0) return @"";
    time_t t = st.st_birthtimespec.tv_sec;
    if (t <= 0) t = st.st_ctimespec.tv_sec;
    if (t <= 0) return @"";
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)t];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm";
    return [fmt stringFromDate:date];
}

NSDictionary *ZXInstallSummary(void)
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];

    Dl_info dlInfo = {0};
    if (dladdr((void *)ZXDeviceSummary, &dlInfo) && dlInfo.dli_fname) {
        NSString *dylibPath = [NSString stringWithUTF8String:dlInfo.dli_fname] ?: @"";
        d[@"dylib_path"] = dylibPath;
        if (dylibPath.length > 0) d[@"dylib_time"] = ZXFileBirthTimeString(dylibPath);
    }

    NSArray<NSString *> *appCandidates = @[
        jbroot(@"/Applications/zxtouch.app"),
        @"/var/jb/Applications/zxtouch.app",
        @"/Applications/zxtouch.app",
    ];
    for (NSString *appPath in appCandidates) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:appPath]) {
            d[@"app_path"] = appPath;
            d[@"app_time"] = ZXFileBirthTimeString(appPath);
            break;
        }
    }
    return d;
}

static NSArray<NSString *> *ZXRingtoneFolders(void)
{
    return @[ @"/Library/Ringtones", @"/var/jb/Library/Ringtones" ];
}

static NSArray<NSString *> *ZXUserRingtoneFolders(void)
{
    return @[ @"/var/mobile/Media/iTunes_Control/Ringtones" ];
}

// 爱思助手 / iTunes 导入的 m4r，文件名常被改成乱码（如 ENMK.m4r），真名在 moov 里的 ©nam 原子
// 不按原子树逐层走：直接全文件扫 0xA9 'n' 'a' 'm' 签名，后面必须紧跟 data 子原子才算命中
static NSString *ZXRingtoneEmbeddedName(NSString *path)
{
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (data.length < 32) return nil;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger total = data.length;

    for (NSUInteger i = 0; i + 28 <= total; i++) {
        if (bytes[i] != 0xA9 || bytes[i + 1] != 'n' || bytes[i + 2] != 'a' || bytes[i + 3] != 'm') continue;
        if (memcmp(bytes + i + 8, "data", 4) != 0) continue;

        uint32_t dataSize = ((uint32_t)bytes[i + 4] << 24) | ((uint32_t)bytes[i + 5] << 16) |
                            ((uint32_t)bytes[i + 6] << 8) | bytes[i + 7];
        if (dataSize < 16) continue;

        NSUInteger textStart = i + 20;   // data 原子头：size + 'data' + flags + locale
        NSUInteger textEnd = textStart + (NSUInteger)dataSize - 16;
        if (textEnd > total) textEnd = total;
        if (textStart >= textEnd) continue;

        NSUInteger len = textEnd - textStart;
        while (len > 0 && bytes[textStart + len - 1] == 0) len--;
        if (len == 0) continue;

        NSString *name = [[NSString alloc] initWithBytes:bytes + textStart
                                                  length:len
                                                encoding:NSUTF8StringEncoding];
        if (name.length == 0) {
            name = [[NSString alloc] initWithBytes:bytes + textStart
                                            length:len
                                          encoding:NSUTF16StringEncoding];
        }
        if (name.length > 0) return name;
    }
    return nil;
}

NSArray<NSDictionary *> *ZXRingtoneItems(void)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *okExtensions = @[ @"m4r", @"m4a", @"mp3", @"caf", @"aiff", @"wav" ];
    NSMutableArray *items = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    for (NSString *folder in ZXUserRingtoneFolders()) {
        for (NSString *file in [fm contentsOfDirectoryAtPath:folder error:nil]) {
            if (![okExtensions containsObject:[file pathExtension].lowercaseString]) continue;
            NSString *full = [folder stringByAppendingPathComponent:file];
            if ([seen containsObject:full]) continue;
            [seen addObject:full];
            NSString *name = ZXRingtoneEmbeddedName(full);
            if (name.length == 0) name = [file stringByDeletingPathExtension];
            [items addObject:@{ @"name": name, @"path": full, @"user": @YES }];
        }
    }
    for (NSString *folder in ZXRingtoneFolders()) {
        for (NSString *file in [fm contentsOfDirectoryAtPath:folder error:nil]) {
            if (![okExtensions containsObject:[file pathExtension].lowercaseString]) continue;
            NSString *full = [folder stringByAppendingPathComponent:file];
            if ([seen containsObject:full]) continue;
            [seen addObject:full];
            [items addObject:@{ @"name": file, @"path": full, @"user": @NO }];
        }
    }

    return [items sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL userA = [a[@"user"] boolValue], userB = [b[@"user"] boolValue];
        if (userA != userB) return userA ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
}

BOOL ZXPlayRingtone(NSString *path, double seconds, NSError **error)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *resolved = path ?: @"";
    if (![fm fileExistsAtPath:resolved]) {
        // 允许只填文件名：到系统铃声目录里找
        NSString *name = [path lastPathComponent];
        resolved = @"";
        for (NSString *folder in ZXRingtoneFolders()) {
            NSString *candidate = [folder stringByAppendingPathComponent:name ?: @""];
            if (name.length > 0 && [fm fileExistsAtPath:candidate]) { resolved = candidate; break; }
        }
    }
    if (resolved.length == 0 || ![fm fileExistsAtPath:resolved]) {
        if (error) *error = ZXActionError([NSString stringWithFormat:@"找不到铃声：%@", path ?: @""]);
        return NO;
    }

    // 静态持有：播放期间必须保证 AVAudioPlayer 不被 ARC 提前释放
    static AVAudioPlayer *playing = nil;

    @try {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setCategory:AVAudioSessionCategoryPlayback error:nil];
        [session setActive:YES error:nil];

        NSError *playerError = nil;
        AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:resolved]
                                                                      error:&playerError];
        if (!player) {
            if (error) *error = ZXActionError([NSString stringWithFormat:@"无法播放：%@",
                                               playerError.localizedDescription ?: @"格式不支持"]);
            return NO;
        }

        playing = player;
        player.numberOfLoops = -1;
        [player play];

        if (seconds > 0) {
            double capped = MIN(seconds, 3600.0);
            usleep((useconds_t)llround(capped * 1e6));
            [player stop];
        }
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = ZXActionError(exception.reason ?: @"播放铃声失败。");
        return NO;
    }
}

BOOL ZXSetVolume(NSString *mode, double value, NSError **error)
{
    static dispatch_once_t once;
    static Class volumeClass = Nil;
    dispatch_once(&once, ^{
        if (dlopen("/System/Library/PrivateFrameworks/Celestial.framework/Celestial", RTLD_LAZY)) {
            volumeClass = objc_getClass("AVSystemController");
        }
    });

    if (!volumeClass) {
        if (error) *error = ZXActionError(@"当前系统不支持直接调整音量。");
        return NO;
    }

    @try {
        id controller = [volumeClass sharedAVSystemController];
        if (!controller) {
            if (error) *error = ZXActionError(@"拿不到系统音量控制器。");
            return NO;
        }

        NSString *category = @"Audio/Video";
        float current = 0.0f;
        [(AVSystemController *)controller getVolume:&current forCategory:category];

        float target = current;
        if ([mode isEqualToString:@"delta"]) {
            target = current + (float)(value / 16.0);
        } else if ([mode isEqualToString:@"deltaPercent"]) {
            target = current + (float)(value / 100.0);
        } else {
            target = (float)(value / 100.0);
        }
        target = MAX(0.0f, MIN(1.0f, target));

        if (![(AVSystemController *)controller setVolumeTo:target forCategory:category]) {
            if (error) *error = ZXActionError(@"设置音量失败。");
            return NO;
        }
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = ZXActionError(exception.reason ?: @"调整音量失败。");
        return NO;
    }
}

BOOL ZXStopAllScripts(NSError **error)
{
    stopScriptPlaying(error);
    if (error && *error) return NO;
    return YES;
}

/*
 打电话 / 发短信走的是系统私有 API，没有公开头文件。这里只声明「我们要用的那几个方法」，
 运行时按名字取类再按 respondsToSelector 探路，取不到就退化成系统 URL（会弹确认框）。
*/
@interface ZXCallProvider : NSObject
@property (nonatomic, readonly) NSString *identifier;
@property (nonatomic, readonly) NSString *localizedName;
@end

@interface ZXCallProviderManager : NSObject
+ (instancetype)sharedInstance;
- (instancetype)initWithQueue:(id)queue;
@property (nonatomic, readonly) NSArray *providers;
@end

@interface ZXTUDialRequest : NSObject
- (instancetype)initWithProvider:(id)provider;
@property (nonatomic, copy) NSString *destinationID;
@end

@interface ZXCallCenter : NSObject
+ (instancetype)callCenter;
+ (instancetype)sharedInstance;
- (void)dialWithRequest:(id)request;
- (void)dialWithRequest:(id)request completion:(void (^)(id result))completion;
@end

@interface ZXCTMessageCenter : NSObject
+ (instancetype)sharedMessageCenter;
- (void)sendSMSWithText:(NSString *)text serviceCenter:(id)serviceCenter toAddress:(NSString *)address;
- (void)sendSMSWithText:(NSString *)text serviceCenter:(id)serviceCenter toAddress:(NSString *)address withMoreToFollow:(BOOL)more;
@end

static void ZXLoadFramework(const char *path)
{
    static dispatch_once_t once;
    static NSMutableSet *loaded = nil;
    dispatch_once(&once, ^{ loaded = [NSMutableSet set]; });
    if (!path) return;
    NSString *key = [NSString stringWithUTF8String:path];
    if ([loaded containsObject:key]) return;
    [loaded addObject:key];
    dlopen(path, RTLD_LAZY);
}

static NSString *ZXDialableNumber(NSString *raw)
{
    NSMutableString *out = [NSMutableString string];
    NSCharacterSet *keep = [NSCharacterSet characterSetWithCharactersInString:@"0123456789+*#"];
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if ([keep characterIsMember:c]) [out appendFormat:@"%C", c];
    }
    return out;
}

static BOOL ZXOpenURLScheme(NSString *urlString)
{
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return NO;
    ZXRunOnMainSync(^{
        @try {
            UIApplication *app = [UIApplication sharedApplication];
            if ([app respondsToSelector:@selector(openURL:options:completionHandler:)]) {
                [app openURL:url options:@{} completionHandler:nil];
            } else if ([app respondsToSelector:@selector(openURL:)]) {
                [app openURL:url];
            }
        } @catch (NSException *exception) {
            NSLog(@"com.zjx.springboard: openURL %@ failed: %@", urlString, exception.reason);
        }
    });
    return YES;
}

static id ZXCallProviderForSIM(NSString *sim)
{
    if (sim.length == 0 || [sim isEqualToString:@"default"]) return nil;
    NSInteger wanted = sim.integerValue;
    if (wanted < 1) return nil;

    Class managerClass = objc_getClass("TUCallProviderManager");
    if (!managerClass) return nil;

    ZXCallProviderManager *manager = nil;
    @try {
        if ([managerClass respondsToSelector:@selector(sharedInstance)]) {
            manager = (ZXCallProviderManager *)[(id)managerClass sharedInstance];
        }
        if (!manager) {
            manager = [[(id)managerClass alloc] initWithQueue:nil];
        }
    } @catch (NSException *exception) {
        NSLog(@"com.zjx.springboard: ZXCallProviderManager failed: %@", exception.reason);
        manager = nil;
    }
    if (!manager) return nil;

    NSArray *providers = nil;
    @try {
        providers = manager.providers;
    } @catch (NSException *exception) {
        providers = nil;
    }
    if (providers.count == 0) return nil;

    NSMutableArray *simProviders = [NSMutableArray array];
    for (id provider in providers) {
        NSString *label = nil;
        @try {
            label = [(ZXCallProvider *)provider localizedName];
            if (label.length == 0) label = [(ZXCallProvider *)provider identifier];
        } @catch (NSException *exception) {
            label = nil;
        }
        NSString *lower = label.lowercaseString ?: @"";
        if ([lower containsString:@"sim"] || [lower containsString:@"卡"]) {
            [simProviders addObject:provider];
        }
    }
    if ((NSInteger)simProviders.count >= wanted) return simProviders[wanted - 1];
    return nil;
}

BOOL ZXMakeCall(NSString *number, NSString *sim, NSError **error)
{
    NSString *dialable = ZXDialableNumber(number ?: @"");
    if (dialable.length == 0) {
        if (error) *error = ZXActionError(@"没有可拨打的号码。");
        return NO;
    }

    ZXLoadFramework("/System/Library/PrivateFrameworks/TelephonyUtilities.framework/TelephonyUtilities");
    Class centerClass = objc_getClass("TUCallCenter");
    Class requestClass = objc_getClass("TUDialRequest");
    if (centerClass && requestClass) {
        @try {
            ZXCallCenter *center = nil;
            if ([centerClass respondsToSelector:@selector(callCenter)]) {
                center = (ZXCallCenter *)[(id)centerClass callCenter];
            }
            if (!center && [centerClass respondsToSelector:@selector(sharedInstance)]) {
                center = (ZXCallCenter *)[(id)centerClass sharedInstance];
            }

            id provider = ZXCallProviderForSIM(sim);
            ZXTUDialRequest *request = nil;
            if ([requestClass instancesRespondToSelector:@selector(initWithProvider:)]) {
                request = [[(id)requestClass alloc] initWithProvider:provider];
            }
            if (!request) request = [[(id)requestClass alloc] init];

            if ([request respondsToSelector:@selector(setDestinationID:)]) {
                request.destinationID = dialable;
            }

            if (center && request) {
                if ([center respondsToSelector:@selector(dialWithRequest:completion:)]) {
                    [center dialWithRequest:request completion:nil];
                    return YES;
                }
                if ([center respondsToSelector:@selector(dialWithRequest:)]) {
                    [center dialWithRequest:request];
                    return YES;
                }
            }
        } @catch (NSException *exception) {
            NSLog(@"com.zjx.springboard: ZXMakeCall private API failed: %@", exception.reason);
        }
    }

    BOOL opened = ZXOpenURLScheme([@"tel:" stringByAppendingString:dialable]);
    if (!opened && error) *error = ZXActionError(@"当前系统不支持直接拨号。");
    return opened;
}

BOOL ZXSendSMS(NSString *number, NSString *text, NSString *sim, NSError **error)
{
    NSString *dialable = ZXDialableNumber(number ?: @"");
    if (dialable.length == 0) {
        if (error) *error = ZXActionError(@"没有可发送的号码。");
        return NO;
    }
    NSString *body = text ?: @"";

    ZXLoadFramework("/System/Library/PrivateFrameworks/CoreTelephony.framework/CoreTelephony");
    Class messageClass = objc_getClass("CTMessageCenter");
    if (messageClass && [messageClass respondsToSelector:@selector(sharedMessageCenter)]) {
        @try {
            ZXCTMessageCenter *center = (ZXCTMessageCenter *)[(id)messageClass sharedMessageCenter];
            if (center) {
                if ([center respondsToSelector:@selector(sendSMSWithText:serviceCenter:toAddress:withMoreToFollow:)]) {
                    [center sendSMSWithText:body serviceCenter:nil toAddress:dialable withMoreToFollow:NO];
                    return YES;
                }
                if ([center respondsToSelector:@selector(sendSMSWithText:serviceCenter:toAddress:)]) {
                    [center sendSMSWithText:body serviceCenter:nil toAddress:dialable];
                    return YES;
                }
            }
        } @catch (NSException *exception) {
            NSLog(@"com.zjx.springboard: ZXSendSMS private API failed: %@", exception.reason);
        }
    }

    NSString *encoded = [body stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"";
    BOOL opened = ZXOpenURLScheme([NSString stringWithFormat:@"sms:%@&body=%@", dialable, encoded]);
    if (!opened && error) *error = ZXActionError(@"当前系统不支持直接发短信。");
    return opened;
}

BOOL ZXSetWiFi(BOOL enabled, NSError **error)
{
    // 老系统的 SBWiFiManager 在新系统上已消失，先走 MobileWiFi 的 C 接口（Activator 用的就是它），
    // 两个都不成再报错。客户端只建一次并常驻，免得开关状态被回收
    static dispatch_once_t once;
    static void *wifiClient = NULL;
    static Boolean (*wifiSetPower)(void *, Boolean) = NULL;

    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi", RTLD_LAZY);
        if (!handle) return;
        void *(*createClient)(CFAllocatorRef, int) = (void *(*)(CFAllocatorRef, int))dlsym(handle, "WiFiManagerClientCreate");
        wifiSetPower = (Boolean (*)(void *, Boolean))dlsym(handle, "WiFiManagerClientSetPower");
        if (!createClient || !wifiSetPower) {
            wifiSetPower = NULL;
            return;
        }
        wifiClient = createClient(NULL, 0);
    });

    if (wifiClient && wifiSetPower && wifiSetPower(wifiClient, enabled ? 1 : 0)) return YES;

    __block BOOL done = NO;
    ZXRunOnMainSync(^{
        @try {
            Class managerClass = objc_getClass("SBWiFiManager");
            if (!managerClass) return;
            if (![managerClass respondsToSelector:@selector(sharedInstance)]) return;
            ZXWiFiManager *manager = (ZXWiFiManager *)[(id)managerClass sharedInstance];
            if ([manager respondsToSelector:@selector(setWiFiEnabled:)]) {
                [manager setWiFiEnabled:enabled];
                done = YES;
            }
        } @catch (NSException *exception) {
            NSLog(@"com.zjx.springboard: ZXSetWiFi failed: %@", exception.reason);
        }
    });

    if (done) return YES;
    if (error) *error = ZXActionError(@"当前系统不支持直接开关 WiFi。");
    return NO;
}

BOOL ZXSaveScreenshot(NSString **pathOut, NSError **error)
{
    CGImageRef shot = [Screen createScreenShotCGImageRef];
    if (!shot) {
        if (error) *error = ZXActionError(@"截图失败。");
        return NO;
    }

    // 自绘的帧是竖屏物理像素，按当前方向转正后再存，否则横屏存出来是躺着的
    UIImage *image = nil;
    @try {
        UIImageOrientation orientation = UIImageOrientationUp;
        int screenOrientation = [Screen getScreenOrientation];
        if (screenOrientation == 4) orientation = UIImageOrientationRight;
        else if (screenOrientation == 3) orientation = UIImageOrientationLeft;
        else if (screenOrientation == 2) orientation = UIImageOrientationDown;

        CGFloat scale = [Screen getScale];
        image = [UIImage imageWithCGImage:shot scale:scale orientation:orientation];
        if (image && orientation != UIImageOrientationUp) {
            CGSize orientedSize = CGSizeMake(CGImageGetWidth(shot) / scale, CGImageGetHeight(shot) / scale);
            if (orientation == UIImageOrientationLeft || orientation == UIImageOrientationRight) {
                orientedSize = CGSizeMake(orientedSize.height, orientedSize.width);
            }
            UIGraphicsBeginImageContextWithOptions(orientedSize, YES, scale);
            [image drawInRect:CGRectMake(0, 0, orientedSize.width, orientedSize.height)];
            UIImage *oriented = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            if (oriented) image = oriented;
        }
    } @catch (NSException *exception) {
        NSLog(@"com.zjx.springboard: ZXSaveScreenshot orient failed: %@", exception.reason);
    }
    CGImageRelease(shot);

    if (!image) {
        if (error) *error = ZXActionError(@"截图失败。");
        return NO;
    }

    __block BOOL finished = NO;
    __block NSError *saveError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    @try {
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromImage:image];
        } completionHandler:^(BOOL success, NSError *err) {
            if (!success) saveError = err;
            finished = YES;
            dispatch_semaphore_signal(sem);
        }];
    } @catch (NSException *exception) {
        NSLog(@"com.zjx.springboard: ZXSaveScreenshot save failed: %@", exception.reason);
        if (error) *error = ZXActionError(@"保存到相册失败。");
        return NO;
    }
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)));

    if (!finished) {
        if (error) *error = ZXActionError(@"保存到相册超时。");
        return NO;
    }
    if (saveError) {
        if (error) *error = ZXActionError([NSString stringWithFormat:@"保存到相册失败：%@",
                                           saveError.localizedDescription ?: @"未知错误"]);
        return NO;
    }
    if (pathOut) *pathOut = @"相册";
    return YES;
}

static NSCharacterSet *ZXRobotURLSafeSet(void)
{
    static NSCharacterSet *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSCharacterSet characterSetWithCharactersInString:
               @"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_.~"];
    });
    return set;
}

static NSString *ZXTrimmedText(id value)
{
    NSString *text = [value isKindOfClass:[NSString class]] ? value : @"";
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL ZXPostJSON(NSString *urlString, NSDictionary *payload, NSError **error)
{
    NSURL *url = [NSURL URLWithString:urlString ?: @""];
    if (url.scheme.length == 0 || url.host.length == 0) {
        if (error) *error = ZXActionError(@"机器人地址不正确。");
        return NO;
    }

    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!body) {
        if (error) *error = ZXActionError(@"推送内容无法编码。");
        return NO;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    request.timeoutInterval = 10.0;
    [request setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-Type"];

    __block NSInteger status = 0;
    __block NSData *received = nil;
    __block NSError *netError = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);

    // 这里会阻塞当前线程，调用方（流程单步 / socket 任务）都在后台线程，别改到主线程上跑
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
        status = [(NSHTTPURLResponse *)response statusCode];
        received = data;
        netError = err;
        dispatch_semaphore_signal(sema);
    }];
    [task resume];

    if (dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)) != 0) {
        [task cancel];
        if (error) *error = ZXActionError(@"推送超时，请检查网络。");
        return NO;
    }

    if (netError) {
        if (error) *error = ZXActionError([NSString stringWithFormat:@"推送失败：%@", netError.localizedDescription ?: @"网络错误"]);
        return NO;
    }
    if (status < 200 || status >= 300) {
        if (error) *error = ZXActionError([NSString stringWithFormat:@"推送失败：服务器返回 %ld。", (long)status]);
        return NO;
    }

    // 钉钉和企业微信都用 errcode 报成败
    id json = received.length ? [NSJSONSerialization JSONObjectWithData:received options:0 error:nil] : nil;
    if ([json isKindOfClass:[NSDictionary class]]) {
        NSNumber *code = ((NSDictionary *)json)[@"errcode"];
        if (code && code.integerValue != 0) {
            id message = ((NSDictionary *)json)[@"errmsg"];
            if (error) *error = ZXActionError([NSString stringWithFormat:@"推送失败：%@",
                                               [message isKindOfClass:[NSString class]] ? message : @"机器人返回错误"]);
            return NO;
        }
    }
    return YES;
}

BOOL ZXSendDingTalk(NSString *webhook, NSString *secret, NSString *text, NSError **error)
{
    NSString *url = ZXTrimmedText(webhook);
    if (url.length == 0) {
        if (error) *error = ZXActionError(@"还没有填写钉钉机器人的 webhook 地址。");
        return NO;
    }
    if (ZXTrimmedText(text).length == 0) {
        if (error) *error = ZXActionError(@"推送内容不能为空。");
        return NO;
    }

    NSString *signSecret = ZXTrimmedText(secret);
    if (signSecret.length > 0) {
        long long timestamp = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
        NSString *stringToSign = [NSString stringWithFormat:@"%lld\n%@", timestamp, signSecret];
        NSData *key = [signSecret dataUsingEncoding:NSUTF8StringEncoding];
        NSData *source = [stringToSign dataUsingEncoding:NSUTF8StringEncoding];
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, source.bytes, source.length, digest);
        NSData *mac = [NSData dataWithBytes:digest length:CC_SHA256_DIGEST_LENGTH];
        NSString *sign = [[mac base64EncodedStringWithOptions:0]
                          stringByAddingPercentEncodingWithAllowedCharacters:ZXRobotURLSafeSet()];
        if (sign.length == 0) {
            if (error) *error = ZXActionError(@"加签计算失败。");
            return NO;
        }
        url = [NSString stringWithFormat:@"%@%@timestamp=%lld&sign=%@",
               url, [url containsString:@"?"] ? @"&" : @"?", timestamp, sign];
    }

    NSDictionary *payload = @{ @"msgtype": @"text", @"text": @{ @"content": text ?: @"" } };
    return ZXPostJSON(url, payload, error);
}

BOOL ZXSendWeCom(NSString *webhook, NSString *text, NSError **error)
{
    NSString *url = ZXTrimmedText(webhook);
    if (url.length == 0) {
        if (error) *error = ZXActionError(@"还没有填写企业微信机器人的 webhook 地址。");
        return NO;
    }
    if (ZXTrimmedText(text).length == 0) {
        if (error) *error = ZXActionError(@"推送内容不能为空。");
        return NO;
    }

    NSDictionary *payload = @{ @"msgtype": @"text", @"text": @{ @"content": text ?: @"" } };
    return ZXPostJSON(url, payload, error);
}

@interface INPersonHandle : NSObject
- (instancetype)initWithValue:(NSString *)value type:(NSInteger)type;
@end

@interface INPerson : NSObject
- (instancetype)initWithPersonHandle:(id)handle nameComponents:(id)components
                         displayName:(NSString *)displayName image:(id)image
                   contactIdentifier:(NSString *)contactIdentifier
                    customIdentifier:(NSString *)customIdentifier;
@end

@interface INSendMessageIntent : NSObject
- (instancetype)initWithRecipients:(NSArray *)recipients content:(NSString *)content
                speakableGroupName:(id)groupName conversationIdentifier:(NSString *)conversationIdentifier
                        serviceName:(NSString *)serviceName sender:(id)sender;
@end

@interface INCExtensionConnection : NSObject
- (instancetype)initWithIntent:(id)intent;
- (instancetype)initWithIntent:(id)intent remoteProxyProvider:(void (^)(id proxy))provider;
@property (nonatomic, readonly) id appProxy;
- (void)resumeWithCompletionHandler:(void (^)(NSError *error))handler;
@end

@interface INCExtensionProxy : NSObject
- (void)handleIntentWithCompletionHandler:(void (^)(id response, NSError *error))handler;
@end

static void ZXEnsureIntentsLoaded(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/Intents.framework/Intents", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/IntentsCore.framework/IntentsCore", RTLD_NOW);
    });
}

static BOOL ZXWaitSemaphore(dispatch_semaphore_t sem, double seconds)
{
    return dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC))) == 0;
}

static NSString * const ZXWeChatLogPath = @"/var/mobile/Library/ZXTouch/wechat_send.log";

static void ZXWeChatLog(NSString *line, BOOL truncate)
{
    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Library/ZXTouch"
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    NSData *data = [(line ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    if (truncate) {
        [data writeToFile:ZXWeChatLogPath atomically:NO];
        return;
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:ZXWeChatLogPath];
    if (!fh) {
        [data writeToFile:ZXWeChatLogPath atomically:NO];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:data];
    [fh closeFile];
}

void ZXWeChatSendRun(NSString *recipient, NSString *text)
{
    ZXWeChatLog(@"", YES);
    ZXEnsureIntentsLoaded();

    @try {
        Class handleCls = NSClassFromString(@"INPersonHandle");
        Class personCls = NSClassFromString(@"INPerson");
        Class intentCls = NSClassFromString(@"INSendMessageIntent");
        Class connCls = NSClassFromString(@"INCExtensionConnection");
        if (!handleCls || !personCls || !intentCls || !connCls) {
            ZXWeChatLog(@"classes=missing\n", NO);
            return;
        }

        SEL handleSel = NSSelectorFromString(@"initWithValue:type:");
        SEL personSel = NSSelectorFromString(@"initWithPersonHandle:nameComponents:displayName:image:contactIdentifier:customIdentifier:");
        SEL intentSel = NSSelectorFromString(@"initWithRecipients:content:speakableGroupName:conversationIdentifier:serviceName:sender:");
        SEL connSel = NSSelectorFromString(@"initWithIntent:");
        ZXWeChatLog([NSString stringWithFormat:@"selectors=%d%d%d%d\n",
                     [handleCls instancesRespondToSelector:handleSel],
                     [personCls instancesRespondToSelector:personSel],
                     [intentCls instancesRespondToSelector:intentSel],
                     [connCls instancesRespondToSelector:connSel]], NO);

        id personHandle = ((id (*)(id, SEL, id, NSInteger))objc_msgSend)(
            [handleCls alloc], handleSel, recipient, 0);
        id person = ((id (*)(id, SEL, id, id, id, id, id, id))objc_msgSend)(
            [personCls alloc], personSel, personHandle, nil, recipient, nil, nil, nil);
        id intent = ((id (*)(id, SEL, id, id, id, id, id, id))objc_msgSend)(
            [intentCls alloc], intentSel, person ? @[person] : @[], text ?: @"", nil, nil, nil, nil);
        ZXWeChatLog([NSString stringWithFormat:@"person=%@ intent=%@\n",
                     person ? @"ok" : @"nil", intent ? @"ok" : @"nil"], NO);
        if (!intent) return;

        ZXWeChatLog(@"connecting\n", NO);
        dispatch_semaphore_t proxySem = dispatch_semaphore_create(0);
        __block id extProxy = nil;
        SEL connSel2 = NSSelectorFromString(@"initWithIntent:remoteProxyProvider:");
        id conn = nil;
        if ([connCls instancesRespondToSelector:connSel2]) {
            conn = ((id (*)(id, SEL, id, id))objc_msgSend)([connCls alloc], connSel2, intent,
                ^(id proxy) {
                    extProxy = proxy;
                    dispatch_semaphore_signal(proxySem);
                });
        } else {
            conn = ((id (*)(id, SEL, id))objc_msgSend)([connCls alloc], connSel, intent);
        }
        if (!conn) {
            ZXWeChatLog(@"connection=nil\n", NO);
            return;
        }

        dispatch_semaphore_t resumeSem = dispatch_semaphore_create(0);
        __block NSError *resumeError = nil;
        ((void (*)(id, SEL, id))objc_msgSend)(conn, NSSelectorFromString(@"resumeWithCompletionHandler:"),
            ^(NSError *err) {
                resumeError = err;
                dispatch_semaphore_signal(resumeSem);
            });
        if (!ZXWaitSemaphore(resumeSem, 20)) {
            ZXWeChatLog(@"resume=timeout\n", NO);
            return;
        }
        ZXWeChatLog([NSString stringWithFormat:@"resume=%@\n",
                     resumeError ? resumeError.localizedDescription : @"ok"], NO);

        if (!extProxy && !ZXWaitSemaphore(proxySem, 10)) {
            ZXWeChatLog(@"proxy=timeout\n", NO);
            return;
        }
        id proxy = extProxy;
        if (!proxy) {
            proxy = ((id (*)(id, SEL))objc_msgSend)(conn, NSSelectorFromString(@"appProxy"));
        }
        ZXWeChatLog([NSString stringWithFormat:@"proxy=%@\n",
                     proxy ? NSStringFromClass([proxy class]) : @"nil"], NO);
        if (!proxy) return;

        dispatch_semaphore_t handleSem = dispatch_semaphore_create(0);
        __block id handleResponse = nil;
        __block NSError *handleError = nil;
        ((void (*)(id, SEL, id))objc_msgSend)(proxy, NSSelectorFromString(@"handleIntentWithCompletionHandler:"),
            ^(id response, NSError *err) {
                handleResponse = response;
                handleError = err;
                dispatch_semaphore_signal(handleSem);
            });
        if (!ZXWaitSemaphore(handleSem, 30)) {
            ZXWeChatLog(@"handle=timeout\n", NO);
            return;
        }
        NSInteger code = handleResponse ? ((NSInteger (*)(id, SEL))objc_msgSend)(handleResponse, NSSelectorFromString(@"code")) : -999;
        ZXWeChatLog([NSString stringWithFormat:@"handle=%@ code=%ld class=%@\n",
                     handleError ? handleError.localizedDescription : @"ok", (long)code,
                     handleResponse ? NSStringFromClass([handleResponse class]) : @"nil"], NO);
    }
    @catch (NSException *ex) {
        ZXWeChatLog([NSString stringWithFormat:@"exception=%@ reason=%@\n", ex.name, ex.reason], NO);
    }
    ZXWeChatLog(@"done\n", NO);
}

NSInteger ZXHTTPRequest(NSString *method, NSString *url, NSString *headers, NSString *body,
                        double timeout, NSString **textOut, NSError **error)
{
    NSString *address = ZXTrimmedText(url);
    if (address.length == 0 || ![NSURL URLWithString:address].scheme.length) {
        if (error) *error = ZXActionError(@"请求地址不完整，需要以 http:// 或 https:// 开头。");
        return -1;
    }
    NSString *verb = ZXTrimmedText(method).uppercaseString;
    if (verb.length == 0) verb = @"GET";
    if (timeout <= 0) timeout = 10;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:address]];
    request.HTTPMethod = verb;
    request.timeoutInterval = timeout;
    for (NSString *line in [headers ?: @"" componentsSeparatedByString:@";"]) {
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *key = ZXTrimmedText([line substringToIndex:colon.location]);
        NSString *value = ZXTrimmedText([line substringFromIndex:colon.location + 1]);
        if (key.length && value.length) [request setValue:value forHTTPHeaderField:key];
    }
    if (![verb isEqualToString:@"GET"] && ![verb isEqualToString:@"HEAD"] && body.length > 0) {
        request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    }

    __block NSInteger status = -1;
    __block NSString *text = @"";
    __block NSError *netError = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
            if ([response isKindOfClass:[NSHTTPURLResponse class]])
                status = ((NSHTTPURLResponse *)response).statusCode;
            if (data.length) {
                NSString *decoded = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                text = decoded ?: @"";
            }
            netError = taskError;
            dispatch_semaphore_signal(sema);
        }];
    [task resume];
    if (dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 5) * NSEC_PER_SEC))) != 0) {
        [task cancel];
        if (error) *error = ZXActionError(@"请求超时。");
        return -1;
    }
    if (netError) {
        if (error) *error = ZXActionError([NSString stringWithFormat:@"请求失败：%@",
                                           netError.localizedDescription ?: @"网络错误"]);
        return -1;
    }
    if (status >= 400) {
        if (error) *error = ZXActionError([NSString stringWithFormat:@"请求失败：服务器返回 %ld。", (long)status]);
        return status;
    }
    if (textOut) *textOut = text;
    return status;
}

NSInteger ZXRunShell(NSString *command, double timeout, NSString **outputOut, NSError **error)
{
    NSString *script = command ?: @"";
    if (ZXTrimmedText(script).length == 0) {
        if (error) *error = ZXActionError(@"命令不能为空。");
        return -1;
    }
    const char *shellPath = zxShellPath();
    if (!shellPath) {
        if (error) *error = ZXActionError(@"设备上找不到可用的 sh。");
        return -1;
    }
    if (timeout <= 0) timeout = 10;
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"zx_shell_out.txt"];
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
    NSString *wrapped = [NSString stringWithFormat:@"{ %@\n} > '%@' 2>&1", script, tmp];

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawnattr_t attrs;
    posix_spawnattr_init(&attrs);
    char * const argv[] = { (char *)"sh", (char *)"-c", (char *)[wrapped UTF8String], NULL };
    extern char **environ;
    pid_t pid = 0;
    int spawnError = posix_spawn(&pid, shellPath, &actions, &attrs, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attrs);
    if (spawnError != 0) {
        if (error) *error = ZXActionError([NSString stringWithFormat:@"命令启动失败：%s", strerror(spawnError)]);
        return -1;
    }

    int status = 0;
    int waited = zxWaitTimeout(pid, timeout, &status);
    if (waited == 1) {
        kill(pid, SIGKILL);
        zxWaitTimeout(pid, 2.0, &status);
    } else if (waited == -1) {
        if (error) *error = ZXActionError(@"等待命令结束失败。");
        return -1;
    }
    NSString *output = [NSString stringWithContentsOfFile:tmp encoding:NSUTF8StringEncoding error:NULL] ?: @"";
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
    if (outputOut) *outputOut = output;
    NSInteger code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    if (waited == 1) {
        if (error) *error = ZXActionError(@"命令执行超时。");
        return code;
    }
    if (code != 0) {
        if (error) *error = ZXActionError([NSString stringWithFormat:@"命令退出码 %ld。%@", (long)code,
                                           output.length > 120 ? [output substringFromIndex:output.length - 120] : output]);
    }
    return code;
}

// 闸门只有一个时间戳：打开时定一个窗口，只要还有被丢弃的触摸在流进来就把窗口往后顺延，
// 直到积压排空（出现一段安静期）或撞上硬上限。不用定时器，避免积压时堆出成千上万个 block。
static volatile double zxTouchDropDeadline = 0;
static volatile double zxTouchDropHardStop = 0;

#define ZX_TOUCH_DROP_QUIET   0.6
#define ZX_TOUCH_DROP_MAX     3.0

void ZXDropPendingTouchInjections(void)
{
    double now = CFAbsoluteTimeGetCurrent();
    zxTouchDropDeadline = now + ZX_TOUCH_DROP_QUIET;
    zxTouchDropHardStop = now + ZX_TOUCH_DROP_MAX;
}

BOOL ZXShouldDropTouchInjection(void)
{
    if (zxTouchDropDeadline <= 0) return NO;

    double now = CFAbsoluteTimeGetCurrent();
    if (now >= zxTouchDropDeadline || now >= zxTouchDropHardStop) {
        zxTouchDropDeadline = 0;
        zxTouchDropHardStop = 0;
        return NO;
    }

    zxTouchDropDeadline = MIN(now + ZX_TOUCH_DROP_QUIET, zxTouchDropHardStop);
    return YES;
}

static volatile int zxStepRunActive = 0;
static volatile int zxStepRunPaused = 0;
static volatile int zxStepRunStop = 0;

void ZXStepRunBegin(void)
{
    zxStepRunStop = 0;
    zxStepRunPaused = 0;
    zxStepRunActive = 1;
}

void ZXStepRunFinish(void)
{
    zxStepRunActive = 0;
    zxStepRunPaused = 0;
    zxStepRunStop = 0;
}

BOOL ZXStepRunActive(void)
{
    return zxStepRunActive != 0;
}

BOOL ZXStepRunPaused(void)
{
    return zxStepRunActive != 0 && zxStepRunPaused != 0;
}

void ZXStepRunSetPaused(BOOL paused)
{
    if (zxStepRunActive == 0) return;
    zxStepRunPaused = paused ? 1 : 0;
}

void ZXStepRunRequestStop(void)
{
    if (zxStepRunActive == 0) return;
    zxStepRunStop = 1;
    zxStepRunPaused = 0;
}

BOOL ZXStepRunAborted(void)
{
    return zxStepRunActive != 0 && zxStepRunStop != 0;
}

BOOL ZXStepRunWait(double seconds)
{
    if (seconds <= 0) return !ZXStepRunAborted();

    double waited = 0;
    const double slice = 0.05;
    while (waited < seconds) {
        if (ZXStepRunAborted()) return NO;
        while (zxStepRunPaused != 0) {
            if (ZXStepRunAborted()) return NO;
            usleep(50000);
        }
        double remain = seconds - waited;
        double step = (remain < slice) ? remain : slice;
        usleep((useconds_t)llround(step * 1e6));
        waited += step;
    }
    return !ZXStepRunAborted();
}
