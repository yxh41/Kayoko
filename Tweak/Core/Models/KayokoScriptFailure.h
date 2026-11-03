//
//  KayokoScriptFailure.h
//  Kayoko
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Everything the executor is able to say about a run that went wrong, in one place. Scripts are written by
/// the user and fail for ordinary reasons (a bad regular expression, a missing return), so the panel has to be
/// able to say which line, at which stage, and with what the script actually produced.
@interface KayokoScriptFailure : NSObject

/// Stable key: `exception`, `no-main`, `bad-result-type`, `too-many-results`, `result-too-large`,
/// `input-too-large`, `invalid-request`, `timeout`, `missing-executor`, `spawn-failed`, `runner-failed`.
@property(nonatomic, copy, readonly) NSString *code;
/// The executor's own sentence. English by design: it is the JavaScript engine's wording, not ours.
@property(nonatomic, copy, readonly) NSString *message;
/// `compile` when the source was rejected before running, `run` when main() threw, empty when unknown.
@property(nonatomic, copy, readonly) NSString *stage;
/// 1-based line in the script, 0 when the executor could not tell.
@property(nonatomic, assign, readonly) NSInteger line;
@property(nonatomic, assign, readonly) NSInteger column;
/// The offending source line, trimmed to something that fits on a page.
@property(nonatomic, copy, readonly, nullable) NSString *sourceLine;
/// Whatever numbers the executor attached: `limit`, `count`, `length`, `seconds`, `type`, `index`, `status`.
@property(nonatomic, copy, readonly) NSDictionary<NSString *, id> *fields;
/// console.log output, oldest first, already capped.
@property(nonatomic, copy, readonly) NSArray<NSString *> *logs;

+ (instancetype)failureWithCode:(NSString *)code message:(nullable NSString *)message;
+ (instancetype)failureWithCode:(NSString *)code
                        message:(nullable NSString *)message
                         fields:(nullable NSDictionary<NSString *, id> *)fields;
+ (instancetype)failureWithCode:(NSString *)code
                        message:(nullable NSString *)message
                         fields:(nullable NSDictionary<NSString *, id> *)fields
                           logs:(nullable NSArray<NSString *> *)logs;
/// Builds from the executor's failed payload (`{"error": ..., "code": ..., "line": ...}`).
+ (instancetype)failureWithResponse:(NSDictionary<NSString *, id> *)response
                               logs:(nullable NSArray<NSString *> *)logs;

- (nullable NSNumber *)numberForKey:(NSString *)key;
- (nullable NSString *)stringForKey:(NSString *)key;

/// Compact technical report used by the dry-run page in Settings: code, stage, line, the engine's own sentence,
/// the offending source line and whatever the script logged. Deliberately untranslated - a script author wants
/// the engine's wording, not ours.
- (NSString *)technicalSummary;

@end

NS_ASSUME_NONNULL_END
