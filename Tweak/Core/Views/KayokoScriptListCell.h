//
//  KayokoScriptListCell.h
//  Kayoko
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// One row of the script list or the candidate list. Text only, because both lists are plain sequences of
/// strings the user picks from.
@interface KayokoScriptListCell : UITableViewCell

@property(nonatomic, strong, readonly) UILabel *titleLabel;

- (void)updateWithTitle:(NSString *)title truncatesInMiddle:(BOOL)truncatesInMiddle;

@end

NS_ASSUME_NONNULL_END
