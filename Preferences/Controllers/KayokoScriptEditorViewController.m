//
//  KayokoScriptEditorViewController.m
//  Kayoko
//

#import "KayokoScriptEditorViewController.h"

#import "KayokoKeyboardAvoidanceCoordinator.h"
#import "KayokoScript.h"
#import "KayokoScriptFailure.h"
#import "KayokoScriptItem.h"
#import "KayokoScriptRunner.h"

#import <UIKit/UIKit.h>

static CGFloat const kKayokoScriptEditorCodeHeight = 300.0;

#pragma mark - Output

/// A dry run turns one input into one or more outputs, and the whole point is to see the transformation, so
/// the page mirrors that pairing: the input it ran against, then each result in its own card. A result that
/// looks like the input (dedupe, sort, trim) is still clearly the transformed copy, not the field above.
@interface KayokoScriptOutputViewController : UIViewController

- (instancetype)initWithInput:(NSString *)input
                      results:(NSArray<NSString *> *)results
                     failure:(nullable KayokoScriptFailure *)failure
            localizationBundle:(NSBundle *)bundle
                        title:(NSString *)title;

@end

@implementation KayokoScriptOutputViewController {
    NSString *_input;
    NSArray<NSString *> *_results;
    KayokoScriptFailure *_failure;
    NSBundle *_bundle;
    NSString *_pageTitle;
}

- (instancetype)initWithInput:(NSString *)input
                      results:(NSArray<NSString *> *)results
                     failure:(nullable KayokoScriptFailure *)failure
            localizationBundle:(NSBundle *)bundle
                        title:(NSString *)title {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _input = [input copy];
        _results = [results count] ? [results copy] : @[];
        _failure = failure;
        _bundle = bundle ?: [NSBundle mainBundle];
        _pageTitle = [title copy];
        [self setModalPresentationStyle:UIModalPresentationPageSheet];
    }
    return self;
}

- (NSString *)localizedStringForKey:(NSString *)key {
    return [_bundle localizedStringForKey:key value:key table:@"Tweak"];
}

