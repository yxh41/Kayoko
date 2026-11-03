//
//  KayokoScriptSourceViewController.m
//  Kayoko
//

#import "KayokoScriptSourceViewController.h"

#import "KayokoScript.h"

#import <UIKit/UIKit.h>

@interface KayokoScriptSourceViewController ()

@property(nonatomic, strong) KayokoScript *script;
@property(nonatomic, strong) NSBundle *localizationBundle;
@property(nonatomic, strong) UITextView *sourceTextView;

@end

@implementation KayokoScriptSourceViewController

- (instancetype)initWithScript:(KayokoScript *)script localizationBundle:(NSBundle *)localizationBundle {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _script = script;
        _localizationBundle = localizationBundle ?: [NSBundle mainBundle];
        [self setModalPresentationStyle:UIModalPresentationPageSheet];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    [[self view] setBackgroundColor:[UIColor systemBackgroundColor]];
    [self setTitle:[self localizedStringForKey:@"Script Source"]];

    UIBarButtonItem *doneItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                             target:self
                                                                             action:@selector(dismissSelf)];
    [[self navigationItem] setRightBarButtonItem:doneItem];

    _sourceTextView = [[UITextView alloc] init];
    [_sourceTextView setTranslatesAutoresizingMaskIntoConstraints:NO];
    [_sourceTextView setText:[[self script] code]];
    [_sourceTextView setFont:[UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular]];
    [_sourceTextView setTextColor:[UIColor labelColor]];
    [_sourceTextView setEditable:NO];
    [_sourceTextView setSelectable:YES];
    [_sourceTextView setAutocorrectionType:UITextAutocorrectionTypeNo];
    [_sourceTextView setAutocapitalizationType:UITextAutocapitalizationTypeNone];
    [_sourceTextView setSmartQuotesType:UITextSmartQuotesTypeNo];
    [_sourceTextView setSmartDashesType:UITextSmartDashesTypeNo];
    [_sourceTextView setTextContainerInset:UIEdgeInsetsMake(12, 12, 12, 12)];
    [_sourceTextView setBackgroundColor:[UIColor secondarySystemGroupedBackgroundColor]];
    [[_sourceTextView layer] setCornerRadius:12];
    [_sourceTextView setClipsToBounds:YES];
    [[self view] addSubview:_sourceTextView];

    [NSLayoutConstraint activateConstraints:@[
        [[_sourceTextView topAnchor] constraintEqualToAnchor:[[self view] safeAreaLayoutGuide].topAnchor
                                                    constant:12],
        [[_sourceTextView leadingAnchor] constraintEqualToAnchor:[[self view] leadingAnchor] constant:12],
        [[_sourceTextView trailingAnchor] constraintEqualToAnchor:[[self view] trailingAnchor] constant:-12],
        [[_sourceTextView bottomAnchor] constraintEqualToAnchor:[[self view] safeAreaLayoutGuide].bottomAnchor
                                                       constant:-12]
    ]];
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSString *)localizedStringForKey:(NSString *)key {
    return [[self localizationBundle] localizedStringForKey:key value:key table:@"Tweak"];
}

@end
