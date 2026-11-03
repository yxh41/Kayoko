//
//  KayokoScriptItem.h
//  Kayoko
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// What a script asked for. `Text` is the only type a v1 script could produce; everything else is an action the
/// host performs, which is why the panel has to route them differently instead of dumping them on the result page.
typedef NS_ENUM(NSUInteger, KayokoScriptItemType) {
    KayokoScriptItemTypeText = 0,
    KayokoScriptItemTypePasteboard,
    KayokoScriptItemTypeURL,
    KayokoScriptItemTypeURLInApp,
    KayokoScriptItemTypeApplication,
};

@interface KayokoScriptItem : NSObject

@property(nonatomic, assign, readonly) KayokoScriptItemType type;
/// Optional caption. Empty when the script did not name the item.
@property(nonatomic, copy, readonly) NSString *title;
@property(nonatomic, copy, readonly) NSString *content;

/// Parses one `kayoko_script` item. Returns nil for unknown types and for items without usable content; the
/// executor already rejected those, so nil here means the executor and this side disagree about the protocol.
+ (nullable instancetype)itemWithDictionary:(NSDictionary<NSString *, id> *)dictionary;
+ (instancetype)textItemWithContent:(NSString *)content;

/// `title` when the script gave one, otherwise the content cut down to a single readable line.
- (NSString *)displayTitle;
/// YES for every type the host has to perform an action for.
- (BOOL)isAction;

/// The executor emits these; kept here too so a mismatch shows up as an assertion in the verify script.
+ (nullable NSString *)typeIdentifierForType:(KayokoScriptItemType)type;
+ (KayokoScriptItemType)typeForIdentifier:(NSString *)identifier found:(BOOL *)found;

@end

NS_ASSUME_NONNULL_END