- (UIView *)cardWithTitle:(NSString *)title body:(NSString *)body accent:(BOOL)accent {
    UIView *card = [[UIView alloc] init];
    [card setTranslatesAutoresizingMaskIntoConstraints:NO];
    [card setBackgroundColor:accent ? [UIColor tertiarySystemBackgroundColor]
                                    : [UIColor secondarySystemGroupedBackgroundColor]];
    [[card layer] setCornerRadius:12];
    [card setClipsToBounds:YES];

    UILabel *titleLabel = [[UILabel alloc] init];
    [titleLabel setTranslatesAutoresizingMaskIntoConstraints:NO];
    [titleLabel setText:title];
    [titleLabel setFont:[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]];
    [titleLabel setTextColor:accent ? [UIColor labelColor] : [UIColor secondaryLabelColor]];

    UILabel *bodyLabel = [[UILabel alloc] init];
    [bodyLabel setTranslatesAutoresizingMaskIntoConstraints:NO];
    [bodyLabel setText:body ?: @""];
    [bodyLabel setFont:[UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular]];
    [bodyLabel setTextColor:[UIColor labelColor]];
    [bodyLabel setNumberOfLines:0];
    [bodyLabel setLineBreakMode:NSLineBreakByCharWrapping];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ titleLabel, bodyLabel ]];
    [stack setTranslatesAutoresizingMaskIntoConstraints:NO];
    [stack setAxis:UILayoutConstraintAxisVertical];
    [stack setSpacing:8];
    [card addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [[stack topAnchor] constraintEqualToAnchor:[card topAnchor] constant:12],
        [[stack leadingAnchor] constraintEqualToAnchor:[card leadingAnchor] constant:12],
        [[stack trailingAnchor] constraintEqualToAnchor:[card trailingAnchor] constant:-12],
        [[stack bottomAnchor] constraintEqualToAnchor:[card bottomAnchor] constant:-12]
    ]];

    return card;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    [[self view] setBackgroundColor:[UIColor systemBackgroundColor]];
    [self setTitle:_pageTitle];

    UIScrollView *scrollView = [[UIScrollView alloc] init];
    [scrollView setTranslatesAutoresizingMaskIntoConstraints:NO];
    [scrollView setAlwaysBounceVertical:YES];
    [[self view] addSubview:scrollView];

    UIStackView *stack = [[UIStackView alloc] init];
    [stack setTranslatesAutoresizingMaskIntoConstraints:NO];
    [stack setAxis:UILayoutConstraintAxisVertical];
    [stack setSpacing:16];
    [scrollView addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [[scrollView topAnchor] constraintEqualToAnchor:[[self view] safeAreaLayoutGuide].topAnchor],
        [[scrollView leadingAnchor] constraintEqualToAnchor:[[self view] leadingAnchor]],
        [[scrollView trailingAnchor] constraintEqualToAnchor:[[self view] trailingAnchor]],
        [[scrollView bottomAnchor] constraintEqualToAnchor:[[self view] bottomAnchor]],
        [[stack topAnchor] constraintEqualToAnchor:[scrollView contentLayoutGuide].topAnchor constant:16],
        [[stack leadingAnchor] constraintEqualToAnchor:[scrollView contentLayoutGuide].leadingAnchor constant:16],
        [[stack trailingAnchor] constraintEqualToAnchor:[scrollView contentLayoutGuide].trailingAnchor constant:-16],
        [[stack bottomAnchor] constraintEqualToAnchor:[scrollView contentLayoutGuide].bottomAnchor constant:-16],
        [[stack widthAnchor] constraintEqualToAnchor:[scrollView contentLayoutGuide].widthAnchor]
    ]];

    [stack addArrangedSubview:[self cardWithTitle:[self localizedStringForKey:@"Input"]
                                             body:_input
                                           accent:NO]];

    if (_failure) {
        [stack addArrangedSubview:[self cardWithTitle:[self localizedStringForKey:@"Error"]
                                                 body:[_failure technicalSummary]
                                               accent:YES]];
    } else if ([_results count] == 0) {
        [stack addArrangedSubview:[self cardWithTitle:[self localizedStringForKey:@"Output"]
                                                 body:[self localizedStringForKey:@"No matches"]
                                               accent:YES]];
    } else {
        [_results enumerateObjectsUsingBlock:^(NSString *result, NSUInteger index, BOOL *stop) {
            NSString *title = ([_results count] == 1)
                ? [self localizedStringForKey:@"Output"]
                : [NSString stringWithFormat:@"%@ %lu", [self localizedStringForKey:@"Output"],
                                               (unsigned long)(index + 1)];
            [stack addArrangedSubview:[self cardWithTitle:title body:result accent:YES]];
        }];
    }

    UIBarButtonItem *doneItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                             target:self
                                                                             action:@selector(dismissSelf)];
    [[self navigationItem] setRightBarButtonItem:doneItem];
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark - Editor

@interface KayokoScriptEditorViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>

@property(nonatomic, strong) KayokoScript *script;
@property(nonatomic, strong) NSBundle *localizationBundle;
@property(nonatomic, copy, nullable) void (^completionHandler)(KayokoScript *script);

@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) UITextField *nameField;
@property(nonatomic, strong) UITextField *inputField;
@property(nonatomic, strong) UITextView *codeTextView;
@property(nonatomic, strong) KayokoKeyboardAvoidanceCoordinator *keyboardAvoidanceCoordinator;
@property(nonatomic, strong) KayokoScriptRunner *runner;

@property(nonatomic, strong, nullable) UITableViewCell *nameCell;
@property(nonatomic, strong, nullable) UITableViewCell *inputCell;
@property(nonatomic, strong, nullable) UITableViewCell *codeCell;
@property(nonatomic, assign, getter=isRunning) BOOL running;

+ (NSArray<NSString *> *)descriptionsForItems:(NSArray<KayokoScriptItem *> *)items;

@end

@implementation KayokoScriptEditorViewController

#pragma mark - Lifecycle

