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
#import <roothide.h>

/// One line per recognition, rolled at 8 KB.
///
/// OCR quality is not something the user can describe ("认出来的字不对") and not
/// something that can be reproduced off-device, so the pass that won, its mean
/// confidence and how much CJK it produced are recorded. If Vision refuses the
/// Chinese model in SpringBoard, this file is the only place that shows it.
static NSString *const kKayokoOCRLogPath = @"/var/mobile/Library/com.82flex.kayoko/ocr.log";
static const unsigned long long kKayokoOCRLogLimit = 8192;

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

static NSString *const kKayokoRecognitionLanguageChinese = @"zh-Hans";
static NSString *const kKayokoRecognitionLanguageEnglish = @"en-US";

/// Raw values of `VNRequestTextRecognitionLevel`.
///
/// Accurate is **0** and fast is **1** — the opposite of what the names suggest,
/// and the opposite of what 4.3.15 through 4.3.18 assumed. Every pass therefore
/// ran at the fast level, and the fast level only ships English, Portuguese,
/// French, Italian, German and Spanish: assigning
/// `recognitionLanguages = @[@"zh-Hans"]` to a fast request is silently ignored
/// rather than rejected, the English model reads the picture, and Chinese comes
/// back as Latin approximations ("凡人修仙传" → "nAlI°ILtIl*") at high confidence.
///
/// The probe line in the OCR log was the dead giveaway: it listed exactly the six
/// fast-level languages. Tuning confidence thresholds and reading order could
/// never have helped, because the Chinese model was never asked to run.
static const NSInteger kKayokoRecognitionLevelAccurate = 0;
static const NSInteger kKayokoRecognitionLevelFast = 1;

/// Observations below this confidence are noise: a single misread glyph on a
/// busy background, or the residue of a gradient. Dropping them beats handing
/// the user a stray character to delete.
static const float kKayokoMinimumConfidence = 0.25f;

/// Quality at which a pass that actually produced Chinese counts as settled.
static const double kKayokoAcceptedQuality = 0.72;

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
- (void)setRevision:(NSUInteger)revision;
- (NSUInteger)revision;
- (NSInteger)recognitionLevel;
- (NSUInteger)currentRevision;
- (NSArray<NSString *> *)supportedRecognitionLanguagesForTextRecognitionLevel:(NSInteger)level
                                                                    revision:(NSUInteger)revision
                                                                       error:(NSError **)error;
- (BOOL)performRequests:(NSArray *)requests error:(NSError **)error;
- (NSArray *)results;
- (NSArray *)topCandidates:(NSUInteger)limit;
- (CGRect)boundingBox;
- (float)confidence;
- (NSString *)string;
@end

@interface KayokoTextRecognizer ()
+ (nullable NSString *)recognizeSynchronouslyAtPath:(NSString *)path;
+ (nullable UIImage *)preparedImage:(UIImage *)image;
+ (NSArray<NSDictionary<NSString *, id> *> *)recognitionAttempts;
+ (nullable NSArray *)observationsForImage:(CGImageRef)cgImage
                                correction:(BOOL)correction
                                 languages:(NSArray<NSString *> *)languages
                                     level:(NSInteger)level
                                 passIndex:(NSUInteger)passIndex
                               diagnostics:(NSMutableString *)diagnostics;
+ (nullable NSArray<NSDictionary<NSString *, id> *> *)boxesFromObservations:(NSArray *)observations;
+ (nullable NSString *)assembleTextFromBoxes:(NSArray<NSDictionary<NSString *, id> *> *)boxes;
+ (void)appendRow:(NSArray<NSDictionary<NSString *, id> *> *)row to:(NSMutableString *)result;
+ (BOOL)needsSpaceBetween:(NSString *)previous
                  andNext:(NSString *)next
                      gap:(CGFloat)gap
                rowHeight:(CGFloat)rowHeight;
@end

#pragma mark - Character classes

