//
//  KayokoScriptPanelController.h
//  Kayoko
//

#import <UIKit/UIKit.h>

@class KayokoScriptPanelController;
@class KayokoScriptPanelView;

NS_ASSUME_NONNULL_BEGIN

@protocol KayokoScriptPanelControllerDelegate <NSObject>

- (void)scriptPanelControllerDidRequestBack:(KayokoScriptPanelController *)controller;
- (void)scriptPanelController:(KayokoScriptPanelController *)controller
         didRequestCopyText:(NSString *)text;
- (void)scriptPanelController:(KayokoScriptPanelController *)controller
        didRequestPasteText:(NSString *)text;
/// The script asked to open a link. `inApp` distinguishes `urlInApp` from `url`: the host shows an in-app browser
/// instead of leaving the app the panel was opened over.
- (void)scriptPanelController:(KayokoScriptPanelController *)controller
             didRequestOpenURL:(NSString *)urlString
                        inApp:(BOOL)inApp;
/// The script asked to open an app by bundle identifier.
- (void)scriptPanelController:(KayokoScriptPanelController *)controller
    didRequestOpenApplication:(NSString *)bundleIdentifier;
/// The script search wants the whole panel: the host grows it to full screen so the keyboard does not cover the
/// list, and shrinks it back when the search ends.
- (void)scriptPanelControllerDidBeginSearching:(KayokoScriptPanelController *)controller;
- (void)scriptPanelControllerDidEndSearching:(KayokoScriptPanelController *)controller;

@end

/// Drives the script picker: list → optional candidate picker → result. Everything runs out of process through
/// `KayokoScriptRunner`, so the panel only has to guard against results arriving after it moved on.
@interface KayokoScriptPanelController : UIViewController

@property(nonatomic, strong, readonly) KayokoScriptPanelView *panelView;
@property(nonatomic, weak, nullable) id<KayokoScriptPanelControllerDelegate> delegate;
@property(nonatomic, copy, nullable) void (^hapticFeedbackHandler)(UIImpactFeedbackStyle style);

/// `text` may be empty: a script that only works on the clipboard is a first-class case, so the panel runs it
/// with an empty input instead of refusing. `sourceBundleIdentifier` is passed through as `$env.bundleIdentifier`
/// and may be `nil` when the panel was not opened from a history item.
- (void)beginWithText:(NSString *)text sourceBundleIdentifier:(nullable NSString *)sourceBundleIdentifier;
- (void)resetState;

@end

NS_ASSUME_NONNULL_END
