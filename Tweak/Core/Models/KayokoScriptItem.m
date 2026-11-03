//
//  KayokoScriptItem.m
//  Kayoko
//

#import "KayokoScriptItem.h"

static NSString *const kKayokoScriptItemTypeTextIdentifier = @"txt";
static NSString *const kKayokoScriptItemTypePasteboardIdentifier = @"pb";
static NSString *const kKayokoScriptItemTypeURLIdentifier = @"url";
static NSString *const kKayokoScriptItemTypeURLInAppIdentifier = @"urlInApp";
static NSString *const kKayokoScriptItemTypeApplicationIdentifier = @"app";

static NSString *const kKayokoScriptItemKeyType = @"type";
static NSString *const kKayokoScriptItemKeyTitle = @"title";
static NSString *const kKayokoScriptItemKeyContent = @"content";

static NSUInteger const kKayokoScriptItemDisplayTitleMaximumLength = 120;

NS_ASSUME_NONNULL_BEGIN

@interface KayokoScriptItem ()

@property(nonatomic, assign, readwrite) KayokoScriptItemType type;
@property(nonatomic, copy, readwrite) NSString *title;
@property(nonatomic, copy, readwrite) NSString *content;

@end

NS_ASSUME_NONNULL_END

@implementation KayokoScriptItem

#pragma mark - Lifecycle

+ (instancetype)textItemWithContent:(NSString *)content {
    KayokoScriptItem *item = [[self alloc] init];
    [item setType:KayokoScriptItemTypeText];
    [item setTitle:@""];
    [item setContent:content ?: @""];
    return item;
}

+ (nullable instancetype)itemWithDictionary:(NSDictionary<NSString *, id> *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    id rawType = [dictionary objectForKey:kKayokoScriptItemKeyType];
    if (![rawType isKindOfClass:[NSString class]] || [rawType length] == 0) {
        return nil;
    }

    BOOL found = NO;
    KayokoScriptItemType type = [[self class] typeForIdentifier:rawType found:&found];
    if (!found) {
        return nil;
    }

    id rawContent = [dictionary objectForKey:kKayokoScriptItemKeyContent];
    if (![rawContent isKindOfClass:[NSString class]] || [rawContent length] == 0) {
        return nil;
    }

    id rawTitle = [dictionary objectForKey:kKayokoScriptItemKeyTitle];
    NSString *title = [rawTitle isKindOfClass:[NSString class]] ? rawTitle : @"";

    KayokoScriptItem *item = [[self alloc] init];
    [item setType:type];
    [item setTitle:title];
    [item setContent:rawContent];
    return item;
}

#pragma mark - Type Mapping

+ (nullable NSString *)typeIdentifierForType:(KayokoScriptItemType)type {
    switch (type) {
    case KayokoScriptItemTypeText:
        return kKayokoScriptItemTypeTextIdentifier;
    case KayokoScriptItemTypePasteboard:
        return kKayokoScriptItemTypePasteboardIdentifier;
    case KayokoScriptItemTypeURL:
        return kKayokoScriptItemTypeURLIdentifier;
    case KayokoScriptItemTypeURLInApp:
        return kKayokoScriptItemTypeURLInAppIdentifier;
    case KayokoScriptItemTypeApplication:
        return kKayokoScriptItemTypeApplicationIdentifier;
    }

    return nil;
}

+ (KayokoScriptItemType)typeForIdentifier:(NSString *)identifier found:(BOOL *)found {
    if (found) {
        *found = YES;
    }

    if ([identifier isEqualToString:kKayokoScriptItemTypeTextIdentifier]) {
        return KayokoScriptItemTypeText;
    }
    if ([identifier isEqualToString:kKayokoScriptItemTypePasteboardIdentifier]) {
        return KayokoScriptItemTypePasteboard;
    }
    if ([identifier isEqualToString:kKayokoScriptItemTypeURLIdentifier]) {
        return KayokoScriptItemTypeURL;
    }
    if ([identifier isEqualToString:kKayokoScriptItemTypeURLInAppIdentifier]) {
        return KayokoScriptItemTypeURLInApp;
    }
    if ([identifier isEqualToString:kKayokoScriptItemTypeApplicationIdentifier]) {
        return KayokoScriptItemTypeApplication;
    }

    if (found) {
        *found = NO;
    }
    return KayokoScriptItemTypeText;
}

#pragma mark - Display

- (NSString *)displayTitle {
    if ([[self title] length] > 0) {
        return [self title];
    }

    NSString *content = [self content];
    if ([content length] <= kKayokoScriptItemDisplayTitleMaximumLength) {
        return content;
    }

    return [[content substringToIndex:kKayokoScriptItemDisplayTitleMaximumLength] stringByAppendingString:@"…"];
}

- (BOOL)isAction {
    return [self type] != KayokoScriptItemTypeText;
}

@end
