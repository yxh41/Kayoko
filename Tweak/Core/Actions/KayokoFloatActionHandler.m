//
//  KayokoFloatActionHandler.m
//  Kayoko
//

#import "KayokoFloatActionHandler.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <roothide.h>
#import <math.h>
#import <string.h>

#import "KayokoPasteboardItem.h"
#import "KayokoPasteboardManager.h"
#import "KayokoPreferenceKeys.h"

/// ShellX's own integration notes name this class as the way to detect it.
static NSString *const kKayokoShellXPluginManagerClassName = @"SHELLXPluginManager";

/// ShellX's floating-image manager, read out of ScreenshotShell.dylib. It is a
/// singleton behind the *class* method `+shared`, and it declares
/// `-showFloatingImage:frame:` with a `v56@0:8@16{CGRect}24` signature.
///
/// Calling it works, but the window it builds has no lifecycle of its own when
/// it is summoned from SpringBoard while a swipe action is unwinding: the float
/// appears and then the whole UI stops taking touches. The inbox below is the
/// channel ShellX actually provides for other processes, so that one is used
/// instead and this class is only named for the availability check.
static NSString *const kKayokoShellXFloatingManagerClassName = @"SSFloatingManager";

/// Where another process hands ShellX an image to float. ShellX picks the file
/// up itself, which keeps the window inside its own lifecycle.
static NSString *const kKayokoShellXClipImageNotification = @"com.iosdump.screenshotshell.clipimg";

/// The window that manager builds, used only to observe whether one is visible.
static NSString *const kKayokoShellXFloatingWindowClassName = @"SSFloatingWindow";

/// Snapper 3's plugin manager, from its published extension API.
static NSString *const kKayokoSnapper3PluginManagerClassName = @"Snapper3PluginManager";

/// Snapper 3's floating window. It has no singleton, but it is a UIWindow, so it
/// can be found by walking the application's window list.
static NSString *const kKayokoSnapper3WindowClassName = @"SnapperWindow";

/// The selector CopyVault probes for to recognise Snapper's window, and calls to
/// float a picture. Taking a rect in the image's own coordinates is what makes
/// this exact instead of "whatever happened to be newest".
static NSString *const kKayokoSnapper3SnapRectSelectorName = @"wantsToSnapRect:inImage:";

/// ShellX floats the newest entry of its own history when this is posted.
static NSString *const kKayokoShellXOpenLastNotification = @"com.iosdump.screenshotshell.openlast";

/// Snapper 3's equivalent.
static NSString *const kKayokoSnapper3OpenLastNotification = @"com.jontelang.snapper3.openlast";

static NSString *const kKayokoFloatLogPath = @"/var/mobile/Library/com.82flex.kayoko/float.log";

@interface KayokoFloatActionHandler ()

+ (NSUserDefaults *)preferences;
+ (nullable NSString *)historyDirectoryForTarget:(KayokoFloatTarget)target;
+ (nullable NSString *)shellXHistoryDirectory;
+ (BOOL)directoryLooksLikeImageStore:(NSString *)directory;
+ (BOOL)writeImage:(UIImage *)image toDirectory:(NSString *)directory;
+ (void)postDarwinNotification:(NSString *)notificationName;
+ (CGRect)floatingFrameForImage:(UIImage *)image;

+ (BOOL)floatWithShellXInMemory:(UIImage *)image;
+ (BOOL)floatWithSnapper3InMemory:(UIImage *)image;

+ (NSArray<UIWindow *> *)applicationWindows;
+ (nullable UIWindowScene *)activeWindowScene;
+ (nullable id)sharedInstanceOfClass:(Class)classObject selectorName:(NSString *)selectorName;
+ (nullable id)snapper3WindowInWindows:(NSArray<UIWindow *> *)windows windowClass:(Class)windowClass;
+ (NSUInteger)visibleFloatingWindowCount;

+ (BOOL)isFloatingWindow:(UIWindow *)window;
+ (nullable UIWindow *)keyWindowInWindows:(NSArray<UIWindow *> *)windows excludingFloating:(BOOL)excludingFloating;
+ (BOOL)windowCanBecomeKey:(UIWindow *)window;
+ (BOOL)restoreKeyWindow:(UIWindow *)window;
+ (nullable UIWindow *)primaryWindowInWindows:(NSArray<UIWindow *> *)windows;
+ (nullable UIWindow *)ensureKeyWindow:(UIWindow *)preferred;
+ (nullable NSString *)keyWindowDescriptionInWindows:(NSArray<UIWindow *> *)windows;
+ (nullable NSString *)floatingWindowDescriptionInWindows:(NSArray<UIWindow *> *)windows;

+ (NSArray<UIView *> *)snapViewsInWindow:(UIWindow *)window;
+ (nullable UIView *)snapViewAddedSince:(NSArray<UIView *> *)existing inWindow:(UIWindow *)window;
+ (BOOL)centerNewestSnapInWindow:(UIWindow *)window
                           image:(UIImage *)image
                        existing:(NSArray<UIView *> *)existing
                         attempt:(NSUInteger)attempt;
+ (BOOL)centerNewestSnapInWindow:(UIWindow *)window image:(UIImage *)image existing:(NSArray<UIView *> *)existing;

+ (nullable id)valueForKey:(NSString *)key onTarget:(id)target;
+ (NSUInteger)countForKey:(NSString *)key onTarget:(id)target;
+ (BOOL)boolForKey:(NSString *)key onTarget:(id)target;

+ (BOOL)invokeRectSelector:(SEL)selector onTarget:(id)target image:(UIImage *)image rect:(CGRect)rect;
+ (BOOL)invokeRectCenterSelector:(SEL)selector
                        onTarget:(id)target
                           image:(UIImage *)image
                            rect:(CGRect)rect
                          center:(CGPoint)center;
