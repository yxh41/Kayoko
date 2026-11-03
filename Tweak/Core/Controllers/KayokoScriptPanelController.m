//
//  KayokoScriptPanelController.m
//  Kayoko
//

#import "KayokoScriptPanelController.h"

#import "KayokoHeaderView.h"
#import "KayokoHUD.h"
#import "KayokoPasteboardManager.h"
#import "KayokoScript.h"
#import "KayokoScriptFailure.h"
#import "KayokoScriptListCell.h"
#import "KayokoScriptPanelView.h"
#import "KayokoScriptRunner.h"
#import "KayokoScriptStore.h"

typedef NS_ENUM(NSUInteger, KayokoScriptPanelState) {
    KayokoScriptPanelStateList,
    KayokoScriptPanelStateChoices,
    KayokoScriptPanelStateResult,
    KayokoScriptPanelStateFailure,
};

static NSString *const kKayokoScriptPanelCellReuseIdentifier = @"KayokoScriptListCell";

NS_ASSUME_NONNULL_BEGIN

static NSString *KayokoScriptPanelLocalized(NSString *key, NSString *fallback) {
    return [[KayokoPasteboardManager localizationBundle] localizedStringForKey:key value:fallback table:@"Tweak"];
}

@interface KayokoScriptPanelController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>

@property(nonatomic, strong, readwrite) KayokoScriptPanelView *panelView;
@property(nonatomic, strong) KayokoScriptStore *scriptStore;
@property(nonatomic, strong) KayokoScriptRunner *runner;

@property(nonatomic, copy) NSString *inputText;
@property(nonatomic, copy) NSArray<KayokoScript *> *scripts;
/// What the list actually shows; a subset of `scripts` while a search query is active, equal to it otherwise.
@property(nonatomic, copy) NSArray<KayokoScript *> *filteredScripts;
@property(nonatomic, copy) NSArray<NSString *> *values;
@property(nonatomic, copy, nullable) NSString *resultText;
@property(nonatomic, strong, nullable) KayokoScript *activeScript;
@property(nonatomic, assign) KayokoScriptPanelState state;
@property(nonatomic, assign, getter=isRunning) BOOL running;
/// Bumped on every reset so a late runner callback cannot resurrect a panel the user already left.
@property(nonatomic, assign) NSUInteger generation;

@end

NS_ASSUME_NONNULL_END

@implementation KayokoScriptPanelController

#pragma mark - Lifecycle

- (instancetype)init {
    self = [super init];
    if (self) {
        _panelView = [[KayokoScriptPanelView alloc] initWithFrame:CGRectZero];
        _scriptStore = [[KayokoScriptStore alloc] init];
        _runner = [[KayokoScriptRunner alloc] init];
        _inputText = @"";
        _scripts = @[];
        _values = @[];
        [self setView:_panelView];

        [[[_panelView headerView] leadingButton] addTarget:self
                                                    action:@selector(handleBackButtonPressed)
                                          forControlEvents:UIControlEventTouchUpInside];
        [[_panelView resultCopyButton] addTarget:self
                                    action:@selector(handleCopyButtonPressed)
                          forControlEvents:UIControlEventTouchUpInside];
        [[_panelView resultPasteButton] addTarget:self
                                     action:@selector(handlePasteButtonPressed)
                           forControlEvents:UIControlEventTouchUpInside];
        [[_panelView tableView] setDataSource:self];
        [[_panelView tableView] setDelegate:self];
        [[_panelView searchBar] setDelegate:self];
    }

    return self;
}

#pragma mark - Entry Points

- (void)beginWithText:(NSString *)text {
    [self setInputText:text ?: @""];
    [self setActiveScript:nil];
    [self setValues:@[]];
    [self setResultText:nil];
    [self setRunning:NO];
    [self setGeneration:[self generation] + 1];

    [[self scriptStore] reload];
    [self setScripts:[[self scriptStore] enabledScripts]];
    [self setFilteredScripts:[self scripts]];
    [[[self panelView] searchBar] setText:@""];
    [self showListState];
    [self updateTableInteraction];
}

- (void)resetState {
    [self setGeneration:[self generation] + 1];
    [self setInputText:@""];
    [self setActiveScript:nil];
    [self setValues:@[]];
    [self setResultText:nil];
    [self setRunning:NO];
    [self setScripts:@[]];
    [self setFilteredScripts:@[]];
    [self showListState];
    [self updateTableInteraction];
}

#pragma mark - States

