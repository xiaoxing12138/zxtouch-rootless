//
//  FlowEditorViewController.m
//  小新Lap 可视化脚本
//

#import "FlowEditorViewController.h"
#import "FlowScript.h"
#import "ScreenPickerViewController.h"
#import "ScheduleSettingsViewController.h"
#import "Util.h"

#import <math.h>

#pragma mark - 代码预览页

/// 只读地把生成的 main.py 摊开给用户看
@interface ZXFlowCodePreviewViewController : UIViewController
@property (nonatomic, copy) NSString *source;
@end

@implementation ZXFlowCodePreviewViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UITextView *textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    textView.editable = NO;
    textView.alwaysBounceVertical = YES;
    textView.font = [UIFont systemFontOfSize:12];
    textView.text = self.source;
    textView.textContainerInset = UIEdgeInsetsMake(12, 12, 32, 12);
    [self.view addSubview:textView];
}

@end

#pragma mark - 编辑器

// 顶层页面的三段；分支模式只有「步骤」段
typedef NS_ENUM(NSInteger, ZXFlowSection) {
    ZXFlowSectionRunMode = 0,
    ZXFlowSectionSteps,
    ZXFlowSectionScript,
};

@interface FlowEditorViewController ()

@property (nonatomic, copy, nullable) NSString *bundlePath;
@property (nonatomic, strong, nullable) NSMutableDictionary *flow;   // 顶层：整条流程
@property (nonatomic, strong) NSMutableArray *steps;                 // 当前显示的步骤数组

@property (nonatomic) BOOL isBranch;
@property (nonatomic, copy) NSString *branchTitle;
/// 分支模式：分支自己不写文件，改动交给顶层编辑器落盘
@property (nonatomic, weak, nullable) FlowEditorViewController *rootEditor;

@property (nonatomic) BOOL edited;                   // 有没有改过（改过才写盘，光看看不动文件）
@property (nonatomic) BOOL reportedError;            // 同一个保存错误只弹一次
@property (nonatomic) BOOL checkedHandwritten;       // 手写覆盖提醒只问一次
@property (nonatomic, strong) UIBarButtonItem *sortButton;
@property (nonatomic, strong) UIBarButtonItem *doneButton;

@end

@implementation FlowEditorViewController

- (instancetype)initWithScriptBundlePath:(NSString *)bundlePath
{
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) {
        _bundlePath = [bundlePath copy];
        NSMutableDictionary *flow = [FlowScript loadFlowFromBundle:bundlePath];
        if (!flow) flow = [FlowScript emptyFlow];
        _flow = flow;
        _steps = flow[@"Steps"];
    }
    return self;
}

- (instancetype)initWithBranchSteps:(NSMutableArray *)steps title:(NSString *)title
{
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) {
        _isBranch = YES;
        _steps = steps;
        _branchTitle = [title copy];
    }
    return self;
}

#pragma mark - 生命周期

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = self.isBranch ? (self.branchTitle ?: @"分支") : @"可视化编辑";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 54;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;

    if (!self.isBranch) {
        self.sortButton = [[UIBarButtonItem alloc] initWithTitle:@"排序" style:UIBarButtonItemStylePlain
                                                          target:self action:@selector(toggleSorting)];
        self.doneButton = [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone
                                                          target:self action:@selector(doneTapped)];
        self.navigationItem.rightBarButtonItems = @[self.sortButton, self.doneButton];
    }
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    self.reportedError = NO;
    // 从「定时设置」或更深一层的分支页回来：数据可能变了，先落盘再刷新
    [self persist];
    [self.tableView reloadData];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (self.checkedHandwritten) return;
    self.checkedHandwritten = YES;
    [self warnBeforeOverwritingHandwrittenScript];
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated
{
    [super setEditing:editing animated:animated];
    self.sortButton.title = editing ? @"完成" : @"排序";
}

- (void)toggleSorting
{
    [self setEditing:!self.isEditing animated:YES];
}

- (void)doneTapped
{
    if (self.isEditing) {
        [self setEditing:NO animated:YES];
        return;
    }
    [self persist];
    [self.navigationController popViewControllerAnimated:YES];
}

