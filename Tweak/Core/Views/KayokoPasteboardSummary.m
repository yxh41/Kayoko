//
//  KayokoPasteboardSummary.m
//  Kayoko
//

#import "KayokoPasteboardSummary.h"

#import "KayokoPasteboardManager.h"

#import <ImageIO/ImageIO.h>
#import <math.h>

/// Long ASCII tag: proves this build really carries the summary view and gives
/// field triage an accessibility identifier to look for.
static NSString *const kKayokoSummaryBuildTag = @"KayokoPasteboardSummary-4.3.42";
static NSString *const kKayokoSummaryHintFallback =
    @"Long press the grabber to inspect the current pasteboard (4.3.42). Tap outside to close.";

static NSString *KayokoSummaryLocalized(NSString *key, NSString *fallback) {
    return [[KayokoPasteboardManager localizationBundle] localizedStringForKey:key value:fallback table:@"Tweak"];
}

static NSString *KayokoSummaryByteString(unsigned long long byteCount) {
    return [NSByteCountFormatter stringFromByteCount:(long long)byteCount
                                          countStyle:NSByteCountFormatterCountStyleFile];
}

/// ImageIO reads only the container header. Decoding a full-resolution photo on
/// SpringBoard's main thread is exactly what this view must not do.
static CGSize KayokoSummaryPixelSizeForData(NSData *data) {
    if ([data length] == 0) {
        return CGSizeZero;
    }
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) {
        return CGSizeZero;
    }
    NSDictionary<NSString *, id> *properties =
        CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    CFRelease(source);

    CGFloat width = [properties[(NSString *)kCGImagePropertyPixelWidth] doubleValue];
    CGFloat height = [properties[(NSString *)kCGImagePropertyPixelHeight] doubleValue];
    if (!isfinite(width) || !isfinite(height) || width <= 0 || height <= 0) {
        return CGSizeZero;
    }
    return CGSizeMake(width, height);
}

/// Only ever used for text-like representations, and always bounded so a huge
/// rich-text payload cannot allocate an unbounded NSString on the main thread.
static NSString *KayokoSummaryTextFromValue(id value, NSUInteger limit) {
    NSString *text = nil;
    if ([value isKindOfClass:[NSString class]]) {
        text = value;
    } else if ([value isKindOfClass:[NSURL class]]) {
        text = [(NSURL *)value absoluteString];
    } else if ([value isKindOfClass:[NSAttributedString class]]) {
        text = [(NSAttributedString *)value string];
    } else if ([value isKindOfClass:[NSData class]]) {
        NSData *data = value;
        NSUInteger length = MIN([data length], 8192);
        if (length > 0) {
            NSData *prefix = [data subdataWithRange:NSMakeRange(0, length)];
            text = [[NSString alloc] initWithData:prefix encoding:NSUTF8StringEncoding];
        }
    }
    if ([text length] == 0) {
        return @"";
    }
    text = [[text stringByReplacingOccurrencesOfString:@"\n" withString:@" "]
        stringByReplacingOccurrencesOfString:@"\r"
                                  withString:@" "];
    if ([text length] > limit) {
        text = [[text substringToIndex:limit] stringByAppendingString:@"…"];
    }
    return text;
}

static NSString *KayokoSummaryDetail(NSString *key, NSString *fallbackFormat, unsigned long first,
                                    unsigned long second, NSString *trailing) {
    NSString *format = KayokoSummaryLocalized(key, fallbackFormat);
    if (trailing) {
        return [NSString stringWithFormat:format, first, second, trailing];
    }
    return [NSString stringWithFormat:format, first, second];
}

#pragma mark - Read-only snapshot

@implementation KayokoPasteboardSummary

