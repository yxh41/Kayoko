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

        UIView *contentView = [self contentView];
        [[self titleLabel] setTranslatesAutoresizingMaskIntoConstraints:NO];
        [NSLayoutConstraint activateConstraints:@[
            [[[self titleLabel] leadingAnchor] constraintEqualToAnchor:[contentView leadingAnchor]
                                                             constant:kKayokoScriptListCellHorizontalInset],
            [[[self titleLabel] trailingAnchor] constraintEqualToAnchor:[contentView trailingAnchor]
                                                               constant:-kKayokoScriptListCellHorizontalInset],
            [[[self titleLabel] centerYAnchor] constraintEqualToAnchor:[contentView centerYAnchor]]
        ]];

        [self setAccessoryType:UITableViewCellAccessoryNone];
        [self setSelectionStyle:UITableViewCellSelectionStyleDefault];
    }

    return self;
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
