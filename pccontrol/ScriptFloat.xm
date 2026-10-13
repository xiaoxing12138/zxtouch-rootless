#import "ScriptFloat.h"
#import "FloatingMenu.h"
#import "Common.h"
#import "Play.h"
#import "Record.h"
#import "Toast.h"
#import "AlertBox.h"
#import <QuartzCore/QuartzCore.h>
#include <mach/mach_time.h>
#include <pthread.h>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wavailability"
#pragma clang diagnostic ignored "-Wattributes"
#include "headers/IOHIDEvent.h"
#include "headers/IOHIDEventTypes.h"
#pragma clang diagnostic pop

#define kSFCfgBallsKey @"script_float_balls"
#define kSFBallSize    48.0f
#define kSFIconTitle   1
#define kSFIconApp     2

#define kSFStateIdle    0
#define kSFStateRunning 1
#define kSFStatePaused  2

#define kSFInjectSlots 64
#define kSFInjectSlack 1000ULL
#define kSFTouchLogMax 120

static uint64_t sfInjectTimes[kSFInjectSlots];
static int sfInjectCursor = 0;
static pthread_mutex_t sfInjectLock = PTHREAD_MUTEX_INITIALIZER;
static int sfTouchLogCount = 0;

void ZXScriptInjectionNote(uint64_t timeStamp)
{
    if (timeStamp == 0) {
        return;
    }
    pthread_mutex_lock(&sfInjectLock);
    sfInjectTimes[sfInjectCursor] = timeStamp;
    sfInjectCursor = (sfInjectCursor + 1) % kSFInjectSlots;
    pthread_mutex_unlock(&sfInjectLock);
}

static BOOL sfStampIsInjection(uint64_t stamp)
{
    if (stamp == 0) {
        return NO;
    }
    BOOL matched = NO;
    pthread_mutex_lock(&sfInjectLock);
    for (int i = 0; i < kSFInjectSlots; i++) {
        uint64_t t = sfInjectTimes[i];
        if (t == 0) {
            continue;
        }
        uint64_t diff = (t > stamp) ? (t - stamp) : (stamp - t);
        if (diff <= kSFInjectSlack) {
            matched = YES;
            break;
        }
    }
    pthread_mutex_unlock(&sfInjectLock);
    return matched;
}

@interface UIEvent (SFHIDPrivate)
- (IOHIDEventRef)_hidEvent;
@end

static IOHIDEventRef sfHIDEventFromUIEvent(UIEvent *event)
{
    if (!event) {
        return NULL;
    }
    @try {
        if ([event respondsToSelector:@selector(_hidEvent)]) {
            return [event _hidEvent];
        }
    } @catch (NSException *exception) {
        return NULL;
    }
    return NULL;
}

BOOL ZXEventIsScriptInjection(UIEvent *event)
{
    IOHIDEventRef hid = sfHIDEventFromUIEvent(event);
    if (!hid) {
        return NO;
    }
    @try {
        if (IOHIDEventGetIntegerValue(hid, ZX_SCRIPT_INJECT_FIELD) == ZX_SCRIPT_INJECT_VALUE) {
            return YES;
        }
        if (sfStampIsInjection((uint64_t)IOHIDEventGetTimeStamp(hid))) {
            return YES;
        }
    } @catch (NSException *exception) {
        return NO;
    }
    return NO;
}

static void sfRunOnMain(void (^block)(void))
{
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

static void sfToast(NSString *content, int type)
{
    [Toast showToastWithContent:content type:type duration:1.8f position:1 fontSize:14];
}

static NSString *sfAppIconPath(void)
{
    static NSString *cached = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *names = @[@"AppIcon83.5x83.5@2x~ipad.png", @"AppIcon76x76@2x~ipad.png",
                                       @"AppIcon60x60@3x.png", @"AppIcon76x76~ipad.png",
                                       @"AppIcon60x60@2x.png", @"AppIcon40x40@3x.png", @"AppIcon29x29@3x.png"];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSMutableArray<NSString *> *dirs = [NSMutableArray arrayWithObjects:
                                            @"/var/jb/Applications/zxtouch.app",
                                            @"/Applications/zxtouch.app", nil];
        NSString *base = @"/private/var/containers/Bundle/Application";
        NSArray<NSString *> *containers = [fm contentsOfDirectoryAtPath:base error:nil];
        for (NSString *uuid in containers) {
            [dirs addObject:[[base stringByAppendingPathComponent:uuid] stringByAppendingPathComponent:@"zxtouch.app"]];
        }
        for (NSString *dir in dirs) {
            for (NSString *name in names) {
                NSString *path = [dir stringByAppendingPathComponent:name];
                if ([fm fileExistsAtPath:path]) {
                    cached = path;
                    return;
                }
            }
        }
    });
    return cached;
}

