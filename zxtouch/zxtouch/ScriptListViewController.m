//
//  ScriptListViewController.m
//  zxtouch
//
//  Created by Jason on 2020/12/14.
//

#import "ScriptListViewController.h"
#import "ScriptListTableCell.h"
#import "ScriptEditorViewController.h"
#import "RecordingEditorViewController.h"
#import "LogViewController.h"
#import "ScriptManagement/AdderPopOverViewController.h"
#import "ImageViewerViewController.h"
#include "Config.h"
#import "ScriptManagement/MoreOptionsPopOverTableViewController.h"
#import "Socket.h"
#import "Util.h"

@interface ScriptListViewController ()

@end

@implementation ScriptListViewController
{
    NSMutableArray *scriptList;
    NSString *currentFolder;
    UIRefreshControl *refreshControl;
}


- (void) setFolder:(NSString*)folder {
    currentFolder = [folder stringByStandardizingPath];
}

- (UIModalPresentationStyle) adaptivePresentationStyleForPresentationController: (UIPresentationController * ) controller {
    return UIModalPresentationNone;
}

- (IBAction)logButtonClick:(id)sender {
    

    LogViewController *logEditorViewController = [[LogViewController alloc] initWithNibName: @"LogViewController" bundle: nil];
    
    logEditorViewController.title = @"日志";
    //[logEditorViewController setFile:RUNTIME_OUTPUT_PATH];

    [self presentViewController:logEditorViewController animated:YES completion:nil];
     

}

- (IBAction)addButtonClick:(id)sender {
    AdderPopOverViewController *contentVC = [[AdderPopOverViewController alloc] initWithNibName:@"AdderPopOverViewController" bundle:nil];
    contentVC.modalPresentationStyle = UIModalPresentationPopover;
    [contentVC setFolder:currentFolder];
    [contentVC setUpperLevelViewController:self];
    UIPopoverPresentationController *popPC = contentVC.popoverPresentationController;
    popPC.permittedArrowDirections = UIPopoverArrowDirectionAny;
    popPC.barButtonItem = sender;
    popPC.delegate = contentVC;
    [self presentViewController:contentVC animated:YES completion:nil];
}


- (NSMutableArray*) updateScriptList {
    NSMutableArray *scriptList = [[NSMutableArray alloc] init];

    if (!currentFolder)
        currentFolder = SCRIPTS_PATH;

    [self insertFileListIntoArray:scriptList fromPath:currentFolder];

    // add scripts from documents list
    return scriptList;
}

- (BOOL) insertFileListIntoArray:(NSMutableArray*)arr fromPath:(NSString*) path {
    NSError *err = nil;
    
    NSArray* files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:&err];
    
    if (err)
    {
        NSLog(@"Error happens while getting files list. Error info: %@", err);
        return NO;
    }
    
    
    BOOL isDir = NO;
    for (NSString *fileName in files)
    {
        if ([[fileName substringWithRange:NSMakeRange(0, 1)] isEqualToString:@"."])
        {
            continue;
        }
        NSString *filePath = [NSString stringWithFormat:@"%@/%@", path, fileName];
        if (![[fileName pathExtension] isEqualToString:@"bdl"] && [[NSFileManager defaultManager] fileExistsAtPath:filePath isDirectory:&isDir] && isDir)
        {
            [arr insertObject:filePath atIndex:0];
        }
        else
        {
            [arr addObject:filePath];
        }
    }
    
    return YES;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.title.length ? self.title : @"脚本列表";
    if (@available(iOS 11.0, *)) {
        self.navigationController.navigationBar.prefersLargeTitles = YES;
        self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAutomatic;
    }
    self._scriptListTableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self._scriptListTableView.rowHeight = 56;
    self._scriptListTableView.separatorInset = UIEdgeInsetsMake(0, 70, 0, 16);
    self._scriptListTableView.tableFooterView = [[UIView alloc] init];
    
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"notifyDoubleClickVolumnBtn"])
    {
        
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"提示"
                                                                       message:@"在任意应用中双击音量减按钮即可显示弹出窗。"
                                       preferredStyle:UIAlertControllerStyleAlert];
         
        UIAlertAction* defaultAction = [UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault
           handler:^(UIAlertAction * action) {}];
         
        [alert addAction:defaultAction];
        [self presentViewController:alert animated:YES completion:nil];
        
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"notifyDoubleClickVolumnBtn"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"ZXTouchAlreadyLaunchedv0.0.6"])
    {
        
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"新特性"
                                                                       message:@"1. 新增 zxtouch Python 库支持（详见示例脚本）\n2. 支持底部、左侧、右侧悬浮提示\n3. 新增日志与添加按钮\n4. 界面更新\n5. 所有示例脚本均已更新\n6. 修复若干问题"
                                       preferredStyle:UIAlertControllerStyleAlert];
         
        UIAlertAction* defaultAction = [UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault
           handler:^(UIAlertAction * action) {}];
         
        [alert addAction:defaultAction];
        [self presentViewController:alert animated:YES completion:nil];
        
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"ZXTouchAlreadyLaunchedv0.0.6"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    
    
    scriptList = [self updateScriptList];
    
    refreshControl = [[UIRefreshControl alloc]init];
    [refreshControl addTarget:self action:@selector(refreshTable) forControlEvents:UIControlEventValueChanged];
    self._scriptListTableView.refreshControl = refreshControl;
    [self updateReadmeHeader];
    
    if (![currentFolder isEqualToString:SCRIPTS_PATH])
    {
        self.navigationItem.leftBarButtonItems = nil;
    }
}