- (instancetype)initWithScript:(KayokoScript *)script
            localizationBundle:(NSBundle *)localizationBundle
           completionHandler:(void (^_Nullable)(KayokoScript *))completionHandler {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _script = script;
        _localizationBundle = localizationBundle ?: [NSBundle mainBundle];
        _completionHandler = [completionHandler copy];
        _runner = [[KayokoScriptRunner alloc] init];
        [self setModalPresentationStyle:UIModalPresentationPageSheet];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    [[self view] setBackgroundColor:[UIColor systemGroupedBackgroundColor]];
    [self setTitle:[self localizedStringForKey:@"Edit Script"]];

    UIBarButtonItem *cancelItem = [[UIBarButtonItem alloc] initWithTitle:[self localizedStringForKey:@"Cancel"]
                                                                 style:UIBarButtonItemStylePlain
                                                                target:self
                                                                action:@selector(cancelEditing)];
    UIBarButtonItem *doneItem = [[UIBarButtonItem alloc] initWithTitle:[self localizedStringForKey:@"Done"]
                                                                 style:UIBarButtonItemStyleDone
                                                                target:self
                                                                action:@selector(finishEditing)];
    [[self navigationItem] setLeftBarButtonItem:cancelItem];
    [[self navigationItem] setRightBarButtonItem:doneItem];

    [self configureFields];
    [self configureTableView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[self keyboardAvoidanceCoordinator] startObserving];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [[self keyboardAvoidanceCoordinator] stopObservingAndRestoreInsets];
}

#pragma mark - View Setup

- (void)configureFields {
    _nameField = [[UITextField alloc] init];
    [_nameField setText:[[self script] name]];
    [_nameField setPlaceholder:[self localizedStringForKey:@"Script Name"]];
    [_nameField setBorderStyle:UITextBorderStyleNone];
    [_nameField setReturnKeyType:UIReturnKeyDone];
    [_nameField setDelegate:self];
    [_nameField setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];

    _inputField = [[UITextField alloc] init];
    [_inputField setText:[[self script] sampleInput]];
    [_inputField setPlaceholder:[self localizedStringForKey:@"Sample Input"]];
    [_inputField setBorderStyle:UITextBorderStyleNone];
    [_inputField setAutocorrectionType:UITextAutocorrectionTypeNo];
    [_inputField setAutocapitalizationType:UITextAutocapitalizationTypeNone];
    [_inputField setReturnKeyType:UIReturnKeyDone];
    [_inputField setDelegate:self];
    [_inputField setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];

    _codeTextView = [[UITextView alloc] init];
    [_codeTextView setText:[[self script] code]];
    [_codeTextView setFont:[UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular]];
    [_codeTextView setAutocorrectionType:UITextAutocorrectionTypeNo];
    [_codeTextView setAutocapitalizationType:UITextAutocapitalizationTypeNone];
    [_codeTextView setSmartQuotesType:UITextSmartQuotesTypeNo];
    [_codeTextView setSmartDashesType:UITextSmartDashesTypeNo];
    [_codeTextView setTextContainerInset:UIEdgeInsetsMake(10, 10, 10, 10)];
    [_codeTextView setBackgroundColor:[UIColor secondarySystemGroupedBackgroundColor]];
    [[_codeTextView layer] setCornerRadius:8];
    [_codeTextView setClipsToBounds:YES];
}

- (void)configureTableView {
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    [_tableView setTranslatesAutoresizingMaskIntoConstraints:NO];
    [_tableView setDataSource:self];
    [_tableView setDelegate:self];
    [_tableView setKeyboardDismissMode:UIScrollViewKeyboardDismissModeInteractive];
    [[self view] addSubview:_tableView];

    [NSLayoutConstraint activateConstraints:@[
        [[_tableView topAnchor] constraintEqualToAnchor:[[self view] topAnchor]],
        [[_tableView leadingAnchor] constraintEqualToAnchor:[[self view] leadingAnchor]],
        [[_tableView trailingAnchor] constraintEqualToAnchor:[[self view] trailingAnchor]],
        [[_tableView bottomAnchor] constraintEqualToAnchor:[[self view] bottomAnchor]]
    ]];

    _keyboardAvoidanceCoordinator = [[KayokoKeyboardAvoidanceCoordinator alloc] initWithView:[self view]
                                                                                 scrollView:_tableView];
}

#pragma mark - Cells

- (UITableViewCell *)nameCell {
    if (!_nameCell) {
        _nameCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        [_nameCell setSelectionStyle:UITableViewCellSelectionStyleNone];
        [[_nameCell textLabel] setText:[self localizedStringForKey:@"Script Name"]];
        [_nameField setFrame:CGRectMake(0, 0, 210, 36)];
        [_nameCell setAccessoryView:_nameField];
    }

    return _nameCell;
}