+ (NSArray<NSDictionary<NSString *, id> *> *)entries {
    NSArray *items = [[UIPasteboard generalPasteboard] items];
    if (![items isKindOfClass:[NSArray class]]) {
        return @[];
    }

    NSArray<NSString *> *imageTypes = @[
        @"public.png", @"public.jpeg", @"public.jpeg-2000", @"public.tiff", @"public.image",
        @"com.apple.uikit.image", @"public.heic", @"public.heif", @"public.webp", @"com.compuserve.gif"
    ];
    NSArray<NSString *> *linkTypes = @[ @"public.url", @"public.file-url" ];
    NSArray<NSString *> *richTypes = @[
        @"public.html", @"public.rtf", @"public.rtfd", @"com.apple.flat-rtfd", @"com.apple.rtfd",
        @"com.apple.WebKit.archived-content"
    ];
    NSArray<NSString *> *textTypes = @[ @"public.utf8-plain-text", @"public.plain-text", @"public.text" ];

    NSMutableArray<NSDictionary<NSString *, id> *> *result =
        [[NSMutableArray alloc] initWithCapacity:[items count]];

    [items enumerateObjectsUsingBlock:^(id rawItem, NSUInteger index, __unused BOOL *stop) {
      if (![rawItem isKindOfClass:[NSDictionary class]]) {
          [result addObject:@{
              @"index" : @(index + 1),
              @"kindKey" : @"Pasteboard Summary Kind Other",
              @"kindFallback" : @"Other",
              @"detail" : @"",
              @"preview" : @"",
              @"typeCount" : @0
          }];
          return;
      }

      NSDictionary<NSString *, id> *item = rawItem;
      NSString *kindKey = @"Pasteboard Summary Kind Other";
      NSString *kindFallback = @"Other";
      NSString *detail = @"";
      NSString *preview = @"";

      NSData *imageData = nil;
      NSString *imageType = nil;
      UIImage *directImage = nil;
      for (NSString *type in imageTypes) {
          id value = item[type];
          if ([value isKindOfClass:[NSData class]]) {
              imageData = value;
              imageType = type;
              break;
          }
          if ([value isKindOfClass:[UIImage class]]) {
              directImage = value;
              imageType = type;
              break;
          }
      }

      if (imageData || directImage) {
          kindKey = @"Pasteboard Summary Kind Image";
          kindFallback = @"Image";
          preview = imageType ?: @"";
          if (imageData) {
              CGSize pixels = KayokoSummaryPixelSizeForData(imageData);
              unsigned long long bytes = [imageData length];
              if (pixels.width > 0 && pixels.height > 0) {
                  detail = KayokoSummaryDetail(@"Pasteboard Summary Pixels", @"%lu x %lu px · %@",
                                               (unsigned long)pixels.width, (unsigned long)pixels.height,
                                               KayokoSummaryByteString(bytes));
              } else {
                  detail = KayokoSummaryByteString(bytes);
              }
          } else {
              CGSize size = [directImage size];
              detail = KayokoSummaryDetail(@"Pasteboard Summary Points", @"%lu x %lu pt · in memory",
                                           (unsigned long)size.width, (unsigned long)size.height, nil);
          }
      } else {
          NSString *linkType = nil;
          for (NSString *type in linkTypes) {
              if (item[type]) {
                  linkType = type;
                  break;
              }
          }
          NSString *richType = nil;
          for (NSString *type in richTypes) {
              if (item[type]) {
                  richType = type;
                  break;
              }
          }
          NSString *textType = nil;
          for (NSString *type in textTypes) {
              if (item[type]) {
                  textType = type;
                  break;
              }
          }

          if (linkType) {
              kindKey = @"Pasteboard Summary Kind Link";
              kindFallback = @"Link";
              NSString *text = KayokoSummaryTextFromValue(item[linkType], 100);
              preview = text;
              detail = KayokoSummaryDetail(@"Pasteboard Summary Characters", @"%lu characters",
                                           (unsigned long)[text length], 0, nil);
          } else if (richType) {
              kindKey = @"Pasteboard Summary Kind Rich Text";
              kindFallback = @"Rich Text";
              preview = richType;
              id value = item[richType];
              unsigned long long bytes = [value isKindOfClass:[NSData class]] ? [value length] : 0;
              detail = bytes > 0 ? KayokoSummaryByteString(bytes) : richType;
              NSString *plainText = textType ? KayokoSummaryTextFromValue(item[textType], 60) : @"";
              if ([plainText length] > 0) {
                  preview = plainText;
              }
          } else if (textType) {
              kindKey = @"Pasteboard Summary Kind Text";
              kindFallback = @"Text";
              NSString *text = KayokoSummaryTextFromValue(item[textType], 100);
              preview = text;
              detail = KayokoSummaryDetail(@"Pasteboard Summary Characters", @"%lu characters",
                                           (unsigned long)[text length], 0, nil);
          } else {
              NSArray<NSString *> *types = [[item allKeys] sortedArrayUsingSelector:@selector(compare:)];
              NSUInteger shown = MIN([types count], 2);
              preview = [[types subarrayWithRange:NSMakeRange(0, shown)] componentsJoinedByString:@", "];
              detail = @"";
          }
      }

      NSString *formats = KayokoSummaryDetail(@"Pasteboard Summary Formats", @"%lu formats",
                                              (unsigned long)[item count], 0, nil);
      if ([detail length] > 0) {
          detail = [NSString stringWithFormat:@"%@ · %@", detail, formats];
      } else {
          detail = formats;
      }

      [result addObject:@{
          @"index" : @(index + 1),
          @"kindKey" : kindKey,
          @"kindFallback" : kindFallback,
          @"detail" : detail,
          @"preview" : preview,
          @"typeCount" : @([item count])
      }];
    }];

    return result;
}