static NSString *sfScriptsRootDir(void)
{
    return @"/var/mobile/Library/ZXTouch/scripts";
}

static NSString *sfInoTokenForPath(NSString *path)
{
    if (path.length == 0) {
        return nil;
    }
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSNumber *ino = attrs[NSFileSystemFileNumber];
    NSNumber *dev = attrs[NSFileSystemNumber];
    if (!ino || !dev) {
        return nil;
    }
    return [NSString stringWithFormat:@"%@:%@", dev, ino];
}

static NSString *sfPathForInoToken(NSString *token)
{
    if (token.length == 0) {
        return nil;
    }
    NSArray<NSString *> *parts = [token componentsSeparatedByString:@":"];
    if (parts.count != 2) {
        return nil;
    }
    NSNumber *dev = @([parts[0] longLongValue]);
    NSNumber *ino = @([parts[1] longLongValue]);
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *stack = [NSMutableArray arrayWithObject:sfScriptsRootDir()];
    while (stack.count > 0) {
        NSString *dir = stack.lastObject;
        [stack removeLastObject];
        NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *name in items) {
            NSString *full = [dir stringByAppendingPathComponent:name];
            NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
            if (![attrs[NSFileType] isEqual:NSFileTypeDirectory]) {
                continue;
            }
            if ([[full pathExtension] isEqualToString:@"bdl"]) {
                if ([attrs[NSFileSystemFileNumber] isEqual:ino] && [attrs[NSFileSystemNumber] isEqual:dev]) {
                    return full;
                }
            } else {
                [stack addObject:full];
            }
        }
    }
    return nil;
}

@interface SFPassthroughView : UIView
@end

@implementation SFPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}
@end

@interface SFBallView : UIView
@property (nonatomic, copy) NSString *scriptPath;
@property (nonatomic, assign) BOOL locked;
@property (nonatomic, assign) NSInteger iconMode;
@property (nonatomic, assign) NSInteger playState;
@property (nonatomic, copy) void (^onTap)(SFBallView *ball);
@property (nonatomic, copy) void (^onDragMove)(SFBallView *ball, CGPoint center);
@property (nonatomic, copy) void (^onDragEnd)(SFBallView *ball, CGPoint center);
- (void)applyTitleForScriptPath:(NSString *)path;
@end

@implementation SFBallView {
    UILabel *_sfTitleLabel;
    UIImageView *_sfIconView;
    CGPoint _sfDragStart;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        CGFloat radius = frame.size.width / 2.0f;
        self.backgroundColor = [UIColor colorWithRed:0.08f green:0.08f blue:0.11f alpha:0.86f];
        self.layer.cornerRadius = radius;
        self.layer.borderWidth = 1.0f;
        self.layer.borderColor = [UIColor colorWithWhite:1.0f alpha:0.28f].CGColor;
        _iconMode = kSFIconTitle;
        _playState = kSFStateIdle;

        _sfTitleLabel = [[UILabel alloc] initWithFrame:self.bounds];
        _sfTitleLabel.textAlignment = NSTextAlignmentCenter;
        _sfTitleLabel.textColor = [UIColor whiteColor];
        _sfTitleLabel.font = [UIFont boldSystemFontOfSize:17.0f];
        _sfTitleLabel.adjustsFontSizeToFitWidth = YES;
        _sfTitleLabel.minimumScaleFactor = 0.5f;
        _sfTitleLabel.userInteractionEnabled = NO;
        [self addSubview:_sfTitleLabel];

        _sfIconView = [[UIImageView alloc] initWithFrame:self.bounds];
        _sfIconView.contentMode = UIViewContentModeScaleAspectFill;
        _sfIconView.clipsToBounds = YES;
        _sfIconView.layer.cornerRadius = radius;
        _sfIconView.hidden = YES;
        _sfIconView.userInteractionEnabled = NO;
        [self addSubview:_sfIconView];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        pan.maximumNumberOfTouches = 1;
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
        [tap requireGestureRecognizerToFail:pan];
        [self addGestureRecognizer:pan];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)applyTitleForScriptPath:(NSString *)path
{
    if (self.iconMode == kSFIconApp) {
        NSString *imagePath = sfAppIconPath();
        UIImage *icon = imagePath ? [UIImage imageWithContentsOfFile:imagePath] : nil;
        if (icon) {
            _sfIconView.image = icon;
            _sfIconView.hidden = NO;
            _sfTitleLabel.hidden = YES;
            return;
        }
    }
    _sfIconView.hidden = YES;
    _sfTitleLabel.hidden = NO;
    NSString *name = [[path lastPathComponent] stringByDeletingPathExtension];
    NSUInteger length = MIN((NSUInteger)2, name.length);
    _sfTitleLabel.text = (length > 0) ? [name substringToIndex:length] : @"?";
}

