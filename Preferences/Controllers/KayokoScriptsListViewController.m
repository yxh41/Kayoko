//
//  KayokoScriptsListViewController.m
//  Kayoko
//

#import "KayokoScriptsListViewController.h"

#import "KayokoKeyboardAvoidanceCoordinator.h"
#import "KayokoScript.h"
#import "KayokoScriptEditorViewController.h"
#import "KayokoScriptStore.h"

#import <UIKit/UIKit.h>

static NSString *const kKayokoScriptsListCellReuseIdentifier = @"KayokoScriptsListCell";

@interface KayokoScriptsListViewController () <UITableViewDataSource, UITableViewDelegate>

@property(nonatomic, strong) KayokoScriptStore *scriptStore;
@property(nonatomic, strong) NSMutableArray<KayokoScript *> *scripts;
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) KayokoKeyboardAvoidanceCoordinator *keyboardAvoidanceCoordinator;
@property(nonatomic, strong) NSBundle *localizationBundle;

@end

@implementation KayokoScriptsListViewController

#pragma mark - Lifecycle

- (void)loadView {
    UIView *view = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    [view setBackgroundColor:[UIColor systemGroupedBackgroundColor]];
    [self setView:view];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    _localizationBundle = [NSBundle bundleForClass:[self class]] ?: [NSBundle mainBundle];
    _scriptStore = [[KayokoScriptStore alloc] init];
    _scripts = [[NSMutableArray alloc] init];

    [self setTitle:[self localizedStringForKey:@"Script Management"]];
    [self reloadScripts];
    [self configureNavigationItem];
    [self configureTableView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[self keyboardAvoidanceCoordinator] startObserving];
    [self reloadScripts];
    [self reloadTable];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [[self keyboardAvoidanceCoordinator] stopObservingAndRestoreInsets];
}

#pragma mark - View Setup

- (void)configureNavigationItem {
    [[self navigationItem] setLargeTitleDisplayMode:UINavigationItemLargeTitleDisplayModeNever];

    UIBarButtonItem *addItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                            target:self
                                                                            action:@selector(presentAddMenu:)];
    UIBarButtonItem *editItem = [[UIBarButtonItem alloc] initWithTitle:[self localizedStringForKey:@"Edit"]
                                                                 style:UIBarButtonItemStylePlain
                                                                target:self
                                                                action:@selector(toggleEditing)];
    [[self navigationItem] setRightBarButtonItems:@[ addItem, editItem ]];
}

- (void)configureTableView {
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    [_tableView setTranslatesAutoresizingMaskIntoConstraints:NO];
    [_tableView setDataSource:self];
    [_tableView setDelegate:self];
    [_tableView setRowHeight:60.0];
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

#pragma mark - Data

- (void)reloadTable {
    [[self tableView] reloadData];
    [[self tableView] setBackgroundView:([[self scripts] count] == 0 ? [self emptyStateView] : nil)];
}

- (void)reloadScripts {
    [[self scriptStore] reload];
    [self setScripts:[[[self scriptStore] allScripts] mutableCopy]];
}

- (BOOL)persistScripts {
    NSError *error = nil;
    if ([[self scriptStore] saveScripts:[self scripts] error:&error]) {
        return YES;
    }

    NSString *title = [self localizedStringForKey:@"Could Not Save Scripts"];
    NSString *message = [error localizedDescription];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[self localizedStringForKey:@"Done"]
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
    return NO;
}

- (KayokoScript *)scriptLike:(KayokoScript *)script enabled:(BOOL)enabled {
    NSDictionary<NSString *, id> *dictionary = @{
        kKayokoScriptKeyIdentifier : [script identifier],
        kKayokoScriptKeyName : [script name],
        kKayokoScriptKeyCode : [script code],
        kKayokoScriptKeyInput : [script sampleInput],
        kKayokoScriptKeyEnabled : @(enabled),
    };

    return [KayokoScript scriptFromDictionary:dictionary];
}

- (void)replaceScript:(KayokoScript *)script {
    NSString *identifier = [script identifier];
    for (NSUInteger index = 0; index < [[self scripts] count]; index++) {
        if ([[[[self scripts] objectAtIndex:index] identifier] isEqualToString:identifier]) {
            [[self scripts] replaceObjectAtIndex:index withObject:script];
            [self persistScripts];
            [self reloadTable];
            return;
        }
    }

    [[self scripts] addObject:script];
    [self persistScripts];
    [self reloadTable];
}

/// The first line the author bothered to comment is a better name than anything this side could invent.
- (NSString *)suggestedNameForCode:(NSString *)code {
    for (NSString *line in [code componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed length] == 0) {
            continue;
        }
        if ([trimmed hasPrefix:@"//"]) {
            NSString *name =
                [[trimmed stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/ "]]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([name length] > 0) {
                return name;
            }
        }
        break;
    }

    return [self localizedStringForKey:@"Imported Script"];
}

#pragma mark - Actions

- (void)toggleEditing {
    [self setEditing:![self isEditing] animated:YES];
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];
    [[self tableView] setEditing:editing animated:animated];

    UIBarButtonItem *editItem = [[self navigationItem] rightBarButtonItems].lastObject;
    [editItem setTitle:[self localizedStringForKey:editing ? @"Done" : @"Edit"]];
    [editItem setStyle:editing ? UIBarButtonItemStyleDone : UIBarButtonItemStylePlain];
}

