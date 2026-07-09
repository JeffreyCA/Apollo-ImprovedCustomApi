#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Reads the tweak's "Autoplay Inline GIFs" setting. In Default mode this follows
/// Apollo's native Autoplay GIFs/Videos setting; otherwise it is independent.
BOOL ApolloShouldAutoplayInlineGIF(void);

/// Cached autoplay decision for the current settings/reachability epoch.
/// Invalidated when settings, reachability, or Low Power Mode changes.
BOOL ApolloShouldAutoplayInlineGIFCached(void);

/// Current inline-GIF autoplay mode as a normalized string
/// (never / tap-to-play / only-on-wifi / always).
NSString *ApolloAutoplayGIFModeString(void);

/// YES when Apollo's NATIVE Autoplay GIFs/Videos setting is effectively off
/// right now: "never", or "only-on-wifi" while on cellular. Matches Apollo's
/// own runtime decision (see the implementation for the verified semantics);
/// independent of the tweak's Autoplay Inline GIFs setting.
BOOL ApolloNativeAutoplayEffectivelyOff(void);

/// One-time migration for the legacy "Default (Follow Apollo)" mode (0):
/// resolves Apollo's native Autoplay GIFs/Videos setting to the equivalent
/// explicit mode so existing users keep their current behavior.
NSInteger ApolloResolveLegacyDefaultAutoplayGIFMode(void);

/// YES when a paused inline GIF should show the play-button overlay for
/// inline tap-to-play (Tap to Play mode, or WiFi Only while blocked).
/// Never mode shows a pure static cover with no overlay.
BOOL ApolloPausedInlineGIFWantsPlayOverlay(void);

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

/// Flag an Apollo-native inline animated node (giphy-picker embeds, native
/// ![gif](...) tokens, animated snoomoji) so the registry gates it too. These
/// nodes are paused/resumed in place (no cover/overlay/URL reload machinery).
void ApolloFlagNativeInlineGIFNode(id imageNode);

/// YES when the node was flagged via ApolloFlagNativeInlineGIFNode.
BOOL ApolloNodeIsNativeInlineGIF(id imageNode);

/// Apply the current autoplay decision to a native inline animated node:
/// stops/starts its FLAnimatedImageView subview and toggles Texture's
/// animatedImagePaused. Returns YES when a live node was updated.
BOOL ApolloApplyNativeInlineGIFAutoplayGate(id imageNode);

/// Re-evaluate autoplay for all registered inline GIF nodes.
void ApolloRefreshVisibleInlineGIFAutoplay(void);

/// Pause a registered inline GIF node (settings refresh — Never / WiFi blocked).
/// Returns YES when a live node was paused.
BOOL ApolloPauseInlineGIFNodeForAutoplay(id imageNode);

/// Reload a registered inline GIF from its URL (settings refresh — Always / WiFi ok).
/// Returns YES when a paused node was reloaded; NO when skipped or resume-only.
BOOL ApolloReloadInlineGIFImageNodeForAutoplay(id imageNode);

/// Install observers for the Autoplay Inline GIFs preference / reachability / Low Power Mode.
void ApolloMediaAutoplayInstall(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
