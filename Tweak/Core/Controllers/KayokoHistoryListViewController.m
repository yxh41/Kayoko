//
//  KayokoHistoryListViewController.m
//  Kayoko
//

#import "KayokoHistoryListViewController.h"
#import "KayokoFavoritesTableView.h"
#import "KayokoFloatActionHandler.h"
#import "KayokoHUD.h"
#import "KayokoHistoryItemActionHandler.h"
#import "KayokoHistoryListView.h"
#import "KayokoHistoryTableView.h"
#import "KayokoPasteboardItem.h"
#import "KayokoPasteboardManager.h"
#import "KayokoSearchCriteria.h"
#import "KayokoTableDataStore.h"
#import "KayokoTableViewCell.h"
#import "KayokoTableViewCellContent.h"
#import "KayokoTableViewCellContentProvider.h"

/// Faircopy's panel URL scheme. Faircopy's WritingTools injector intercepts
/// this scheme in-process and presents its panel with `keyword` as the text,
/// so a Kayoko clip can be handed over without a pasteboard round-trip.
static NSString *const kKayokoFaircopyPanelURLString = @"faircopy://panel";

/// Fallback for clips too long to ride in a URL: fill the pasteboard and post
/// this notification. Faircopy's standalone panel reads the pasteboard when it
/// is summoned with no keyword. (Same cross-process channel Kayoko itself uses.)
static NSString *const kKayokoFaircopyPresentNotification = @"wiki.qaq.faircopy.present";

/// Past this length a URL stops being a sane transport; switch to the pasteboard.
static const NSUInteger kKayokoFaircopyKeywordLengthLimit = 1000;

/// 4.3.22: pictures take a different road — see
/// `sendImageToFaircopyForSegmentation:` below. AIGate registers the same
/// `faircopy` scheme, so this host is simply "recognise this and bounce back";
/// Faircopy's injector only intercepts the `panel` host, which is what lets the
/// request leave SpringBoard at all.
///
/// 4.3.23: the URL also carries `?caller=<our bundle id>`. iOS reports
/// `com.apple.springboard` as the source application for this openURL (Faircopy
/// 3.0.80 logs it verbatim: `ocr: url received src=com.apple.springboard`), so
/// AIGate's "bounce back to whoever opened me" landed the user on the home
/// screen — and the panel, addressed to the home screen, had to be summoned
/// there. AIGate 3.0.82 prefers this explicit caller: the bounce returns here
/// and the panel is presented in this process, the way it already works in
/// Safari.
static NSString *const kKayokoFaircopyOCRURLString = @"faircopy://ocr?caller=";

/// Drop box for the picture and its answer. Same shared directory Faircopy's
/// panel hand-off and app-search stores already use, and the one place both
/// processes can reach: a clipboard screenshot is far too large for a URL, and
/// SpringBoard and the AIGate app share no container.
/// KEEP IN SYNC with FaircopyImageOCR in AIGate/AIGate/Editor/FaircopyApp.swift.
static NSString *const kKayokoFaircopyOCRDirectory =
    @"/var/mobile/Library/Preferences/wiki.qaq.ai.gate";
static NSString *const kKayokoFaircopyOCRInputPath =
    @"/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_ocr_input.img";
static NSString *const kKayokoFaircopyOCRResultPath =
    @"/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_ocr_result.json";
/// Posted by AIGate once the recognition finished, whatever the outcome.
static NSString *const kKayokoFaircopyOCRResultNotification = @"wiki.qaq.faircopy.ocr.result";

/// 4.3.24: ask the resident AIGate process to read the picture where it is.
///
/// The app switch only ever existed because Vision's accurate network refuses
/// to run inside SpringBoard. AIGate is the process that can run it, and while
/// it is parked in the background a Darwin notification wakes it without
/// bringing anything forward: the list the user is looking at stays in front,
/// and the panel is presented on top of it.
///
/// KEEP IN SYNC with FaircopyImageOCR.requestNotification.
static NSString *const kKayokoFaircopyOCRRequestNotification = @"wiki.qaq.faircopy.ocr.request";

/// How long to wait for that answer before taking the visible road.
///
/// 4.3.27: one flat value was shorter than the work. A cold accurate pass on a
/// full-screen screenshot measures 4.9 s (`faircopy_ocr.log` 18:51:31
/// `t=4883ms`), a warm one 1.6 s, so a 2 s timer always won on the first picture
/// after a boot or after the worker had been idle for a while: the app switch
/// fired, and the panel arrived on top of it a second later. That is the
/// "首次还是会跳转一下" report, and it is the timer, not the recognition.
///
/// The resident worker's heartbeat tells the two cases apart, so each road now
/// gets the wait it deserves — long enough for a cold pass when somebody is
/// actually working on the picture, and *shorter* than before when nobody is,
/// because that is when the fallback is the only road left.
///
/// KEEP IN SYNC with FaircopyDaemon.heartbeatPath.
static NSString *const kKayokoFaircopyDaemonHeartbeatPath =
    @"/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_ocr_daemon.json";

/// KEEP IN SYNC with `FaircopyDaemon.isAlive()` (15 s).
static const NSTimeInterval kKayokoFaircopyDaemonHeartbeatTTL = 15.0;

/// Long enough for a cold accurate pass plus the hand-off write.
static const NSTimeInterval kKayokoFaircopyOCRSilentWaitResident = 6.0;

/// No worker: do not make the user stare at a pill before doing the only thing
/// that can work.
static const NSTimeInterval kKayokoFaircopyOCRSilentWaitAbsent = 0.8;

/// True while a launchd-started worker is answering requests.
///
/// Read-only and failure-tolerant on purpose: SpringBoard is the wrong place to
/// be strict, and a missing or unparsable heartbeat means "nobody there", which
/// simply takes the road that worked before 4.3.24.
static BOOL KayokoFaircopyResidentWorkerIsAlive(void) {
    NSData *data = [NSData dataWithContentsOfFile:kKayokoFaircopyDaemonHeartbeatPath];
    if (data.length == 0) {
        return NO;
    }
    NSDictionary *object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    NSNumber *at = object[@"at"];
    if (![at isKindOfClass:[NSNumber class]]) {
        return NO;
    }
    return [NSDate date].timeIntervalSince1970 - at.doubleValue <
           kKayokoFaircopyDaemonHeartbeatTTL;
}

/// 4.3.25: which app the panel belongs on.
///
/// This list is a SpringBoard window drawn on top of whatever the user is
/// looking at (`KayokoCore.plist` injects SpringBoard only), so "here" is NOT
/// SpringBoard: the panel has to be presented by the app underneath, or it
/// lands on SpringBoard's layer beneath that app's window and the user sees
/// nothing until they go back to the home screen.
///
/// AIGate cannot answer this itself — it is a background process, not the
/// workspace — so the answer travels in a file beside the picture.
///
/// KEEP IN SYNC with FaircopyImageOCR.displayTargetPath.
static NSString *const kKayokoFaircopyOCRDisplayTargetPath =
    @"/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_ocr_target.txt";