- (UITableViewCell *)inputCell {
    if (!_inputCell) {
        _inputCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        [_inputCell setSelectionStyle:UITableViewCellSelectionStyleNone];
        [[_inputCell textLabel] setText:[self localizedStringForKey:@"Sample Input"]];
        [_inputField setFrame:CGRectMake(0, 0, 210, 36)];
        [_inputCell setAccessoryView:_inputField];
    }

    return _inputCell;
}

- (UITableViewCell *)codeCell {
    if (!_codeCell) {
        _codeCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        [_codeCell setSelectionStyle:UITableViewCellSelectionStyleNone];
        [_codeTextView setTranslatesAutoresizingMaskIntoConstraints:NO];
        [[_codeCell contentView] addSubview:_codeTextView];

        UILayoutGuide *margins = [[_codeCell contentView] layoutMarginsGuide];
        [NSLayoutConstraint activateConstraints:@[
            [[_codeTextView topAnchor] constraintEqualToAnchor:[margins topAnchor]],
            [[_codeTextView leadingAnchor] constraintEqualToAnchor:[margins leadingAnchor]],
            [[_codeTextView trailingAnchor] constraintEqualToAnchor:[margins trailingAnchor]],
            [[_codeTextView bottomAnchor] constraintEqualToAnchor:[margins bottomAnchor]]
        ]];
    }

    return _codeCell;
}

- (UITableViewCell *)actionCellWithTitle:(NSString *)title tinted:(BOOL)tinted {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    [[cell textLabel] setText:title];
    [[cell textLabel] setTextAlignment:NSTextAlignmentCenter];
    if (tinted) {
        [[cell textLabel] setTextColor:[UIColor labelColor]];
        [[cell textLabel] setFont:[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]];
    } else {
        [[cell textLabel] setTextColor:[UIColor secondaryLabelColor]];
    }

    return cell;
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) {
        return 2;
    }

    return section == 2 ? 2 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return section == 1 ? [self localizedStringForKey:@"Code"] : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section != 1) {
        return nil;
    }

    return [self localizedStringForKey:@"Script Footer Hint"];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if ([indexPath section] == 1) {
        return kKayokoScriptEditorCodeHeight;
    }

    return UITableViewAutomaticDimension;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;

    if ([indexPath section] == 0) {
        return [indexPath row] == 0 ? [self nameCell] : [self inputCell];
    }
    if ([indexPath section] == 1) {
        return [self codeCell];
    }

    if ([indexPath row] == 0) {
        return [self actionCellWithTitle:[self runActionTitle] tinted:YES];
    }

    return [self actionCellWithTitle:[self localizedStringForKey:@"Export Script"] tinted:NO];
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if ([indexPath section] == 0) {
        UITextField *field = ([indexPath row] == 0 ? [self nameField] : [self inputField]);
        [field becomeFirstResponder];
        return;
    }
    if ([indexPath section] != 2) {
        return;
    }

    if ([indexPath row] == 0) {
        [self runScript];
    } else {
        [self exportScript];
    }
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

#pragma mark - Actions

