#import "ScriptFunctions.h"
#include "Config.h"
#include "Common.h"

// 功能声明标记：脚本里写成 `# @功能 名称`
static NSString *ZXFunctionMarker(void) {
    return @"@功能";
}

static NSString *ZXFunctionEntryFilePath(NSString *scriptBundlePath)
{
    if (scriptBundlePath.length == 0) return nil;
    NSDictionary *scriptInfo = [NSDictionary dictionaryWithContentsOfFile:
                                [scriptBundlePath stringByAppendingPathComponent:@"info.plist"]];
    NSString *entry = scriptInfo[@"Entry"];
    if (![entry isKindOfClass:[NSString class]] || entry.length == 0) entry = @"main.py";
    return [scriptBundlePath stringByAppendingPathComponent:entry];
}

NSArray<NSString *> *ZXScriptFunctionNames(NSString *scriptBundlePath)
{
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSString *entryPath = ZXFunctionEntryFilePath(scriptBundlePath);
    if (entryPath.length == 0) return names;

    NSString *source = [NSString stringWithContentsOfFile:entryPath
                                                encoding:NSUTF8StringEncoding
                                                   error:nil];
    if (source.length == 0) return names;

    NSCharacterSet *blank = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    for (NSString *rawLine in [source componentsSeparatedByString:@"\n"]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:blank];
        if (line.length < 2 || ![line hasPrefix:@"#"]) continue;

        NSString *body = [[line substringFromIndex:1] stringByTrimmingCharactersInSet:blank];
        if (![body hasPrefix:ZXFunctionMarker()]) continue;

        NSString *name = [[body substringFromIndex:ZXFunctionMarker().length]
                          stringByTrimmingCharactersInSet:blank];
        if (name.length > 0) [names addObject:name];
    }
    return names;
}

static NSMutableDictionary *ZXFunctionConfigRead(void)
{
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:SCRIPT_FUNCTIONS_CONFIG_PATH];
    if (![config isKindOfClass:[NSDictionary class]]) config = @{};
    return [NSMutableDictionary dictionaryWithDictionary:config];
}

NSArray<NSString *> *ZXScriptFunctionSelection(NSString *scriptBundlePath)
{
    if (scriptBundlePath.length == 0) return nil;
    NSDictionary *config = ZXFunctionConfigRead();
    NSDictionary *scripts = config[@"scripts"];
    if (![scripts isKindOfClass:[NSDictionary class]]) return nil;

    id saved = scripts[scriptBundlePath];
    if (![saved isKindOfClass:[NSArray class]]) return nil;

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id item in (NSArray *)saved) {
        if ([item isKindOfClass:[NSString class]]) [names addObject:item];
    }
    return names;
}

void ZXSaveScriptFunctionSelection(NSString *scriptBundlePath, NSArray<NSString *> *names)
{
    if (scriptBundlePath.length == 0) return;

    NSMutableDictionary *config = ZXFunctionConfigRead();
    NSDictionary *existing = config[@"scripts"];
    NSMutableDictionary *scripts = [existing isKindOfClass:[NSDictionary class]]
        ? [NSMutableDictionary dictionaryWithDictionary:existing]
        : [NSMutableDictionary dictionary];

    scripts[scriptBundlePath] = ([names isKindOfClass:[NSArray class]] ? [names copy] : @[]);
    config[@"scripts"] = scripts;
    [config writeToFile:SCRIPT_FUNCTIONS_CONFIG_PATH atomically:YES];
}

#define ZX_OPTIONS_FILE_NAME @"script_options.json"

#pragma mark - 选项

static NSString *ZXOptionMarker(void) {
    return @"@选项";
}

