#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Reads Apollo's native General > Autoplay GIFs/Videos setting.
BOOL ApolloShouldAutoplayInlineGIF(void);

/// Cached autoplay decision for the current settings/reachability epoch.
/// Invalidated when settings, reachability, or Low Power Mode changes.
BOOL ApolloShouldAutoplayInlineGIFCached(void);

/// Current AutoplayGIFs raw string (never / only-on-wifi / always).
NSString *ApolloAutoplayGIFModeString(void);

/// YES for URLs that are typically animated GIFs (not static JPEG/PNG/WebP).
BOOL ApolloURLLooksLikeAnimatedGIF(NSURL *url);

/// When media_metadata has a GIF entry matching url, return the canonical display URL.
NSURL *_Nullable ApolloInlineGIFDisplayURLFromMetadata(NSURL *url, NSDictionary *_Nullable mediaMetadata);

/// Mark a UIView as belonging to an inline comment/post GIF.
void ApolloMarkViewAsInlineGIF(UIView *view);

/// YES when view or an ancestor was marked as an inline GIF host.
BOOL ApolloViewIsInlineGIF(UIView *view);

/// User tapped play on a paused inline GIF — allow animation until reuse.
void ApolloSetInlineGIFUserForcedPlay(UIView *view, BOOL forced);

/// YES when autoplay is allowed for this FLAnimatedImageView (inline + settings + forced).
BOOL ApolloInlineGIFViewShouldAutoplay(UIView *view);

/// Apply start/stop to an FLAnimatedImageView based on inline GIF autoplay rules.
void ApolloApplyFLAnimatedImageViewAutoplayGate(UIView *view);

/// Depth-first search for an FLAnimatedImageView inside a Texture node view hierarchy.
UIView *_Nullable ApolloFindFLAnimatedImageViewInView(UIView *view);

/// Track inline GIF image nodes for settings refresh.
void ApolloRegisterInlineGIFNode(id imageNode);

/// Stop tracking an inline GIF node after state is cleared or the node is recycled.
void ApolloUnregisterInlineGIFNode(id imageNode);

/// YES when object is a live ASNetworkImageNode suitable for the inline GIF registry.
BOOL ApolloInlineGIFNodeIsRegistryEligible(id imageNode);

/// Re-evaluate autoplay for all registered inline GIF nodes.
void ApolloRefreshVisibleInlineGIFAutoplay(void);

/// Pause a registered inline GIF node (settings refresh — Never / WiFi blocked).
/// Returns YES when a live node was paused.
BOOL ApolloPauseInlineGIFNodeForAutoplay(id imageNode);

/// Reload a registered inline GIF from its URL (settings refresh — Always / WiFi ok).
/// Returns YES when a paused node was reloaded; NO when skipped or resume-only.
BOOL ApolloReloadInlineGIFImageNodeForAutoplay(id imageNode);

/// Install observers for AutoplayGIFs preference / reachability / Low Power Mode.
void ApolloMediaAutoplayInstall(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