- (void)showListState {
    [self setState:KayokoScriptPanelStateList];
    [self setFilteredScripts:[self scripts]];
    [[[self panelView] searchBar] setText:@""];
    [[[self panelView] searchBar] resignFirstResponder];
    [[self panelView] setSearchBarVisible:([[self scripts] count] > 0)];
    [[self panelView] setTitleText:KayokoScriptPanelLocalized(@"Scripts", @"Scripts")];
    [[self panelView] showList];
    if ([[self scripts] count] == 0) {
        [[self panelView] showNotice:KayokoScriptPanelLocalized(@"No scripts enabled", @"No scripts enabled")];
    }
}

- (void)showChoicesState {
    [self setState:KayokoScriptPanelStateChoices];
    [[[self panelView] searchBar] resignFirstResponder];
    [[self panelView] setSearchBarVisible:NO];
    [[self panelView] setTitleText:[self activeScriptTitle]];
    [[self panelView] showList];
}

- (void)showResultStateWithText:(NSString *)text {
    [self setState:KayokoScriptPanelStateResult];
    [[[self panelView] searchBar] resignFirstResponder];
    [[self panelView] setSearchBarVisible:NO];
    [self setResultText:text];

    NSString *format = KayokoScriptPanelLocalized(@"%lu characters", @"%lu characters");
    NSString *countText = [NSString stringWithFormat:format, (unsigned long)[text length]];
    [[self panelView] setTitleText:[self activeScriptTitle]];
    [[self panelView] showResultWithText:text countText:countText];
}

- (NSString *)activeScriptTitle {
    NSString *title = [[self activeScript] displayName];
    return [title length] > 0 ? title : KayokoScriptPanelLocalized(@"Scripts", @"Scripts");
}

#pragma mark - Running

- (void)runScript:(KayokoScript *)script {
    if ([self isRunning]) {
        return;
    }

    [self setActiveScript:script];
    [self setRunning:YES];
    [self updateTableInteraction];

    NSUInteger generation = [self generation];
    [KayokoHUD showStatus:KayokoScriptPanelLocalized(@"Running…", @"Running…")];

    if ([self hapticFeedbackHandler]) {
        [self hapticFeedbackHandler](UIImpactFeedbackStyleLight);
    }

    __weak typeof(self) weakSelf = self;
    [[self runner] runScript:script
                       input:[self inputText]
                  completion:^(NSArray<NSString *> *_Nullable results, KayokoScriptFailure *_Nullable failure) {
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (!strongSelf) {
                        return;
                    }

                    [KayokoHUD hide];
                    if ([strongSelf generation] != generation) {
                        return;
                    }

                    [strongSelf setRunning:NO];
                    [strongSelf updateTableInteraction];

                    if (failure) {
                        [strongSelf showFailureStateWithFailure:failure];
                        return;
                    }
                    if ([results count] == 0) {
                        [KayokoHUD showTransientStatus:KayokoScriptPanelLocalized(@"No matches",
                                                                                 @"No matches")];
                        return;
                    }

                    [strongSelf setValues:results ?: @[]];
                    if ([results count] == 1) {
                        NSString *singleResult = [results firstObject];
                        if ([singleResult length] > 0) {
                            [strongSelf showResultStateWithText:singleResult];
                        }
                    } else {
                        [strongSelf showChoicesState];
                    }
                  }];
}

- (void)updateTableInteraction {
    [[[self panelView] tableView] setUserInteractionEnabled:![self isRunning]];
    [[[self panelView] tableView] setAlpha:([self isRunning] ? 0.55 : 1.0)];
}

#pragma mark - Failure

- (void)showFailureStateWithFailure:(KayokoScriptFailure *)failure {
    [self setState:KayokoScriptPanelStateFailure];
    [[[self panelView] searchBar] resignFirstResponder];
    [[self panelView] setSearchBarVisible:NO];
    [[self panelView] setTitleText:[self activeScriptTitle]];
    NSString *report = [self reportForFailure:failure];
    // The failure page hides the paste button, so stashing the report here is enough to make the copy button work.
    [self setResultText:report];
    [[self panelView] showFailureWithText:report
                                copyTitle:KayokoScriptPanelLocalized(@"Copy error", @"Copy error")];
}

