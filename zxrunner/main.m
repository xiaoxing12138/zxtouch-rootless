#import <Foundation/Foundation.h>
#import <unistd.h>
#import <errno.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/types.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <sys/select.h>
#import <sys/time.h>
#import <signal.h>
#import <fcntl.h>
#import <spawn.h>
#import <string.h>
#import <pthread.h>
#import <dlfcn.h>
#import <Vision/Vision.h>
#import <CoreImage/CoreImage.h>

#define ZXRUNNER_SOCKET_PATH "/tmp/zxrunner.sock"
#define ZXRUNNER_VERSION "1.1.0"

#define ZXTESS_MAX_SLOTS 4

typedef struct
{
    char *langs;
    void *api;
} ZXTessSlot;

static ZXTessSlot g_tessSlots[ZXTESS_MAX_SLOTS];
static int g_tessSlotCount = 0;
static pthread_mutex_t g_tessMutex = PTHREAD_MUTEX_INITIALIZER;
static int g_tessLoadState = 0;
static char g_tessError[256] = {0};

static void *(*p_tessCreate)(void);
static int (*p_tessInit3)(void *, const char *, const char *);
static int (*p_tessSetVariable)(void *, const char *, const char *);
static void (*p_tessSetPsm)(void *, int);
static void (*p_tessSetImage2)(void *, void *);
static char *(*p_tessGetText)(void *);
static void (*p_tessDeleteText)(char *);
static void (*p_tessDelete)(void *);
static void *(*p_pixRead)(const char *);
static void (*p_pixDestroy)(void **);

static const char *zx_first_readable(const char *a, const char *b)
{
    if (access(a, R_OK) == 0) return a;
    if (access(b, R_OK) == 0) return b;
    return NULL;
}

static int zx_tess_load(void)
{
    if (g_tessLoadState == 1) return 0;
    if (g_tessLoadState == -1) return -1;

    const char *leptPath = zx_first_readable("/var/jb/usr/lib/liblept.5.dylib", "/usr/lib/liblept.5.dylib");
    const char *tessPath = zx_first_readable("/var/jb/usr/lib/libtesseract.5.dylib", "/usr/lib/libtesseract.5.dylib");
    if (!leptPath || !tessPath)
    {
        snprintf(g_tessError, sizeof(g_tessError), "OCR engine is not installed");
        g_tessLoadState = -2;
        return -1;
    }

    void *lept = dlopen(leptPath, RTLD_NOW | RTLD_GLOBAL);
    if (!lept)
    {
        snprintf(g_tessError, sizeof(g_tessError), "dlopen liblept failed: %s", dlerror());
        g_tessLoadState = -1;
        return -1;
    }
    void *tess = dlopen(tessPath, RTLD_NOW | RTLD_LOCAL);
    if (!tess)
    {
        snprintf(g_tessError, sizeof(g_tessError), "dlopen libtesseract failed: %s", dlerror());
        g_tessLoadState = -1;
        return -1;
    }

    p_pixRead = (void *(*)(const char *))dlsym(lept, "pixRead");
    p_pixDestroy = (void (*)(void **))dlsym(lept, "pixDestroy");
    p_tessCreate = (void *(*)(void))dlsym(tess, "TessBaseAPICreate");
    p_tessInit3 = (int (*)(void *, const char *, const char *))dlsym(tess, "TessBaseAPIInit3");
    p_tessSetVariable = (int (*)(void *, const char *, const char *))dlsym(tess, "TessBaseAPISetVariable");
    p_tessSetPsm = (void (*)(void *, int))dlsym(tess, "TessBaseAPISetPageSegMode");
    p_tessSetImage2 = (void (*)(void *, void *))dlsym(tess, "TessBaseAPISetImage2");
    p_tessGetText = (char *(*)(void *))dlsym(tess, "TessBaseAPIGetUTF8Text");
    p_tessDeleteText = (void (*)(char *))dlsym(tess, "TessDeleteText");
    p_tessDelete = (void (*)(void *))dlsym(tess, "TessBaseAPIDelete");

    if (!p_pixRead || !p_pixDestroy || !p_tessCreate || !p_tessInit3 || !p_tessSetPsm ||
        !p_tessSetImage2 || !p_tessGetText || !p_tessDeleteText || !p_tessDelete)
    {
        snprintf(g_tessError, sizeof(g_tessError), "missing OCR engine symbols");
        g_tessLoadState = -1;
        return -1;
    }

    g_tessLoadState = 1;
    return 0;
}

