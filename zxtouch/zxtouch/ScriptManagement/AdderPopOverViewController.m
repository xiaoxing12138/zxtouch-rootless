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
    self.preferredContentSize = CGSizeMake(300, 200);
    // Do any additional setup after loading the view from its nib.
}

- (void)setFolder:(NSString*)path {
    currentFolder = [path stringByStandardizingPath];
}

- (void)setUpperLevelViewController:(ScriptListViewController*)vc{
    upperLevel = vc;
}

- (IBAction)createScriptButtonClick:(id)sender {
    if (!self->currentFolder)
    {
        [Util showAlertBoxWithOneOption:self title:@"错误" message:@"无法创建脚本：路径未设置。" buttonString:@"确定"];
        return;
    }
    
    // 不再让用户起名：直接用「年月日_时分秒」，想改名字事后自己改
    NSDateFormatter *nameFormatter = [[NSDateFormatter alloc] init];
    [nameFormatter setDateFormat:@"yyyyMMdd_HHmmss"];
    NSString *scriptName = [nameFormatter stringFromDate:[NSDate date]];

    BOOL isDir;
    NSError *err = nil;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *folderToAddPath = [self->currentFolder stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.bdl", scriptName]];
    // 同一秒里连点两下（基本不会发生）就往后加 -2、-3，保证不重名
    NSInteger seq = 2;
    while ([fileManager fileExistsAtPath:folderToAddPath isDirectory:&isDir] && isDir)
    {
        folderToAddPath = [self->currentFolder stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"%@-%ld.bdl", scriptName, (long)seq++]];
    }

    [fileManager createDirectoryAtPath:folderToAddPath withIntermediateDirectories:YES attributes:nil error:&err];
    if (err)
    {
        [Util showAlertBoxWithOneOption:self title:@"错误" message:[NSString stringWithFormat:@"%@%@", @"无法创建脚本，原因：", err] buttonString:@"确定"];
        return;
    }

    // add plist file
    NSDictionary *scriptInfo = @{@"Entry": @"main.py", @"FrontApp": @"", @"Orientation": @"1"};
    [scriptInfo writeToFile:[folderToAddPath stringByAppendingPathComponent:@"info.plist"] atomically:YES];

    // add python file
    NSDateFormatter *dateFormatter=[[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    NSString *currentDateTime = [dateFormatter stringFromDate:[NSDate date]];
    NSString *initContent = [NSString stringWithFormat:@"# 本脚本创建于 %@\n# ZXTouch 模块文档（GitHub）：https://github.com/xuan32546/IOS13-SimulateTouch/\n\nfrom zxtouch.client import zxtouch\n\n\n# 请在此处编写你的代码。", currentDateTime];

    [initContent writeToFile:[folderToAddPath stringByAppendingPathComponent:@"main.py"] atomically:YES encoding:NSUTF8StringEncoding error:&err];
    if (err)
    {
        [Util showAlertBoxWithOneOption:self title:@"错误" message:[NSString stringWithFormat:@"%@%@", @"无法创建脚本，原因：", err] buttonString:@"确定"];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self->upperLevel refreshTable];
    });
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
        [Util showAlertBoxWithOneOption:self title:@"错误" message:@"无法创建文件夹：路径未设置。" buttonString:@"确定"];
        return;
    }

    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[(NSString *)kUTTypeItem] inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:picker animated:YES completion:nil];
}

- (IBAction)importImageButtonClick:(id)sender {
    if (!self->currentFolder) {
        [Util showAlertBoxWithOneOption:self title:@"错误" message:@"无法创建文件夹：路径未设置。" buttonString:@"确定"];
        return;
    }

    if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary]) {
        [Util showAlertBoxWithOneOption:self title:@"错误" message:@"照片图库不可用。" buttonString:@"确定"];
        return;
    }

    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.delegate = self;
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes = @[(NSString *)kUTTypeImage];
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

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    UIImage *image = info[UIImagePickerControllerOriginalImage];
    NSURL *imageURL = info[UIImagePickerControllerImageURL];
    NSString *fileName = imageURL.lastPathComponent.length ? imageURL.lastPathComponent : @"导入的图片.png";
    NSString *destinationPath = [self availableDestinationPathForFileName:fileName];

    NSError *err = nil;
    NSData *imageData = nil;
    NSString *extension = [[destinationPath pathExtension] lowercaseString];
    if ([extension isEqualToString:@"jpg"] || [extension isEqualToString:@"jpeg"]) {
        imageData = UIImageJPEGRepresentation(image, 0.92);
    } else {
        if (extension.length == 0) {
            destinationPath = [destinationPath stringByAppendingPathExtension:@"png"];
        }
        imageData = UIImagePNGRepresentation(image);
    }

    if (!imageData) {
        err = [NSError errorWithDomain:@"ZXTouchImport" code:1 userInfo:@{NSLocalizedDescriptionKey: @"无法读取所选图片。"}];
    } else {
        [imageData writeToFile:destinationPath options:NSDataWritingAtomic error:&err];
    }

    [picker dismissViewControllerAnimated:YES completion:^{
        [self finishImportWithError:err destination:destinationPath];
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}
@end