- (void)setPlayState:(NSInteger)playState
{
    _playState = playState;
    [self applyPlayStateAppearance];
}

- (void)applyPlayStateAppearance
{
    if (_playState == kSFStateRunning) {
        self.alpha = 1.0f;
        self.layer.borderColor = [UIColor colorWithRed:0.2f green:0.9f blue:0.35f alpha:0.9f].CGColor;
        [self startSpinner];
    } else {
        self.alpha = (_playState == kSFStatePaused) ? 0.55f : 1.0f;
        self.layer.borderColor = [UIColor colorWithWhite:1.0f alpha:0.28f].CGColor;
        [self stopSpinner];
    }
}

- (void)startSpinner
{
    for (CALayer *sub in self.layer.sublayers) {
        if ([sub.name hasPrefix:@"sfRing_"]) {
            return;
        }
    }
    CGFloat s = self.bounds.size.width + 10.0f;
    CAShapeLayer *ring = [CAShapeLayer layer];
    ring.frame = CGRectMake(-5, -5, s, s);
    ring.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(3, 3, s - 6, s - 6)].CGPath;
    ring.fillColor = [UIColor clearColor].CGColor;
    ring.strokeColor = [UIColor colorWithRed:0.2f green:0.95f blue:0.3f alpha:1.0f].CGColor;
    ring.lineWidth = 3.0f;
    ring.lineCap = kCALineCapRound;
    ring.strokeStart = 0.0f;
    ring.strokeEnd = 0.35f;
    ring.name = @"sfRing_0";
    ring.zPosition = -1;
    [self.layer addSublayer:ring];

    CABasicAnimation *rot = [CABasicAnimation animationWithKeyPath:@"transform.rotation"];
    rot.fromValue = @(0);
    rot.toValue = @(2 * M_PI);
    rot.duration = 1.0f;
    rot.repeatCount = INFINITY;
    rot.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    [ring addAnimation:rot forKey:@"sfSpinning"];
}

- (void)stopSpinner
{
    NSMutableArray *toRemove = [NSMutableArray array];
    for (CALayer *sub in self.layer.sublayers) {
        if ([sub.name hasPrefix:@"sfRing_"]) {
            [toRemove addObject:sub];
        }
    }
    for (CALayer *s in toRemove) {
        [s removeAllAnimations];
        [s removeFromSuperlayer];
    }
}

