//
//  KayokoPreviewViewController.h
//  Kayoko
//

#import <UIKit/UIKit.h>

@class KayokoPreviewView;
@class KayokoPasteboardItem;

NS_ASSUME_NONNULL_BEGIN

@interface KayokoPreviewViewController : UIViewController

@property(nonatomic, strong, readonly) KayokoPreviewView *previewView;
@property(nonatomic, copy, nullable, readonly) NSString *sourceHistoryKey;
@property(nonatomic, strong, nullable, readonly) KayokoPasteboardItem *previewItem;
@property(nonatomic, copy, nullable) void (^tagAssignmentHandler)(KayokoPasteboardItem *item, NSString *historyKey);
@property(nonatomic, copy, nullable) void (^hapticFeedbackHandler)(UIImpactFeedbackStyle style);
/// Called when the user taps the script button next to the primary action.
@property(nonatomic, copy, nullable) void (^scriptButtonHandler)(KayokoPasteboardItem *item, NSString *historyKey);

- (void)showPreviewWithItem:(KayokoPasteboardItem *)item sourceHistoryKey:(NSString *)sourceHistoryKey;
- (void)handleActionButtonWithCompletion:(nullable void (^)(BOOL success))completion;
- (void)hidePreview;
- (void)resetPreviewState;
- (void)scrollToTopAnimated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END
