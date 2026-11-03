//
//  KayokoScriptStore.m
//  Kayoko
//

#import "KayokoScriptStore.h"

#import "KayokoScript.h"
#import "KayokoScriptResources.h"

#import <roothide.h>

static NSString *const kKayokoScriptStoreDataDirectoryPath = @"/var/mobile/Library/com.82flex.kayoko";
static NSString *const kKayokoScriptStoreFileName = @"scripts.plist";
static NSString *const kKayokoScriptStoreBundledResourceName = @"BundledScripts";

NS_ASSUME_NONNULL_BEGIN

@interface KayokoScriptStore ()

@property(nonatomic, copy, nullable) NSArray<KayokoScript *> *cachedScripts;

- (NSArray<KayokoScript *> *)loadScripts;
- (nullable NSArray<NSDictionary<NSString *, id> *> *)dictionaryArrayAtPath:(NSString *)path;
- (nullable NSArray<NSDictionary<NSString *, id> *> *)bundledScriptDictionaries;
- (BOOL)persistScriptDictionaries:(NSArray<NSDictionary<NSString *, id> *> *)dictionaries
                            error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END

@implementation KayokoScriptStore

+ (NSString *)scriptsPath {
    return [jbroot(kKayokoScriptStoreDataDirectoryPath) stringByAppendingPathComponent:kKayokoScriptStoreFileName];
}

#pragma mark - Reading

- (NSArray<KayokoScript *> *)allScripts {
    NSArray<KayokoScript *> *scripts = [self cachedScripts];
    if (!scripts) {
        scripts = [self loadScripts];
        [self setCachedScripts:scripts];
    }

    return scripts;
}

- (NSArray<KayokoScript *> *)enabledScripts {
    NSMutableArray<KayokoScript *> *scripts = [NSMutableArray array];
    for (KayokoScript *script in [self allScripts]) {
        if ([script isEnabled]) {
            [scripts addObject:script];
        }
    }

    return scripts;
}

- (void)reload {
    [self setCachedScripts:nil];
}

- (NSArray<KayokoScript *> *)loadScripts {
    NSArray<NSDictionary<NSString *, id> *> *bundled = [self bundledScriptDictionaries] ?: @[];
    NSArray<NSDictionary<NSString *, id> *> *stored = [self dictionaryArrayAtPath:[[self class] scriptsPath]];

    if (!stored) {
        [self persistScriptDictionaries:bundled error:nil];
        stored = bundled;
    } else {
        NSMutableArray<NSDictionary<NSString *, id> *> *merged = [stored mutableCopy];
        NSMutableSet<NSString *> *knownIdentifiers = [NSMutableSet set];
        for (NSDictionary<NSString *, id> *dictionary in stored) {
            id identifier = [dictionary objectForKey:kKayokoScriptKeyIdentifier];
            if ([identifier isKindOfClass:[NSString class]]) {
                [knownIdentifiers addObject:identifier];
            }
        }
        BOOL didAppendBundledScript = NO;
        for (NSDictionary<NSString *, id> *dictionary in bundled) {
            id identifier = [dictionary objectForKey:kKayokoScriptKeyIdentifier];
            if (![identifier isKindOfClass:[NSString class]] || [knownIdentifiers containsObject:identifier]) {
                continue;
            }
            [merged addObject:dictionary];
            didAppendBundledScript = YES;
        }
        if (didAppendBundledScript) {
            [self persistScriptDictionaries:merged error:nil];
            stored = merged;
        }
    }

    NSMutableArray<KayokoScript *> *scripts = [NSMutableArray arrayWithCapacity:[stored count]];
    for (NSDictionary<NSString *, id> *dictionary in stored) {
        KayokoScript *script = [KayokoScript scriptFromDictionary:dictionary];
        if (script) {
            [scripts addObject:script];
        }
    }

    return scripts;
}

- (nullable NSArray<NSDictionary<NSString *, id> *> *)dictionaryArrayAtPath:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if ([data length] == 0) {
        return nil;
    }

    id propertyList = [NSPropertyListSerialization propertyListWithData:data
                                                               options:NSPropertyListImmutable
                                                                format:NULL
                                                                 error:NULL];
    if (![propertyList isKindOfClass:[NSArray class]]) {
        return nil;
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *dictionaries = [NSMutableArray array];
    for (id entry in (NSArray *)propertyList) {
        if ([entry isKindOfClass:[NSDictionary class]]) {
            [dictionaries addObject:entry];
        }
    }

    return dictionaries;
}

- (nullable NSArray<NSDictionary<NSString *, id> *> *)bundledScriptDictionaries {
    NSBundle *bundle = KayokoScriptResourcesBundle();
    NSString *path = [bundle pathForResource:kKayokoScriptStoreBundledResourceName ofType:@"plist"];
    if ([path length] == 0) {
        return nil;
    }

    return [self dictionaryArrayAtPath:path];
}

#pragma mark - Writing

- (BOOL)saveScripts:(NSArray<KayokoScript *> *)scripts error:(NSError *_Nullable *_Nullable)error {
    NSMutableArray<NSDictionary<NSString *, id> *> *dictionaries = [NSMutableArray arrayWithCapacity:[scripts count]];
    for (KayokoScript *script in scripts) {
        NSDictionary<NSString *, id> *dictionary = [script dictionaryRepresentation];
        if (dictionary) {
            [dictionaries addObject:dictionary];
        }
    }

    BOOL success = [self persistScriptDictionaries:dictionaries error:error];
    if (success) {
        [self setCachedScripts:nil];
    }

    return success;
}

- (BOOL)persistScriptDictionaries:(NSArray<NSDictionary<NSString *, id> *> *)dictionaries
                            error:(NSError *_Nullable *_Nullable)error {
    NSString *directoryPath = jbroot(kKayokoScriptStoreDataDirectoryPath);
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

    // Keep the file readable and hand-editable: it is the only way to add a script before the editor exists.
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:dictionaries
                                                             format:NSPropertyListXMLFormat_v1_0
                                                            options:0
                                                              error:error];
    if (!data) {
        return NO;
    }

    return [data writeToFile:[[self class] scriptsPath] options:NSDataWritingAtomic error:error];
}

@end
