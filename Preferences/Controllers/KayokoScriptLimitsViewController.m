//
//  KayokoScriptLimitsViewController.m
//  Kayoko
//

#import "KayokoScriptLimitsViewController.h"

#import "KayokoScriptLimits.h"

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, KayokoScriptLimitsRow) {
    KayokoScriptLimitsRowTimeout = 0,
    KayokoScriptLimitsRowResults,
    KayokoScriptLimitsRowLength,
    KayokoScriptLimitsRowCount,
};

@interface KayokoScriptLimitsViewController () <UITableViewDataSource, UITableViewDelegate>

@property(nonatomic, strong) KayokoScriptLimits *limits;
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) NSBundle *localizationBundle;

@end

@implementation KayokoScriptLimitsViewController

- (instancetype)initWithLocalizationBundle:(NSBundle *)localizationBundle {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _localizationBundle = localizationBundle ?: [NSBundle mainBundle];
        _limits = [KayokoScriptLimits loadLimits];
    }
    return self;
}

- (void)loadView {
    UIView *view = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    [view setBackgroundColor:[UIColor systemGroupedBackgroundColor]];
    [self setView:view];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // PreferenceLoader instantiates this page with -init, so neither the bundle nor the limits are handed in;
    // resolve both here so every entry path (init, or the bundle convenience initializer) starts populated.
    if (![self localizationBundle]) {
        [self setLocalizationBundle:[NSBundle bundleForClass:[self class]] ?: [NSBundle mainBundle]];
    }
    if (![self limits]) {
        [self setLimits:[KayokoScriptLimits loadLimits]];
    }

    [self setTitle:[self localizedStringForKey:@"Run Limits"]];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    [_tableView setTranslatesAutoresizingMaskIntoConstraints:NO];
    [_tableView setDataSource:self];
    [_tableView setDelegate:self];
    [[self view] addSubview:_tableView];

    [NSLayoutConstraint activateConstraints:@[
        [[_tableView topAnchor] constraintEqualToAnchor:[[self view] topAnchor]],
        [[_tableView leadingAnchor] constraintEqualToAnchor:[[self view] leadingAnchor]],
        [[_tableView trailingAnchor] constraintEqualToAnchor:[[self view] trailingAnchor]],
        [[_tableView bottomAnchor] constraintEqualToAnchor:[[self view] bottomAnchor]]
    ]];
}

#pragma mark - Values

