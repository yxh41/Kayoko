//
//  KayokoFloatActionHandler.m
//  Kayoko
//

#import "KayokoFloatActionHandler.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "KayokoPasteboardItem.h"
#import "KayokoPasteboardManager.h"
#import "KayokoPreferenceKeys.h"

@interface KayokoFloatActionHandler ()

+ (nullable id)instanceOfClassNamed:(NSString *)className;
+ (BOOL)isCGRectArgumentType:(const char *)argumentType;
+ (BOOL)invokeSelector:(SEL)selector onTarget:(id)target withImage:(UIImage *)image frame:(CGRect)frame;
+ (BOOL)floatWithShellX:(UIImage *)image;
+ (BOOL)floatWithSnapper3:(UIImage *)image;
+ (BOOL)floatWithSnapper3InMemory:(UIImage *)image;
+ (BOOL)floatWithSnapper3OnDisk:(UIImage *)image;
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
    if (value < KayokoFloatTargetAutomatic || value > KayokoFloatTargetSnapper3) {
        return KayokoFloatTargetAutomatic;
    }
    return (KayokoFloatTarget)value;
}

+ (BOOL)isHostAvailable:(KayokoFloatTarget)target {
    NSString *className = nil;
    switch (target) {
        case KayokoFloatTargetShellX:
            className = @"SSFloatingManager";
            break;
        case KayokoFloatTargetSnapper3:
            className = @"Snapper3PluginManager";
            break;
        case KayokoFloatTargetAutomatic:
        default:
            break;
    }

    if (!className) {
        return NO;
    }

    return objc_getClass([className UTF8String]) != NULL;
}

+ (BOOL)isAvailable {
    if (![self isEnabled]) {
        return NO;
    }

    switch ([self target]) {
        case KayokoFloatTargetShellX:
            return [self isHostAvailable:KayokoFloatTargetShellX];
        case KayokoFloatTargetSnapper3:
            return [self isHostAvailable:KayokoFloatTargetSnapper3];
        case KayokoFloatTargetAutomatic:
        default:
            return [self isHostAvailable:KayokoFloatTargetShellX] || [self isHostAvailable:KayokoFloatTargetSnapper3];
    }
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
    if (target == KayokoFloatTargetAutomatic) {
        if ([self floatWithShellX:image]) {
            return;
        }
        [self floatWithSnapper3:image];
        return;
    }

    if (target == KayokoFloatTargetShellX) {
        [self floatWithShellX:image];
        return;
    }

    [self floatWithSnapper3:image];
}

#pragma mark - Reflection helpers

/// Looks up a singleton accessor without linking against anything. `+[NSObject ...]`
/// style names are tried in order; the first that returns an object wins.
+ (nullable id)instanceOfClassNamed:(NSString *)className {
    Class klass = objc_getClass([className UTF8String]);
    if (!klass) {
        return nil;
    }

    NSArray<NSString *> *accessorNames = @[
        @"sharedInstance", @"sharedManager", @"shared", @"defaultManager", @"sharedInstanceIfExists",
    ];
    for (NSString *accessorName in accessorNames) {
        SEL accessor = NSSelectorFromString(accessorName);
        if (![klass respondsToSelector:accessor]) {
            continue;
        }

        NSMethodSignature *signature = [klass methodSignatureForSelector:accessor];
        if (!signature || strcmp([signature methodReturnType], "@") != 0) {
            continue;
        }

        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        [invocation setTarget:klass];
        [invocation setSelector:accessor];
        [invocation invoke];

        id result = nil;
        [invocation getReturnValue:&result];
        if (result) {
            return result;
        }
    }

    return nil;
}

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

#pragma mark - ShellX

/// ShellX keeps its floating windows in `SSFloatingManager` and hands over an
/// image with `-showFloatingImage:frame:` (or `…fromRect:`). One call, no files.
+ (BOOL)floatWithShellX:(UIImage *)image {
    id manager = [self instanceOfClassNamed:@"SSFloatingManager"];
    if (!manager) {
        return NO;
    }

    CGRect frame = [self centeredFrameForImage:image];
    if ([self invokeSelector:NSSelectorFromString(@"showFloatingImage:frame:")
                    onTarget:manager
                   withImage:image
                       frame:frame]) {
        return YES;
    }

    return [self invokeSelector:NSSelectorFromString(@"showFloatingImage:fromRect:")
                       onTarget:manager
                      withImage:image
                          frame:frame];
}

#pragma mark - Snapper 3

/// Snapper 3 has no documented "pin this image" entry point, so two routes are
/// tried: the in-memory `-addSnap:atRect:animated:` on its window, and — if that
/// is not reachable — dropping the file into its history and asking it to open
/// the last snap.
+ (BOOL)floatWithSnapper3:(UIImage *)image {
    if ([self floatWithSnapper3InMemory:image]) {
        return YES;
    }

    return [self floatWithSnapper3OnDisk:image];
}

+ (BOOL)floatWithSnapper3InMemory:(UIImage *)image {
    id window = [self instanceOfClassNamed:@"SnapperWindow"];
    if (!window) {
        return NO;
    }

    CGRect frame = [self centeredFrameForImage:image];
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

+ (BOOL)floatWithSnapper3OnDisk:(UIImage *)image {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *imagesDirectory = jbroot(@"/var/mobile/Library/Snapper3/Images/");
    if (![fileManager fileExistsAtPath:imagesDirectory]) {
        [fileManager createDirectoryAtPath:imagesDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    }

    NSString *fileName = [NSString stringWithFormat:@"kayoko-%@.png", [NSUUID UUID].UUIDString];
    NSString *filePath = [imagesDirectory stringByAppendingPathComponent:fileName];
    NSData *data = UIImagePNGRepresentation(image);
    if (![data writeToFile:filePath atomically:YES]) {
        return NO;
    }

    // `openLastSnap` picks the newest history entry up from preferences, so the
    // file we just wrote has to be named there too.
    CFPreferencesSetValue(CFSTR("lastSnapFileName"), (__bridge CFPropertyListRef)fileName,
                          CFSTR("com.jontelang.snapper3preferences"), kCFPreferencesCurrentUser,
                          kCFPreferencesAnyHost);
    CFPreferencesSynchronize(CFSTR("com.jontelang.snapper3preferences"), kCFPreferencesCurrentUser,
                             kCFPreferencesAnyHost);

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.jontelang.snapper3.history"),
                                         NULL, NULL, YES);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.jontelang.snapper3.openlast"), NULL, NULL, YES);
    return YES;
}

#pragma mark - Layout

/// Scales the image down to at most 70% of the screen and centres it, so a long
/// screenshot does not cover everything and a tiny icon stays usable.
+ (CGRect)centeredFrameForImage:(UIImage *)image {
    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    CGFloat maximumWidth = screenSize.width * 0.7;
    CGFloat maximumHeight = screenSize.height * 0.7;

    CGSize size = image.size;
    if (size.width <= 0 || size.height <= 0) {
        return CGRectMake((screenSize.width - 200.0) * 0.5, (screenSize.height - 200.0) * 0.5, 200.0, 200.0);
    }

    CGFloat scale = MIN(1.0, MIN(maximumWidth / size.width, maximumHeight / size.height));
    size = CGSizeMake(ceil(size.width * scale), ceil(size.height * scale));

    return CGRectMake((screenSize.width - size.width) * 0.5, (screenSize.height - size.height) * 0.5,
                      size.width, size.height);
}

@end
