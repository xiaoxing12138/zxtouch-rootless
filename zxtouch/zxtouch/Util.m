//
//  Util.m
//  zxtouch
//
//  Created by Jason on 2021/1/16.
//
#import "Util.h"
#import "Socket.h"

@implementation Util


+ (NSString *)sendEngineCommand:(NSString *)command
{
    Socket *socket = [[Socket alloc] init];
    if ([socket connect:@"127.0.0.1" byPort:6000] != 0) return nil;
    // 必须以 \r\n 结尾：引擎只认这个，漏了不派发，recv 会一直阻塞把 App 卡死
    [socket send:[NSString stringWithFormat:@"%@\r\n", command]];
    NSString *result = [socket recv:1024];
    [socket close];
    return result.length ? result : nil;
}


+ (void)showAlertBoxWithOneOption:(UIViewController*)vc title:(NSString*)aTitle message:(NSString*)aMessage buttonString:(NSString*)aBts
{
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:aTitle
                                                                   message:aMessage
                                   preferredStyle:UIAlertControllerStyleAlert];
     
    UIAlertAction* defaultAction = [UIAlertAction actionWithTitle:aBts style:UIAlertActionStyleDefault
       handler:^(UIAlertAction * action) {}];
     
    [alert addAction:defaultAction];
    [vc presentViewController:alert animated:YES completion:nil];
}




@end
