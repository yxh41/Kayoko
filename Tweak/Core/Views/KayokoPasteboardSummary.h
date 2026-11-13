//
//  KayokoPasteboardSummary.h
//  Kayoko
//
//  A grouped breakdown of Kayoko's own history rows, with per-category deletion.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, KayokoSummaryKind) {
    KayokoSummaryKindImage = 0,
    KayokoSummaryKindText,
    KayokoSummaryKindLink,
    KayokoSummaryKindRichText,
    KayokoSummaryKindOther,
    KayokoSummaryKindCount
};

/// The owner performs the deletion (only it owns the data store) and returns a
/// fresh items array so the popover can rebuild itself.
typedef void (^KayokoSummaryDeleteCompletion)(BOOL success,
                                              NSArray<NSDictionary<NSString *, id> *> *freshItems);

@interface KayokoPasteboardSummary : NSObject

/// Classify one stored history dictionary. The original dictionary is carried
/// through untouched: that exact object is what -removeItemDictionary: needs.
+ (NSDictionary<NSString *, id> *)entryForItem:(NSDictionary<NSString *, id> *)item;

/// One dictionary per non-empty kind: kind, kindKey, kindFallback, count and
/// entries. Never reads UIPasteboard and never calls the capture pipeline.
+ (NSArray<NSDictionary<NSString *, id> *> *)groupsForItems:(NSArray<NSDictionary<NSString *, id> *> *)items;

@end

/// A small popover laid over the panel. Its card uses the same
/// UIBlurEffectStyleRegular material as KayokoMainView.
@interface KayokoPasteboardSummaryView : UIView

@property(nonatomic, copy, nullable) void (^dismissHandler)(void);
/// Deletes an entire category at once: the caller passes every original history
/// dictionary grouped under one kind, the owner removes them and returns the
/// post-deletion item list so the popover can rebuild itself.
@property(nonatomic, copy, nullable) void (^deleteHandler)(NSArray<NSDictionary<NSString *, id> *> *items,
                                                            KayokoSummaryDeleteCompletion completion);

- (void)showInView:(UIView *)view
             items:(NSArray<NSDictionary<NSString *, id> *> *)items
          animated:(BOOL)animated;
- (void)reloadWithItems:(NSArray<NSDictionary<NSString *, id> *> *)items;
- (void)dismissAnimated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END
