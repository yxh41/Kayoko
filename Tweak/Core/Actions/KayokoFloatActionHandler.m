//
//  KayokoFloatActionHandler.m
//  Kayoko
//

#import "KayokoFloatActionHandler.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <roothide.h>
#import <string.h>

#import "KayokoPasteboardItem.h"
#import "KayokoPasteboardManager.h"
#import "KayokoPreferenceKeys.h"

/// ShellX's own integration notes name this class as the way to detect it.
static NSString *const kKayokoShellXPluginManagerClassName = @"SHELLXPluginManager";

/// ShellX's floating-image manager, read out of ScreenshotShell.dylib. It
/// declares exactly two entry points with the same `v56@0:8@16{CGRect}24`
/// signature; `-showFloatingImage:frame:` puts the picture at a known spot,
/// which is what "float this one" needs.
static NSString *const kKayokoShellXFloatingManagerClassName = @"SSFloatingManager";

/// Snapper 3's plugin manager, from its published extension API.
static NSString *const kKayokoSnapper3PluginManagerClassName = @"Snapper3PluginManager";

/// Snapper 3's floating window. Its `SnapMaker` holds a `SnapMakerDelegate`,
/// and that delegate callback is `-didMakeImage:fromRect:center:` — an
/// in-memory UIImage plus where it came from and where it should sit. Handing
/// it an image is the only way to float the tapped item instead of "newest".
static NSString *const kKayokoSnapper3WindowClassName = @"SnapperWindow";

/// ShellX floats the newest entry of its own history when this is posted.
static NSString *const kKayokoShellXOpenLastNotification = @"com.iosdump.screenshotshell.openlast";

/// Snapper 3's equivalent.
static NSString *const kKayokoSnapper3OpenLastNotification = @"com.jontelang.snapper3.openlast";

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
+ (nullable id)snapper3WindowForClass:(Class)windowClass;
+ (NSUInteger)snapper3SnapCountForWindow:(id)window;
+ (BOOL)invokeSelector:(SEL)selector onTarget:(id)target image:(UIImage *)image rect:(CGRect)rect;
+ (BOOL)invokeSelector:(SEL)selector
+              onTarget:(id)target
+                 image:(UIImage *)image
+                  rect:(CGRect)rect
+                center:(CGPoint)center;
+ (BOOL)isCGRectArgumentType:(const char *)argumentType;
+ (BOOL)isCGPointArgumentType:(const char *)argumentType;
+ (BOOL)boolForSelector:(SEL)selector onTarget:(id)target;
+ (nullable UIImage *)imageFromText:(NSString *)text;

@end

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
        return;
    }

    KayokoFloatTarget target = [self target];

    // Both hosts can be handed the UIImage itself, which is the only way to end
    // up with exactly the tapped item. That path is tried first and, once it
    // reports success, the history file is never touched.
    BOOL floated = target == KayokoFloatTargetShellX ? [self floatWithShellXInMemory:image]
                                                    : [self floatWithSnapper3InMemory:image];
    if (floated) {
        return;
    }

    // Last resort: drop the picture into the host's history folder and ask it to
    // reopen "the last one". That is a date comparison rather than a direct
    // hand-off, so it is only reached when the in-memory call was unavailable.
    NSString *directory = [self historyDirectoryForTarget:target];
    if ([directory length] == 0) {
        return;
    }

    // ShellX's folder is discovered by name, so only write once it has proved
    // itself by already holding pictures; otherwise a name collision could drop
    // a PNG into an unrelated Library directory.
    if (target == KayokoFloatTargetShellX && ![self directoryLooksLikeImageStore:directory]) {
        return;
    }

    if (![self writeImage:image toDirectory:directory]) {
        return;
    }

    NSString *notificationName = target == KayokoFloatTargetShellX ? kKayokoShellXOpenLastNotification
                                                                  : kKayokoSnapper3OpenLastNotification;
    [self postDarwinNotification:notificationName];
}

