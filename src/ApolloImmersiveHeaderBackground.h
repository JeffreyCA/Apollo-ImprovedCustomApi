#import <UIKit/UIKit.h>

// Draws a profile or subreddit banner through the table's adjusted top inset
// so the artwork continues behind the navigation bar without changing the
// existing header's layout. Two layers: a blurred continuation owns the
// chrome + identity region, while the sharp image uses the actual banner strip
// inside `regionHeight` (below `topInset`) and dissolves into the blur. The blur
// resolves to the theme page color exactly at `extendedHeight` (the bottom of
// the identity header), where the first opaque cells begin.
@interface ApolloImmersiveHeaderBackgroundView : UIView

@property(nonatomic, assign) CGFloat contentTranslation;

- (void)applyBanner:(UIImage *)banner
          pageColor:(UIColor *)pageColor
       regionHeight:(CGFloat)regionHeight
     extendedHeight:(CGFloat)extendedHeight
           topInset:(CGFloat)topInset;

@end

FOUNDATION_EXPORT UIColor *ApolloImmersiveResolvedPageColor(UIColor *fallback,
                                                             UITraitCollection *traits);

// Average-luminance check over the banner's top strip (the region under the
// status bar / nav chrome). Used to pick readable chrome text over the image.
// Result is cached on the image. Returns the cached value (or NO as a safe
// default) without blocking — call ApolloImmersiveBannerIsLightAsync to
// trigger the computation for a banner that hasn't been sampled yet.
FOUNDATION_EXPORT BOOL ApolloImmersiveBannerIsLight(UIImage *banner);

// Associates a stable logical identity (normally the image URL) with a banner.
// Pointer-distinct UIImage instances carrying the same key share luminance and
// blurred-backdrop work. Call this before either API below.
FOUNDATION_EXPORT void ApolloImmersiveSetBannerCacheKey(UIImage *banner, NSString *cacheKey);

// A cache-key component unique to this image INSTANCE for callers that need
// "never share with a different image" semantics (custom banners, appearance
// variants). Use this instead of the raw pointer: heap addresses recycle on
// dealloc, so "%p" keys can serve a brand-new image the dead image's cached
// blur; this UUID lives and dies with the instance it stamps.
FOUNDATION_EXPORT NSString *ApolloImmersiveBannerInstanceIdentity(UIImage *image);

// Same check, computed off the main thread for a not-yet-sampled banner
// (the sample reads every pixel of the source image, which can be a visible
// hitch on the main thread for a large custom banner). `completion` fires on
// the main queue — synchronously/inline if the value is already cached, or
// after a background hop the first time a given banner is seen.
FOUNDATION_EXPORT void ApolloImmersiveBannerIsLightAsync(UIImage *banner,
                                                          void (^completion)(BOOL isLight));

// Shared Liquid Glass effect builder for identity-header controls (Join/Edit
// pills, search field backing). Returns nil when Liquid Glass is unavailable;
// callers fall back to a solid fill. `tintAlpha` only applies when tintColor
// is non-nil.
FOUNDATION_EXPORT UIVisualEffect *ApolloImmersiveGlassEffect(UIColor *tintColor,
                                                             CGFloat tintAlpha,
                                                             BOOL interactive);
