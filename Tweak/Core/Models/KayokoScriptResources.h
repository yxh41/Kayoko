//
//  KayokoScriptResources.h
//  Kayoko
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The preference bundle carries the script localisation table and the bundled defaults, and it is the one
/// bundle both processes can reach: SpringBoard through the jailbreak root, the Settings app through the very
/// same path. Resolving it here keeps the script model free of any dependency on the pasteboard manager, so
/// the Settings bundle can compile it without dragging the whole tweak in.
FOUNDATION_EXPORT NSBundle *KayokoScriptResourcesBundle(void);

/// Looks a key up in Tweak.strings. `fallback` is returned verbatim when the table has nothing, so a missing
/// translation degrades to English instead of an empty or raw key.
FOUNDATION_EXPORT NSString *KayokoScriptLocalizedString(NSString *key, NSString *fallback);

NS_ASSUME_NONNULL_END
