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

/// Longest edge handed to Vision.
///
/// 4.3.15 used 2400, which every iPhone screenshot exceeded (1170 x 2532), so
/// each one was resampled down by ~5% through a bilinear pass. Chinese glyphs
/// in UI text are only a dozen pixels tall; softening them by even a few percent
/// is enough to turn 未 into 末 and 己 into 已. The cap now only bites on stitched
/// long captures, where a full-resolution pass would be slow enough to look like
/// a hang.
static const CGFloat kKayokoRecognitionMaxPixelSize = 4096.0;

/// Small pictures are scaled up instead. Vision recognises glyphs relative to
/// the image it is handed, so a 400 px sticker has almost no signal; tripling it
/// costs nothing and recovers text that would otherwise be dropped entirely.
static const CGFloat kKayokoRecognitionMinPixelSize = 1000.0;
static const CGFloat kKayokoRecognitionMaxUpscale = 3.0;

/// Recognition languages, in priority order. Chinese first because the pictures
/// people clip here are overwhelmingly Chinese UI; English is kept as the
/// fallback so mixed lines ("已复制 3 items") still come out whole.
///
/// Traditional Chinese is deliberately not listed: Vision emits characters in
/// the script of whichever language it picks, so adding zh-Hant to the list
/// risks converting a Simplified screenshot into Traditional output — a whole
/// different way of being wrong.
static NSString *const kKayokoRecognitionLanguageChinese = @"zh-Hans";
static NSString *const kKayokoRecognitionLanguageEnglish = @"en-US";

/// Observations below this confidence are noise: a single misread glyph on a
/// busy background, or the residue of a gradient. Dropping them beats handing
/// the user a stray character to delete.
static const float kKayokoMinimumConfidence = 0.25f;

/// Mean confidence under which a second, correction-free pass is worth running.
/// Screenshot text is not prose — codes, prices, names, mixed scripts — and the
/// language-correction model rewrites what it reads into something more
/// plausible, which is the classic "recognised but wrong" result.
static const double kKayokoCorrectionFallbackQuality = 0.62;

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
- (float)confidence;
- (NSString *)string;
@end

/// Private helpers, declared up front so the blocks below do not have to call a
/// method that is textually defined further down.
@interface KayokoTextRecognizer ()
+ (nullable NSString *)recognizeSynchronouslyAtPath:(NSString *)path;
+ (nullable UIImage *)preparedImage:(UIImage *)image;
+ (nullable NSArray *)observationsForImage:(CGImageRef)cgImage
                                correction:(BOOL)correction
                                  language:(NSArray<NSString *> *)languages;
+ (nullable NSArray<NSDictionary<NSString *, id> *> *)boxesFromObservations:(NSArray *)observations;
+ (nullable NSString *)assembleTextFromBoxes:(NSArray<NSDictionary<NSString *, id> *> *)boxes;
+ (void)appendRow:(NSArray<NSDictionary<NSString *, id> *> *)row to:(NSMutableString *)result;
+ (BOOL)needsSpaceBetween:(NSString *)previous
                  andNext:(NSString *)next
                      gap:(CGFloat)gap
                rowHeight:(CGFloat)rowHeight;
+ (BOOL)isCJK:(unichar)character;
+ (BOOL)isPunctuation:(unichar)character;
@end

/// Mean recognition confidence, weighted by how much text each box carries.
/// 0 when nothing usable came back.
static double KayokoQualityForBoxes(NSArray<NSDictionary<NSString *, id> *> *boxes) {
    double weight = 0.0;
    double weighted = 0.0;
    for (NSDictionary<NSString *, id> *box in boxes) {
        NSString *text = box[@"text"];
        if (![text isKindOfClass:[NSString class]] || text.length == 0) {
            continue;
        }
        double length = (double)text.length;
        weight += length;
        weighted += (double)[box[@"confidence"] floatValue] * length;
    }
    return weight > 0.0 ? weighted / weight : 0.0;
}