+ (BOOL)invokePointSelector:(SEL)selector onTarget:(id)target point:(CGPoint)point;
+ (NSUInteger)argumentCountForSelector:(SEL)selector;
+ (nullable NSString *)signatureDescriptionForSelector:(SEL)selector onTarget:(id)target;
+ (void)fallBackToHistoryWithImage:(UIImage *)image target:(KayokoFloatTarget)target;
+ (BOOL)isCGRectArgumentType:(const char *)argumentType;
+ (BOOL)isCGPointArgumentType:(const char *)argumentType;

+ (nullable UIImage *)imageFromText:(NSString *)text;

@end

/// One line per attempt, appended to a file. Counting properties only tell us
/// that a call was accepted, not that anything appeared; when neither is
/// conclusive this log is the difference between guessing and knowing.
static void KayokoFloatLog(NSString *step, NSString *detail) {
    NSString *path = jbroot(kKayokoFloatLogPath);
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *directory = [path stringByDeletingLastPathComponent];
    if (![fileManager fileExistsAtPath:directory]) {
        [fileManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    }

    NSDictionary *attributes = [fileManager attributesOfItemAtPath:path error:nil];
    if ([attributes fileSize] > 24 * 1024) {
        [fileManager removeItemAtPath:path error:nil];
    }

    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"MM-dd HH:mm:ss.SSS";
    });

    NSString *line = [NSString stringWithFormat:@"%@ %@ | %@\n",
                                                [formatter stringFromDate:[NSDate date]], step, detail ?: @""];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (![fileManager fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    [handle seekToEndOfFile];
    [handle writeData:data];
    [handle closeFile];
}

@implementation KayokoFloatActionHandler

#pragma mark - Preferences

+ (NSUserDefaults *)preferences {
    NSUserDefaults *preferences = [[NSUserDefaults alloc] initWithSuiteName:kKayokoPreferencesIdentifier];
    [preferences registerDefaults:@{
        kKayokoPreferenceKeyFloatAction : @(kKayokoPreferenceKeyFloatActionDefaultValue),
        kKayokoPreferenceKeyFloatTarget : @(kKayokoPreferenceKeyFloatTargetDefaultValue),
    }];
    return preferences;
}

+ (BOOL)isEnabled {
    return [[self preferences] boolForKey:kKayokoPreferenceKeyFloatAction];
}

+ (KayokoFloatTarget)target {
    NSInteger value = [[self preferences] integerForKey:kKayokoPreferenceKeyFloatTarget];
    if (value != KayokoFloatTargetShellX && value != KayokoFloatTargetSnapper3) {
        return (KayokoFloatTarget)kKayokoPreferenceKeyFloatTargetDefaultValue;
    }
    return (KayokoFloatTarget)value;
}

/// The floating class is what actually gets called, so it is the honest test.
/// The documented plugin manager is accepted as a secondary signal so a future
/// host build that renames the internal class still shows the button.
+ (BOOL)isHostInstalled:(KayokoFloatTarget)target {
    NSArray<NSString *> *classNames = target == KayokoFloatTargetShellX
                                          ? @[ kKayokoShellXFloatingManagerClassName, kKayokoShellXPluginManagerClassName ]
                                          : @[ kKayokoSnapper3WindowClassName, kKayokoSnapper3PluginManagerClassName ];

    for (NSString *className in classNames) {
        if (objc_getClass([className UTF8String]) != NULL) {
            return YES;
        }
    }

    return NO;
}

/// Availability no longer depends on the host's history folder: both hosts are
/// now driven through an in-memory call, and the folder is only the last-ditch
/// fallback.
+ (BOOL)isAvailable {
    if (![self isEnabled]) {
        return NO;
    }

    return [self isHostInstalled:[self target]];
}

#pragma mark - Item to image

+ (nullable UIImage *)imageForItem:(KayokoPasteboardItem *)item {
    if (!item) {
        return nil;
    }

    if ([[item imageName] length] > 0) {
        NSString *filePath = [NSString stringWithFormat:@"%@/%@", [KayokoPasteboardManager historyImagesPath],
                                                       [item imageName]];
        UIImage *image = [UIImage imageWithContentsOfFile:filePath];
        if (image) {
            return image;
        }
    }

    NSString *content = [item content];
    if ([content length] == 0) {
        return nil;
    }

    return [self imageFromText:content];
}

/// Draws a text clip into an image so a text item can float just like a picture.
///
/// The type size scales with the length of the clip: short notes get a big,
/// readable card, long articles shrink to something that still fits a third of
/// the screen. Colours are the dynamic system ones, so the card follows the
/// system appearance it is drawn in.
+ (nullable UIImage *)imageFromText:(NSString *)text {
    if ([text length] == 0) {
        return nil;
    }

    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    CGFloat maximumWidth = MAX(240.0, MIN(screenSize.width * 0.72, 560.0));

    NSUInteger length = [text length];
    CGFloat fontSize = 26.0;
    if (length > 40) {
        fontSize = 21.0;
    }
    if (length > 120) {
        fontSize = 17.0;
    }
    if (length > 400) {
        fontSize = 13.0;
    }

    UIFont *font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightRegular];
    NSDictionary *attributes = @{NSFontAttributeName : font};

    CGSize textSize = [text boundingRectWithSize:CGSizeMake(maximumWidth, CGFLOAT_MAX)
                                         options:NSStringDrawingUsesLineFragmentOrigin
                                      attributes:attributes
                                         context:nil].size;

    CGFloat padding = 16.0;
    CGSize size = CGSizeMake(ceil(textSize.width) + padding * 2, ceil(textSize.height) + padding * 2);
    if (size.width < 160.0) {
        size.width = 160.0;
    }

    UIGraphicsBeginImageContextWithOptions(size, YES, 0.0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(context, [UIColor systemBackgroundColor].CGColor);
    CGContextFillRect(context, CGRectMake(0, 0, size.width, size.height));

    NSDictionary *drawAttributes = @{
        NSFontAttributeName : font,
        NSForegroundColorAttributeName : [UIColor labelColor],
    };
    [text drawWithRect:CGRectMake(padding, padding, ceil(textSize.width), ceil(textSize.height))
               options:NSStringDrawingUsesLineFragmentOrigin
            attributes:drawAttributes
               context:nil];

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

#pragma mark - Dispatch

+ (void)floatItem:(KayokoPasteboardItem *)item {
    UIImage *image = [self imageForItem:item];
    if (!image) {
        KayokoFloatLog(@"float", @"no image for item");
        return;
    }

    KayokoFloatTarget target = [self target];

    if (target == KayokoFloatTargetSnapper3) {
        // Both hosts can be handed the UIImage itself, which is the only way to
        // end up with exactly the tapped item.
        if ([self floatWithSnapper3InMemory:image]) {
            return;
        }

        [self fallBackToHistoryWithImage:image target:target];
        return;
    }

    // ShellX builds a window of its own, and asking it to do that synchronously
    // from inside a swipe action leaves SpringBoard mid-gesture and mid-dismissal.
    // One clean runloop turn later there is nothing left to unwind.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([self floatWithShellXInMemory:image]) {
            return;
        }

        [self fallBackToHistoryWithImage:image target:KayokoFloatTargetShellX];
    });
}

