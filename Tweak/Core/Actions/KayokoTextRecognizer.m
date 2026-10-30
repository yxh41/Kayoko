//
//  KayokoTextRecognizer.m
//  Kayoko
//
//  Vision-based OCR for the swipe action that sends a clipboard picture to
//  Faircopy's 分词. Runs inside SpringBoard (Kayoko's panel lives there), which
//  is exactly why nothing here is linked against Vision.
//

#import "KayokoTextRecognizer.h"

#import <CoreGraphics/CoreGraphics.h>
#import <UIKit/UIKit.h>
#import <ctype.h>
#import <dlfcn.h>

/// Vision is opened on demand, never linked.
///
/// Linking `-framework Vision` would make dyld load it into SpringBoard at
/// launch for every user, whether or not they ever swipe a picture — tens of
/// megabytes of resident memory in the one process where a jetsam kill is
/// unrecoverable. `dlopen` on first use costs nothing until the button is
/// actually pressed, and the handle is kept so a second press does not re-open
/// it.
static NSString *const kKayokoVisionFrameworkPath =
    @"/System/Library/Frameworks/Vision.framework/Vision";

/// Longest edge handed to Vision. Screenshots on these devices are 1170 px wide,
/// so this only bites on very tall stitched captures, where a full-resolution
/// pass is slow enough to look like a hang. Vision's own detector works on a
/// normalised scale anyway, so downscaling this far does not lose usable text.
static const CGFloat kKayokoRecognitionMaxPixelSize = 2400.0;

/// Recognition languages, in priority order. Chinese first because the pictures
/// people clip here are overwhelmingly Chinese UI; English is kept as the
/// fallback so mixed lines ("已复制 3 items") still come out whole.
static NSString *const kKayokoRecognitionLanguageChinese = @"zh-Hans";
static NSString *const kKayokoRecognitionLanguageEnglish = @"en-US";

/// Compile-time selector declarations for the Vision classes.
///
/// These are declared, never implemented — the actual objects come from
/// `NSClassFromString` after `dlopen`. The point is only to make the compiler
/// aware of the selectors and their shapes: with these in scope ARC applies the
/// normal `init` ownership rules (`+1` in, ARC-managed out), so no object is
/// leaked and none is over-released. Calling through `objc_msgSend` casts or
/// `performSelector:` instead would leave ownership to guesswork, which is the
/// exact mistake that deallocated ShellX's singleton in the floating-image work.
@interface NSObject (KayokoVisionShims)
- (instancetype)initWithCGImage:(CGImageRef)image options:(NSDictionary<NSString *, id> *)options;
- (void)setRecognitionLevel:(NSInteger)level;
- (void)setRecognitionLanguages:(NSArray<NSString *> *)languages;
- (void)setUsesLanguageCorrection:(BOOL)usesLanguageCorrection;
- (BOOL)performRequests:(NSArray *)requests error:(NSError **)error;
- (NSArray *)results;
- (NSArray *)topCandidates:(NSUInteger)limit;
- (CGRect)boundingBox;
- (NSString *)string;
@end

/// Private helpers, declared up front so the block below does not have to call a
/// method that is textually defined further down.
@interface KayokoTextRecognizer ()
+ (nullable NSString *)recognizeSynchronouslyAtPath:(NSString *)path;
+ (nullable NSString *)textFromObservations:(NSArray *)observations;
+ (BOOL)needsSpaceBetween:(NSString *)previous andNext:(NSString *)next;
+ (UIImage *)downscaledImage:(UIImage *)image maxPixelSize:(CGFloat)maxPixelSize;
@end

@implementation KayokoTextRecognizer
+ (BOOL)isAvailable {
    static dispatch_once_t onceToken;
    static BOOL available = NO;
    dispatch_once(&onceToken, ^{
      void *handle = dlopen(kKayokoVisionFrameworkPath.UTF8String, RTLD_LAZY);
      if (!handle) {
          const char *reason = dlerror();
          NSLog(@"Kayoko: Vision unavailable (%s) — picture OCR disabled",
                reason ? reason : "unknown error");
          return;
      }
      available = NSClassFromString(@"VNImageRequestHandler") != Nil &&
                  NSClassFromString(@"VNRecognizeTextRequest") != Nil;
      if (!available) {
          NSLog(@"Kayoko: Vision loaded but the recogniser classes are missing");
      }
    });
    return available;
}

+ (void)recognizeTextInImageAtPath:(NSString *)path
                        completion:(void (^)(NSString *_Nullable))completion {
    if (!completion) {
        return;
    }
    if ([path length] == 0 || ![self isAvailable]) {
        dispatch_async(dispatch_get_main_queue(), ^{
          completion(nil);
        });
        return;
    }
    // Vision's synchronous request is CPU/GPU heavy and must never run on the
    // main queue: Kayoko's panel lives in SpringBoard, where a blocked main
    // thread is a frozen home screen, not a spinner.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSString *text = nil;
      @autoreleasepool {
          text = [self recognizeSynchronouslyAtPath:path];
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(text);
      });
    });
}

#pragma mark - Recognition