NSArray<NSDictionary *> *ZXScriptOptionDeclarations(NSString *scriptBundlePath)
{
    NSMutableArray<NSDictionary *> *decls = [NSMutableArray array];
    NSString *entryPath = ZXFunctionEntryFilePath(scriptBundlePath);
    if (entryPath.length == 0) return decls;

    NSString *source = [NSString stringWithContentsOfFile:entryPath
                                                encoding:NSUTF8StringEncoding
                                                   error:nil];
    if (source.length == 0) return decls;

    NSCharacterSet *blank = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    for (NSString *rawLine in [source componentsSeparatedByString:@"\n"]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:blank];
        if (line.length < 2 || ![line hasPrefix:@"#"]) continue;

        NSString *body = [[line substringFromIndex:1] stringByTrimmingCharactersInSet:blank];
        if (![body hasPrefix:ZXOptionMarker()]) continue;

        NSString *rest = [[body substringFromIndex:ZXOptionMarker().length]
                          stringByTrimmingCharactersInSet:blank];
        NSArray<NSString *> *rawTokens =
            [rest componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSMutableArray<NSString *> *tokens = [NSMutableArray array];
        for (NSString *t in rawTokens) if (t.length > 0) [tokens addObject:t];
        if (tokens.count < 2) continue;   // 至少要「名称 类型」

        NSString *name = tokens[0];
        NSString *typeText = tokens[1];

        ZXOptionType type = ZXOptionTypeText;   // 类型写错时按文本处理，不静默丢选项
        if ([typeText isEqualToString:@"数字"]) type = ZXOptionTypeNumber;
        else if ([typeText isEqualToString:@"文本"]) type = ZXOptionTypeText;
        else if ([typeText isEqualToString:@"下拉"]) type = ZXOptionTypeDropdown;
        else if ([typeText isEqualToString:@"单选"]) type = ZXOptionTypeRadio;

        NSString *defaultValue = @"";
        NSArray<NSString *> *choices = @[];
        for (NSUInteger i = 2; i < tokens.count; i++) {
            NSString *token = tokens[i];
            NSRange eq = [token rangeOfString:@"="];
            if (eq.location == NSNotFound) continue;
            NSString *key = [token substringToIndex:eq.location];
            NSString *value = [token substringFromIndex:eq.location + 1];
            if ([key isEqualToString:@"默认"]) defaultValue = value;
            else if ([key isEqualToString:@"候选"]) choices = [value componentsSeparatedByString:@"|"];
        }

        if ((type == ZXOptionTypeDropdown || type == ZXOptionTypeRadio) && choices.count == 0)
            type = ZXOptionTypeText;   // 没有候选项就退回文本，避免出现空控件

        if (type == ZXOptionTypeDropdown || type == ZXOptionTypeRadio) {
            if (![choices containsObject:defaultValue]) defaultValue = choices[0];
        }

        [decls addObject:@{ @"name": name,
                            @"type": @(type),
                            @"default": defaultValue,
                            @"choices": choices }];
    }
    return decls;
}

NSDictionary<NSString *, NSString *> *ZXScriptOptionValues(NSString *scriptBundlePath)
{
    if (scriptBundlePath.length == 0) return @{};
    NSDictionary *config = ZXFunctionConfigRead();
    NSDictionary *allOptions = config[@"options"];
    if (![allOptions isKindOfClass:[NSDictionary class]]) return @{};

    NSDictionary *saved = allOptions[scriptBundlePath];
    if (![saved isKindOfClass:[NSDictionary class]]) return @{};

    NSMutableDictionary<NSString *, NSString *> *values = [NSMutableDictionary dictionary];
    for (id key in (NSDictionary *)saved) {
        id value = ((NSDictionary *)saved)[key];
        if ([key isKindOfClass:[NSString class]] && [value isKindOfClass:[NSString class]])
            values[key] = value;
    }
    return values;
}

void ZXSaveScriptOptionValues(NSString *scriptBundlePath, NSDictionary<NSString *, NSString *> *values)
{
    if (scriptBundlePath.length == 0) return;

    NSMutableDictionary *config = ZXFunctionConfigRead();
    NSDictionary *existing = config[@"options"];
    NSMutableDictionary *allOptions = [existing isKindOfClass:[NSDictionary class]]
        ? [NSMutableDictionary dictionaryWithDictionary:existing]
        : [NSMutableDictionary dictionary];

    allOptions[scriptBundlePath] = ([values isKindOfClass:[NSDictionary class]] ? [values copy] : @{});
    config[@"options"] = allOptions;
    [config writeToFile:SCRIPT_FUNCTIONS_CONFIG_PATH atomically:YES];
}