/// Last resort: drop the picture into the host's history folder and ask it to
/// reopen "the last one". That is a date comparison rather than a direct
/// hand-off, so it is only reached when the in-memory call was unavailable.
+ (void)fallBackToHistoryWithImage:(UIImage *)image target:(KayokoFloatTarget)target {
    NSString *directory = [self historyDirectoryForTarget:target];
    if ([directory length] == 0) {
        KayokoFloatLog(@"fallback", @"no history directory");
        return;
    }

    // ShellX's folder is discovered by name, so only write once it has proved
    // itself by already holding pictures; otherwise a name collision could drop
    // a PNG into an unrelated Library directory.
    if (target == KayokoFloatTargetShellX && ![self directoryLooksLikeImageStore:directory]) {
        KayokoFloatLog(@"fallback", [NSString stringWithFormat:@"%@ holds no images", directory]);
        return;
    }

    if (![self writeImage:image toDirectory:directory]) {
        KayokoFloatLog(@"fallback", @"write failed");
        return;
    }

    NSString *notificationName = target == KayokoFloatTargetShellX ? kKayokoShellXOpenLastNotification
                                                                  : kKayokoSnapper3OpenLastNotification;
    [self postDarwinNotification:notificationName];
    KayokoFloatLog(@"fallback", [NSString stringWithFormat:@"posted %@", notificationName]);
}

/// Shared sizing: about two thirds of the screen, centred, never upscaled.
+ (CGRect)floatingFrameForImage:(UIImage *)image {
    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    if (image.size.width < 1.0 || image.size.height < 1.0) {
        return CGRectMake(screenSize.width * 0.25, screenSize.height * 0.35, screenSize.width * 0.5,
                          screenSize.width * 0.5);
    }

    CGFloat scale = MIN(1.0, MIN(screenSize.width * 0.68 / image.size.width,
                                 screenSize.height * 0.55 / image.size.height));
    CGSize size = CGSizeMake(ceil(image.size.width * scale), ceil(image.size.height * scale));
    return CGRectMake(ceil((screenSize.width - size.width) * 0.5), ceil((screenSize.height - size.height) * 0.5),
                      size.width, size.height);
}

#pragma mark - History folders

/// Snapper 3's folder is known from its binary. ShellX does not publish one, so
/// a short list of likely names is probed and then the whole Library directory
/// is scanned for anything that looks like its image store. The result is
/// cached: a wrong guess would only cost one respring, and scanning
/// `/var/mobile/Library` on every swipe would be wasteful.
+ (nullable NSString *)historyDirectoryForTarget:(KayokoFloatTarget)target {
    if (target == KayokoFloatTargetSnapper3) {
        return jbroot(@"/var/mobile/Library/Snapper3/Images/");
    }

    return [self shellXHistoryDirectory];
}

+ (nullable NSString *)shellXHistoryDirectory {
    static NSString *cachedDirectory = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSFileManager *fileManager = [NSFileManager defaultManager];

        NSArray<NSString *> *candidates = @[
            jbroot(@"/var/mobile/Library/com.iosdump.screenshotshell/"),
            jbroot(@"/var/mobile/Library/ScreenshotShell/"),
            jbroot(@"/var/mobile/Library/ScreenshotsShell/"),
            jbroot(@"/var/mobile/Library/screenshotshell/"),
        ];
        for (NSString *candidate in candidates) {
            BOOL isDirectory = NO;
            if ([fileManager fileExistsAtPath:candidate isDirectory:&isDirectory] && isDirectory) {
                cachedDirectory = [candidate copy];
                return;
            }
        }

        NSString *libraryPath = jbroot(@"/var/mobile/Library/");
        for (NSString *entry in [fileManager contentsOfDirectoryAtPath:libraryPath error:nil]) {
            NSString *lowercased = [entry lowercaseString];
            if (![lowercased containsString:@"screenshot"] && ![lowercased containsString:@"shell"]) {
                continue;
            }

            NSString *fullPath = [libraryPath stringByAppendingPathComponent:entry];
            BOOL isDirectory = NO;
            if (![fileManager fileExistsAtPath:fullPath isDirectory:&isDirectory] || !isDirectory) {
                continue;
            }

            cachedDirectory = [fullPath copy];
            return;
        }
    });

    return cachedDirectory;
}