+ (nullable NSString *)recognizeSynchronouslyAtPath:(NSString *)path {
    UIImage *image = [UIImage imageWithContentsOfFile:path];
    if (!image) {
        NSLog(@"Kayoko: OCR skipped — cannot read image at %@", path);
        return nil;
    }
    image = [self downscaledImage:image maxPixelSize:kKayokoRecognitionMaxPixelSize];
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) {
        NSLog(@"Kayoko: OCR skipped — image has no CGImage backing");
        return nil;
    }

    Class handlerClass = NSClassFromString(@"VNImageRequestHandler");
    Class requestClass = NSClassFromString(@"VNRecognizeTextRequest");
    if (!handlerClass || !requestClass) {
        return nil;
    }

    NSDate *startedAt = [NSDate date];
    id handler = [(id)handlerClass alloc];
    handler = [handler initWithCGImage:cgImage options:@{}];
    id request = [[(id)requestClass alloc] init];
    // 1 = accurate. 0 (fast) loses the thin UI glyphs these screenshots are
    // full of, and the difference on a phone screenshot is a few hundred ms.
    [request setRecognitionLevel:1];
    [request setRecognitionLanguages:@[ kKayokoRecognitionLanguageChinese,
                                        kKayokoRecognitionLanguageEnglish ]];
    [request setUsesLanguageCorrection:YES];

    NSError *error = nil;
    if (![handler performRequests:@[ request ] error:&error]) {
        NSLog(@"Kayoko: OCR failed — %@", error.localizedDescription ?: @"unknown error");
        return nil;
    }

    NSArray *observations = [request results];
    NSString *text = [self textFromObservations:observations];
    NSLog(@"Kayoko: OCR %@ in %.0f ms, %lu chars",
          text.length > 0 ? @"ok" : @"empty",
          [[NSDate date] timeIntervalSinceDate:startedAt] * 1000.0,
          (unsigned long)text.length);
    return text;
}

/// Rebuilds reading order from the recognised boxes.
///
/// Vision returns observations in no guaranteed order, and it splits a single
/// visual line into several boxes whenever there is a wide gap in it. Emitting
/// them one per line would turn a two-column screenshot into word salad, so the
/// boxes are grouped into visual lines (same height band), sorted left to right
/// inside a line, and separated by a newline between lines.
+ (nullable NSString *)textFromObservations:(NSArray *)observations {
    if (![observations isKindOfClass:[NSArray class]] || observations.count == 0) {
        return nil;
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *boxes = [NSMutableArray array];
    for (id observation in observations) {
        NSArray *candidates = [observation topCandidates:1];
        id candidate = candidates.firstObject;
        NSString *string = [candidate string];
        if (![string isKindOfClass:[NSString class]] || string.length == 0) {
            continue;
        }
        CGRect box = [observation boundingBox];
        [boxes addObject:@{
            @"text" : string,
            @"x" : @(CGRectGetMinX(box)),
            @"y" : @(CGRectGetMidY(box)),
            @"height" : @(CGRectGetHeight(box)),
        }];
    }
    if (boxes.count == 0) {
        return nil;
    }

    // Vision's origin is bottom-left: bigger y is higher on the page.
    [boxes sortUsingComparator:^NSComparisonResult(NSDictionary<NSString *, id> *lhs,
                                                   NSDictionary<NSString *, id> *rhs) {
      double leftY = [lhs[@"y"] doubleValue];
      double rightY = [rhs[@"y"] doubleValue];
      if (fabs(leftY - rightY) > 0.008) {
          return leftY > rightY ? NSOrderedAscending : NSOrderedDescending;
      }
      double leftX = [lhs[@"x"] doubleValue];
      double rightX = [rhs[@"x"] doubleValue];
      if (leftX < rightX) {
          return NSOrderedAscending;
      }
      if (leftX > rightX) {
          return NSOrderedDescending;
      }
      return NSOrderedSame;
    }];

    NSMutableString *result = [NSMutableString string];
    double lineY = 0.0;
    double lineHeight = 0.0;
    BOOL hasLine = NO;
    for (NSDictionary<NSString *, id> *box in boxes) {
        double y = [box[@"y"] doubleValue];
        double height = [box[@"height"] doubleValue];
        NSString *fragment = box[@"text"];
        BOOL sameLine = hasLine && fabs(y - lineY) <= MAX(0.006, lineHeight * 0.6);
        if (sameLine) {
            // Two ASCII fragments on one visual line need the space Vision
            // dropped; Chinese fragments must not get one, or every word ends up
            // separated by a stray gap when the text is tokenized.
            if ([self needsSpaceBetween:[result hasSuffix:@"\n"] ? @"" : result
                                andNext:fragment]) {
                [result appendString:@" "];
            }
            [result appendString:fragment];
            lineHeight = MAX(lineHeight, height);
        } else {
            if (hasLine) {
                [result appendString:@"\n"];
            }
            [result appendString:fragment];
            lineY = y;
            lineHeight = height;
            hasLine = YES;
        }
    }
    NSString *trimmed = [result stringByTrimmingCharactersInSet:
                                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length > 0 ? trimmed : nil;
}

+ (BOOL)needsSpaceBetween:(NSString *)previous andNext:(NSString *)next {
    if (previous.length == 0 || next.length == 0) {
        return NO;
    }
    unichar left = [previous characterAtIndex:previous.length - 1];
    unichar right = [next characterAtIndex:0];
    // ASCII word characters on both sides: Vision usually ate the gap.
    BOOL leftIsWord = left < 0x80 && (isalnum((int)left) != 0);
    BOOL rightIsWord = right < 0x80 && (isalnum((int)right) != 0);
    return leftIsWord && rightIsWord;
}

+ (UIImage *)downscaledImage:(UIImage *)image maxPixelSize:(CGFloat)maxPixelSize {
    CGSize size = image.size;
    CGFloat longest = MAX(size.width, size.height);
    if (longest <= maxPixelSize || longest <= 0.0) {
        return image;
    }
    CGFloat scale = maxPixelSize / longest;
    CGSize target = CGSizeMake(floor(size.width * scale), floor(size.height * scale));
    if (target.width < 1.0 || target.height < 1.0) {
        return image;
    }
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1.0;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:target
                                                                              format:format];
    return [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
      [image drawInRect:CGRectMake(0.0, 0.0, target.width, target.height)];
    }];
}

@end