static BOOL KayokoCharIsCJK(unichar character) {
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

static BOOL KayokoCharIsPunctuation(unichar character) {
    if (character < 0x80) {
        return ispunct((int)character) != 0 && character != '#' && character != '@';
    }
    return NO;
}

/// How many CJK characters a result carries.
///
/// This is the signal that separates the two failure modes: an English-only
/// model reads Chinese glyphs as Latin approximations ("凡人修仙传" came back as
/// "nAlI°ILtIl*"), which produces a long string with almost no CJK in it. A pass
/// that returned CJK at all went through the Chinese model.
static NSUInteger KayokoCJKCount(NSString *text) {
    NSUInteger length = text.length;
    if (length == 0) {
        return 0;
    }
    NSUInteger count = 0;
    unichar *buffer = malloc(sizeof(unichar) * length);
    if (!buffer) {
        return 0;
    }
    [text getCharacters:buffer range:NSMakeRange(0, length)];
    for (NSUInteger index = 0; index < length; index++) {
        if (KayokoCharIsCJK(buffer[index])) {
            count++;
        }
    }
    free(buffer);
    return count;
}

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

static void KayokoOCRAppendLog(NSString *line) {
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      formatter = [[NSDateFormatter alloc] init];
      [formatter setDateFormat:@"HH:mm:ss"];
    });
    if (line.length == 0) {
        return;
    }

    NSString *path = jbroot(kKayokoOCRLogPath);
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *directory = [path stringByDeletingLastPathComponent];
    if (![fileManager fileExistsAtPath:directory]) {
        [fileManager createDirectoryAtPath:directory
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:nil];
    }
    NSData *existing = [fileManager contentsAtPath:path];
    if (existing.length > kKayokoOCRLogLimit) {
        [fileManager removeItemAtPath:path error:nil];
        existing = nil;
    }
    NSString *entry = [NSString stringWithFormat:@"%@ %@\n",
                                                 [formatter stringFromDate:[NSDate date]], line];
    NSMutableData *data = [NSMutableData dataWithData:existing ?: [NSData data]];
    [data appendData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
    [data writeToFile:path atomically:YES];
}

/// The revision the system considers current.
///
/// Set on every request explicitly, never left to the default. 4.3.19 relied on
/// "0 means whatever the system defaults to" and every pass came back with zero
/// observations — which is what a request pinned to revision 1 would look like on
/// iOS 16, since revision 1 only ships the English model. Probing one revision and
/// performing another is exactly the kind of mismatch that produces silence
/// instead of an error, so the value is now read from the system, applied, and
/// read back into the log.
static NSUInteger KayokoCurrentRecognitionRevision(void) {
    static dispatch_once_t onceToken;
    static NSUInteger revision = 0;
    dispatch_once(&onceToken, ^{
      Class requestClass = NSClassFromString(@"VNRecognizeTextRequest");
      if (requestClass && [(id)requestClass respondsToSelector:@selector(currentRevision)]) {
          revision = [(id)requestClass currentRevision];
      }
    });
    return revision;
}

/// Records what Vision claims to support, once per process.
///
/// Both levels are written because the pair is the whole diagnosis: accurate
/// listing zh-Hans means the model is there; a fast list of six Latin languages
/// and nothing else means the request was built at the wrong level. 4.3.18 logged
/// a single line and it was read as "this device has no Chinese", which sent the
/// fix toward the model instead of toward the enum.
static void KayokoLogSupportedLanguages(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      Class requestClass = NSClassFromString(@"VNRecognizeTextRequest");
      if (!requestClass) {
          return;
      }
      NSUInteger revision = KayokoCurrentRecognitionRevision();
      SEL probe = @selector(supportedRecognitionLanguagesForTextRecognitionLevel:revision:error:);
      if (![(id)requestClass respondsToSelector:probe]) {
          KayokoOCRAppendLog([NSString stringWithFormat:@"supported r%lu = (probe missing)",
                                                                (unsigned long)revision]);
          return;
      }
      NSArray<NSNumber *> *levels = @[
          @(kKayokoRecognitionLevelAccurate),
          @(kKayokoRecognitionLevelFast),
      ];
      for (NSNumber *level in levels) {
          NSError *error = nil;
          NSArray *supported =
              [(id)requestClass supportedRecognitionLanguagesForTextRecognitionLevel:level.integerValue
                                                                           revision:revision
                                                                              error:&error];
          NSString *name = level.integerValue == kKayokoRecognitionLevelAccurate ? @"accurate" : @"fast";
          KayokoOCRAppendLog([NSString stringWithFormat:@"supported r%lu %@ = %@",
                                                        (unsigned long)revision,
                                                        name,
                                                        [supported componentsJoinedByString:@","]
                                                            ?: @"(query failed)"]);
      }
    });
}