- (void)handleTap:(UITapGestureRecognizer *)tap
{
    if (tap.state == UIGestureRecognizerStateRecognized && self.onTap) {
        self.onTap(self);
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)pan
{
    if (self.locked) {
        return;
    }
    UIView *root = self.superview;
    CGFloat radius = self.bounds.size.width / 2.0f;
    CGFloat maxX = root.bounds.size.width - radius - 2.0f;
    CGFloat maxY = root.bounds.size.height - radius - 2.0f;

    if (pan.state == UIGestureRecognizerStateBegan) {
        _sfDragStart = self.center;
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [pan translationInView:root];
        CGFloat x = MIN(MAX(_sfDragStart.x + t.x, radius + 2.0f), maxX);
        CGFloat y = MIN(MAX(_sfDragStart.y + t.y, radius + 2.0f), maxY);
        self.center = CGPointMake(x, y);
        if (self.onDragMove) {
            self.onDragMove(self, self.center);
        }
    } else if (pan.state == UIGestureRecognizerStateEnded ||
               pan.state == UIGestureRecognizerStateCancelled ||
               pan.state == UIGestureRecognizerStateFailed) {
        if (self.onDragEnd) {
            self.onDragEnd(self, self.center);
        }
    }
}

@end

@interface ScriptFloat (SFInternal)
+ (instancetype)shared;
- (void)noteTouchAtWindowPoint:(CGPoint)point injected:(BOOL)injected event:(UIEvent *)event;
@end

@interface SFBallWindow : FMPassthroughWindow
@end

@implementation SFBallWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    BOOL injected = ZXEventIsScriptInjection(event);
    if (injected) {
        [[ScriptFloat shared] noteTouchAtWindowPoint:point injected:YES event:event];
        return nil;
    }
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit) {
        [[ScriptFloat shared] noteTouchAtWindowPoint:point injected:NO event:event];
    }
    return hit;
}
@end

static ScriptFloat *_sfShared = nil;

@interface ScriptFloat () {
    SFBallWindow *_window;
    UIView *_content;
    NSMutableDictionary<NSString *, SFBallView *> *_balls;
    NSMutableDictionary<NSString *, NSMutableDictionary *> *_configs;
    NSTimer *_watchTimer;
    BOOL _observing;
}
@end

@implementation ScriptFloat

+ (instancetype)shared
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sfShared = [[ScriptFloat alloc] init];
    });
    return _sfShared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _balls = [NSMutableDictionary dictionary];
        _configs = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - 配置

- (void)loadConfigsFromDisk
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSDictionary *config = [[NSDictionary alloc] initWithContentsOfFile:getCommonConfigFilePath()];
    NSDictionary *stored = [config[kSFCfgBallsKey] isKindOfClass:[NSDictionary class]] ? config[kSFCfgBallsKey] : nil;
    for (id key in stored) {
        if (![key isKindOfClass:[NSString class]]) {
            continue;
        }
        NSDictionary *item = stored[key];
        if (![item isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"enabled"] = @([item[@"enabled"] boolValue]);
        entry[@"locked"] = @([item[@"locked"] boolValue]);
        entry[@"icon"] = ([item[@"icon"] integerValue] == kSFIconApp) ? @(kSFIconApp) : @(kSFIconTitle);
        entry[@"x"] = [item[@"x"] isKindOfClass:[NSNumber class]] ? @([item[@"x"] doubleValue]) : @(0.5);
        entry[@"y"] = [item[@"y"] isKindOfClass:[NSNumber class]] ? @([item[@"y"] doubleValue]) : @(0.5);
        NSString *token = [item[@"ino"] isKindOfClass:[NSString class]] ? item[@"ino"] : nil;
        if (token.length == 0) {
            token = sfInoTokenForPath(key);
        }
        if (token.length > 0) {
            entry[@"ino"] = token;
        }
        result[key] = entry;
    }
    _configs = result;
}

- (void)persistToDisk
{
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    for (NSString *key in _configs) {
        snapshot[key] = [_configs[key] copy];
    }
    NSDictionary *plain = [snapshot copy];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            @try {
                NSString *path = getCommonConfigFilePath();
                NSMutableDictionary *config = [[NSMutableDictionary alloc] initWithContentsOfFile:path];
                if (!config) {
                    config = [NSMutableDictionary dictionary];
                }
                config[kSFCfgBallsKey] = plain;
                [config writeToFile:path atomically:YES];
            } @catch (NSException *exception) {
                ZXLogUIException(exception);
            }
        }
    });
}

- (NSString *)configKeyForPath:(NSString *)path
{
    if (path.length == 0) {
        return nil;
    }
    if (_configs[path]) {
        return path;
    }
    NSString *token = sfInoTokenForPath(path);
    if (token.length == 0) {
        return nil;
    }
    for (NSString *key in _configs) {
        if ([_configs[key][@"ino"] isEqualToString:token]) {
            return key;
        }
    }
    return nil;
}

