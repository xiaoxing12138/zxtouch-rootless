//
//  Socket.m
//  zxtouch
//
//  Created by Jason on 2020/12/11.
//

#import "Socket.h"


@implementation Socket
{
    int socketHandle;
}

/**
 Connect to a server, return -1 if fail
 */
-(int) connect: (NSString*) ip byPort:(int) port
{
    //NSLog(@"ip: %@, and port: %d", ip, port);、
    int sock = 0;
    struct sockaddr_in serv_addr;

    if ((sock = socket(AF_INET, SOCK_STREAM, 0)) < 0)
    {
        NSLog(@"### com.zjx.zxtouchb:  Socket creation error");
        return -1;
        
    }
    serv_addr.sin_family = AF_INET;
    serv_addr.sin_port = htons(port);

    // Convert IPv4 and IPv6 addresses from text to binary form
    if(inet_pton(AF_INET, [ip UTF8String], &serv_addr.sin_addr)<=0)
    {
        NSLog(@"### com.zjx.zxtouchb: Invalid address. Address not supported");
        return -1;
    }

    if (connect(sock, (struct sockaddr *)&serv_addr, sizeof(serv_addr)) < 0)
    {
        NSLog(@"### com.zjx.zxtouchb: \nConnection Failed \n");
        return -1;
    }
    socketHandle = sock;

    // 兜底：读超时必须设。命令若没带 \r\n，socket server 不会派发，
    // 没有超时的 recv 会永久阻塞主线程，最后被看门狗杀掉（表现为 App 卡死）。
    struct timeval tv;
    tv.tv_sec = 8;
    tv.tv_usec = 0;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    return 0;
}

-(BOOL) isConnected {
    return socketHandle != 0;
}

-(void) send: (NSString*)msg
{
    const char *buffer = [msg UTF8String];
    send(socketHandle , buffer, strlen(buffer) , 0);
}

-(void) sendChar: (char*)msg
{
    send(socketHandle , msg, strlen(msg) , 0);
}

-(NSString*) recv:(int)length
{
    char buffer[length];
    memset(buffer, 0, sizeof(buffer));
    recv(socketHandle, buffer, length, 0);
    return [NSString stringWithUTF8String:buffer];
}

-(void)close {
    if (!socketHandle)
        return;
    close(socketHandle);
    socketHandle = 0;
}

-(void)dealloc {
    [self close];
}

@end
