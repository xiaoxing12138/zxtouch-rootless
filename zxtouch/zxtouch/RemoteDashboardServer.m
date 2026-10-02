#if ZX_DASHBOARD_SPRINGBOARD_SERVER
#import "../../pccontrol/RemoteDashboardServer.h"
#import <sys/socket.h>
#import <sys/time.h>
#import <unistd.h>
#else
#import "RemoteDashboardServer.h"
#endif

#import <arpa/inet.h>
#import <ifaddrs.h>
#import <notify.h>

#import "Config.h"
#if !ZX_DASHBOARD_SPRINGBOARD_SERVER
#import "Socket.h"
#endif
#import "GCDWebServer.h"
#import "GCDWebServerDataRequest.h"
#import "GCDWebServerDataResponse.h"
#import "GCDWebServerFileResponse.h"
#import "GCDWebServerMultiPartFormRequest.h"

static NSString *const ZXDashboardConfigPath = @"/var/mobile/Library/ZXTouch/config/tweak/remote_dashboard.plist";
static NSString *const ZXDashboardEnabledKey = @"enabled";
static NSString *const ZXDashboardTokenKey = @"token";
static const char *ZXDashboardConfigurationNotification = "com.zjx.zxtouch.remote-dashboard-changed";
static const unsigned long long ZXDashboardMaximumAssetSize = 25ULL * 1024ULL * 1024ULL;
static const NSUInteger ZXDashboardMaximumLogLength = 256 * 1024;

static NSString *ZXDashboardIPAddress(void)
{
    struct ifaddrs *interfaces = NULL;
    NSString *address = nil;
    if (getifaddrs(&interfaces) != 0) return nil;

    for (struct ifaddrs *entry = interfaces; entry != NULL; entry = entry->ifa_next) {
        if (!entry->ifa_addr || entry->ifa_addr->sa_family != AF_INET) continue;
        NSString *name = [NSString stringWithUTF8String:entry->ifa_name];
        if (![name isEqualToString:@"en0"] && ![name isEqualToString:@"en1"]) continue;

        char host[INET_ADDRSTRLEN] = {0};
        struct sockaddr_in *ipv4 = (struct sockaddr_in *)entry->ifa_addr;
        if (inet_ntop(AF_INET, &ipv4->sin_addr, host, sizeof(host))) {
            address = [NSString stringWithUTF8String:host];
            break;
        }
    }
    freeifaddrs(interfaces);
    return address;
}

#if ZX_DASHBOARD_SPRINGBOARD_SERVER

// 8080 网页端是 SpringBoard 里的 tweak 在跑，[NSBundle mainBundle] 拿到的是
// SpringBoard 自己的版本号（1.0），所以必须去读 ZXTouch App 包里的 Info.plist。
static NSString *ZXDashboardAppVersion(void)
{
    static NSString *version = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *candidates = @[
            @"/var/jb/Applications/zxtouch.app/Info.plist",
            @"/Applications/zxtouch.app/Info.plist"
        ];
        for (NSString *path in candidates) {
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:path];
            NSString *value = [info[@"CFBundleShortVersionString"] isKindOfClass:[NSString class]] ? info[@"CFBundleShortVersionString"] : nil;
            if (value.length > 0) {
                version = [value copy];
                break;
            }
        }
        if (version == nil) {
            version = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] copy] ?: @"";
        }
    });
    return version;
}

@interface ZXRemoteDashboardServer : NSObject
@property(nonatomic, strong) GCDWebServer *server;
@property(nonatomic, copy) NSString *token;
@property(nonatomic, copy) NSString *lastError;
@property(nonatomic, copy) NSString *lastAction;
@end

@implementation ZXRemoteDashboardServer

- (instancetype)initWithToken:(NSString *)token
{
    self = [super init];
    if (self) {
        _token = [token copy];
        _lastAction = @"就绪";
    }
    return self;
}

- (BOOL)requestIsAuthorized:(GCDWebServerRequest *)request
{
    return [request.query[@"token"] isEqualToString:self.token];
}

