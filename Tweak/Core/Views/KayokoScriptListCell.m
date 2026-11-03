//
//  KayokoScriptListCell.m
//  Kayoko
//

#import "KayokoScriptListCell.h"

static CGFloat const kKayokoScriptListCellHeight = 52;
static CGFloat const kKayokoScriptListCellHorizontalInset = 16;

NS_ASSUME_NONNULL_BEGIN

@interface KayokoScriptListCell ()

@property(nonatomic, strong, readwrite) UILabel *titleLabel;

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
    CGFloat width = CGRectGetWidth(bounds) - 2 * kKayokoScriptListCellHorizontalInset;
    [[self titleLabel] setFrame:CGRectMake(kKayokoScriptListCellHorizontalInset, 0, MAX(width, 0),
                                           CGRectGetHeight(bounds))];
}

- (void)updateWithTitle:(NSString *)title truncatesInMiddle:(BOOL)truncatesInMiddle {
    [[self titleLabel] setText:title];
    [[self titleLabel] setLineBreakMode:(truncatesInMiddle ? NSLineBreakByTruncatingMiddle
                                                          : NSLineBreakByTruncatingTail)];
}

- (void)prepareForReuse {
    [super prepareForReuse];

    [[self titleLabel] setText:nil];
}

@end
