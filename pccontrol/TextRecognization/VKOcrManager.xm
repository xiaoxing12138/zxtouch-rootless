#import "VKOcrManager.h"
#import "../Screen.h"
#include "../Common.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/select.h>
#import <sys/time.h>
#import <unistd.h>
#import <errno.h>
#import <stdlib.h>

static BOOL sVisionUnavailable = NO;

static CIContext *ZXOcrCIContext(void)
{
    static CIContext *ctx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ctx = [CIContext contextWithOptions:nil];
    });
    return ctx;
}

static NSArray *ZXRunnerRequest(NSDictionary *command, NSString **errorText)
{
    if (errorText) *errorText = nil;

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0)
    {
        if (errorText) *errorText = @"无法创建本地套接字";
        return nil;
    }

    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, "/tmp/zxrunner.sock", sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0)
    {
        close(fd);
        if (errorText) *errorText = @"无法连接 zxrunner 守护进程，请重启设备后重试";
        return nil;
    }

    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:command options:0 error:NULL];
    if (!jsonData)
    {
        close(fd);
        if (errorText) *errorText = @"无法编码文字识别请求";
        return nil;
    }

    NSMutableData *payload = [NSMutableData dataWithData:jsonData];
    [payload appendBytes:"\r\n" length:2];
    const uint8_t *wp = payload.bytes;
    size_t wleft = payload.length;
    while (wleft > 0)
    {
        ssize_t n = write(fd, wp, wleft);
        if (n <= 0)
        {
            if (errno == EINTR) continue;
            close(fd);
            if (errorText) *errorText = @"向守护进程写入命令失败";
            return nil;
        }
        wp += n;
        wleft -= (size_t)n;
    }

    NSMutableArray *responses = [NSMutableArray array];
    NSMutableData *pending = [NSMutableData data];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30.0];
    BOOL finished = NO;

    char buf[4096];
    while (!finished)
    {
        if ([deadline timeIntervalSinceNow] < 0)
        {
            if (errorText) *errorText = @"文字识别执行超时";
            break;
        }

        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        struct timeval tv = { 0, 100 * 1000 };
        int ret = select(fd + 1, &rfds, NULL, NULL, &tv);
        if (ret < 0 && errno == EINTR) continue;
        if (ret <= 0) continue;

        ssize_t nr = read(fd, buf, sizeof(buf));
        if (nr <= 0) break;
        [pending appendBytes:buf length:(NSUInteger)nr];

        while (!finished)
        {
            const uint8_t *bytes = pending.bytes;
            NSUInteger len = pending.length;
            NSUInteger cut = 0;
            BOOL found = NO;

            for (NSUInteger i = 0; i < len; i++)
            {
                if (bytes[i] != '\n') continue;
                NSUInteger lineLen = i;
                if (lineLen > 0 && bytes[lineLen - 1] == '\r') lineLen--;
                cut = i + 1;
                found = YES;
                if (lineLen > 0)
                {
                    NSData *lineData = [NSData dataWithBytes:bytes length:lineLen];
                    NSDictionary *resp = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:NULL];
                    if ([resp isKindOfClass:[NSDictionary class]])
                    {
                        [responses addObject:resp];
                        NSString *type = resp[@"type"];
                        if ([type isEqualToString:@"done"] || [type isEqualToString:@"exit"])
                        {
                            finished = YES;
                        }
                        else if ([type isEqualToString:@"error"])
                        {
                            if (errorText) *errorText = resp[@"msg"] ?: @"守护进程返回错误";
                            finished = YES;
                        }
                    }
                }
                break;
            }

            if (found) [pending replaceBytesInRange:NSMakeRange(0, cut) withBytes:NULL length:0];
            else break;
        }
    }

    close(fd);

    if (errorText && (*errorText).length > 0) return nil;
    if (!finished && errorText) *errorText = @"守护进程连接中断";
    if (errorText && (*errorText).length > 0) return nil;
    return responses;
}

