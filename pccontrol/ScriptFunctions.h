#ifndef SCRIPT_FUNCTIONS_H
#define SCRIPT_FUNCTIONS_H

#import <Foundation/Foundation.h>

// 功能勾选：脚本入口文件里用一行 `# @功能 名称` 声明功能，声明顺序即功能顺序。
// 悬浮面板的「功能」页读这些声明生成勾选框，勾选结果按脚本路径存 plist，
// 启动脚本时通过环境变量 ZX_FUNCS（功能序号，逗号分隔）传给脚本。

// 解析脚本声明的功能名（按声明顺序）；没声明返回空数组
NSArray<NSString *> *ZXScriptFunctionNames(NSString *scriptBundlePath);

// 读该脚本上次勾选的功能名；从没勾选过返回 nil（= 全跑）
NSArray<NSString *> *ZXScriptFunctionSelection(NSString *scriptBundlePath);

// 保存勾选结果
void ZXSaveScriptFunctionSelection(NSString *scriptBundlePath, NSArray<NSString *> *names);

// 启动命令用的环境变量前缀，如 "ZX_FUNCS=0,2 "。
// 没勾选过 / 勾选的脚本没有功能声明 / 勾选的功能已全部不存在 → 返回 @""（脚本全跑）
NSString *ZXScriptFunctionEnvPrefix(NSString *scriptBundlePath);

// 「功能」页上次使用的脚本
NSString *ZXLastFunctionScriptPath(void);
void ZXSaveLastFunctionScriptPath(NSString *scriptBundlePath);

// 脚本目录里第一个声明了功能的 .bdl（找不到返回 nil）
NSString *ZXFirstScriptPathWithFunctions(void);

#endif