- (BOOL)resolveRenamedConfigs
{
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL changed = NO;
    for (NSString *key in [_configs allKeys]) {
        NSMutableDictionary *entry = _configs[key];
        if ([fm fileExistsAtPath:key]) {
            continue;
        }
        NSString *token = [entry[@"ino"] isKindOfClass:[NSString class]] ? entry[@"ino"] : nil;
        NSString *found = token.length > 0 ? sfPathForInoToken(token) : nil;
        [_configs removeObjectForKey:key];
        if (found.length > 0 && !_configs[found]) {
            _configs[found] = entry;
        }
        changed = YES;
    }
    if (changed) {
        [self persistToDisk];
    }
    return changed;
}

- (NSDictionary *)ballEntryForPath:(NSString *)path
{
    NSString *key = [self configKeyForPath:path];
    NSDictionary *entry = key ? _configs[key] : nil;
    return entry ? [entry copy] : nil;
}

- (void)setBallEnabled:(BOOL)enabled forPath:(NSString *)path
{
    if (path.length == 0) {
        return;
    }
    NSString *key = [self configKeyForPath:path];
    if (!key) {
        if (!enabled) {
            return;
        }
        key = path;
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"x"] = @(0.5);
        entry[@"y"] = @(MIN(0.15 + 0.12 * (double)_configs.count, 0.85));
        entry[@"locked"] = @NO;
        entry[@"icon"] = @(kSFIconTitle);
        _configs[key] = entry;
    }
    NSString *token = sfInoTokenForPath(path);
    if (token.length > 0) {
        _configs[key][@"ino"] = token;
    }
    _configs[key][@"enabled"] = @(enabled);
    [self persistToDisk];
    [self rebuildBalls];
}

- (void)setBallLocked:(BOOL)locked forPath:(NSString *)path
{
    NSString *key = [self configKeyForPath:path];
    if (!key) {
        return;
    }
    _configs[key][@"locked"] = @(locked);
    [self persistToDisk];
    [self rebuildBalls];
}

- (void)setBallIconMode:(NSInteger)mode forPath:(NSString *)path
{
    NSString *key = [self configKeyForPath:path];
    if (!key) {
        return;
    }
    _configs[key][@"icon"] = (mode == kSFIconApp) ? @(kSFIconApp) : @(kSFIconTitle);
    [self persistToDisk];
    [self rebuildBalls];
}

#pragma mark - 公开 API

+ (void)reloadConfig
{
    sfRunOnMain(^{
        ScriptFloat *m = [self shared];
        [m loadConfigsFromDisk];
        [m rebuildBalls];
    });
}

+ (NSDictionary *)ballConfigForScriptPath:(NSString *)scriptPath
{
    __block NSDictionary *result = nil;
    sfRunOnMain(^{
        result = [[self shared] ballEntryForPath:scriptPath];
    });
    return result;
}

+ (void)setBallEnabled:(BOOL)enabled forScriptPath:(NSString *)scriptPath
{
    sfRunOnMain(^{
        [[self shared] setBallEnabled:enabled forPath:scriptPath];
    });
}

+ (void)setBallLocked:(BOOL)locked forScriptPath:(NSString *)scriptPath
{
    sfRunOnMain(^{
        [[self shared] setBallLocked:locked forPath:scriptPath];
    });
}

+ (void)setBallIconMode:(NSInteger)mode forScriptPath:(NSString *)scriptPath
{
    sfRunOnMain(^{
        [[self shared] setBallIconMode:mode forPath:scriptPath];
    });
}

+ (void)refreshPlayState
{
    sfRunOnMain(^{
        [[self shared] refreshPlayStateNow];
    });
}

#pragma mark - 窗口

- (void)buildWindow
{
    if (_window) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    UIWindowScene *scene = [FloatingMenu preferredWindowScene];
    if (scene) {
        _window = [[SFBallWindow alloc] initWithWindowScene:scene];
    } else {
        _window = [[SFBallWindow alloc] initWithFrame:CGRectZero];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5f * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ScriptFloat *m = weakSelf;
            if (m && m->_balls.count > 0 && !m->_window) {
                [m buildWindow];
            }
        });
    }
    _window.windowLevel = UIWindowLevelStatusBar + 2;

    SFPassthroughView *rootView = [[SFPassthroughView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    rootView.backgroundColor = [UIColor clearColor];
    UIViewController *root = [[UIViewController alloc] init];
    root.view = rootView;
    _window.rootViewController = root;
    _content = rootView;

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [weakSelf applyGeometry];
        } @catch (NSException *exception) {
            ZXLogUIException(exception);
        }
    });
}

