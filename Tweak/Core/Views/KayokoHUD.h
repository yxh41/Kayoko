//
//  KayokoHUD.h
//  Kayoko
//
//  A very small status pill. Exists because the picture → OCR hand-off takes a
//  moment inside SpringBoard, and "nothing happened for a second" reads as a
//  broken button.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface KayokoHUD : NSObject

/// Shows a pill with a spinner on the key window. Stays until `hide` is called.
+ (void)showStatus:(NSString *)status;

/// Replaces any visible pill with a short message that fades by itself.
+ (void)showTransientStatus:(NSString *)status;

/// Fades the current pill out.
+ (void)hide;

@end

NS_ASSUME_NONNULL_END