/// A bundle id worth handing to another process: ASCII, dotted, sane length.
///
/// 4.3.26: this is the belt to the KVC braces. Whatever a private API hands
/// back has to look like a bundle id before it can become a panel target — the
/// 4.3.25 crash was precisely a value that did not.
static BOOL KayokoIsPlausibleBundleIdentifier(NSString *bundle) {
    if (![bundle isKindOfClass:[NSString class]]) {
        return NO;
    }
    if (bundle.length == 0 || bundle.length > 200) {
        return NO;
    }
    NSCharacterSet *allowed = [NSCharacterSet
        characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    return [bundle rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

/// The bundle id of the app currently in front, or nil when it cannot be read.
///
/// 4.3.26: KVC only. 4.3.25 also called
/// `SBFrontmostApplicationDisplayIdentifier()` through dlsym, whose signature
/// on iOS 16.4 is not `CFStringRef (void)`: it handed back an invalid pointer,
/// `copy` was sent to it, and SpringBoard died with EXC_BAD_ACCESS at
/// 0x10000003 (crash 07:48 on 2026-10-31, main thread, inside
/// UIContextualAction's handler). Nothing about that call is worth the risk —
/// the object graph below answers the same question, and when even that fails
/// the panel is simply left to the injector's arbitration, which does not need
/// to know the app's name at all.
static NSString *KayokoFaircopyFrontmostBundleIdentifier(void) {
    NSArray<NSString *> *classNames = @[ @"SBWorkspace", @"SBApplicationController" ];
    NSArray<NSString *> *keys = @[ @"frontmostApplication", @"_frontmostApplication" ];
    for (NSString *className in classNames) {
        Class cls = NSClassFromString(className);
        if (![cls respondsToSelector:@selector(sharedInstance)]) {
            continue;
        }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id shared = [cls performSelector:@selector(sharedInstance)];
#pragma clang diagnostic pop
        for (NSString *key in keys) {
            @try {
                id application = [shared valueForKey:key];
                NSString *bundle = [application valueForKey:@"bundleIdentifier"];
                if (KayokoIsPlausibleBundleIdentifier(bundle)) {
                    return bundle;
                }
            } @catch (__unused NSException *exception) {
                // A missing key is the normal case for one of the two spellings.
            }
        }
    }
    return nil;
}

/// Leaves the answer where AIGate can read it.
///
/// 4.3.26: no answer means NO file, not "SpringBoard". An empty file is read by
/// AIGate as "let the injector arbitrate", which is the road a plain broadcast
/// has always taken — the app the user is looking at claims the panel first and
/// SpringBoard defers 0.8 s. Writing SpringBoard here would pin the panel to
/// the home screen, i.e. exactly the behaviour this is meant to remove.
static void KayokoWriteFaircopyOCRDisplayTarget(void) {
    NSString *bundle = KayokoFaircopyFrontmostBundleIdentifier();
    if (!KayokoIsPlausibleBundleIdentifier(bundle)) {
        [[NSFileManager defaultManager] removeItemAtPath:kKayokoFaircopyOCRDisplayTargetPath
                                                   error:nil];
        return;
    }
    [bundle writeToFile:kKayokoFaircopyOCRDisplayTargetPath
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
}

/// A hand-off that dies mid-flight (AIGate killed by jetsam, bounce lost) must
/// not leave the pill spinning on the home screen forever.
static const NSTimeInterval kKayokoFaircopyOCRTimeout = 12.0;

/// One hand-off at a time: a late result from a previous picture must not take
/// down the pill of the current one, or claim its words.
static BOOL gKayokoFaircopyOCRHandoffPending = NO;

/// 4.3.24: the visible road is fired at most once per hand-off — the silent
/// answer and the 2 s timeout can both decide to take it.
static BOOL gKayokoFaircopyOCRVisibleRoadIssued = NO;

/// Hands text to Faircopy: URL when it fits, pasteboard + notification otherwise.
///
/// Deliberately a C function rather than a method: the OCR hand-off outlives the
/// list controller (the panel is dismissed before recognition starts), so it must
/// stay callable after `self` is gone.
static void KayokoSendTextToFaircopy(NSString *content, NSString *mode, NSUInteger limit) {
    if ([content length] <= limit) {
        NSURLComponents *components = [NSURLComponents componentsWithString:kKayokoFaircopyPanelURLString];
        NSMutableArray<NSURLQueryItem *> *queryItems =
            [NSMutableArray arrayWithObject:[NSURLQueryItem queryItemWithName:@"keyword" value:content]];
        if ([mode length] > 0) {
            [queryItems addObject:[NSURLQueryItem queryItemWithName:@"mode" value:mode]];
        }
        [components setQueryItems:queryItems];
        NSURL *URL = [components URL];
        if (URL) {
            [[UIApplication sharedApplication] openURL:URL options:@{} completionHandler:nil];
            return;
        }
    }

    // Too long for a URL. The pasteboard carries the text but not the options, so
    // this road always opens the normal panel (see the method doc below).
    [[UIPasteboard generalPasteboard] setString:content];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kKayokoFaircopyPresentNotification,
                                         NULL,
                                         NULL,
                                         YES);
}

#pragma mark - Picture hand-off (4.3.22)

/// Vision's accurate text network cannot run inside SpringBoard.
///
/// 4.3.15-4.3.21 tried everything in-process: the recognition level (Accurate is
/// raw value 0, Fast is 1), the revision, the language list, the image variant.
/// The 4.3.20 probe settled it — every `.accurate` pass on the very same handler
/// and the very same picture fails with `Error computing NN outputs`, while a
/// `.fast` pass on that same handler in the same run returns observations. Fast,
/// however, ships no Chinese model at all, which is why it read `凡人修仙传` as
/// `nAlI°ILtIl*`. The network needs a process it will run in, so the recognition
/// happens in AIGate — a real app, where Live Text does the same work — and the
/// answer comes back through the shared directory.
///
/// The picture travels by file: a clipboard screenshot is far too large for a
/// URL, and SpringBoard and the app share no container.

/// Copies the picture into the drop box and clears the previous answer.
static BOOL KayokoPrepareFaircopyOCRHandoff(NSString *imagePath) {
    NSData *data = [NSData dataWithContentsOfFile:imagePath];
    if (data.length == 0) {
        return NO;
    }
    NSFileManager *manager = [NSFileManager defaultManager];
    [manager createDirectoryAtPath:kKayokoFaircopyOCRDirectory
       withIntermediateDirectories:YES
                        attributes:nil
                             error:nil];
    // A stale answer must never be mistaken for this picture's.
    [manager removeItemAtPath:kKayokoFaircopyOCRResultPath error:nil];
    return [data writeToFile:kKayokoFaircopyOCRInputPath options:NSDataWritingAtomic error:nil];
}

/// Runs the visible road: hand the picture to AIGate through `faircopy://ocr`,
/// which brings it to the front for the length of one recognition.
///
/// Only used when the silent request went unanswered (AIGate was jetsammed or
/// has not been opened since install) or when the silent attempt itself could
/// not finish. Guarded so a slow answer and the 2 s timeout cannot both fire it.
static void KayokoRunFaircopyOCRVisibleRoad(void);

/// Reads AIGate's answer and settles the pill. `ok` means the panel is on its
/// way; `retry` means the silent attempt could not finish and the visible road
/// must run; anything else means the picture had no text (or the hand-off
/// failed), and staying silent there would look exactly like a dead button.
static void KayokoSettleFaircopyOCRHandoff(void) {
    if (!gKayokoFaircopyOCRHandoffPending) {
        return;
    }

    NSData *data = [NSData dataWithContentsOfFile:kKayokoFaircopyOCRResultPath];
    NSDictionary *result = data
        ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![result isKindOfClass:[NSDictionary class]]) {
        gKayokoFaircopyOCRHandoffPending = NO;
        [KayokoHUD hide];
        return;
    }
    if ([result[@"retry"] boolValue]) {
        // 4.3.24: the background attempt gave up — the picture could not be
        // read there, or the hand-off file could not be written. Take the
        // visible road rather than telling the user there was no text, which
        // is what a zero-length answer would look like. The hand-off stays
        // pending: that road writes the second answer.
        KayokoRunFaircopyOCRVisibleRoad();
        return;
    }
    gKayokoFaircopyOCRHandoffPending = NO;
    if ([result[@"ok"] boolValue]) {
        [KayokoHUD hide];
        return;
    }
    NSInteger chars = [result[@"chars"] integerValue];
    if (chars > 0) {
        // Recognised, but the panel invocation never landed. Nothing useful to
        // say beyond "that did not work"; the pill must still go away.
        [KayokoHUD hide];
        return;
    }
    [KayokoHUD showTransientStatus:@"No text in this image"];
    UINotificationFeedbackGenerator *generator = [[UINotificationFeedbackGenerator alloc] init];
    [generator notificationOccurred:UINotificationFeedbackTypeWarning];
}

static void KayokoFaircopyOCRResultCallback(__unused CFNotificationCenterRef center,
                                            __unused void *observer,
                                            __unused CFStringRef name,
                                            __unused const void *object,
                                            __unused CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
      KayokoSettleFaircopyOCRHandoff();
    });
}

