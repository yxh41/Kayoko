//
//  KayokoScriptListCell.m
//  Kayoko
//

#import "KayokoScriptListCell.h"

static CGFloat const kKayokoScriptListCellHeight = 52;
static CGFloat const kKayokoScriptListCellHorizontalInset = 16;
static CGFloat const kKayokoScriptListCellBadgeHeight = 20;
static CGFloat const kKayokoScriptListCellBadgeHorizontalPadding = 7;
static CGFloat const kKayokoScriptListCellBadgeTitleGap = 8;

NS_ASSUME_NONNULL_BEGIN

@interface KayokoScriptListCell ()

@property(nonatomic, strong, readwrite) UILabel *titleLabel;
@property(nonatomic, strong, readwrite) UILabel *badgeLabel;

@end

NS_ASSUME_NONNULL_END

@implementation KayokoScriptListCell

+ (CGFloat)preferredHeight {
    return kKayokoScriptListCellHeight;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(nullable NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];

    if (self) {
        [self setBackgroundColor:[UIColor clearColor]];
        UIView *selectedBackgroundView = [[UIView alloc] init];
        UIColor *selectedBackgroundColor =
            [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traitCollection) {
              if ([traitCollection userInterfaceStyle] == UIUserInterfaceStyleDark) {
                  return [UIColor colorWithWhite:1 alpha:0.08];
              }

              return [UIColor colorWithWhite:0 alpha:0.055];
            }];
        [selectedBackgroundView setBackgroundColor:selectedBackgroundColor];
        [self setSelectedBackgroundView:selectedBackgroundView];

        _titleLabel = [[UILabel alloc] init];
        [[self titleLabel] setFont:[UIFont systemFontOfSize:16 weight:UIFontWeightMedium]];
        [[self titleLabel] setTextColor:[UIColor labelColor]];
        [[self titleLabel] setNumberOfLines:1];
        [self addSubview:[self titleLabel]];

        _badgeLabel = [[UILabel alloc] init];
        [[self badgeLabel] setFont:[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold]];
        [[self badgeLabel] setTextColor:[UIColor secondaryLabelColor]];
        [[self badgeLabel] setTextAlignment:NSTextAlignmentCenter];
        [[self badgeLabel] setNumberOfLines:1];
        [[self badgeLabel] setBackgroundColor:[UIColor quaternarySystemFillColor]];
        [[self badgeLabel] setClipsToBounds:YES];
        [[[self badgeLabel] layer] setCornerRadius:kKayokoScriptListCellBadgeHeight / 2.0];
        [[self badgeLabel] setHidden:YES];
        [self addSubview:[self badgeLabel]];

        [self setAccessoryType:UITableViewCellAccessoryNone];
        [self setSelectionStyle:UITableViewCellSelectionStyleDefault];
    }

    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    // Frame-based on purpose. The label lives on the cell while the row height comes from the table, and a
    // layout on the cell is not guaranteed to re-solve a constraint that reaches across into the content view:
    // pinning the title to -[UITableView contentView].centerY left it at the top edge of the cell, half a row
    // above the row the touch actually landed on. Bounds of the cell are always correct here.
    CGRect bounds = [self bounds];
    CGFloat height = CGRectGetHeight(bounds);
    CGFloat available = MAX(CGRectGetWidth(bounds) - 2 * kKayokoScriptListCellHorizontalInset, 0);

    // The badge is measured first: it is a fixed-height pill on the right edge, and the title gets whatever
    // room is left so a long candidate never runs underneath it.
    CGFloat badgeWidth = 0;
    UILabel *badgeLabel = [self badgeLabel];
    if ([[badgeLabel text] length] > 0) {
        CGFloat maximumBadgeWidth = available * 0.4;
        CGFloat measuredWidth = ceil([[badgeLabel text]
            sizeWithAttributes:@{NSFontAttributeName : [badgeLabel font]}].width) +
            kKayokoScriptListCellBadgeHorizontalPadding * 2;
        badgeWidth = MIN(measuredWidth, maximumBadgeWidth);
        [badgeLabel setFrame:CGRectMake(CGRectGetWidth(bounds) - kKayokoScriptListCellHorizontalInset - badgeWidth,
                                       (height - kKayokoScriptListCellBadgeHeight) / 2.0, badgeWidth,
                                       kKayokoScriptListCellBadgeHeight)];
        [badgeLabel setHidden:NO];
    } else {
        [badgeLabel setHidden:YES];
    }

    CGFloat titleWidth = available - (badgeWidth > 0 ? badgeWidth + kKayokoScriptListCellBadgeTitleGap : 0);
    [[self titleLabel] setFrame:CGRectMake(kKayokoScriptListCellHorizontalInset, 0, MAX(titleWidth, 0), height)];
}

- (void)updateWithTitle:(NSString *)title
                  badge:(nullable NSString *)badge
      truncatesInMiddle:(BOOL)truncatesInMiddle {
    [[self titleLabel] setText:title];
    [[self titleLabel] setLineBreakMode:(truncatesInMiddle ? NSLineBreakByTruncatingMiddle
                                                          : NSLineBreakByTruncatingTail)];
    [[self badgeLabel] setText:badge];
    [self setNeedsLayout];
}

- (void)prepareForReuse {
    [super prepareForReuse];

    [[self titleLabel] setText:nil];
    [[self badgeLabel] setText:nil];
    [[self badgeLabel] setHidden:YES];
}

@end
