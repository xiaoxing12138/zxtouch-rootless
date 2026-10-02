#import "TemplateMatch.h"
#import <Accelerate/Accelerate.h>
#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#include <math.h>

// 匹配分三段花时间：灰度化 / 建积分图 / 扫描。三段耗时记下来，用 socket 命令 40;;perf 读回，
// 免得每次优化都靠猜瓶颈在哪一段。
static double gGrayMilliseconds = 0;
static double gIntegralMilliseconds = 0;
static double gScanMilliseconds = 0;

// 灰度系数放大 8192 倍给 vImage 做整数矩阵乘（Rec.601，与旧实现同系数）
#define GRAY_FIXED_SHIFT 8192

// 4 通道交织像素 → 平面灰度，vImage 矩阵乘一次过整屏（NEON 加速），替代原来
// 「先 CGContextDrawImage 画进 RGBA 上下文 + 387 万次标量乘法循环」。
// 屏幕帧和模板图都走这一个函数（调用方把模板也解码成同一种内存序），所以 vImage 究竟
// 按什么顺序解释这 4 个字节并不影响结果——两边解释一致，NCC 就对得上。
static unsigned char* pixelsToGrayscale(const UInt8 *pixels, size_t stride, size_t w, size_t h) {
    size_t grayStride = (w + 3) & ~(size_t)3;   // vImage 要求行跨距 4 字节对齐
    unsigned char *gray = (unsigned char *)malloc(grayStride * h);
    if (!gray) return NULL;

    vImage_Buffer src = { (void *)pixels, h, w, stride };
    vImage_Buffer dst = { gray, h, w, grayStride };
    const int16_t matrix[4] = { (int16_t)lroundf(0.114f * GRAY_FIXED_SHIFT),
                                (int16_t)lroundf(0.587f * GRAY_FIXED_SHIFT),
                                (int16_t)lroundf(0.299f * GRAY_FIXED_SHIFT),
                                0 };
    vImage_Error error = vImageMatrixMultiply_ARGB8888ToPlanar8(&src, &dst, matrix, GRAY_FIXED_SHIFT, NULL, 0, kvImageNoFlags);
    if (error != kvImageNoError) {
        NSLog(@"com.zjx.springboard: image_match 灰度转换失败：%ld", (long)error);
        free(gray);
        return NULL;
    }
    // 调用方（整数积分图 + vDSP）都按紧凑排布寻址，把行尾的对齐填充压掉。
    // 真实机型屏幕宽度都是 4 的倍数，这里通常一次都不搬。
    if (grayStride != w) {
        for (size_t row = 1; row < h; row++) memmove(gray + row * w, gray + row * grayStride, w);
    }
    return gray;
}

// 模板灰度图缓存：模板图每次匹配都从磁盘解码 + 灰度化是白花的开销，
// 按「路径 + 修改时间」缓存，换图（mtime 变）自动失效。
@interface ZXGrayTemplate : NSObject
@property (nonatomic) size_t width;
@property (nonatomic) size_t height;
@property (nonatomic) unsigned char *gray;
@end

@implementation ZXGrayTemplate
- (void)dealloc { if (_gray) free(_gray); }
@end

static ZXGrayTemplate* cachedTemplateGray(NSString *path) {
    NSDate *modified = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL] fileModificationDate];
    NSString *key = [NSString stringWithFormat:@"%@|%.0f", path, modified ? modified.timeIntervalSince1970 : 0];

    // 脚本线程和多个 socket 客户端可能同时匹配，缓存字典必须互斥；返回的对象由调用方的
    // 强引用持住，所以这里清缓存也不会把别人正在用的模板灰度图释放掉。
    @synchronized ([TemplateMatch class]) {
        static NSMutableDictionary<NSString *, ZXGrayTemplate *> *cache = nil;
        if (!cache) cache = [NSMutableDictionary dictionary];
        ZXGrayTemplate *cached = cache[key];
        if (cached) return cached;
        if (cache.count >= 8) [cache removeAllObjects];   // 只留最近几个，别一直涨

        UIImage *image = [UIImage imageWithContentsOfFile:path];
        if (!image || !image.CGImage) return nil;

        size_t w = CGImageGetWidth(image.CGImage);
        size_t h = CGImageGetHeight(image.CGImage);
        if (w == 0 || h == 0) return nil;

        // 解码成与屏幕帧同一种内存序（BGRA，4 字节步长），再走同一个灰度函数，保证两边口径一致
        size_t rowBytes = ((w * 4) + 31) & ~(size_t)31;
        unsigned char *rgba = (unsigned char *)calloc(rowBytes * h, 1);
        if (!rgba) return nil;

        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(rgba, w, h, 8, rowBytes, colorSpace,
                                                     kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        CGColorSpaceRelease(colorSpace);
        if (!context) {
            free(rgba);
            return nil;
        }
        CGContextDrawImage(context, CGRectMake(0, 0, w, h), image.CGImage);
        CGContextRelease(context);

        unsigned char *gray = pixelsToGrayscale(rgba, rowBytes, w, h);
        free(rgba);
        if (!gray) return nil;

        ZXGrayTemplate *entry = [ZXGrayTemplate new];
        entry.width = w;
        entry.height = h;
        entry.gray = gray;
        cache[key] = entry;
        return entry;
    }
}

