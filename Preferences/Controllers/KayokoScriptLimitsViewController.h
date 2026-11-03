//
//  KayokoScriptLimitsViewController.h
//  Kayoko
//

#import <Preferences/PSViewController.h>

NS_ASSUME_NONNULL_BEGIN

/// Lets the user tune the safety limits the script executor enforces, instead of the values baked into the tool.
@interface KayokoScriptLimitsViewController : PSViewController

- (instancetype)initWithLocalizationBundle:(NSBundle *)localizationBundle;

@end

NS_ASSUME_NONNULL_END