/// 手写脚本一进编辑器就会被重新生成覆盖，先把话说明白
- (void)warnBeforeOverwritingHandwrittenScript
{
    if (self.isBranch || !self.bundlePath) return;
    if ([FlowScript bundleHasFlow:self.bundlePath]) return;            // 本来就是可视化脚本
    if ([FlowScript bundleHasGeneratedScript:self.bundlePath]) return;
    NSString *mainPath = [self.bundlePath stringByAppendingPathComponent:@"main.py"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:mainPath]) return;   // 空脚本，随便编

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"这个脚本是手写代码"
                                            message:@"在这里加步骤并改动之后，main.py 会被重新生成、原来的代码会被覆盖，也不会自动备份。要留着的话请先复制一份。"
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"返回" style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *action) {
        [self.navigationController popViewControllerAnimated:YES];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了，继续" style:UIAlertActionStyleDestructive handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 落盘

- (void)markEdited
{
    self.edited = YES;
    if (self.isBranch) [self.rootEditor markEditedFromBranch];
    else [self persist];
    [self.tableView reloadData];
}

/// 分支里的改动走这里：由顶层编辑器负责写 flow.plist 和 main.py
- (void)markEditedFromBranch
{
    self.edited = YES;
    [self persist];
}

- (void)persist
{
    if (self.isBranch || !self.edited || !self.bundlePath) return;
    NSError *error = nil;
    BOOL ok = [FlowScript saveFlow:self.flow toBundle:self.bundlePath error:&error] &&
              [FlowScript writeGeneratedScriptForFlow:self.flow toBundle:self.bundlePath error:&error];
    if (ok) {
        self.reportedError = NO;
        return;
    }
    if (self.reportedError) return;
    self.reportedError = YES;
    [Util showAlertBoxWithOneOption:self title:@"保存失败"
                            message:error.localizedDescription ?: @"未知错误" buttonString:@"确定"];
}

#pragma mark - 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return self.isBranch ? 1 : 3;
}

- (ZXFlowSection)sectionKind:(NSInteger)section
{
    return self.isBranch ? ZXFlowSectionSteps : (ZXFlowSection)section;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch ([self sectionKind:section]) {
        case ZXFlowSectionRunMode: return @"运行方式";
        case ZXFlowSectionSteps:   return self.isBranch ? @"这一支里做这些" : @"步骤";
        default:                   return @"脚本";
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    switch ([self sectionKind:section]) {
        case ZXFlowSectionRunMode:
            return @"循环次数填 0 = 一直循环，直到在悬浮窗里手动停止。每轮间隔 = 跑完一轮歇多久。";
        case ZXFlowSectionSteps:
            if (self.isBranch) return @"分支里只能放「点击 / 滑动 / 等待 / 提示」这类动作；要再判断就回外层加条件步骤。";
            return @"点一行改参数；条件步骤点右侧的 ⓘ 编辑「成立时 / 不成立时」要做的事。左滑删除，点右上角「排序」拖动调顺序。";
        default:
            return @"坐标、颜色、识图模板都可以从这一步直接对着屏幕量，量到的就是触摸指示器上显示的像素，不用自己换算。";
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch ([self sectionKind:section]) {
        case ZXFlowSectionRunMode: return 2;
        case ZXFlowSectionSteps:   return self.steps.count + 1;   // 最后一行是「添加」
        default:                   return 2;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    ZXFlowSection kind = [self sectionKind:indexPath.section];

    if (kind == ZXFlowSectionSteps) {
        if (indexPath.row >= (NSInteger)self.steps.count) return [self addStepCell];
        return [self stepCellAtIndexPath:indexPath];
    }
    return [self settingCellForRow:indexPath.row kind:kind];
}

- (UITableViewCell *)addStepCell
{
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"add"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"add"];
    cell.textLabel.text = self.isBranch ? @"＋ 往这一支里加动作" : @"＋ 添加步骤";
    cell.textLabel.textColor = self.view.tintColor;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.detailTextLabel.text = nil;
    return cell;
}

- (UITableViewCell *)stepCellAtIndexPath:(NSIndexPath *)indexPath
{
    NSDictionary *step = self.steps[indexPath.row];
    FlowStepType *type = [FlowScript typeForKind:step[@"Kind"]];

    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"step"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"step"];

    cell.textLabel.text = [FlowScript summaryForStep:step];
    cell.textLabel.numberOfLines = 2;
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    cell.textLabel.minimumScaleFactor = 0.8;

    cell.detailTextLabel.text = [FlowScript detailForStep:step];
    cell.detailTextLabel.numberOfLines = 2;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;

    cell.accessoryType = type.isCondition ? UITableViewCellAccessoryDetailButton : UITableViewCellAccessoryNone;
    if (@available(iOS 13.0, *)) {
        cell.imageView.image = [UIImage systemImageNamed:type.symbolName];
        cell.imageView.tintColor = self.view.tintColor;
    }
    return cell;
}

- (UITableViewCell *)settingCellForRow:(NSInteger)row kind:(ZXFlowSection)kind
{
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"setting"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"setting"];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    cell.textLabel.minimumScaleFactor = 0.85;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
    cell.detailTextLabel.minimumScaleFactor = 0.6;

    if (kind == ZXFlowSectionRunMode) {
        NSInteger times = [self.flow[@"LoopTimes"] integerValue];
        if (row == 0) {
            cell.textLabel.text = @"循环次数";
            cell.detailTextLabel.text = times > 0 ? [NSString stringWithFormat:@"%ld 次", (long)times] : @"一直循环";
        } else {
            cell.textLabel.text = @"每轮间隔";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ 秒", [FlowScript textForValue:self.flow[@"LoopInterval"]]];
        }
        return cell;
    }

    if (row == 0) {
        cell.textLabel.text = @"启动 / 结束";
        cell.detailTextLabel.text = [ScheduleSettingsViewController summaryForBundle:self.bundlePath];
    } else {
        cell.textLabel.text = @"查看生成的脚本";
        cell.detailTextLabel.text = nil;
    }
    return cell;
}