// 模板缩放（灰度 → 灰度 float）
static float* resizeGrayToFloat(const unsigned char *src, size_t srcW, size_t srcH, size_t dstW, size_t dstH) {
    float *dst = (float *)malloc(dstW * dstH * sizeof(float));
    if (!dst) return NULL;

    vImage_Buffer srcBuf = { (void*)src, srcH, srcW, srcW };
    vImage_Buffer dstBuf = { dst, dstH, dstW, dstW * sizeof(float) };
    vImage_Error error = vImageScale_Planar8(&srcBuf, &dstBuf, NULL, kvImageEdgeExtend);
    if (error != kvImageNoError) {
        free(dst);
        return NULL;
    }
    return dst;
}

static BOOL buildIntegralImages(const float *img, size_t w, size_t h, double **outSum, double **outSqSum) {
    size_t stride = w + 1;
    size_t rows = h + 1;
    double *sum = (double *)calloc(stride * rows, sizeof(double));
    double *sqSum = (double *)calloc(stride * rows, sizeof(double));
    if (!sum || !sqSum) {
        if (sum) free(sum);
        if (sqSum) free(sqSum);
        return NO;
    }

    for (size_t y = 1; y <= h; y++) {
        double rowSum = 0.0;
        double rowSqSum = 0.0;
        for (size_t x = 1; x <= w; x++) {
            double value = img[(y - 1) * w + (x - 1)];
            rowSum += value;
            rowSqSum += value * value;
            size_t idx = y * stride + x;
            sum[idx] = sum[(y - 1) * stride + x] + rowSum;
            sqSum[idx] = sqSum[(y - 1) * stride + x] + rowSqSum;
        }
    }

    *outSum = sum;
    *outSqSum = sqSum;
    return YES;
}

static inline double integralRectSum(const double *integral, size_t imgW, size_t x, size_t y, size_t w, size_t h) {
    size_t stride = imgW + 1;
    size_t x2 = x + w;
    size_t y2 = y + h;
    return integral[y2 * stride + x2] - integral[y * stride + x2] - integral[y2 * stride + x] + integral[y * stride + x];
}

static float* centeredTemplate(const float *tmpl, size_t tw, size_t th, float *outNorm) {
    size_t n = tw * th;
    float *tmplCentered = (float *)malloc(n * sizeof(float));
    if (!tmplCentered) return NULL;
    memcpy(tmplCentered, tmpl, n * sizeof(float));

    float tmplMean = 0.0f;
    vDSP_meanv(tmplCentered, 1, &tmplMean, n);
    float negTmplMean = -tmplMean;
    vDSP_vsadd(tmplCentered, 1, &negTmplMean, tmplCentered, 1, n);

    float tmplNorm = 0.0f;
    vDSP_svesq(tmplCentered, 1, &tmplNorm, n);
    *outNorm = tmplNorm;
    return tmplCentered;
}

static float nccScoreFast(const float *img, size_t imgW,
                          const double *integral, const double *sqIntegral,
                          const float *tmplCentered, float tmplNorm,
                          size_t tw, size_t th, size_t x, size_t y) {
    size_t n = tw * th;
    double patchSum = integralRectSum(integral, imgW, x, y, tw, th);
    double patchSqSum = integralRectSum(sqIntegral, imgW, x, y, tw, th);
    double patchNorm = patchSqSum - ((patchSum * patchSum) / (double)n);
    if (patchNorm <= 1e-6 || tmplNorm <= 1e-6f) return 0.0f;

    double dotProduct = 0.0;
    for (size_t row = 0; row < th; row++) {
        float rowDot = 0.0f;
        vDSP_dotpr(img + (y + row) * imgW + x, 1,
                   tmplCentered + row * tw, 1,
                   &rowDot, tw);
        dotProduct += rowDot;
    }

    double denom = sqrt(patchNorm * (double)tmplNorm);
    if (denom < 1e-6) return 0.0f;
    return (float)(dotProduct / denom);
}

