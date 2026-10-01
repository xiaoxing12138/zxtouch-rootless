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

NSString *ZXScriptFunctionEnvPrefix(NSString *scriptBundlePath)
{
    NSArray<NSString *> *selection = ZXScriptFunctionSelection(scriptBundlePath);
    if (selection.count == 0) return @"";  // 没勾选过 → 全部功能都跑

    NSArray<NSString *> *declared = ZXScriptFunctionNames(scriptBundlePath);
    if (declared.count == 0) return @"";

    NSMutableArray<NSString *> *indexes = [NSMutableArray array];
    for (NSUInteger i = 0; i < declared.count; i++) {
        if ([selection containsObject:declared[i]]) {
            [indexes addObject:[NSString stringWithFormat:@"%lu", (unsigned long)i]];
        }
    }
    if (indexes.count == 0) return @"";  // 勾选的功能在新脚本里都不存在了 → 退回全跑

    return [NSString stringWithFormat:@"ZX_FUNCS=%@ ", [indexes componentsJoinedByString:@","]];
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
            if (ZXScriptFunctionNames(path).count > 0) return path;
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