/// Only write into a folder that already holds pictures: that is what keeps a
/// name collision from dropping a PNG into an unrelated preferences directory.
+ (BOOL)directoryLooksLikeImageStore:(NSString *)directory {
    if ([directory length] == 0) {
        return NO;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *entry in [fileManager contentsOfDirectoryAtPath:directory error:nil]) {
        if ([[entry pathExtension] isEqualToString:@"png"] || [[entry pathExtension] isEqualToString:@"jpg"] ||
            [[entry pathExtension] isEqualToString:@"jpeg"]) {
            return YES;
        }
    }

    return NO;
}

+ (BOOL)writeImage:(UIImage *)image toDirectory:(NSString *)directory {
    if ([directory length] == 0) {
        return NO;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:directory]) {
        [fileManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    }

    NSString *fileName = [NSString stringWithFormat:@"kayoko-%@.png", [NSUUID UUID].UUIDString];
    NSString *filePath = [directory stringByAppendingPathComponent:fileName];
    NSData *data = UIImagePNGRepresentation(image);
    if (![data writeToFile:filePath atomically:YES]) {
        return NO;
    }

    // The host floats "the last one", which is a date comparison, so the new
    // file has to be the newest thing in the folder by a clear margin.
    [[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate : [NSDate date]}
                                    ofItemAtPath:filePath
                                           error:nil];
    return YES;
}

+ (void)postDarwinNotification:(NSString *)notificationName {
    if ([notificationName length] == 0) {
        return;
    }

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)notificationName, NULL, NULL, YES);
}

#pragma mark - ShellX in-memory hand-off

/// `SSFloatingManager` is a singleton behind the *class* method `+shared`. That
/// detail is easy to miss: a fresh `alloc/init` leaves `_floatingWindows` empty,
/// so `-showFloatingImage:frame:` runs against a manager that keeps no record of
/// the window and the picture never shows up.
///
/// The key window is the other trap. `SSFloatingWindow` overrides both
/// `-canBecomeKeyWindow` and `-_canBecomeKeyWindow`, and the manager raises the
/// new window with `-makeKeyAndVisible`; ShellX gets away with it because its
/// own flow always ends by closing the float, and closing it is what hands key
/// back. We never close it, so key would stay with a small window that has no
/// business routing touches, the screen would still draw but stop responding,
/// and only a respring would clear it. Taking key back right after the call is
/// therefore not cosmetic - it is the difference between "floats an image" and
/// "freezes the device".
+ (BOOL)floatWithShellXInMemory:(UIImage *)image {
    Class managerClass = objc_getClass([kKayokoShellXFloatingManagerClassName UTF8String]);
    if (!managerClass) {
        KayokoFloatLog(@"shellx", @"SSFloatingManager missing");
        return NO;
    }

    id manager = [self sharedInstanceOfClass:managerClass selectorName:@"shared"];
    if (!manager) {
        KayokoFloatLog(@"shellx", @"+shared returned nil");
        return NO;
    }

    NSArray<UIWindow *> *windowsBefore = [self applicationWindows];
    NSString *keyBefore = [self keyWindowDescriptionInWindows:windowsBefore];
    UIWindow *keyWindowBefore = [self keyWindowInWindows:windowsBefore excludingFloating:YES];

    NSUInteger beforeCount = [self countForKey:@"floatingWindows" onTarget:manager];
    NSUInteger visibleBefore = [self visibleFloatingWindowCount];
    CGRect frame = [self floatingFrameForImage:image];

    BOOL invoked = [self invokeRectSelector:NSSelectorFromString(@"showFloatingImage:frame:")
                                   onTarget:manager
                                      image:image
                                       rect:frame];
    if (!invoked) {
        invoked = [self invokeRectSelector:NSSelectorFromString(@"showFloatingImage:fromRect:")
                                  onTarget:manager
                                     image:image
                                      rect:frame];
    }

    // Read the float's state before handing key back, otherwise the interesting
    // part - whether it took key at all - is already gone by the time we log.
    NSString *floatDescription = [self floatingWindowDescriptionInWindows:[self applicationWindows]];

    // Twice: `-makeKeyAndVisible` is synchronous inside the manager, so the
    // first call is the one that matters, but ShellX also re-raises the window
    // from a `dispatch_async` in some builds. The second call is a no-op once
    // key is already back where it belongs.
    [self ensureKeyWindow:keyWindowBefore];
    UIWindow *keyWindowArgument = keyWindowBefore;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self ensureKeyWindow:keyWindowArgument];
    });

    NSUInteger afterCount = [self countForKey:@"floatingWindows" onTarget:manager];
    NSUInteger visibleAfter = [self visibleFloatingWindowCount];
    NSString *keyAfter = [self keyWindowDescriptionInWindows:[self applicationWindows]];
    KayokoFloatLog(@"shellx",
                   [NSString stringWithFormat:@"%@ invoked=%d windows %lu->%lu visible %lu->%lu frame=%@ key %@->%@ "
                                              @"float=%@",
                                              NSStringFromClass([manager class]), invoked,
                                              (unsigned long)beforeCount, (unsigned long)afterCount,
                                              (unsigned long)visibleBefore, (unsigned long)visibleAfter,
                                              NSStringFromCGRect(frame), keyBefore, keyAfter, floatDescription]);

    return afterCount > beforeCount || visibleAfter > visibleBefore;
}

#pragma mark - Snapper 3 in-memory hand-off