@interface TemplateMatch() {
    int _maxTryTimes;
    float _acceptableValue;
    float _scaleRation;
    float _lastBestScore;
}
@end

@implementation TemplateMatch

@synthesize lastBestScore = _lastBestScore;

+ (NSDictionary *)lastTiming {
    return @{ @"gray_ms": @(gGrayMilliseconds),
              @"integral_ms": @(gIntegralMilliseconds),
              @"scan_ms": @(gScanMilliseconds) };
}

- (instancetype)init {
    self = [super init];
    _maxTryTimes = 4;
    _acceptableValue = 0.8f;
    _scaleRation = 0.8f;
    return self;
}

- (void)setAcceptableValue:(float)av { _acceptableValue = av; }
- (void)setMaxTryTimes:(int)mtt     { _maxTryTimes = MAX(0, MIN(mtt, 8)); }
- (void)setScaleRation:(float)sr    { _scaleRation = (sr > 0.05f && sr < 1.0f) ? sr : 0.8f; }

- (CGRect)templateMatchWithPixels:(const UInt8 *)pixels stride:(int)stride width:(size_t)imgW height:(size_t)imgH templatePath:(NSString*)templatePath error:(NSError**)err {
    CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();

    // 一、灰度化：vImage 出平面灰度，再用 vDSP 整批转 float（扫描要用 float 做点积）
    CFAbsoluteTime tGray = CFAbsoluteTimeGetCurrent();
    unsigned char *grayBytes = pixelsToGrayscale(pixels, stride, imgW, imgH);
    if (!grayBytes) {
        *err = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999
                userInfo:@{NSLocalizedDescriptionKey:@"-1;;图像匹配：截图转换为灰度图失败\r\n"}];
        return CGRectZero;
    }
    float *imgGray = (float *)malloc(imgW * imgH * sizeof(float));
    if (imgGray) vDSP_vfltu8(grayBytes, 1, imgGray, 1, (vDSP_Length)(imgW * imgH));
    free(grayBytes);
    if (!imgGray) {
        *err = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999
                userInfo:@{NSLocalizedDescriptionKey:@"-1;;图像匹配：分配灰度图内存缓冲区失败\r\n"}];
        return CGRectZero;
    }
    gGrayMilliseconds = (CFAbsoluteTimeGetCurrent() - tGray) * 1000.0;

    // 二、模板：命中缓存就不再重新解码
    ZXGrayTemplate *tpl = cachedTemplateGray(templatePath);
    if (!tpl) {
        free(imgGray);
        *err = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999
                userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:
                    @"-1;;图像匹配：加载模板图片失败：%@\r\n", templatePath]}];
        return CGRectZero;
    }
    size_t tmplW = tpl.width;
    size_t tmplH = tpl.height;
    float *tmplGray = (float *)malloc(tmplW * tmplH * sizeof(float));
    if (!tmplGray) {
        free(imgGray);
        *err = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999
                userInfo:@{NSLocalizedDescriptionKey:@"-1;;图像匹配：分配模板内存缓冲区失败\r\n"}];
        return CGRectZero;
    }
    for (size_t i = 0; i < tmplW * tmplH; i++) tmplGray[i] = (float)tpl.gray[i];

    // 三、积分图（求每块区域的和 / 平方和，定好分母）
    CFAbsoluteTime tIntegral = CFAbsoluteTimeGetCurrent();
    double *integral = NULL;
    double *sqIntegral = NULL;
    if (!buildIntegralImages(imgGray, imgW, imgH, &integral, &sqIntegral)) {
        free(imgGray);
        free(tmplGray);
        *err = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999
                userInfo:@{NSLocalizedDescriptionKey:@"-1;;图像匹配：分配积分图内存缓冲区失败\r\n"}];
        return CGRectZero;
    }
    gIntegralMilliseconds = (CFAbsoluteTimeGetCurrent() - tIntegral) * 1000.0;

    // 四、逐档缩放粗扫 + ±step 精修
    CFAbsoluteTime tScan = CFAbsoluteTimeGetCurrent();
    CGRect best = CGRectZero;
    float bestScore = -1.0f;
    size_t bestTW = tmplW;
    size_t bestTH = tmplH;

    NSMutableArray *scales = [NSMutableArray array];
    [scales addObject:@(1.0f)];
    for (int i = 0; i < _maxTryTimes; i++) {
        [scales addObject:@(powf(2.0f - _scaleRation, i + 1))];
        [scales addObject:@(powf(_scaleRation, i + 1))];
    }

    for (NSNumber *scaleNum in scales) {
        float scale = scaleNum.floatValue;
        size_t tw = (size_t)llround((double)tmplW * scale);
        size_t th = (size_t)llround((double)tmplH * scale);
        if (tw < 2 || th < 2 || tw >= imgW || th >= imgH) continue;

        float *tmplScaled = NULL;
        if (fabsf(scale - 1.0f) < 0.0001f) {
            tmplScaled = tmplGray;
        } else {
            tmplScaled = resizeGrayToFloat(tpl.gray, tmplW, tmplH, tw, th);
            if (!tmplScaled) continue;
        }

        float tmplNorm = 0.0f;
        float *tmplCentered = centeredTemplate(tmplScaled, tw, th, &tmplNorm);
        if (!tmplCentered || tmplNorm <= 1e-6f) {
            if (tmplCentered) free(tmplCentered);
            if (tmplScaled != tmplGray) free(tmplScaled);
            continue;
        }

        size_t step = MAX((size_t)1, MIN(tw, th) / 8);
        for (size_t y = 0; y + th <= imgH; y += step) {
            for (size_t x = 0; x + tw <= imgW; x += step) {
                float score = nccScoreFast(imgGray, imgW, integral, sqIntegral, tmplCentered, tmplNorm, tw, th, x, y);
                if (score > bestScore) {
                    bestScore = score;
                    best = CGRectMake(x, y, tw, th);
                    bestTW = tw;
                    bestTH = th;
                }
            }
        }

        free(tmplCentered);
        if (tmplScaled != tmplGray) free(tmplScaled);

        if (bestScore >= _acceptableValue) break;
    }

    // 粗扫是跳着扫的（步长 = 模板边长/8），最优点最多离真峰一个 step。
    // 而模板去掉均值后常常只剩尖锐边缘（平滑图标 + 纯色底），NCC 峰值极窄：
    // 实测同一张图，step=14 只能扫到 0.583，真峰在 0.9998。所以必须无条件精修一遍，
    // 不能像以前那样「分数够高才精修」——那恰好是最需要精修的时候把它跳过了。
    if (bestTW <= imgW && bestTH <= imgH) {
        size_t refineStep = MAX((size_t)1, MIN(bestTW, bestTH) / 8);
        size_t bx = (size_t)best.origin.x;
        size_t by = (size_t)best.origin.y;
        size_t rx = (bx > refineStep) ? bx - refineStep : 0;
        size_t ry = (by > refineStep) ? by - refineStep : 0;
        size_t rxMax = MIN(bx + refineStep, imgW - bestTW);
        size_t ryMax = MIN(by + refineStep, imgH - bestTH);

        float *tmplRefine = (bestTW == tmplW && bestTH == tmplH) ? tmplGray : resizeGrayToFloat(tpl.gray, tmplW, tmplH, bestTW, bestTH);
        float tmplNorm = 0.0f;
        float *tmplCentered = tmplRefine ? centeredTemplate(tmplRefine, bestTW, bestTH, &tmplNorm) : NULL;
        if (tmplCentered && tmplNorm > 1e-6f) {
            for (size_t y = ry; y <= ryMax; y++) {
                for (size_t x = rx; x <= rxMax; x++) {
                    float score = nccScoreFast(imgGray, imgW, integral, sqIntegral, tmplCentered, tmplNorm, bestTW, bestTH, x, y);
                    if (score > bestScore) {
                        bestScore = score;
                        best = CGRectMake(x, y, bestTW, bestTH);
                    }
                }
            }
        }
        if (tmplCentered) free(tmplCentered);
        if (tmplRefine && tmplRefine != tmplGray) free(tmplRefine);
    }
    gScanMilliseconds = (CFAbsoluteTimeGetCurrent() - tScan) * 1000.0;

    _lastBestScore = bestScore;   // 最高分写回，成功失败都留着给调用方

    free(integral);
    free(sqIntegral);
    free(imgGray);
    free(tmplGray);

    CFTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - startedAt;
    if (bestScore >= _acceptableValue) {
        NSLog(@"com.zjx.springboard: image_match success. x:%.0f y:%.0f w:%.0f h:%.0f score:%.3f elapsed:%.3fs",
              best.origin.x, best.origin.y, best.size.width, best.size.height, bestScore, elapsed);
        return best;
    }

    NSLog(@"com.zjx.springboard: image_match failed. best score: %.3f elapsed:%.3fs", bestScore, elapsed);
    *err = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999
            userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:
                @"-1;;图像匹配：未找到匹配结果（最高得分：%.3f，要求得分：%.3f）\r\n",
                bestScore, _acceptableValue]}];
    return CGRectZero;
}

@end
