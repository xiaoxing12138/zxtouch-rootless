#include "Touch.h"
#include "Common.h"
#include "Screen.h"
#include "AlertBox.h"
#include "Task.h"
#include "ScriptFloat.h"

#define TOUCH_SENDER_ID_PLIST_FILE_NAME @"senderid.plist"

#define MAX_FINGER_INDEX 20

#define NOT_VALID 0
#define VALID 1
#define VALID_AT_NEXT_APPEND 2

#define EVENT_VALID_INDEX 0
#define EVENT_TYPE_INDEX 1
#define EVENT_X_INDEX 2
#define EVENT_Y_INDEX 3

// device screen size
static CGFloat device_screen_width = 0;
static CGFloat device_screen_height = 0;

IOHIDEventSystemClientRef ioHIDEventSystemForSenderID = NULL;

// touch event sender id
unsigned long long int senderID = 0x0;

// 注入统计：真发出去几条、被丢掉几条、最近一次失败原因
static volatile NSInteger zxPostedCount = 0;
static volatile NSInteger zxDroppedCount = 0;
static NSString *zxLastTouchError = @"";

// 服务属性探测用的私有接口（不保证存在，取不到就当没有）
// Touch.xm 按 Objective-C++ 编译，这里必须显式 extern "C"，否则符号被 C++ 改名、链接失败
#ifdef __cplusplus
extern "C" {
#endif
CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
CFTypeRef IOHIDServiceClientCopyProperty(void *service, CFStringRef key);
#ifdef __cplusplus
}
#endif

// valid type x y
static int eventsToAppend[MAX_FINGER_INDEX][4];

BOOL ZXTouchSenderReady(void) { return senderID != 0x0; }
uint64_t ZXTouchSenderID(void) { return senderID; }
NSInteger ZXTouchPostedCount(void) { return zxPostedCount; }
NSInteger ZXTouchDroppedCount(void) { return zxDroppedCount; }
NSString *ZXTouchLastError(void) { return zxLastTouchError ?: @""; }
static void setLastTouchError(NSString *message)
{
    zxLastTouchError = [message copy] ?: @"";
}

/*
从系统 HID 服务的属性里直接问一个 senderID。
手指触摸嗅探拿不到时（比如刚重启、或者嗅探回调没生效）用这条兜底，
拿到的值同样能派发事件；拿不到就返回 0，行为和以前一样（不冒险瞎发）。
*/
static uint64_t senderIDFromServices(void)
{
    uint64_t found = 0;
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!client) return 0;

    CFArrayRef services = NULL;
    @try {
        services = IOHIDEventSystemClientCopyServices(client);
    } @catch (NSException *exception) {
        services = NULL;
    }

    if (services) {
        CFIndex count = CFArrayGetCount(services);
        for (CFIndex i = 0; i < count && found == 0; i++) {
            void *service = (void *)CFArrayGetValueAtIndex(services, i);
            if (!service) continue;

            // 只要触摸屏那一路（Digitizer Page = 0x0D），别的服务给了也不能点
            CFTypeRef page = NULL;
            @try {
                page = IOHIDServiceClientCopyProperty(service, CFSTR("PrimaryUsagePage"));
            } @catch (NSException *exception) {
                page = NULL;
            }
            BOOL isDigitizer = NO;
            if (page) {
                if (CFGetTypeID(page) == CFNumberGetTypeID()) {
                    long long pageValue = -1;
                    if (CFNumberGetValue((CFNumberRef)page, kCFNumberLongLongType, &pageValue)) {
                        isDigitizer = (pageValue == 0x0D);
                    }
                }
                CFRelease(page);
            }
            if (!isDigitizer) continue;

            CFTypeRef value = NULL;
            @try {
                value = IOHIDServiceClientCopyProperty(service, CFSTR("SenderID"));
            } @catch (NSException *exception) {
                value = NULL;
            }
            if (!value) continue;
            if (CFGetTypeID(value) == CFNumberGetTypeID()) {
                long long raw = 0;
                if (CFNumberGetValue((CFNumberRef)value, kCFNumberLongLongType, &raw) && raw != 0) {
                    found = (uint64_t)raw;
                }
            }
            CFRelease(value);
        }
        CFRelease(services);
    }
    CFRelease(client);
    return found;
}

/// 兜底 senderID：只问一次系统，结果缓存。给自检和注入共用，避免两边结论不一致
uint64_t ZXTouchFallbackSenderID(void)
{
    static uint64_t cached = 0;
    static BOOL tried = NO;
    if (!tried) {
        tried = YES;
        cached = senderIDFromServices();
    }
    return cached;
}

/*
get count from data array by socket
*/
static int getTouchCountFromDataArray(UInt8* dataArray)
{
	int count = (dataArray[0] - '0');
	return count;
}