@end

NS_ASSUME_NONNULL_BEGIN

@interface KayokoPasteboardSummaryView ()
@property(nonatomic, strong) UIView *cardView;
@property(nonatomic, strong) UILabel *countLabel;
@property(nonatomic, strong) UIStackView *rowsStackView;
@property(nonatomic, assign) BOOL isDismissing;
@end

NS_ASSUME_NONNULL_END

@implementation KayokoPasteboardSummaryView

#pragma mark - Lifecycle

- (instancetype)init {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        [self setAccessibilityIdentifier:kKayokoSummaryBuildTag];
        [self setBackgroundColor:[[UIColor blackColor] colorWithAlphaComponent:0.22]];

        UITapGestureRecognizer *backdropTap =
            [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleBackdropTap:)];
        [backdropTap setCancelsTouchesInView:NO];
        [self addGestureRecognizer:backdropTap];

        [self buildCard];
    }
    return self;
}

- (void)buildCard {
    UIView *card = [[UIView alloc] init];
    [card setBackgroundColor:[UIColor secondarySystemGroupedBackgroundColor]];
    [[card layer] setCornerRadius:16];
    [[card layer] setShadowColor:[[UIColor blackColor] CGColor]];
    [[card layer] setShadowOpacity:0.18];
    [[card layer] setShadowRadius:20];
    [[card layer] setShadowOffset:CGSizeMake(0, 8)];
    [self addSubview:card];
    [self setCardView:card];

    [card setTranslatesAutoresizingMaskIntoConstraints:NO];
    NSLayoutConstraint *preferredWidth = [[card widthAnchor] constraintEqualToConstant:320];
    [preferredWidth setPriority:UILayoutPriorityDefaultHigh];
    [NSLayoutConstraint activateConstraints:@[
        [[card centerXAnchor] constraintEqualToAnchor:[self centerXAnchor]],
        [[card centerYAnchor] constraintEqualToAnchor:[self centerYAnchor]],
        preferredWidth,
        [[card widthAnchor] constraintLessThanOrEqualToConstant:320],
        [[card widthAnchor] constraintLessThanOrEqualToAnchor:[self widthAnchor] constant:-40],
        [[card heightAnchor] constraintLessThanOrEqualToAnchor:[self heightAnchor] constant:-40]
    ]];

    UIStackView *root = [[UIStackView alloc] init];
    [root setAxis:UILayoutConstraintAxisVertical];
    [root setAlignment:UIStackViewAlignmentFill];
    [root setSpacing:14];
    [card addSubview:root];
    [root setTranslatesAutoresizingMaskIntoConstraints:NO];
    [NSLayoutConstraint activateConstraints:@[
        [[root topAnchor] constraintEqualToAnchor:[card topAnchor] constant:18],
        [[root leadingAnchor] constraintEqualToAnchor:[card leadingAnchor] constant:18],
        [[root trailingAnchor] constraintEqualToAnchor:[card trailingAnchor] constant:-18],
        [[root bottomAnchor] constraintEqualToAnchor:[card bottomAnchor] constant:-18]
    ]];

    UIStackView *header = [[UIStackView alloc] init];
    [header setAxis:UILayoutConstraintAxisHorizontal];
    [header setAlignment:UIStackViewAlignmentCenter];
    [header setSpacing:8];
    [root addArrangedSubview:header];

    UILabel *titleLabel = [[UILabel alloc] init];
    [titleLabel setText:KayokoSummaryLocalized(@"Pasteboard Summary", @"Clipboard")];
    [titleLabel setFont:[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]];
    [titleLabel setTextColor:[UIColor labelColor]];
    [header addArrangedSubview:titleLabel];

    UIView *flex = [[UIView alloc] init];
    [flex setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisHorizontal];
    [header addArrangedSubview:flex];

    UILabel *countLabel = [[UILabel alloc] init];
    [countLabel setFont:[UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium]];
    [countLabel setTextColor:[UIColor secondaryLabelColor]];
    [countLabel setTextAlignment:NSTextAlignmentRight];
    [header addArrangedSubview:countLabel];
    [self setCountLabel:countLabel];

    UIStackView *rows = [[UIStackView alloc] init];
    [rows setAxis:UILayoutConstraintAxisVertical];
    [rows setAlignment:UIStackViewAlignmentFill];
    [rows setSpacing:12];
    [root addArrangedSubview:rows];
    [self setRowsStackView:rows];

    UILabel *hintLabel = [[UILabel alloc] init];
    [hintLabel setText:KayokoSummaryLocalized(@"Pasteboard Summary Hint", kKayokoSummaryHintFallback)];
    [hintLabel setFont:[UIFont systemFontOfSize:11]];
    [hintLabel setTextColor:[UIColor tertiaryLabelColor]];
    [hintLabel setNumberOfLines:0];
    [root addArrangedSubview:hintLabel];

    UIButton *doneButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [doneButton setTitle:KayokoSummaryLocalized(@"Pasteboard Summary Done", @"Done")
                forState:UIControlStateNormal];
    [[doneButton titleLabel] setFont:[UIFont systemFontOfSize:16 weight:UIFontWeightMedium]];
    [doneButton setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    [doneButton setBackgroundColor:[UIColor tertiarySystemFillColor]];
    [[doneButton layer] setCornerRadius:8];
    [doneButton setClipsToBounds:YES];
    [doneButton addTarget:self action:@selector(handleDoneButton) forControlEvents:UIControlEventTouchUpInside];
    [root addArrangedSubview:doneButton];
    [NSLayoutConstraint activateConstraints:@[ [[doneButton heightAnchor] constraintEqualToConstant:36] ]];
}

#pragma mark - Content

- (void)reloadRows {
    for (UIView *arranged in [[self rowsStackView] arrangedSubviews]) {
        [arranged removeFromSuperview];
    }

    NSArray<NSDictionary<NSString *, id> *> *entries = [KayokoPasteboardSummary entries];
    NSUInteger count = [entries count];
    NSString *countFormat = KayokoSummaryLocalized(@"Pasteboard Summary Count", @"%lu items");
    [[self countLabel] setText:[NSString stringWithFormat:countFormat, (unsigned long)count]];

    if (count == 0) {
        UILabel *emptyLabel = [[UILabel alloc] init];
        [emptyLabel setText:KayokoSummaryLocalized(@"Pasteboard Summary Empty", @"The clipboard is empty.")];
        [emptyLabel setFont:[UIFont systemFontOfSize:13]];
        [emptyLabel setTextColor:[UIColor secondaryLabelColor]];
        [emptyLabel setNumberOfLines:0];
        [[self rowsStackView] addArrangedSubview:emptyLabel];
        return;
    }

    NSUInteger const visibleLimit = 8;
    NSUInteger visible = MIN(count, visibleLimit);
    for (NSUInteger index = 0; index < visible; index++) {
        [[self rowsStackView] addArrangedSubview:[self rowForEntry:entries[index]]];
    }
    if (count > visible) {
        NSString *moreFormat = KayokoSummaryLocalized(@"Pasteboard Summary More", @"+ %lu more");
        UILabel *moreLabel = [[UILabel alloc] init];
        [moreLabel setText:[NSString stringWithFormat:moreFormat, (unsigned long)(count - visible)]];
        [moreLabel setFont:[UIFont systemFontOfSize:12]];
        [moreLabel setTextColor:[UIColor tertiaryLabelColor]];
        [[self rowsStackView] addArrangedSubview:moreLabel];
    }
}

- (UIView *)rowForEntry:(NSDictionary<NSString *, id> *)entry {
    UIStackView *row = [[UIStackView alloc] init];
    [row setAxis:UILayoutConstraintAxisHorizontal];
    [row setAlignment:UIStackViewAlignmentTop];
    [row setSpacing:10];

    UILabel *indexLabel = [[UILabel alloc] init];
    [indexLabel setText:[NSString stringWithFormat:@"#%@", entry[@"index"]]];
    [indexLabel setFont:[UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium]];
    [indexLabel setTextColor:[UIColor tertiaryLabelColor]];
    [row addArrangedSubview:indexLabel];
    [NSLayoutConstraint activateConstraints:@[ [[indexLabel widthAnchor] constraintEqualToConstant:26] ]];

    UIStackView *texts = [[UIStackView alloc] init];
    [texts setAxis:UILayoutConstraintAxisVertical];
    [texts setAlignment:UIStackViewAlignmentFill];
    [texts setSpacing:2];
    [row addArrangedSubview:texts];

    UILabel *kindLabel = [[UILabel alloc] init];
    [kindLabel setText:KayokoSummaryLocalized(entry[@"kindKey"], entry[@"kindFallback"])];
    [kindLabel setFont:[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]];
    [kindLabel setTextColor:[UIColor labelColor]];
    [texts addArrangedSubview:kindLabel];

    NSString *detail = entry[@"detail"];
    if ([detail length] > 0) {
        UILabel *detailLabel = [[UILabel alloc] init];
        [detailLabel setText:detail];
        [detailLabel setFont:[UIFont systemFontOfSize:12]];
        [detailLabel setTextColor:[UIColor secondaryLabelColor]];
        [detailLabel setNumberOfLines:0];
        [texts addArrangedSubview:detailLabel];
    }

    NSString *preview = entry[@"preview"];
    if ([preview length] > 0) {
        UILabel *previewLabel = [[UILabel alloc] init];
        [previewLabel setText:preview];
        [previewLabel setFont:[UIFont systemFontOfSize:12]];
        [previewLabel setTextColor:[UIColor tertiaryLabelColor]];
        [previewLabel setNumberOfLines:2];
        [texts addArrangedSubview:previewLabel];
    }

    return row;
}

#pragma mark - Presentation

- (void)showInView:(UIView *)view animated:(BOOL)animated {
    [self setFrame:[view bounds]];
    [self setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
    [view addSubview:self];
    [self reloadRows];

    if (!animated) {
        return;
    }
    [self setAlpha:0];
    [[self cardView] setAlpha:0];
    [[self cardView] setTransform:CGAffineTransformMakeScale(0.94, 0.94)];
    [UIView animateWithDuration:0.28
                          delay:0
         usingSpringWithDamping:0.86
          initialSpringVelocity:0.6
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
                       [self setAlpha:1];
                       [[self cardView] setAlpha:1];
                       [[self cardView] setTransform:CGAffineTransformIdentity];
                     }
                     completion:nil];
}

- (void)dismissAnimated:(BOOL)animated {
    if ([self isDismissing]) {
        return;
    }
    [self setIsDismissing:YES];

    if (!animated) {
        [self removeFromSuperview];
        return;
    }
    [UIView animateWithDuration:0.2
        delay:0
        options:UIViewAnimationOptionCurveEaseIn
        animations:^{
          [self setAlpha:0];
          [[self cardView] setTransform:CGAffineTransformMakeScale(0.96, 0.96)];
        }
        completion:^(__unused BOOL finished) {
          [self removeFromSuperview];
        }];
}

#pragma mark - Actions

- (void)handleBackdropTap:(UITapGestureRecognizer *)recognizer {
    if (CGRectContainsPoint([[self cardView] frame], [recognizer locationInView:self])) {
        return;
    }
    if ([self dismissHandler]) {
        [self dismissHandler]();
    }
}

- (void)handleDoneButton {
    if ([self dismissHandler]) {
        [self dismissHandler]();
    }
}

@end