- (void)updateReadmeHeader {
    NSString *readmePath = [currentFolder stringByAppendingPathComponent:@"README.md"];
    if (!currentFolder || ![[NSFileManager defaultManager] fileExistsAtPath:readmePath]) {
        self._scriptListTableView.tableHeaderView = nil;
        return;
    }

    NSString *readme = [NSString stringWithContentsOfFile:readmePath encoding:NSUTF8StringEncoding error:nil];
    if (readme.length == 0) {
        self._scriptListTableView.tableHeaderView = nil;
        return;
    }

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self._scriptListTableView.bounds.size.width, 1)];
    header.backgroundColor = UIColor.systemGroupedBackgroundColor;

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"说明";
    title.font = [UIFont boldSystemFontOfSize:15];
    title.textColor = UIColor.secondaryLabelColor;

    UITextView *preview = [[UITextView alloc] init];
    preview.translatesAutoresizingMaskIntoConstraints = NO;
    preview.text = readme;
    preview.editable = NO;
    preview.scrollEnabled = NO;
    preview.font = [UIFont systemFontOfSize:14];
    preview.textColor = UIColor.labelColor;
    preview.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    preview.layer.cornerRadius = 8;
    preview.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);

    [header addSubview:title];
    [header addSubview:preview];

    CGFloat width = self._scriptListTableView.bounds.size.width;
    CGFloat previewWidth = MAX(width - 32, 100);
    CGSize previewSize = [preview sizeThatFits:CGSizeMake(previewWidth, CGFLOAT_MAX)];
    CGFloat previewHeight = MIN(MAX(previewSize.height, 72), 240);
    header.frame = CGRectMake(0, 0, width, previewHeight + 50);

    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [title.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],
        [title.topAnchor constraintEqualToAnchor:header.topAnchor constant:12],
        [preview.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [preview.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],
        [preview.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:6],
        [preview.heightAnchor constraintEqualToConstant:previewHeight]
    ]];

    self._scriptListTableView.tableHeaderView = header;
}


- (IBAction)moreButtonClicked:(id)sender {
    CGPoint buttonPosition = [sender convertPoint:CGPointZero toView:self._scriptListTableView];
    NSIndexPath *indexPath = [self._scriptListTableView indexPathForRowAtPoint:buttonPosition];
    
    MoreOptionsPopOverTableViewController *contentVC = [[MoreOptionsPopOverTableViewController alloc] initWithFolderPath:scriptList[indexPath.row]];
    
    contentVC.modalPresentationStyle = UIModalPresentationPopover;
    [contentVC setUpperLevelViewController:self];
    UIPopoverPresentationController *popPC = contentVC.popoverPresentationController;
    popPC.permittedArrowDirections = UIPopoverArrowDirectionAny;
    //popPC.barButtonItem = sender;
    popPC.sourceView = sender;
    popPC.delegate = contentVC;
    [self presentViewController:contentVC animated:YES completion:nil];
}

- (void)refreshTable {
    scriptList = [self updateScriptList];
    [self updateReadmeHeader];
    [__scriptListTableView reloadData];
    
    [refreshControl endRefreshing];
}


