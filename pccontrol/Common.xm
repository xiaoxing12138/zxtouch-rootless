#include "Common.h"
#include "Config.h"
#import <sys/utsname.h>
#import <sys/wait.h>
#include <dlfcn.h>
#include <spawn.h>
#include <errno.h>
#include <string.h>
#include <math.h>

int call_system(const char *cmd)
{
    static int (*sys_fn)(const char *) = NULL;
    if (!sys_fn)
        sys_fn = (int (*)(const char *))dlsym(RTLD_DEFAULT, "system");
    return sys_fn ? sys_fn(cmd) : -1;
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
static void ZXStepNumberField(UITextField *field, BOOL integer, NSInteger direction)
{
    double value = field.text.doubleValue;
    double step;
    if (integer) {
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

UIView *ZXMakeNumberStepper(UITextField *field, BOOL integer)
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
            ZXStepNumberField(field, integer, direction);
        }] forControlEvents:UIControlEventTouchUpInside];
        [box addSubview:btn];
    }
    return box;
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
    CGFloat overlap = CGRectGetMaxY(inWindow) - scrolled + 8.0 - keyboardTop;
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