static void *zx_tess_api(const char *langs)
{
    for (int i = 0; i < g_tessSlotCount; i++)
    {
        if (strcmp(g_tessSlots[i].langs, langs) == 0) return g_tessSlots[i].api;
    }

    if (g_tessSlotCount >= ZXTESS_MAX_SLOTS)
    {
        p_tessDelete(g_tessSlots[0].api);
        free(g_tessSlots[0].langs);
        for (int i = 1; i < g_tessSlotCount; i++) g_tessSlots[i - 1] = g_tessSlots[i];
        g_tessSlotCount--;
    }

    const char *dataPath = zx_first_readable("/var/jb/usr/share/tesseract-ocr/5/tessdata",
                                            "/usr/share/tesseract-ocr/5/tessdata");
    if (!dataPath)
    {
        snprintf(g_tessError, sizeof(g_tessError), "OCR language data is missing");
        return NULL;
    }

    void *api = p_tessCreate();
    if (!api)
    {
        snprintf(g_tessError, sizeof(g_tessError), "cannot create OCR engine");
        return NULL;
    }
    if (p_tessInit3(api, dataPath, langs) != 0)
    {
        p_tessDelete(api);
        snprintf(g_tessError, sizeof(g_tessError), "cannot load language data %s", langs);
        return NULL;
    }
    if (p_tessSetVariable) p_tessSetVariable(api, "user_defined_dpi", "300");

    g_tessSlots[g_tessSlotCount].langs = strdup(langs);
    g_tessSlots[g_tessSlotCount].api = api;
    g_tessSlotCount++;
    return api;
}

// 脚本开始跑时才预热，且在后台线程做，不挡 spawn_python / 触摸命令
static void *zx_tess_warmup_thread(void *arg)
{
    (void)arg;
    pthread_mutex_lock(&g_tessMutex);
    if (zx_tess_load() == 0)
    {
        if (zx_tess_api("chi_sim+eng"))
        {
            NSLog(@"[zxrunner] ocr warmed up (script)");
        }
        else
        {
            NSLog(@"[zxrunner] ocr warm up failed: %s", g_tessError);
        }
    }
    else
    {
        NSLog(@"[zxrunner] ocr engine unavailable: %s", g_tessError);
    }
    pthread_mutex_unlock(&g_tessMutex);
    return NULL;
}

static void zx_tess_warmup_async(void)
{
    pthread_t tid;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&tid, &attr, zx_tess_warmup_thread, NULL) != 0)
    {
        zx_tess_warmup_thread(NULL);
    }
    pthread_attr_destroy(&attr);
}

static int send_json_object(int fd, NSDictionary *obj)
{
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:NULL];
    if (!data) return -1;

    NSMutableData *out = [NSMutableData dataWithData:data];
    [out appendBytes:"\r\n" length:2];

    const uint8_t *p = out.bytes;
    size_t left = out.length;
    int total = 0;
    while (left > 0)
    {
        ssize_t n = write(fd, p, left);
        if (n <= 0)
        {
            if (errno == EINTR) continue;
            return -1;
        }
        p += n;
        left -= (size_t)n;
        total += (int)n;
    }
    return total;
}

static int send_json_line(int fd, const char *type, const char *extra_json)
{
    char line[4096];
    if (extra_json && strlen(extra_json) > 0) {
        snprintf(line, sizeof(line), "{\"type\":\"%s\",%s}\r\n", type, extra_json);
    } else {
        snprintf(line, sizeof(line), "{\"type\":\"%s\"}\r\n", type);
    }
    return (int)write(fd, line, strlen(line));
}

static int send_data(int fd, const char *type, const char *data, size_t len)
{
    NSMutableString *escaped = [NSMutableString stringWithCapacity:len * 2];
    for (size_t i = 0; i < len; i++) {
        char c = data[i];
        switch (c) {
            case '"':  [escaped appendString:@"\\\""]; break;
            case '\\': [escaped appendString:@"\\\\"]; break;
            case '\n': [escaped appendString:@"\\n"]; break;
            case '\r': [escaped appendString:@"\\r"]; break;
            case '\t': [escaped appendString:@"\\t"]; break;
            default:
                if ((unsigned char)c < 0x20) {
                    [escaped appendFormat:@"\\u%04x", c];
                } else {
                    [escaped appendFormat:@"%c", c];
                }
        }
    }
    char line[8192];
    snprintf(line, sizeof(line), "{\"type\":\"%s\",\"data\":\"%s\"}\r\n",
             type, escaped.UTF8String);
    return (int)write(fd, line, strlen(line));
}

