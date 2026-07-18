#import <UIKit/UIKit.h>

// Draws a profile or subreddit banner through the table's adjusted top inset
// so the artwork continues behind the navigation bar without changing the
// existing header's layout. Two layers: the sharp banner owns the chrome +
// banner strip (`regionHeight`), then dissolves into a blurred continuation
// of itself that sits behind the identity text and resolves to the theme
// page color exactly at `extendedHeight` (the bottom of the identity header),
// where the first opaque cells begin.
@interface ApolloImmersiveHeaderBackgroundView : UIView

@property(nonatomic, assign) CGFloat contentTranslation;

- (void)applyBanner:(UIImage *)banner
          pageColor:(UIColor *)pageColor
       regionHeight:(CGFloat)regionHeight
     extendedHeight:(CGFloat)extendedHeight
           topInset:(CGFloat)topInset;

@end

FOUNDATION_EXPORT UIColor *ApolloImmersiveResolvedPageColor(UIColor *fallback);

// Average-luminance check over the banner's top strip (the region under the
// status bar / nav chrome). Used to pick readable chrome text over the image.
// Result is cached on the image.
FOUNDATION_EXPORT BOOL ApolloImmersiveBannerIsLight(UIImage *banner);

// Shared Liquid Glass effect builder for identity-header controls (Join/Edit
// pills, search field backing). Returns nil when Liquid Glass is unavailable;
// callers fall back to a solid fill. `tintAlpha` only applies when tintColor
// is non-nil.
FOUNDATION_EXPORT UIVisualEffect *ApolloImmersiveGlassEffect(UIColor *tintColor,
                                                             CGFloat tintAlpha,
                                                             BOOL interactive);