/// Whether the accurate level advertises the Chinese model.
///
/// Nothing else in this file can tell the two failures apart by looking at the
/// output: an unsupported language is not an error, Vision just keeps its
/// default and returns confident Latin. Recorded so a bad run is explainable
/// from the device, and so the per-pass log line can be read honestly.
static BOOL KayokoAccurateLevelSupportsChinese(void) {
    static dispatch_once_t onceToken;
    static BOOL supported = NO;
    dispatch_once(&onceToken, ^{
      Class requestClass = NSClassFromString(@"VNRecognizeTextRequest");
      SEL probe = @selector(supportedRecognitionLanguagesForTextRecognitionLevel:revision:error:);
      if (!requestClass || ![(id)requestClass respondsToSelector:probe]) {
          return;
      }
      NSUInteger revision = KayokoCurrentRecognitionRevision();
      NSArray *list =
          [(id)requestClass supportedRecognitionLanguagesForTextRecognitionLevel:kKayokoRecognitionLevelAccurate
                                                                       revision:revision
                                                                          error:NULL];
      supported = [list containsObject:kKayokoRecognitionLanguageChinese];
    });
    return supported;
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

/// Tried in order, stopping as soon as a pass is good enough.
///
/// The single-language passes are not redundant with the two-language one. When
/// a request lists more than one language, Vision picks one for the whole image
/// based on the dominant script — on a chat screenshot full of timestamps, app
/// names and English UI it picked English, and then read every Chinese glyph as
/// the nearest Latin approximation. Forcing zh-Hans alone removes the choice:
/// that model also reads Latin text, so mixed screenshots still come out whole.
///
/// No attempt carries a revision any more: every pass runs at the revision the
/// system reports as current (see `KayokoCurrentRecognitionRevision`). The
/// revision-2 fallback is gone as well — 4.3.19's silence came from probing one
/// revision and performing another, so a second revision is the last thing worth
/// trying, not the first.
///
/// The trailing fast pass is a probe, not a fallback. 4.3.19 handed accurate the
/// same image, the same handler and the same languages and got zero observations
/// on all five passes, while 4.3.18's fast request read hundreds of characters
/// off the very same picture. Repeating that request at the fast level separates
/// "the accurate engine refuses to run here" from "the image never reached
/// Vision", which are two completely different bugs. Its result is logged and
/// thrown away: Latin soup is exactly what this feature is being fixed to stop
/// producing.
+ (NSArray<NSDictionary<NSString *, id> *> *)recognitionAttempts {
    return @[
        @{@"languages" : @[ kKayokoRecognitionLanguageChinese ],
          @"correction" : @YES,
          @"level" : @(kKayokoRecognitionLevelAccurate)},
        @{@"languages" : @[ kKayokoRecognitionLanguageChinese ],
          @"correction" : @NO,
          @"level" : @(kKayokoRecognitionLevelAccurate)},
        @{@"languages" : @[ kKayokoRecognitionLanguageChinese, kKayokoRecognitionLanguageEnglish ],
          @"correction" : @YES,
          @"level" : @(kKayokoRecognitionLevelAccurate)},
        @{@"languages" : @[ kKayokoRecognitionLanguageEnglish ],
          @"correction" : @YES,
          @"level" : @(kKayokoRecognitionLevelAccurate)},
        @{@"languages" : @[ kKayokoRecognitionLanguageEnglish ],
          @"correction" : @YES,
          @"level" : @(kKayokoRecognitionLevelFast),
          @"diagnosticOnly" : @YES},
    ];
}

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
    KayokoLogSupportedLanguages();
    NSString *bestText = nil;
    double bestQuality = -1.0;
    BOOL bestHasCJK = NO;
    NSString *bestPass = nil;

    NSUInteger passIndex = 0;
    for (NSDictionary<NSString *, id> *attempt in [self recognitionAttempts]) {
        passIndex++;
        NSArray<NSString *> *languages = attempt[@"languages"];
        BOOL correction = [attempt[@"correction"] boolValue];
        NSInteger level = attempt[@"level"]
                              ? [attempt[@"level"] integerValue]
                              : kKayokoRecognitionLevelAccurate;
        BOOL diagnosticOnly = [attempt[@"diagnosticOnly"] boolValue];
        NSMutableString *diagnostics = [NSMutableString string];
        NSArray *observations = [self observationsForImage:cgImage
                                                correction:correction
                                                 languages:languages
                                                     level:level
                                                 passIndex:passIndex
                                               diagnostics:diagnostics];
        NSArray<NSDictionary<NSString *, id> *> *boxes = [self boxesFromObservations:observations];
        NSString *text = [self assembleTextFromBoxes:boxes];
        double quality = KayokoQualityForBoxes(boxes);
        NSUInteger cjk = KayokoCJKCount(text);
        NSString *label = [NSString stringWithFormat:@"%@%@",
                                                    [languages componentsJoinedByString:@"+"],
                                                    correction ? @"" : @"-nc"];
        NSLog(@"Kayoko: OCR pass %@ quality=%.2f cjk=%lu chars=%lu", label, quality,
              (unsigned long)cjk, (unsigned long)text.length);
        // One line per pass, written even when the pass produced nothing: an empty
        // result is the interesting case, and until now it was the one case the
        // log could not describe.
        [diagnostics appendFormat:@" box=%lu text=%lu t=%.0fms%@",
                                  (unsigned long)boxes.count,
                                  (unsigned long)text.length,
                                  [[NSDate date] timeIntervalSinceDate:startedAt] * 1000.0,
                                  diagnosticOnly ? @" probe=discarded" : @""];
        KayokoOCRAppendLog(diagnostics);

        if (diagnosticOnly) {
            continue;
        }

        BOOL hasCJK = cjk > 0;
        BOOL better = NO;
        if (text.length > 0) {
            if (bestText == nil) {
                better = YES;
            } else if (hasCJK != bestHasCJK) {
                // Any CJK at all beats a longer Latin-only reading: it means the
                // Chinese model handled the image instead of the English one
                // guessing at every glyph.
                better = hasCJK;
            } else {
                better = quality > bestQuality + 0.02;
            }
        }
        if (better) {
            bestText = text;
            bestQuality = quality;
            bestHasCJK = hasCJK;
            bestPass = label;
        }

        if (bestHasCJK && bestQuality >= kKayokoAcceptedQuality) {
            break;
        }
        // A very confident Latin-only reading is a genuinely Latin picture; no
        // further pass will improve on it.
        if (!bestHasCJK && bestQuality >= 0.90 && bestText.length > 0) {
            break;
        }
    }

    NSLog(@"Kayoko: OCR %@ in %.0f ms, %lu chars, quality %.2f, from %@",
          bestText.length > 0 ? @"ok" : @"empty",
          [[NSDate date] timeIntervalSinceDate:startedAt] * 1000.0,
          (unsigned long)bestText.length, bestQuality, bestPass ?: @"nothing");
    KayokoOCRAppendLog([NSString stringWithFormat:@"pass=%@ lvl=acc q=%.2f cjk=%lu chars=%lu ms=%.0f",
                                                  bestPass ?: @"nothing", bestQuality,
                                                  (unsigned long)KayokoCJKCount(bestText),
                                                  (unsigned long)bestText.length,
                                                  [[NSDate date] timeIntervalSinceDate:startedAt] * 1000.0]);
    return bestText;
}