/// Snapper 3 has no singleton, so its window is found by walking the
/// application's window list and matching either the class name or - exactly
/// what CopyVault does - the `-wantsToSnapRect:inImage:` selector.
///
/// That selector is then the call: "snap this rect inside this image". Passing
/// the image's own bounds means the whole picture comes back, which is the
/// direct hand-off the history folder can never give.
+ (BOOL)floatWithSnapper3InMemory:(UIImage *)image {
    Class windowClass = objc_getClass([kKayokoSnapper3WindowClassName UTF8String]);
    NSArray<UIWindow *> *windows = [self applicationWindows];
    id window = [self snapper3WindowInWindows:windows windowClass:windowClass];
    if (!window) {
        KayokoFloatLog(@"snapper", [NSString stringWithFormat:@"no window among %lu", (unsigned long)[windows count]]);
        return NO;
    }

    NSUInteger snapsBefore = [self countForKey:@"snapsOverlay.numberOfSnaps" onTarget:window];
    BOOL showingBefore = [self boolForKey:@"hasSnapsShowing" onTarget:window];
    BOOL croppingBefore = [self boolForKey:@"isCropping" onTarget:window];
    NSArray<UIView *> *existingSnapViews = [self snapViewsInWindow:window];

    CGRect imageBounds = CGRectMake(0, 0, image.size.width, image.size.height);
    BOOL invoked = [self invokeRectSelector:NSSelectorFromString(kKayokoSnapper3SnapRectSelectorName)
                                   onTarget:window
                                      image:image
                                       rect:imageBounds];

    NSUInteger snapsAfter = [self countForKey:@"snapsOverlay.numberOfSnaps" onTarget:window];
    BOOL showingAfter = [self boolForKey:@"hasSnapsShowing" onTarget:window];
    BOOL croppingAfter = [self boolForKey:@"isCropping" onTarget:window];
    KayokoFloatLog(@"snapper",
                   [NSString stringWithFormat:@"%@ invoked=%d snaps %lu->%lu showing %d->%d cropping %d->%d",
                                              NSStringFromClass([window class]), invoked,
                                              (unsigned long)snapsBefore, (unsigned long)snapsAfter, showingBefore,
                                              showingAfter, croppingBefore, croppingAfter]);

    if (invoked && (snapsAfter > snapsBefore || (!showingBefore && showingAfter) || (!croppingBefore && croppingAfter))) {
        // Which pixels and where they land are two separate decisions in
        // Snapper: the rect only picks the pixels, the position comes from its
        // own cascade counter (`santaCount`), so a new snap shows up wherever
        // the previous ones left off. Put it on the centre explicitly.
        [self centerNewestSnapInWindow:window image:image existing:existingSnapViews];
        return YES;
    }

    // Second choice: the SnapMakerDelegate callback, which takes a finished
    // image plus where it came from and where it should sit.
    CGRect frame = [self floatingFrameForImage:image];
    CGPoint center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    BOOL madeImage = [self invokeRectCenterSelector:NSSelectorFromString(@"didMakeImage:fromRect:center:")
                                           onTarget:window
                                              image:image
                                               rect:frame
                                             center:center];
    NSUInteger snapsFinal = [self countForKey:@"snapsOverlay.numberOfSnaps" onTarget:window];
    KayokoFloatLog(@"snapper", [NSString stringWithFormat:@"didMakeImage invoked=%d snaps %lu->%lu", madeImage,
                                                           (unsigned long)snapsAfter, (unsigned long)snapsFinal]);

    if (madeImage && (snapsFinal > snapsAfter || [self boolForKey:@"hasSnapsShowing" onTarget:window])) {
        return YES;
    }

    return NO;
}

#pragma mark - Window and singleton discovery

/// The window list matters more than it looks: Snapper's window is not
/// necessarily attached to a `UIWindowScene`, so `connectedScenes` alone can come
/// back empty even though the window is alive. The private
/// `-allWindowsIncludingInternalWindows:onlyVisibleWindows:` call has no such
/// blind spot and is what CopyVault relies on; both lists are unioned so either
/// one being unavailable is harmless.
+ (NSArray<UIWindow *> *)applicationWindows {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    UIApplication *application = [UIApplication sharedApplication];

    SEL allWindowsSelector = NSSelectorFromString(@"allWindowsIncludingInternalWindows:onlyVisibleWindows:");
    if ([application respondsToSelector:allWindowsSelector]) {
        NSMethodSignature *signature = [application methodSignatureForSelector:allWindowsSelector];
        if (signature && [signature numberOfArguments] == 4 && strcmp([signature methodReturnType], "@") == 0) {
            BOOL internal = YES;
            BOOL visibleOnly = NO;
            NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
            [invocation setTarget:application];
            [invocation setSelector:allWindowsSelector];
            [invocation setArgument:&internal atIndex:2];
            [invocation setArgument:&visibleOnly atIndex:3];
            [invocation invoke];

            id result = nil;
            [invocation getReturnValue:&result];
            if ([result isKindOfClass:[NSArray class]]) {
                for (id candidate in (NSArray *)result) {
                    if ([candidate isKindOfClass:[UIWindow class]] && ![windows containsObject:candidate]) {
                        [windows addObject:candidate];
                    }
                }
            }
        }
    }

    for (UIScene *scene in [application connectedScenes]) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }

        for (UIWindow *window in [(UIWindowScene *)scene windows]) {
            if (![windows containsObject:window]) {
                [windows addObject:window];
            }
        }
    }

    return windows;
}

+ (nullable UIWindowScene *)activeWindowScene {
    UIApplication *application = [UIApplication sharedApplication];
    for (UIScene *scene in [application connectedScenes]) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }

        if (scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
    }

    for (UIScene *scene in [application connectedScenes]) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            return (UIWindowScene *)scene;
        }
    }

    return nil;
}

/// How many ShellX floating windows are actually on screen, which is the only
/// end-to-end signal available: the manager's array can grow while the window
/// stays hidden.
+ (NSUInteger)visibleFloatingWindowCount {
    Class windowClass = objc_getClass([kKayokoShellXFloatingWindowClassName UTF8String]);
    if (!windowClass) {
        return 0;
    }

    NSUInteger count = 0;
    for (UIWindow *window in [self applicationWindows]) {
        if ([window isKindOfClass:windowClass] && !window.isHidden) {
            count += 1;
        }
    }

    return count;
}

+ (BOOL)isFloatingWindow:(UIWindow *)window {
    Class windowClass = objc_getClass([kKayokoShellXFloatingWindowClassName UTF8String]);
    if (!windowClass || ![window isKindOfClass:[UIWindow class]]) {
        return NO;
    }

    return [window isKindOfClass:windowClass];
}

