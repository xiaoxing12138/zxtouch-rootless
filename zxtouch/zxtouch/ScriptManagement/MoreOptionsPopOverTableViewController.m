//
//  MoreOptionsTableViewController.m
//  zxtouch
//
//  Created by Jason on 2021/1/24.
//

#import "MoreOptionsPopOverTableViewController.h"
#import "TableViewCellWithSingleButton.h"
#import "Util.h"
#import "../ZXScriptListView.h"
#include "../Config.h"

@interface MoreOptionsPopOverTableViewController ()
{
    NSString *currentFolder;
    ScriptListViewController* upperLevel;
    
}

@end

@implementation MoreOptionsPopOverTableViewController
@synthesize tableView;

- (UIModalPresentationStyle) adaptivePresentationStyleForPresentationController: (UIPresentationController * ) controller {
    return UIModalPresentationNone;
}


- (void)viewDidLoad {
    [super viewDidLoad];
    
    // Uncomment the following line to preserve selection between presentations.
    // self.clearsSelectionOnViewWillAppear = NO;
    
    // Uncomment the following line to display an Edit button in the navigation bar for this view controller.
    // self.navigationItem.rightBarButtonItem = self.editButtonItem;
    
    UINib *entryCellNib = [UINib nibWithNibName:@"TableViewCellWithSingleButton" bundle:nil];
    [tableView registerNib:entryCellNib forCellReuseIdentifier:@"SingleButtonCell"];
    
    int rows = [self tableView:tableView numberOfRowsInSection:0];
    self.preferredContentSize = CGSizeMake(300, rows*50);
    
    NSLog(@"script folder: %@", currentFolder);
}

- (void)changeName:(id)sender {
    if (!self->currentFolder)
    {
        [Util showAlertBoxWithOneOption:self title:@"错误" message:@"无法创建文件夹：路径未设置。" buttonString:@"确定"];
        return;
    }
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"文件夹名称"
                                                                    message:@"请输入文件夹名称"
                                                             preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *submit = [UIAlertAction actionWithTitle:@"提交" style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction * action) {
                                                       if (alert.textFields.count > 0) {
                                                           UITextField *textField = [alert.textFields firstObject];
                                                           NSString *cleanName = [[textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lastPathComponent];
                                                           if ([cleanName length] != 0)
                                                           {

                                                               BOOL isDir;
                                                               NSError *err = nil;
                                                               NSFileManager *fileManager= [NSFileManager defaultManager];
                                                               NSString* extension = [self->currentFolder pathExtension];
                                                               if (extension.length && [[cleanName pathExtension] isEqualToString:extension]) {
                                                                   cleanName = [cleanName stringByDeletingPathExtension];
                                                               }
                                                               NSString *newName = extension.length ? [cleanName stringByAppendingPathExtension:extension] : cleanName;
                                                               NSString* newFolderPath = [[self->currentFolder stringByDeletingLastPathComponent] stringByAppendingPathComponent:newName];
                                                               if ([newFolderPath isEqualToString:self->currentFolder])
                                                               {
                                                                   [self dismissViewControllerAnimated:YES completion:nil];
                                                                   return;
                                                               }
                                                               if([fileManager fileExistsAtPath:newFolderPath isDirectory:&isDir])
                                                               {
                                                                   [Util showAlertBoxWithOneOption:self title:@"错误" message:@"文件夹已存在，请使用其他文件夹名称。" buttonString:@"确定"];
                                                               }
                                                               else
                                                               {
                                                                   [fileManager moveItemAtPath:self->currentFolder toPath:newFolderPath error:&err];
                                                                   if (err)
                                                                   {
                                                                       [Util showAlertBoxWithOneOption:self title:@"错误" message:[NSString stringWithFormat:@"%@%@", @"无法创建文件夹，原因：", err] buttonString:@"确定"];
                                                                       return;
                                                                   }
                                                                   self->currentFolder = newFolderPath;
                                                                   dispatch_async(dispatch_get_main_queue(), ^{
                                                                       [self->upperLevel refreshTable];
                                                                       [self dismissViewControllerAnimated:YES completion:nil];
                                                                   });
                                                               }
                                                               
                                                           }
                                                           else
                                                           {
                                                               [Util showAlertBoxWithOneOption:self title:@"错误" message:@"请输入文件夹名称。" buttonString:@"确定"];
                                                           }
                                                       }
                                                   }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction * action) {}];

    [alert addAction:cancel];
    [alert addAction:submit];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        NSString *name = [self->currentFolder lastPathComponent];
        NSString *extension = [self->currentFolder pathExtension];
        textField.text = extension.length ? [name stringByDeletingPathExtension] : name;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 可视化脚本