- (GCDWebServerDataResponse *)jsonResponse:(NSDictionary *)payload status:(NSInteger)status
{
    GCDWebServerDataResponse *response = [GCDWebServerDataResponse responseWithJSONObject:payload];
    response.statusCode = status;
    return response;
}

- (GCDWebServerDataResponse *)unauthorizedResponse
{
    return [self jsonResponse:@{ @"ok": @NO, @"error": @"配对令牌无效。" } status:403];
}

- (NSString *)bundlePathForRelativePath:(NSString *)relativePath
{
    if (![relativePath isKindOfClass:[NSString class]] || ![relativePath.pathExtension.lowercaseString isEqualToString:@"bdl"]) {
        return nil;
    }

    NSString *root = [SCRIPTS_PATH stringByStandardizingPath];
    NSString *candidate = [[root stringByAppendingPathComponent:relativePath] stringByStandardizingPath];
    NSString *rootPrefix = [root stringByAppendingString:@"/"];
    BOOL isDirectory = NO;
    if (![candidate hasPrefix:rootPrefix] || ![[NSFileManager defaultManager] fileExistsAtPath:candidate isDirectory:&isDirectory] || !isDirectory) {
        return nil;
    }
    return candidate;
}

- (NSString *)safePathForRelativePath:(NSString *)relativePath mustExist:(BOOL)mustExist
{
    if (![relativePath isKindOfClass:[NSString class]] || relativePath.length == 0) return nil;
    NSString *root = [SCRIPTS_PATH stringByStandardizingPath];
    NSString *candidate = [[root stringByAppendingPathComponent:relativePath] stringByStandardizingPath];
    if (![candidate hasPrefix:[root stringByAppendingString:@"/"]]) return nil;
    if (mustExist && ![[NSFileManager defaultManager] fileExistsAtPath:candidate]) return nil;
    return candidate;
}

- (NSString *)relativePathForScriptsPath:(NSString *)path
{
    NSString *rootPrefix = [[SCRIPTS_PATH stringByStandardizingPath] stringByAppendingString:@"/"];
    return [path hasPrefix:rootPrefix] ? [path substringFromIndex:rootPrefix.length] : path;
}

- (BOOL)isSafeScriptName:(NSString *)name
{
    if (![name isKindOfClass:[NSString class]] || name.length == 0 ||
        [name isEqualToString:@"."] || [name isEqualToString:@".."]) {
        return NO;
    }
    NSCharacterSet *forbidden = [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|"];
    return [name rangeOfCharacterFromSet:forbidden].location == NSNotFound;
}

- (NSString *)entryPathForBundle:(NSString *)bundlePath
{
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"info.plist"]];
    NSString *entry = [info[@"Entry"] isKindOfClass:[NSString class]] ? info[@"Entry"] : @"";
    if (entry.length == 0) return nil;
    return [bundlePath stringByAppendingPathComponent:entry];
}

- (NSString *)modifiedDateStringForPath:(NSString *)path
{
    NSDate *date = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil][NSFileModificationDate];
    if (!date) return @"";
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    });
    return [formatter stringFromDate:date];
}

- (NSArray<NSDictionary *> *)scripts
{
    NSMutableArray<NSDictionary *> *scripts = [NSMutableArray array];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fileManager enumeratorAtPath:SCRIPTS_PATH];
    NSString *relativePath = nil;

    while ((relativePath = [enumerator nextObject])) {
        if (![relativePath.pathExtension.lowercaseString isEqualToString:@"bdl"]) continue;
        NSString *bundlePath = [SCRIPTS_PATH stringByAppendingPathComponent:relativePath];
        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:bundlePath isDirectory:&isDirectory] || !isDirectory) continue;

        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"info.plist"]];
        NSString *entry = [info[@"Entry"] isKindOfClass:[NSString class]] ? info[@"Entry"] : @"";
        NSString *folder = relativePath.stringByDeletingLastPathComponent ?: @"";
        [scripts addObject:@{
            @"path": relativePath,
            @"name": relativePath.lastPathComponent.stringByDeletingPathExtension,
            @"entry": entry,
            @"type": entry.pathExtension.lowercaseString ?: @"",
            @"modified": [self modifiedDateStringForPath:bundlePath],
            @"folder": folder
        }];
        [enumerator skipDescendants];
    }
    return [scripts sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"name"] localizedCaseInsensitiveCompare:right[@"name"]];
    }];
}