/// Shared sizing: a third to two thirds of the screen, centred, never upscaled.
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

/// `SSFloatingManager` holds nothing but an array of windows, so a fresh
/// instance is a complete manager: `-showFloatingImage:frame:` builds an
/// `SSFloatingWindow` and puts it on screen by itself. The call is judged by
/// that array growing, which is the only objective proof it landed.
+ (BOOL)floatWithShellXInMemory:(UIImage *)image {
    Class managerClass = objc_getClass([kKayokoShellXFloatingManagerClassName UTF8String]);
    if (!managerClass) {
        return NO;
    }

    id manager = [[managerClass alloc] init];
    if (!manager) {
        return NO;
    }

    // Counted now, not later: the ivar is a mutable array, so holding a pointer
    // to it and counting afterwards would just read the new length back.
    id before = [manager valueForKey:@"floatingWindows"];
    NSUInteger beforeCount = [before isKindOfClass:[NSArray class]] ? [(NSArray *)before count] : 0;

    CGRect frame = [self floatingFrameForImage:image];

    if (![self invokeSelector:NSSelectorFromString(@"showFloatingImage:frame:")
                     onTarget:manager
                        image:image
                         rect:frame] &&
        ![self invokeSelector:NSSelectorFromString(@"showFloatingImage:fromRect:")
                     onTarget:manager
                        image:image
                         rect:frame]) {
        return NO;
    }

    id after = [manager valueForKey:@"floatingWindows"];
    if (![after isKindOfClass:[NSArray class]]) {
        return NO;
    }

    return [(NSArray *)after count] > beforeCount;
}

#pragma mark - Snapper 3 in-memory hand-off

/// Snapper 3 floats through its window rather than through its history.
/// `SnapperWindow` implements `SnapMakerDelegate`, and `-didMakeImage:fromRect:
/// center:` is the callback Snapper itself runs once a capture exists: an
/// in-memory UIImage, the rect it came from and where it should sit. Feeding it
/// an image is therefore the exact equivalent of "snap this".
+ (BOOL)floatWithSnapper3InMemory:(UIImage *)image {
    Class windowClass = objc_getClass([kKayokoSnapper3WindowClassName UTF8String]);
    if (!windowClass) {
        return NO;
    }

    id window = [self snapper3WindowForClass:windowClass];
    if (!window) {
        return NO;
    }

    NSUInteger snapCountBefore = [self snapper3SnapCountForWindow:window];
    CGRect frame = [self floatingFrameForImage:image];
    CGPoint center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));

    BOOL invoked = [self invokeSelector:NSSelectorFromString(@"didMakeImage:fromRect:center:")
                               onTarget:window
                                  image:image
                                   rect:frame
                                 center:center];
    if (!invoked) {
        return NO;
    }

    if ([self snapper3SnapCountForWindow:window] > snapCountBefore) {
        return YES;
    }

    // A second signal, for builds whose overlay count is only refreshed lazily.
    return [self boolForSelector:NSSelectorFromString(@"hasSnapsShowing") onTarget:window];
}

/// Finds the window Snapper already lives in. Enumerating the windows of the
/// connected window scenes is the reliable half: every UIWindow of SpringBoard
/// is listed there, including hidden ones, so no private singleton is needed.
+ (nullable id)snapper3WindowForClass:(Class)windowClass {
    if (!windowClass) {
        return nil;
    }

    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }

        for (UIWindow *window in [(UIWindowScene *)scene windows]) {
            if ([window isKindOfClass:windowClass]) {
                return window;
            }
        }
    }

    // Older builds may keep it as a class-level accessor instead.
    NSArray<NSString *> *accessorNames = @[ @"sharedInstance", @"shared", @"sharedWindow", @"defaultWindow" ];
    for (NSString *accessorName in accessorNames) {
        SEL accessor = NSSelectorFromString(accessorName);
        if (![windowClass respondsToSelector:accessor]) {
            continue;
        }

        NSMethodSignature *signature = [windowClass methodSignatureForSelector:accessor];
        if (!signature || strcmp([signature methodReturnType], "@") != 0) {
            continue;
        }

        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        [invocation setTarget:windowClass];
        [invocation setSelector:accessor];
        [invocation invoke];

        id result = nil;
        [invocation getReturnValue:&result];
        if ([result isKindOfClass:windowClass]) {
            return result;
        }
    }

    return nil;
}