static void ZXOcrDebugLog(NSString *text)
{
    NSString *folder = @"/var/mobile/Library/ZXTouch";
    NSString *path = [folder stringByAppendingPathComponent:@"ocr.log"];
    [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path])
    {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    [handle seekToEndOfFile];
    [handle writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}


@interface VKOcrManager ()
- (NSString *)recognizeWithVision:(NSError **)error;
- (NSString *)recognizeWithTesseract:(NSError **)error;
- (NSString *)tesseractLanguages;
@end


@implementation VKOcrManager
{
    BOOL inProgress;

    VNRequest* requestResult;
    NSError* errorResult;

    VNImageRequestHandler* requestHandler;
    VNRecognizeTextRequest* request;

    CIImage *img;
    CIImage *sourceImage;
    CGRect recognizeRect;
    CGRect sourceRect;
    NSArray *requestedLanguages;
    CGFloat imageScale;
}


- (id)initWithCIImage:(CIImage*)image area:(CGRect)aarea orientation:(int)orientation {
    self = [super init];
    if (self)
    {
        int after = kCGImagePropertyOrientationUp;
        if (orientation == 4)
        {
            after = kCGImagePropertyOrientationRight;
        }
        else if (orientation == 3)
        {
            after = kCGImagePropertyOrientationLeft;
        }
        else if (orientation == 2)
        {
            after = kCGImagePropertyOrientationDown;
        }

        image = [image imageByApplyingOrientation:after];

        sourceImage = image;

        CGRect rawArea = aarea;
        CGFloat sourceWidth = sourceImage.extent.size.width;
        CGFloat sourceHeight = sourceImage.extent.size.height;
        if (rawArea.origin.x == 0 && rawArea.origin.y == 0 &&
            rawArea.size.width == 0 && rawArea.size.height == 0)
        {
            rawArea = CGRectMake(0, 0, sourceWidth, sourceHeight);
        }
        if (rawArea.origin.x + rawArea.size.width > sourceWidth)
        {
            rawArea.size.width = sourceWidth - rawArea.origin.x;
        }
        if (rawArea.origin.y + rawArea.size.height > sourceHeight)
        {
            rawArea.size.height = sourceHeight - rawArea.origin.y;
        }
        sourceRect = rawArea;

        CGFloat scale = 1.0;
        CGFloat longSide = MAX(image.extent.size.width, image.extent.size.height);
        if (longSide > 1600.0)
        {
            scale = 1600.0 / longSide;
            image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
        }
        imageScale = scale;
        if (scale != 1.0)
        {
            aarea = CGRectMake(aarea.origin.x * scale, aarea.origin.y * scale,
                               aarea.size.width * scale, aarea.size.height * scale);
        }

        img = image;

        CGFloat imageWidth = image.extent.size.width;
        CGFloat imageHeight = image.extent.size.height;



        // check whether width/height is too large
        if (aarea.size.width + aarea.origin.x > imageWidth)
        {
            aarea.size.width = imageWidth - aarea.origin.x;
        }
        if (aarea.size.height + aarea.origin.y > imageHeight)
        {
            aarea.size.height = imageHeight - aarea.origin.y;
        }
        if (aarea.size.width == 0)
        {
            aarea.size.width = imageWidth - aarea.origin.x;
        }
        if (aarea.size.height == 0)
        {
            aarea.size.height = imageHeight - aarea.origin.y;
        }

        recognizeRect = aarea;

        if (aarea.origin.x != 0 || aarea.origin.y != 0 || aarea.size.width != 0 || aarea.size.height != 0)
        {
            CGFloat y = imageHeight - aarea.origin.y - aarea.size.height;
            requestHandler = [[VNImageRequestHandler alloc] initWithCIImage:[image imageByCroppingToRect:CGRectMake(aarea.origin.x, y, aarea.size.width, aarea.size.height)] options:nil];
        }
        else
        {
            requestHandler = [[VNImageRequestHandler alloc] initWithCIImage:image options:nil];
        }

        request = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *request, NSError *error){
            requestResult = request;
            errorResult = error;
        }];

        // may cause crash
        if (SYSTEM_VERSION_LESS_THAN(@"14.0"))
        {
            request.revision = 1;
        }
        else if (SYSTEM_VERSION_LESS_THAN(@"16.0"))
        {
            request.revision = 2;
        }
        else
        {
            request.revision = 3;
        }
    }
    return self;
}

