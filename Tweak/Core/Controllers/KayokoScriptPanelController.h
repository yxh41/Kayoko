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

@end

/// Drives the script picker: list → optional candidate picker → result. Everything runs out of process through
/// `KayokoScriptRunner`, so the panel only has to guard against results arriving after it moved on.
@interface KayokoScriptPanelController : UIViewController

@property(nonatomic, strong, readonly) KayokoScriptPanelView *panelView;
@property(nonatomic, weak, nullable) id<KayokoScriptPanelControllerDelegate> delegate;
@property(nonatomic, copy, nullable) void (^hapticFeedbackHandler)(UIImpactFeedbackStyle style);

- (void)beginWithText:(NSString *)text;
- (void)resetState;

@end

NS_ASSUME_NONNULL_END
