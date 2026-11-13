//
//  KayokoPasteboardSummary.m
//  Kayoko
//

#import "KayokoPasteboardSummary.h"

#import "KayokoPasteboardItem.h"
#import "KayokoPasteboardManager.h"

#import <objc/runtime.h>

/// Kept as the 4.3.42 build-evidence tag; the card itself now shows a history
/// breakdown rather than a snapshot of UIPasteboard.generalPasteboard.
static NSString *const kKayokoSummaryBuildTag = @"KayokoPasteboardSummary-4.3.42";
static NSString *const kKayokoSummaryBreakdownTag = @"KayokoHistoryBreakdown-4.3.43";
static NSString *const kKayokoSummaryHistoryGateTag = @"KayokoSummaryHistoryOnly-4.3.43";
static NSString *const kKayokoSummaryDeleteTag = @"KayokoSummaryDeleteRow-4.3.43";
/// 4.3.44: the delete buttons now call the public completion-bearing removal
/// API, so the popover refreshes from the exact post-animation item list.
static NSString *const kKayokoSummaryDeleteAPITag = @"KayokoSummaryDeletePublicAPI-4.3.44";
static NSString *const kKayokoSummaryHintFallback =
    @"Long press the grabber to inspect the current pasteboard (4.3.42). Tap outside to close.";
static char kKayokoSummaryAssociatedItemKey = 0;
static NSUInteger const kKayokoSummaryRowsPerGroup = 6;

static NSString *KayokoSummaryLocalized(NSString *key, NSString *fallback) {
    return [[KayokoPasteboardManager localizationBundle] localizedStringForKey:key value:fallback table:@"Tweak"];
}

static NSString *KayokoSummaryByteString(unsigned long long byteCount) {
    return [NSByteCountFormatter stringFromByteCount:(long long)byteCount
                                          countStyle:NSByteCountFormatterCountStyleFile];
}

/// Bounded so a long note or a pasted article cannot allocate an unbounded
/// string on SpringBoard's main thread.
static NSString *KayokoSummaryPreviewFromValue(id value) {
    NSString *text = nil;
    if ([value isKindOfClass:[NSString class]]) {
        text = value;
    } else if ([value isKindOfClass:[NSURL class]]) {
        text = [(NSURL *)value absoluteString];
    }
    if ([text length] == 0) {
        return @"";
    }
    text = [[text stringByReplacingOccurrencesOfString:@"\n" withString:@" "]
        stringByReplacingOccurrencesOfString:@"\r"
                                  withString:@" "];
    if ([text length] > 100) {
        text = [[text substringToIndex:100] stringByAppendingString:@"..."];
    }
    return text;
}

static NSString *KayokoSummaryKindKey(KayokoSummaryKind kind) {
    switch (kind) {
    case KayokoSummaryKindImage:
        return @"Pasteboard Summary Kind Image";
    case KayokoSummaryKindText:
        return @"Pasteboard Summary Kind Text";
    case KayokoSummaryKindLink:
        return @"Pasteboard Summary Kind Link";
    case KayokoSummaryKindRichText:
        return @"Pasteboard Summary Kind Rich Text";
    case KayokoSummaryKindOther:
    default:
        return @"Pasteboard Summary Kind Other";
    }
}

static NSString *KayokoSummaryKindFallback(KayokoSummaryKind kind) {
    switch (kind) {
    case KayokoSummaryKindImage:
        return @"Image";
    case KayokoSummaryKindText:
        return @"Text";
    case KayokoSummaryKindLink:
        return @"Link";
    case KayokoSummaryKindRichText:
        return @"Rich Text";
    case KayokoSummaryKindOther:
    default:
        return @"Other";
    }
}

