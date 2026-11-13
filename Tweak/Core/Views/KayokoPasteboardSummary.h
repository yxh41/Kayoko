//
//  KayokoPasteboardSummary.h
//  Kayoko
//
//  A read-only look at what the system pasteboard is holding right now.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Never call KayokoPasteboardManager's pull path from here: that one advances
/// the change count, honours saveImages/saveText, writes history rows and runs
/// the blacklist. This snapshot only reads UIPasteboard's item dictionaries, so
/// opening it can never add, drop or duplicate a history entry. Images are
/// inspected through ImageIO headers, never decoded into a UIImage.
@interface KayokoPasteboardSummary : NSObject

/// One dictionary per pasteboard item: index, kindKey, kindFallback,
/// detail, preview and typeCount. The count of this array is numberOfItems.
+ (NSArray<NSDictionary<NSString *, id> *> *)entries;

@end

/// A small popover laid over the panel. It owns its own dimming background and
/// closes on a tap outside the card or on the Done button.
@interface KayokoPasteboardSummaryView : UIView

@property(nonatomic, copy, nullable) void (^dismissHandler)(void);

- (void)showInView:(UIView *)view animated:(BOOL)animated;
- (void)dismissAnimated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END