- (void)cancelEditing {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)finishEditing {
    NSString *code = [[self codeTextView] text] ?: @"";
    if ([[code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length] == 0) {
        [self presentMessage:[self localizedStringForKey:@"Script Is Empty"]];
        return;
    }

    NSString *name = [[[self nameField] text]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([name length] == 0) {
        name = [self localizedStringForKey:@"Untitled Script"];
    }

    KayokoScript *updatedScript = [self composedScriptWithName:name];
    if (!updatedScript) {
        [self presentMessage:[self localizedStringForKey:@"Script Is Empty"]];
        return;
    }

    void (^completionHandler)(KayokoScript *) = [self completionHandler];
    [self dismissViewControllerAnimated:YES
                             completion:^{
                               if (completionHandler) {
                                   completionHandler(updatedScript);
                               }
                             }];
}

- (void)runScript {
    if ([self isRunning]) {
        return;
    }

    NSString *code = [[self codeTextView] text] ?: @"";
    if ([[code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length] == 0) {
        [self presentMessage:[self localizedStringForKey:@"Script Is Empty"]];
        return;
    }

    KayokoScript *script = [self composedScriptWithName:[[self script] name]];
    if (!script) {
        return;
    }

    [self setRunning:YES];
    [[self tableView] reloadSections:[NSIndexSet indexSetWithIndex:2]
                    withRowAnimation:UITableViewRowAnimationNone];

    __weak typeof(self) weakSelf = self;
    // The pasteboard is deliberately not read here: this page runs inside Settings, and a dry run is not worth
    // an "Allow Paste" prompt. `$pb.readString()` gets an empty string and the sample input field is the input.
    [[self runner] runScript:script
                       input:[[self inputField] text] ?: @""
               clipboardText:nil
       sourceBundleIdentifier:nil
                  completion:^(NSArray<KayokoScriptItem *> *_Nullable items, KayokoScriptFailure *_Nullable failure) {
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (!strongSelf) {
                        return;
                    }

                    [strongSelf setRunning:NO];
                    [[strongSelf tableView] reloadSections:[NSIndexSet indexSetWithIndex:2]
                                          withRowAnimation:UITableViewRowAnimationNone];

                    [strongSelf presentOutputWithInput:[[strongSelf inputField] text] ?: @""
                                               results:[[strongSelf class] descriptionsForItems:items]
                                              failure:failure];
                  }];
}

/// The dry run answers "what did it produce", so an action is shown with its type in front: a `pb` item that
/// looks like plain text would otherwise read as a no-op.
+ (NSArray<NSString *> *)descriptionsForItems:(NSArray<KayokoScriptItem *> *)items {
    NSMutableArray<NSString *> *descriptions = [NSMutableArray array];
    for (KayokoScriptItem *item in items) {
        NSString *typeIdentifier = [[KayokoScriptItem class] typeIdentifierForType:[item type]];
        if (![item isAction] || [typeIdentifier length] == 0) {
            [descriptions addObject:[item content]];
            continue;
        }

        [descriptions addObject:[NSString stringWithFormat:@"[%@] %@", typeIdentifier, [item content]]];
    }

    return descriptions;
}

- (void)exportScript {
    NSString *name = [[[self nameField] text]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([name length] == 0) {
        name = [self localizedStringForKey:@"Untitled Script"];
    }

    NSString *fileName = [[name stringByReplacingOccurrencesOfString:@"/" withString:@"-"]
        stringByAppendingPathExtension:@"js"];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
    NSError *error = nil;
    if (![[[self codeTextView] text] ?: @"" writeToFile:path
                                             atomically:YES
                                               encoding:NSUTF8StringEncoding
                                                  error:&error]) {
        [self presentMessage:[error localizedDescription]];
        return;
    }

    UIActivityViewController *activity =
        [[UIActivityViewController alloc] initWithActivityItems:@[ [NSURL fileURLWithPath:path] ]
                                          applicationActivities:nil];
    [[activity popoverPresentationController] setSourceView:[self view]];
    [[activity popoverPresentationController] setSourceRect:CGRectMake(CGRectGetMidX([[self view] bounds]),
                                                                      CGRectGetMidY([[self view] bounds]), 1, 1)];
    [self presentViewController:activity animated:YES completion:nil];
}

#pragma mark - Composition

- (KayokoScript *)composedScriptWithName:(NSString *)name {
    NSDictionary<NSString *, id> *dictionary = @{
        kKayokoScriptKeyIdentifier : [[self script] identifier],
        kKayokoScriptKeyName : name,
        kKayokoScriptKeyCode : [[self codeTextView] text] ?: @"",
        kKayokoScriptKeyInput : [[self inputField] text] ?: @"",
        kKayokoScriptKeyEnabled : @([[self script] isEnabled]),
    };

    return [KayokoScript scriptFromDictionary:dictionary];
}

- (NSString *)runActionTitle {
    return [self localizedStringForKey:([self isRunning] ? @"Running…" : @"Run")];
}

#pragma mark - Presentation

- (void)presentOutputWithInput:(NSString *)input
                       results:(NSArray<NSString *> *)results
                      failure:(KayokoScriptFailure *)failure {    KayokoScriptOutputViewController *output =
        [[KayokoScriptOutputViewController alloc] initWithInput:input
                                                      results:results
                                                     failure:failure
                                            localizationBundle:[self localizationBundle]
                                                        title:[self localizedStringForKey:@"Run Result"]];
    UINavigationController *navigationController =
        [[UINavigationController alloc] initWithRootViewController:output];
    [self presentViewController:navigationController animated:YES completion:nil];
}

- (void)presentMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[self localizedStringForKey:@"Done"]
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Helpers

- (NSString *)localizedStringForKey:(NSString *)key {
    return [[self localizationBundle] localizedStringForKey:key value:key table:@"Tweak"];
}

@end
