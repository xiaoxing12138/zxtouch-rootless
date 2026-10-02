//
//  Socket.h
//  zxtouch
//
//  Created by Jason on 2020/12/11.
//

#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>

NS_ASSUME_NONNULL_BEGIN

@interface Socket : NSObject


-(int) connect: (NSString*) ip byPort:(int) port;
-(void) send: (NSString*)msg;
-(void) sendChar: (char*)msg;
-(BOOL) isConnected;
-(NSString*) recv:(int)length;
// 逐字节读到 \r\n（含）并返回这一行。截图这类「一行响应头 + 二进制体」的协议必须这样读，
// 一次 recv 大缓冲会把二进制体一起吃进来。读不到返回 nil。
-(NSString*) recvLine;
// 读满 length 字节的二进制体；读不满（超时/断链）返回 nil。
-(NSData*) recvData:(NSInteger)length;
-(void)close;

@end

NS_ASSUME_NONNULL_END