/*
get type from data array by socket
*/
static int getTouchTypeFromDataArray(UInt8* dataArray, int index)
{
	int type = (dataArray[1+index*TOUCH_DATA_LEN] - '0');
	return type;
}

/*
get index from data array by socket
*/
static int getTouchIndexFromDataArray(UInt8* dataArray, int index)
{
	int touchIndex = 0;
	for (int i = 2; i <= 3; i++)
	{
		touchIndex += (dataArray[i+index*TOUCH_DATA_LEN] - '0')*pow(10, 3-i);
	}
	return touchIndex;
}

/*
get x from data array by socket
*/
static float getTouchXFromDataArray(UInt8* dataArray, int index)
{
	int x = 0;
	for (int i = 4; i <= 8; i++)
	{
		x += (dataArray[i+index*TOUCH_DATA_LEN] - '0')*pow(10, 8-i);
	}
	return x/10.0;
}


/*
get y from data array by socket
*/
static float getTouchYFromDataArray(UInt8* dataArray, int index)
{
	int y = 0;
	for (int i = 9; i <= 13; i++)
	{
		y += (dataArray[i+index*TOUCH_DATA_LEN] - '0')*pow(10, 13-i);
	}
	return y/10.0;
}

/*
Get the child event of touching down.
index: index of the finger
x: coordinate x of the screen (before conversion)
y: coordinate y of the screen (before conversion)
*/
static IOHIDEventRef generateChildEventTouchDown(int index, float x, float y)
{
	IOHIDEventRef child = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, mach_absolute_time(), index, 3, 3, x/device_screen_width, y/device_screen_height, 0.0f, 0.0f, 0.0f, 1, 1, 0);
    IOHIDEventSetFloatValue(child, 0xb0014, 0.04f); //set the major index getRandomNumberFloat(0.03, 0.05)
    IOHIDEventSetFloatValue(child, 0xb0015, 0.04f); //set the minor index
	return child;
}

/*
Get the child event of touching move. 
index: index of the finger
x: coordinate x of the screen (before conversion)
y: coordinate y of the screen (before conversion)
*/
static IOHIDEventRef generateChildEventTouchMove(int index, float x, float y)
{
	IOHIDEventRef child = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, mach_absolute_time(), index, 3, 4, x/device_screen_width, y/device_screen_height, 0.0f, 0.0f, 0.0f, 1, 1, 0);
    IOHIDEventSetFloatValue(child, 0xb0014, 0.04f); //set the major index
    IOHIDEventSetFloatValue(child, 0xb0015, 0.04f); //set the minor index
	return child;
}

/*
Get the child event of touching up.
index: index of the finger
x: coordinate x of the screen (before conversion)
y: coordinate y of the screen (before conversion)
*/
static IOHIDEventRef generateChildEventTouchUp(int index, float x, float y)
{
	IOHIDEventRef child = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, mach_absolute_time(), index, 3, 2, x/device_screen_width, y/device_screen_height, 0.0f, 0.0f, 0.0f, 0, 0, 0);
    IOHIDEventSetFloatValue(child, 0xb0014, 0.04f); //set the major index
    IOHIDEventSetFloatValue(child, 0xb0015, 0.04f); //set the minor index
	return child;
}

/**
Append child event to parent
*/
static void appendChildEvent(IOHIDEventRef parent, int type, int index, float x, float y)
{
    switch (type)
    {
        case TOUCH_MOVE:
			IOHIDEventAppendEvent(parent, generateChildEventTouchMove(index, x, y));
            break;
        case TOUCH_DOWN:
            IOHIDEventAppendEvent(parent, generateChildEventTouchDown(index, x, y));
            break;
        case TOUCH_UP:
            IOHIDEventAppendEvent(parent, generateChildEventTouchUp(index, x, y));
            break;
        default:
            NSLog(@"com.zjx.springboard: Unknown touch event type in appendChildEvent, type: %d", type);
    }
}