- (id)initWithImagePath:(NSString*)path area:(CGRect)aarea orientation:(int)orientation {
    NSURL *fileURL = [NSURL fileURLWithPath:path];
    CIImage *image = [CIImage imageWithContentsOfURL:fileURL];
    return [self initWithCIImage:image area:aarea orientation:orientation];
}

- (id)initWithCGImage:(CGImageRef)cgimage area:(CGRect)aarea orientation:(int)orientation {
    CIImage *image = [[CIImage alloc] initWithCGImage:cgimage];
    return [self initWithCIImage:image area:aarea orientation:orientation];
}

/*
Return the string from a area
*/
- (NSString*)recognize:(NSError**)error{
    if (inProgress)
    {
        NSLog(@"com.zjx.springboard: cannot start recognize text from this instance: %@ because another task is running.", self);
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"-1;;无法从此实例启动文字识别：%@，因为已有另一个识别任务正在运行。\r\n", self]}];
        return nil;
    }
    inProgress = true;

    NSString *text = nil;
    if (!sVisionUnavailable)
    {
        NSError *visionError = nil;
        text = [self recognizeWithVision:&visionError];
        if (text == nil)
        {
            if (visionError) sVisionUnavailable = YES;
            NSLog(@"com.zjx.springboard: system ocr unavailable, falling back to tesseract. %@", visionError);
            ZXOcrDebugLog([NSString stringWithFormat:@"vision unavailable: %@\n", visionError]);
        }
    }

    if (text == nil)
    {
        text = [self recognizeWithTesseract:error];
    }

    inProgress = false;
    return text;
}

- (NSString*)recognizeWithVision:(NSError**)error{
    NSError *err = nil;
    NSMutableArray<NSNumber *> *revisions = [NSMutableArray array];
    for (NSNumber *rev in @[@(request.revision), @2, @1])
    {
        if (![revisions containsObject:rev]) [revisions addObject:rev];
    }

    for (NSNumber *rev in revisions)
    {
        request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        @try
        {
            request.revision = (NSUInteger)[rev integerValue];
        }
        @catch (NSException *e)
        {
            continue;
        }
        if (requestedLanguages.count)
        {
            if ([request respondsToSelector:NSSelectorFromString(@"setAutomaticallyDetectsLanguage:")])
            {
                [request setValue:@NO forKey:@"automaticallyDetectsLanguage"];
            }
            request.recognitionLanguages = requestedLanguages;
        }
        NSLog(@"com.zjx.springboard: ocr rev=%d level=%d langs=%@", (int)request.revision, (int)request.recognitionLevel, request.recognitionLanguages);
        id autoValue = [request respondsToSelector:NSSelectorFromString(@"automaticallyDetectsLanguage")]
                           ? [request valueForKey:@"automaticallyDetectsLanguage"] : @"n/a";
        ZXOcrDebugLog([NSString stringWithFormat:@"before rev=%d level=%d minH=%.4f auto=%@ langs=%@\n",
                       (int)request.revision, (int)request.recognitionLevel, request.minimumTextHeight,
                       autoValue, request.recognitionLanguages]);

        requestResult = nil;
        err = nil;
        [requestHandler performRequests:@[request] error:&err];
        ZXOcrDebugLog([NSString stringWithFormat:@"after err=%@ rev=%d langs=%@ count=%d\n",
                       err, (int)request.revision, request.recognitionLanguages,
                       (int)requestResult.results.count]);

        if (!err) break;
        NSLog(@"com.zjx.springboard: accurate ocr revision %d failed. %@", (int)[rev integerValue], err);
    }

    if (err)
    {
        NSLog(@"com.zjx.springboard: accurate ocr failed on every revision, skip fast level. %@", err);
        ZXOcrDebugLog([NSString stringWithFormat:@"accurate failed all revisions: %@\n", err]);
    }

    if (err)
    {
        NSLog(@"com.zjx.springboard: error happened while performing ocr. %@", err);
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"-1;;执行文字识别（OCR）时出错，错误信息：%@\r\n", err]}];
        return nil;
    }
    
    NSMutableArray<NSString*>* stringList = [[NSMutableArray alloc] init];

    for (VNRecognizedTextObservation* i in requestResult.results)
    {
        VNRecognizedText* text = [i topCandidates:1][0];
        NSString* textString = [text string];

        VNRectangleObservation* boundingBox = [text boundingBoxForRange:NSMakeRange(0, [textString length]) error:nil];

        float invScale = (imageScale > 0) ? (1.0f / imageScale) : 1.0f;
        float rectWidth = (boundingBox.topRight.x - boundingBox.topLeft.x) * recognizeRect.size.width * invScale;
        float rectHeight = abs(boundingBox.topLeft.y - boundingBox.bottomLeft.y) * recognizeRect.size.height * invScale;
        float rectx = (boundingBox.topLeft.x * recognizeRect.size.width + recognizeRect.origin.x) * invScale;
        float recty = ((1 - boundingBox.topLeft.y) * recognizeRect.size.height + recognizeRect.origin.y) * invScale;

        NSString* outputString = [NSString stringWithFormat:@"%@,,%d,,%d,,%d,,%d", textString, (int)rectx, (int)recty, (int)rectWidth, (int)rectHeight];

        [stringList addObject:outputString];
    }

    return [stringList componentsJoinedByString:@";;"];
}

