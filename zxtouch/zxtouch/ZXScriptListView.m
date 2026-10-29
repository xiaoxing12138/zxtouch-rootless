#import "ZXScriptListView.h"
#import <math.h>

#define ZX_ROW_DELETE_W 72.0f

@implementation ZXScriptListItem

+ (instancetype)itemWithPath:(NSString *)path
{
    ZXScriptListItem *item = [[ZXScriptListItem alloc] init];
    item.path = path;
    item.name = path.lastPathComponent;
    item.stepCount = -1;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    BOOL isDir = [attrs[NSFileType] isEqual:NSFileTypeDirectory];
    NSString *ext = path.pathExtension.lowercaseString;

    item.isScript = isDir && [ext isEqualToString:@"bdl"];
    item.isFolder = isDir && !item.isScript;
    item.modifiedDate = attrs[NSFileModificationDate];

    if (item.isScript) {
        NSDictionary *flow = [NSDictionary dictionaryWithContentsOfFile:
                              [path stringByAppendingPathComponent:@"flow.plist"]];
        NSArray *steps = [flow[@"Steps"] isKindOfClass:[NSArray class]] ? flow[@"Steps"] : nil;
        item.stepCount = steps ? (NSInteger)steps.count : -1;
    }

    if (item.isFolder) {
        NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:path error:nil] ?: @[];
        for (NSString *child in children) {
            if ([child hasPrefix:@"."]) continue;
            NSString *full = [path stringByAppendingPathComponent:child];
            NSDictionary *childAttrs = [fm attributesOfItemAtPath:full error:nil];
            BOOL childDir = [childAttrs[NSFileType] isEqual:NSFileTypeDirectory];
            BOOL childBundle = [child.pathExtension.lowercaseString isEqualToString:@"bdl"];
            if (childDir && !childBundle) item.folderCount += 1;
            else item.fileCount += 1;
        }
    }

    return item;
}

@end

static UIColor *ZXStepCountColor(NSInteger count)
{
    if (count <= 0)  return [UIColor systemGrayColor];
    if (count <= 5)  return [UIColor systemGreenColor];
    if (count <= 10) return [UIColor systemOrangeColor];
    if (count <= 15) return [UIColor systemPurpleColor];
    if (count <= 20) return [UIColor systemPinkColor];
    if (count <= 25) return [UIColor systemTealColor];
    if (count <= 30) return [UIColor systemBrownColor];
    return [UIColor systemRedColor];
}

static NSString *ZXDateText(NSDate *date)
{
    if (!date) return @"";
    static NSDateFormatter *thisYear = nil;
    static NSDateFormatter *otherYear = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        thisYear = [[NSDateFormatter alloc] init];
        thisYear.dateFormat = @"MM-dd HH:mm";
        otherYear = [[NSDateFormatter alloc] init];
        otherYear.dateFormat = @"yyyy-MM-dd HH:mm";
    });
    NSInteger year = [[NSCalendar currentCalendar] component:NSCalendarUnitYear fromDate:date];
    NSInteger nowYear = [[NSCalendar currentCalendar] component:NSCalendarUnitYear fromDate:[NSDate date]];
    return [(year != nowYear ? otherYear : thisYear) stringFromDate:date];
}

static NSString *ZXModifiedDateText(NSDate *date)
{
    NSString *text = ZXDateText(date);
    if (text.length == 0) return @"";
    return [NSString stringWithFormat:@"最后修改日期：%@", text];
}

static NSComparator ZXModifiedDescComparator(void)
{
    return ^NSComparisonResult(id a, id b) {
        ZXScriptListItem *ia = a;
        ZXScriptListItem *ib = b;
        NSDate *da = ia.modifiedDate ?: [NSDate distantPast];
        NSDate *db = ib.modifiedDate ?: [NSDate distantPast];
        return [db compare:da];
    };
}

static UIColor *ZXScriptRowBackground(void)
{
    return [UIColor secondarySystemBackgroundColor];
}