/// How much of the smaller box sits inside the other one. Used to collapse the
/// duplicate observations Vision sometimes returns for the same words, which
/// otherwise print the line twice.
static CGFloat KayokoOverlapRatio(CGRect lhs, CGRect rhs) {
    CGRect intersection = CGRectIntersection(lhs, rhs);
    if (CGRectIsNull(intersection)) {
        return 0.0;
    }
    CGFloat area = CGRectGetWidth(intersection) * CGRectGetHeight(intersection);
    CGFloat smaller = MIN(CGRectGetWidth(lhs) * CGRectGetHeight(lhs),
                          CGRectGetWidth(rhs) * CGRectGetHeight(rhs));
    return smaller > 0.0 ? area / smaller : 0.0;
}

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
    UIImage *prepared = [self preparedImage:image];
    CGImageRef cgImage = prepared.CGImage;
    if (!cgImage) {
        NSLog(@"Kayoko: OCR skipped — image has no CGImage backing");
        return nil;
    }

    NSDate *startedAt = [NSDate date];
    NSArray *languages = @[ kKayokoRecognitionLanguageChinese, kKayokoRecognitionLanguageEnglish ];

    NSArray *observations = [self observationsForImage:cgImage correction:YES language:languages];
    NSArray<NSDictionary<NSString *, id> *> *boxes = [self boxesFromObservations:observations];
    double quality = KayokoQualityForBoxes(boxes);
    NSString *pass = @"corrected";

    if (quality < kKayokoCorrectionFallbackQuality) {
        // Language correction is a language model, and on screenshot text it
        // likes to rewrite what it half-read into a more common phrase. A
        // correction-free pass often leaves the glyphs alone and scores higher.
        NSArray *plain = [self observationsForImage:cgImage correction:NO language:languages];
        NSArray<NSDictionary<NSString *, id> *> *plainBoxes = [self boxesFromObservations:plain];
        double plainQuality = KayokoQualityForBoxes(plainBoxes);
        NSLog(@"Kayoko: OCR fell back to the correction-free pass (quality %.2f -> %.2f)",
              quality, plainQuality);
        if (plainQuality > quality) {
            boxes = plainBoxes;
            quality = plainQuality;
            pass = @"plain";
        }
    }

    NSString *text = [self assembleTextFromBoxes:boxes];
    NSLog(@"Kayoko: OCR %@ in %.0f ms, %lu chars, %lu boxes, quality %.2f (%@)",
          text.length > 0 ? @"ok" : @"empty",
          [[NSDate date] timeIntervalSinceDate:startedAt] * 1000.0,
          (unsigned long)text.length,
          (unsigned long)boxes.count,
          quality,
          pass);
    return text;
}

/// Runs one recognition pass and returns the raw observations.
///
/// `accurate` (level 1) rather than `fast` (0): fast drops the thin UI glyphs
/// these screenshots are full of, and the difference on a phone screenshot is a
/// few hundred milliseconds.
+ (nullable NSArray *)observationsForImage:(CGImageRef)cgImage
                                correction:(BOOL)correction
                                  language:(NSArray<NSString *> *)languages {
    Class handlerClass = NSClassFromString(@"VNImageRequestHandler");
    Class requestClass = NSClassFromString(@"VNRecognizeTextRequest");
    if (!handlerClass || !requestClass) {
        return nil;
    }

    id handler = [(id)handlerClass alloc];
    handler = [handler initWithCGImage:cgImage options:@{}];
    id request = [[(id)requestClass alloc] init];
    [request setRecognitionLevel:1];
    [request setRecognitionLanguages:languages];
    [request setUsesLanguageCorrection:correction];

    NSError *error = nil;
    if (![handler performRequests:@[ request ] error:&error]) {
        NSLog(@"Kayoko: OCR failed — %@", error.localizedDescription ?: @"unknown error");
        return nil;
    }
    return [request results];
}

/// Normalises the image before Vision sees it.
///
/// Pixel dimensions are taken from the CGImage, not `UIImage.size`: size is in
/// points, so an image carrying a scale of 2 would have been "downscaled" to
/// half its real size by the old check. Orientation is flattened here too —
/// `CGImage` has no EXIF rotation, so a photo pasted from the camera roll used
/// to reach Vision sideways, which reads as pure noise.
+ (nullable UIImage *)preparedImage:(UIImage *)image {
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) {
        return nil;
    }
    CGFloat pixelWidth = (CGFloat)CGImageGetWidth(cgImage);
    CGFloat pixelHeight = (CGFloat)CGImageGetHeight(cgImage);
    CGFloat longest = MAX(pixelWidth, pixelHeight);
    if (longest <= 0.0) {
        return nil;
    }

    CGFloat factor = 1.0;
    if (longest > kKayokoRecognitionMaxPixelSize) {
        factor = kKayokoRecognitionMaxPixelSize / longest;
    } else if (longest < kKayokoRecognitionMinPixelSize) {
        factor = MIN(kKayokoRecognitionMinPixelSize / longest, kKayokoRecognitionMaxUpscale);
    }
    BOOL needsFlattening = image.imageOrientation != UIImageOrientationUp;
    if (fabs(factor - 1.0) < 0.01 && !needsFlattening) {
        return image;
    }

    CGSize target = CGSizeMake(MAX(1.0, floor(pixelWidth * factor)),
                               MAX(1.0, floor(pixelHeight * factor)));
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1.0;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:target
                                                                              format:format];
    return [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
      [image drawInRect:CGRectMake(0.0, 0.0, target.width, target.height)];
    }];
}