static void KayokoObserveFaircopyOCRResult(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                      KayokoFaircopyOCRResultCallback,
                                      (__bridge CFStringRef)kKayokoFaircopyOCRResultNotification,
                                      NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    });
}

NS_ASSUME_NONNULL_BEGIN

@interface KayokoHistoryListViewController () <UITableViewDelegate, UITableViewDataSource>

#pragma mark - Views

@property(nonatomic, strong, readwrite) KayokoHistoryListView *tableView;

#pragma mark - State

@property(nonatomic, copy, readwrite) NSString *historyKey;
@property(nonatomic, copy, readwrite) NSString *name;

#pragma mark - Data

@property(nonatomic, strong) KayokoTableDataStore *dataStore;
@property(nonatomic, strong) KayokoTableViewCellContentProvider *cellContentProvider;
@property(nonatomic, strong) KayokoHistoryItemActionHandler *actionHandler;
@property(nonatomic, copy, nullable) NSString *presentationHiddenItemContent;

- (KayokoTableViewCell *)newCellForItem:(KayokoPasteboardItem *)item addsPreviewGesture:(BOOL)addsPreviewGesture;
- (void)loadThumbnailForItem:(KayokoPasteboardItem *)item intoCell:(KayokoTableViewCell *)cell;
- (void)refreshVisibleItemDetails;
- (void)removeItemDictionary:(NSDictionary<NSString *, id> *)dictionary
                  completion:(nullable void (^)(BOOL success))completion;
@end

NS_ASSUME_NONNULL_END

@implementation KayokoHistoryListViewController

#pragma mark - Lifecycle

- (instancetype)initWithName:(NSString *)name historyKey:(NSString *)historyKey {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _name = [name copy] ?: @"";
        _historyKey = [historyKey copy] ?: kKayokoHistoryKeyHistory;
        if ([_historyKey isEqualToString:kKayokoHistoryKeyFavorites]) {
            _tableView = [[KayokoFavoritesTableView alloc] initWithName:_name];
        } else {
            _tableView = [[KayokoHistoryTableView alloc] initWithName:_name];
        }
        _dataStore = [[KayokoTableDataStore alloc] init];
        _cellContentProvider = [[KayokoTableViewCellContentProvider alloc] init];
        _actionHandler = [[KayokoHistoryItemActionHandler alloc] init];
        [_tableView setName:_name];
        [_tableView setDelegate:self];
        [_tableView setDataSource:self];
    }
    return self;
}

- (void)loadView {
    [self setView:[self tableView]];
}

#pragma mark - State

- (NSArray<NSDictionary<NSString *, id> *> *)items {
    return [[self dataStore] items];
}

- (NSArray<NSDictionary<NSString *, id> *> *)displayedItems {
    return [[self dataStore] displayedItems];
}

- (NSString *)searchText {
    return [[self dataStore] searchText];
}

- (KayokoSearchCriteria *)searchCriteria {
    return [[self dataStore] searchCriteria];
}

- (BOOL)isBrowsingSearchTokens {
    return [[self dataStore] isBrowsingSearchTokens];
}

- (BOOL)hasActiveSearch {
    return [[self dataStore] hasActiveSearch];
}

- (void)setPreviewLineCount:(NSUInteger)previewLineCount {
    [[self tableView] setPreviewLineCount:previewLineCount];
}

- (NSUInteger)previewLineCount {
    return [[self tableView] previewLineCount];
}

- (void)setItemDetailsMode:(KayokoItemDetailsMode)itemDetailsMode {
    [[self tableView] setItemDetailsMode:itemDetailsMode];
}

- (KayokoItemDetailsMode)itemDetailsMode {
    return [[self tableView] itemDetailsMode];
}

- (void)refreshSearchPlaceholder {
    BOOL showsNoSearchResults = [self hasActiveSearch] && ![self isBrowsingSearchTokens] && [[self items] count] > 0 &&
                                [[self displayedItems] count] == 0;
    [[self tableView] setShowsNoSearchResultsPlaceholder:showsNoSearchResults];
}

- (void)reloadTableView {
    [[self tableView] reloadData];
    [self refreshSearchPlaceholder];
}

- (void)refreshVisibleItemDetails {
    for (NSIndexPath *indexPath in [[self tableView] indexPathsForVisibleRows]) {
        KayokoPasteboardItem *item =
            [KayokoPasteboardItem itemFromDictionary:[self itemDictionaryAtIndexPath:indexPath]];
        if (!item) {
            continue;
        }
        KayokoTableViewCellContent *content = [[self cellContentProvider] cellContentForItem:item
                                                                            previewLineCount:[self previewLineCount]
                                                                             itemDetailsMode:[self itemDetailsMode]
                                                                                  searchText:[self searchText]];
        KayokoTableViewCell *cell = (KayokoTableViewCell *)[[self tableView] cellForRowAtIndexPath:indexPath];
        [cell applyDetailContent:content];
    }
}

- (void)scrollToTopAnimated:(BOOL)animated {
    [[self tableView] scrollToTopAnimated:animated];
}

#pragma mark - Diffing

- (NSArray<NSIndexPath *> *)indexPathsFromRow:(NSUInteger)startRow count:(NSUInteger)count {
    NSMutableArray<NSIndexPath *> *indexPaths = [[NSMutableArray alloc] initWithCapacity:count];
    for (NSUInteger row = startRow; row < startRow + count; row++) {
        [indexPaths addObject:[NSIndexPath indexPathForRow:row inSection:0]];
    }
    return indexPaths;
}

- (BOOL)canUpdateFromItems:(NSArray<NSDictionary<NSString *, id> *> *)oldItems
                   toItems:(NSArray<NSDictionary<NSString *, id> *> *)newItems
      withTopInsertedCount:(NSUInteger *)insertedCount
        bottomRemovedCount:(NSUInteger *)removedCount {
    NSUInteger oldCount = [oldItems count];
    NSUInteger newCount = [newItems count];

    if (newCount == 0 || [oldItems isEqualToArray:newItems]) {
        return NO;
    }

    if (oldCount == 0) {
        if (insertedCount) {
            *insertedCount = newCount;
        }
        if (removedCount) {
            *removedCount = 0;
        }
        return YES;
    }

    NSUInteger candidateInsertedCount = [newItems indexOfObject:oldItems[0]];
    if (candidateInsertedCount == NSNotFound || candidateInsertedCount == 0) {
        return NO;
    }

    NSUInteger retainedCount = MIN(oldCount, newCount - candidateInsertedCount);
    if (retainedCount == 0 || candidateInsertedCount + retainedCount != newCount) {
        return NO;
    }

    for (NSUInteger index = 0; index < retainedCount; index++) {
        if (![newItems[candidateInsertedCount + index] isEqual:oldItems[index]]) {
            return NO;
        }
    }

    if (insertedCount) {
        *insertedCount = candidateInsertedCount;
    }
    if (removedCount) {
        *removedCount = oldCount - retainedCount;
    }
    return YES;
}

- (NSUInteger)normalizedLimit:(NSUInteger)limit {
    return limit == 0 ? NSUIntegerMax : limit;
}

- (BOOL)shouldRestoreContentOffsetAfterTopInsertionFromOffset:(CGPoint)contentOffset {
    return ![self hasActiveSearch] && [[self tableView] isContentOffsetAtHiddenSearchHeaderBoundary:contentOffset];
}

- (BOOL)shouldRestoreContentOffsetAfterTopRowRemovalAtIndexPath:(NSIndexPath *)indexPath
                                                     fromOffset:(CGPoint)contentOffset {
    if ([indexPath row] != 0) {
        return NO;
    }

    return [[self tableView] isSearchHeaderExposedAtContentOffset:contentOffset] ||
           [[self tableView] isContentOffsetAtHiddenSearchHeaderBoundary:contentOffset];
}