static int handle_spawn_python(int client, NSDictionary *cmd)
{
    NSString *pythonPath = cmd[@"path"];
    NSString *scriptPath = cmd[@"script"];
    NSArray  *args = cmd[@"args"] ?: @[];
    NSDictionary *envDict = cmd[@"env"] ?: @{};
    NSString *cwd = cmd[@"cwd"];

    if (!pythonPath || pythonPath.length == 0) {
        send_json_line(client, "error", "\"msg\":\"missing path\"");
        return -1;
    }

    if (cwd.length > 0) chdir(cwd.UTF8String);

    int envCount = (int)envDict.count;
    char **envp = malloc(sizeof(char *) * (envCount + 1));
    int i = 0;
    for (NSString *key in envDict) {
        NSString *val = envDict[key];
        char *pair = malloc(strlen(key.UTF8String) + strlen(val.UTF8String) + 2);
        sprintf(pair, "%s=%s", key.UTF8String, val.UTF8String);
        envp[i++] = pair;
    }
    envp[i] = NULL;

    int argc = 2 + (int)args.count;
    char **argv = malloc(sizeof(char *) * argc);
    argv[0] = (char *)pythonPath.UTF8String;
    int ai = 1;
    if (scriptPath.length > 0) argv[ai++] = (char *)scriptPath.UTF8String;
    for (NSString *a in args) argv[ai++] = (char *)a.UTF8String;
    argv[ai] = NULL;

    int pipefd[2];
    if (pipe(pipefd) != 0) {
        send_json_line(client, "error", "\"msg\":\"pipe failed\"");
        free(envp); free(argv);
        return -1;
    }

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&fa, pipefd[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&fa, pipefd[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&fa, pipefd[0]);
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    sigset_t empty; sigemptyset(&empty);
    posix_spawnattr_setsigmask(&attr, &empty);
    posix_spawnattr_setpgroup(&attr, 0);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP);

    pid_t pid = 0;
    int err = posix_spawn(&pid, pythonPath.UTF8String, &fa, &attr, argv, envp);

    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);
    close(pipefd[1]);
    free(envp); free(argv);

    if (err != 0) {
        char errbuf[256];
        snprintf(errbuf, sizeof(errbuf), "\"msg\":\"posix_spawn: %s (%d)\"", strerror(err), err);
        send_json_line(client, "error", errbuf);
        return -1;
    }

    char started[64];
    snprintf(started, sizeof(started), "\"pid\":%d", pid);
    if (send_json_line(client, "started", started) < 0) {
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        return -1;
    }

    char buf[4096];
    int pipefd_local = pipefd[0];
    int died = 0;
    while (1) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(pipefd_local, &rfds);
        FD_SET(client, &rfds);
        int maxfd = pipefd_local > client ? pipefd_local : client;

        struct timeval tv = { 0, 50 * 1000 };
        int ret = select(maxfd + 1, &rfds, NULL, NULL, &tv);
        if (ret < 0 && errno == EINTR) continue;
        if (ret <= 0) continue;

        if (FD_ISSET(client, &rfds)) {
            char dummy;
            ssize_t nr = read(client, &dummy, 1);
            if (nr <= 0) {
                kill(pid, SIGKILL);
                died = 1;
                break;
            }
        }

        if (FD_ISSET(pipefd_local, &rfds)) {
            ssize_t n = read(pipefd_local, buf, sizeof(buf));
            if (n <= 0) break;
            if (send_data(client, "stdout", buf, n) < 0) {
                kill(pid, SIGKILL);
                died = 1;
                break;
            }
        }
    }
    close(pipefd_local);

    int st = 0;
    waitpid(pid, &st, 0);
    if (died) return 0;
    int code = WIFEXITED(st) ? WEXITSTATUS(st) : (WIFSIGNALED(st) ? 128 + WTERMSIG(st) : -1);
    char exit[64];
    snprintf(exit, sizeof(exit), "\"code\":%d", code);
    send_json_line(client, "exit", exit);

    return 0;
}