- (void)dismissThen:(void (^)(void))completion
{
    // 关的一定得是「弹层本身」：自己身上可能还挂着一层 alert，
    // 直接对自己 dismiss 只会把 alert 关掉，弹层会赖在屏幕上。
    UIViewController *host = self.presentingViewController;
    if (!host) {
        [self dismissViewControllerAnimated:YES completion:completion];
        return;
    }
    // 等这一轮 runloop 走完再关：上面的 alert 正在收自己的动画，
    // 同一时刻再发起一次模态变更会被 UIKit 丢掉
    dispatch_async(dispatch_get_main_queue(), ^{
        [host dismissViewControllerAnimated:YES completion:completion];
    });
}

- (void)createVisualScript:(id)sender {
    ScriptListViewController *upper = self->upperLevel;

    // 不再让用户起名：直接用「年月日_时分秒」，想改名字事后自己改
    NSDateFormatter *nameFormatter = [[NSDateFormatter alloc] init];
    [nameFormatter setDateFormat:@"yyyyMMdd_HHmmss"];
    NSString *name = [nameFormatter stringFromDate:[NSDate date]];

    NSString *bundlePath = [[currentFolder stringByAppendingPathComponent:name] stringByAppendingPathExtension:@"bdl"];
    // 同一秒里连点两下（基本不会发生）就往后加 -2、-3，保证不重名
    NSInteger seq = 2;
    while ([[NSFileManager defaultManager] fileExistsAtPath:bundlePath]) {
        bundlePath = [[currentFolder stringByAppendingPathComponent:
                       [NSString stringWithFormat:@"%@-%ld", name, (long)seq++]] stringByAppendingPathExtension:@"bdl"];
    }

    // 建包（目录 + flow.plist + main.py）和开卡片都在插件侧做
    [self dismissThen:^{
        NSString *result = [Util sendEngineCommand:[NSString stringWithFormat:@"44;;new;;%@", bundlePath]];
        [upper refreshTable];
        if (!result) {
            [Util showAlertBoxWithOneOption:upper title:@"错误" message:@"小新Lap 服务不可用，请确认插件已生效。" buttonString:@"确定"];
        }
    }];
}

- (id)initWithFolderPath:(NSString *)path
{
    self = [super initWithNibName:@"MoreOptionsPopOverTableViewController" bundle:nil];
    if (self) {
        currentFolder = path;
    }
    return self;
}

- (void)moveFromFolder:(NSString*)source to:(NSString*)dest {
    NSError *error = nil;
    [[NSFileManager defaultManager] moveItemAtPath:source toPath:dest error:&error];
    if (error) {
        [Util showAlertBoxWithOneOption:self title:@"错误" message:[NSString stringWithFormat:@"移动文件时出错。错误：%@",error] buttonString:@"确定"];
    }
}

- (void)setUpperLevelViewController:(ScriptListViewController*)vc{
    upperLevel = vc;
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if ([[currentFolder pathExtension] isEqualToString:@"bdl"])
    {
        return 5;
    }
    else
    {
        return 4;
    }
}

- (void)copyScript:(id)sender {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [currentFolder stringByDeletingLastPathComponent];
    NSString *base = [[currentFolder lastPathComponent] stringByDeletingPathExtension];
    NSString *copy = [[dir stringByAppendingPathComponent:[base stringByAppendingString:@" 副本"]]
                      stringByAppendingPathExtension:@"bdl"];
    NSInteger seq = 2;
    while ([fm fileExistsAtPath:copy]) {
        copy = [[dir stringByAppendingPathComponent:
                 [NSString stringWithFormat:@"%@ 副本%ld", base, (long)seq++]] stringByAppendingPathExtension:@"bdl"];
    }
    NSError *err = nil;
    if (![fm copyItemAtPath:currentFolder toPath:copy error:&err]) {
        [Util showAlertBoxWithOneOption:self title:@"错误"
                                message:[NSString stringWithFormat:@"复制失败:%@", err.localizedDescription]
                           buttonString:@"确定"];
        return;
    }
    ScriptListViewController *upper = upperLevel;
    [self dismissThen:^{
        [upper refreshTable];
    }];
}

- (void)exportScript:(id)sender {
    NSURL *url = [NSURL fileURLWithPath:currentFolder];
    ScriptListViewController *upper = upperLevel;
    [self dismissThen:^{
        UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                                                             applicationActivities:nil];
        activity.popoverPresentationController.sourceView = upper.view;
        activity.popoverPresentationController.sourceRect = CGRectMake(upper.view.bounds.size.width / 2.0f,
                                                                       upper.view.bounds.size.height / 2.0f, 1, 1);
        [upper presentViewController:activity animated:YES completion:nil];
    }];
}