/// How many snaps are floating right now, read off the overlay the window owns.
+ (NSUInteger)snapper3SnapCountForWindow:(id)window {
    @try {
        id overlay = [window valueForKey:@"snapsOverlay"];
        if (!overlay || ![overlay respondsToSelector:NSSelectorFromString(@"numberOfSnaps")]) {
            return 0;
        }

        id value = [overlay valueForKey:@"numberOfSnaps"];
        return [value respondsToSelector:@selector(unsignedIntegerValue)] ? [value unsignedIntegerValue] : 0;
    } @catch (NSException *exception) {
        (void)exception;
        return 0;
    }

    return 0;
}

#pragma mark - Reflection helpers

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

/// Invokes `-(void)foo:(UIImage *)image bar:(CGRect)rect` on an object we know
/// nothing about, refusing to call if the argument types do not line up. That
/// refusal is what keeps a signature mismatch from turning into a crash.
+ (BOOL)invokeSelector:(SEL)selector onTarget:(id)target image:(UIImage *)image rect:(CGRect)rect {
    if (!target || !selector || ![target respondsToSelector:selector]) {
        return NO;
    }

    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || [signature numberOfArguments] != 3) {
        return NO;
    }

    const char *imageType = [signature getArgumentTypeAtIndex:2];
    const char *rectType = [signature getArgumentTypeAtIndex:3];
    if (!imageType || imageType[0] != '@' || ![self isCGRectArgumentType:rectType]) {
        return NO;
    }

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setTarget:target];
    [invocation setSelector:selector];

    UIImage *imageArgument = image;
    [invocation setArgument:&imageArgument atIndex:2];
    CGRect rectArgument = rect;
    [invocation setArgument:&rectArgument atIndex:3];
    [invocation invoke];
    return YES;
}

/// Same idea for `-(void)foo:(UIImage *)image bar:(CGRect)rect baz:(CGPoint)point`.
+ (BOOL)invokeSelector:(SEL)selector
              onTarget:(id)target
                 image:(UIImage *)image
                  rect:(CGRect)rect
                center:(CGPoint)center {
    if (!target || !selector || ![target respondsToSelector:selector]) {
        return NO;
    }

    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || [signature numberOfArguments] != 4) {
        return NO;
    }

    const char *imageType = [signature getArgumentTypeAtIndex:2];
    const char *rectType = [signature getArgumentTypeAtIndex:3];
    const char *centerType = [signature getArgumentTypeAtIndex:4];
    if (!imageType || imageType[0] != '@' || ![self isCGRectArgumentType:rectType] ||
        ![self isCGPointArgumentType:centerType]) {
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

/// Reads a BOOL-returning method without trusting its return type blindly.
+ (BOOL)boolForSelector:(SEL)selector onTarget:(id)target {
    if (!target || !selector || ![target respondsToSelector:selector]) {
        return NO;
    }

    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || [signature numberOfArguments] != 2) {
        return NO;
    }

    const char *returnType = [signature methodReturnType];
    if (!returnType) {
        return NO;
    }

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setTarget:target];
    [invocation setSelector:selector];
    [invocation invoke];

    switch (returnType[0]) {
        case 'B':
        case 'c': {
            BOOL value = NO;
            [invocation getReturnValue:&value];
            return value;
        }
        case 'i': {
            int value = 0;
            [invocation getReturnValue:&value];
            return value != 0;
        }
        case 'q':
        case 'Q': {
            long long value = 0;
            [invocation getReturnValue:&value];
            return value != 0;
        }
        default:
            return NO;
    }
}

@end