@implementation ZXScriptListView
{
    UIView      *_content;
    UIView      *_deletePanel;
    UILabel     *_badge;
    UIImageView *_typeIcon;
    UIImageView *_chevron;
    UIImageView *_folderIcon;
    UILabel     *_nameLabel;
    UILabel     *_trailingLabel;
    BOOL         _open;
    CGFloat      _panStartX;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.cornerRadius = 8;
        self.clipsToBounds = YES;

        _deletePanel = [[UIView alloc] init];
        _deletePanel.backgroundColor = [UIColor systemRedColor];
        _deletePanel.hidden = YES;
        _deletePanel.tag = 9;
        UILabel *deleteLabel = [[UILabel alloc] init];
        deleteLabel.text = @"删除";
        deleteLabel.textColor = [UIColor whiteColor];
        deleteLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        deleteLabel.textAlignment = NSTextAlignmentCenter;
        deleteLabel.tag = 10;
        [_deletePanel addSubview:deleteLabel];
        [_deletePanel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDeleteTap)]];
        [self addSubview:_deletePanel];

        _content = [[UIView alloc] initWithFrame:self.bounds];
        _content.backgroundColor = ZXScriptRowBackground();
        _content.layer.cornerRadius = 8;
        [self addSubview:_content];

        _badge = [[UILabel alloc] init];
        _badge.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightBold];
        _badge.textAlignment = NSTextAlignmentCenter;
        _badge.adjustsFontSizeToFitWidth = YES;
        _badge.minimumScaleFactor = 0.7;
        _badge.layer.cornerRadius = 4;
        _badge.clipsToBounds = YES;
        [_content addSubview:_badge];

        _typeIcon = [[UIImageView alloc] init];
        _typeIcon.contentMode = UIViewContentModeScaleAspectFit;
        [_content addSubview:_typeIcon];

        _chevron = [[UIImageView alloc] init];
        _chevron.contentMode = UIViewContentModeScaleAspectFit;
        _chevron.tintColor = [UIColor secondaryLabelColor];
        [_content addSubview:_chevron];

        _folderIcon = [[UIImageView alloc] init];
        _folderIcon.contentMode = UIViewContentModeScaleAspectFit;
        _folderIcon.tintColor = [UIColor systemBlueColor];
        [_content addSubview:_folderIcon];

        _nameLabel = [[UILabel alloc] init];
        _nameLabel.font = [UIFont systemFontOfSize:13];
        _nameLabel.textColor = [UIColor labelColor];
        _nameLabel.adjustsFontSizeToFitWidth = YES;
        _nameLabel.minimumScaleFactor = 0.8;
        [_content addSubview:_nameLabel];

        _trailingLabel = [[UILabel alloc] init];
        _trailingLabel.font = [UIFont systemFontOfSize:11];
        _trailingLabel.textColor = [UIColor secondaryLabelColor];
        _trailingLabel.textAlignment = NSTextAlignmentRight;
        _trailingLabel.adjustsFontSizeToFitWidth = YES;
        _trailingLabel.minimumScaleFactor = 0.7;
        [_content addSubview:_trailingLabel];

        UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handlePress:)];
        press.minimumPressDuration = 0.45;
        [self addGestureRecognizer:press];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
        [tap requireGestureRecognizerToFail:press];
        [_content addGestureRecognizer:tap];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        pan.delegate = self;
        [self addGestureRecognizer:pan];
    }
    return self;
}

- (void)setShowsDisclosure:(BOOL)showsDisclosure
{
    _showsDisclosure = showsDisclosure;
    [self setNeedsLayout];
}

- (void)setExpanded:(BOOL)expanded
{
    _expanded = expanded;
    [self refreshFolderImages];
    [self setNeedsLayout];
}

- (void)setTrailingInset:(CGFloat)trailingInset
{
    _trailingInset = trailingInset;
    [self setNeedsLayout];
}

- (void)setHighlighted:(BOOL)highlighted
{
    _highlighted = highlighted;
    [self updateHighlight];
}

- (void)updateHighlight
{
    _content.backgroundColor = _highlighted
        ? [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
            if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
                return [UIColor colorWithRed:0.05f green:0.17f blue:0.34f alpha:1.0f];
            }
            return [UIColor colorWithRed:0.82f green:0.91f blue:1.0f alpha:1.0f];
        }]
        : ZXScriptRowBackground();
}

- (void)refreshFolderImages
{
    if (!_item.isFolder) return;
    _chevron.image = [UIImage systemImageNamed:(self.expanded ? @"chevron.down" : @"chevron.right")];
    _folderIcon.image = [UIImage systemImageNamed:(self.expanded ? @"folder.fill" : @"folder")];
}

