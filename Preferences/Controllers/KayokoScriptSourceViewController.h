//
//  KayokoScriptSourceViewController.h
//  Kayoko
//

#import <UIKit/UIKit.h>

@class KayokoScript;

NS_ASSUME_NONNULL_BEGIN

/// Read-only view of a script's source, reached by long-pressing a row in the settings list. Editing lives in the
/// editor; this is purely so a user can eyeball the code without opening the full editor and risking a stray edit.
@interface KayokoScriptSourceViewController : UIViewController

- (instancetype)initWithScript:(KayokoScript *)script localizationBundle:(NSBundle *)localizationBundle;

@end

NS_ASSUME_NONNULL_END
