#ifndef TOUCH_H
#define TOUCH_H

#import <Foundation/Foundation.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wavailability"
#pragma clang diagnostic ignored "-Wattributes"
#include "headers/IOHIDEvent.h"
#include "headers/IOHIDEventData.h"
#include "headers/IOHIDEventTypes.h"
#include "headers/IOHIDEventSystemClient.h"
#include "headers/IOHIDEventSystem.h"
#pragma clang diagnostic pop

#include <mach/mach_time.h>

#define TOUCH_UP 0
#define TOUCH_DOWN 1
#define TOUCH_MOVE 2

const int TOUCH_DATA_LEN = 13;

static int getTouchCountFromDataArray(UInt8* dataArray);
static int getTouchTypeFromDataArray(UInt8* dataArray, int index);
static int getTouchIndexFromDataArray(UInt8* dataArray, int index);
static float getTouchXFromDataArray(UInt8* dataArray, int index);
static float getTouchYFromDataArray(UInt8* dataArray, int index);
/// 返回 YES = 事件真的交给系统了；NO = 没交出去（原因见 ZXTouchLastError）
BOOL performTouchFromRawData(UInt8 *eventData);

BOOL ZXTouchSenderReady(void);
uint64_t ZXTouchSenderID(void);
uint64_t ZXTouchFallbackSenderID(void);
NSInteger ZXTouchPostedCount(void);
NSInteger ZXTouchDroppedCount(void);
NSString *ZXTouchLastError(void);

static IOHIDEventRef generateChildEventTouchDown(int index, float x, float y);
static IOHIDEventRef generateChildEventTouchMove(int index, float x, float y);
static IOHIDEventRef generateChildEventTouchUp(int index, float x, float y);

static BOOL postIOHIDEvent(IOHIDEventRef event);
static void setSenderIdCallback(void* target, void* refcon, IOHIDServiceRef service, IOHIDEventRef event);
void startSetSenderIDCallBack();
void initSenderId();

void initTouchGetScreenSize();

#endif