- (BOOL)shouldRestoreContentOffsetAfterMovingRowToTopFromOffset:(CGPoint)contentOffset {
    return ![self hasActiveSearch] && ([[self tableView] isSearchHeaderExposedAtContentOffset:contentOffset] ||
                                       [[self tableView] isContentOffsetAtHiddenSearchHeaderBoundary:contentOffset]);
}

- (UITableViewRowAnimation)rowAnimationForTopInsertionFromContentOffset:(CGPoint)contentOffset {
    if ([[self tableView] isSearchHeaderExposedAtContentOffset:contentOffset]) {
        return UITableViewRowAnimationFade;
    }

    return UITableViewRowAnimationTop;
}

- (nullable NSDictionary<NSString *, id> *)itemDictionaryAtIndexPath:(NSIndexPath *)indexPath {
    NSArray<NSDictionary<NSString *, id> *> *displayedItems = [self displayedItems];
    if ([indexPath row] >= [displayedItems count]) {
        return nil;
    }
    return displayedItems[[indexPath row]];
}

#pragma mark - Data Updates

- (void)setItems:(NSArray<NSDictionary<NSString *, id> *> *)items {
    [[self dataStore] setItems:items];
}

- (void)reloadDataWithItems:(NSArray<NSDictionary<NSString *, id> *> *)items {
    [self updateDataWithItems:items animatingTopInsertions:NO];
}

- (void)updateDataWithItems:(NSArray<NSDictionary<NSString *, id> *> *)items
     animatingTopInsertions:(BOOL)animatingTopInsertions {
    NSArray<NSDictionary<NSString *, id> *> *oldItems = [self items] ?: @[];
    NSArray<NSDictionary<NSString *, id> *> *newItems = items ?: @[];
    if ([oldItems isEqualToArray:newItems] && [[self tableView] numberOfRowsInSection:0] == [oldItems count]) {
        [self refreshVisibleItemDetails];
        return;
    }

    NSUInteger insertedCount = 0;
    NSUInteger removedCount = 0;
    BOOL canAnimateTopInsertion = ![self hasActiveSearch] && animatingTopInsertions &&
                                  [[self tableView] numberOfRowsInSection:0] == [oldItems count] &&
                                  [self canUpdateFromItems:oldItems
                                                   toItems:newItems
                                      withTopInsertedCount:&insertedCount
                                        bottomRemovedCount:&removedCount];

    if (!canAnimateTopInsertion) {
        [self setItems:newItems];
        [self reloadTableView];
        return;
    }

    NSArray<NSIndexPath *> *insertedIndexPaths = [self indexPathsFromRow:0 count:insertedCount];
    NSArray<NSIndexPath *> *removedIndexPaths = [self indexPathsFromRow:[oldItems count] - removedCount
                                                                  count:removedCount];
    UITableViewRowAnimation insertionAnimation =
        [self rowAnimationForTopInsertionFromContentOffset:[[self tableView] contentOffset]];

    [[self tableView]
        performBatchUpdates:^{
          [self setItems:newItems];
          if ([insertedIndexPaths count] > 0) {
              [[self tableView] insertRowsAtIndexPaths:insertedIndexPaths withRowAnimation:insertionAnimation];
          }
          if ([removedIndexPaths count] > 0) {
              [[self tableView] deleteRowsAtIndexPaths:removedIndexPaths withRowAnimation:UITableViewRowAnimationFade];
          }
        }
        completion:^(__unused BOOL finished) {
          [self refreshVisibleItemDetails];
          [self refreshSearchPlaceholder];
        }];
}

#pragma mark - Search

- (void)applySearchText:(NSString *)searchText {
    [[self dataStore] applySearchText:searchText];
    [self reloadTableView];
}

- (void)beginApplyingSearchCriteria:(KayokoSearchCriteria *)searchCriteria {
    [[self dataStore] beginApplyingSearchCriteria:searchCriteria];
    [self refreshSearchPlaceholder];
}

- (void)applySearchCriteria:(KayokoSearchCriteria *)searchCriteria
              filteredItems:(NSArray<NSDictionary<NSString *, id> *> *)filteredItems {
    [[self dataStore] applySearchCriteria:searchCriteria filteredItems:filteredItems];
    [self reloadTableView];
}

- (void)showSearchTokensWithFullListForCriteria:(KayokoSearchCriteria *)searchCriteria {
    [[self dataStore] showSearchTokensWithFullListForCriteria:searchCriteria];
    [self reloadTableView];
}

- (void)clearSearch {
    [[self dataStore] clearSearch];
    [self reloadTableView];
}

#pragma mark - Item Mutations

- (void)clearItems {
    NSArray<NSDictionary<NSString *, id> *> *oldItems = [self items] ?: @[];
    if ([oldItems count] == 0) {
        return;
    }

    [self setItems:@[]];
    [self reloadTableView];
}

- (void)upsertItemDictionaryAtTop:(NSDictionary<NSString *, id> *)dictionary limit:(NSUInteger)limit {
    [self upsertItemDictionaryAtTop:dictionary limit:limit animating:YES];
}