- (NSString *)tesseractLanguages
{
    if (requestedLanguages.count == 0) return @"chi_sim+eng";

    NSMutableArray *mapped = [NSMutableArray array];
    for (NSString *language in requestedLanguages)
    {
        NSString *lower = language.lowercaseString;
        NSString *code = nil;
        if ([lower hasPrefix:@"zh"]) code = @"chi_sim";
        else if ([lower hasPrefix:@"en"]) code = @"eng";
        else if ([lower hasPrefix:@"ja"]) code = @"jpn";
        else if ([lower hasPrefix:@"ko"]) code = @"kor";
        else if ([lower hasPrefix:@"ru"]) code = @"rus";
        else if ([lower hasPrefix:@"fr"]) code = @"fra";
        else if ([lower hasPrefix:@"de"]) code = @"deu";
        else if ([lower hasPrefix:@"es"]) code = @"spa";
        else if ([lower hasPrefix:@"it"]) code = @"ita";
        else if ([lower hasPrefix:@"pt"]) code = @"por";
        if (code && ![mapped containsObject:code]) [mapped addObject:code];
    }
    if (mapped.count == 0) [mapped addObject:@"chi_sim"];
    if (![mapped containsObject:@"eng"]) [mapped addObject:@"eng"];
    return [mapped componentsJoinedByString:@"+"];
}

