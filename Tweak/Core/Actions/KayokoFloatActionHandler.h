//
//  KayokoFloatActionHandler.h
//  Kayoko
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class KayokoPasteboardItem;

typedef NS_ENUM(NSUInteger, KayokoFloatTarget) {
    KayokoFloatTargetShellX = 0,
    KayokoFloatTargetSnapper3 = 1,
    KayokoFloatTargetClippa = 2
};

/// Turns a clipboard item into a floating image, hosted by ShellX, Snapper 3 or
/// Clippa. Nothing else happens: the picture is pinned and Kayoko closes.
///
/// ShellX and Snapper 3 publish no "pin this image" call, so their route drops
/// the picture into the host's history folder and asks it to float the last one.
/// Clippa does publish `pinImage:initialFrame:error:` (ClippaPinning.h), so it
/// takes the UIImage directly with no history folder and no Darwin notification.
/// A host that cannot be reached makes the swipe action disappear instead of
/// failing silently.
@interface KayokoFloatActionHandler : NSObject

/// Whether the user wants the left-swipe action at all.
+ (BOOL)isEnabled;

/// The host the user picked.
+ (KayokoFloatTarget)target;

/// Whether that host is installed and its history folder could be found.
+ (BOOL)isAvailable;

/// A UIImage for the item: the stored image for clips, a rendered card for text.
+ (nullable UIImage *)imageForItem:(KayokoPasteboardItem *)item;

/// Hands the item over to the configured host.
+ (void)floatItem:(KayokoPasteboardItem *)item;

@end

NS_ASSUME_NONNULL_END