/// The window that routes touches. Deliberately skips ShellX's own floats,
/// because the whole point of this lookup is to find who had key *before* one of
/// them took it.
+ (nullable UIWindow *)keyWindowInWindows:(NSArray<UIWindow *> *)windows excludingFloating:(BOOL)excludingFloating {
    for (UIWindow *window in windows) {
        if (!window.isKeyWindow) {
            continue;
        }

        if (excludingFloating && [self isFloatingWindow:window]) {
            continue;
        }

        return window;
    }

    return nil;
}

/// `-canBecomeKeyWindow` was only made public in iOS 15, and this tweak builds
/// against an older deployment target. Below 15 every window could always become
/// key, so the honest answer there is simply yes.
+ (BOOL)windowCanBecomeKey:(UIWindow *)window {
    if (![window isKindOfClass:[UIWindow class]]) {
        return NO;
    }

    if (@available(iOS 15.0, *)) {
        return window.canBecomeKeyWindow;
    }

    return YES;
}

+ (BOOL)restoreKeyWindow:(UIWindow *)window {
    if (![window isKindOfClass:[UIWindow class]]) {
        return NO;
    }

    if (window.isKeyWindow) {
        return YES;
    }

    if (![self windowCanBecomeKey:window]) {
        return NO;
    }

    [window makeKeyWindow];
    return window.isKeyWindow;
}

/// The window that would hold key if everything sensible were in order: the
/// biggest normal-level, non-float window. Only used when nothing at all has
/// key, which already means the screen is not receiving touches.
+ (nullable UIWindow *)primaryWindowInWindows:(NSArray<UIWindow *> *)windows {
    UIWindow *best = nil;
    CGFloat bestArea = 0;

    for (UIWindow *window in windows) {
        if (window.isHidden || [self isFloatingWindow:window] || ![self windowCanBecomeKey:window]) {
            continue;
        }

        if (window.windowLevel != UIWindowLevelNormal) {
            continue;
        }

        CGFloat area = window.frame.size.width * window.frame.size.height;
        if (area > bestArea) {
            bestArea = area;
            best = window;
        }
    }

    return best;
}

/// Guarantees that key ends up on something that can route touches. The preferred
/// window is tried first because it is the one that had key before we interfered;
/// if it has since been torn down, the biggest normal window takes over. Returning
/// nil means nothing could be restored, which is worth a log line of its own.
+ (nullable UIWindow *)ensureKeyWindow:(UIWindow *)preferred {
    if ([self restoreKeyWindow:preferred]) {
        return preferred;
    }

    NSArray<UIWindow *> *windows = [self applicationWindows];
    UIWindow *current = [self keyWindowInWindows:windows excludingFloating:YES];
    if (current) {
        return current;
    }

    UIWindow *primary = [self primaryWindowInWindows:windows];
    if (!primary) {
        KayokoFloatLog(@"shellx", @"no window left to hold key");
        return nil;
    }

    [self restoreKeyWindow:primary];
    KayokoFloatLog(@"shellx", [NSString stringWithFormat:@"key rescued by %@", NSStringFromClass([primary class])]);
    return primary;
}

+ (nullable NSString *)floatingWindowDescriptionInWindows:(NSArray<UIWindow *> *)windows {
    Class windowClass = objc_getClass([kKayokoShellXFloatingWindowClassName UTF8String]);
    if (!windowClass) {
        return @"none";
    }

    for (UIWindow *window in windows) {
        if (![window isKindOfClass:windowClass]) {
            continue;
        }

        return [NSString stringWithFormat:@"%@ level=%.0f %@ hidden=%d key=%d", NSStringFromClass([window class]),
                                          window.windowLevel, NSStringFromCGRect(window.frame), window.isHidden,
                                          window.isKeyWindow];
    }

    return @"none";
}

+ (nullable NSString *)keyWindowDescriptionInWindows:(NSArray<UIWindow *> *)windows {
    for (UIWindow *window in windows) {
        if (window.isKeyWindow) {
            return NSStringFromClass([window class]);
        }
    }

    return @"none";
}

+ (nullable id)sharedInstanceOfClass:(Class)classObject selectorName:(NSString *)selectorName {
    if (!classObject || [selectorName length] == 0) {
        return nil;
    }

    SEL selector = NSSelectorFromString(selectorName);
    if (![classObject respondsToSelector:selector]) {
        return nil;
    }

    NSMethodSignature *signature = [classObject methodSignatureForSelector:selector];
    if (!signature || [signature numberOfArguments] != 2 || strcmp([signature methodReturnType], "@") != 0) {
        return nil;
    }

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setTarget:classObject];
    [invocation setSelector:selector];
    [invocation invoke];

    id result = nil;
    [invocation getReturnValue:&result];
    return result;
}

/// Selector first, class second: the selector survives a renamed class, and it
/// is exactly how CopyVault recognises the window.
+ (nullable id)snapper3WindowInWindows:(NSArray<UIWindow *> *)windows windowClass:(Class)windowClass {
    SEL probe = NSSelectorFromString(kKayokoSnapper3SnapRectSelectorName);
    for (id window in windows) {
        if ([window respondsToSelector:probe]) {
            return window;
        }
    }

    if (!windowClass) {
        return nil;
    }

    for (id window in windows) {
        if ([window isKindOfClass:windowClass]) {
            return window;
        }
    }

    return nil;
}

#pragma mark - Snapper 3 snap placement

