//
//  KayokoTextRecognizer.h
//  Kayoko
//
//  Recognises the text inside a clipboard picture, so the swipe action can hand
//  real text to Faircopy's 分词 instead of an image it cannot read.
//
//  4.3.22: NOT CALLED ANY MORE. Vision's accurate text network does not run in
//  SpringBoard — every `.accurate` pass fails with `Error computing NN outputs`
//  on the same handler and the same picture that a `.fast` pass reads fine — so
//  the recognition moved into AIGate's own process (`faircopy://ocr`, see
//  KayokoHistoryListViewController's picture hand-off). This class stays in the
//  build for two reasons: its pass-by-pass probe is the only written record of
//  how that was narrowed down (supported-language tables, per-pass error text,
//  image variants, revisions), and it is the thing to re-enable if a future iOS
//  lets the accurate engine run here.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface KayokoTextRecognizer : NSObject

/// YES when the on-device recogniser can be used. Vision is loaded lazily on
/// first use, so this is cheap to call (and answers NO on a system without it).
+ (BOOL)isAvailable;

/// Recognises text in the picture at `path` on a background queue and calls
/// `completion` on the main queue.
///
/// `text` is nil when nothing was recognised. Callers must NOT open Faircopy in
/// that case — an empty panel with no words to tokenize reads as "the button is
/// broken" rather than "this picture has no text".
+ (void)recognizeTextInImageAtPath:(NSString *)path
                        completion:(void (^)(NSString *_Nullable text))completion;

@end

NS_ASSUME_NONNULL_END
