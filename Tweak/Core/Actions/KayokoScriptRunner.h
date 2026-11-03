//
//  KayokoScriptRunner.h
//  Kayoko
//

#import <Foundation/Foundation.h>

@class KayokoScript;
@class KayokoScriptFailure;
@class KayokoScriptItem;

NS_ASSUME_NONNULL_BEGIN

typedef void (^KayokoScriptRunnerCompletion)(NSArray<KayokoScriptItem *> *_Nullable items,
                                             KayokoScriptFailure *_Nullable failure);

/// Runs `kayoko_script` out of process. JavaScriptCore has no interrupt API, so a hung script can only be
/// stopped by killing its process, which means the runner must never evaluate user code in-process.
@interface KayokoScriptRunner : NSObject

/// Resolved `kayoko_script` path, honouring bootstrap, rootless and rootful layouts.
+ (nullable NSString *)executorPath;

/// `clipboardText` is pre-read and shipped inside the request, because the executor reads stdin exactly once:
/// a script that asks the host for the clipboard mid-run would need a second channel it does not have.
- (void)runScript:(KayokoScript *)script
            input:(NSString *)input
    clipboardText:(nullable NSString *)clipboardText
       completion:(KayokoScriptRunnerCompletion)completion;

@end

NS_ASSUME_NONNULL_END
