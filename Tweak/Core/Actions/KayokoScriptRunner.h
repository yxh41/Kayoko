//
//  KayokoScriptRunner.h
//  Kayoko
//

#import <Foundation/Foundation.h>

@class KayokoScript;
@class KayokoScriptFailure;

NS_ASSUME_NONNULL_BEGIN

typedef void (^KayokoScriptRunnerCompletion)(NSArray<NSString *> *_Nullable results,
                                             KayokoScriptFailure *_Nullable failure);

/// Runs `kayoko_script` out of process. JavaScriptCore has no interrupt API, so a hung script can only be
/// stopped by killing its process, which means the runner must never evaluate user code in-process.
@interface KayokoScriptRunner : NSObject

/// Resolved `kayoko_script` path, honouring bootstrap, rootless and rootful layouts.
+ (nullable NSString *)executorPath;

- (void)runScript:(KayokoScript *)script
            input:(NSString *)input
       completion:(KayokoScriptRunnerCompletion)completion;

@end

NS_ASSUME_NONNULL_END
