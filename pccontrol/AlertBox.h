#ifndef ALERT_BOX_H
#define ALERT_BOX_H

#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

void showAlertBox(NSString* title, NSString* content, int dismissTime);
void showAlertBoxFromRawData(UInt8 *eventData, NSError **error);
NSString *promptInputFromRawData(UInt8 *eventData, NSError **error);
CFTimeInterval lastAlertBoxRequestTime(void);

#endif