/// Classification uses only the keys Kayoko itself writes into a history row.
/// No UIPasteboard access, no image decoding, no disk I/O.
static KayokoSummaryKind KayokoSummaryKindForItem(NSDictionary<NSString *, id> *item) {
    NSString *imageName = item[kKayokoItemKeyImageName];
    if ([imageName isKindOfClass:[NSString class]] && [imageName length] > 0) {
        return KayokoSummaryKindImage;
    }

    NSString *richUTI = item[kKayokoItemKeyRichTextUTI];
    NSString *richName = item[kKayokoItemKeyRichTextName];
    if (([richUTI isKindOfClass:[NSString class]] && [richUTI length] > 0) ||
        ([richName isKindOfClass:[NSString class]] && [richName length] > 0)) {
        return KayokoSummaryKindRichText;
    }

    if ([item[kKayokoItemKeyHasLink] boolValue]) {
        return KayokoSummaryKindLink;
    }

    NSString *content = item[kKayokoItemKeyContent];
    if ([content isKindOfClass:[NSString class]] && [content length] > 0) {
        return KayokoSummaryKindText;
    }
    return KayokoSummaryKindOther;
}

static NSString *KayokoSummaryDetailForItem(NSDictionary<NSString *, id> *item, KayokoSummaryKind kind) {
    if (kind == KayokoSummaryKindImage) {
        NSUInteger width = [item[kKayokoItemKeyImagePixelWidth] unsignedIntegerValue];
        NSUInteger height = [item[kKayokoItemKeyImagePixelHeight] unsignedIntegerValue];
        unsigned long long bytes = [item[kKayokoItemKeyImageByteCount] unsignedLongLongValue];
        if (width > 0 && height > 0) {
            NSString *format = KayokoSummaryLocalized(@"Pasteboard Summary Pixels", @"%lu x %lu px | %@");
            return [NSString stringWithFormat:format, (unsigned long)width, (unsigned long)height,
                                              KayokoSummaryByteString(bytes)];
        }
        return KayokoSummaryByteString(bytes);
    }

    if (kind == KayokoSummaryKindRichText) {
        NSString *name = item[kKayokoItemKeyRichTextName];
        if ([name isKindOfClass:[NSString class]] && [name length] > 0) {
            return name;
        }
        NSString *uti = item[kKayokoItemKeyRichTextUTI];
        return [uti isKindOfClass:[NSString class]] ? uti : @"";
    }

    NSString *content = item[kKayokoItemKeyContent];
    NSUInteger characters = [content isKindOfClass:[NSString class]] ? [content length] : 0;
    NSString *format = KayokoSummaryLocalized(@"Pasteboard Summary Characters", @"%lu characters");
    return [NSString stringWithFormat:format, (unsigned long)characters];
}

static NSString *KayokoSummaryPreviewForItem(NSDictionary<NSString *, id> *item, KayokoSummaryKind kind) {
    if (kind == KayokoSummaryKindImage) {
        NSString *name = item[kKayokoItemKeyImageName];
        return [name isKindOfClass:[NSString class]] ? KayokoSummaryPreviewFromValue(name) : @"";
    }
    return KayokoSummaryPreviewFromValue(item[kKayokoItemKeyContent]);
}

#pragma mark - History breakdown

@implementation KayokoPasteboardSummary

+ (NSDictionary<NSString *, id> *)entryForItem:(NSDictionary<NSString *, id> *)item {
    KayokoSummaryKind kind = KayokoSummaryKindForItem(item);
    return @{
        @"item" : item,
        @"kind" : @(kind),
        @"detail" : KayokoSummaryDetailForItem(item, kind),
        @"preview" : KayokoSummaryPreviewForItem(item, kind)
    };
}

