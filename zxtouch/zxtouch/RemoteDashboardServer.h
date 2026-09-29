#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL ZXRemoteDashboardSetEnabled(BOOL enabled);
FOUNDATION_EXPORT BOOL ZXRemoteDashboardIsEnabled(void);
FOUNDATION_EXPORT NSString *ZXRemoteDashboardURL(void);
FOUNDATION_EXPORT NSString *ZXRemoteDashboardLastError(void);

NS_ASSUME_NONNULL_END
