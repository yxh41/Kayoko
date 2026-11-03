//
//  KayokoHUD.m
//  Kayoko
//

#import "KayokoHUD.h"

#import <QuartzCore/QuartzCore.h>

static const NSTimeInterval kKayokoHUDFadeDuration = 0.16;
static const NSTimeInterval kKayokoHUDTransientDuration = 1.2;
static const CGFloat kKayokoHUDHorizontalPadding = 18.0;
static const CGFloat kKayokoHUDVerticalPadding = 14.0;
static const CGFloat kKayokoHUDSpinnerSpacing = 10.0;

/// The pill currently on screen, if any. Held strongly on purpose: it is a
/// transient piece of UI owned by no controller, and SpringBoard's window does
/// not keep a reference a caller could reach.
static UIView *kKayokoHUDContainer = nil;

/// Bumped on every show/hide. A delayed hide from an earlier request compares
/// against this and does nothing, so a "no text found" pill cannot be dismissed
/// by the timer that belonged to the spinner before it.
static NSUInteger kKayokoHUDGeneration = 0;

/// Private helpers, declared up front so `showStatus:` can call methods that are
/// textually defined below it.
@interface KayokoHUD ()
+ (void)presentStatus:(NSString *)status transient:(BOOL)transient;
+ (void)fadeOutCurrentPill;
+ (nullable UIWindow *)hostWindow;
@end

@implementation KayokoHUD

+ (void)showStatus:(NSString *)status {
    [self presentStatus:status transient:NO];
}

+ (void)showTransientStatus:(NSString *)status {
    [self presentStatus:status transient:YES];
}

+ (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
      kKayokoHUDGeneration += 1;
      [self fadeOutCurrentPill];
    });
}

#pragma mark - Presentation

+ (void)presentStatus:(NSString *)status transient:(BOOL)transient {
    NSString *text = [status copy];
    dispatch_async(dispatch_get_main_queue(), ^{
      kKayokoHUDGeneration += 1;
      NSUInteger generation = kKayokoHUDGeneration;

      // Replace, never stack: the OCR pill and a follow-up message are the same
      // slot in the user's attention.
      [kKayokoHUDContainer removeFromSuperview];
      kKayokoHUDContainer = nil;

      UIWindow *window = [self hostWindow];
      if (!window || text.length == 0) {
          return;
      }

      UIView *container = [[UIView alloc] init];
      container.translatesAutoresizingMaskIntoConstraints = NO;
      container.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.78];
      container.layer.cornerRadius = 14.0;
      container.layer.cornerCurve = kCACornerCurveContinuous;
      container.alpha = 0.0;
      container.userInteractionEnabled = NO;

      UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
          initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
      spinner.translatesAutoresizingMaskIntoConstraints = NO;
      spinner.color = [UIColor whiteColor];
      [spinner startAnimating];

      UILabel *label = [[UILabel alloc] init];
      label.translatesAutoresizingMaskIntoConstraints = NO;
      label.text = text;
      label.textColor = [UIColor whiteColor];
      label.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
      label.numberOfLines = 0;
      label.textAlignment = NSTextAlignmentCenter;

      UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ spinner, label ]];
      stack.translatesAutoresizingMaskIntoConstraints = NO;
      stack.axis = UILayoutConstraintAxisHorizontal;
      stack.alignment = UIStackViewAlignmentCenter;
      stack.spacing = kKayokoHUDSpinnerSpacing;

      [container addSubview:stack];
      [window addSubview:container];

      [NSLayoutConstraint activateConstraints:@[
          [container.centerXAnchor constraintEqualToAnchor:window.centerXAnchor],
          // Above the vertical centre: the panel owns the lower half of the screen, and a pill down there read
          // as part of the list it was reporting on.
          [container.centerYAnchor constraintEqualToAnchor:window.centerYAnchor constant:-60.0],
          [container.widthAnchor constraintLessThanOrEqualToAnchor:window.widthAnchor constant:-80.0],
          [stack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor
                                             constant:kKayokoHUDHorizontalPadding],
          [stack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor
                                              constant:-kKayokoHUDHorizontalPadding],
          [stack.topAnchor constraintEqualToAnchor:container.topAnchor
                                          constant:kKayokoHUDVerticalPadding],
          [stack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor
                                             constant:-kKayokoHUDVerticalPadding],
      ]];

      kKayokoHUDContainer = container;

      [UIView animateWithDuration:kKayokoHUDFadeDuration
                            delay:0.0
                          options:UIViewAnimationOptionBeginFromCurrentState
                       animations:^{
                         container.alpha = 1.0;
                       }
                       completion:nil];

      if (!transient) {
          return;
      }
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                   (int64_t)(kKayokoHUDTransientDuration * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
                       if (kKayokoHUDGeneration != generation) {
                           return;
                       }
                       [self fadeOutCurrentPill];
                     });
    });
}

+ (void)fadeOutCurrentPill {
    UIView *container = kKayokoHUDContainer;
    if (!container) {
        return;
    }
    kKayokoHUDContainer = nil;
    [UIView animateWithDuration:kKayokoHUDFadeDuration
        delay:0.0
        options:UIViewAnimationOptionBeginFromCurrentState
        animations:^{
          container.alpha = 0.0;
        }
        completion:^(__unused BOOL finished) {
          [container removeFromSuperview];
        }];
}

+ (nullable UIWindow *)hostWindow {
    // The panel is a subview of the status bar window, which sits far above the app's key window, so a pill
    // pinned to the key window is drawn underneath the panel. Prefer that same window: the pill is added last
    // there and therefore stays visible above the panel it is reporting on.
    Class runtimeClass = NSClassFromString(@"KayokoCoreRuntime");
    SEL sharedRuntimeSelector = NSSelectorFromString(@"sharedRuntime");
    if (runtimeClass && [runtimeClass respondsToSelector:sharedRuntimeSelector]) {
        id (*sharedRuntimeIMP)(id, SEL) =
            (id (*)(id, SEL))[runtimeClass methodForSelector:sharedRuntimeSelector];
        id runtime = sharedRuntimeIMP ? sharedRuntimeIMP(runtimeClass, sharedRuntimeSelector) : nil;
        if (runtime) {
            UIWindow *statusBarWindow = nil;
            @try {
                statusBarWindow = [runtime valueForKey:@"statusBarWindow"];
            } @catch (NSException *exception) {
                (void)exception;
                statusBarWindow = nil;
            }
            if ([statusBarWindow isKindOfClass:[UIWindow class]] && ![statusBarWindow isHidden]) {
                return statusBarWindow;
            }
        }
    }

    // `UIApplication.windows` is deprecated and this project compiles against a
    // deployment target that forbids it, so the scene API is the only route.
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow) {
                return window;
            }
        }
    }
    // Nothing reports key (happens during a transition): any foreground window
    // is still better than dropping the message.
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        if (scene.activationState != UISceneActivationStateForegroundActive) {
            continue;
        }
        UIWindow *candidate = ((UIWindowScene *)scene).windows.firstObject;
        if (candidate) {
            return candidate;
        }
    }
    return nil;
}

@end
