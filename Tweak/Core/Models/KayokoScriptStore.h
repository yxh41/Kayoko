//
//  KayokoScriptStore.h
//  Kayoko
//

#import <Foundation/Foundation.h>

@class KayokoScript;

NS_ASSUME_NONNULL_BEGIN

/// Reads and seeds `scripts.plist`. The bundled defaults only ever add scripts that are missing, so a user
/// file that was edited by hand keeps its own order, code and enabled state across updates.
@interface KayokoScriptStore : NSObject

+ (NSString *)scriptsPath;

- (NSArray<KayokoScript *> *)allScripts;
- (NSArray<KayokoScript *> *)enabledScripts;
- (void)reload;

- (BOOL)saveScripts:(NSArray<KayokoScript *> *)scripts error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
