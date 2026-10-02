//
//  ActivatorEventsTableViewController.m
//  zxtouch
//
//  Created by Jason on 2021/1/29.
//

#import "ActivatorEventsTableViewController.h"
#import "TableViewCellSingleChoice.h"
#import "Util.h"
#import "Config.h"

@interface ActivatorEventsTableViewController ()

@end

@implementation ActivatorEventsTableViewController
{
    NSArray *titleArray;
    NSArray *subtitleArray;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // Uncomment the following line to preserve selection between presentations.
    // self.clearsSelectionOnViewWillAppear = NO;
    
    // Uncomment the following line to display an Edit button in the navigation bar for this view controller.
    // self.navigationItem.rightBarButtonItem = self.editButtonItem;
    self.tableView.backgroundColor = [UIColor groupTableViewBackgroundColor];
    self.tableView.tableFooterView = [[UIView alloc] init];
    
    titleArray = @[@"运行脚本", @"显示/隐藏控制面板", @"终止运行脚本"];
    subtitleArray = @[@"在脚本列表界面配置此项", @"显示或隐藏 小新Lap 后台弹出窗口", @"立刻终止运行所有脚本"];

    UINib *singleChoiceCellNib = [UINib nibWithNibName:@"TableViewCellSingleChoice" bundle:nil];
    [self.tableView registerNib:singleChoiceCellNib forCellReuseIdentifier:@"singleChoiceCell"];
    
}

#pragma mark - Table view data source

-(NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{
    return 3;
}

-(NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

-(UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath{
    static NSString *cellID = @"singleChoiceCell";

    TableViewCellSingleChoice *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    
    //判断队列里面是否有这个cell 没有自己创建，有直接使用
    if (cell == nil) {
        //没有,创建一个
        cell = [[TableViewCellSingleChoice alloc]initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellID];
    }

    [cell.title setText:titleArray[indexPath.row]];
    [cell.subtitle setText:subtitleArray[indexPath.row]];

    
    
    int type = [_config[_eventName][@"type"] intValue];
    if (type == indexPath.row + 1)
    {
        [cell setCheck:YES];
    }
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath{
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    
    TableViewCellSingleChoice* cell = [self.tableView cellForRowAtIndexPath:indexPath];
    
    if (!cell.check)
    {
        // checked
        if (indexPath.row == 0)
        {
            [Util showAlertBoxWithOneOption:self title:@"提示" message:@"当前版本只能在脚本列表中设置 Activator 运行脚本的触发事件，未来版本将支持在此直接配置。"  buttonString:@"确定"];
            cell.check = NO;
            return;
        }
        _config[_eventName] = @{@"type": @(indexPath.row + 1)};
        
        // deselect all others
        NSInteger sections = [self numberOfSectionsInTableView:self.tableView];
        for (int section = 0; section < sections; section++)
        {
            NSInteger rows = [self tableView:self.tableView numberOfRowsInSection:section];
            for (int row = 0; row < rows; row++)
            {
                NSIndexPath* ip = [NSIndexPath indexPathForRow:row inSection:section];
                TableViewCellSingleChoice* temp = [self.tableView cellForRowAtIndexPath:ip];
                temp.check = YES;
            }
        }
        
    }
    else
    {
        // unchecked
        [_config removeObjectForKey:_eventName];
    }
    
    [_config writeToFile:ACTIVATOR_CONFIG_PATH atomically:NO];
}


/*
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:<#@"reuseIdentifier"#> forIndexPath:indexPath];
    
    // Configure the cell...
    
    return cell;
}
*/

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
#pragma mark - Navigation

// In a storyboard-based application, you will often want to do a little preparation before navigation
- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    // Get the new view controller using [segue destinationViewController].
    // Pass the selected object to the new view controller.
}
*/

@end
