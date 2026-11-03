//
//  KayokoScriptPanelController.m
//  Kayoko
//

#import "KayokoScriptPanelController.h"

#import "KayokoHeaderView.h"
#import "KayokoHUD.h"
#import "KayokoPasteboardManager.h"
#import "KayokoScript.h"
#import "KayokoScriptListCell.h"
#import "KayokoScriptPanelView.h"
#import "KayokoScriptRunner.h"
#import "KayokoScriptStore.h"

typedef NS_ENUM(NSUInteger, KayokoScriptPanelState) {
    KayokoScriptPanelStateList,
    KayokoScriptPanelStateChoices,
    KayokoScriptPanelStateResult,
};

static NSString *const kKayokoScriptPanelCellReuseIdentifier = @"KayokoScriptListCell";

NS_ASSUME_NONNULL_BEGIN

static NSString *KayokoScriptPanelLocalized(NSString *key, NSString *fallback) {
    return [[KayokoPasteboardManager localizationBundle] localizedStringForKey:key value:fallback table:@"Tweak"];
}

@interface KayokoScriptPanelController () <UITableViewDataSource, UITableViewDelegate>

@property(nonatomic, strong, readwrite) KayokoScriptPanelView *panelView;
@property(nonatomic, strong) KayokoScriptStore *scriptStore;
@property(nonatomic, strong) KayokoScriptRunner *runner;

@property(nonatomic, copy) NSString *inputText;
@property(nonatomic, copy) NSArray<KayokoScript *> *scripts;
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
        [[_panelView copyButton] addTarget:self
                                    action:@selector(handleCopyButtonPressed)
                          forControlEvents:UIControlEventTouchUpInside];
        [[_panelView pasteButton] addTarget:self
                                     action:@selector(handlePasteButtonPressed)
                           forControlEvents:UIControlEventTouchUpInside];
        [[_panelView tableView] setDataSource:self];
        [[_panelView tableView] setDelegate:self];
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
    [self showListState];
    [self updateTableInteraction];
}

#pragma mark - States

- (void)showListState {
    [self setState:KayokoScriptPanelStateList];
    [[self panelView] setTitleText:KayokoScriptPanelLocalized(@"Scripts", @"Scripts")];
    [[self panelView] showList];
    if ([[self scripts] count] == 0) {
        [[self panelView] showNotice:KayokoScriptPanelLocalized(@"No scripts enabled", @"No scripts enabled")];
    }
}

- (void)showChoicesState {
    [self setState:KayokoScriptPanelStateChoices];
    [[self panelView] setTitleText:[self activeScriptTitle]];
    [[self panelView] showList];
}

- (void)showResultStateWithText:(NSString *)text {
    [self setState:KayokoScriptPanelStateResult];
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
                  completion:^(NSArray<NSString *> *_Nullable results, NSString *_Nullable errorCode,
                               NSString *_Nullable errorMessage) {
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

                    if ([errorCode length] > 0) {
                        [KayokoHUD showTransientStatus:[strongSelf messageForErrorCode:errorCode
                                                                             fallback:errorMessage]];
                        return;
                    }
                    if ([results count] == 0) {
                        [KayokoHUD showTransientStatus:KayokoScriptPanelLocalized(@"No matches",
                                                                                 @"No matches")];
                        return;
                    }

                    [strongSelf setValues:results ?: @[]];
                    if ([results count] == 1) {
                        [strongSelf showResultStateWithText:[results firstObject]];
                    } else {
                        [strongSelf showChoicesState];
                    }
                  }];
}

- (void)updateTableInteraction {
    [[[self panelView] tableView] setUserInteractionEnabled:![self isRunning]];
    [[[self panelView] tableView] setAlpha:([self isRunning] ? 0.55 : 1.0)];
}

- (NSString *)messageForErrorCode:(nullable NSString *)code fallback:(nullable NSString *)fallback {
    NSString *localizationKey = nil;
    if ([code isEqualToString:@"timeout"]) {
        localizationKey = @"Script timed out";
    } else if ([code isEqualToString:@"no-main"]) {
        localizationKey = @"Script is missing a main(text) function";
    } else if ([code isEqualToString:@"missing-executor"] || [code isEqualToString:@"spawn-failed"]) {
        localizationKey = @"Script runner is unavailable";
    } else if ([code isEqualToString:@"too-many-results"] || [code isEqualToString:@"result-too-large"]) {
        localizationKey = @"Script returned too much text";
    } else if ([code isEqualToString:@"bad-result-type"]) {
        localizationKey = @"Script returned an unsupported value";
    }

    if ([localizationKey length] > 0) {
        return KayokoScriptPanelLocalized(localizationKey, localizationKey);
    }

    return [fallback length] > 0 ? fallback : KayokoScriptPanelLocalized(@"Script failed", @"Script failed");
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
        return [[self scripts] count];
    }

    return [[self values] count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    KayokoScriptListCell *cell = [tableView dequeueReusableCellWithIdentifier:kKayokoScriptPanelCellReuseIdentifier];
    if (!cell) {
        cell = [[KayokoScriptListCell alloc] initWithStyle:UITableViewCellStyleDefault
                                           reuseIdentifier:kKayokoScriptPanelCellReuseIdentifier];
    }

    if ([self state] == KayokoScriptPanelStateList) {
        KayokoScript *script = [[self scripts] objectAtIndex:(NSUInteger)[indexPath row]];
        [cell updateWithTitle:[script displayName] showsChevron:YES truncatesInMiddle:NO];
    } else {
        NSString *value = [[self values] objectAtIndex:(NSUInteger)[indexPath row]];
        [cell updateWithTitle:value showsChevron:YES truncatesInMiddle:YES];
    }

    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSUInteger row = (NSUInteger)[indexPath row];
    if ([self state] == KayokoScriptPanelStateList) {
        if (row < [[self scripts] count]) {
            [self runScript:[[self scripts] objectAtIndex:row]];
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

@end