- (void)applyItem:(ZXScriptListItem *)item
{
    _item = item;
    [self setOpen:NO animated:NO];
    _nameLabel.text = item.name;

    if (item.isFolder) {
        _badge.hidden = YES;
        _typeIcon.hidden = YES;
        _folderIcon.hidden = NO;
        _chevron.hidden = !self.showsDisclosure;
        [self refreshFolderImages];
        if (item.folderCount == 0 && item.fileCount == 0) {
            _trailingLabel.text = @"空文件夹";
        } else {
            _trailingLabel.text = [NSString stringWithFormat:@"%ld文件夹 · %ld文件",
                                   (long)item.folderCount, (long)item.fileCount];
        }
        [self updateHighlight];
        [self setNeedsLayout];
        return;
    }

    _chevron.hidden = YES;
    _folderIcon.hidden = YES;
    _badge.hidden = NO;
    _typeIcon.hidden = NO;
    _trailingLabel.text = ZXModifiedDateText(item.modifiedDate);

    if (item.isScript) {
        NSInteger steps = item.stepCount;
        UIColor *color = (steps >= 0) ? ZXStepCountColor(steps) : [UIColor systemBlueColor];
        _badge.text = (steps >= 0) ? [NSString stringWithFormat:@"%ld步", (long)steps] : @"PY";
        _badge.textColor = color;
        _badge.backgroundColor = [color colorWithAlphaComponent:0.14f];
        _typeIcon.image = [UIImage systemImageNamed:(steps >= 0 ? @"square.grid.2x2.fill" : @"doc.text.fill")];
        _typeIcon.tintColor = (steps >= 0) ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
    } else {
        _badge.hidden = YES;
        NSString *ext = item.path.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"py"]) {
            _typeIcon.image = [UIImage systemImageNamed:@"chevron.left.forwardslash.chevron.right"];
            _typeIcon.tintColor = [UIColor systemBlueColor];
        } else if ([ext isEqualToString:@"raw"]) {
            _typeIcon.image = [UIImage systemImageNamed:@"waveform.path.ecg"];
            _typeIcon.tintColor = [UIColor systemOrangeColor];
        } else if ([ext isEqualToString:@"md"] || [ext isEqualToString:@"markdown"]) {
            _typeIcon.image = [UIImage systemImageNamed:@"doc.richtext"];
            _typeIcon.tintColor = [UIColor systemPurpleColor];
        } else if ([ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"]
                   || [ext isEqualToString:@"jpeg"] || [ext isEqualToString:@"gif"]) {
            _typeIcon.image = [UIImage systemImageNamed:@"photo"];
            _typeIcon.tintColor = [UIColor systemTealColor];
        } else {
            _typeIcon.image = [UIImage systemImageNamed:@"doc"];
            _typeIcon.tintColor = [UIColor secondaryLabelColor];
        }
    }

    [self updateHighlight];
    [self setNeedsLayout];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width - self.trailingInset;
    CGFloat h = self.bounds.size.height;

    _deletePanel.frame = CGRectMake(self.bounds.size.width - ZX_ROW_DELETE_W, 0, ZX_ROW_DELETE_W, h);
    [_deletePanel viewWithTag:10].frame = _deletePanel.bounds;
    if (CGAffineTransformIsIdentity(_content.transform)) _content.frame = self.bounds;

    CGFloat timeW = MIN(150.0f, w * 0.52f);
    CGFloat countW = MIN(122.0f, w * 0.44f);

    if (_item.isFolder) {
        CGFloat x = 6.0f;
        _chevron.frame = CGRectMake(x, (h - 12.0f) / 2.0f, 12, 12);
        if (self.showsDisclosure) x += 18.0f;
        _folderIcon.frame = CGRectMake(x, (h - 16.0f) / 2.0f, 16, 16);
        CGFloat nameX = x + 22.0f;
        _nameLabel.frame = CGRectMake(nameX, 0, MAX(w - nameX - countW - 10.0f, 40.0f), h);
        _trailingLabel.frame = CGRectMake(w - countW - 8.0f, 0, countW, h);
        return;
    }

    if (_item.isScript) {
        _badge.frame = CGRectMake(4, (h - 16.0f) / 2.0f, 34, 16);
        _typeIcon.frame = CGRectMake(40, (h - 16.0f) / 2.0f, 16, 16);
        CGFloat nameX = 60.0f;
        _nameLabel.frame = CGRectMake(nameX, 0, MAX(w - nameX - timeW - 10.0f, 40.0f), h);
        _trailingLabel.frame = CGRectMake(w - timeW - 8.0f, 0, timeW, h);
        return;
    }

    _typeIcon.frame = CGRectMake(6, (h - 16.0f) / 2.0f, 16, 16);
    CGFloat nameX = 28.0f;
    _nameLabel.frame = CGRectMake(nameX, 0, MAX(w - nameX - timeW - 10.0f, 40.0f), h);
    _trailingLabel.frame = CGRectMake(w - timeW - 8.0f, 0, timeW, h);
}