/// The page a failed run lands on. It answers three questions in the order they get asked: what went wrong,
/// which line, and what the script printed before it did.
- (NSString *)reportForFailure:(KayokoScriptFailure *)failure {
    NSMutableArray<NSString *> *sections = [NSMutableArray array];

    NSString *headline = [self headlineForFailure:failure];
    if ([headline length] > 0) {
        [sections addObject:headline];
    }

    // Left as the engine wrote it: this sentence comes from JavaScriptCore and names the actual mistake, which
    // no translation of ours would.
    NSString *message = [failure message];
    if ([message length] > 0 && ![message isEqualToString:headline]) {
        [sections addObject:message];
    }

    NSString *sourceLine = [failure sourceLine];
    if ([sourceLine length] > 0) {
        [sections addObject:[NSString
                                stringWithFormat:@"%@\n%@",
                                                 KayokoScriptPanelLocalized(@"Offending line", @"Offending line"),
                                                 sourceLine]];
    }

    NSArray<NSString *> *logs = [failure logs];
    if ([logs count] > 0) {
        [sections addObject:[NSString
                                stringWithFormat:@"%@\n%@",
                                                 KayokoScriptPanelLocalized(@"Console output", @"Console output"),
                                                 [logs componentsJoinedByString:@"\n"]]];
    }

    return [sections componentsJoinedByString:@"\n\n"];
}

- (NSString *)headlineForFailure:(KayokoScriptFailure *)failure {
    NSString *code = [failure code];
    NSInteger line = [failure line];

    if ([code isEqualToString:@"exception"]) {
        if ([[failure stage] isEqualToString:@"compile"]) {
            if (line > 0) {
                return [NSString
                    stringWithFormat:KayokoScriptPanelLocalized(@"Syntax error on line %ld",
                                                                @"Syntax error on line %ld"),
                                     (long)line];
            }
            return KayokoScriptPanelLocalized(@"Syntax error in the script", @"Syntax error in the script");
        }
        if (line > 0) {
            return [NSString
                stringWithFormat:KayokoScriptPanelLocalized(@"Failed on line %ld", @"Failed on line %ld"),
                                 (long)line];
        }
        return KayokoScriptPanelLocalized(@"Script failed while running", @"Script failed while running");
    }

    if ([code isEqualToString:@"no-main"]) {
        return KayokoScriptPanelLocalized(@"Script is missing a main(text) function",
                                          @"Script is missing a main(text) function");
    }

    if ([code isEqualToString:@"timeout"]) {
        NSNumber *seconds = [failure numberForKey:@"seconds"];
        return [NSString
            stringWithFormat:KayokoScriptPanelLocalized(@"Stopped after %g seconds", @"Stopped after %g seconds"),
                             seconds ? [seconds doubleValue] : 5.0];
    }

    if ([code isEqualToString:@"bad-result-type"]) {
        NSString *type = [failure stringForKey:@"type"];
        NSNumber *index = [failure numberForKey:@"index"];
        if (index) {
            return [NSString
                stringWithFormat:KayokoScriptPanelLocalized(@"Item %ld is %@, expected text",
                                                            @"Item %ld is %@, expected text"),
                                 (long)[index integerValue], type ?: @"?"];
        }
        return [NSString
            stringWithFormat:KayokoScriptPanelLocalized(@"Returned %@, expected text or a list of texts",
                                                        @"Returned %@, expected text or a list of texts"),
                             type ?: @"?"];
    }

    if ([code isEqualToString:@"too-many-results"]) {
        NSNumber *count = [failure numberForKey:@"count"];
        NSNumber *limit = [failure numberForKey:@"limit"];
        return [NSString
            stringWithFormat:KayokoScriptPanelLocalized(@"Returned %ld results, the limit is %ld",
                                                        @"Returned %ld results, the limit is %ld"),
                             (long)[count integerValue], (long)[limit integerValue]];
    }

    if ([code isEqualToString:@"result-too-large"]) {
        NSNumber *length = [failure numberForKey:@"length"];
        NSNumber *limit = [failure numberForKey:@"limit"];
        return [NSString
            stringWithFormat:KayokoScriptPanelLocalized(@"Result is %ld characters, the limit is %ld",
                                                        @"Result is %ld characters, the limit is %ld"),
                             (long)[length integerValue], (long)[limit integerValue]];
    }

    if ([code isEqualToString:@"input-too-large"]) {
        NSNumber *limit = [failure numberForKey:@"limit"];
        return [NSString
            stringWithFormat:KayokoScriptPanelLocalized(@"Input is larger than %ld bytes",
                                                        @"Input is larger than %ld bytes"),
                             (long)[limit integerValue]];
    }

    if ([code isEqualToString:@"missing-executor"]) {
        return KayokoScriptPanelLocalized(@"Script runner is unavailable", @"Script runner is unavailable");
    }

    if ([code isEqualToString:@"spawn-failed"]) {
        NSNumber *status = [failure numberForKey:@"status"];
        return [NSString
            stringWithFormat:KayokoScriptPanelLocalized(@"Unable to start the script runner (%d)",
                                                        @"Unable to start the script runner (%d)"),
                             (int)[status intValue]];
    }

    if ([code isEqualToString:@"runner-failed"]) {
        return KayokoScriptPanelLocalized(@"The script runner stopped unexpectedly",
                                          @"The script runner stopped unexpectedly");
    }

    if ([code isEqualToString:@"invalid-request"]) {
        return KayokoScriptPanelLocalized(@"Script request was rejected", @"Script request was rejected");
    }

    return KayokoScriptPanelLocalized(@"Script failed", @"Script failed");
}

