//
//  KayokoScriptPanelView.h
//  Kayoko
//

#import <UIKit/UIKit.h>

@class KayokoEdgeFadingTextView;
@class KayokoHeaderView;

NS_ASSUME_NONNULL_BEGIN

/// Full-height panel content: a header, one list, and one result page. The list doubles as the script picker
/// and the candidate picker, because both are just "tap a row to go on".
@interface KayokoScriptPanelView : UIView

@property(nonatomic, strong, readonly) KayokoHeaderView *headerView;
@property(nonatomic, strong, readonly) UIView *transitionContentView;
@property(nonatomic, strong, readonly) UITableView *tableView;
@property(nonatomic, strong, readonly) UIView *resultView;
@property(nonatomic, strong, readonly) KayokoEdgeFadingTextView *resultTextView;
@property(nonatomic, strong, readonly) UILabel *resultCountLabel;
@property(nonatomic, strong, readonly) UIButton *resultCopyButton;
@property(nonatomic, strong, readonly) UIButton *resultPasteButton;
@property(nonatomic, strong, readonly) UILabel *noticeLabel;

- (void)setTitleText:(NSString *)title;
- (void)showList;
- (void)showResultWithText:(NSString *)text countText:(nullable NSString *)countText;
- (void)showNotice:(nullable NSString *)notice;
/// Called once the presentation transition has finished, so the list can be put back at its rest position
/// after UIKit has had its last word on the scroll offset.
- (void)finishListPresentation;

@end

NS_ASSUME_NONNULL_END