- (void)teardown
{
    [self stopWatcher];
    for (SFBallView *ball in _balls.allValues) {
        [ball removeFromSuperview];
    }
    [_balls removeAllObjects];
    if (_window) {
        _window.hidden = YES;
        _window.rootViewController = nil;
        _window = nil;
        _content = nil;
    }
}

- (void)applyGeometry
{
    if (!_window || !_content) {
        return;
    }
    _content.frame = _window.bounds;
    for (NSString *path in _balls) {
        [self layoutBall:_balls[path] config:_configs[path]];
    }
}

- (void)layoutBall:(SFBallView *)ball config:(NSDictionary *)config
{
    CGRect bounds = _content ? _content.bounds : CGRectZero;
    if (bounds.size.width <= 0 || bounds.size.height <= 0) {
        bounds = [UIScreen mainScreen].bounds;
    }
    CGFloat radius = ball.bounds.size.width / 2.0f;
    CGFloat x = [config[@"x"] doubleValue] * bounds.size.width;
    CGFloat y = [config[@"y"] doubleValue] * bounds.size.height;
    x = MIN(MAX(x, radius + 2.0f), bounds.size.width - radius - 2.0f);
    y = MIN(MAX(y, radius + 2.0f), bounds.size.height - radius - 2.0f);
    ball.center = CGPointMake(x, y);
}

#pragma mark - 重建悬浮球

- (void)rebuildBalls
{
    [self resolveRenamedConfigs];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSString *path in _configs) {
        if ([_configs[path][@"enabled"] boolValue]) {
            [paths addObject:path];
        }
    }

    if (paths.count == 0) {
        [self teardown];
        return;
    }

    if (!_window) {
        [self buildWindow];
    }
    if (!_window) {
        return;
    }

    NSMutableArray<NSString *> *stale = [NSMutableArray array];
    for (NSString *path in _balls) {
        if (![paths containsObject:path]) {
            [stale addObject:path];
        }
    }
    for (NSString *path in stale) {
        [_balls[path] removeFromSuperview];
        [_balls removeObjectForKey:path];
    }

    __weak typeof(self) weakSelf = self;
    for (NSString *path in paths) {
        NSDictionary *config = _configs[path];
        SFBallView *ball = _balls[path];
        if (!ball) {
            ball = [[SFBallView alloc] initWithFrame:CGRectMake(0, 0, kSFBallSize, kSFBallSize)];
            ball.scriptPath = path;
            ball.onTap = ^(SFBallView *b) {
                [weakSelf handleBallTap:b.scriptPath];
            };
            ball.onDragMove = ^(SFBallView *b, CGPoint center) {
                [weakSelf handleBallDragMove:b center:center];
            };
            ball.onDragEnd = ^(SFBallView *b, CGPoint center) {
                [weakSelf handleBallDragEnd:b center:center];
            };
            [_content addSubview:ball];
            _balls[path] = ball;
        }
        ball.locked = [config[@"locked"] boolValue];
        ball.iconMode = [config[@"icon"] integerValue];
        [ball applyTitleForScriptPath:path];
        [self layoutBall:ball config:config];
    }

    _window.hidden = NO;
    [self startWatcher];
    [self refreshPlayStateNow];
}

#pragma mark - 点击 / 拖动

- (void)handleBallTap:(NSString *)path
{
    if (path.length == 0) {
        return;
    }
    if (isRecordingStart()) {
        sfToast(@"录制中，无法启停脚本", 2);
        return;
    }
    if (isScriptPlaying()) {
        NSString *current = ZXCurrentScriptBundlePath();
        if (current.length > 0 && [current isEqualToString:path]) {
            NSError *error = nil;
            stopScriptPlaying(&error);
            sfToast(@"已停止", 3);
        } else {
            sfToast(@"已有脚本在运行", 2);
        }
        [self refreshPlayStateNow];
        return;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        sfToast(@"脚本不存在", 2);
        return;
    }
    sfToast(@"启动中…", 3);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            NSError *error = nil;
            playScriptWithSettings((UInt8 *)[path UTF8String], 0, 1.0f, 0.0f, &error);
            if (error) {
                NSString *message = [[error localizedDescription] copy];
                ZXSafeMainAsync(^{
                    @try {
                        showAlertBox(@"错误", message, 999);
                    } @catch (NSException *exception) {
                        ZXLogUIException(exception);
                    }
                });
            }
        }
    });
}

