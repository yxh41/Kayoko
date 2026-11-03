//
//  KayokoScript.m
//  Kayoko
//

#import "KayokoScript.h"

#import "KayokoScriptResources.h"

NS_ASSUME_NONNULL_BEGIN

@implementation KayokoScript

+ (nullable instancetype)scriptFromDictionary:(nullable NSDictionary<NSString *, id> *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    id identifier = [dictionary objectForKey:kKayokoScriptKeyIdentifier];
    id code = [dictionary objectForKey:kKayokoScriptKeyCode];
    if (![identifier isKindOfClass:[NSString class]] || [identifier length] == 0) {
        return nil;
    }
    if (![code isKindOfClass:[NSString class]] || [code length] == 0) {
        return nil;
    }

    id name = [dictionary objectForKey:kKayokoScriptKeyName];
    id input = [dictionary objectForKey:kKayokoScriptKeyInput];
    id enabled = [dictionary objectForKey:kKayokoScriptKeyEnabled];

    KayokoScript *script = [[KayokoScript alloc] init];
    script->_identifier = [identifier copy];
    script->_name = [name isKindOfClass:[NSString class]] ? [name copy] : [identifier copy];
    script->_code = [code copy];
    script->_sampleInput = [input isKindOfClass:[NSString class]] ? [input copy] : @"";
    script->_enabled = [enabled isKindOfClass:[NSNumber class]] ? [enabled boolValue] : YES;

    return script;
}

- (nullable NSDictionary<NSString *, id> *)dictionaryRepresentation {
    if ([[self identifier] length] == 0 || [[self code] length] == 0) {
        return nil;
    }

    return @{
        kKayokoScriptKeyIdentifier : [self identifier],
        kKayokoScriptKeyName : [self name] ?: [self identifier],
        kKayokoScriptKeyCode : [self code],
        kKayokoScriptKeyInput : [self sampleInput] ?: @"",
        kKayokoScriptKeyEnabled : @([self isEnabled])
    };
}

- (NSString *)displayName {
    NSString *localized = KayokoScriptLocalizedString([self identifier], [self name]);
    if ([localized length] > 0) {
        return localized;
    }

    return [[self name] length] > 0 ? [self name] : [self identifier];
}

@end

NS_ASSUME_NONNULL_END