- (void)upsertItemDictionaryAtTop:(NSDictionary<NSString *, id> *)dictionary
                            limit:(NSUInteger)limit
                        animating:(BOOL)animating {
    if (!dictionary || [dictionary[kKayokoItemKeyContent] length] == 0) {
        return;
    }

    NSArray<NSDictionary<NSString *, id> *> *oldItems = [self items] ?: @[];
    NSMutableArray<NSDictionary<NSString *, id> *> *newItems = [oldItems mutableCopy];
    NSUInteger existingIndex = [[self dataStore] indexOfItemMatchingDictionary:dictionary inItems:newItems];
    NSUInteger normalizedLimit = [self normalizedLimit:limit];

    if (existingIndex != NSNotFound) {
        [newItems removeObjectAtIndex:existingIndex];
    }
    [newItems insertObject:dictionary atIndex:0];
    while ([newItems count] > normalizedLimit) {
        [newItems removeLastObject];
    }

    if ([oldItems isEqualToArray:newItems] &&
        [[self tableView] numberOfRowsInSection:0] == [[self displayedItems] count]) {
        [self refreshVisibleItemDetails];
        return;
    }

    if (!animating) {
        [self updateDataWithItems:newItems animatingTopInsertions:NO];
        return;
    }

    if ([self hasActiveSearch] || [[self tableView] numberOfRowsInSection:0] != [oldItems count]) {
        [self updateDataWithItems:newItems animatingTopInsertions:YES];
        return;
    }

    if (existingIndex == 0) {
        [self setItems:newItems];
        [[self tableView] reloadRowsAtIndexPaths:@[ [NSIndexPath indexPathForRow:0 inSection:0] ]
                                withRowAnimation:UITableViewRowAnimationNone];
        [self refreshVisibleItemDetails];
        [self refreshSearchPlaceholder];
        return;
    }

    if (existingIndex != NSNotFound && existingIndex < [oldItems count] && [newItems count] == [oldItems count]) {
        CGPoint contentOffsetBeforeMove = [[self tableView] contentOffset];
        BOOL restoresContentOffsetAfterMove =
            [self shouldRestoreContentOffsetAfterMovingRowToTopFromOffset:contentOffsetBeforeMove];

        [[self tableView]
            performBatchUpdates:^{
              [self setItems:newItems];
              [[self tableView] moveRowAtIndexPath:[NSIndexPath indexPathForRow:existingIndex inSection:0]
                                       toIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
            }
            completion:^(__unused BOOL finished) {
              if (restoresContentOffsetAfterMove) {
                  [[self tableView] setContentOffset:contentOffsetBeforeMove animated:NO];
              }
              [self refreshVisibleItemDetails];
              [self refreshSearchPlaceholder];
            }];
        return;
    }

    NSUInteger removedCount = [oldItems count] + 1 > [newItems count] ? [oldItems count] + 1 - [newItems count] : 0;
    NSMutableArray<NSIndexPath *> *removedIndexPaths = [[NSMutableArray alloc] initWithCapacity:removedCount];
    for (NSUInteger row = [oldItems count] - removedCount; row < [oldItems count]; row++) {
        [removedIndexPaths addObject:[NSIndexPath indexPathForRow:row inSection:0]];
    }

    CGPoint contentOffsetBeforeInsertion = [[self tableView] contentOffset];
    BOOL restoresContentOffsetAfterInsertion =
        [self shouldRestoreContentOffsetAfterTopInsertionFromOffset:contentOffsetBeforeInsertion];
    UITableViewRowAnimation insertionAnimation =
        [self rowAnimationForTopInsertionFromContentOffset:contentOffsetBeforeInsertion];

    [[self tableView]
        performBatchUpdates:^{
          [self setItems:newItems];
          [[self tableView] insertRowsAtIndexPaths:@[ [NSIndexPath indexPathForRow:0 inSection:0] ]
                                  withRowAnimation:insertionAnimation];
          if ([removedIndexPaths count] > 0) {
              [[self tableView] deleteRowsAtIndexPaths:removedIndexPaths withRowAnimation:UITableViewRowAnimationFade];
          }
        }
        completion:^(__unused BOOL finished) {
          if (restoresContentOffsetAfterInsertion) {
              [[self tableView] setContentOffset:contentOffsetBeforeInsertion animated:NO];
          }
          [self refreshVisibleItemDetails];
          [self refreshSearchPlaceholder];
        }];
}

- (void)removeItemDictionary:(NSDictionary<NSString *, id> *)dictionary {
    [self removeItemDictionary:dictionary completion:nil];
}

- (void)removeItemAtIndexPath:(NSIndexPath *)indexPath completion:(void (^)(BOOL success))completion {
    NSDictionary<NSString *, id> *dictionary = [self itemDictionaryAtIndexPath:indexPath];
    if (!dictionary) {
        if (completion) {
            completion(NO);
        }
        return;
    }

    [self removeItemDictionary:dictionary completion:completion];
}

- (void)removeItemDictionary:(NSDictionary<NSString *, id> *)dictionary completion:(void (^)(BOOL success))completion {
    if (!dictionary) {
        if (completion) {
            completion(NO);
        }
        return;
    }

    NSUInteger itemIndex = [[self dataStore] indexOfItemMatchingDictionary:dictionary inItems:[self items] ?: @[]];
    if (itemIndex == NSNotFound) {
        if (completion) {
            completion(NO);
        }
        return;
    }

    NSUInteger displayedIndex = [[self dataStore] indexOfItemMatchingDictionary:dictionary
                                                                        inItems:[self displayedItems] ?: @[]];
    BOOL canAnimateRemoval =
        displayedIndex != NSNotFound && [[self tableView] numberOfRowsInSection:0] == [[self displayedItems] count];
    if (!canAnimateRemoval) {
        BOOL removed = [[self dataStore] removeItemMatchingDictionary:dictionary displayedItemIndex:nil];
        if (displayedIndex != NSNotFound) {
            [self reloadTableView];
        } else {
            [self refreshSearchPlaceholder];
        }
        if (completion) {
            completion(removed);
        }
        return;
    }

    NSIndexPath *displayedIndexPath = [NSIndexPath indexPathForRow:displayedIndex inSection:0];

    CGPoint contentOffsetBeforeRemoval = [[self tableView] contentOffset];
    BOOL restoresContentOffsetAfterRemoval =
        [self shouldRestoreContentOffsetAfterTopRowRemovalAtIndexPath:displayedIndexPath
                                                           fromOffset:contentOffsetBeforeRemoval];

    [[self tableView] prepareHiddenHeaderInsetsForRemovingRowAtIndexPath:displayedIndexPath];

    __block BOOL removed = NO;
    [[self tableView]
        performBatchUpdates:^{
          NSUInteger removedDisplayedIndex = NSNotFound;
          removed = [[self dataStore] removeItemMatchingDictionary:dictionary
                                                displayedItemIndex:&removedDisplayedIndex];
          if (removed && removedDisplayedIndex != NSNotFound) {
              NSIndexPath *removedIndexPath = [NSIndexPath indexPathForRow:removedDisplayedIndex inSection:0];
              [[self tableView] deleteRowsAtIndexPaths:@[ removedIndexPath ]
                                      withRowAnimation:UITableViewRowAnimationAutomatic];
          }
        }
        completion:^(__unused BOOL finished) {
          if (restoresContentOffsetAfterRemoval) {
              [[self tableView] setContentOffset:contentOffsetBeforeRemoval animated:NO];
          }
          [self refreshVisibleItemDetails];
          [self refreshSearchPlaceholder];
          if (completion) {
              completion(removed);
          }
        }];
}

- (void)updateTagUUID:(NSString *)tagUUID forItem:(KayokoPasteboardItem *)item {
    if (!item) {
        return;
    }

    NSDictionary<NSString *, id> *dictionary = [item dictionaryRepresentation];
    __block KayokoTableDataStoreDisplayedItemUpdate update = KayokoTableDataStoreDisplayedItemUpdateNotFound;
    __block NSUInteger displayedIndex = NSNotFound;

    [[self tableView]
        performBatchUpdates:^{
          update = [[self dataStore] updateTagUUID:tagUUID
                         forItemMatchingDictionary:dictionary
                                displayedItemIndex:&displayedIndex];
          if (displayedIndex == NSNotFound) {
              return;
          }

          NSIndexPath *indexPath = [NSIndexPath indexPathForRow:displayedIndex inSection:0];
          if (update == KayokoTableDataStoreDisplayedItemUpdateRemove) {
              [[self tableView] deleteRowsAtIndexPaths:@[ indexPath ]
                                      withRowAnimation:UITableViewRowAnimationAutomatic];
          } else if (update == KayokoTableDataStoreDisplayedItemUpdateReload) {
              [[self tableView] reloadRowsAtIndexPaths:@[ indexPath ] withRowAnimation:UITableViewRowAnimationNone];
          }
        }
        completion:^(__unused BOOL finished) {
          [self refreshVisibleItemDetails];
          [self refreshSearchPlaceholder];
        }];
}

- (void)updateNote:(NSString *)note forItem:(KayokoPasteboardItem *)item completion:(void (^)(void))completion {
    if (!item) {
        if (completion) {
            completion();
        }
        return;
    }

    NSDictionary<NSString *, id> *dictionary = [item dictionaryRepresentation];
    __block KayokoTableDataStoreDisplayedItemUpdate update = KayokoTableDataStoreDisplayedItemUpdateNotFound;
    __block NSUInteger displayedIndex = NSNotFound;

    [[self tableView]
        performBatchUpdates:^{
          update = [[self dataStore] updateNote:note
                      forItemMatchingDictionary:dictionary
                             displayedItemIndex:&displayedIndex];
          if (displayedIndex == NSNotFound) {
              return;
          }

          NSIndexPath *indexPath = [NSIndexPath indexPathForRow:displayedIndex inSection:0];
          if (update == KayokoTableDataStoreDisplayedItemUpdateRemove) {
              [[self tableView] deleteRowsAtIndexPaths:@[ indexPath ]
                                      withRowAnimation:UITableViewRowAnimationAutomatic];
          } else if (update == KayokoTableDataStoreDisplayedItemUpdateReload) {
              [[self tableView] reloadRowsAtIndexPaths:@[ indexPath ] withRowAnimation:UITableViewRowAnimationNone];
          }
        }
        completion:^(__unused BOOL finished) {
          [self refreshVisibleItemDetails];
          [self refreshSearchPlaceholder];
          if (completion) {
              completion();
          }
        }];
}

- (nullable KayokoTableViewCell *)visibleCellForItem:(KayokoPasteboardItem *)item {
    if (!item) {
        return nil;
    }

    NSUInteger displayedIndex = [[self dataStore] indexOfItemMatchingDictionary:[item dictionaryRepresentation]
                                                                        inItems:[self displayedItems]];
    if (displayedIndex == NSNotFound) {
        return nil;
    }
    return (KayokoTableViewCell *)[[self tableView] cellForRowAtIndexPath:[NSIndexPath indexPathForRow:displayedIndex
                                                                                             inSection:0]];
}

- (KayokoTableViewCell *)presentationCellForItem:(KayokoPasteboardItem *)item {
    return [self newCellForItem:item addsPreviewGesture:NO];
}

- (void)setCellPresentationHidden:(BOOL)hidden forItem:(KayokoPasteboardItem *)item {
    NSString *content = [item content];
    if ([content length] == 0) {
        return;
    }

    if (hidden) {
        [self setPresentationHiddenItemContent:content];
    } else if ([[self presentationHiddenItemContent] isEqualToString:content]) {
        [self setPresentationHiddenItemContent:nil];
    } else {
        return;
    }

    KayokoHistoryListView *tableView = [self tableView];
    NSString *hiddenContent = [self presentationHiddenItemContent];
    for (NSIndexPath *indexPath in [tableView indexPathsForVisibleRows]) {
        NSDictionary<NSString *, id> *dictionary = [self itemDictionaryAtIndexPath:indexPath];
        BOOL hidesCell =
            [hiddenContent length] > 0 && [dictionary[kKayokoItemKeyContent] isEqualToString:hiddenContent];
        [[tableView cellForRowAtIndexPath:indexPath] setHidden:hidesCell];
    }
}

- (nullable KayokoTableViewCell *)scrollItemToVisible:(KayokoPasteboardItem *)item {
    if (!item) {
        return nil;
    }

    NSUInteger displayedIndex = [[self dataStore] indexOfItemMatchingDictionary:[item dictionaryRepresentation]
                                                                        inItems:[self displayedItems]];
    if (displayedIndex == NSNotFound) {
        return nil;
    }

    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:displayedIndex inSection:0];
    KayokoHistoryListView *tableView = [self tableView];
    [tableView layoutIfNeeded];
    KayokoTableViewCell *visibleCell = (KayokoTableViewCell *)[tableView cellForRowAtIndexPath:indexPath];
    if (visibleCell) {
        return visibleCell;
    }

    [tableView scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
    [tableView layoutIfNeeded];
    return (KayokoTableViewCell *)[tableView cellForRowAtIndexPath:indexPath];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (tableView != [self tableView]) {
        return 0;
    }
    return [[self displayedItems] count];
}

- (KayokoTableViewCell *)newCellForItem:(KayokoPasteboardItem *)item addsPreviewGesture:(BOOL)addsPreviewGesture {
    KayokoTableViewCellContent *content = [[self cellContentProvider] cellContentForItem:item
                                                                        previewLineCount:[self previewLineCount]
                                                                         itemDetailsMode:[self itemDetailsMode]
                                                                              searchText:[self searchText]];

    KayokoTableViewCell *cell =
        [[KayokoTableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                           content:content
                                   reuseIdentifier:[KayokoTableViewCell reuseIdentifierForContent:content]];
    [self loadThumbnailForItem:item intoCell:cell];

    if (addsPreviewGesture) {
        UILongPressGestureRecognizer *gesture =
            [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                          action:@selector(handleLongPressGestureRecognizer:)];
        [cell addGestureRecognizer:gesture];
    }
    return cell;
}

- (void)loadThumbnailForItem:(KayokoPasteboardItem *)item intoCell:(KayokoTableViewCell *)cell {
    NSString *imageName = [[item imageName] copy];
    if ([imageName length] == 0) {
        return;
    }

    __weak KayokoTableViewCell *weakCell = cell;
    [[self cellContentProvider] loadThumbnailForItem:item
                                          targetSize:[KayokoTableViewCell contentImageThumbnailSize]
                                          completion:^(UIImage *_Nullable image) {
                                            [weakCell setContentImage:image forImageName:imageName];
                                          }];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary<NSString *, id> *dictionary = [self itemDictionaryAtIndexPath:indexPath];
    KayokoPasteboardItem *item = [KayokoPasteboardItem itemFromDictionary:dictionary];
    KayokoTableViewCellContent *content = [[self cellContentProvider] cellContentForItem:item
                                                                        previewLineCount:[self previewLineCount]
                                                                         itemDetailsMode:[self itemDetailsMode]
                                                                              searchText:[self searchText]];
    NSString *reuseIdentifier = [KayokoTableViewCell reuseIdentifierForContent:content];
    KayokoTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseIdentifier];
    if (cell) {
        [cell applyContent:content];
    } else {
        cell = [[KayokoTableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                  content:content
                                          reuseIdentifier:reuseIdentifier];
        UILongPressGestureRecognizer *gesture =
            [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                          action:@selector(handleLongPressGestureRecognizer:)];
        [cell addGestureRecognizer:gesture];
    }
    [self loadThumbnailForItem:item intoCell:cell];
    [cell setHidden:[[self presentationHiddenItemContent] isEqualToString:[item content]]];
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView
      willDisplayCell:(UITableViewCell *)cell
    forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    NSDictionary<NSString *, id> *dictionary = [self itemDictionaryAtIndexPath:indexPath];
    NSString *hiddenContent = [self presentationHiddenItemContent];
    BOOL hidesCell = [hiddenContent length] > 0 && [dictionary[kKayokoItemKeyContent] isEqualToString:hiddenContent];
    [cell setHidden:hidesCell];
}

- (void)tableView:(UITableView *)tableView
    didEndDisplayingCell:(UITableViewCell *)cell
       forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    (void)indexPath;
    [cell setHidden:NO];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [[tableView cellForRowAtIndexPath:indexPath] setSelected:NO animated:YES];

    KayokoPasteboardItem *item = [KayokoPasteboardItem itemFromDictionary:[self itemDictionaryAtIndexPath:indexPath]];
    [[self actionHandler] activateItem:item
                            historyKey:[self historyKey]
                            completion:^(BOOL success) {
                              if (success) {
                                  if ([self automaticallyPaste]) {
                                      [[self delegate] historyListViewControllerDidRequestHideAfterDirectPaste:self];
                                  } else {
                                      [[self delegate] historyListViewControllerDidRequestHide:self];
                                  }
                              }
                            }];
}

- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView
                     withVelocity:(CGPoint)velocity
              targetContentOffset:(inout CGPoint *)targetContentOffset {
    (void)velocity;
    if (scrollView != [self tableView] || [self hasActiveSearch]) {
        return;
    }

    [[self tableView] adjustTargetContentOffsetForSearchBarSnap:targetContentOffset];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSMutableArray<UIContextualAction *> *actions = [[NSMutableArray alloc] init];
    NSDictionary<NSString *, id> *dictionary = [self itemDictionaryAtIndexPath:indexPath];
    KayokoPasteboardItem *item = [KayokoPasteboardItem itemFromDictionary:dictionary];

    UIContextualAction *moveAction = [self moveActionForItem:item dictionary:dictionary];
    if (moveAction) {
        [actions addObject:moveAction];
    }

    UIContextualAction *noteAction = [self noteActionForItem:item indexPath:indexPath];
    if (noteAction) {
        [actions addObject:noteAction];
    }

    UIContextualAction *faircopyAction = [self faircopyActionForItem:item];
    if (faircopyAction) {
        [actions addObject:faircopyAction];
    }

    UIContextualAction *saveAction = [self saveActionForItem:item];
    if (saveAction) {
        [actions addObject:saveAction];
    }

    UIContextualAction *linkAction = [self linkActionForItem:item];
    if (linkAction) {
        [actions addObject:linkAction];
    }

    return [UISwipeActionsConfiguration configurationWithActions:actions];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSMutableArray<UIContextualAction *> *actions = [[NSMutableArray alloc] init];
    NSDictionary<NSString *, id> *dictionary = [self itemDictionaryAtIndexPath:indexPath];
    KayokoPasteboardItem *item = [KayokoPasteboardItem itemFromDictionary:dictionary];

    UIContextualAction *deleteAction = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
                            title:@""
                          handler:^(__unused UIContextualAction *action, __unused __kindof UIView *sourceView,
                                    void (^completionHandler)(BOOL)) {
                            [[self actionHandler]
                                deleteItem:item
                                historyKey:[self historyKey]
                                completion:^(BOOL success) {
                                  if (!success) {
                                      completionHandler(NO);
                                      return;
                                  }
                                  [self removeItemDictionary:dictionary
                                                  completion:^(BOOL removed) {
                                                    if (removed) {
                                                        [[self delegate]
                                                            historyListViewControllerDidChangeContentState:self];
                                                    }
                                                    completionHandler(removed);
                                                  }];
                                }];
                          }];
    [deleteAction setImage:[UIImage systemImageNamed:@"trash.fill"]];
    [deleteAction setBackgroundColor:[UIColor systemRedColor]];
    // Delete goes first on purpose: on a trailing swipe the first action is the
    // one a full swipe lands on, and that has to stay delete.
    [actions addObject:deleteAction];

    UIContextualAction *floatAction = [self floatActionForItem:item];
    if (floatAction) {
        [actions addObject:floatAction];
    }

    return [UISwipeActionsConfiguration configurationWithActions:actions];
}