+ (NSArray<NSDictionary<NSString *, id> *> *)groupsForItems:(NSArray<NSDictionary<NSString *, id> *> *)items {
    NSMutableArray<NSMutableArray<NSDictionary<NSString *, id> *> *> *buckets =
        [[NSMutableArray alloc] initWithCapacity:KayokoSummaryKindCount];
    for (NSUInteger kind = 0; kind < KayokoSummaryKindCount; kind++) {
        [buckets addObject:[[NSMutableArray alloc] init]];
    }

    for (id candidate in items ?: @[]) {
        if (![candidate isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary<NSString *, id> *item = candidate;
        NSDictionary<NSString *, id> *entry = [self entryForItem:item];
        NSUInteger kind = [entry[@"kind"] unsignedIntegerValue];
        if (kind < KayokoSummaryKindCount) {
            [buckets[kind] addObject:entry];
        }
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *groups =
        [[NSMutableArray alloc] initWithCapacity:KayokoSummaryKindCount];
    for (NSUInteger kind = 0; kind < KayokoSummaryKindCount; kind++) {
        NSArray<NSDictionary<NSString *, id> *> *entries = buckets[kind];
        if ([entries count] == 0) {
            continue;
        }
        [groups addObject:@{
            @"kind" : @(kind),
            @"kindKey" : KayokoSummaryKindKey((KayokoSummaryKind)kind),
            @"kindFallback" : KayokoSummaryKindFallback((KayokoSummaryKind)kind),
            @"count" : @([entries count]),
            @"entries" : entries
        }];
    }
    return groups;
}

@end

NS_ASSUME_NONNULL_BEGIN

@interface KayokoPasteboardSummaryView ()
@property(nonatomic, strong) UIView *cardView;
@property(nonatomic, strong) UIVisualEffectView *materialView;
@property(nonatomic, strong) UILabel *countLabel;
@property(nonatomic, strong) UILabel *breakdownLabel;
@property(nonatomic, strong) UIStackView *groupsStackView;
@property(nonatomic, assign) BOOL isDismissing;
@end

NS_ASSUME_NONNULL_END

@implementation KayokoPasteboardSummaryView

#pragma mark - Lifecycle

- (instancetype)init {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        [self setAccessibilityIdentifier:kKayokoSummaryBuildTag];
        [self setBackgroundColor:[[UIColor blackColor] colorWithAlphaComponent:0.22]];

        UITapGestureRecognizer *backdropTap =
            [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleBackdropTap:)];
        [backdropTap setCancelsTouchesInView:NO];
        [self addGestureRecognizer:backdropTap];

        [self buildCard];
    }
    return self;
}

- (void)buildCard {
    // The panel itself is a UIBlurEffectStyleRegular material view. The card
    // uses the very same style; a transparent shadow host keeps the shadow
    // outside the clipped, rounded glass layer.
    UIView *card = [[UIView alloc] init];
    [card setBackgroundColor:[UIColor clearColor]];
    [card setAccessibilityIdentifier:kKayokoSummaryHistoryGateTag];
    [[card layer] setShadowColor:[[UIColor blackColor] CGColor]];
    [[card layer] setShadowOpacity:0.18];
    [[card layer] setShadowRadius:20];
    [[card layer] setShadowOffset:CGSizeMake(0, 8)];
    [self addSubview:card];
    [self setCardView:card];

    [card setTranslatesAutoresizingMaskIntoConstraints:NO];
    NSLayoutConstraint *preferredWidth = [[card widthAnchor] constraintEqualToConstant:320];
    [preferredWidth setPriority:UILayoutPriorityDefaultHigh];
    [NSLayoutConstraint activateConstraints:@[
        [[card centerXAnchor] constraintEqualToAnchor:[self centerXAnchor]],
        [[card centerYAnchor] constraintEqualToAnchor:[self centerYAnchor]],
        preferredWidth,
        [[card widthAnchor] constraintLessThanOrEqualToConstant:320],
        [[card widthAnchor] constraintLessThanOrEqualToAnchor:[self widthAnchor] constant:-40],
        [[card heightAnchor] constraintLessThanOrEqualToAnchor:[self heightAnchor] constant:-40]
    ]];

    UIVisualEffectView *glass =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleRegular]];
    [glass setClipsToBounds:YES];
    [[glass layer] setCornerRadius:16];
    [card addSubview:glass];
    [self setMaterialView:glass];
    [glass setTranslatesAutoresizingMaskIntoConstraints:NO];
    [NSLayoutConstraint activateConstraints:@[
        [[glass topAnchor] constraintEqualToAnchor:[card topAnchor]],
        [[glass leadingAnchor] constraintEqualToAnchor:[card leadingAnchor]],
        [[glass trailingAnchor] constraintEqualToAnchor:[card trailingAnchor]],
        [[glass bottomAnchor] constraintEqualToAnchor:[card bottomAnchor]]
    ]];

    UIStackView *root = [[UIStackView alloc] init];
    [root setAxis:UILayoutConstraintAxisVertical];
    [root setAlignment:UIStackViewAlignmentFill];
    [root setSpacing:12];
    [[glass contentView] addSubview:root];
    [root setTranslatesAutoresizingMaskIntoConstraints:NO];
    [NSLayoutConstraint activateConstraints:@[
        [[root topAnchor] constraintEqualToAnchor:[[glass contentView] topAnchor] constant:18],
        [[root leadingAnchor] constraintEqualToAnchor:[[glass contentView] leadingAnchor] constant:18],
        [[root trailingAnchor] constraintEqualToAnchor:[[glass contentView] trailingAnchor] constant:-18],
        [[root bottomAnchor] constraintEqualToAnchor:[[glass contentView] bottomAnchor] constant:-18]
    ]];

    UIStackView *header = [[UIStackView alloc] init];
    [header setAxis:UILayoutConstraintAxisHorizontal];
    [header setAlignment:UIStackViewAlignmentCenter];
    [header setSpacing:8];
    [root addArrangedSubview:header];

    UILabel *titleLabel = [[UILabel alloc] init];
    [titleLabel setText:KayokoSummaryLocalized(@"Pasteboard Summary", @"History Breakdown")];
    [titleLabel setFont:[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]];
    [titleLabel setTextColor:[UIColor labelColor]];
    [header addArrangedSubview:titleLabel];

    UIView *flex = [[UIView alloc] init];
    [flex setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisHorizontal];
    [header addArrangedSubview:flex];

    UILabel *countLabel = [[UILabel alloc] init];
    [countLabel setFont:[UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium]];
    [countLabel setTextColor:[UIColor secondaryLabelColor]];
    [countLabel setTextAlignment:NSTextAlignmentRight];
    [header addArrangedSubview:countLabel];
    [self setCountLabel:countLabel];

    UILabel *breakdownLabel = [[UILabel alloc] init];
    [breakdownLabel setAccessibilityIdentifier:kKayokoSummaryBreakdownTag];
    [breakdownLabel setFont:[UIFont systemFontOfSize:12 weight:UIFontWeightMedium]];
    [breakdownLabel setTextColor:[UIColor secondaryLabelColor]];
    [breakdownLabel setNumberOfLines:2];
    [root addArrangedSubview:breakdownLabel];
    [self setBreakdownLabel:breakdownLabel];

    UIScrollView *scrollView = [[UIScrollView alloc] init];
    [scrollView setShowsVerticalScrollIndicator:YES];
    [scrollView setAlwaysBounceVertical:NO];
    // 4.3.45: content is edge-pinned to the scroll view because the SDK
    // headers lack the modern guide properties; the tag below marks the build.
    [scrollView setAccessibilityIdentifier:@"KayokoSummaryScrollEdgePins-4.3.45"];
    [root addArrangedSubview:scrollView];
    [scrollView setTranslatesAutoresizingMaskIntoConstraints:NO];
    // A UIScrollView has no intrinsic height, so without an explicit preferred
    // height the stack would collapse it to zero. The preferred/minimum values
    // stay below required priority so a short panel can still shrink the card.
    NSLayoutConstraint *preferredScrollHeight = [[scrollView heightAnchor] constraintEqualToConstant:200];
    [preferredScrollHeight setPriority:UILayoutPriorityDefaultLow];
    NSLayoutConstraint *minimumScrollHeight =
        [[scrollView heightAnchor] constraintGreaterThanOrEqualToConstant:60];
    [minimumScrollHeight setPriority:UILayoutPriorityDefaultHigh];
    [NSLayoutConstraint activateConstraints:@[
        [[scrollView heightAnchor] constraintLessThanOrEqualToConstant:260],
        preferredScrollHeight, minimumScrollHeight
    ]];

    UIStackView *groupsStack = [[UIStackView alloc] init];
    [groupsStack setAxis:UILayoutConstraintAxisVertical];
    [groupsStack setAlignment:UIStackViewAlignmentFill];
    [groupsStack setSpacing:12];
    [scrollView addSubview:groupsStack];
    [groupsStack setAccessibilityIdentifier:kKayokoSummaryDeleteAPITag];
    [self setGroupsStackView:groupsStack];
    [groupsStack setTranslatesAutoresizingMaskIntoConstraints:NO];
    [NSLayoutConstraint activateConstraints:@[
        [[groupsStack topAnchor] constraintEqualToAnchor:[scrollView topAnchor]],
        [[groupsStack leadingAnchor] constraintEqualToAnchor:[scrollView leadingAnchor]],
        [[groupsStack trailingAnchor] constraintEqualToAnchor:[scrollView trailingAnchor]],
        [[groupsStack bottomAnchor] constraintEqualToAnchor:[scrollView bottomAnchor]],
        [[groupsStack widthAnchor] constraintEqualToAnchor:[scrollView widthAnchor]]
    ]];

    UILabel *hintLabel = [[UILabel alloc] init];
    [hintLabel setText:KayokoSummaryLocalized(@"Pasteboard Summary Hint", kKayokoSummaryHintFallback)];
    [hintLabel setFont:[UIFont systemFontOfSize:11]];
    [hintLabel setTextColor:[UIColor tertiaryLabelColor]];
    [hintLabel setNumberOfLines:0];
    [root addArrangedSubview:hintLabel];

    UIButton *doneButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [doneButton setTitle:KayokoSummaryLocalized(@"Pasteboard Summary Done", @"Done")
                forState:UIControlStateNormal];
    [[doneButton titleLabel] setFont:[UIFont systemFontOfSize:16 weight:UIFontWeightMedium]];
    [doneButton setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    [doneButton setBackgroundColor:[UIColor tertiarySystemFillColor]];
    [[doneButton layer] setCornerRadius:8];
    [doneButton setClipsToBounds:YES];
    [doneButton addTarget:self action:@selector(handleDoneButton) forControlEvents:UIControlEventTouchUpInside];
    [root addArrangedSubview:doneButton];
    [NSLayoutConstraint activateConstraints:@[ [[doneButton heightAnchor] constraintEqualToConstant:36] ]];
}