/// Runs one recognition pass and returns the raw observations.
///
/// Level `accurate` (raw value 0), not `fast` (raw value 1). This is the whole
/// bug that survived four releases: fast has no Chinese model, and asking it for
/// one fails silently. Accurate costs a few hundred extra milliseconds on a phone
/// screenshot, which is invisible next to the round trip through the panel.
///
/// Everything the engine was actually configured with is formatted into
/// `diagnostics` rather than assumed: 4.3.19 asked for revision 3 in the probe,
/// performed revision 3 by accident-or-not, and returned zero observations on
/// five consecutive passes with nothing in the log to say which of those was
/// true. Reading the values back is the only way to tell "the request was built
/// wrong" from "the engine refused".
+ (nullable NSArray *)observationsForImage:(CGImageRef)cgImage
                                correction:(BOOL)correction
                                 languages:(NSArray<NSString *> *)languages
                                     level:(NSInteger)level
                                 passIndex:(NSUInteger)passIndex
                               diagnostics:(NSMutableString *)diagnostics {
    Class handlerClass = NSClassFromString(@"VNImageRequestHandler");
    Class requestClass = NSClassFromString(@"VNRecognizeTextRequest");
    if (!handlerClass || !requestClass) {
        [diagnostics appendFormat:@"p%lu req=CLASS-MISSING",
                                  (unsigned long)passIndex];
        return nil;
    }

    id handler = [(id)handlerClass alloc];
    handler = [handler initWithCGImage:cgImage options:@{}];
    id request = [[(id)requestClass alloc] init];
    [request setRecognitionLevel:level];
    NSUInteger revision = KayokoCurrentRecognitionRevision();
    if (revision > 0) {
        [request setRevision:revision];
    }
    [request setRecognitionLanguages:languages];
    [request setUsesLanguageCorrection:correction];

    NSUInteger appliedRevision = [(id)request respondsToSelector:@selector(revision)]
                                     ? (NSUInteger)[request revision]
                                     : 0;
    NSInteger appliedLevel = [(id)request respondsToSelector:@selector(recognitionLevel)]
                                 ? (NSInteger)[request recognitionLevel]
                                 : -1;
    [diagnostics appendFormat:@"p%lu %@ rev%lu lvl=%ld corr=%d",
                              (unsigned long)passIndex,
                              [languages componentsJoinedByString:@"+"],
                              (unsigned long)appliedRevision,
                              (long)appliedLevel,
                              correction ? 1 : 0];

    if ([languages containsObject:kKayokoRecognitionLanguageChinese]) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
          if (KayokoAccurateLevelSupportsChinese()) {
              return;
          }
          NSLog(@"Kayoko: Vision has no zh-Hans model at the accurate level — "
                @"this pass can only return Latin");
          KayokoOCRAppendLog(@"warning: zh-Hans missing from accurate level");
        });
    }

    NSError *error = nil;
    if (![handler performRequests:@[ request ] error:&error]) {
        NSString *reason = error.localizedDescription ?: @"unknown error";
        // Newlines would split one pass across several log lines.
        reason = [reason stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        NSLog(@"Kayoko: OCR failed — %@", reason);
        [diagnostics appendFormat:@" req=FAIL err=%@", reason];
        return nil;
    }
    NSArray *results = [request results];
    [diagnostics appendFormat:@" req=OK obs=%lu", (unsigned long)results.count];
    return results;
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
    if (KayokoCharIsCJK(left) || KayokoCharIsCJK(right)) {
        return gap > unit * 0.5;
    }
    // Latin fragments: Vision usually ate the gap. Restore it unless the next
    // fragment starts with something that never follows a space.
    if (KayokoCharIsPunctuation(right)) {
        return NO;
    }
    return gap > unit * 0.08;
}

@end
