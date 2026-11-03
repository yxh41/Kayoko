//
//  KayokoScriptEditorViewController.h
//  Kayoko
//

#import <Preferences/PSViewController.h>

@class KayokoScript;

NS_ASSUME_NONNULL_BEGIN

@interface KayokoScriptEditorViewController : PSViewController

/// `script` is always an existing script: new ones are created by the list page first, so the editor only ever
/// has to save an edit and never has to guess an identifier.
- (instancetype)initWithScript:(KayokoScript *)script
            localizationBundle:(NSBundle *)localizationBundle
           completionHandler:(void (^_Nullable)(KayokoScript *script))completionHandler;

@end

NS_ASSUME_NONNULL_END