/**
Perform touch events with data received from socket
*/
BOOL performTouchFromRawData(UInt8 *eventData)
{
    // generate a parent event
	IOHIDEventRef parent = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, mach_absolute_time(), 3, 99, 1, 0, 0, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0, 0, 0); 
    IOHIDEventSetIntegerValue(parent , 0xb0019, 1); //set flags of parent event   flags: 0x20001 -> 0xa0001
    IOHIDEventSetIntegerValue(parent , 0x4, 1); //set flags of parent event   flags: 0xa0001 -> 0xa0011

    // 载荷里的坐标是触摸指示器显示的当前方向像素，要换算成引擎用的竖屏物理像素。
    // 换算只有 Screen.h 里那一份实现，取色 / 找色 / 识图共用同一套。
    for (int i = 0; i < getTouchCountFromDataArray(eventData); i++)
    {
        //NSLog(@"### com.zjx.springboard: get data. index: %d. type: %d. touchIndex: %d. x: %f. y: %f", i, getTouchTypeFromDataArray(eventData, i), getTouchIndexFromDataArray(eventData, i), getTouchXFromDataArray(eventData, i), getTouchYFromDataArray(eventData, i));
        int touchType = getTouchTypeFromDataArray(eventData, i);
        CGPoint framePoint = ZXFramePointFromIndicatorPoint(CGPointMake(getTouchXFromDataArray(eventData, i),
                                                                        getTouchYFromDataArray(eventData, i)));
        int x = (int)lroundf(framePoint.x);
        int y = (int)lroundf(framePoint.y);
        int index = getTouchIndexFromDataArray(eventData, i);

        appendChildEvent(parent, touchType, index, x, y); // append child event to parent

        switch (touchType)
        {
            case TOUCH_MOVE:
                eventsToAppend[index][EVENT_VALID_INDEX] = VALID_AT_NEXT_APPEND;
                eventsToAppend[index][EVENT_TYPE_INDEX] = TOUCH_MOVE;
                eventsToAppend[index][EVENT_X_INDEX] = x;
                eventsToAppend[index][EVENT_Y_INDEX] = y;
                break;
            case TOUCH_DOWN:
                eventsToAppend[index][EVENT_VALID_INDEX] = VALID_AT_NEXT_APPEND;
                eventsToAppend[index][EVENT_TYPE_INDEX] = TOUCH_DOWN;
                eventsToAppend[index][EVENT_X_INDEX] = x;
                eventsToAppend[index][EVENT_Y_INDEX] = y;
                break;
            case TOUCH_UP:
                eventsToAppend[index][EVENT_VALID_INDEX] = NOT_VALID;
                break;
        }

    }

    for (int i = 0; i < MAX_FINGER_INDEX; i++)
    {
        if (eventsToAppend[i][EVENT_VALID_INDEX] == VALID)
        {
            //NSLog(@"com.zjx.springboard: appending event for finger: %d. type: %d. x: %d. y: %d", i, eventsToAppend[i][EVENT_TYPE_INDEX], eventsToAppend[i][EVENT_X_INDEX], eventsToAppend[i][EVENT_Y_INDEX]);
            appendChildEvent(parent, eventsToAppend[i][EVENT_TYPE_INDEX], i, eventsToAppend[i][EVENT_X_INDEX], eventsToAppend[i][EVENT_Y_INDEX]);
        }
        else if (eventsToAppend[i][EVENT_VALID_INDEX] == VALID_AT_NEXT_APPEND) // make it valid
        {
            //NSLog(@"com.zjx.springboard:  finger: %d to become valid. type: %d. x: %d. y: %d", i, eventsToAppend[i][EVENT_TYPE_INDEX], eventsToAppend[i][EVENT_X_INDEX], eventsToAppend[i][EVENT_Y_INDEX]);
            eventsToAppend[i][EVENT_VALID_INDEX] = VALID;
        }
    }

    IOHIDEventSetIntegerValue(parent, 0xb0007, 0x23);
    IOHIDEventSetIntegerValue(parent, 0xb0008, 0x1);
    IOHIDEventSetIntegerValue(parent, 0xb0009, 0x1);
    IOHIDEventSetIntegerValue(parent, ZX_SCRIPT_INJECT_FIELD, ZX_SCRIPT_INJECT_VALUE);

    BOOL posted = postIOHIDEvent(parent);
    if (posted) {
        ZXScriptInjectionNote((uint64_t)IOHIDEventGetTimeStamp(parent));
    }
    CFRelease(parent);

    // 画面马上要变了，作废当前帧缓存，让下一次取色 / 匹配重新抓屏
    [Screen invalidateFrame];
    return posted;
}

/**
Post the parent event
*/
static BOOL postIOHIDEvent(IOHIDEventRef event)
{
    static IOHIDEventSystemClientRef ioSystemClient = NULL;

    if (!ioSystemClient){
        ioSystemClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    }

    uint64_t effectiveID = senderID;
    if (effectiveID == 0) {
        // 懒加载：万一开机时的预热没跑（老版本升级上来、SpringBoard 没走到初始化），这里再补一次
        initSenderId();
        effectiveID = senderID;
    }
    if (effectiveID == 0) {
        // 真实触摸还没抓到过：直接问系统要一个触摸屏服务的 senderID。
        // 只作兜底——真值一旦被嗅探到就立刻盖过去，不会被这个猜的值长期占据。
        effectiveID = ZXTouchFallbackSenderID();
    }

    if (effectiveID == 0) {
        // 这里以前是「静默丢弃」：脚本照常往下跑，屏幕一点反应都没有，自检还显示可用。
        // 现在记下次数和原因，让自检能明确报出来。
        zxDroppedCount += 1;
        setLastTouchError(@"还没拿到系统触摸 ID（先在屏幕上用手指点几下，再重试）");
        NSLog(@"### com.zjx.springboard: sender id still 0 after init, skip event");
        return NO;
    }

    IOHIDEventSetSenderID(event, effectiveID);
    IOHIDEventSystemClientDispatchEvent(ioSystemClient, event);
    zxPostedCount += 1;
    setLastTouchError(@"");
    return YES;
}

