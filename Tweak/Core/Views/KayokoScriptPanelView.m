//
//  KayokoScriptPanelView.m
//  Kayoko
//

#import "KayokoScriptPanelView.h"

#import "KayokoEdgeFadingTextView.h"
#import "KayokoHeaderButtonStyle.h"
#import "KayokoHeaderView.h"
#import "KayokoPasteboardManager.h"
#import "KayokoSearchBar.h"

static CGFloat const kKayokoScriptPanelVerticalFadeHeight = 24;
static CGFloat const kKayokoScriptPanelFooterHorizontalInset = 16;
static CGFloat const kKayokoScriptPanelFooterBottomInset = 12;
static CGFloat const kKayokoScriptPanelButtonHeight = 40;
static CGFloat const kKayokoScriptPanelListTopInset = 14;
static CGFloat const kKayokoScriptPanelListBottomInset = 12;

NS_ASSUME_NONNULL_BEGIN

static NSString *KayokoScriptPanelLocalizedString(NSString *key, NSString *fallback) {
    return [[KayokoPasteboardManager localizationBundle] localizedStringForKey:key value:fallback table:@"Tweak"];
}

@interface KayokoScriptPanelView ()

@property(nonatomic, strong, readwrite) KayokoHeaderView *headerView;
@property(nonatomic, strong, readwrite) UIView *transitionContentView;
@property(nonatomic, strong, readwrite) UITableView *tableView;
@property(nonatomic, strong, readwrite) UIView *resultView;
@property(nonatomic, strong, readwrite) KayokoEdgeFadingTextView *resultTextView;
@property(nonatomic, strong, readwrite) UILabel *resultCountLabel;
@property(nonatomic, strong, readwrite) UIButton *resultCopyButton;
@property(nonatomic, strong, readwrite) UIButton *resultPasteButton;
@property(nonatomic, strong, readwrite) UILabel *noticeLabel;
@property(nonatomic, strong, readwrite) UISearchBar *searchBar;
/// Drives the search bar's height: collapsing it to zero removes the bar from the layout without animation churn.
@property(nonatomic, strong) NSLayoutConstraint *searchBarHeightConstraint;
@property(nonatomic, strong) UIStackView *footerStackView;
/// What the copy button says when the page is a real result rather than a failure report.
@property(nonatomic, copy) NSString *defaultCopyTitle;

@end

NS_ASSUME_NONNULL_END

