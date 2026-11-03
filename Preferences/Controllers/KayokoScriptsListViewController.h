//
//  KayokoScriptsListViewController.h
//  Kayoko
//

#import <Preferences/PSViewController.h>

NS_ASSUME_NONNULL_BEGIN

/// Settings-side manager for `scripts.plist`: enable, reorder, delete, create, import and open a script for
/// editing. The panel only ever consumes the file this page writes.
@interface KayokoScriptsListViewController : PSViewController
@end

NS_ASSUME_NONNULL_END