#pragma mark - 选中

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    ZXFlowSection kind = [self sectionKind:indexPath.section];

    if (kind == ZXFlowSectionSteps) {
        if (indexPath.row >= (NSInteger)self.steps.count) [self presentAddStepSheetFromIndexPath:indexPath];
        else [self presentEditorAtIndex:indexPath.row];
        return;
    }

    if (kind == ZXFlowSectionRunMode) {
        if (indexPath.row == 0) [self promptLoopTimes];
        else [self promptLoopInterval];
        return;
    }

    if (indexPath.row == 0) {
        ScheduleSettingsViewController *settings =
            [[ScheduleSettingsViewController alloc] initWithScriptBundlePath:self.bundlePath];
        [self.navigationController pushViewController:settings animated:YES];
    } else {
        ZXFlowCodePreviewViewController *preview = [[ZXFlowCodePreviewViewController alloc] init];
        preview.title = @"生成的脚本";
        preview.source = [FlowScript pythonSourceForFlow:self.flow];
        [self.navigationController pushViewController:preview animated:YES];
    }
}

- (void)tableView:(UITableView *)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath
{
    if ([self sectionKind:indexPath.section] != ZXFlowSectionSteps) return;
    if (indexPath.row >= (NSInteger)self.steps.count) return;

    NSMutableDictionary *step = self.steps[indexPath.row];
    FlowStepType *type = [FlowScript typeForKind:step[@"Kind"]];
    if (!type.isCondition) return;

    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:[FlowScript summaryForStep:step]
                                           message:@"这一支里的动作"
                                    preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"编辑「成立时」的动作" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [weakSelf pushBranchEditorForStep:step key:@"Then" title:@"成立时"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"编辑「不成立时」的动作" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [weakSelf pushBranchEditorForStep:step key:@"Else" title:@"不成立时"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    sheet.popoverPresentationController.sourceView = tableView;
    sheet.popoverPresentationController.sourceRect = [tableView rectForRowAtIndexPath:indexPath];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)pushBranchEditorForStep:(NSMutableDictionary *)step key:(NSString *)key title:(NSString *)title
{
    if (![step[key] isKindOfClass:[NSMutableArray class]]) {
        step[key] = [NSMutableArray array];      // 兜底：老流程或手改过的 plist 里可能不是可变数组
    }
    FlowEditorViewController *editor =
        [[FlowEditorViewController alloc] initWithBranchSteps:(NSMutableArray *)step[key] title:title];
    editor.rootEditor = self;
    [self.navigationController pushViewController:editor animated:YES];
}

#pragma mark - 增删排序

- (void)presentAddStepSheetFromIndexPath:(NSIndexPath *)indexPath
{
    NSArray<FlowStepType *> *types = self.isBranch ? [FlowScript simpleStepTypes] : [FlowScript allStepTypes];
    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:@"加什么步骤"
                                           message:(self.isBranch ? @"分支里只能放动作" : @"条件步骤可以带「成立 / 不成立」两支")
                                    preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (FlowStepType *type in types) {
        [sheet addAction:[UIAlertAction actionWithTitle:type.title style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            [weakSelf addStepOfType:type];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    sheet.popoverPresentationController.sourceView = self.tableView;
    sheet.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:indexPath];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)addStepOfType:(FlowStepType *)type
{
    NSMutableDictionary *step = [FlowScript newStepOfKind:type.kind];
    if (!step) return;
    [self.steps addObject:step];
    [self markEdited];
    [self presentEditorAtIndex:self.steps.count - 1];     // 加完直接把参数窗弹出来，省一次点击
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self sectionKind:indexPath.section] != ZXFlowSectionSteps) return nil;
    if (indexPath.row >= (NSInteger)self.steps.count) return nil;

    __weak typeof(self) weakSelf = self;
    UIContextualAction *delete =
        [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                title:@"删除"
                                              handler:^(UIContextualAction *action, UIView *sourceView,
                                                        void (^completionHandler)(BOOL)) {
        FlowEditorViewController *strongSelf = weakSelf;
        if (strongSelf && indexPath.row < (NSInteger)strongSelf.steps.count) {
            [strongSelf.steps removeObjectAtIndex:indexPath.row];
            [strongSelf markEdited];
        }
        completionHandler(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete]];
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath
{
    return [self sectionKind:indexPath.section] == ZXFlowSectionSteps
        && indexPath.row < (NSInteger)self.steps.count;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return UITableViewCellEditingStyleNone;      // 删除走左滑；编辑模式只用来拖动排序，不显示红圈
}

- (NSIndexPath *)tableView:(UITableView *)tableView
targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)sourceIndexPath
       toProposedIndexPath:(NSIndexPath *)proposedDestinationIndexPath
{
    if ([self sectionKind:proposedDestinationIndexPath.section] != ZXFlowSectionSteps) return sourceIndexPath;
    if (self.steps.count == 0) return sourceIndexPath;
    if (proposedDestinationIndexPath.row >= (NSInteger)self.steps.count) {
        return [NSIndexPath indexPathForRow:self.steps.count - 1 inSection:proposedDestinationIndexPath.section];
    }
    return proposedDestinationIndexPath;
}

- (void)tableView:(UITableView *)tableView
moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath
      toIndexPath:(NSIndexPath *)destinationIndexPath
{
    if (sourceIndexPath.row == destinationIndexPath.row) return;
    id step = self.steps[sourceIndexPath.row];
    [self.steps removeObjectAtIndex:sourceIndexPath.row];
    [self.steps insertObject:step atIndex:destinationIndexPath.row];
    // 这里不能 reloadData：UIKit 正在做移动动画，只更新数据 + 落盘
    self.edited = YES;
    if (self.isBranch) [self.rootEditor markEditedFromBranch];
    else [self persist];
}

#pragma mark - 运行方式

- (void)promptLoopTimes
{
    NSInteger times = [self.flow[@"LoopTimes"] integerValue];
    __weak typeof(self) weakSelf = self;
    [self promptNumberWithTitle:@"循环次数"
                           note:@"填 0 = 一直循环，直到手动停止"
                        current:[NSString stringWithFormat:@"%ld", (long)MAX(0, times)]
                       keyboard:UIKeyboardTypeNumberPad
                      onConfirm:^(NSString *text) {
        FlowEditorViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.flow[@"LoopTimes"] = @(MAX(0, (NSInteger)llround(text.doubleValue)));
        [strongSelf markEdited];
    }];
}

- (void)promptLoopInterval
{
    id current = self.flow[@"LoopInterval"];
    __weak typeof(self) weakSelf = self;
    [self promptNumberWithTitle:@"每轮间隔"
                           note:@"跑完一轮歇多少秒，可以填小数，例如 0.2"
                        current:[FlowScript textForValue:current ?: @0.2]
                       keyboard:UIKeyboardTypeNumbersAndPunctuation
                      onConfirm:^(NSString *text) {
        FlowEditorViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.flow[@"LoopInterval"] = @(MAX(0.0, text.doubleValue));
        [strongSelf markEdited];
    }];
}

- (void)promptNumberWithTitle:(NSString *)title
                         note:(NSString *)note
                      current:(NSString *)current
                     keyboard:(UIKeyboardType)keyboard
                    onConfirm:(void (^)(NSString *text))onConfirm
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:note
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = current;
        field.keyboardType = keyboard;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightMedium];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        onConfirm(alert.textFields.firstObject.text ?: @"");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 步骤参数弹窗

- (void)presentEditorAtIndex:(NSInteger)index
{
    if (index < 0 || index >= (NSInteger)self.steps.count) return;
    NSMutableDictionary *step = self.steps[index];
    FlowStepType *type = [FlowScript typeForKind:step[@"Kind"]];
    if (!type) return;

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:type.title
                                            message:(type.isCondition
                                                     ? @"先填判断条件；成立 / 不成立时要做什么，点列表里这一行右侧的 ⓘ。"
                                                     : @"改完点「确定」。有取点按钮的可以直接照着屏幕量坐标。")
                                     preferredStyle:UIAlertControllerStyleAlert];

    for (FlowFieldSpec *spec in type.fields) {
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.placeholder = spec.title;
            field.text = [FlowScript textForValue:step[spec.key]];
            field.keyboardType = spec.integer ? UIKeyboardTypeNumbersAndPunctuation : UIKeyboardTypeDefault;
            field.clearButtonMode = UITextFieldViewModeWhileEditing;
            field.font = [UIFont systemFontOfSize:14];
        }];
    }

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    if (type.pickActionTitle.length > 0) {
        [alert addAction:[UIAlertAction actionWithTitle:type.pickActionTitle style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            FlowEditorViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf readFieldsFromAlert:alert type:type intoStep:step];
            [strongSelf presentPickerForType:type step:step index:index];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        FlowEditorViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf readFieldsFromAlert:alert type:type intoStep:step];
        // 识图没有模板就跑不起来，直接把框选接上去，省得用户来回点
        if ([type.kind isEqualToString:kFlowImage] && [strongSelf templateNameOfStep:step].length == 0) {
            [strongSelf presentPickerForType:type step:step index:index];
            return;
        }
        [strongSelf markEdited];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (NSString *)templateNameOfStep:(NSDictionary *)step
{
    return [step[@"Template"] isKindOfClass:[NSString class]] ? step[@"Template"] : @"";
}

- (void)readFieldsFromAlert:(UIAlertController *)alert type:(FlowStepType *)type intoStep:(NSMutableDictionary *)step
{
    NSInteger index = 0;
    for (FlowFieldSpec *spec in type.fields) {
        if (index >= (NSInteger)alert.textFields.count) break;
        step[spec.key] = [FlowScript valueFromText:alert.textFields[index].text integer:spec.integer];
        index += 1;
    }
}

#pragma mark - 从屏幕取

- (void)presentPickerForType:(FlowStepType *)type step:(NSMutableDictionary *)step index:(NSInteger)index
{
    NSString *suggested = [self templateNameOfStep:step];
    __weak typeof(self) weakSelf = self;
    ScreenPickerViewController *picker =
        [[ScreenPickerViewController alloc] initWithMode:type.pickMode
                                       suggestedTemplate:(suggested.length ? suggested : nil)
                                              completion:^(CGRect rect, NSString *hexColor, NSString *templateName) {
            FlowEditorViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf applyPickResult:rect hexColor:hexColor templateName:templateName toStep:step type:type];
            [strongSelf markEdited];
            [strongSelf presentEditorAtIndex:index];      // 取完接着改剩下的字段
        }];
    // 这条路径既可能从弹窗的按钮进来、也可能从取点页的关闭回调进来，排到下一个 runloop 再弹最稳
    dispatch_async(dispatch_get_main_queue(), ^{
        [self presentViewController:picker animated:YES completion:nil];
    });
}