@implementation KayokoScriptPanelView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self) {
        _headerView = [[KayokoHeaderView alloc]
            initWithTitle:KayokoScriptPanelLocalizedString(@"Scripts", @"Scripts")];
        [_headerView updateStyleForButton:[_headerView leadingButton]
                            withImageName:@"arrowshape.turn.up.backward"
                                imageSize:kKayokoFavoritesButtonImageSize
                                tintColor:[UIColor labelColor]];
        [[_headerView leadingButton]
            setAccessibilityLabel:KayokoScriptPanelLocalizedString(@"Back", @"Back")];
        [[_headerView trailingButton] setHidden:YES];
        [[_headerView alternateTrailingButton] setHidden:YES];
        [[_headerView scriptButton] setHidden:YES];
        [self addSubview:_headerView];

        // Search lives directly under the header (not in the sliding container) so it stays put while the list
        // scrolls beneath it; it is collapsed out of the layout unless the panel controller asks for it.
        // The history/favorites search uses KayokoSearchBar with a cleared background, so the script panel does
        // the same: identical chrome is the whole point of this class existing.
        _searchBar = [[KayokoSearchBar alloc] initWithFrame:CGRectZero];
        [_searchBar setPlaceholder:KayokoScriptPanelLocalizedString(@"Search", @"Search")];
        [_searchBar setSearchBarStyle:UISearchBarStyleMinimal];
        [_searchBar setBackgroundImage:[[UIImage alloc] init]];
        [_searchBar setTintColor:[UIColor labelColor]];
        [_searchBar setAlpha:0];
        [_searchBar setHidden:YES];
        [self addSubview:_searchBar];

        // The header has to stay put while content slides, so everything else lives in its own container.
        _transitionContentView = [[UIView alloc] init];
        [self addSubview:_transitionContentView];

        _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
        [_tableView setBackgroundColor:[UIColor clearColor]];
        // The rows carry no chrome: the list is a plain sequence of script names and separators only added noise.
        [_tableView setSeparatorStyle:UITableViewCellSeparatorStyleNone];
        [_tableView setRowHeight:52];
        [_tableView setEstimatedRowHeight:52];
        [_tableView setContentInsetAdjustmentBehavior:UIScrollViewContentInsetAdjustmentNever];
        // The script list is usually shorter than the panel, so without this a pull-down would not even bounce and
        // there would be no way to reveal the search bar.
        [_tableView setAlwaysBounceVertical:YES];
        [_tableView setContentInset:UIEdgeInsetsMake(kKayokoScriptPanelListTopInset, 0,
                                                     kKayokoScriptPanelListBottomInset, 0)];
        [_transitionContentView addSubview:_tableView];

        _noticeLabel = [[UILabel alloc] init];
        [_noticeLabel setFont:[UIFont systemFontOfSize:15 weight:UIFontWeightMedium]];
        [_noticeLabel setTextColor:[UIColor secondaryLabelColor]];
        [_noticeLabel setTextAlignment:NSTextAlignmentCenter];
        [_noticeLabel setNumberOfLines:0];
        [_noticeLabel setHidden:YES];
        [_transitionContentView addSubview:_noticeLabel];

        _resultView = [[UIView alloc] init];
        [_resultView setHidden:YES];
        [_transitionContentView addSubview:_resultView];

        _resultTextView = [[KayokoEdgeFadingTextView alloc] init];
        [_resultTextView setEdgeFadeAxis:KayokoEdgeFadeAxisVertical];
        [_resultTextView setEdgeFadeWidth:kKayokoScriptPanelVerticalFadeHeight];
        [_resultTextView setEdgeFadeEnabled:YES];
        [_resultTextView setBackgroundColor:[UIColor clearColor]];
        [_resultTextView setFont:[UIFont systemFontOfSize:15]];
        [_resultTextView setTextColor:[UIColor labelColor]];
        [_resultTextView setEditable:NO];
        [_resultTextView setSelectable:NO];
        [_resultTextView setAutomaticallyAdjustsScrollIndicatorInsets:NO];
        [_resultTextView setContentInsetAdjustmentBehavior:UIScrollViewContentInsetAdjustmentNever];
        [_resultTextView setTextContainerInset:UIEdgeInsetsMake(8, 16, 8, 16)];
        [[_resultTextView textContainer] setLineFragmentPadding:0];
        [_resultView addSubview:_resultTextView];

        _resultCountLabel = [[UILabel alloc] init];
        [_resultCountLabel setFont:[UIFont systemFontOfSize:13 weight:UIFontWeightRegular]];
        [_resultCountLabel setTextColor:[UIColor secondaryLabelColor]];
        [_resultCountLabel setNumberOfLines:1];
        [_resultCountLabel setHidden:YES];

        _resultCopyButton = [self footerButtonWithTitle:KayokoScriptPanelLocalizedString(@"Copy", @"Copy")
                                           weight:UIFontWeightMedium];
        _resultPasteButton = [self footerButtonWithTitle:KayokoScriptPanelLocalizedString(@"Paste", @"Paste")
                                            weight:UIFontWeightSemibold];
        [self setDefaultCopyTitle:KayokoScriptPanelLocalizedString(@"Copy", @"Copy")];

        UIStackView *buttonStackView =
            [[UIStackView alloc] initWithArrangedSubviews:@[ _resultCopyButton, _resultPasteButton ]];
        [buttonStackView setAxis:UILayoutConstraintAxisHorizontal];
        [buttonStackView setDistribution:UIStackViewDistributionFillEqually];
        [buttonStackView setSpacing:12];

        UIStackView *footerStackView =
            [[UIStackView alloc] initWithArrangedSubviews:@[ _resultCountLabel, buttonStackView ]];
        [footerStackView setAxis:UILayoutConstraintAxisVertical];
        [footerStackView setSpacing:8];
        [self setFooterStackView:footerStackView];
        [_resultView addSubview:footerStackView];

        [self activateConstraints];
        [self setSearchBarVisible:NO];
        [self showList];
    }

    return self;
}