/// Turns observations into plain boxes, dropping noise and duplicates.
+ (nullable NSArray<NSDictionary<NSString *, id> *> *)boxesFromObservations:(NSArray *)observations {
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
        float confidence = [candidate confidence];
        if (confidence < kKayokoMinimumConfidence) {
            continue;
        }
        CGRect rect = [observation boundingBox];
        if (CGRectGetWidth(rect) <= 0.0 || CGRectGetHeight(rect) <= 0.0) {
            continue;
        }
        [boxes addObject:@{
            @"text" : string,
            @"rect" : [NSValue valueWithCGRect:rect],
            @"confidence" : @(confidence),
        }];
    }

    if (boxes.count < 2) {
        return boxes;
    }

    // Drop boxes that mostly sit on top of a more confident one, keeping the
    // longer string when both are plausible (Vision sometimes splits a word and
    // also reports it whole).
    NSMutableArray<NSDictionary<NSString *, id> *> *kept = [NSMutableArray array];
    NSArray<NSDictionary<NSString *, id> *> *byConfidence =
        [boxes sortedArrayUsingComparator:^NSComparisonResult(NSDictionary<NSString *, id> *lhs,
                                                              NSDictionary<NSString *, id> *rhs) {
          float left = [lhs[@"confidence"] floatValue];
          float right = [rhs[@"confidence"] floatValue];
          if (left > right) {
              return NSOrderedAscending;
          }
          if (left < right) {
              return NSOrderedDescending;
          }
          return NSOrderedSame;
        }];
    for (NSDictionary<NSString *, id> *box in byConfidence) {
        CGRect rect = [box[@"rect"] CGRectValue];
        BOOL duplicate = NO;
        for (NSDictionary<NSString *, id> *existing in kept) {
            if (KayokoOverlapRatio(rect, [existing[@"rect"] CGRectValue]) > 0.75) {
                duplicate = YES;
                break;
            }
        }
        if (!duplicate) {
            [kept addObject:box];
        }
    }
    return kept;
}