static int handle_ocr(int client, NSDictionary *cmd)
{
    NSString *path = cmd[@"path"];
    NSArray *langs = [cmd[@"langs"] isKindOfClass:[NSArray class]] ? cmd[@"langs"] : @[@"zh-Hans", @"en-US"];
    NSNumber *rev = [cmd[@"revision"] isKindOfClass:[NSNumber class]] ? cmd[@"revision"] : @2;
    if (path.length == 0) {
        send_json_line(client, "error", "\"msg\":\"missing path\"");
        return -1;
    }

    NSError *err = nil;
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithURL:[NSURL fileURLWithPath:path]
                                                                      options:@{}];
    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] init];
    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.usesLanguageCorrection = YES;
    @try {
        req.revision = (NSUInteger)rev.integerValue;
    } @catch (NSException *e) {
        send_json_line(client, "error", "\"msg\":\"revision not supported\"");
        return -1;
    }
    req.recognitionLanguages = langs;

    [handler performRequests:@[req] error:&err];
    if (err) {
        NSString *msg = [err.localizedDescription stringByReplacingOccurrencesOfString:@"\"" withString:@"'"];
        NSString *detail = [NSString stringWithFormat:@"\"msg\":\"perform failed\",\"detail\":\"%@\"", msg];
        send_json_line(client, "error", detail.UTF8String);
        return -1;
    }

    NSMutableString *result = [NSMutableString string];
    for (VNRecognizedTextObservation *obs in req.results) {
        VNRecognizedText *text = [[obs topCandidates:1] firstObject];
        if (text.string.length > 0) {
            [result appendFormat:@"%@,,%f,,%f\n", text.string, obs.boundingBox.origin.x, obs.boundingBox.origin.y];
        }
    }
    send_data(client, "result", result.UTF8String, strlen(result.UTF8String));
    send_json_line(client, "done", NULL);
    return 0;
}

static int handle_ocr_tess_locked(int client, NSDictionary *cmd)
{
    NSString *path = cmd[@"path"];
    NSString *langs = [cmd[@"langs"] isKindOfClass:[NSString class]] ? cmd[@"langs"] : @"";
    int psm = [cmd[@"psm"] isKindOfClass:[NSNumber class]] ? [cmd[@"psm"] intValue] : 6;

    if (path.length == 0)
    {
        send_json_object(client, @{ @"type": @"error", @"msg": @"missing path" });
        return -1;
    }
    if (langs.length == 0) langs = @"chi_sim+eng";

    if (zx_tess_load() != 0)
    {
        send_json_object(client, @{ @"type": @"error",
                                    @"msg": [NSString stringWithUTF8String:g_tessError] });
        return -1;
    }

    void *api = zx_tess_api(langs.UTF8String);
    if (!api)
    {
        send_json_object(client, @{ @"type": @"error",
                                    @"msg": [NSString stringWithUTF8String:g_tessError] });
        return -1;
    }

    void *pix = p_pixRead(path.fileSystemRepresentation);
    if (!pix)
    {
        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
        NSString *msg = exists
            ? [NSString stringWithFormat:@"cannot read image (decode failed: %@)", path]
            : [NSString stringWithFormat:@"cannot read image (not found: %@)", path];
        send_json_object(client, @{ @"type": @"error", @"msg": msg });
        return -1;
    }

    p_tessSetPsm(api, psm);
    p_tessSetImage2(api, pix);
    char *text = p_tessGetText(api);
    p_pixDestroy(&pix);

    if (!text)
    {
        send_json_object(client, @{ @"type": @"error", @"msg": @"ocr returned nothing" });
        return -1;
    }

    NSString *utf8 = [NSString stringWithUTF8String:text] ?: @"";
    p_tessDeleteText(text);

    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *line in [utf8 componentsSeparatedByString:@"\n"])
    {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length > 0) [lines addObject:trimmed];
    }

    send_json_object(client, @{ @"type": @"lines", @"data": lines });
    send_json_object(client, @{ @"type": @"done" });
    return 0;
}

static int handle_ocr_tess(int client, NSDictionary *cmd)
{
    pthread_mutex_lock(&g_tessMutex);
    int ret = handle_ocr_tess_locked(client, cmd);
    pthread_mutex_unlock(&g_tessMutex);
    return ret;
}

static void handle_client(int client)
{
    char linebuf[8192];
    int  linepos = 0;

    while (1) {
        char ch;
        ssize_t nr = read(client, &ch, 1);
        if (nr <= 0) break;

        if (ch == '\n') {
            if (linepos == 0) continue;
            linebuf[linepos] = '\0';

            NSData *data = [NSData dataWithBytes:linebuf length:linepos];
            NSError *jsonErr = nil;
            NSDictionary *cmd = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];

            if (jsonErr || ![cmd isKindOfClass:[NSDictionary class]]) {
                send_json_line(client, "error", "\"msg\":\"invalid JSON\"");
            } else {
                NSString *c = cmd[@"cmd"];
                if ([c isEqualToString:@"spawn_python"]) {
                    handle_spawn_python(client, cmd);
                } else if ([c isEqualToString:@"ocr"]) {
                    handle_ocr(client, cmd);
                } else if ([c isEqualToString:@"ocr_tess"]) {
                    handle_ocr_tess(client, cmd);
                } else if ([c isEqualToString:@"ocr_warmup"]) {
                    zx_tess_warmup_async();
                    send_json_line(client, "done", NULL);
                } else if ([c isEqualToString:@"ping"]) {
                    send_json_line(client, "pong", "\"v\":\"" ZXRUNNER_VERSION "\"");
                } else {
                    send_json_line(client, "error", "\"msg\":\"unknown cmd\"");
                }
            }
            linepos = 0;
        } else if (linepos < (int)sizeof(linebuf) - 1) {
            linebuf[linepos++] = ch;
        }
    }
    close(client);
}

