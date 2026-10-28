//
//  AdderPopOverViewController.m
//  zxtouch
//
//  Created by Jason on 2021/1/16.
//

#import "AdderPopOverViewController.h"
#import "Util.h"
#import <MobileCoreServices/MobileCoreServices.h>

@interface AdderPopOverViewController ()

@end

@implementation AdderPopOverViewController
{
    NSString *currentFolder;
    ScriptListViewController *upperLevel;
}


- (UIModalPresentationStyle) adaptivePresentationStyleForPresentationController: (UIPresentationController * ) controller {
    return UIModalPresentationNone;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.preferredContentSize = CGSizeMake(300, 100);
}

- (void)setFolder:(NSString*)path {
    currentFolder = [path stringByStandardizingPath];
}

- (void)setUpperLevelViewController:(ScriptListViewController*)vc{
    upperLevel = vc;
}

- (IBAction)createFolderButtonClick:(id)sender {
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
                                                           if ([textField.text length] != 0)
                                                           {

                                                               // create folder
                                                               BOOL isDir;
                                                               NSError *err = nil;
                                                               NSFileManager *fileManager= [NSFileManager defaultManager];
                                                               NSString* folderToAddPath = [self->currentFolder stringByAppendingPathComponent:textField.text];
                                                               if([fileManager fileExistsAtPath:folderToAddPath isDirectory:&isDir] && isDir)
                                                               {
                                                                   [Util showAlertBoxWithOneOption:self title:@"错误" message:@"文件夹已存在，请使用其他文件夹名称。" buttonString:@"确定"];
                                                               }
                                                               else
                                                               {
                                                                   [fileManager createDirectoryAtPath:folderToAddPath withIntermediateDirectories:YES attributes:nil error:&err];
                                                                   if (err)
                                                                   {
                                                                       [Util showAlertBoxWithOneOption:self title:@"错误" message:[NSString stringWithFormat:@"%@%@", @"无法创建文件夹，原因：", err] buttonString:@"确定"];
                                                                   }
                                                                   dispatch_async(dispatch_get_main_queue(), ^{
                                                                       [self->upperLevel refreshTable];
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
        //textField.placeholder = @""; // if needs
    }];

    [self presentViewController:alert animated:YES completion:nil];
}

- (NSString *)availableDestinationPathForFileName:(NSString *)fileName {
    NSString *cleanName = [fileName lastPathComponent];
    if (cleanName.length == 0) {
        cleanName = @"导入的文件";
    }

    NSString *base = [cleanName stringByDeletingPathExtension];
    NSString *extension = [cleanName pathExtension];
    NSString *candidate = [currentFolder stringByAppendingPathComponent:cleanName];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSInteger index = 2;

    while ([fileManager fileExistsAtPath:candidate]) {
        NSString *nextName = extension.length
            ? [NSString stringWithFormat:@"%@（%ld）.%@", base, (long)index, extension]
            : [NSString stringWithFormat:@"%@（%ld）", base, (long)index];
        candidate = [currentFolder stringByAppendingPathComponent:nextName];
        index += 1;
    }

    return candidate;
}

- (void)finishImportWithError:(NSError *)err destination:(NSString *)destinationPath {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (err) {
            [Util showAlertBoxWithOneOption:self title:@"错误" message:[NSString stringWithFormat:@"导入失败：%@", err.localizedDescription] buttonString:@"确定"];
            return;
        }

        [self->upperLevel refreshTable];
        [Util showAlertBoxWithOneOption:self title:@"导入完成" message:[NSString stringWithFormat:@"%@ 已添加。", [destinationPath lastPathComponent]] buttonString:@"确定"];
    });
}

- (IBAction)importFileButtonClick:(id)sender {
    if (!self->currentFolder) {
        [Util showAlertBoxWithOneOption:self title:@"错误" message:@"无法导入文件：路径未设置。" buttonString:@"确定"];
        return;
    }

    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[(NSString *)kUTTypeItem] inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) {
        return;
    }

    BOOL didAccess = [url startAccessingSecurityScopedResource];
    NSString *destinationPath = [self availableDestinationPathForFileName:url.lastPathComponent];
    NSError *err = nil;
    [[NSFileManager defaultManager] copyItemAtURL:url toURL:[NSURL fileURLWithPath:destinationPath] error:&err];
    if (didAccess) {
        [url stopAccessingSecurityScopedResource];
    }

    [self finishImportWithError:err destination:destinationPath];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentAtURL:(NSURL *)url {
    [self documentPicker:controller didPickDocumentsAtURLs:@[url]];
}
@end