#pragma mark - Layout

- (UIButton *)footerButtonWithTitle:(NSString *)title weight:(UIFontWeight)weight {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    [[button titleLabel] setFont:[UIFont systemFontOfSize:16 weight:weight]];
    [button setBackgroundColor:[UIColor tertiarySystemFillColor]];
    [[button layer] setCornerRadius:10];
    [button setClipsToBounds:YES];
    [button setTranslatesAutoresizingMaskIntoConstraints:NO];
    return button;
}

- (void)activateConstraints {
    UIView *headerView = [self headerView];
    UIView *transitionContentView = [self transitionContentView];
    UIView *tableView = [self tableView];
    UIView *noticeLabel = [self noticeLabel];
    UIView *resultView = [self resultView];
    UIView *resultTextView = [self resultTextView];
    UIStackView *footerStackView = [self footerStackView];
    UIView *searchBar = [self searchBar];
    UILayoutGuide *safeArea = [self safeAreaLayoutGuide];

    for (UIView *view in @[
             headerView, transitionContentView, tableView, noticeLabel, resultView, resultTextView, footerStackView,
             searchBar
         ]) {
        [view setTranslatesAutoresizingMaskIntoConstraints:NO];
    }

    NSLayoutConstraint *searchBarHeight = [[searchBar heightAnchor] constraintEqualToConstant:0];
    [self setSearchBarHeightConstraint:searchBarHeight];

    [NSLayoutConstraint activateConstraints:@[
        [[headerView topAnchor] constraintEqualToAnchor:[self topAnchor]],
        [[headerView leadingAnchor] constraintEqualToAnchor:[self leadingAnchor]],
        [[headerView trailingAnchor] constraintEqualToAnchor:[self trailingAnchor]],
        [[headerView heightAnchor] constraintEqualToConstant:[KayokoHeaderView preferredHeight]],

        [[searchBar topAnchor] constraintEqualToAnchor:[headerView bottomAnchor]],
        [[searchBar leadingAnchor] constraintEqualToAnchor:[safeArea leadingAnchor]],
        [[searchBar trailingAnchor] constraintEqualToAnchor:[safeArea trailingAnchor]],
        searchBarHeight,

        [[transitionContentView topAnchor] constraintEqualToAnchor:[searchBar bottomAnchor]],
        [[transitionContentView leadingAnchor] constraintEqualToAnchor:[self leadingAnchor]],
        [[transitionContentView trailingAnchor] constraintEqualToAnchor:[self trailingAnchor]],
        [[transitionContentView bottomAnchor] constraintEqualToAnchor:[self bottomAnchor]],

        [[tableView topAnchor] constraintEqualToAnchor:[searchBar bottomAnchor]],
        [[tableView leadingAnchor] constraintEqualToAnchor:[safeArea leadingAnchor]],
        [[tableView trailingAnchor] constraintEqualToAnchor:[safeArea trailingAnchor]],
        [[tableView bottomAnchor] constraintEqualToAnchor:[safeArea bottomAnchor]],

        [[noticeLabel centerXAnchor] constraintEqualToAnchor:[transitionContentView centerXAnchor]],
        [[noticeLabel centerYAnchor] constraintEqualToAnchor:[transitionContentView centerYAnchor]],
        [[noticeLabel leadingAnchor] constraintGreaterThanOrEqualToAnchor:[self leadingAnchor] constant:32],
        [[noticeLabel trailingAnchor] constraintLessThanOrEqualToAnchor:[self trailingAnchor] constant:-32],

        [[resultView topAnchor] constraintEqualToAnchor:[tableView topAnchor]],
        [[resultView leadingAnchor] constraintEqualToAnchor:[tableView leadingAnchor]],
        [[resultView trailingAnchor] constraintEqualToAnchor:[tableView trailingAnchor]],
        [[resultView bottomAnchor] constraintEqualToAnchor:[tableView bottomAnchor]],

        [[resultTextView topAnchor] constraintEqualToAnchor:[resultView topAnchor]],
        [[resultTextView leadingAnchor] constraintEqualToAnchor:[resultView leadingAnchor]],
        [[resultTextView trailingAnchor] constraintEqualToAnchor:[resultView trailingAnchor]],
        [[resultTextView bottomAnchor] constraintEqualToAnchor:[footerStackView topAnchor] constant:-12],

        [[footerStackView leadingAnchor] constraintEqualToAnchor:[resultView leadingAnchor]
                                                        constant:kKayokoScriptPanelFooterHorizontalInset],
        [[footerStackView trailingAnchor] constraintEqualToAnchor:[resultView trailingAnchor]
                                                         constant:-kKayokoScriptPanelFooterHorizontalInset],
        [[footerStackView bottomAnchor] constraintEqualToAnchor:[safeArea bottomAnchor]
                                                       constant:-kKayokoScriptPanelFooterBottomInset],

        [[[self resultCopyButton] heightAnchor] constraintEqualToConstant:kKayokoScriptPanelButtonHeight],
        [[[self resultPasteButton] heightAnchor] constraintEqualToConstant:kKayokoScriptPanelButtonHeight],
    ]];
}

