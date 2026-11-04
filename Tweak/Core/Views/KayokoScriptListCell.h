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
/// Optional pill on the right edge. The candidate list uses it to say what tapping the row will do
/// ("copy" / "open") before the user commits to it.
@property(nonatomic, strong, readonly) UILabel *badgeLabel;

- (void)updateWithTitle:(NSString *)title
                  badge:(nullable NSString *)badge
      truncatesInMiddle:(BOOL)truncatesInMiddle;

@end

NS_ASSUME_NONNULL_END