- (void)handleTap
{
    if (_open) { [self setOpen:NO animated:YES]; return; }
    if (self.onTap && _item) self.onTap(_item);
}

- (void)handlePress:(UILongPressGestureRecognizer *)g
{
    if (g.state != UIGestureRecognizerStateBegan) return;
    [self setOpen:NO animated:NO];
    if (self.onLongPress && _item) self.onLongPress(_item);
}

- (void)handleDeleteTap
{
    [self setOpen:NO animated:NO];
    if (self.onDeleteSwipe && _item) self.onDeleteSwipe(_item);
}

- (void)handlePan:(UIPanGestureRecognizer *)g
{
    if (!self.swipeDeleteEnabled) return;
    if (g.state == UIGestureRecognizerStateBegan) _panStartX = _content.transform.tx;
    CGFloat x = _panStartX + [g translationInView:self].x;
    if (x > 0) x = 0;
    if (x < -ZX_ROW_DELETE_W) x = -ZX_ROW_DELETE_W;
    _deletePanel.hidden = (x > -1.0f);
    _content.transform = CGAffineTransformMakeTranslation(x, 0);
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        [self setOpen:(x < -ZX_ROW_DELETE_W / 2.0f) animated:YES];
    }
}

- (void)setOpen:(BOOL)open animated:(BOOL)animated
{
    _open = open;
    _deletePanel.hidden = !open;
    void (^apply)(void) = ^{
        self->_content.transform = CGAffineTransformMakeTranslation(open ? -ZX_ROW_DELETE_W : 0, 0);
    };
    if (animated) [UIView animateWithDuration:0.18 animations:apply];
    else apply();
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g
{
    if ([g isKindOfClass:[UIPanGestureRecognizer class]]) {
        if (!self.swipeDeleteEnabled) return NO;
        CGPoint v = [(UIPanGestureRecognizer *)g velocityInView:self];
        return fabs(v.x) > fabs(v.y);
    }
    return YES;
}

@end

NSArray<ZXScriptListItem *> *ZXScriptListScan(NSString *directory, BOOL includePlainFiles)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:directory error:nil] ?: @[];
    NSMutableArray<ZXScriptListItem *> *folders = [NSMutableArray array];
    NSMutableArray<ZXScriptListItem *> *scripts = [NSMutableArray array];
    NSMutableArray<ZXScriptListItem *> *plain = [NSMutableArray array];

    for (NSString *name in names) {
        if ([name hasPrefix:@"."]) continue;
        NSString *full = [directory stringByAppendingPathComponent:name];
        ZXScriptListItem *item = [ZXScriptListItem itemWithPath:full];
        if (item.isFolder) [folders addObject:item];
        else if (item.isScript) [scripts addObject:item];
        else if (includePlainFiles) [plain addObject:item];
    }

    NSComparator byDateDesc = ZXModifiedDescComparator();
    [folders sortUsingComparator:byDateDesc];
    [scripts sortUsingComparator:byDateDesc];
    [plain sortUsingComparator:byDateDesc];

    NSMutableArray<ZXScriptListItem *> *out = [NSMutableArray array];
    [out addObjectsFromArray:folders];
    [out addObjectsFromArray:scripts];
    [out addObjectsFromArray:plain];
    return out;
}

