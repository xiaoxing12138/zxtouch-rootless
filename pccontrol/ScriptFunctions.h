#ifndef SCRIPT_FUNCTIONS_H
#define SCRIPT_FUNCTIONS_H

#import <Foundation/Foundation.h>

// 功能勾选：脚本入口文件里用一行 `# @功能 名称` 声明功能，声明顺序即功能顺序。
// 悬浮面板的「功能」页读这些声明生成勾选框，勾选结果按脚本路径存 plist，
// 启动脚本时通过环境变量 ZX_FUNCS（功能序号，逗号分隔）传给脚本。
//
// 选项：入口文件里用一行 `# @选项 名称 类型 [默认=值] [候选=甲|乙|丙]` 声明，
// 类型有 数字 / 文本 / 下拉 / 单选 四种。值按脚本路径存在同一份 plist 里，
// 启动脚本时引擎把「当前值」写成一个 JSON 文件，用 ZX_OPTS_FILE 把路径传给脚本。

typedef NS_ENUM(NSInteger, ZXOptionType) {
    ZXOptionTypeNumber = 0,   // 数字输入框
    ZXOptionTypeText,         // 文本输入框
    ZXOptionTypeDropdown,     // 下拉框
    ZXOptionTypeRadio         // 单选组
};

// 解析脚本声明的功能名（按声明顺序）；没声明返回空数组
NSArray<NSString *> *ZXScriptFunctionNames(NSString *scriptBundlePath);

// 解析脚本声明的选项，每项是：
//   name    : NSString       选项名称
//   type    : NSNumber       ZXOptionType
//   default : NSString       默认值（下拉/单选保证是 choices 之一）
//   choices : NSArray       候选项（数字/文本为空数组）
NSArray<NSDictionary *> *ZXScriptOptionDeclarations(NSString *scriptBundlePath);

// 读该脚本上次勾选的功能名；从没勾选过返回 nil（= 全跑）
NSArray<NSString *> *ZXScriptFunctionSelection(NSString *scriptBundlePath);

// 保存勾选结果
void ZXSaveScriptFunctionSelection(NSString *scriptBundlePath, NSArray<NSString *> *names);

// 读该脚本上次保存的选项值（名称 → 值，都是字符串）；没存过返回空字典
NSDictionary<NSString *, NSString *> *ZXScriptOptionValues(NSString *scriptBundlePath);

// 保存选项值
void ZXSaveScriptOptionValues(NSString *scriptBundlePath, NSDictionary<NSString *, NSString *> *values);

// 选项的当前值 = 保存过就用保存的，否则用声明里的默认值
NSDictionary<NSString *, NSString *> *ZXScriptEffectiveOptionValues(NSString *scriptBundlePath);

// 启动命令用的环境变量前缀，形如
// "ZX_OPTS_FILE=/.../script_options.json ZX_FUNCS=0,2 "
// 没勾选过 / 勾选的脚本没有功能声明 / 勾选的功能已全部不存在 → 不产出 ZX_FUNCS（脚本全跑）
NSString *ZXScriptEnvPrefix(NSString *scriptBundlePath);

// 「功能」页上次使用的脚本
NSString *ZXLastFunctionScriptPath(void);
void ZXSaveLastFunctionScriptPath(NSString *scriptBundlePath);

// 脚本目录里第一个声明了功能或选项的 .bdl（找不到返回 nil）
NSString *ZXFirstScriptPathWithFunctions(void);

#endif