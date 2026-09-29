//
//  ImageViewerViewController.m
//  zxtouch
//
//  Created by Jason on 2021/2/2.
//

#import "ImageViewerViewController.h"
#import "Util.h"

@interface ImageViewerViewController ()

@end

@implementation ImageViewerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    if (_path)
    {
        UIImage *image = [UIImage imageWithContentsOfFile:_path];
        _imageView.image=image;
    }
    else
    {
        [Util showAlertBoxWithOneOption:self title:@"错误" message:@"发生了一个错误，请稍后重试。" buttonString:@"确定"];
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