- (void)presentAddMenu:(UIBarButtonItem *)sender {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:[self localizedStringForKey:@"New Script"]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
                                              [self addNewScript];
                                            }]];
    [sheet addAction:[UIAlertAction actionWithTitle:[self localizedStringForKey:@"Import from Clipboard"]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
                                              [self importScriptFromClipboard];
                                            }]];
    [sheet addAction:[UIAlertAction actionWithTitle:[self localizedStringForKey:@"Cancel"]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    [[sheet popoverPresentationController] setBarButtonItem:sender];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)addNewScript {
    NSString *code = @"function main(text) {\n    return text;\n}\n";
    NSDictionary<NSString *, id> *dictionary = @{
        kKayokoScriptKeyIdentifier : [[NSUUID UUID] UUIDString],
        kKayokoScriptKeyName : [self localizedStringForKey:@"New Script"],
        kKayokoScriptKeyCode : code,
        kKayokoScriptKeyInput : @"",
        kKayokoScriptKeyEnabled : @YES,
    };
    KayokoScript *script = [KayokoScript scriptFromDictionary:dictionary];
    if (!script) {
        return;
    }

    [[self scripts] addObject:script];
    [self persistScripts];
    [self reloadTable];
    [self presentEditorForScript:script];
}

- (void)importScriptFromClipboard {
    NSString *code = [[UIPasteboard generalPasteboard] string];
    if ([[code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length] == 0) {
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:[self localizedStringForKey:@"Pasteboard is empty"]
                                                message:nil
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:[self localizedStringForKey:@"Done"]
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSDictionary<NSString *, id> *dictionary = @{
        kKayokoScriptKeyIdentifier : [[NSUUID UUID] UUIDString],
        kKayokoScriptKeyName : [self suggestedNameForCode:code],
        kKayokoScriptKeyCode : code,
        kKayokoScriptKeyInput : @"",
        kKayokoScriptKeyEnabled : @YES,
    };
    KayokoScript *script = [KayokoScript scriptFromDictionary:dictionary];
    if (!script) {
        return;
    }

    [[self scripts] addObject:script];
    [self persistScripts];
    [self reloadTable];
    [self presentEditorForScript:script];
}

- (void)presentEditorForScript:(KayokoScript *)script {
    __weak typeof(self) weakSelf = self;
    KayokoScriptEditorViewController *editor =
        [[KayokoScriptEditorViewController alloc] initWithScript:script
                                              localizationBundle:[self localizationBundle]
                                             completionHandler:^(KayokoScript *updatedScript) {
                                               [weakSelf replaceScript:updatedScript];
                                             }];
    UINavigationController *navigationController =
        [[UINavigationController alloc] initWithRootViewController:editor];
    [self presentViewController:navigationController animated:YES completion:nil];
}

- (void)toggleChanged:(UISwitch *)sender {
    NSInteger row = [sender tag];
    if (row < 0 || row >= (NSInteger)[[self scripts] count]) {
        return;
    }

    KayokoScript *script = [[self scripts] objectAtIndex:(NSUInteger)row];
    KayokoScript *updatedScript = [self scriptLike:script enabled:[sender isOn]];
    if (!updatedScript) {
        return;
    }

    [[self scripts] replaceObjectAtIndex:(NSUInteger)row withObject:updatedScript];
    [self persistScripts];
    [self reloadTable];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return (NSInteger)[[self scripts] count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kKayokoScriptsListCellReuseIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:kKayokoScriptsListCellReuseIdentifier];
    }

    KayokoScript *script = [[self scripts] objectAtIndex:(NSUInteger)[indexPath row]];
    BOOL enabled = [script isEnabled];

    [[cell textLabel] setText:[script displayName]];
    [[cell textLabel] setTextColor:(enabled ? [UIColor labelColor] : [UIColor secondaryLabelColor])];
    [[cell detailTextLabel] setText:(enabled ? [self previewForScript:script]
                                             : [self localizedStringForKey:@"Disabled"])];
    [[cell detailTextLabel] setTextColor:[UIColor secondaryLabelColor]];
    [cell setAccessoryView:[self toggleForCell:cell row:[indexPath row] on:enabled]];

    return cell;
}

/// The first line of a script says more about it than an identifier ever would.
- (NSString *)previewForScript:(KayokoScript *)script {
    for (NSString *line in [[script code] componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([trimmed length] > 0) {
            return [trimmed length] > 60 ? [[trimmed substringToIndex:60] stringByAppendingString:@"…"] : trimmed;
        }
    }

    return [script name];
}

- (UISwitch *)toggleForCell:(UITableViewCell *)cell row:(NSInteger)row on:(BOOL)on {
    UISwitch *toggle = (UISwitch *)[cell accessoryView];
    if (![toggle isKindOfClass:[UISwitch class]]) {
        toggle = [[UISwitch alloc] init];
        [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
        [cell setAccessoryView:toggle];
    }

    [toggle setTag:row];
    [toggle setOn:on animated:NO];
    return toggle;
}

- (UIView *)emptyStateView {
    UILabel *label = [[UILabel alloc] init];
    [label setText:[self localizedStringForKey:@"No scripts yet"]];
    [label setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]];
    [label setTextColor:[UIColor secondaryLabelColor]];
    [label setTextAlignment:NSTextAlignmentCenter];
    [label setNumberOfLines:0];
    return label;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ([self isEditing]) {
        return;
    }

    KayokoScript *script = [[self scripts] objectAtIndex:(NSUInteger)[indexPath row]];
    [self presentEditorForScript:script];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    (void)indexPath;
    return YES;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    (void)indexPath;
    return YES;
}

- (void)tableView:(UITableView *)tableView
    moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath
           toIndexPath:(NSIndexPath *)destinationIndexPath {
    KayokoScript *script = [[self scripts] objectAtIndex:(NSUInteger)[sourceIndexPath row]];
    [[self scripts] removeObjectAtIndex:(NSUInteger)[sourceIndexPath row]];
    [[self scripts] insertObject:script atIndex:(NSUInteger)[destinationIndexPath row]];
    [self persistScripts];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    __weak typeof(self) weakSelf = self;
    UIContextualAction *deleteAction =
        [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                title:[self localizedStringForKey:@"Delete"]
                                              handler:^(UIContextualAction *action, UIView *sourceView,
                                                        void (^completionHandler)(BOOL)) {
                                                [weakSelf deleteScriptAtIndexPath:indexPath];
                                                completionHandler(YES);
                                              }];

    return [UISwipeActionsConfiguration configurationWithActions:@[ deleteAction ]];
}

- (void)deleteScriptAtIndexPath:(NSIndexPath *)indexPath {
    if ((NSUInteger)[indexPath row] >= [[self scripts] count]) {
        return;
    }

    [[self scripts] removeObjectAtIndex:(NSUInteger)[indexPath row]];
    [self persistScripts];
    [self reloadTable];
}

#pragma mark - Helpers

- (NSString *)localizedStringForKey:(NSString *)key {
    return [[self localizationBundle] localizedStringForKey:key value:key table:@"Tweak"];
}

@end
