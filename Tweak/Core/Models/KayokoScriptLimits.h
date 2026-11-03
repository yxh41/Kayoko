//
//  KayokoScriptLimits.h
//  Kayoko
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The script executor enforces a few safety limits so a runaway or greedy script cannot hang the process or
/// flood memory. They used to be constants baked into the tool; this model lifts them into a plist both the
/// Settings app and the tweak can read, so the user can tune them without recompiling.
@interface KayokoScriptLimits : NSObject

/// Hard cutoff for a single run, in seconds. The executor also sets RLIMIT_CPU around it.
@property(nonatomic, assign) NSTimeInterval timeout;
/// Maximum number of strings a script may return.
@property(nonatomic, assign) NSUInteger maxResults;
/// Maximum length, in characters, of a single returned string.
@property(nonatomic, assign) NSUInteger maxResultLength;

+ (instancetype)defaultLimits;
+ (instancetype)limitsFromDictionary:(NSDictionary<NSString *, id> *)dictionary;
- (NSDictionary<NSString *, id> *)dictionaryRepresentation;

/// Derived cap on the combined length of all returned strings, kept proportional to `maxResultLength` so the
/// two knobs cannot be set at odds.
- (NSUInteger)maxTotalLength;

+ (NSString *)limitsPath;
/// Returns the stored limits, or `defaultLimits` when nothing valid is on disk yet.
+ (instancetype)loadLimits;
- (BOOL)saveLimits:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