NSDictionary<NSString *, NSString *> *ZXScriptEffectiveOptionValues(NSString *scriptBundlePath)
{
    NSDictionary<NSString *, NSString *> *saved = ZXScriptOptionValues(scriptBundlePath);
    NSMutableDictionary<NSString *, NSString *> *values = [NSMutableDictionary dictionary];
    for (NSDictionary *decl in ZXScriptOptionDeclarations(scriptBundlePath)) {
        NSString *name = decl[@"name"];
        NSString *value = saved[name];
        if (value.length == 0) value = decl[@"default"];
        values[name] = (value.length > 0) ? value : @"";
    }
    return values;
}

static NSString *ZXOptionsFilePath(void)
{
    return [[SCRIPT_FUNCTIONS_CONFIG_PATH stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:ZX_OPTIONS_FILE_NAME];
}

// 把选项的当前值写成 JSON 文件，让脚本用 ZX_OPTS_FILE 读；
// 用文件而不是环境变量，是为了中文值不被 shell 转义搞乱。
static BOOL ZXWriteScriptOptionFile(NSString *scriptBundlePath)
{
    NSDictionary<NSString *, NSString *> *values = ZXScriptEffectiveOptionValues(scriptBundlePath);
    NSData *json = [NSJSONSerialization dataWithJSONObject:values options:0 error:nil];
    if (!json) return NO;

    NSString *path = ZXOptionsFilePath();
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    return [json writeToFile:path atomically:YES];
}

#pragma mark - 启动环境变量

NSString *ZXScriptEnvPrefix(NSString *scriptBundlePath)
{
    if (scriptBundlePath.length == 0) return @"";

    NSMutableString *env = [NSMutableString string];

    // 选项：声明了才写文件（脚本可能只声明选项、不声明功能）
    if (ZXScriptOptionDeclarations(scriptBundlePath).count > 0 && ZXWriteScriptOptionFile(scriptBundlePath))
        [env appendFormat:@"ZX_OPTS_FILE=%@ ", ZXOptionsFilePath()];

    // 勾选的功能序号
    NSArray<NSString *> *selection = ZXScriptFunctionSelection(scriptBundlePath);
    NSArray<NSString *> *declared = ZXScriptFunctionNames(scriptBundlePath);
    if (selection.count > 0 && declared.count > 0) {
        NSMutableArray<NSString *> *indexes = [NSMutableArray array];
        for (NSUInteger i = 0; i < declared.count; i++) {
            if ([selection containsObject:declared[i]]) {
                [indexes addObject:[NSString stringWithFormat:@"%lu", (unsigned long)i]];
            }
        }
        // 勾选的功能在新脚本里都不存在了 → 不产出 ZX_FUNCS（退回全跑）
        if (indexes.count > 0)
            [env appendFormat:@"ZX_FUNCS=%@ ", [indexes componentsJoinedByString:@","]];
    }

    return env;
}

NSString *ZXLastFunctionScriptPath(void)
{
    NSDictionary *config = ZXFunctionConfigRead();
    NSString *path = config[@"last_script"];
    if (![path isKindOfClass:[NSString class]] || path.length == 0) return nil;
    return path;
}

void ZXSaveLastFunctionScriptPath(NSString *scriptBundlePath)
{
    if (scriptBundlePath.length == 0) return;
    NSMutableDictionary *config = ZXFunctionConfigRead();
    config[@"last_script"] = scriptBundlePath;
    [config writeToFile:SCRIPT_FUNCTIONS_CONFIG_PATH atomically:YES];
}

static NSString *ZXScanForScriptWithFunctions(NSString *folderPath, int depth)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *entries = [[fm contentsOfDirectoryAtPath:folderPath error:nil]
                                    sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSMutableArray<NSString *> *subFolders = [NSMutableArray array];

    for (NSString *name in entries) {
        NSString *path = [folderPath stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDir]) continue;

        if ([name hasSuffix:@".bdl"]) {
            if (ZXScriptFunctionNames(path).count > 0 ||
                ZXScriptOptionDeclarations(path).count > 0) return path;
        } else if (isDir && depth > 0) {
            [subFolders addObject:path];
        }
    }
    for (NSString *sub in subFolders) {
        NSString *found = ZXScanForScriptWithFunctions(sub, depth - 1);
        if (found) return found;
    }
    return nil;
}

NSString *ZXFirstScriptPathWithFunctions(void)
{
    return ZXScanForScriptWithFunctions(getScriptsFolder(), 2);
}