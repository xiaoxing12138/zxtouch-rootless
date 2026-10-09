//
//  FlowScript.h
//  小新Lap 可视化脚本
//
//  一块脚本包（xxx.bdl）里可以有两份「真源」：
//    - 手写脚本：main.py 就是真源
//    - 可视化脚本：flow.plist 是真源，main.py 是它生成出来的产物
//  这个类负责后者的模型、类型元数据、以及 main.py 的代码生成。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 流程真源文件名（放在脚本包里）
extern NSString * const kFlowFileName;
/// 识图模板存放目录（和手写脚本共用同一个，位置固定，脚本改名也不会丢）
extern NSString * const kFlowTemplateFolder;

// ---------------------------------------------------------------------------
// 动作类型
// ---------------------------------------------------------------------------
extern NSString * const kFlowTap;        // 点击
extern NSString * const kFlowSwipe;      // 滑动
extern NSString * const kFlowWait;       // 等待
extern NSString * const kFlowToast;      // 提示
extern NSString * const kFlowColor;      // 识色（条件）
extern NSString * const kFlowFindColor;  // 找色（条件）
extern NSString * const kFlowImage;      // 识图（条件）
extern NSString * const kFlowOCR;        // 识字（条件）

/// 在弹窗里追加的「从屏幕取…」动作
typedef NS_ENUM(NSInteger, FlowPickMode) {
    FlowPickModeNone = 0,
    FlowPickModePoint,     // 取一个坐标点 → 写回 x/y 键
    FlowPickModePath,      // 一帧上放两个选择器取起点/终点 → 写回 x1/y1/x2/y2 键
    FlowPickModeRect,      // 框一个区域 → 写回 x1/y1/x2/y2 键
    FlowPickModeColor,     // 取一个点并读它的颜色 → 写回 x/y 与 Color 键
    FlowPickModeTemplate,  // 框选并存成识图模板 → 写回 Template 键
};

@interface FlowFieldSpec : NSObject
@property (nonatomic, copy) NSString *key;          // plist 键名
@property (nonatomic, copy) NSString *title;        // 弹窗上的标签
@property (nonatomic) BOOL integer;                 // 只用整数键盘
@property (nonatomic) BOOL numeric;                 // 纯数值（含小数）：输入框后面会挂上下箭头步进器
@property (nonatomic, copy) NSString *defaultValue;
/// 非空 = 这一行是「分段选择」（如 包含 / 等于 / 不包含），不是输入框
@property (nonatomic, copy, nullable) NSArray<NSString *> *choiceTitles;
/// 与 choiceTitles 一一对应，存进 plist 的值；缺省时直接存 choiceTitles
@property (nonatomic, copy, nullable) NSArray<NSString *> *choiceValues;
+ (instancetype)key:(NSString *)key title:(NSString *)title integer:(BOOL)integer def:(NSString *)def;
/// 同上，并标记为「数值字段」（小数也走 DecimalPad + 上下箭头步进器）
+ (instancetype)numKey:(NSString *)key title:(NSString *)title integer:(BOOL)integer def:(NSString *)def;
@end

@interface FlowStepType : NSObject
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy) NSString *title;        // 「点击」
@property (nonatomic, copy) NSString *symbolName;   // SF Symbol
@property (nonatomic) BOOL isCondition;             // 是不是「判断」类（有成立/不成立）
@property (nonatomic, copy) NSString *pickActionTitle;  // 空串 = 这个类型没有取点动作
@property (nonatomic) FlowPickMode pickMode;
@property (nonatomic, copy) NSArray<NSString *> *pickTargets;
@property (nonatomic, copy) NSArray<FlowFieldSpec *> *fields;
@end

/// 流程（flow.plist 的顶层字典）
@interface FlowScript : NSObject

+ (NSArray<FlowStepType *> *)allStepTypes;       // 顶层能加的全部类型
+ (NSArray<FlowStepType *> *)simpleStepTypes;    // 「成立 / 不成立」分支里能加的类型（只能放动作）
+ (nullable FlowStepType *)typeForKind:(NSString *)kind;

+ (NSMutableDictionary *)newStepOfKind:(NSString *)kind;
/// 深拷贝一步（含成立/不成立分支，全部转成可变），用于「复制到下方」
+ (NSMutableDictionary *)mutableStepFromStep:(NSDictionary *)step;

/// 编辑弹窗里拿到的是字符串，这里按字段类型转成 plist 里该存的值
+ (id)valueFromText:(nullable NSString *)text integer:(BOOL)integer;
/// plist 里的值转成弹窗/列表上显示的文字
+ (NSString *)textForValue:(nullable id)value;

/// 列表里那一行的大字（「点击 (400, 400) ×3」）
+ (NSString *)summaryForStep:(NSDictionary *)step;
/// 列表里那一行的小字（条件的成立/不成立动作数）；不需要就返回 nil
+ (nullable NSString *)detailForStep:(NSDictionary *)step;

+ (NSMutableDictionary *)emptyFlow;
+ (nullable NSMutableDictionary *)loadFlowFromBundle:(NSString *)bundlePath;
+ (BOOL)saveFlow:(NSDictionary *)flow toBundle:(NSString *)bundlePath error:(NSError **)error;
/// 按流程生成 main.py 和 info.plist（保留已有的 Schedule 键）
+ (BOOL)writeGeneratedScriptForFlow:(NSDictionary *)flow
                           toBundle:(NSString *)bundlePath
                              error:(NSError **)error;
/// 这个脚本包里有没有可视化流程
+ (BOOL)bundleHasFlow:(NSString *)bundlePath;
/// main.py 是不是这个生成器产出的（用来在覆盖手写脚本前提醒用户）
+ (BOOL)bundleHasGeneratedScript:(NSString *)bundlePath;
/// 新建一个可视化脚本包：建目录 + info.plist + 空的 flow.plist + main.py
+ (BOOL)createVisualScriptAtPath:(NSString *)bundlePath error:(NSError **)error;
/// 生成出来大概长什么样（保存前的预览）
+ (NSString *)pythonSourceForFlow:(NSDictionary *)flow;

@end

NS_ASSUME_NONNULL_END
