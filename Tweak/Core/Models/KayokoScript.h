//
//  KayokoScript.h
//  Kayoko
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

static NSString *const kKayokoScriptKeyIdentifier = @"id";
static NSString *const kKayokoScriptKeyName = @"name";
static NSString *const kKayokoScriptKeyCode = @"code";
static NSString *const kKayokoScriptKeyInput = @"input";
static NSString *const kKayokoScriptKeyEnabled = @"enabled";

/// A single text transformation. The source of truth is `scripts.plist`, which is seeded from the bundled
/// defaults on first launch.
@interface KayokoScript : NSObject

@property(nonatomic, copy, readonly) NSString *identifier;
@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, copy, readonly) NSString *code;
@property(nonatomic, copy, readonly) NSString *sampleInput;
@property(nonatomic, assign, readonly, getter=isEnabled) BOOL enabled;

+ (nullable instancetype)scriptFromDictionary:(nullable NSDictionary<NSString *, id> *)dictionary;
- (nullable NSDictionary<NSString *, id> *)dictionaryRepresentation;

/// Localized name when a translation exists for the script identifier, otherwise the stored name.
- (NSString *)displayName;

@end

NS_ASSUME_NONNULL_END