#pragma mark - Content

- (void)reloadWithItems:(NSArray<NSDictionary<NSString *, id> *> *)items {
    for (UIView *arranged in [[self groupsStackView] arrangedSubviews]) {
        [arranged removeFromSuperview];
    }

    NSArray<NSDictionary<NSString *, id> *> *safeItems = items ?: @[];
    NSUInteger total = 0;
    for (id candidate in safeItems) {
        if ([candidate isKindOfClass:[NSDictionary class]]) {
            total++;
        }
    }
    NSString *countFormat = KayokoSummaryLocalized(@"Pasteboard Summary Count", @"%lu items");
    [[self countLabel] setText:[NSString stringWithFormat:countFormat, (unsigned long)total]];

    NSArray<NSDictionary<NSString *, id> *> *groups = [KayokoPasteboardSummary groupsForItems:safeItems];
    NSMutableArray<NSString *> *chips = [[NSMutableArray alloc] initWithCapacity:[groups count]];
    for (NSDictionary<NSString *, id> *group in groups) {
        NSString *name = KayokoSummaryLocalized(group[@"kindKey"], group[@"kindFallback"]);
        NSString *chipFormat = KayokoSummaryLocalized(@"Pasteboard Summary Chip", @"%@ x %lu");
        [chips addObject:[NSString stringWithFormat:chipFormat, name,
                                                    (unsigned long)[group[@"count"] unsignedIntegerValue]]];
    }
    [[self breakdownLabel] setText:[chips componentsJoinedByString:@"  |  "]];

    if ([groups count] == 0) {
        UILabel *emptyLabel = [[UILabel alloc] init];
        [emptyLabel setText:KayokoSummaryLocalized(@"Pasteboard Summary Empty", @"History is empty.")];
        [emptyLabel setFont:[UIFont systemFontOfSize:13]];
        [emptyLabel setTextColor:[UIColor secondaryLabelColor]];
        [emptyLabel setNumberOfLines:0];
        [[self groupsStackView] addArrangedSubview:emptyLabel];
        return;
    }

    for (NSDictionary<NSString *, id> *group in groups) {
        [[self groupsStackView] addArrangedSubview:[self headerForGroup:group]];

        NSArray<NSDictionary<NSString *, id> *> *entries = group[@"entries"];
        NSUInteger visible = MIN([entries count], kKayokoSummaryRowsPerGroup);
        for (NSUInteger index = 0; index < visible; index++) {
            [[self groupsStackView] addArrangedSubview:[self rowForEntry:entries[index]]];
        }
        if ([entries count] > visible) {
            NSString *moreFormat = KayokoSummaryLocalized(@"Pasteboard Summary More", @"+ %lu more");
            UILabel *moreLabel = [[UILabel alloc] init];
            [moreLabel setText:[NSString stringWithFormat:moreFormat,
                                                         (unsigned long)([entries count] - visible)]];
            [moreLabel setFont:[UIFont systemFontOfSize:12]];
            [moreLabel setTextColor:[UIColor tertiaryLabelColor]];
            [[self groupsStackView] addArrangedSubview:moreLabel];
        }
    }
}

