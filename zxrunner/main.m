//
//  zxrunner — 小新Lap 守护进程 PoC
//
//  职责：独立于 SpringBoard 进程树，由 launchd 拉起，负责 posix_spawn python3。
//  iOS 18 Dopamine 上 SpringBoard sandbox 硬拦 exec /var/jb/usr/bin/*，
//  但 launchd 起的 daemon 不受这个限制。
//
//  本文件只做最小探测：启动时把 pid / uid / access(python3.9, X_OK) 结果写到
//  /tmp/zxrunner_probe，验证 daemon 进程到底能不能 exec python。
//  后续再补 socket server 让 tweak 发命令过来。
//

#import <Foundation/Foundation.h>
#import <unistd.h>
#import <errno.h>
#import <sys/types.h>
#import <sys/stat.h>

static void write_probe(void)
{
    const char *probe_path = "/tmp/zxrunner_probe";
    FILE *f = fopen(probe_path, "w");
    if (!f) { perror("zxrunner: fopen probe"); return; }

    fprintf(f, "zxrunner probe\n");
    fprintf(f, "pid=%d uid=%d gid=%d\n", getpid(), getuid(), getgid());
    fprintf(f, "time=%ld\n", (long)time(NULL));

    // 探测 SpringBoard 不能 exec 的那些路径，daemon 行不行
    const char *targets[] = {
        "/var/jb/usr/bin/python3.9",
        "/var/jb/usr/bin/python3",
        "/var/jb/usr/bin/ls",
        "/var/jb/usr/bin/env",
        "/var/jb/usr/bin/dpkg",
        "/var/jb/bin/sh",
        "/bin/sh",
        NULL
    };

    for (int i = 0; targets[i]; i++) {
        const char *p = targets[i];
        struct stat st;
        BOOL exists = (access(p, F_OK) == 0);
        BOOL can_exec = (access(p, X_OK) == 0);
        int e_access = exists ? errno : 0;
        int st_r = stat(p, &st);

        fprintf(f, "%s  exists=%d  access_X_OK=%d  stat_errno=%d  mode=%04o\n",
                p, exists, can_exec, e_access,
                st_r == 0 ? (unsigned)st.st_mode & 07777 : 0);

        // daemon 能 exec 就直接跑 --version 看结果
        if (can_exec) {
            int pipefd[2];
            if (pipe(pipefd) == 0) {
                pid_t pid = fork();
                if (pid == 0) {
                    close(pipefd[0]);
                    dup2(pipefd[1], STDOUT_FILENO);
                    dup2(pipefd[1], STDERR_FILENO);
                    close(pipefd[1]);
                    execl(p, p, "--version", NULL);
                    _exit(127);
                } else if (pid > 0) {
                    close(pipefd[1]);
                    char buf[256];
                    ssize_t n = read(pipefd[0], buf, sizeof(buf) - 1);
                    buf[n > 0 ? n : 0] = '\0';
                    close(pipefd[0]);
                    int st2 = 0;
                    waitpid(pid, &st2, 0);
                    fprintf(f, "  → exec exit=%d output=%s",
                            WIFEXITED(st2) ? WEXITSTATUS(st2) : -1,
                            n > 0 ? buf : "(none)");
                }
            }
        }
    }

    fclose(f);
    chmod(probe_path, 0666);   // 让 mobile 用户能读到
}

int main(int argc, char *argv[])
{
    @autoreleasepool {
        write_probe();
        NSLog(@"[zxrunner] probe written to /tmp/zxrunner_probe");

        // PoC 阶段：probe 写完就 exit。后续改成 socket server 常驻。
        // 用 exit 而不是 while(1) sleep 因为 launchd KeepAlive 会在 daemon exit 后重启它，
        // 这样每次重启都重新写 probe，方便在 tweak 里直接 cat 验证。
        _exit(0);
    }
}