static int run_server(void)
{
    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server < 0) { perror("zxrunner: socket"); return 1; }

    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, ZXRUNNER_SOCKET_PATH, sizeof(addr.sun_path) - 1);

    {
        int probe = socket(AF_UNIX, SOCK_STREAM, 0);
        if (probe >= 0) {
            struct timeval tv = { 0, 300 * 1000 };
            setsockopt(probe, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
            int alive = (connect(probe, (struct sockaddr *)&addr, sizeof(addr)) == 0);
            close(probe);
            if (alive) {
                fprintf(stderr, "zxrunner: another instance is alive, exiting\n");
                close(server);
                return 2;
            }
        }
    }
    unlink(ZXRUNNER_SOCKET_PATH);

    if (bind(server, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "zxrunner: bind: %s\n", strerror(errno));
        close(server);
        return 3;
    }
    chmod(ZXRUNNER_SOCKET_PATH, 0666);

    if (listen(server, 5) < 0) {
        perror("zxrunner: listen");
        close(server);
        return 4;
    }

    NSLog(@"[zxrunner] listening on %s (uid=%d)", ZXRUNNER_SOCKET_PATH, getuid());

    while (1) {
        int client = accept(server, NULL, NULL);
        if (client >= 0) {
            handle_client(client);
        }
    }
}

// launchd 会给自己的服务进程套一个很小的 jetsam 内存上限，
// tesseract 一加载就被 JETSAM_REASON_MEMORY_PERPROCESSLIMIT 杀掉。
// 所以由 launchd 启动的这一份只当看门狗，真正的服务进程以子进程身份起，
// 子进程不归 launchd 管，内存不受限制。
static int run_supervisor(const char *selfPath)
{
    while (1) {
        posix_spawn_file_actions_t fa;
        posix_spawn_file_actions_init(&fa);
        posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO, "/tmp/zxrunner_stdout.log",
                                         O_WRONLY | O_CREAT | O_APPEND, 0644);
        posix_spawn_file_actions_addopen(&fa, STDERR_FILENO, "/tmp/zxrunner_stderr.log",
                                         O_WRONLY | O_CREAT | O_APPEND, 0644);
        posix_spawnattr_t attr;
        posix_spawnattr_init(&attr);
        char *envp[] = { "ZXRUNNER_WORKER=1", "HOME=/var/mobile",
                         "PATH=/usr/bin:/bin:/usr/sbin:/sbin", NULL };
        char *argv[] = { (char *)selfPath, NULL };

        pid_t pid = 0;
        int err = posix_spawn(&pid, selfPath, &fa, &attr, argv, envp);
        posix_spawn_file_actions_destroy(&fa);
        posix_spawnattr_destroy(&attr);

        if (err == 0 && pid > 0) {
            int status = 0;
            while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
            }
            sleep(2);
        } else {
            sleep(5);
        }
    }
    return 0;
}

int main(int argc, char *argv[])
{
    @autoreleasepool {
        signal(SIGCHLD, SIG_DFL);
        signal(SIGPIPE, SIG_IGN);

        NSDictionary *env = [[NSProcessInfo processInfo] environment];
        if (env[@"XPC_SERVICE_NAME"] && !env[@"ZXRUNNER_WORKER"]) {
            return run_supervisor(argv[0]);
        }

        // LaunchDaemon 以 root 启动（rootless 上 system 域不能用 UserName），
        // 这里主动降到 mobile：python / socket 都必须以手机用户身份跑
        if (geteuid() == 0) {
            unlink(ZXRUNNER_SOCKET_PATH);
            setenv("HOME", "/var/mobile", 1);
            chdir("/var/mobile");
            setgid(501);
            setuid(501);
            if (getuid() != 501) {
                fprintf(stderr, "zxrunner: failed to drop privileges\n");
                return 5;
            }
        }

        return run_server();
    }
}