#pragma mark - Actions

- (void)handleBackButtonPressed {
    if ([self isRunning]) {
        return;
    }

    switch ([self state]) {
    case KayokoScriptPanelStateResult:
        if ([[self values] count] > 1) {
            [self showChoicesState];
        } else {
            [self showListState];
        }
        break;
    case KayokoScriptPanelStateChoices:
        [self showListState];
        break;
    case KayokoScriptPanelStateFailure:
        [self showListState];
        break;
    case KayokoScriptPanelStateList:
        [[self delegate] scriptPanelControllerDidRequestBack:self];
        break;
    }

    if ([self hapticFeedbackHandler]) {
        [self hapticFeedbackHandler](UIImpactFeedbackStyleSoft);
    }
}

- (void)handleCopyButtonPressed {
    NSString *text = [self resultText];
    if ([text length] == 0) {
        return;
    }

    [[self delegate] scriptPanelController:self didRequestCopyText:text];
}

- (void)handlePasteButtonPressed {
    NSString *text = [self resultText];
    if ([text length] == 0) {
        return;
    }

    [[self delegate] scriptPanelController:self didRequestPasteText:text];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if ([self state] == KayokoScriptPanelStateList) {
        return (NSInteger)[[self filteredScripts] count];
    }

    return (NSInteger)[[self values] count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    KayokoScriptListCell *cell = [tableView dequeueReusableCellWithIdentifier:kKayokoScriptPanelCellReuseIdentifier];
    if (!cell) {
        cell = [[KayokoScriptListCell alloc] initWithStyle:UITableViewCellStyleDefault
                                           reuseIdentifier:kKayokoScriptPanelCellReuseIdentifier];
    }

    if ([self state] == KayokoScriptPanelStateList) {
        KayokoScript *script = [[self filteredScripts] objectAtIndex:(NSUInteger)[indexPath row]];
        [cell updateWithTitle:[script displayName] truncatesInMiddle:NO];
    } else {
        NSString *value = [[self values] objectAtIndex:(NSUInteger)[indexPath row]];
        [cell updateWithTitle:value truncatesInMiddle:YES];
    }

    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSUInteger row = (NSUInteger)[indexPath row];
    if ([self state] == KayokoScriptPanelStateList) {
        if (row < [[self filteredScripts] count]) {
            [self runScript:[[self filteredScripts] objectAtIndex:row]];
        }
        return;
    }

    if (row < [[self values] count]) {
        [self showResultStateWithText:[[self values] objectAtIndex:row]];
        if ([self hapticFeedbackHandler]) {
            [self hapticFeedbackHandler](UIImpactFeedbackStyleLight);
        }
    }
}

#pragma mark - UISearchBarDelegate

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
    [searchBar setShowsCancelButton:YES animated:YES];
}

- (void)searchBarTextDidEndEditing:(UISearchBar *)searchBar {
    [searchBar setShowsCancelButton:NO animated:YES];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self applyScriptFilter:searchText];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    [searchBar setText:@""];
    [self applyScriptFilter:@""];
    [searchBar resignFirstResponder];
}

/// An empty query restores the full list; otherwise every script whose name contains the text (case-insensitive)
/// stays. The table is reloaded in place, so the scroll offset and the rest position are both preserved.
- (void)applyScriptFilter:(NSString *)query {
    NSString *trimmed =
        [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed length] == 0) {
        [self setFilteredScripts:[self scripts]];
    } else {
        NSMutableArray<KayokoScript *> *filtered = [NSMutableArray array];
        for (KayokoScript *script in [self scripts]) {
            NSRange match = [[script displayName] rangeOfString:trimmed options:NSCaseInsensitiveSearch];
            if (match.location != NSNotFound) {
                [filtered addObject:script];
            }
        }
        [self setFilteredScripts:filtered];
    }
    [[[self panelView] tableView] reloadData];
}

@end