// 连一次、发一条、收一条。连不上或没回包都返回 nil（区别于服务端真的回了 "-1;;…"）。
- (NSString *)sendSocketCommandOnce:(NSString *)command expectsReply:(BOOL)expectsReply
{
    int socketHandle = socket(AF_INET, SOCK_STREAM, 0);
    if (socketHandle < 0) return nil;
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(6000);
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);
    // 4 秒：251/252/2532 这几条要绕到 SpringBoard 主线程去取，主线程一忙 2 秒就不够。
    struct timeval timeout = {4, 0};
    setsockopt(socketHandle, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(socketHandle, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    if (connect(socketHandle, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(socketHandle);
        return nil;
    }
    // The tweak's socket server splits incoming data on CRLF and only dispatches
    // a task once it sees the terminator, so a bare command sits in the buffer
    // forever and every dashboard action reports the service as unavailable.
    NSString *terminated = [command hasSuffix:@"\r\n"] ? command
                                                       : [command stringByAppendingString:@"\r\n"];
    const char *message = terminated.UTF8String;
    if (send(socketHandle, message, strlen(message), 0) < 0) {
        close(socketHandle);
        return nil;
    }
    char buffer[4096] = {0};
    ssize_t length = expectsReply ? recv(socketHandle, buffer, sizeof(buffer) - 1, 0) : 1;
    close(socketHandle);
    if (!expectsReply) return @"0";
    return length > 0 ? [NSString stringWithUTF8String:buffer] : nil;
}

- (NSString *)sendSocketCommand:(NSString *)command expectsReply:(BOOL)expectsReply
{
    NSString *result = [self sendSocketCommandOnce:command expectsReply:expectsReply];
    // 偶发一次不回包（服务端正忙）就重连再发一次，避免网页端误报「服务不可用」。
    if (result == nil) {
        result = [self sendSocketCommandOnce:command expectsReply:expectsReply];
    }
    if (result == nil) {
        self.lastError = @"本机 小新Lap 服务没有返回响应。";
        return @"-1;;小新Lap 服务不可用。";
    }
    self.lastError = [result hasPrefix:@"-1"] ? result : @"";
    return result;
}

- (NSString *)payloadFromSocketReply:(NSString *)reply
{
    NSString *trimmed = [reply stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [trimmed hasPrefix:@"0;;"] ? [trimmed substringFromIndex:3] : trimmed;
}

- (NSDictionary *)status
{
    NSString *rawSize = [self sendSocketCommand:@"251" expectsReply:YES];
    NSString *rawOrientation = [self sendSocketCommand:@"252" expectsReply:YES];
    NSString *rawBattery = [self sendSocketCommand:@"2531" expectsReply:YES];
    NSString *rawRuntime = [self sendSocketCommand:@"2532" expectsReply:YES];
    NSString *size = [self payloadFromSocketReply:rawSize];
    NSString *orientation = [self payloadFromSocketReply:rawOrientation];
    NSString *battery = [self payloadFromSocketReply:rawBattery];
    NSString *runtime = [self payloadFromSocketReply:rawRuntime];
    NSArray *sizeParts = [size componentsSeparatedByString:@";;"];
    NSArray *batteryParts = [battery componentsSeparatedByString:@";;"];
    NSArray *runtimeParts = [runtime componentsSeparatedByString:@";;"];
    NSString *version = ZXDashboardAppVersion();
    // 四条里任意一条有响应就算服务在线：251 要等 SpringBoard 主线程，最容易被卡住，
    // 只盯它会让网页端误报「服务不可用」。
    BOOL serviceOnline = [rawSize hasPrefix:@"0"] || [rawOrientation hasPrefix:@"0"] ||
                         [rawBattery hasPrefix:@"0"] || [rawRuntime hasPrefix:@"0"];
    if (serviceOnline) self.lastError = @"";
    return @{
        @"running": @(self.server.running),
        @"serviceOnline": @(serviceOnline),
        @"port": @(self.server.port),
        @"version": version,
        @"screen": @{ @"width": sizeParts.count > 0 ? sizeParts[0] : @"", @"height": sizeParts.count > 1 ? sizeParts[1] : @"" },
        @"orientation": orientation ?: @"",
        @"battery": batteryParts.count > 1 ? batteryParts[1] : @"",
        @"foregroundApp": runtimeParts.count > 0 ? runtimeParts[0] : @"",
        @"scriptPlaying": runtimeParts.count > 1 ? @([runtimeParts[1] boolValue]) : @NO,
        @"recording": runtimeParts.count > 2 ? @([runtimeParts[2] boolValue]) : @NO,
        @"lastAction": self.lastAction ?: @"就绪",
        @"lastError": self.lastError ?: @"",
        @"scriptCount": @([self scripts].count)
    };
}

- (NSString *)recentLogs
{
    NSString *logs = [NSString stringWithContentsOfFile:RUNTIME_OUTPUT_PATH encoding:NSUTF8StringEncoding error:nil] ?: @"";
    if (logs.length <= ZXDashboardMaximumLogLength) return logs;
    return [@"[Showing the newest log output.]\n" stringByAppendingString:[logs substringFromIndex:logs.length - ZXDashboardMaximumLogLength]];
}

- (BOOL)isSafeAssetFileName:(NSString *)fileName
{
    if (fileName.length == 0 || [fileName isEqualToString:@"."] || [fileName isEqualToString:@".."] ||
        [fileName rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\"]].location != NSNotFound) {
        return NO;
    }
    return [fileName caseInsensitiveCompare:@"info.plist"] != NSOrderedSame;
}

- (NSString *)dashboardHTML
{
    NSString *path = @"/var/jb/Applications/zxtouch.app/index.html";
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) path = nil;
    NSString *html = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
    return html ?: @"<h1>小新Lap 控制台不可用。</h1>";
}

- (void)configureHandlers
{
    __weak typeof(self) weakSelf = self;

    [self.server addHandlerForMethod:@"GET" path:@"/" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        return [GCDWebServerDataResponse responseWithHTML:[strongSelf dashboardHTML]];
    }];

    [self.server addHandlerForMethod:@"GET" path:@"/api/scripts" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        return [strongSelf jsonResponse:@{ @"ok": @YES, @"scripts": [strongSelf scripts] } status:200];
    }];

    [self.server addHandlerForMethod:@"GET" path:@"/api/status" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        return [strongSelf jsonResponse:@{ @"ok": @YES, @"status": [strongSelf status] } status:200];
    }];

    [self.server addHandlerForMethod:@"GET" path:@"/api/logs" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        return [strongSelf jsonResponse:@{ @"ok": @YES, @"logs": [strongSelf recentLogs] } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/logs/clear" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        NSError *error = nil;
        [@"" writeToFile:RUNTIME_OUTPUT_PATH atomically:YES encoding:NSUTF8StringEncoding error:&error];
        if (error) return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": error.localizedDescription ?: @"无法清空日志。" } status:500];
        strongSelf.lastAction = @"清空日志";
        return [strongSelf jsonResponse:@{ @"ok": @YES } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/run" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        NSDictionary *body = [request.jsonObject isKindOfClass:[NSDictionary class]] ? request.jsonObject : @{};
        NSString *bundlePath = [strongSelf bundlePathForRelativePath:body[@"path"]];
        if (!bundlePath) return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": @"未找到脚本。" } status:404];
        NSString *result = [strongSelf sendSocketCommand:[@"19" stringByAppendingString:bundlePath] expectsReply:YES];
        strongSelf.lastAction = [NSString stringWithFormat:@"运行 %@", bundlePath.lastPathComponent];
        return [strongSelf jsonResponse:@{ @"ok": @([result hasPrefix:@"0"]), @"result": result ?: @"" } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/stop" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        NSString *result = [strongSelf sendSocketCommand:@"20" expectsReply:YES];
        strongSelf.lastAction = @"停止脚本";
        return [strongSelf jsonResponse:@{ @"ok": @([result hasPrefix:@"0"]), @"result": result ?: @"" } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/record/start" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        NSString *result = [strongSelf sendSocketCommand:@"14" expectsReply:YES];
        strongSelf.lastAction = @"开始录制";
        return [strongSelf jsonResponse:@{ @"ok": @(![result hasPrefix:@"-1"]), @"result": result ?: @"" } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/record/stop" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        NSString *result = [strongSelf sendSocketCommand:@"15" expectsReply:YES];
        strongSelf.lastAction = @"停止录制";
        return [strongSelf jsonResponse:@{ @"ok": @([result hasPrefix:@"0"]), @"result": result ?: @"" } status:200];
    }];

    // 救急用：某个脚本/功能把屏幕点击占住、设备点不动时，从这里一键全停。
    [self.server addHandlerForMethod:@"POST" path:@"/api/stop-all" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        // 停脚本 → 关三个悬浮窗（网速 / 控制按钮 / 触摸坐标）→ 停屏幕坐标测试
        NSString *result = [strongSelf sendSocketCommand:@"20" expectsReply:YES];
        [strongSelf sendSocketCommand:@"31;;0" expectsReply:NO];
        [strongSelf sendSocketCommand:@"32;;0" expectsReply:NO];
        [strongSelf sendSocketCommand:@"42;;0" expectsReply:NO];
        [strongSelf sendSocketCommand:@"41;;0" expectsReply:NO];
        strongSelf.lastAction = @"停止所有功能";
        return [strongSelf jsonResponse:@{ @"ok": @(![result hasPrefix:@"-1"]), @"result": result ?: @"" } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/assets" requestClass:[GCDWebServerMultiPartFormRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerMultiPartFormRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        NSString *relativePath = [[request firstArgumentForControlName:@"script"] string];
        NSString *bundlePath = [strongSelf bundlePathForRelativePath:relativePath];
        GCDWebServerMultiPartFile *upload = [request firstFileForControlName:@"asset"];
        NSString *fileName = upload.fileName.lastPathComponent;
        NSDictionary *attributes = upload.temporaryPath.length ? [[NSFileManager defaultManager] attributesOfItemAtPath:upload.temporaryPath error:nil] : nil;
        unsigned long long size = [attributes fileSize];
        if (!bundlePath || upload == nil || ![strongSelf isSafeAssetFileName:fileName]) {
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": @"请选择脚本和素材文件。" } status:400];
        }
        if (size > ZXDashboardMaximumAssetSize) {
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": @"素材文件不能超过 25 MB。" } status:413];
        }
        NSString *destination = [bundlePath stringByAppendingPathComponent:fileName];
        [[NSFileManager defaultManager] removeItemAtPath:destination error:nil];
        NSError *error = nil;
        BOOL copied = [[NSFileManager defaultManager] copyItemAtPath:upload.temporaryPath toPath:destination error:&error];
        if (!copied) return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": error.localizedDescription ?: @"无法保存素材文件。" } status:500];
        strongSelf.lastAction = [NSString stringWithFormat:@"上传 %@", fileName];
        return [strongSelf jsonResponse:@{ @"ok": @YES, @"file": fileName } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/script/create" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        NSDictionary *body = [request.jsonObject isKindOfClass:[NSDictionary class]] ? request.jsonObject : @{};
        NSString *name = [body[@"name"] isKindOfClass:[NSString class]] ? body[@"name"] : @"";
        NSString *folder = [body[@"folder"] isKindOfClass:[NSString class]] ? body[@"folder"] : @"";
        if (![strongSelf isSafeScriptName:name]) {
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": @"脚本名无效，不能包含 / \\ : * ? \" < > | 等字符。" } status:400];
        }
        NSString *bundleName = [name stringByAppendingPathExtension:@"bdl"];
        NSString *relativePath = folder.length ? [folder stringByAppendingPathComponent:bundleName] : bundleName;
        NSString *bundlePath = [strongSelf safePathForRelativePath:relativePath mustExist:NO];
        if (!bundlePath) {
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": @"路径无效。" } status:400];
        }
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if ([fileManager fileExistsAtPath:bundlePath]) {
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": @"同名脚本已存在。" } status:409];
        }
        NSError *error = nil;
        if (![fileManager createDirectoryAtPath:bundlePath withIntermediateDirectories:YES attributes:nil error:&error]) {
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": error.localizedDescription ?: @"无法创建脚本目录。" } status:500];
        }
        NSDictionary *info = @{ @"Entry": @"main.py" };
        if (![info writeToFile:[bundlePath stringByAppendingPathComponent:@"info.plist"] atomically:YES]) {
            [fileManager removeItemAtPath:bundlePath error:nil];
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": @"无法写入 info.plist。" } status:500];
        }
        NSString *template = @"# -*- coding: utf-8 -*-\n# 小新Lap 脚本\n\n";
        if (![template writeToFile:[bundlePath stringByAppendingPathComponent:@"main.py"] atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
            [fileManager removeItemAtPath:bundlePath error:nil];
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": error.localizedDescription ?: @"无法写入 main.py。" } status:500];
        }
        strongSelf.lastAction = [NSString stringWithFormat:@"新建脚本 %@", name];
        return [strongSelf jsonResponse:@{ @"ok": @YES, @"path": [strongSelf relativePathForScriptsPath:bundlePath] } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/folder/create" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        NSDictionary *body = [request.jsonObject isKindOfClass:[NSDictionary class]] ? request.jsonObject : @{};
        NSString *name = [body[@"name"] isKindOfClass:[NSString class]] ? body[@"name"] : @"";
        NSString *folder = [body[@"folder"] isKindOfClass:[NSString class]] ? body[@"folder"] : @"";
        if (![strongSelf isSafeScriptName:name]) {
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": @"文件夹名无效，不能包含 / \\ : * ? \" < > | 等字符。" } status:400];
        }
        NSString *relativePath = folder.length ? [folder stringByAppendingPathComponent:name] : name;
        NSString *folderPath = [strongSelf safePathForRelativePath:relativePath mustExist:NO];
        if (!folderPath) {
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": @"路径无效。" } status:400];
        }
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if ([fileManager fileExistsAtPath:folderPath]) {
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": @"同名文件夹已存在。" } status:409];
        }
        NSError *error = nil;
        if (![fileManager createDirectoryAtPath:folderPath withIntermediateDirectories:YES attributes:nil error:&error]) {
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": error.localizedDescription ?: @"无法创建文件夹。" } status:500];
        }
        strongSelf.lastAction = [NSString stringWithFormat:@"新建文件夹 %@", name];
        return [strongSelf jsonResponse:@{ @"ok": @YES, @"path": [strongSelf relativePathForScriptsPath:folderPath] } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/script/delete" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        NSDictionary *body = [request.jsonObject isKindOfClass:[NSDictionary class]] ? request.jsonObject : @{};
        NSString *path = [strongSelf safePathForRelativePath:body[@"path"] mustExist:YES];
        if (!path) {
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": @"路径无效或不存在。" } status:404];
        }
        NSError *error = nil;
        if (![[NSFileManager defaultManager] removeItemAtPath:path error:&error]) {
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": error.localizedDescription ?: @"删除失败。" } status:500];
        }
        strongSelf.lastAction = [NSString stringWithFormat:@"删除 %@", path.lastPathComponent];
        return [strongSelf jsonResponse:@{ @"ok": @YES } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/script/rename" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        NSDictionary *body = [request.jsonObject isKindOfClass:[NSDictionary class]] ? request.jsonObject : @{};
        NSString *path = [strongSelf safePathForRelativePath:body[@"path"] mustExist:YES];
        NSString *newName = [body[@"newName"] isKindOfClass:[NSString class]] ? body[@"newName"] : @"";
        if (!path) {
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": @"路径无效或不存在。" } status:404];
        }
        if (![strongSelf isSafeScriptName:newName]) {
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": @"新名字无效，不能包含 / \\ : * ? \" < > | 等字符。" } status:400];
        }
        NSString *extension = path.pathExtension;
        NSString *newLastComponent = extension.length ? [newName stringByAppendingPathExtension:extension] : newName;
        NSString *newPath = [[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:newLastComponent];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if ([fileManager fileExistsAtPath:newPath]) {
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": @"同名文件已存在。" } status:409];
        }
        NSError *error = nil;
        if (![fileManager moveItemAtPath:path toPath:newPath error:&error]) {
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": error.localizedDescription ?: @"重命名失败。" } status:500];
        }
        strongSelf.lastAction = [NSString stringWithFormat:@"重命名为 %@", newLastComponent];
        return [strongSelf jsonResponse:@{ @"ok": @YES, @"path": [strongSelf relativePathForScriptsPath:newPath] } status:200];
    }];

    [self.server addHandlerForMethod:@"GET" path:@"/api/script/read" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        NSString *bundlePath = [strongSelf bundlePathForRelativePath:request.query[@"path"]];
        if (!bundlePath) {
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": @"未找到脚本。" } status:404];
        }
        NSString *entryPath = [strongSelf entryPathForBundle:bundlePath];
        NSString *content = entryPath ? [NSString stringWithContentsOfFile:entryPath encoding:NSUTF8StringEncoding error:nil] : nil;
        if (!content) {
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": @"无法读取脚本入口文件。" } status:404];
        }
        return [strongSelf jsonResponse:@{
            @"ok": @YES,
            @"content": content,
            @"name": bundlePath.lastPathComponent.stringByDeletingPathExtension,
            @"modified": [strongSelf modifiedDateStringForPath:entryPath]
        } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/script/save" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        NSDictionary *body = [request.jsonObject isKindOfClass:[NSDictionary class]] ? request.jsonObject : @{};
        NSString *bundlePath = [strongSelf bundlePathForRelativePath:body[@"path"]];
        NSString *content = [body[@"content"] isKindOfClass:[NSString class]] ? body[@"content"] : nil;
        if (!bundlePath) {
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": @"未找到脚本。" } status:404];
        }
        if (content == nil) {
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": @"缺少脚本内容。" } status:400];
        }
        NSString *entryPath = [strongSelf entryPathForBundle:bundlePath];
        if (!entryPath) {
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": @"脚本缺少入口文件配置。" } status:404];
        }
        NSError *error = nil;
        if (![content writeToFile:entryPath atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": error.localizedDescription ?: @"保存失败。" } status:500];
        }
        strongSelf.lastAction = [NSString stringWithFormat:@"保存 %@", bundlePath.lastPathComponent];
        return [strongSelf jsonResponse:@{ @"ok": @YES } status:200];
    }];

    [self.server addHandlerForMethod:@"GET" path:@"/api/download" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        NSString *bundlePath = [strongSelf bundlePathForRelativePath:request.query[@"path"]];
        NSString *entry = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"info.plist"]][@"Entry"];
        NSString *entryPath = entry.length ? [bundlePath stringByAppendingPathComponent:entry] : nil;
        if (!entryPath || ![[NSFileManager defaultManager] fileExistsAtPath:entryPath]) {
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": @"未找到脚本入口文件。" } status:404];
        }
        return [GCDWebServerFileResponse responseWithFile:entryPath isAttachment:YES];
    }];
}

- (BOOL)start
{
    if (self.server.running) return YES;
    self.server = [[GCDWebServer alloc] init];
    [self configureHandlers];
    NSError *error = nil;
    BOOL started = [self.server startWithOptions:@{
        GCDWebServerOption_Port: @8080,
        GCDWebServerOption_ServerName: @"ZXTouch Dashboard",
        GCDWebServerOption_AutomaticallySuspendInBackground: @NO
    } error:&error];
    self.lastError = started ? @"" : (error.localizedDescription ?: @"无法启动控制面板。");
    if (!started) self.server = nil;
    return started;
}

- (void)stop
{
    [self.server stop];
    self.server = nil;
}

@end

static ZXRemoteDashboardServer *ZXDashboardServer;

void ZXDashboardReloadConfiguration(void)
{
    NSDictionary *configuration = [NSDictionary dictionaryWithContentsOfFile:ZXDashboardConfigPath];
    if (![configuration isKindOfClass:[NSDictionary class]]) {
        NSDictionary *legacy = [NSDictionary dictionaryWithContentsOfFile:@"/var/jb/var/mobile/Library/Preferences/com.zjx.zxtouch.plist"];
        NSMutableDictionary *migrated = [NSMutableDictionary dictionary];
        id legacyEnabled = legacy[@"zxtouch_remote_dashboard_enabled"];
        NSString *legacyToken = [legacy[@"zxtouch_remote_dashboard_token"] isKindOfClass:[NSString class]] ? legacy[@"zxtouch_remote_dashboard_token"] : @"";
        if (legacyEnabled) migrated[ZXDashboardEnabledKey] = legacyEnabled;
        if (legacyToken.length) migrated[ZXDashboardTokenKey] = legacyToken;
        if (migrated.count) [migrated writeToFile:ZXDashboardConfigPath atomically:YES];
        configuration = migrated;
    }
    BOOL enabled = [configuration[ZXDashboardEnabledKey] boolValue];
    NSString *token = [configuration[ZXDashboardTokenKey] isKindOfClass:[NSString class]] ? configuration[ZXDashboardTokenKey] : @"";
    if (!enabled || token.length == 0) {
        [ZXDashboardServer stop];
        ZXDashboardServer = nil;
        return;
    }
    if (ZXDashboardServer && ![ZXDashboardServer.token isEqualToString:token]) {
        [ZXDashboardServer stop];
        ZXDashboardServer = nil;
    }
    if (!ZXDashboardServer) ZXDashboardServer = [[ZXRemoteDashboardServer alloc] initWithToken:token];
    [ZXDashboardServer start];
}

#else

static NSString *ZXDashboardSettingsLastError = @"";

static NSMutableDictionary *ZXDashboardConfiguration(void)
{
    NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:ZXDashboardConfigPath];
    if ([stored isKindOfClass:[NSDictionary class]]) return [stored mutableCopy];

    NSMutableDictionary *configuration = [NSMutableDictionary dictionary];
    NSUserDefaults *legacyDefaults = [NSUserDefaults standardUserDefaults];
    id legacyEnabled = [legacyDefaults objectForKey:@"zxtouch_remote_dashboard_enabled"];
    NSString *legacyToken = [legacyDefaults stringForKey:@"zxtouch_remote_dashboard_token"];
    if (legacyEnabled) configuration[ZXDashboardEnabledKey] = legacyEnabled;
    if (legacyToken.length) configuration[ZXDashboardTokenKey] = legacyToken;
    return configuration;
}

static NSString *ZXDashboardToken(NSMutableDictionary *configuration)
{
    NSString *token = [configuration[ZXDashboardTokenKey] isKindOfClass:[NSString class]] ? configuration[ZXDashboardTokenKey] : @"";
    if (token.length == 0) {
        token = [[NSUUID UUID].UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
        configuration[ZXDashboardTokenKey] = token;
    }
    return token;
}

BOOL ZXRemoteDashboardSetEnabled(BOOL enabled)
{
    NSMutableDictionary *configuration = ZXDashboardConfiguration();
    ZXDashboardToken(configuration);
    configuration[ZXDashboardEnabledKey] = @(enabled);
    NSError *directoryError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:[ZXDashboardConfigPath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:&directoryError];
    BOOL saved = directoryError == nil && [configuration writeToFile:ZXDashboardConfigPath atomically:YES];
    ZXDashboardSettingsLastError = saved ? @"" : (directoryError.localizedDescription ?: @"无法保存远程控制面板设置。");
    if (saved) notify_post(ZXDashboardConfigurationNotification);
    return saved;
}

BOOL ZXRemoteDashboardIsEnabled(void)
{
    return [ZXDashboardConfiguration()[ZXDashboardEnabledKey] boolValue];
}

NSString *ZXRemoteDashboardURL(void)
{
    NSMutableDictionary *configuration = ZXDashboardConfiguration();
    NSString *token = ZXDashboardToken(configuration);
    NSString *host = ZXDashboardIPAddress() ?: @"iPad的IP地址";
    return [NSString stringWithFormat:@"http://%@:%d/?token=%@", host, 8080, token];
}

NSString *ZXRemoteDashboardLastError(void)
{
    return ZXDashboardSettingsLastError ?: @"";
}

#endif
