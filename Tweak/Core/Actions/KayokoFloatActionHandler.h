//
//  KayokoFloatActionHandler.h
//  Kayoko
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class KayokoPasteboardItem;

typedef NS_ENUM(NSUInteger, KayokoFloatTarget) {
    KayokoFloatTargetAutomatic = 0,
    KayokoFloatTargetShellX = 1,
    KayokoFloatTargetSnapper3 = 2
};

/// Turns a clipboard item into a floating image, hosted by ShellX or Snapper 3.
///
/// Both hosts live in SpringBoard, which is exactly where Kayoko Core runs, so a
/// clip can be handed over without any file round-trip. Neither package exposes
/// a documented API for "pin this image", so the calls are made reflectively:
/// every selector is probed with `respondsToSelector:` and its arguments are
/// checked against the method signature before anything is invoked.
@interface KayokoFloatActionHandler : NSObject

/// Whether the user wants the left-swipe action at all.
+ (BOOL)isEnabled;

/// Whether at least one floating host is installed and reachable right now.
+ (BOOL)isAvailable;

/// A UIImage for the item: the stored image for clips, a rendered card for text.
+ (nullable UIImage *)imageForItem:(KayokoPasteboardItem *)item;

/// Hands the item over to the configured host.
+ (void)floatItem:(KayokoPasteboardItem *)item;

@end

NS_ASSUME_NONNULL_END