- (void)moveScript:(id)sender {
    NSString *path = [currentFolder copy];
    ScriptListViewController *upper = upperLevel;
    [self dismissThen:^{
        ZXScriptShowMovePicker(path, SCRIPTS_PATH, upper, nil, ^(BOOL moved) {
            if (moved) [upper refreshTable];
        });
    }];
}

- (void)deleteScript:(id)sender {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示"
                                                                   message:@"确定要删除此文件（文件夹）吗？"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        MoreOptionsPopOverTableViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        NSError *err = nil;
        [[NSFileManager defaultManager] removeItemAtPath:strongSelf->currentFolder error:&err];
        if (err) {
            [Util showAlertBoxWithOneOption:strongSelf title:@"错误"
                                    message:[NSString stringWithFormat:@"删除此文件时出错。错误信息：%@", err]
                               buttonString:@"确定"];
            return;
        }
        ScriptListViewController *upper = strongSelf->upperLevel;
        [strongSelf dismissThen:^{
            [upper refreshTable];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"SingleButtonCell";

    TableViewCellWithSingleButton *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    
    //判断队列里面是否有这个cell 没有自己创建，有直接使用
    if (cell == nil) {
        //没有,创建一个
        NSLog(@"create a setting cell switch");
        cell = [[TableViewCellWithSingleButton alloc]initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellID];
    }
    cell.button.titleLabel.font = [UIFont systemFontOfSize:21];
    // cell 是复用的：不清掉上一次挂上去的 target，会出现「点一项触发两个动作」
    [cell.button removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];

    BOOL isBundle = [[currentFolder pathExtension] isEqualToString:@"bdl"];
    if (indexPath.row == 0)
    {
        [cell setButtonText:@"重命名"];
        [cell.button addTarget:self action:@selector(changeName:) forControlEvents:UIControlEventTouchUpInside];
    }
    else if (indexPath.row == 1 && isBundle)
    {
        [cell setButtonText:@"复制"];
        [cell.button addTarget:self action:@selector(copyScript:) forControlEvents:UIControlEventTouchUpInside];
    }
    else if (indexPath.row == 1)
    {
        [cell setButtonText:@"移动"];
        [cell.button addTarget:self action:@selector(moveScript:) forControlEvents:UIControlEventTouchUpInside];
    }
    else if (indexPath.row == 2 && isBundle)
    {
        [cell setButtonText:@"导出"];
        [cell.button addTarget:self action:@selector(exportScript:) forControlEvents:UIControlEventTouchUpInside];
    }
    else if (indexPath.row == 2)
    {
        [cell setButtonText:@"删除"];
        [cell.button addTarget:self action:@selector(deleteScript:) forControlEvents:UIControlEventTouchUpInside];
    }
    else if (indexPath.row == 3 && isBundle)
    {
        [cell setButtonText:@"移动"];
        [cell.button addTarget:self action:@selector(moveScript:) forControlEvents:UIControlEventTouchUpInside];
    }
    else if (indexPath.row == 3)
    {
        [cell setButtonText:@"新建可视化脚本"];
        [cell.button addTarget:self action:@selector(createVisualScript:) forControlEvents:UIControlEventTouchUpInside];
    }
    else if (indexPath.row == 4 && isBundle)
    {
        [cell setButtonText:@"删除"];
        [cell.button addTarget:self action:@selector(deleteScript:) forControlEvents:UIControlEventTouchUpInside];
    }
    
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return 50;
}

/*
// Override to support conditional editing of the table view.
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    // Return NO if you do not want the specified item to be editable.
    return YES;
}
*/

/*
// Override to support editing the table view.
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        // Delete the row from the data source
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
    } else if (editingStyle == UITableViewCellEditingStyleInsert) {
        // Create a new instance of the appropriate class, insert it into the array, and add a new row to the table view
    }   
}
*/

/*
// Override to support rearranging the table view.
- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)fromIndexPath toIndexPath:(NSIndexPath *)toIndexPath {
}
*/

/*
// Override to support conditional rearranging of the table view.
- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    // Return NO if you do not want the item to be re-orderable.
    return YES;
}
*/

/*
#pragma mark - Table view delegate

// In a xib-based application, navigation from a table can be handled in -tableView:didSelectRowAtIndexPath:
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    // Navigation logic may go here, for example:
    // Create the next view controller.
    <#DetailViewController#> *detailViewController = [[<#DetailViewController#> alloc] initWithNibName:<#@"Nib name"#> bundle:nil];
    
    // Pass the selected object to the new view controller.
    
    // Push the view controller.
    [self.navigationController pushViewController:detailViewController animated:YES];
}
*/

/*
#pragma mark - Navigation

// In a storyboard-based application, you will often want to do a little preparation before navigation
- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    // Get the new view controller using [segue destinationViewController].
    // Pass the selected object to the new view controller.
}
*/

@end