/// The stepper and the row label both read from the same limits object, so the value text is derived on demand
/// rather than kept in a label that a reused cell would otherwise pin to the wrong row.
- (NSString *)valueTextForRow:(KayokoScriptLimitsRow)row {
    switch (row) {
    case KayokoScriptLimitsRowTimeout:
        return [NSString stringWithFormat:@"%.0f s", [self limits].timeout];
    case KayokoScriptLimitsRowResults:
        return [NSString stringWithFormat:@"%lu", (unsigned long)[self limits].maxResults];
    case KayokoScriptLimitsRowLength:
        return [NSString stringWithFormat:@"%lu", (unsigned long)[self limits].maxResultLength];
    default:
        break;
    }
    return @"";
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return KayokoScriptLimitsRowCount;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return [self localizedStringForKey:@"Run Limits Footer"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    KayokoScriptLimitsRow row = (KayokoScriptLimitsRow)[indexPath row];

    // Only three rows, so a fresh cell is cheaper than guarding a reused one against a stepper that belonged to
    // another row. Title | value | stepper are laid out left to right, which is what stops the value from
    // sliding under the stepper the way a right-unbounded label did.
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                   reuseIdentifier:nil];
    [cell setSelectionStyle:UITableViewCellSelectionStyleNone];

    UILabel *titleLabel = [[UILabel alloc] init];
    [titleLabel setText:[self titleForRow:row]];
    [titleLabel setFont:[UIFont systemFontOfSize:17]];
    [titleLabel setTextColor:[UIColor labelColor]];
    [titleLabel setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [titleLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                forAxis:UILayoutConstraintAxisHorizontal];

    UILabel *valueLabel = [[UILabel alloc] init];
    [valueLabel setText:[self valueTextForRow:row]];
    [valueLabel setFont:[UIFont systemFontOfSize:15 weight:UIFontWeightMedium]];
    [valueLabel setTextColor:[UIColor secondaryLabelColor]];
    [valueLabel setTextAlignment:NSTextAlignmentRight];
    [valueLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [valueLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                forAxis:UILayoutConstraintAxisHorizontal];

    UIStepper *stepper = [[UIStepper alloc] init];
    switch (row) {
    case KayokoScriptLimitsRowTimeout:
        [stepper setMinimumValue:1];
        [stepper setMaximumValue:30];
        [stepper setStepValue:1];
        [stepper setValue:[self limits].timeout];
        break;
    case KayokoScriptLimitsRowResults:
        [stepper setMinimumValue:1];
        [stepper setMaximumValue:2000];
        [stepper setStepValue:10];
        [stepper setValue:[self limits].maxResults];
        break;
    case KayokoScriptLimitsRowLength:
        [stepper setMinimumValue:1000];
        [stepper setMaximumValue:500000];
        [stepper setStepValue:1000];
        [stepper setValue:[self limits].maxResultLength];
        break;
    default:
        break;
    }
    [stepper setTag:[indexPath row]];
    [stepper addTarget:self action:@selector(stepperChanged:) forControlEvents:UIControlEventValueChanged];
    [stepper setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *stack =
        [[UIStackView alloc] initWithArrangedSubviews:@[ titleLabel, valueLabel, stepper ]];
    [stack setAxis:UILayoutConstraintAxisHorizontal];
    [stack setAlignment:UIStackViewAlignmentCenter];
    [stack setSpacing:8];
    [stack setTranslatesAutoresizingMaskIntoConstraints:NO];
    [[cell contentView] addSubview:stack];

    UILayoutGuide *margins = [[cell contentView] layoutMarginsGuide];
    [NSLayoutConstraint activateConstraints:@[
        [[stack topAnchor] constraintEqualToAnchor:[margins topAnchor]],
        [[stack bottomAnchor] constraintEqualToAnchor:[margins bottomAnchor]],
        [[stack leadingAnchor] constraintEqualToAnchor:[margins leadingAnchor]],
        [[stack trailingAnchor] constraintEqualToAnchor:[margins trailingAnchor]],
    ]];

    return cell;
}

- (NSString *)titleForRow:(KayokoScriptLimitsRow)row {
    switch (row) {
    case KayokoScriptLimitsRowTimeout:
        return [self localizedStringForKey:@"Timeout (seconds)"];
    case KayokoScriptLimitsRowResults:
        return [self localizedStringForKey:@"Maximum results"];
    case KayokoScriptLimitsRowLength:
        return [self localizedStringForKey:@"Maximum length per result"];
    default:
        break;
    }
    return @"";
}

#pragma mark - Actions

- (void)stepperChanged:(UIStepper *)stepper {
    switch ((KayokoScriptLimitsRow)[stepper tag]) {
    case KayokoScriptLimitsRowTimeout:
        [[self limits] setTimeout:[stepper value]];
        break;
    case KayokoScriptLimitsRowResults:
        [[self limits] setMaxResults:(NSUInteger)[stepper value]];
        break;
    case KayokoScriptLimitsRowLength:
        [[self limits] setMaxResultLength:(NSUInteger)[stepper value]];
        break;
    default:
        break;
    }

    [[self tableView] reloadData];

    NSError *error = nil;
    if (![[self limits] saveLimits:&error]) {
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:[self localizedStringForKey:@"Could Not Save Limits"]
                                                message:[error localizedDescription]
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:[self localizedStringForKey:@"Done"]
                                                style:UIAlertActionStyleDefault
                                              handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

#pragma mark - Helpers

- (NSString *)localizedStringForKey:(NSString *)key {
    return [[self localizationBundle] localizedStringForKey:key value:key table:@"Tweak"];
}

@end