- (void)handleBallDragMove:(SFBallView *)ball center:(CGPoint)center
{
    NSMutableDictionary *config = _configs[ball.scriptPath];
    if (!config || !_content || _content.bounds.size.width <= 0 || _content.bounds.size.height <= 0) {
        return;
    }
    config[@"x"] = @(center.x / _content.bounds.size.width);
    config[@"y"] = @(center.y / _content.bounds.size.height);
}

- (void)handleBallDragEnd:(SFBallView *)ball center:(CGPoint)center
{
    [self handleBallDragMove:ball center:center];
    [self persistToDisk];
}

#pragma mark - 状态刷新

- (void)refreshPlayStateNow
{
    if (_balls.count == 0) {
        return;
    }
    BOOL playing = isScriptPlaying();
    BOOL paused = playing && isScriptPaused();
    NSString *current = playing ? ZXCurrentScriptBundlePath() : nil;
    for (NSString *path in _balls) {
        SFBallView *ball = _balls[path];
        NSInteger state = kSFStateIdle;
        if (playing && current.length > 0 && [current isEqualToString:path]) {
            state = paused ? kSFStatePaused : kSFStateRunning;
        }
        ball.playState = state;
    }
}

#pragma mark - 轮询 / 自愈

- (void)startWatcher
{
    if (_watchTimer) {
        return;
    }
    _watchTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                   target:self
                                                 selector:@selector(handleWatchTick:)
                                                 userInfo:nil
                                                  repeats:YES];
    if (!_observing) {
        _observing = YES;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleOrientationNote:)
                                                     name:UIApplicationDidChangeStatusBarOrientationNotification
                                                   object:nil];
    }
}

- (void)stopWatcher
{
    if (_watchTimer) {
        [_watchTimer invalidate];
        _watchTimer = nil;
    }
    if (_observing) {
        _observing = NO;
        [[NSNotificationCenter defaultCenter] removeObserver:self];
    }
}

- (void)handleWatchTick:(NSTimer *)timer
{
    ZXSafeMainAsync(^{
        @try {
            if (self->_balls.count == 0) {
                return;
            }
            if ([self resolveRenamedConfigs]) {
                [self rebuildBalls];
                return;
            }
            if (!self->_window) {
                [self rebuildBalls];
                return;
            }
            if (self->_window.hidden) {
                self->_window.hidden = NO;
            }
            [self applyGeometry];
            [self refreshPlayStateNow];
        } @catch (NSException *exception) {
            ZXLogUIException(exception);
        }
    });
}

- (void)handleOrientationNote:(NSNotification *)note
{
    ZXSafeMainAsync(^{
        @try {
            [self applyGeometry];
        } @catch (NSException *exception) {
            ZXLogUIException(exception);
        }
    });
}

#pragma mark - 触摸取证

- (void)noteTouchAtWindowPoint:(CGPoint)point injected:(BOOL)injected event:(UIEvent *)event
{
    if (_balls.count == 0 || sfTouchLogCount >= kSFTouchLogMax) {
        return;
    }
    BOOL inside = NO;
    for (SFBallView *ball in _balls.allValues) {
        if (CGRectContainsPoint(ball.frame, point)) {
            inside = YES;
            break;
        }
    }
    if (!inside) {
        return;
    }
    IOHIDEventRef hid = sfHIDEventFromUIEvent(event);
    int field = 0;
    uint64_t sender = 0;
    uint64_t stamp = 0;
    if (hid) {
        @try {
            field = IOHIDEventGetIntegerValue(hid, ZX_SCRIPT_INJECT_FIELD);
            sender = IOHIDEventGetSenderID(hid);
            stamp = IOHIDEventGetTimeStamp(hid);
        } @catch (NSException *exception) {
        }
    }
    sfTouchLogCount++;
    NSLog(@"### com.zjx.springboard: [SF] ball_touch injected=%d field=%d sender=%llu stamp=%llu hid=%d",
          injected ? 1 : 0, field, (unsigned long long)sender, (unsigned long long)stamp, hid ? 1 : 0);
}

@end