//
//  KayokoScriptFailure.m
//  Kayoko
//

#import "KayokoScriptFailure.h"

NS_ASSUME_NONNULL_BEGIN

@interface KayokoScriptFailure ()

@property(nonatomic, copy, readwrite) NSString *code;
@property(nonatomic, copy, readwrite) NSString *message;
@property(nonatomic, copy, readwrite) NSString *stage;
@property(nonatomic, assign, readwrite) NSInteger line;
@property(nonatomic, assign, readwrite) NSInteger column;
@property(nonatomic, copy, readwrite, nullable) NSString *sourceLine;
@property(nonatomic, copy, readwrite) NSDictionary<NSString *, id> *fields;
@property(nonatomic, copy, readwrite) NSArray<NSString *> *logs;

@end

@implementation KayokoScriptFailure

+ (instancetype)failureWithCode:(NSString *)code message:(nullable NSString *)message {
    return [self failureWithCode:code message:message fields:nil logs:nil];
}

+ (instancetype)failureWithCode:(NSString *)code
                        message:(nullable NSString *)message
                         fields:(nullable NSDictionary<NSString *, id> *)fields {
    return [self failureWithCode:code message:message fields:fields logs:nil];
}

+ (instancetype)failureWithCode:(NSString *)code
                        message:(nullable NSString *)message
                         fields:(nullable NSDictionary<NSString *, id> *)fields
                           logs:(nullable NSArray<NSString *> *)logs {
    KayokoScriptFailure *failure = [[self alloc] init];
    [failure setCode:[code length] > 0 ? code : @"failure"];
    [failure setMessage:[message length] > 0 ? message : @""];
    [failure setFields:fields ?: @{}];
    [failure setLogs:logs ?: @[]];

    // The executor reports these as ordinary payload keys, and the runner reports them for its own failures
    // through `fields`, so both sources land in the same properties.
    NSString *stage = [failure stringForKey:@"stage"];
    if ([stage length] > 0) {
        [failure setStage:stage];
    }
    [failure setLine:[[failure numberForKey:@"line"] integerValue]];
    [failure setColumn:[[failure numberForKey:@"column"] integerValue]];
    NSString *sourceLine = [failure stringForKey:@"source"];
    if ([sourceLine length] > 0) {
        [failure setSourceLine:sourceLine];
    }

    return failure;
}

+ (instancetype)failureWithResponse:(NSDictionary<NSString *, id> *)response
                               logs:(nullable NSArray<NSString *> *)logs {
    id rawCode = [response objectForKey:@"code"];
    id rawMessage = [response objectForKey:@"error"];

    return [self failureWithCode:([rawCode isKindOfClass:[NSString class]] ? rawCode : @"failure")
                         message:([rawMessage isKindOfClass:[NSString class]] ? rawMessage : @"")
                          fields:response
                            logs:logs];
}

- (NSString *)technicalSummary {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];

    NSMutableString *header = [[self code] mutableCopy];
    if ([[self stage] length] > 0) {
        [header appendFormat:@" · %@", [self stage]];
    }
    if ([self line] > 0) {
        [header appendFormat:@" · line %ld", (long)[self line]];
    }
    [lines addObject:header];

    if ([[self message] length] > 0) {
        [lines addObject:[self message]];
    }
    if ([[self sourceLine] length] > 0) {
        [lines addObject:[NSString stringWithFormat:@"> %@", [self sourceLine]]];
    }

    NSArray<NSString *> *logs = [self logs];
    if ([logs count] > 0) {
        [lines addObject:@""];
        [lines addObject:@"console:"];
        [lines addObjectsFromArray:logs];
    }

    return [lines componentsJoinedByString:@"\n"];
}

- (NSNumber *_Nullable)numberForKey:(NSString *)key {
    id value = [[self fields] objectForKey:key];
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

- (NSString *_Nullable)stringForKey:(NSString *)key {
    id value = [[self fields] objectForKey:key];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

@end

NS_ASSUME_NONNULL_END