- (NSString *)recognizeWithTesseract:(NSError **)error
{
    if (!sourceImage)
    {
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;文字识别（OCR）失败：无法获取屏幕图像。\r\n"}];
        return nil;
    }

    NSString *folder = @"/var/mobile/Library/ZXTouch/cache";
    [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];

    NSString *tag = [NSString stringWithFormat:@"ocr_%d_%u", (int)getpid(), arc4random()];
    NSString *imagePath = [folder stringByAppendingPathComponent:[tag stringByAppendingString:@".jpg"]];

    CGRect area = sourceRect;
    CGFloat upscale = (area.size.height > 0 && area.size.height <= 50.0) ? 2.0 : 1.0;

    CGFloat sourceHeight = sourceImage.extent.size.height;
    CGRect cropRect = CGRectMake(area.origin.x, sourceHeight - area.origin.y - area.size.height,
                                 area.size.width, area.size.height);
    if (cropRect.size.width <= 0 || cropRect.size.height <= 0)
    {
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;文字识别（OCR）失败：识别区域为空。\r\n"}];
        return nil;
    }

    CIImage *cropped = [sourceImage imageByCroppingToRect:cropRect];
    if (upscale != 1.0)
    {
        cropped = [cropped imageByApplyingTransform:CGAffineTransformMakeScale(upscale, upscale)];
    }
    CGImageRef cgImage = [ZXOcrCIContext() createCGImage:cropped fromRect:cropped.extent];
    if (!cgImage)
    {
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;文字识别（OCR）失败：无法生成识别用图片。\r\n"}];
        return nil;
    }
    NSData *jpeg = UIImageJPEGRepresentation([[UIImage alloc] initWithCGImage:cgImage], 0.92);
    CGImageRelease(cgImage);
    if (!jpeg || ![jpeg writeToFile:imagePath atomically:YES])
    {
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;文字识别（OCR）失败：无法写入临时图片。\r\n"}];
        return nil;
    }

    NSString *execError = nil;
    NSArray *responses = ZXRunnerRequest(@{
        @"cmd": @"ocr_tess",
        @"path": imagePath,
        @"langs": [self tesseractLanguages],
        @"psm": @6
    }, &execError);

    [[NSFileManager defaultManager] removeItemAtPath:imagePath error:NULL];

    if (!responses)
    {
        NSString *reason = execError.length ? execError : @"未获得识别结果";
        ZXOcrDebugLog([NSString stringWithFormat:@"tesseract failed reason=%@\n", reason]);
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"-1;;文字识别（OCR）失败：%@\r\n", reason]}];
        return nil;
    }

    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *resp in responses)
    {
        if (![resp[@"type"] isEqualToString:@"lines"]) continue;
        NSArray *lines = resp[@"data"];
        if (![lines isKindOfClass:[NSArray class]]) continue;
        for (id item in lines)
        {
            if (![item isKindOfClass:[NSString class]] || [item length] == 0) continue;
            [result addObject:[NSString stringWithFormat:@"%@,,0,,0,,0,,0", item]];
        }
    }

    return [result componentsJoinedByString:@";;"];
}

/*
Return area that contain text
*/
- (NSArray*)areasOfText {

}

