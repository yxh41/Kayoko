//
//  KayokoScriptPanelView.m
//  Kayoko
//

#import "KayokoScriptPanelView.h"

#import "KayokoEdgeFadingTextView.h"
#import "KayokoHeaderButtonStyle.h"
#import "KayokoHeaderView.h"
#import "KayokoPasteboardManager.h"

static CGFloat const kKayokoScriptPanelVerticalFadeHeight = 24;
static CGFloat const kKayokoScriptPanelFooterHorizontalInset = 16;
static CGFloat const kKayokoScriptPanelFooterBottomInset = 12;
static CGFloat const kKayokoScriptPanelButtonHeight = 40;
static CGFloat const kKayokoScriptPanelListTopInset = 8;
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
@property(nonatomic, strong) UIStackView *footerStackView;

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

        // The header has to stay put while content slides, so everything else lives in its own container.
        _transitionContentView = [[UIView alloc] init];
        [self addSubview:_transitionContentView];

        _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
        [_tableView setBackgroundColor:[UIColor clearColor]];
        [_tableView setSeparatorStyle:UITableViewCellSeparatorStyleSingleLine];
        [_tableView setSeparatorInset:UIEdgeInsetsMake(0, 16, 0, 0)];
        [_tableView setRowHeight:52];
        [_tableView setEstimatedRowHeight:52];
        // The panel is shown before its final bounds are known, and UIKit's automatic inset adjustment used to
        // hand back a stale safe-area value at that moment: the list then started above the header and the
        // first row was clipped. A fixed inset keeps the rest position deterministic.
        [_tableView setContentInsetAdjustmentBehavior:UIScrollViewContentInsetAdjustmentNever];
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
    UILayoutGuide *safeArea = [self safeAreaLayoutGuide];

    for (UIView *view in @[
             headerView, transitionContentView, tableView, noticeLabel, resultView, resultTextView, footerStackView
         ]) {
        [view setTranslatesAutoresizingMaskIntoConstraints:NO];
    }

    [NSLayoutConstraint activateConstraints:@[
        [[headerView topAnchor] constraintEqualToAnchor:[self topAnchor]],
        [[headerView leadingAnchor] constraintEqualToAnchor:[self leadingAnchor]],
        [[headerView trailingAnchor] constraintEqualToAnchor:[self trailingAnchor]],
        [[headerView heightAnchor] constraintEqualToConstant:[KayokoHeaderView preferredHeight]],

        [[transitionContentView topAnchor] constraintEqualToAnchor:[headerView bottomAnchor]],
        [[transitionContentView leadingAnchor] constraintEqualToAnchor:[self leadingAnchor]],
        [[transitionContentView trailingAnchor] constraintEqualToAnchor:[self trailingAnchor]],
        [[transitionContentView bottomAnchor] constraintEqualToAnchor:[self bottomAnchor]],

        [[tableView topAnchor] constraintEqualToAnchor:[transitionContentView topAnchor]],
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

- (void)showList {
    [[self resultView] setHidden:YES];
    [[self tableView] setHidden:NO];
    [[self tableView] reloadData];
    [self layoutIfNeeded];
    [[self tableView] setContentOffset:CGPointMake(0, -kKayokoScriptPanelListTopInset) animated:NO];
    [self showNotice:nil];
}

- (void)showResultWithText:(NSString *)text countText:(nullable NSString *)countText {
    [[self resultTextView] setText:text ?: @""];
    [[self resultTextView] setContentOffset:CGPointZero animated:NO];
    [[self resultCountLabel] setText:countText];
    [[self resultCountLabel] setHidden:([countText length] == 0)];
    [[self resultView] setHidden:NO];
    [[self tableView] setHidden:YES];
    [self showNotice:nil];
}

- (void)showNotice:(nullable NSString *)notice {
    [[self noticeLabel] setText:notice];
    [[self noticeLabel] setHidden:([notice length] == 0)];
}

@end
