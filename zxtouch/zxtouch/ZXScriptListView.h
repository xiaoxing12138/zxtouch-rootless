#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZXScriptListItem : NSObject

@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) BOOL isFolder;
@property (nonatomic, assign) BOOL isScript;
@property (nonatomic, assign) NSInteger stepCount;
@property (nonatomic, strong, nullable) NSDate *modifiedDate;
@property (nonatomic, assign) NSInteger folderCount;
@property (nonatomic, assign) NSInteger fileCount;

+ (instancetype)itemWithPath:(NSString *)path;

@end

@interface ZXScriptListView : UIView <UIGestureRecognizerDelegate>

@property (nonatomic, strong, nullable) ZXScriptListItem *item;
@property (nonatomic, assign) BOOL highlighted;
@property (nonatomic, assign) BOOL swipeDeleteEnabled;
@property (nonatomic, assign) BOOL showsDisclosure;
@property (nonatomic, assign) BOOL expanded;

@property (nonatomic, copy, nullable) void (^onTap)(ZXScriptListItem *item);
@property (nonatomic, copy, nullable) void (^onLongPress)(ZXScriptListItem *item);
@property (nonatomic, copy, nullable) void (^onDeleteSwipe)(ZXScriptListItem *item);

- (void)applyItem:(ZXScriptListItem *)item;

@end

NSArray<ZXScriptListItem *> *ZXScriptListScan(NSString *directory, BOOL includePlainFiles);
NSArray<NSString *> *ZXScriptMoveFolders(NSString *scriptsRoot, NSString *excludingPath);
NSString *ZXScriptMoveFolderTitle(NSString *folder, NSString *scriptsRoot);
BOOL ZXScriptMoveItem(NSString *itemPath, NSString *destinationFolder, NSError **error);
void ZXScriptShowMovePicker(NSString *itemPath, NSString *scriptsRoot, UIViewController *host,
                            UIView *sourceView, void (^completion)(BOOL moved));

NS_ASSUME_NONNULL_END
