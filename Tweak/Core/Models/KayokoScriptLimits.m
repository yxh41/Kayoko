//
//  KayokoScriptLimits.m
//  Kayoko
//

#import "KayokoScriptLimits.h"

#import <roothide.h>

static NSString *const kKayokoScriptLimitsDataDirectoryPath = @"/var/mobile/Library/com.82flex.kayoko";
static NSString *const kKayokoScriptLimitsFileName = @"script_limits.plist";

static NSString *const kKayokoScriptLimitsTimeoutKey = @"timeout";
static NSString *const kKayokoScriptLimitsMaxResultsKey = @"maxResults";
static NSString *const kKayokoScriptLimitsMaxResultLengthKey = @"maxResultLength";

static NSTimeInterval const kKayokoScriptLimitsMinimumTimeout = 1.0;
static NSTimeInterval const kKayokoScriptLimitsMaximumTimeout = 30.0;
static NSUInteger const kKayokoScriptLimitsMinimumResults = 1;
static NSUInteger const kKayokoScriptLimitsMaximumResults = 2000;
static NSUInteger const kKayokoScriptLimitsMinimumResultLength = 1000;
static NSUInteger const kKayokoScriptLimitsMaximumResultLength = 500000;

@implementation KayokoScriptLimits

+ (instancetype)defaultLimits {
    KayokoScriptLimits *limits = [[self alloc] init];
    [limits setTimeout:5.0];
    [limits setMaxResults:100];
    [limits setMaxResultLength:50000];
    return limits;
}

+ (instancetype)limitsFromDictionary:(NSDictionary<NSString *, id> *)dictionary {
    KayokoScriptLimits *limits = [self defaultLimits];
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return limits;
    }

    id timeout = [dictionary objectForKey:kKayokoScriptLimitsTimeoutKey];
    if ([timeout isKindOfClass:[NSNumber class]]) {
        [limits setTimeout:MIN(MAX([timeout doubleValue], kKayokoScriptLimitsMinimumTimeout),
                               kKayokoScriptLimitsMaximumTimeout)];
    }

    id maxResults = [dictionary objectForKey:kKayokoScriptLimitsMaxResultsKey];
    if ([maxResults isKindOfClass:[NSNumber class]]) {
        [limits setMaxResults:(NSUInteger)MIN(MAX([maxResults unsignedIntegerValue],
                                                  kKayokoScriptLimitsMinimumResults),
                                             kKayokoScriptLimitsMaximumResults)];
    }

    id maxResultLength = [dictionary objectForKey:kKayokoScriptLimitsMaxResultLengthKey];
    if ([maxResultLength isKindOfClass:[NSNumber class]]) {
        [limits setMaxResultLength:(NSUInteger)MIN(MAX([maxResultLength unsignedIntegerValue],
                                                       kKayokoScriptLimitsMinimumResultLength),
                                                  kKayokoScriptLimitsMaximumResultLength)];
    }

    return limits;
}

- (NSDictionary<NSString *, id> *)dictionaryRepresentation {
    return @{
        kKayokoScriptLimitsTimeoutKey : @([self timeout]),
        kKayokoScriptLimitsMaxResultsKey : @([self maxResults]),
        kKayokoScriptLimitsMaxResultLengthKey : @([self maxResultLength]),
    };
}

- (NSUInteger)maxTotalLength {
    // Four times a single result keeps a long list from being silently capped at a number unrelated to the UI.
    NSUInteger derived = [self maxResultLength] * 4;
    return MIN(derived, kKayokoScriptLimitsMaximumResultLength * 4);
}

+ (NSString *)limitsPath {
    return [jbroot(kKayokoScriptLimitsDataDirectoryPath) stringByAppendingPathComponent:kKayokoScriptLimitsFileName];
}

+ (instancetype)loadLimits {
    NSString *path = [self limitsPath];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if ([data length] == 0) {
        return [self defaultLimits];
    }

    id propertyList = [NSPropertyListSerialization propertyListWithData:data
                                                               options:NSPropertyListImmutable
                                                                format:NULL
                                                                 error:NULL];
    if (![propertyList isKindOfClass:[NSDictionary class]]) {
        return [self defaultLimits];
    }

    return [self limitsFromDictionary:propertyList];
}

- (BOOL)saveLimits:(NSError *_Nullable *_Nullable)error {
    NSString *directoryPath = jbroot(kKayokoScriptLimitsDataDirectoryPath);
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:directoryPath]) {
        NSError *directoryError = nil;
        if (![fileManager createDirectoryAtPath:directoryPath
                    withIntermediateDirectories:YES
                                     attributes:nil
                                          error:&directoryError]) {
            if (error) {
                *error = directoryError;
            }
            return NO;
        }
    }

    NSData *data = [NSPropertyListSerialization dataWithPropertyList:[self dictionaryRepresentation]
                                                             format:NSPropertyListXMLFormat_v1_0
                                                            options:0
                                                              error:error];
    if (!data) {
        return NO;
    }

    return [data writeToFile:[[self class] limitsPath] options:NSDataWritingAtomic error:error];
}

@end