/// Every snap view inside the window. Snapper's class name is obfuscated, so the
/// identifier has to be behavioural: only its snap views answer to
/// `-setOriginalCenterPoint:`, which is the property its drag handler springs
/// back to.
+ (NSArray<UIView *> *)snapViewsInWindow:(UIWindow *)window {
    // NSSelectorFromString rather than @selector here: the selector is declared
    // nowhere in this project, and -Wundeclared-selector would be fatal under
    // the CI's -Werror.
    SEL marker = NSSelectorFromString(@"setOriginalCenterPoint:");
    NSMutableArray<UIView *> *matches = [NSMutableArray array];
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithArray:[window subviews]];
    NSUInteger guard = 0;

    while ([queue count] > 0 && guard < 4000) {
        guard += 1;
        UIView *candidate = [queue lastObject];
        [queue removeLastObject];
        if ([candidate respondsToSelector:marker]) {
            [matches addObject:candidate];
        }

        [queue addObjectsFromArray:[candidate subviews]];
    }

    return matches;
}

/// The snap that was not there before the call. Comparing against a snapshot is
/// how the old snaps, which stay on screen on purpose, are told apart from the
/// one that was just created.
+ (nullable UIView *)snapViewAddedSince:(NSArray<UIView *> *)existing inWindow:(UIWindow *)window {
    for (UIView *view in [[self snapViewsInWindow:window] reverseObjectEnumerator]) {
        if (![existing containsObject:view]) {
            return view;
        }
    }

    return nil;
}

/// Puts the new snap on the screen centre.
///
/// Two things make this a delayed operation rather than a single assignment: the
/// snap view can be added a runloop turn after the overlay counts it, and Snapper
/// lays it out again once the image finishes loading, which moves it back to its
/// cascade slot. Hence a short retry to find it, then a second correction that
/// only fires if it actually drifted - so it never fights a finger that has
/// already grabbed the snap.
+ (BOOL)centerNewestSnapInWindow:(UIWindow *)window
                           image:(UIImage *)image
                        existing:(NSArray<UIView *> *)existing
                         attempt:(NSUInteger)attempt {
    UIView *snapView = [self snapViewAddedSince:existing inWindow:window];
    if (!snapView) {
        if (attempt < 3) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.1 + 0.1 * attempt) * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               [self centerNewestSnapInWindow:window image:image existing:existing attempt:attempt + 1];
                           });
            return NO;
        }

        snapView = [[self snapViewsInWindow:window] lastObject];
        if (!snapView) {
            KayokoFloatLog(@"snapper", @"no snap view to centre");
            return NO;
        }

        KayokoFloatLog(@"snapper", @"no new snap view, centring the newest existing one");
    }

    CGRect frame = [self floatingFrameForImage:image];
    CGPoint target = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    UIView *coordinateSpace = snapView.superview ?: window;
    CGPoint targetInSpace = [coordinateSpace convertPoint:target fromView:window];
    CGPoint before = snapView.center;

    snapView.center = targetInSpace;
    [self invokePointSelector:NSSelectorFromString(@"setOriginalCenterPoint:") onTarget:snapView point:targetInSpace];

    KayokoFloatLog(@"snapper",
                   [NSString stringWithFormat:@"centre %@ %@ -> %@ (target %@)", NSStringFromClass([snapView class]),
                                              NSStringFromCGPoint(before), NSStringFromCGPoint(snapView.center),
                                              NSStringFromCGPoint(target)]);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.28 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CGPoint current = snapView.center;
        if (fabs(current.x - targetInSpace.x) < 1.0 && fabs(current.y - targetInSpace.y) < 1.0) {
            return;
        }

        snapView.center = targetInSpace;
        [self invokePointSelector:NSSelectorFromString(@"setOriginalCenterPoint:")
                         onTarget:snapView
                            point:targetInSpace];
        KayokoFloatLog(@"snapper",
                       [NSString stringWithFormat:@"centre re-applied from %@ to %@", NSStringFromCGPoint(current),
                                                  NSStringFromCGPoint(targetInSpace)]);
    });

    return YES;
}

+ (BOOL)centerNewestSnapInWindow:(UIWindow *)window image:(UIImage *)image existing:(NSArray<UIView *> *)existing {
    return [self centerNewestSnapInWindow:window image:image existing:existing attempt:0];
}

+ (nullable id)valueForKey:(NSString *)key onTarget:(id)target {
    if (!target || [key length] == 0) {
        return nil;
    }

    @try {
        if ([key containsString:@"."]) {
            return [target valueForKeyPath:key];
        }
        return [target valueForKey:key];
    } @catch (NSException *exception) {
        (void)exception;
        return nil;
    }
}

+ (NSUInteger)countForKey:(NSString *)key onTarget:(id)target {
    id value = [self valueForKey:key onTarget:target];
    if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSSet class]]) {
        return [value count];
    }

    if ([value respondsToSelector:@selector(unsignedIntegerValue)]) {
        return [value unsignedIntegerValue];
    }

    return 0;
}

+ (BOOL)boolForKey:(NSString *)key onTarget:(id)target {
    id value = [self valueForKey:key onTarget:target];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
}

#pragma mark - Reflection helpers

/// `showFloatingImage:frame:` is two parameters, so the signature has four
/// arguments: self, _cmd and the two. Hard-coding a count is how 4.3.8 and 4.3.9
/// managed to refuse every single call while reporting a clean run, so the count
/// is derived from the selector instead: one colon per parameter, plus two.
+ (NSUInteger)argumentCountForSelector:(SEL)selector {
    if (!selector) {
        return 0;
    }

    const char *name = sel_getName(selector);
    if (!name) {
        return 0;
    }

    NSUInteger colons = 0;
    for (const char *cursor = name; *cursor != '\0'; cursor++) {
        if (*cursor == ':') {
            colons += 1;
        }
    }

    return colons + 2;
}

