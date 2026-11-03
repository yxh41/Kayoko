//
//  KayokoHeaderView.h
//  Kayoko
//

#import <UIKit/UIKit.h>

@class KayokoGrabberView;

NS_ASSUME_NONNULL_BEGIN

static CGFloat const kKayokoHeaderContentSpacing = 8;

@interface KayokoHeaderView : UIView

@property(nonatomic, strong, readonly) KayokoGrabberView *grabber;
@property(nonatomic, strong, readonly) UILabel *titleLabel;
@property(nonatomic, strong, readonly) UIControl *titleTapControl;
@property(nonatomic, strong, readonly) UIButton *leadingButton;
@property(nonatomic, strong, readonly) UIButton *trailingButton;
@property(nonatomic, strong, readonly) UIButton *alternateTrailingButton;
/// Third trailing slot, left of the alternate one. Hidden unless a content view opts in, so panels that
/// only use the two original slots keep their exact layout.
@property(nonatomic, strong, readonly) UIButton *scriptButton;
@property(nonatomic, assign) CGFloat grabberFoldProgress;

+ (CGFloat)preferredHeight;
- (instancetype)initWithTitle:(NSString *)title NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(CGRect)frame NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
- (void)setTitleText:(NSString *)title;
- (void)updateStyleForButton:(UIButton *)button
               withImageName:(NSString *)imageName
                   imageSize:(NSUInteger)imageSize
                   tintColor:(UIColor *)color;

@end

NS_ASSUME_NONNULL_END