#pragma mark - Swipe Actions

- (UIContextualAction *)moveActionForItem:(KayokoPasteboardItem *)item
                               dictionary:(NSDictionary<NSString *, id> *)dictionary {
    NSString *sourceHistoryKey = [self historyKey];
    BOOL sourceIsFavorites = [sourceHistoryKey isEqualToString:kKayokoHistoryKeyFavorites];
    NSString *destinationHistoryKey = sourceIsFavorites ? kKayokoHistoryKeyHistory : kKayokoHistoryKeyFavorites;
    NSString *imageName = sourceIsFavorites ? @"heart.slash.fill" : @"heart.fill";

    UIContextualAction *moveAction = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
                            title:@""
                          handler:^(__unused UIContextualAction *action, __unused __kindof UIView *sourceView,
                                    void (^completionHandler)(BOOL)) {
                            [[self actionHandler]
                                             moveItem:item
                                     sourceHistoryKey:sourceHistoryKey
                                destinationHistoryKey:destinationHistoryKey
                                           completion:^(BOOL success) {
                                             if (!success) {
                                                 completionHandler(NO);
                                                 return;
                                             }
                                             [[self delegate] historyListViewController:self
                                                                  didMoveItemDictionary:dictionary
                                                                     fromHistoryWithKey:sourceHistoryKey
                                                                       toHistoryWithKey:destinationHistoryKey];
                                             [self removeItemDictionary:dictionary
                                                             completion:^(BOOL removed) {
                                                               if (removed) {
                                                                   [[self delegate]
                                                                       historyListViewControllerDidChangeContentState:
                                                                           self];
                                                               }
                                                               completionHandler(removed);
                                                             }];
                                           }];
                          }];
    [moveAction setImage:[UIImage systemImageNamed:imageName]];
    [moveAction setBackgroundColor:[UIColor systemPinkColor]];
    return moveAction;
}