//配置每个section(段）有多少row（行） cell
//默认只有一个section
-(NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{
    return [scriptList count];
}


//每行显示什么东西
-(UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath{
    //给每个cell设置ID号（重复利用时使用）
    static NSString *cellID = @"ScriptCell";

    //从tableView的一个队列里获取一个cell
    ScriptListTableCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];

    //判断队列里面是否有这个cell 没有自己创建，有直接使用
    if (cell == nil) {
        //没有,创建一个
        cell = [[ScriptListTableCell alloc]initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellID];
    }
    cell.parentViewController = self;
    [cell setPropertyWithPath:scriptList[indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath{
    BOOL isDir;
    
    NSString *path = scriptList[indexPath.row];
    [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];
    
    
    if (isDir)
    {
        if ([[path pathExtension].lowercaseString isEqualToString:@"bdl"]) {
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"info.plist"]];
            NSString *entry = [info[@"Entry"] isKindOfClass:[NSString class]] ? info[@"Entry"] : @"";
            if ([entry.pathExtension.lowercaseString isEqualToString:@"raw"]) {
                RecordingEditorViewController *recordingEditor = [[RecordingEditorViewController alloc] initWithScriptBundlePath:path];
                [self.navigationController pushViewController:recordingEditor animated:YES];
                return;
            }
            // 可视化脚本：编辑器是插件侧的悬浮卡片。取点/框选要在游戏画面上画覆盖层，
            // App 进程只能截到自己，所以这里只发命令让引擎自己开卡片。
            if ([[NSFileManager defaultManager] fileExistsAtPath:[path stringByAppendingPathComponent:@"flow.plist"]]) {
                NSString *result = [Util sendEngineCommand:[NSString stringWithFormat:@"44;;open;;%@", path]];
                if (!result || [result characterAtIndex:0] != '0') {
                    [Util showAlertBoxWithOneOption:self title:@"错误"
                                            message:[NSString stringWithFormat:@"打不开可视化编辑器。%@", result.length ? result : @"小新Lap 服务不可用。"]
                                       buttonString:@"确定"];
                }
                return;
            }
        }
        ScriptListViewController *scriptBundleContentViewController = [self.storyboard instantiateViewControllerWithIdentifier:@"scriptBundleContent"];
        
        
        
        [scriptBundleContentViewController setFolder:path];
        scriptBundleContentViewController.title = [path lastPathComponent];

        [self.navigationController pushViewController:scriptBundleContentViewController animated:YES];
        return;
    }
    
    NSArray *possibleImageExtension = @[@"jpg", @"png", @"JPG", @"PNG", @"jpeg", @"JPEG", @"GIF", @"gif"];

    BOOL isImage = false;
    for (NSString* i in possibleImageExtension)
    {
        if ([[path pathExtension] isEqualToString:i])
        {
            isImage = true;
        }
    }
    
    if (isImage)
    {
        ImageViewerViewController *imageViewerController = [self.storyboard instantiateViewControllerWithIdentifier:@"imageViewer"];
        
        imageViewerController.title = [path lastPathComponent];
        imageViewerController.path = path;
        [self.navigationController pushViewController:imageViewerController animated:YES];
    }
    else
    {
        ScriptEditorViewController *scriptEditorViewController = [self.storyboard instantiateViewControllerWithIdentifier:@"fileContentEditor"];
        
        scriptEditorViewController.title = [path lastPathComponent];
        [scriptEditorViewController setFile:path];
        [self.navigationController pushViewController:scriptEditorViewController animated:YES];
    }
}


// Override to support editing the table view.
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        //add code here for when you hit delete
        NSLog(@"delete button clicked for index path: %@", indexPath);
        // delete files in NSFileManager
        
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"提示"
                                       message:@"确定要删除此文件（文件夹）吗？"
                                       preferredStyle:UIAlertControllerStyleAlert];
         
        UIAlertAction* ok = [UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault
           handler:^(UIAlertAction * action) {NSError *err = nil;
            [[NSFileManager defaultManager] removeItemAtPath:self->scriptList[indexPath.row] error:&err];

            if (err)
            {
                NSLog(@"Error while removing file. Error: %@", err);
                UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"错误"
                                               message:[NSString stringWithFormat:@"删除此文件时出错。错误信息：%@", err]
                                               preferredStyle:UIAlertControllerStyleAlert];
                 
                UIAlertAction* defaultAction = [UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault
                   handler:^(UIAlertAction * action) {}];
                 
                [alert addAction:defaultAction];
                [self presentViewController:alert animated:YES completion:nil];
            }
            // delete element in our script list array
            [self->scriptList removeObjectAtIndex:indexPath.row];
            // reload table view
            [self._scriptListTableView reloadData];}];
        UIAlertAction* cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleDefault
           handler:nil];
        
        [alert addAction:cancel];
        [alert addAction:ok];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

/*
#pragma mark - Navigation

// In a storyboard-based application, you will often want to do a little preparation before navigation
- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    // Get the new view controller using [segue destinationViewController].
    // Pass the selected object to the new view controller.
}
*/

@end