/// Rebuilds reading order from the recognised boxes.
///
/// Vision returns observations in no guaranteed order and splits one visual line
/// into several boxes wherever there is a wide gap. Boxes are therefore grouped
/// into rows by vertical overlap, sorted left to right inside a row, and
/// separated by a newline between rows.
+ (nullable NSString *)assembleTextFromBoxes:(NSArray<NSDictionary<NSString *, id> *> *)boxes {
    if (boxes.count == 0) {
        return nil;
    }

    // Strict, total order. The previous version compared midY with a 0.008
    // tolerance, which is not a strict weak ordering — with enough boxes the
    // result of the sort was arbitrary, and that alone scrambled reading order.
    NSArray<NSDictionary<NSString *, id> *> *sorted =
        [boxes sortedArrayUsingComparator:^NSComparisonResult(NSDictionary<NSString *, id> *lhs,
                                                              NSDictionary<NSString *, id> *rhs) {
          CGRect left = [lhs[@"rect"] CGRectValue];
          CGRect right = [rhs[@"rect"] CGRectValue];
          // Vision's origin is bottom-left: bigger maxY is higher on the page.
          CGFloat leftTop = CGRectGetMaxY(left);
          CGFloat rightTop = CGRectGetMaxY(right);
          if (fabs(leftTop - rightTop) > 1e-6) {
              return leftTop > rightTop ? NSOrderedAscending : NSOrderedDescending;
          }
          CGFloat leftX = CGRectGetMinX(left);
          CGFloat rightX = CGRectGetMinX(right);
          if (fabs(leftX - rightX) > 1e-6) {
              return leftX < rightX ? NSOrderedAscending : NSOrderedDescending;
          }
          return NSOrderedSame;
        }];

    NSMutableString *result = [NSMutableString string];
    NSMutableArray<NSDictionary<NSString *, id> *> *row = [NSMutableArray array];
    CGFloat rowTop = 0.0;
    CGFloat rowBottom = 0.0;

    for (NSDictionary<NSString *, id> *box in sorted) {
        CGRect rect = [box[@"rect"] CGRectValue];
        CGFloat bottom = CGRectGetMinY(rect);
        CGFloat top = CGRectGetMaxY(rect);
        BOOL sameRow = NO;
        if (row.count > 0) {
            CGFloat overlap = MIN(top, rowTop) - MAX(bottom, rowBottom);
            CGFloat shortest = MIN(top - bottom, rowTop - rowBottom);
            sameRow = shortest > 0.0 && overlap >= shortest * 0.5;
        }
        if (sameRow) {
            [row addObject:box];
            rowTop = MAX(rowTop, top);
            rowBottom = MIN(rowBottom, bottom);
            continue;
        }
        if (row.count > 0) {
            [self appendRow:row to:result];
            if (result.length > 0) {
                [result appendString:@"\n"];
            }
            [row removeAllObjects];
        }
        [row addObject:box];
        rowTop = top;
        rowBottom = bottom;
    }
    if (row.count > 0) {
        [self appendRow:row to:result];
    }

    NSString *trimmed = [result stringByTrimmingCharactersInSet:
                                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length > 0 ? trimmed : nil;
}

/// Appends one visual row, left to right, deciding per gap whether the space
/// Vision dropped should be put back.
+ (void)appendRow:(NSArray<NSDictionary<NSString *, id> *> *)row to:(NSMutableString *)result {
    NSArray<NSDictionary<NSString *, id> *> *ordered =
        [row sortedArrayUsingComparator:^NSComparisonResult(NSDictionary<NSString *, id> *lhs,
                                                            NSDictionary<NSString *, id> *rhs) {
          CGFloat leftX = CGRectGetMinX([lhs[@"rect"] CGRectValue]);
          CGFloat rightX = CGRectGetMinX([rhs[@"rect"] CGRectValue]);
          if (fabs(leftX - rightX) > 1e-6) {
              return leftX < rightX ? NSOrderedAscending : NSOrderedDescending;
          }
          return NSOrderedSame;
        }];

    CGFloat rowHeight = 0.0;
    for (NSDictionary<NSString *, id> *box in ordered) {
        rowHeight = MAX(rowHeight, CGRectGetHeight([box[@"rect"] CGRectValue]));
    }

    CGFloat previousMaxX = 0.0;
    BOOL hasPrevious = NO;
    for (NSDictionary<NSString *, id> *box in ordered) {
        NSString *fragment = box[@"text"];
        CGRect rect = [box[@"rect"] CGRectValue];
        if (result.length > 0) {
            CGFloat gap = hasPrevious ? CGRectGetMinX(rect) - previousMaxX : 0.0;
            if ([self needsSpaceBetween:result andNext:fragment gap:gap rowHeight:rowHeight]) {
                [result appendString:@" "];
            }
        }
        [result appendString:fragment];
        previousMaxX = CGRectGetMaxX(rect);
        hasPrevious = YES;
    }
}

+ (BOOL)needsSpaceBetween:(NSString *)previous
                  andNext:(NSString *)next
                      gap:(CGFloat)gap
                rowHeight:(CGFloat)rowHeight {
    if (previous.length == 0 || next.length == 0) {
        return NO;
    }
    unichar left = [previous characterAtIndex:previous.length - 1];
    unichar right = [next characterAtIndex:0];
    if (left == '\n') {
        return NO;
    }
    // Boxes are normalised, so the gap is a fraction of the image width. Compare
    // it against the row's own height, which is what makes it readable as "how
    // many characters wide is this gap".
    CGFloat unit = rowHeight > 0.0 ? rowHeight : 0.02;

    // Chinese and Japanese have no inter-word gaps, so a space here would be a
    // lie — 分词 would then treat the two halves as separate words. Only a gap
    // wide enough to be a column break counts.
    if ([self isCJK:left] || [self isCJK:right]) {
        return gap > unit * 0.5;
    }
    // Latin fragments: Vision usually ate the gap. Restore it unless the next
    // fragment starts with something that never follows a space.
    if ([self isPunctuation:right]) {
        return NO;
    }
    return gap > unit * 0.08;
}

+ (BOOL)isCJK:(unichar)character {
    if (character >= 0x3000 && character <= 0x303F) {
        return YES; // CJK punctuation
    }
    if (character >= 0x3040 && character <= 0x30FF) {
        return YES; // kana
    }
    if (character >= 0x3400 && character <= 0x4DBF) {
        return YES;
    }
    if (character >= 0x4E00 && character <= 0x9FFF) {
        return YES;
    }
    if (character >= 0xF900 && character <= 0xFAFF) {
        return YES;
    }
    if (character >= 0xFF00 && character <= 0xFFEF) {
        return YES; // fullwidth forms
    }
    return NO;
}

+ (BOOL)isPunctuation:(unichar)character {
    if (character < 0x80) {
        return ispunct((int)character) != 0 && character != '#' && character != '@';
    }
    return NO;
}

@end
