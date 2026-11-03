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
@property(nonatomic, strong, readonly) UISearchBar *searchBar;
@property(nonatomic, strong, readonly) UIView *resultView;
@property(nonatomic, strong, readonly) KayokoEdgeFadingTextView *resultTextView;
@property(nonatomic, strong, readonly) UILabel *resultCountLabel;
@property(nonatomic, strong, readonly) UIButton *resultCopyButton;
@property(nonatomic, strong, readonly) UIButton *resultPasteButton;
@property(nonatomic, strong, readonly) UILabel *noticeLabel;

- (void)setTitleText:(NSString *)title;
- (void)showList;
- (void)setSearchBarVisible:(BOOL)visible;
- (void)showResultWithText:(NSString *)text countText:(nullable NSString *)countText;
/// The failure page reuses the result layout: the text is a diagnostic, and the only thing worth offering on a
/// failed run is the ability to copy it somewhere the user can act on it.
- (void)showFailureWithText:(NSString *)text copyTitle:(NSString *)copyTitle;
- (void)showNotice:(nullable NSString *)notice;

@end

NS_ASSUME_NONNULL_END