- (UIContextualAction *)noteActionForItem:(KayokoPasteboardItem *)item indexPath:(NSIndexPath *)indexPath {
    UIContextualAction *noteAction = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:@""
                          handler:^(__unused UIContextualAction *action, __unused __kindof UIView *sourceView,
                                    void (^completionHandler)(BOOL)) {
                            KayokoTableViewCell *sourceCell =
                                (KayokoTableViewCell *)[[self tableView] cellForRowAtIndexPath:indexPath];
                            KayokoTableViewCell *presentationCell = [self newCellForItem:item addsPreviewGesture:NO];
                            completionHandler(YES);
                            dispatch_async(dispatch_get_main_queue(), ^{
                              [[self delegate] historyListViewController:self
                                               didRequestEditNoteForItem:item
                                                        presentationCell:presentationCell
                                                              sourceCell:sourceCell];
                            });
                          }];
    [noteAction setImage:[UIImage systemImageNamed:@"note.text"]];
    [noteAction setBackgroundColor:[UIColor systemOrangeColor]];
    return noteAction;
}

- (UIContextualAction *)saveActionForItem:(KayokoPasteboardItem *)item {
    if (![self automaticallyPaste] && [[item imageName] length] == 0) {
        return nil;
    }

    BOOL savesImage = [[item imageName] length] > 0;
    UIContextualAction *saveAction = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:@""
                          handler:^(__unused UIContextualAction *action, __unused __kindof UIView *sourceView,
                                    void (^completionHandler)(BOOL)) {
                            if (savesImage) {
                                [[self actionHandler] saveImageForItem:item completion:completionHandler];
                            } else {
                                [[self actionHandler] copyItem:item completion:completionHandler];
                            }
                          }];
    [saveAction setImage:[UIImage systemImageNamed:savesImage ? @"square.and.arrow.down.fill" : @"doc.on.doc.fill"]];
    [saveAction setBackgroundColor:[UIColor systemBlueColor]];
    return saveAction;
}

- (UIContextualAction *)linkActionForItem:(KayokoPasteboardItem *)item {
    if (![item hasLink]) {
        return nil;
    }

    UIContextualAction *linkAction = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:@""
                          handler:^(__unused UIContextualAction *action, __unused __kindof UIView *sourceView,
                                    void (^completionHandler)(BOOL)) {
                            [[self actionHandler] openLinkForItem:item completion:completionHandler];
                          }];
    [linkAction setImage:[UIImage systemImageNamed:@"arrow.up"]];
    [linkAction setBackgroundColor:[UIColor systemGreenColor]];
    return linkAction;
}

/// Reads the “Faircopy” swipe action preference straight from the shared
/// defaults suite. A fresh instance is used on purpose: SpringBoard outlives the
/// preferences pane, so anything cached at launch would go stale the moment the
/// switch is flipped.
- (BOOL)faircopyActionEnabled {
    NSUserDefaults *preferences = [[NSUserDefaults alloc] initWithSuiteName:kKayokoPreferencesIdentifier];
    [preferences registerDefaults:@{
        kKayokoPreferenceKeyFaircopyAction : @(kKayokoPreferenceKeyFaircopyActionDefaultValue),
    }];
    return [preferences boolForKey:kKayokoPreferenceKeyFaircopyAction];
}

- (nullable UIContextualAction *)faircopyActionForItem:(KayokoPasteboardItem *)item {
    if (![self faircopyActionEnabled]) {
        return nil;
    }

    NSString *content = [item content];
    NSString *imageName = [item imageName];
    BOOL isImage = [imageName length] > 0;
    if (!isImage && [content length] == 0) {
        return nil;
    }

    if (isImage) {
        // 4.3.15: a picture cannot be handed over as-is — Faircopy's keyword is
        // a string and 分词 has nothing to tokenize without words. Recognise the
        // text first, then send it with `mode=segment` so the panel opens on the
        // word chips instead of asking for one more tap.
        //
        // No availability probe here on purpose: asking the recogniser whether it
        // can run means `dlopen`-ing Vision, and this method is called while the
        // row is being revealed — a 30-80 ms framework load on SpringBoard's main
        // thread would show up as a stutter on the first swipe. Vision's text
        // recogniser exists on every supported iOS anyway; if it ever fails, the
        // press falls through to the "no text" pill.
        NSString *imagePath = [NSString
            stringWithFormat:@"%@/%@", [KayokoPasteboardManager historyImagesPath], imageName];
        UIContextualAction *imageAction = [UIContextualAction
            contextualActionWithStyle:UIContextualActionStyleNormal
                                title:@""
                              handler:^(__unused UIContextualAction *action,
                                        __unused __kindof UIView *sourceView,
                                        void (^completionHandler)(BOOL)) {
                                // Get the panel out of the way first: OCR takes a
                                // moment, and watching a frozen list while it runs
                                // is the thing that reads as a hang. The HUD goes
                                // up on the window behind it.
                                [[self delegate] historyListViewControllerDidRequestHide:self];
                                [self sendImageToFaircopyForSegmentation:imagePath];
                                if (completionHandler) {
                                    completionHandler(YES);
                                }
                              }];
        [imageAction setImage:[UIImage systemImageNamed:@"text.viewfinder"]];
        [imageAction setBackgroundColor:[UIColor colorWithRed:0.498
                                                        green:0.467
                                                         blue:0.867
                                                        alpha:1.0]];
        return imageAction;
    }

    UIContextualAction *faircopyAction = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:@""
                          handler:^(__unused UIContextualAction *action, __unused __kindof UIView *sourceView,
                                    void (^completionHandler)(BOOL)) {
                            KayokoSendTextToFaircopy(content, nil, kKayokoFaircopyKeywordLengthLimit);
                            // Kayoko gets out of the way; Faircopy's panel
                            // takes over the foreground.
                            [[self delegate] historyListViewControllerDidRequestHide:self];
                            if (completionHandler) {
                                completionHandler(YES);
                            }
                          }];
    // A wand reads as “let the model do something with this”, which the plain
    // sparkles glyph did not; the violet is light enough to stay distinct from
    // the pink, orange, blue and green actions sitting next to it in the row.
    [faircopyAction setImage:[UIImage systemImageNamed:@"wand.and.stars"]];
    [faircopyAction setBackgroundColor:[UIColor colorWithRed:0.498 green:0.467 blue:0.867 alpha:1.0]];
    return faircopyAction;
}