- (void)applyPickResult:(CGRect)rect
               hexColor:(NSString *)hexColor
           templateName:(NSString *)templateName
                 toStep:(NSMutableDictionary *)step
                   type:(FlowStepType *)type
{
    NSArray<NSString *> *keys = type.pickTargets;

    if (type.pickMode == FlowPickModePoint) {
        if (keys.count >= 2) {
            step[keys[0]] = @((NSInteger)llround(rect.origin.x));
            step[keys[1]] = @((NSInteger)llround(rect.origin.y));
        }
    } else if (type.pickMode == FlowPickModeRect) {
        if (keys.count >= 4) {
            // 框选一律按「左上角 / 右下角」写回，滑动就是从左上的点划到右下的点
            step[keys[0]] = @((NSInteger)llround(CGRectGetMinX(rect)));
            step[keys[1]] = @((NSInteger)llround(CGRectGetMinY(rect)));
            step[keys[2]] = @((NSInteger)llround(CGRectGetMaxX(rect)));
            step[keys[3]] = @((NSInteger)llround(CGRectGetMaxY(rect)));
        }
    } else if (type.pickMode == FlowPickModeColor) {
        if (keys.count >= 2) {
            step[keys[0]] = @((NSInteger)llround(rect.origin.x));
            step[keys[1]] = @((NSInteger)llround(rect.origin.y));
        }
        if (hexColor.length) step[@"Color"] = hexColor;
    } else if (type.pickMode == FlowPickModeTemplate) {
        if (templateName.length) step[@"Template"] = templateName;
    }
}

@end
