#import <Foundation/Foundation.h>
#import <unistd.h>
#import <errno.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/types.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <signal.h>
#import <fcntl.h>
#import <spawn.h>
#import <string.h>

#define ZXRUNNER_SOCKET_PATH "/tmp/zxrunner.sock"
#define ZXRUNNER_VERSION "1.0.0"

static void send_json_line(int fd, const char *type, const char *extra_json)
{
    char line[4096];
    if (extra_json && strlen(extra_json) > 0) {
        snprintf(line, sizeof(line), "{\"type\":\"%s\",%s}\r\n", type, extra_json);
    } else {
        snprintf(line, sizeof(line), "{\"type\":\"%s\"}\r\n", type);
    }
    write(fd, line, strlen(line));
}

static void send_data(int fd, const char *type, const char *data, size_t len)
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
    write(fd, line, strlen(line));
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
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGMASK);

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
    send_json_line(client, "started", started);

    char buf[4096];
    ssize_t n;
    while ((n = read(pipefd[0], buf, sizeof(buf))) > 0) {
        send_data(client, "stdout", buf, n);
    }
    close(pipefd[0]);

    int st = 0;
    waitpid(pid, &st, 0);
    int code = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
    char exit[64];
    snprintf(exit, sizeof(exit), "\"code\":%d", code);
    send_json_line(client, "exit", exit);

    return 0;
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

static void run_server(void)
{
    unlink(ZXRUNNER_SOCKET_PATH);

    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server < 0) { perror("zxrunner: socket"); return; }

    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, ZXRUNNER_SOCKET_PATH, sizeof(addr.sun_path) - 1);

    if (bind(server, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("zxrunner: bind");
        close(server);
        return;
    }
    chmod(ZXRUNNER_SOCKET_PATH, 0666);

    if (listen(server, 5) < 0) {
        perror("zxrunner: listen");
        close(server);
        return;
    }

    NSLog(@"[zxrunner] listening on %s (uid=%d)", ZXRUNNER_SOCKET_PATH, getuid());

    while (1) {
        int client = accept(server, NULL, NULL);
        if (client >= 0) {
            handle_client(client);
        }
    }
}

int main(int argc, char *argv[])
{
    @autoreleasepool {
        signal(SIGCHLD, SIG_IGN);
        signal(SIGPIPE, SIG_IGN);

        run_server();
        return 0;
    }
}