- (void)outputDebugImage:(NSString*)imagePath error:(NSError**)error{
    inProgress = true;

    NSError* err = nil;
    UIImage* test = [self drawDebugOutputfromArray:requestResult.results error:&err];

    if (err)
    {
        NSLog(@"com.zjx.springboard: error while outputing debug image.");
        return;
    }

    [[NSFileManager defaultManager] createDirectoryAtPath:[imagePath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];

    [UIImageJPEGRepresentation(test, 0.7) writeToFile:imagePath atomically:true];
    inProgress = false;

    //[test writeJPEGRepresentationOfImage];
}

- (void)drawRectangle:(CGRect)rect inContext:(CGContextRef)ctx withColor:(UIColor*)color {
    CGFloat width = rect.size.width;
    CGFloat height = rect.size.height;
    CGFloat x = rect.origin.x;
    CGFloat y = rect.origin.y;

    CGPoint topLeft = rect.origin;
    CGPoint topRight = CGPointMake(x + width, y);
    CGPoint bottomLeft = CGPointMake(x, y + height);
    CGPoint bottomRight = CGPointMake(x + width, y + height);

    CGContextSetStrokeColorWithColor(ctx, color.CGColor);

    CGContextMoveToPoint(ctx, topLeft.x, topLeft.y);
    CGContextAddLineToPoint(ctx, topRight.x, topRight.y);
    CGContextAddLineToPoint(ctx, bottomRight.x, bottomRight.y);
    CGContextAddLineToPoint(ctx, bottomLeft.x, bottomLeft.y);
    CGContextAddLineToPoint(ctx, topLeft.x, topLeft.y);

    CGContextDrawPath(ctx, kCGPathStroke);
}


-(UIImage *)drawDebugOutputfromArray:(NSArray<VNRecognizedTextObservation*>*)arr error:(NSError**)error{
    // reformat rect (don't know why there is size differnt here)
    CGFloat scale = [Screen getScale];
    CGRect screenBounds = [Screen getBounds];

    UIImage* image = [[UIImage alloc] initWithCIImage:img];
    
    CGFloat imageAbsoluteWidth = image.size.width;
    CGFloat imageAbsoluteHeight = image.size.height;

    CGRect wholeImageRect = CGRectMake(0, 0, imageAbsoluteWidth, imageAbsoluteHeight);

    // begin a graphics context of sufficient size
    UIGraphicsBeginImageContextWithOptions(image.size, NO, 0); // CGSizeMake(imageAbsoluteWidth, imageAbsoluteHeight)
 
	// draw original image into the context
	[image drawInRect:wholeImageRect];
 
	// get the context for CoreGraphics
	CGContextRef ctx = UIGraphicsGetCurrentContext();
 
    // draw match rectangle
    [self drawRectangle:recognizeRect inContext:ctx withColor:[UIColor redColor]];

    [[UIColor redColor] setFill]; // set color
    [[NSString stringWithFormat:@"Rect:(%d, %d, %d, %d)", (int)recognizeRect.origin.x, (int)recognizeRect.origin.y, (int)recognizeRect.size.width, (int)recognizeRect.size.height] drawInRect:CGRectIntegral(recognizeRect) withFont:[UIFont boldSystemFontOfSize:30]]; 

    for (VNRecognizedTextObservation* i in arr)
    {
        VNRecognizedText* text = [i topCandidates:1][0];
        NSString* textString = [text string];
            
        NSError *err = nil;
        VNRectangleObservation* boundingBox = [text boundingBoxForRange:NSMakeRange(0, [textString length]) error:&err];

        if (err)
        {
            NSLog(@"com.zjx.springboard: unable to output debug image for text recognization. Error: %@", err);
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"-1;;无法输出文字识别的调试图片，错误信息：%@", err]}];
            return nil;
        }

        //test = [self drawTextRectangle:CGRectMake(100, 100, 100, 100) andText:@"test"];

        float rectWidth = (boundingBox.topRight.x - boundingBox.topLeft.x) * recognizeRect.size.width;
        float rectHeight = abs(boundingBox.topLeft.y - boundingBox.bottomLeft.y) * recognizeRect.size.height;
        float rectx = boundingBox.topLeft.x * recognizeRect.size.width + recognizeRect.origin.x;
        float recty = (1 - boundingBox.topLeft.y) * recognizeRect.size.height + recognizeRect.origin.y;

        CGRect rect = CGRectMake(rectx, recty, rectWidth, rectHeight);
        //NSLog(@"com.zjx.springboard: rect: recognizeRect: %f, boundingBox: %f", recognizeRect.origin.y, boundingBox.topLeft.y);
        // draw text rectangles
        [self drawRectangle:rect inContext:ctx withColor:[UIColor greenColor]];
        
        // draw filled rectangle
        CGContextSetFillColorWithColor(ctx, [[UIColor redColor] colorWithAlphaComponent:0.3].CGColor); // set color
        CGContextFillRect(ctx, rect);

        // draw text
        [[UIColor redColor] setFill]; // set color
        UIFont *font = [UIFont boldSystemFontOfSize:20]; //set font size
        rect.origin.y = rect.origin.y + rect.size.height; // draw
        [textString drawInRect:CGRectIntegral(rect) withFont:font]; 

        //NSLog(@"com.zjx.springboard: string: %@, topLeft: %f, topright:%f", textString, boundingBox.topLeft.x, boundingBox.topRight.x);

    }


 
	// make image out of bitmap context
	UIImage *retImage = UIGraphicsGetImageFromCurrentImageContext();
 
	// free the context
	UIGraphicsEndImageContext();

	return retImage;
}


- (void)setMinimumHeight:(float)height {
    request.minimumTextHeight = height;
}

- (void)setCustomWords:(NSArray*)customWords {
    request.customWords = customWords;
}

- (void)setRecognitionLevel:(VNRequestTextRecognitionLevel)level {
    request.recognitionLevel = level;
}

- (void)setLanguages:(NSArray*)languages {
    requestedLanguages = [languages copy];
}

- (void)setCorrection:(BOOL)correct {
    request.usesLanguageCorrection = correct;
}


@end