/// Hands a clipboard picture to AIGate, which recognises its text and comes back
/// with a `mode=segment` panel invocation.
///
/// Nothing here does recognition: see the note above
/// `KayokoPrepareFaircopyOCRHandoff` for why the network cannot run in this
/// process. What this side owns is the pill — it goes up before the hand-off,
/// and AIGate's answer takes it down, both when the panel is on its way and when
/// the picture simply had no text.
///
/// 4.3.24: two roads, silent first. `faircopy/ocr/request` asks the AIGate
/// process that is already alive to read the picture where it is — nothing is
/// brought to the front, so the list stays on screen and the panel arrives on
/// top of it. The visible `faircopy://ocr` road (one app switch) is only taken
/// when that request goes unanswered, or when AIGate answers `retry`.
- (void)sendImageToFaircopyForSegmentation:(NSString *)imagePath {
    [KayokoHUD showStatus:@"Reading text…"];
    if (!KayokoPrepareFaircopyOCRHandoff(imagePath)) {
        [KayokoHUD showTransientStatus:@"Cannot read this image"];
        return;
    }
    KayokoObserveFaircopyOCRResult();
    gKayokoFaircopyOCRHandoffPending = YES;
    gKayokoFaircopyOCRVisibleRoadIssued = NO;

    // 4.3.25: before anything is asked, leave AIGate the app the panel belongs
    // on. Without it the panel is addressed to SpringBoard and ends up under
    // the window the user is actually looking at.
    KayokoWriteFaircopyOCRDisplayTarget();

    // The picture is already in the drop box; the notification only says
    // "there is work". AIGate's process is woken by it without being shown.
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kKayokoFaircopyOCRRequestNotification,
                                         NULL, NULL, YES);

    // Silence means the request was not answered. 4.3.27: how long silence has
    // to last depends on whether the worker is there — see the constants above.
    const NSTimeInterval silentWait = KayokoFaircopyResidentWorkerIsAlive()
        ? kKayokoFaircopyOCRSilentWaitResident
        : kKayokoFaircopyOCRSilentWaitAbsent;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(silentWait * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     if (!gKayokoFaircopyOCRHandoffPending) {
                         return;
                     }
                     KayokoRunFaircopyOCRVisibleRoad();
                   });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kKayokoFaircopyOCRTimeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     if (!gKayokoFaircopyOCRHandoffPending) {
                         return;
                     }
                     gKayokoFaircopyOCRHandoffPending = NO;
                     [KayokoHUD hide];
                   });
}

/// The one-app-switch road, kept from 4.3.22/4.3.23: open `faircopy://ocr` so
/// AIGate comes to the front for the length of one recognition and bounces
/// back. Guarded, because a slow silent answer and the 2 s timeout can race.
static void KayokoRunFaircopyOCRVisibleRoad(void) {
    if (gKayokoFaircopyOCRVisibleRoadIssued) {
        return;
    }
    gKayokoFaircopyOCRVisibleRoadIssued = YES;

    // 4.3.23: name ourselves as the caller. This code runs inside SpringBoard
    // (see KayokoCore.plist), so `mainBundle` IS `com.apple.springboard` — the
    // same value iOS already reports as `sourceApplication`, which is why the
    // panel lands on the home screen either way. The item stays because a
    // caller living in the Kayoko app process would then bounce back to itself.
    NSString *caller = [NSBundle mainBundle].bundleIdentifier ?: @"";
    NSString *handoffURL = [kKayokoFaircopyOCRURLString stringByAppendingString:caller];
    NSURL *URL = [NSURL URLWithString:handoffURL];
    if (!URL) {
        // Cannot build the URL at all: fail like "not installed" rather than
        // opening nothing and leaving the pill spinning for 12 s.
        gKayokoFaircopyOCRHandoffPending = NO;
        [KayokoHUD showTransientStatus:@"Faircopy is not installed"];
        return;
    }
    // No `self` in either block on purpose: the list controller is gone by the
    // time any of this runs (the row's action dismisses the panel first), and a
    // weak-self bail-out would leave the pill on screen forever. Nothing here
    // needs the controller.
    [[UIApplication sharedApplication] openURL:URL
                                       options:@{}
                             completionHandler:^(BOOL success) {
                               if (success) {
                                   return;
                               }
                               dispatch_async(dispatch_get_main_queue(), ^{
                                 if (!gKayokoFaircopyOCRHandoffPending) {
                                     return;
                                 }
                                 gKayokoFaircopyOCRHandoffPending = NO;
                                 [KayokoHUD showTransientStatus:@"Faircopy is not installed"];
                                 UINotificationFeedbackGenerator *generator =
                                     [[UINotificationFeedbackGenerator alloc] init];
                                 [generator notificationOccurred:UINotificationFeedbackTypeError];
                               });
                             }];
}

/// The floating-image action, on the left swipe next to delete.
///
/// Unlike the other actions this one hides itself when no floating host is
/// installed, so the row never grows a dead button. Both images and text work:
/// text clips are rendered into a picture first (see KayokoFloatActionHandler).
- (nullable UIContextualAction *)floatActionForItem:(KayokoPasteboardItem *)item {
    if (![KayokoFloatActionHandler isAvailable]) {
        return nil;
    }

    if (![KayokoFloatActionHandler imageForItem:item]) {
        return nil;
    }

    UIContextualAction *floatAction = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:@""
                          handler:^(__unused UIContextualAction *action, __unused __kindof UIView *sourceView,
                                    void (^completionHandler)(BOOL)) {
                            [KayokoFloatActionHandler floatItem:item];
                            // The floating image is meant to stay while other
                            // apps are used, so Kayoko closes like the other
                            // hand-off actions do.
                            [[self delegate] historyListViewControllerDidRequestHide:self];
                            if (completionHandler) {
                                completionHandler(YES);
                            }
                          }];
    [floatAction setImage:[UIImage systemImageNamed:@"rectangle.on.rectangle"]];
    [floatAction setBackgroundColor:[UIColor systemTealColor]];
    return floatAction;
}

#pragma mark - Gestures

- (void)handleLongPressGestureRecognizer:(UILongPressGestureRecognizer *)recognizer {
    if ([recognizer state] != UIGestureRecognizerStateBegan) {
        return;
    }

    NSIndexPath *indexPath = [[self tableView] indexPathForCell:(UITableViewCell *)[recognizer view]];
    KayokoPasteboardItem *item = [KayokoPasteboardItem itemFromDictionary:[self itemDictionaryAtIndexPath:indexPath]];
    if (item) {
        [[self delegate] historyListViewController:self didRequestPreviewForItem:item];
    }
}

@end
