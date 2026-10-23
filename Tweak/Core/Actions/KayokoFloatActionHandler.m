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

/// Snapper 3's plugin manager, from its published extension API.
static NSString *const kKayokoSnapper3PluginManagerClassName = @"Snapper3PluginManager";

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
+ (BOOL)invokeSelector:(SEL)selector onTarget:(id)target withImage:(UIImage *)image frame:(CGRect)frame;
+ (BOOL)isCGRectArgumentType:(const char *)argumentType;
+ (BOOL)floatWithSnapper3InMemory:(UIImage *)image;
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

+ (BOOL)isHostInstalled:(KayokoFloatTarget)target {
    NSString *className = target == KayokoFloatTargetShellX ? kKayokoShellXPluginManagerClassName
                                                            : kKayokoSnapper3PluginManagerClassName;
    return objc_getClass([className UTF8String]) != NULL;
}

/// Both the host being loaded and its history folder being reachable are
/// required: a half-working host would leave a button that does nothing.
+ (BOOL)isAvailable {
    if (![self isEnabled]) {
        return NO;
    }

    KayokoFloatTarget target = [self target];
    if (![self isHostInstalled:target]) {
        return NO;
    }

    NSString *directory = [self historyDirectoryForTarget:target];
    if ([directory length] == 0) {
        return NO;
    }

    // Snapper 3's folder is known, so it can be created on demand. A discovered
    // ShellX folder is only trusted once it already holds pictures.
    if (target == KayokoFloatTargetSnapper3) {
        return YES;
    }

    return [self directoryLooksLikeImageStore:directory];
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

    // Snapper 3 can take a UIImage straight into its window. That is the only
    // route that shows exactly the tapped item rather than "whatever is newest",
    // so it is tried first and the history fallback never runs if it lands.
    if (target == KayokoFloatTargetSnapper3 && [self floatWithSnapper3InMemory:image]) {
        return;
    }

    NSString *directory = [self historyDirectoryForTarget:target];
    if ([directory length] == 0) {
        return;
    }

    // ShellX's folder is discovered by name, so only write once it has proved
    // itself by already holding pictures. Snapper 3's folder is known.
    if (target == KayokoFloatTargetShellX && ![self directoryLooksLikeImageStore:directory]) {
        return;
    }

    // Write first, float second: the host floats whatever is newest in its
    // history, so the picture has to be on disk before it is asked to look.
    if (![self writeImage:image toDirectory:directory]) {
        return;
    }

    NSString *notificationName = target == KayokoFloatTargetShellX ? kKayokoShellXOpenLastNotification
                                                                  : kKayokoSnapper3OpenLastNotification;
    [self postDarwinNotification:notificationName];
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

#pragma mark - Snapper 3 in-memory shortcut

/// Snapper 3 knows how to take a UIImage directly. Worth one guarded attempt
/// before falling back to the history folder, because it is the only route that
/// is exact rather than "whatever is newest".
+ (BOOL)floatWithSnapper3InMemory:(UIImage *)image {
    Class windowClass = objc_getClass("SnapperWindow");
    if (!windowClass) {
        return NO;
    }

    NSArray<NSString *> *accessorNames = @[ @"sharedInstance", @"sharedManager", @"defaultManager" ];
    id window = nil;
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
        if (result) {
            window = result;
            break;
        }
    }

    if (!window) {
        return NO;
    }

    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    CGFloat scale = MIN(1.0, MIN(screenSize.width * 0.7 / image.size.width,
                                 screenSize.height * 0.7 / MAX(image.size.height, 1)));
    CGSize size = CGSizeMake(ceil(image.size.width * scale), ceil(image.size.height * scale));
    CGRect frame = CGRectMake((screenSize.width - size.width) * 0.5, (screenSize.height - size.height) * 0.5,
                              size.width, size.height);

    if ([self invokeSelector:NSSelectorFromString(@"addSnap:atRect:animated:")
                    onTarget:window
                   withImage:image
                       frame:frame]) {
        return YES;
    }

    return [self invokeSelector:NSSelectorFromString(@"showSnap:atCenter:animated:")
                       onTarget:window
                      withImage:image
                          frame:frame];
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

/// Invokes `-(void)foo:(UIImage *)image bar:(CGRect)frame` on an object we know
/// nothing about, refusing to call if the argument types do not line up. That
/// refusal is what keeps a signature mismatch from turning into a crash.
+ (BOOL)invokeSelector:(SEL)selector
              onTarget:(id)target
             withImage:(UIImage *)image
                 frame:(CGRect)frame {
    if (!target || !selector || ![target respondsToSelector:selector]) {
        return NO;
    }

    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || [signature numberOfArguments] != 3) {
        return NO;
    }

    const char *imageType = [signature getArgumentTypeAtIndex:2];
    const char *frameType = [signature getArgumentTypeAtIndex:3];
    if (!imageType || imageType[0] != '@' || ![self isCGRectArgumentType:frameType]) {
        return NO;
    }

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setTarget:target];
    [invocation setSelector:selector];

    UIImage *imageArgument = image;
    [invocation setArgument:&imageArgument atIndex:2];
    CGRect frameArgument = frame;
    [invocation setArgument:&frameArgument atIndex:3];
    [invocation invoke];
    return YES;
}

@end