NSArray<NSString *> *ZXScriptMoveFolders(NSString *scriptsRoot, NSString *excludingPath)
{
    if (scriptsRoot.length == 0) return @[];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *exclude = [excludingPath stringByStandardizingPath];
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithObject:scriptsRoot];
    NSMutableArray<NSString *> *stack = [NSMutableArray arrayWithObject:scriptsRoot];

    while (stack.count > 0) {
        NSString *dir = stack.lastObject;
        [stack removeLastObject];
        NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[];
        for (NSString *name in names) {
            if ([name hasPrefix:@"."]) continue;
            NSString *full = [dir stringByAppendingPathComponent:name];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:full isDirectory:&isDir] || !isDir) continue;
            if ([full.pathExtension.lowercaseString isEqualToString:@"bdl"]) continue;
            if (exclude.length > 0 &&
                ([full isEqualToString:exclude] || [full hasPrefix:[exclude stringByAppendingString:@"/"]])) {
                continue;
            }
            [out addObject:full];
            [stack addObject:full];
        }
    }
    return out;
}

NSString *ZXScriptMoveFolderTitle(NSString *folder, NSString *scriptsRoot)
{
    NSString *root = [scriptsRoot stringByStandardizingPath];
    if ([folder isEqualToString:root]) return @"主脚本目录";
    if ([folder hasPrefix:[root stringByAppendingString:@"/"]]) {
        return [folder substringFromIndex:root.length + 1];
    }
    return folder.lastPathComponent;
}

BOOL ZXScriptMoveItem(NSString *itemPath, NSString *destinationFolder, NSError **error)
{
    NSString *dest = [destinationFolder stringByAppendingPathComponent:itemPath.lastPathComponent];
    if ([dest isEqualToString:itemPath]) return YES;
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:dest]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ZXScriptMove" code:1
                                    userInfo:@{NSLocalizedDescriptionKey: @"目标文件夹里已有同名文件"}];
        }
        return NO;
    }
    return [fm moveItemAtPath:itemPath toPath:dest error:error];
}

static NSMutableArray<UIWindow *> *ZXMovePickerWindows(void)
{
    static NSMutableArray<UIWindow *> *windows = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ windows = [NSMutableArray array]; });
    return windows;
}

void ZXScriptShowMovePicker(NSString *itemPath, NSString *scriptsRoot, UIViewController *host,
                            UIView *sourceView, void (^completion)(BOOL moved))
{
    if (itemPath.length == 0 || scriptsRoot.length == 0) return;

    NSArray<NSString *> *folders = ZXScriptMoveFolders(scriptsRoot, itemPath);
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"移动到"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    UIWindow *tempWindow = nil;
    UIViewController *presenter = host;
    if (!presenter) {
        UIWindowScene *scene = (UIWindowScene *)[[UIApplication sharedApplication].connectedScenes anyObject];
        tempWindow = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                           : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        tempWindow.windowLevel = UIWindowLevelAlert + 3;
        UIViewController *rvc = [[UIViewController alloc] init];
        rvc.view.backgroundColor = [UIColor clearColor];
        tempWindow.rootViewController = rvc;
        [tempWindow makeKeyAndVisible];
        [ZXMovePickerWindows() addObject:tempWindow];
        presenter = rvc;
    }

    void (^closeTempWindow)(void) = ^{
        if (!tempWindow) return;
        UIWindow *win = tempWindow;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            win.hidden = YES;
            [ZXMovePickerWindows() removeObject:win];
        });
    };

    for (NSString *folder in folders) {
        NSString *title = ZXScriptMoveFolderTitle(folder, scriptsRoot);
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *action) {
            NSError *err = nil;
            BOOL ok = ZXScriptMoveItem(itemPath, folder, &err);
            closeTempWindow();
            if (completion) completion(ok);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
                                           handler:^(UIAlertAction *action) {
        closeTempWindow();
    }]];

    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = sourceView ?: presenter.view;
        sheet.popoverPresentationController.sourceRect = sourceView
            ? sourceView.bounds
            : CGRectMake(presenter.view.bounds.size.width / 2.0f, presenter.view.bounds.size.height / 2.0f, 1, 1);
        sheet.popoverPresentationController.permittedArrowDirections = 0;
    }
    [presenter presentViewController:sheet animated:YES completion:nil];
}
