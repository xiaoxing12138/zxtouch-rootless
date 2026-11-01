#ifndef SERVER_H
#define SERVER_H

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#endif

#define PORT 6000
#define ADDR "0.0.0.0"

void socketServer();
static void readStream(CFReadStreamRef readStream, CFStreamEventType eventype, void * clientCallBackInfo);
static void TCPServerAcceptCallBack(CFSocketRef socket, CFSocketCallBackType type, CFDataRef address, const void *data, void *info);
int notifyClient(UInt8* msg, CFWriteStreamRef client);
int notifyClientData(const UInt8 *data, CFIndex length, CFWriteStreamRef client);

/// 6000 端口是否已经绑好并在跑（自检用：脚本连不上这里就什么都做不了）
BOOL ZXSocketServerReady(void);