/// Prints `selector -> ret / argc / [arg types]`, which is what makes a refusal
/// explainable after the fact instead of a silent zero in the log.
+ (nullable NSString *)signatureDescriptionForSelector:(SEL)selector onTarget:(id)target {
    if (!selector) {
        return nil;
    }

    NSString *name = NSStringFromSelector(selector);
    if (!target || ![target respondsToSelector:selector]) {
        return [NSString stringWithFormat:@"%@ -> not implemented by %@", name,
                                          target ? NSStringFromClass([target class]) : @"nil"];
    }

    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature) {
        return [NSString stringWithFormat:@"%@ -> no signature", name];
    }

    NSMutableArray<NSString *> *types = [NSMutableArray array];
    for (NSUInteger index = 2; index < [signature numberOfArguments]; index++) {
        const char *type = [signature getArgumentTypeAtIndex:index];
        [types addObject:type ? [NSString stringWithUTF8String:type] : @"?"];
    }

    return [NSString stringWithFormat:@"%@ -> %s / %lu / [%@]", name, [signature methodReturnType],
                                      (unsigned long)[signature numberOfArguments],
                                      [types componentsJoinedByString:@", "]];
}

/// CGRect arrives as `{CGRect={CGPoint=dd}{CGSize=dd}}`, so the check is a prefix
/// match on the struct name rather than an exact string compare.
+ (BOOL)isCGRectArgumentType:(const char *)argumentType {
    if (!argumentType) {
        return NO;
    }

    return strncmp(argumentType, "{CGRect=", 8) == 0;
}

+ (BOOL)isCGPointArgumentType:(const char *)argumentType {
    if (!argumentType) {
        return NO;
    }

    return strncmp(argumentType, "{CGPoint=", 9) == 0;
}

/// Invokes `foo:(UIImage *) bar:(CGRect)` or `foo:(CGRect) bar:(UIImage *)`,
/// whichever the target actually declares. The order genuinely differs between
/// the two hosts - ShellX takes the image first, Snapper takes the rect first -
/// and getting it backwards would hand a struct where a pointer is expected.
+ (BOOL)invokeRectSelector:(SEL)selector onTarget:(id)target image:(UIImage *)image rect:(CGRect)rect {
    if (!target || !selector || ![target respondsToSelector:selector]) {
        return NO;
    }

    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || [signature numberOfArguments] != [self argumentCountForSelector:selector]) {
        KayokoFloatLog(@"reflect", [self signatureDescriptionForSelector:selector onTarget:target]);
        return NO;
    }

    const char *secondType = [signature getArgumentTypeAtIndex:2];
    const char *thirdType = [signature getArgumentTypeAtIndex:3];
    if (!secondType || !thirdType) {
        return NO;
    }

    BOOL imageFirst = secondType[0] == '@' && [self isCGRectArgumentType:thirdType];
    BOOL rectFirst = [self isCGRectArgumentType:secondType] && thirdType[0] == '@';
    if (!imageFirst && !rectFirst) {
        KayokoFloatLog(@"reflect", [self signatureDescriptionForSelector:selector onTarget:target]);
        return NO;
    }

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setTarget:target];
    [invocation setSelector:selector];

    UIImage *imageArgument = image;
    CGRect rectArgument = rect;
    if (imageFirst) {
        [invocation setArgument:&imageArgument atIndex:2];
        [invocation setArgument:&rectArgument atIndex:3];
    } else {
        [invocation setArgument:&rectArgument atIndex:2];
        [invocation setArgument:&imageArgument atIndex:3];
    }
    [invocation invoke];
    return YES;
}

/// Same idea for `foo:(UIImage *) bar:(CGRect) baz:(CGPoint)`.
+ (BOOL)invokeRectCenterSelector:(SEL)selector
                        onTarget:(id)target
                           image:(UIImage *)image
                            rect:(CGRect)rect
                          center:(CGPoint)center {
    if (!target || !selector || ![target respondsToSelector:selector]) {
        return NO;
    }

    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || [signature numberOfArguments] != [self argumentCountForSelector:selector]) {
        KayokoFloatLog(@"reflect", [self signatureDescriptionForSelector:selector onTarget:target]);
        return NO;
    }

    const char *imageType = [signature getArgumentTypeAtIndex:2];
    const char *rectType = [signature getArgumentTypeAtIndex:3];
    const char *centerType = [signature getArgumentTypeAtIndex:4];
    if (!imageType || imageType[0] != '@' || ![self isCGRectArgumentType:rectType] ||
        ![self isCGPointArgumentType:centerType]) {
        KayokoFloatLog(@"reflect", [self signatureDescriptionForSelector:selector onTarget:target]);
        return NO;
    }

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setTarget:target];
    [invocation setSelector:selector];

    UIImage *imageArgument = image;
    [invocation setArgument:&imageArgument atIndex:2];
    CGRect rectArgument = rect;
    [invocation setArgument:&rectArgument atIndex:3];
    CGPoint centerArgument = center;
    [invocation setArgument:&centerArgument atIndex:4];
    [invocation invoke];
    return YES;
}

/// And for a single `{CGPoint}` argument, which is how Snapper's snap views are
/// told where their resting position is. The struct has to travel through an
/// `NSInvocation`: `-performSelector:withObject:` cannot carry it.
+ (BOOL)invokePointSelector:(SEL)selector onTarget:(id)target point:(CGPoint)point {
    if (!target || !selector || ![target respondsToSelector:selector]) {
        return NO;
    }

    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || [signature numberOfArguments] != [self argumentCountForSelector:selector] ||
        [signature numberOfArguments] < 3) {
        KayokoFloatLog(@"reflect", [self signatureDescriptionForSelector:selector onTarget:target]);
        return NO;
    }

    if (![self isCGPointArgumentType:[signature getArgumentTypeAtIndex:2]]) {
        KayokoFloatLog(@"reflect", [self signatureDescriptionForSelector:selector onTarget:target]);
        return NO;
    }

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setTarget:target];
    [invocation setSelector:selector];
    CGPoint argument = point;
    [invocation setArgument:&argument atIndex:2];
    [invocation invoke];
    return YES;
}

@end