- (UIView *)headerForGroup:(NSDictionary<NSString *, id> *)group {
    UIStackView *header = [[UIStackView alloc] init];
    [header setAxis:UILayoutConstraintAxisHorizontal];
    [header setAlignment:UIStackViewAlignmentCenter];
    [header setSpacing:8];

    UILabel *kindLabel = [[UILabel alloc] init];
    [kindLabel setText:KayokoSummaryLocalized(group[@"kindKey"], group[@"kindFallback"])];
    [kindLabel setFont:[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]];
    [kindLabel setTextColor:[UIColor labelColor]];
    [header addArrangedSubview:kindLabel];

    UIView *flex = [[UIView alloc] init];
    [flex setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisHorizontal];
    [header addArrangedSubview:flex];

    UILabel *badge = [[UILabel alloc] init];
    [badge setText:[NSString stringWithFormat:@"%lu", (unsigned long)[group[@"count"] unsignedIntegerValue]]];
    [badge setFont:[UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold]];
    [badge setTextColor:[UIColor secondaryLabelColor]];
    [header addArrangedSubview:badge];

    return header;
}

- (UIView *)rowForEntry:(NSDictionary<NSString *, id> *)entry {
    UIStackView *row = [[UIStackView alloc] init];
    [row setAxis:UILayoutConstraintAxisHorizontal];
    [row setAlignment:UIStackViewAlignmentCenter];
    [row setSpacing:8];

    UIStackView *texts = [[UIStackView alloc] init];
    [texts setAxis:UILayoutConstraintAxisVertical];
    [texts setAlignment:UIStackViewAlignmentFill];
    [texts setSpacing:2];
    [row addArrangedSubview:texts];

    NSString *preview = entry[@"preview"];
    UILabel *previewLabel = [[UILabel alloc] init];
    [previewLabel setText:[preview length] > 0
                              ? preview
                              : KayokoSummaryLocalized(@"Pasteboard Summary Untitled", @"(no preview)")];
    [previewLabel setFont:[UIFont systemFontOfSize:12]];
    [previewLabel setTextColor:[UIColor labelColor]];
    [previewLabel setNumberOfLines:2];
    [texts addArrangedSubview:previewLabel];

    NSString *detail = entry[@"detail"];
    if ([detail length] > 0) {
        UILabel *detailLabel = [[UILabel alloc] init];
        [detailLabel setText:detail];
        [detailLabel setFont:[UIFont systemFontOfSize:11]];
        [detailLabel setTextColor:[UIColor secondaryLabelColor]];
        [detailLabel setNumberOfLines:1];
        [texts addArrangedSubview:detailLabel];
    }

    UIButton *deleteButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [deleteButton setImage:[UIImage systemImageNamed:@"trash.fill"] forState:UIControlStateNormal];
    [deleteButton setTintColor:[UIColor systemRedColor]];
    [deleteButton setAccessibilityIdentifier:kKayokoSummaryDeleteTag];
    [deleteButton setAccessibilityLabel:KayokoSummaryLocalized(@"Pasteboard Summary Delete", @"Delete")];
    objc_setAssociatedObject(deleteButton, &kKayokoSummaryAssociatedItemKey, entry[@"item"],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [deleteButton addTarget:self
                     action:@selector(handleDeleteButton:)
           forControlEvents:UIControlEventTouchUpInside];
    [row addArrangedSubview:deleteButton];
    [NSLayoutConstraint activateConstraints:@[
        [[deleteButton widthAnchor] constraintEqualToConstant:34],
        [[deleteButton heightAnchor] constraintEqualToConstant:34]
    ]];

    return row;
}

#pragma mark - Presentation

- (void)showInView:(UIView *)view
             items:(NSArray<NSDictionary<NSString *, id> *> *)items
          animated:(BOOL)animated {
    [self setOverrideUserInterfaceStyle:[view overrideUserInterfaceStyle]];
    [self setFrame:[view bounds]];
    [self setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
    [view addSubview:self];
    [self reloadWithItems:items];

    if (!animated) {
        return;
    }
    [self setAlpha:0];
    [[self cardView] setAlpha:0];
    [[self cardView] setTransform:CGAffineTransformMakeScale(0.94, 0.94)];
    [UIView animateWithDuration:0.28
                          delay:0
         usingSpringWithDamping:0.86
          initialSpringVelocity:0.6
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
                       [self setAlpha:1];
                       [[self cardView] setAlpha:1];
                       [[self cardView] setTransform:CGAffineTransformIdentity];
                     }
                     completion:nil];
}

- (void)dismissAnimated:(BOOL)animated {
    if ([self isDismissing]) {
        return;
    }
    [self setIsDismissing:YES];

    if (!animated) {
        [self removeFromSuperview];
        return;
    }
    [UIView animateWithDuration:0.2
        delay:0
        options:UIViewAnimationOptionCurveEaseIn
        animations:^{
          [self setAlpha:0];
          [[self cardView] setTransform:CGAffineTransformMakeScale(0.96, 0.96)];
        }
        completion:^(__unused BOOL finished) {
          [self removeFromSuperview];
        }];
}

#pragma mark - Actions

- (void)handleDeleteButton:(UIButton *)button {
    NSDictionary<NSString *, id> *item = objc_getAssociatedObject(button, &kKayokoSummaryAssociatedItemKey);
    void (^handler)(NSDictionary<NSString *, id> *, KayokoSummaryDeleteCompletion) = [self deleteHandler];
    if (![item isKindOfClass:[NSDictionary class]] || !handler) {
        return;
    }

    [button setEnabled:NO];
    __weak typeof(self) weakSelf = self;
    handler(item, ^(BOOL success, NSArray<NSDictionary<NSString *, id> *> *freshItems) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf) {
          return;
      }
      [button setEnabled:YES];
      if (success) {
          [strongSelf reloadWithItems:freshItems ?: @[]];
      }
    });
}

- (void)handleBackdropTap:(UITapGestureRecognizer *)recognizer {
    if (CGRectContainsPoint([[self cardView] frame], [recognizer locationInView:self])) {
        return;
    }
    if ([self dismissHandler]) {
        [self dismissHandler]();
    }
}

- (void)handleDoneButton {
    if ([self dismissHandler]) {
        [self dismissHandler]();
    }
}

@end