/*
Get sender id. If the device has not been rebooted, read senderid from file. Otherwise start set sender id callback
*/
void initSenderId()
{
    if (senderID != 0x0)
    {
        return;
    }

    NSString *plistPath = [NSString stringWithFormat:@"%@/coreutils/touching/%@", getDocumentRoot(), TOUCH_SENDER_ID_PLIST_FILE_NAME];
    if ([[NSFileManager defaultManager] fileExistsAtPath:plistPath])
    {
        // check start time
        NSInteger currentTime = [[NSDate date] timeIntervalSince1970];
        NSInteger timeSinceReboot = [NSProcessInfo processInfo].systemUptime;
        NSInteger thisRebootTime = currentTime - timeSinceReboot;
        NSLog(@"com.zjx.springboard: currentTime: %ld, time since reboot: %ld, last reboot time: %ld", currentTime, timeSinceReboot, thisRebootTime);
        
        NSDictionary *data = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        NSInteger lastRebootTime = [data[@"lastReboot"] longValue];
        unsigned long long cachedSenderID = [data[@"senderID"] longLongValue];
        
        if (abs(lastRebootTime - thisRebootTime) <= 3 && cachedSenderID != 0x0)
        {
            senderID = cachedSenderID;
            NSLog(@"com.zjx.springboard: since the device has not been rebooted. Read sender id from the file. SenderID get: %qX", senderID);
            return;
        }
    }
    
    NSLog(@"com.zjx.springboard: cannot read the sender id from file because the file doesn't exist or the device has restarted. Start set senderid callback.");
    startSetSenderIDCallBack();
}


/*
Get the sender id。回调常驻：senderID 只能靠「抓到一个真实触摸」拿到，
刚开机或嗅探注册晚了都还是 0，注销掉就再也抓不到，所以拿到后也不注销。
*/
static void setSenderIdCallback(void* target, void* refcon, IOHIDServiceRef service, IOHIDEventRef event)
{
    if (IOHIDEventGetType(event) == kIOHIDEventTypeDigitizer){
		if (senderID == 0x0)
        {
            NSError *err = nil;
            [[NSFileManager defaultManager] createDirectoryAtPath:[NSString stringWithFormat:@"%@/coreutils/touching/", getDocumentRoot()] withIntermediateDirectories:YES attributes:nil error:&err];
            if (err)
            {
                NSLog(@"Cannot save senderid for future use, but the tweak should work fine. Error: %@", err);
            }

			senderID = IOHIDEventGetSenderID(event);
            if (senderID == 0x0)
            {
                return;
            }

            NSInteger currentTime = [[NSDate date] timeIntervalSince1970];
            NSInteger timeSinceReboot = [NSProcessInfo processInfo].systemUptime;
            NSInteger rebootTime = currentTime - timeSinceReboot;

            NSDictionary *dict = @{@"lastReboot":@(rebootTime), @"senderID": @(senderID)};

            [dict writeToFile:[NSString stringWithFormat:@"%@/coreutils/touching/%@", getDocumentRoot(), TOUCH_SENDER_ID_PLIST_FILE_NAME] atomically: YES];

            NSLog(@"com.zjx.springboard: sender id is: %qX", senderID);
        }
    }
}

/**
Start the callback for setting sender id
*/
void startSetSenderIDCallBack()
{
    if (ioHIDEventSystemForSenderID != NULL)
    {
        return;
    }
    ioHIDEventSystemForSenderID = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    // 必须注册到主线程 runloop：initSenderId 是懒加载、可能在后台线程调用，
    // 后台线程的 runloop 默认不运行，回调永远收不到真实触摸事件，senderID 一直是 0，
    // 导致所有注入触摸被 postIOHIDEvent 跳过（v3.0.64 懒加载引入的 bug）。
    IOHIDEventSystemClientScheduleWithRunLoop(ioHIDEventSystemForSenderID, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOHIDEventSystemClientRegisterEventCallback(ioHIDEventSystemForSenderID, (IOHIDEventSystemClientEventCallback)setSenderIdCallback, NULL, NULL);
}

/*!!!!!!!!! Here, all the functions here will be moved to a class instance. This function is just for temporary use.*/
void initTouchGetScreenSize()
{
    device_screen_width = [Screen getScreenWidth];
    device_screen_height = [Screen getScreenHeight];
}