#pragma mark - Content

- (void)setTitleText:(NSString *)title {
    [[self headerView] setTitleText:title];
}

- (void)setSearchBarVisible:(BOOL)visible {
    [self setSearchBarVisible:visible animated:NO];
}

- (void)setSearchBarVisible:(BOOL)visible animated:(BOOL)animated {
    UISearchBar *searchBar = [self searchBar];
    if (visible) {
        [searchBar setHidden:NO];
    }

    void (^apply)(void) = ^{
      [searchBar setAlpha:(visible ? 1.0 : 0.0)];
      [[self searchBarHeightConstraint] setConstant:(visible ? 44.0 : 0.0)];
      [self layoutIfNeeded];
    };

    if (!animated) {
        apply();
        [searchBar setHidden:!visible];
        return;
    }

    [UIView animateWithDuration:0.22
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:apply
                     completion:^(BOOL finished) {
                       if (!visible) {
                           [searchBar setHidden:YES];
                       }
                     }];
}

- (void)showList {
    [[self resultView] setHidden:YES];
    [[self tableView] setHidden:NO];
    [[self tableView] reloadData];
    [self layoutIfNeeded];
    [self applyListRestPosition];
    [self showNotice:nil];
}

- (void)showResultWithText:(NSString *)text countText:(nullable NSString *)countText {
    // The failure page hides the paste button and renames the copy one, so both are put back before a real
    // result is shown.
    [[self resultPasteButton] setHidden:NO];
    [[self resultCopyButton] setTitle:[self defaultCopyTitle] forState:UIControlStateNormal];
    [[self resultTextView] setText:text ?: @""];
    [[self resultTextView] setContentOffset:CGPointZero animated:NO];
    [[self resultCountLabel] setText:countText];
    [[self resultCountLabel] setHidden:([countText length] == 0)];
    [[self resultView] setHidden:NO];
    [[self tableView] setHidden:YES];
    [self showNotice:nil];
}

- (void)showFailureWithText:(NSString *)text copyTitle:(NSString *)copyTitle {
    [[self resultPasteButton] setHidden:YES];
    [[self resultCopyButton] setTitle:copyTitle forState:UIControlStateNormal];
    [[self resultTextView] setText:text ?: @""];
    [[self resultTextView] setContentOffset:CGPointZero animated:NO];
    [[self resultCountLabel] setText:nil];
    [[self resultCountLabel] setHidden:YES];
    [[self resultView] setHidden:NO];
    [[self tableView] setHidden:YES];
    [self showNotice:nil];
}

- (void)showNotice:(nullable NSString *)notice {
    [[self noticeLabel] setText:notice];
    [[self noticeLabel] setHidden:([notice length] == 0)];
}

#pragma mark - List Rest Position

- (void)applyListRestPosition {
    // The rest position of a table with a top inset is simply minus that inset, so one explicit move is all the
    // panel needs; fighting -setContentOffset: afterwards only made the list disagree with itself.
    CGPoint restOffset = CGPointMake(0, -kKayokoScriptPanelListTopInset);
    if (!CGPointEqualToPoint([[self tableView] contentOffset], restOffset)) {
        [[self tableView] setContentOffset:restOffset animated:NO];
    }
}

@end
