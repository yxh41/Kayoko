//
//  KayokoScriptLimitsViewController.h
//  Kayoko
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Lets the user tune the safety limits the script executor enforces, instead of the values baked into the tool.
@interface KayokoScriptLimitsViewController : UIViewController

- (instancetype)initWithLocalizationBundle:(NSBundle *)localizationBundle;

@end

NS_ASSUME_NONNULL_END
