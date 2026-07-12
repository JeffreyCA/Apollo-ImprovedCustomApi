#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloMediaAutoplay.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

// =============================================================================
// MARK: - Overview
// =============================================================================
//
// In-app Picture-in-Picture for comments-page inline videos (see
// docs/pip-design.md for the full RE-backed design).
//
// When the user scrolls a playing video out of view on a post's comments page,
// Apollo pauses it via a midpoint test inside
// -[RichMediaHeaderCellNode cellNodeVisibilityEvent:inScrollView:withCellFrame:]
// (sub_1002060bc → sub_1002063d8): the moment the video's center crosses under
// the nav bar, [[videoNode playerLayer] player] is paused synchronously inside
// that method. We detect the same transition FIRST (our hook in
// ApolloVideoUnmute.xm consults ApolloPiP_HandleCommentsVisibilityEvent before
// %orig), take ownership of the AVPlayer, and skip %orig entirely so the pause
// never happens. The video keeps playing and a floating, draggable card —
// hosting a SECOND AVPlayerLayer attached to the same AVPlayer, in a
// tweak-owned passthrough UIWindow — takes over. Scrolling back restores the
// inline video seamlessly (Apollo's inline layer keeps rendering the whole
// time: AVFoundation vends frames to every attached layer).
//
// While PiP owns a player we must defend it from Apollo's machinery:
//   - TouchHintVideoNode.didExitVisibleState → mute dance (skip %orig; the
//     fork's super implementation is a no-op, so nothing is lost)
//   - RichMediaNode pauseAllAVPlayers notification handler (skip for owned)
//   - RichMediaNode.didExitPreloadState player teardown for non-shareable
//     videos (skip while owned — keeps compact-mode v.redd.it players alive)
//   - LargePostCellNode's feed visibility handler (suppress its pause; restore
//     PiP into the feed cell when it becomes visible after a back-pop)
//   - AVAudioSession Ambient/deactivate downgrades while PiP audio is playing
//     (predicate consumed by the hooks in ApolloVideoUnmute.xm)
//
// Scope: Reddit-hosted v.redd.it videos (shareable, plus compact-mode
// non-shareable fallback players) AND any other inline video that carries
// audio — Streamable and similar external hosts — gated by PiPIsEligibleVideo.
// Silent GIFs (also inline ASVideoNodes, but no audio track) and feed-initiated
// card takeover are intentionally out of scope (see docs/pip-design.md §3).
//
// Second entry point (issue #528): a PiP button in the fullscreen media
// viewer, available ONLY while the video can't be autoplaying inline (setting
// effectively off, or a spoiler/NSFW post) and the viewer owns its player —
// see the "Fullscreen → PiP entry point" section.
//
// =============================================================================

// Provided by ApolloVideoUnmute.xm (both files are Logos/ObjC++, so the
// declarations below mangle identically to the definitions there).
extern AVPlayer *ApolloVideoUnmute_GetPlayerFromVideoNode(id videoNode);
extern void ApolloVideoUnmute_SyncMuteButtonIcon(id richMediaNode, BOOL isMuted);
extern void ApolloVideoUnmute_ClearProtectionIfPlayer(AVPlayer *player);
extern BOOL ApolloVideoUnmute_IsNavigatingBack(void);

// Defined in PictureInPictureViewController.m (plain global — not mangled).
extern NSString *const ApolloPictureInPictureChangedNotification;

// =============================================================================
// MARK: - Small helpers (per-TU statics; mirrors ApolloVideoUnmute.xm patterns)
// =============================================================================

static id PiPGetIvar(id obj, const char *ivarName) {
    if (!obj) return nil;
    Ivar ivar = class_getInstanceVariable([obj class], ivarName);
    return ivar ? object_getIvar(obj, ivar) : nil;
}

static id PiPRichMediaNodeFromCell(id cellNode) {
    id richMediaNode = PiPGetIvar(cellNode, "richMediaNode");
    if (richMediaNode) return richMediaNode;
    id crosspostNode = PiPGetIvar(cellNode, "crosspostNode");
    return crosspostNode ? PiPGetIvar(crosspostNode, "richMediaNode") : nil;
}

static id PiPVideoNodeFromRichMedia(id richMediaNode) {
    return richMediaNode ? PiPGetIvar(richMediaNode, "videoNode") : nil;
}

static UIView *PiPViewForNode(id node) {
    if (!node || ![node respondsToSelector:@selector(view)]) return nil;
    return ((UIView *(*)(id, SEL))objc_msgSend)(node, @selector(view));
}

static BOOL PiPNodeIsShareable(id videoNode) {
    SEL sel = NSSelectorFromString(@"allowPlayerLayerToBeShareable");
    if (!videoNode || ![videoNode respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(videoNode, sel);
}

// Does the currently-playing item carry an audio track? This is what separates
// a real video — which the user can unmute — from a silent autoplaying GIF (also
// an inline ASVideoNode) in the strict eligibility check below. (GIFs are still
// admitted to PiP, but separately, by URL in "All Videos & GIFs" mode.)
//
// Must stay non-blocking: this runs on the feed-scroll / unmute main thread, and
// callers only know rate != 0 (a play rate was REQUESTED), which does NOT imply
// the asset's keys are loaded. So we read only already-loaded state:
//   • item.tracks returns the loaded tracks (empty, never blocking, if unloaded)
//     — a progressive MP4 audio track shows up here.
//   • availableMediaCharacteristicsWithMediaSelectionOptions is a legacy
//     SYNCHRONOUS accessor that blocks on a network round-trip if the asset's
//     keys aren't loaded — HLS (Streamable et al.) exposes audio only here, not
//     as an item track. We gate it on status == ReadyToPlay, which guarantees the
//     keys are loaded so the read can't block. (By the time a user unmutes a
//     playing video the item is ReadyToPlay, so the unmute path still resolves.)
// An item that isn't ready yet returns NO; a later visibility/scroll re-evaluation
// (or the comments retry timer) re-checks once it loads.
static BOOL PiPVideoHasAudio(AVPlayer *player) {
    AVPlayerItem *item = player.currentItem;
    if (!item) return NO;
    for (AVPlayerItemTrack *track in item.tracks) {
        AVAssetTrack *assetTrack = track.assetTrack;
        if (assetTrack && [assetTrack.mediaType isEqualToString:AVMediaTypeAudio]) {
            return YES;
        }
    }
    if (item.status != AVPlayerItemStatusReadyToPlay) return NO;
    return [[item.asset availableMediaCharacteristicsWithMediaSelectionOptions]
            containsObject:AVMediaCharacteristicAudible];
}

// The source URL of the playing item — preferring the player's AVURLAsset, then
// the node's assetURL (works even when videoNode is gone, e.g. a weak inline ref
// cleared by the time a loop observer fires).
static NSURL *PiPAssetURLForNode(id videoNode, AVPlayer *player) {
    AVAsset *asset = player.currentItem.asset;
    if ([asset isKindOfClass:[AVURLAsset class]]) {
        return [(AVURLAsset *)asset URL];
    }
    SEL assetURLSel = NSSelectorFromString(@"assetURL");
    if (videoNode && [videoNode respondsToSelector:assetURLSel]) {
        return ((id (*)(id, SEL))objc_msgSend)(videoNode, assetURLSel);
    }
    return nil;
}

// Strict eligibility: Reddit-hosted videos (shareable v.redd.it, plus compact-
// mode non-shareable comments players that still point at a v.redd.it asset URL),
// PLUS any other inline video that carries audio — Streamable and similar
// external hosts. The audio requirement excludes silent GIFs here; GIFs are
// admitted separately, by URL in "All Videos & GIFs" mode (PiPNodeURLIsGif).
static BOOL PiPIsEligibleVideo(id videoNode, AVPlayer *player) {
    if (PiPNodeIsShareable(videoNode)) return YES;

    NSURL *url = PiPAssetURLForNode(videoNode, player);
    NSString *host = url.host.lowercaseString;
    if (host != nil && [host containsString:@"v.redd.it"]) return YES;

    // Non-Reddit inline video (Streamable etc.): eligible iff it carries audio.
    return PiPVideoHasAudio(player);
}

// Is this content a GIF by origin URL? Reddit serves GIFs from i.redd.it /
// preview.redd.it with a .gif path — and crucially the MP4 playback variant
// keeps ".gif?format=mp4", so the URL still says GIF even though the clip plays
// as an MP4 that can carry a SILENT audio track (which makes the audio heuristic
// wrongly call it a video). imgur uses .gifv; Giphy uses giphy.com. The ".gif"
// substring is safe against real videos: v.redd.it / Streamable / YouTube URLs
// never contain it, and Reddit signature query params are hex (no "gif").
static BOOL PiPNodeURLIsGif(id videoNode, AVPlayer *player) {
    NSString *s = PiPAssetURLForNode(videoNode, player).absoluteString.lowercaseString;
    if (!s) return NO;
    return [s containsString:@".gif"] || [s containsString:@"giphy.com"];
}

// GIF content for PiP purposes (always loops, no audio, no mute button): a GIF
// by origin URL, OR a non-strictly-eligible silent inline video. At takeover the
// eligibility gate has already required ReadyToPlay for the non-URL case, so a
// !PiPIsEligibleVideo result there is a genuinely silent clip, not a still-
// loading audio video.
static BOOL PiPNodeIsGifContent(id videoNode, AVPlayer *player) {
    return PiPNodeURLIsGif(videoNode, player) || !PiPIsEligibleVideo(videoNode, player);
}

// GIFs are admitted to PiP only in the most inclusive Activate For mode,
// "All Videos & GIFs".
static inline BOOL PiPGifsActivated(void) {
    return sPiPActivationMode == ApolloPiPActivationModeAllVideosAndGifs;
}

// Eligible to arm inline / feed System PiP (the swipe-home handoff, no floating
// card). GIF-first, mirroring the card gate: a GIF (by URL) qualifies only in
// "All Videos & GIFs"; everything else uses the strict audio-bearing check. The
// URL check must come first — a GIF has no audio, and a compact-mode comments
// player isn't ReadyToPlay at arm time, so the audio check can't yet see the
// GIF-as-MP4's silent track.
static BOOL PiPIsEligibleForInlineNativePiP(id videoNode, AVPlayer *player) {
    if (PiPNodeURLIsGif(videoNode, player)) return PiPGifsActivated();
    return PiPIsEligibleVideo(videoNode, player);
}

// Mixable, active Playback session for the System-PiP handoff. Callers must
// gate on "no other audio playing": ANY Ambient→Playback transition interrupts
// other apps' audio (device-confirmed, even mixable/category-only), and Apollo
// never hands the session back for a muted player — the interruption would be
// permanent (issue #560).
static void PiPClaimMixablePlaybackSession(void) {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback
                    mode:AVAudioSessionModeDefault
                 options:AVAudioSessionCategoryOptionMixWithOthers error:nil];
    [session setActive:YES withOptions:0 error:nil];
}

// Did the user turn this player's sound on? player.muted alone can't answer:
// Apollo's fresh comments/fullscreen players keep AVPlayer's default
// muted == NO (silenced by the Ambient session), so a muted-sounding video can
// read unmuted forever. But every real unmute path (native muteUnmuteTapped
// sub_100341894, fullscreen unmute, UnmuteRichMediaNode, card muteTapped)
// synchronously claims a NON-mixable Playback session, and that claim survives
// navigation (sub_10058cb30 skips the mute dance for the activeAudioPlayer) —
// so "unmuted + exclusively-held Playback session" is the reliable signal
// (issue #560).
static BOOL PiPPlayerIsDeliberatelyAudible(AVPlayer *player) {
    if (!player || player.muted) return NO;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    return [session.category isEqualToString:AVAudioSessionCategoryPlayback]
        && !(session.categoryOptions & AVAudioSessionCategoryOptionMixWithOthers);
}

// Midpoint visibility test mirroring Apollo's sub_1002063d8 (and the fork's
// -[ASVideoNode isVisibleInProperRect]): the video view's center, in window
// coordinates, must lie between the bottom of the nav bar and the top of the
// tab bar. We deliberately use the TRUE midpoint (convertRect:bounds) rather
// than Apollo's frame-vs-bounds quirk — while PiP owns the player only our
// threshold matters, and the true midpoint is the better UX trigger.
static BOOL PiPIsVideoMidpointVisible(id videoNode, id cellNode) {
    UIView *view = PiPViewForNode(videoNode) ?: PiPViewForNode(cellNode);
    UIWindow *window = view.window;
    if (!view || !window) return NO;

    CGRect rectInWindow = [view convertRect:view.bounds toView:nil];
    CGPoint mid = CGPointMake(CGRectGetMidX(rectInWindow), CGRectGetMidY(rectInWindow));

    CGFloat topY = 0.0;
    CGFloat bottomY = window.bounds.size.height;
    UIViewController *rootVC = window.rootViewController;
    if ([rootVC isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tab = (UITabBarController *)rootVC;
        if (tab.tabBar.window) {
            bottomY -= tab.tabBar.bounds.size.height;
        }
        UIViewController *selected = tab.selectedViewController;
        if ([selected isKindOfClass:[UINavigationController class]]) {
            UINavigationBar *navBar = ((UINavigationController *)selected).navigationBar;
            if (navBar.window) {
                topY = CGRectGetMaxY([navBar convertRect:navBar.bounds toView:nil]);
            }
        }
    }

    return mid.y >= topY && mid.y <= bottomY
        && mid.x >= 0 && mid.x <= window.bounds.size.width;
}

// Deceleration projection (WWDC18 formula) with a deliberately FAST rate.
// The scroll-view "normal" rate (0.998) multiplies velocity by ~0.5s of
// travel — far too floaty for free positioning: even a tiny residual flick at
// release would glide the card tens of points from where the finger left it.
// 0.99 gives ~0.1s of momentum: a real fling still tosses the card, a casual
// release stays put.
static CGFloat PiPProjectOffset(CGFloat velocity) {
    CGFloat rate = 0.99;
    return (velocity / 1000.0) * rate / (1.0 - rate);
}

// Tracks the last midpoint-visibility we observed per cell node, so we can
// detect the visible→hidden transition (the "about to pause" moment).
static const void *kPiPPrevVisibleKey = &kPiPPrevVisibleKey;

// Dedupe flag for the inline native-PiP arm retry chain (the player often
// does not exist yet at the cell's first visibility event).
static const void *kPiPArmRetryPendingKey = &kPiPArmRetryPendingKey;

// Dedupe flag for the same-link stale-card recheck (a compact comments header
// creates its fresh player asynchronously, with no visibility event when it
// attaches — the recheck closes the card once that player really plays).
static const void *kPiPSameLinkRecheckKey = &kPiPSameLinkRecheckKey;

// =============================================================================
// MARK: Fullscreen → PiP entry point state (issue #528)
// =============================================================================
//
// A "PiP" button in the fullscreen media viewer dismisses it and hands the
// video to the in-app card. The button exists ONLY when both hold:
//   1. The video can't be autoplaying inline: Autoplay GIFs/Videos is
//      effectively off ("never", or wifi-only on cellular), OR the post is
//      spoiler/NSFW-tagged (obscured posts never autoplay regardless of the
//      setting). With inline autoplay, scroll-away takeover covers PiP entry.
//   2. The viewer OWNS its player (the `player` ivar — nil when a shared
//      layer was adopted). An owned player has no inline home, so the card
//      is always the sole renderer.

// Pending request captured at button-tap time, resolved after the dismissal
// completes (MediaPageViewController.viewDidDisappear). The player is held
// STRONGLY so a fullscreen-owned (non-shareable) player survives its view
// controller's dealloc until the card adopts it.
static BOOL sFSPiPPending = NO;
static AVPlayer *sFSPiPPlayer = nil;
static BOOL sFSPiPWasMuted = NO;
static BOOL sFSPiPWasPlaying = NO;
static id sFSPiPLink = nil;
static NSUInteger sFSPiPRequestToken = 0; // keys each request's expiry failsafe

// Resolution timestamp — guards PiPHandleFeedViewControllerAppeared against
// closing a card that a fullscreen dismissal is creating at this very moment
// (a modal dismissal fires the presenting feed VC's viewDidAppear, whose
// ordering against MediaPageViewController.viewDidDisappear is undefined).
static CFAbsoluteTime sFSPiPResolvedAt = 0;

// Mirrors the native closeButton's alpha/hidden (the chrome fade toggles each
// chrome view individually inside a UIView animation — KVO fires within the
// animation block, so the mirrored writes inherit the same animation). Holds
// the observed button strongly: associated objects are released AFTER
// .cxx_destruct during dealloc, so a weak/unretained ref could dangle by the
// time this observer needs removing.
@interface ApolloPiPFullscreenButtonMirror : NSObject
@property (nonatomic, strong) UIButton *sourceButton;
@property (nonatomic, strong) UIButton *pipButton;
@end

@implementation ApolloPiPFullscreenButtonMirror

- (instancetype)initWithSource:(UIButton *)source pipButton:(UIButton *)pipButton {
    if ((self = [super init])) {
        _sourceButton = source;
        _pipButton = pipButton;
        [source addObserver:self forKeyPath:@"alpha" options:0 context:NULL];
        [source addObserver:self forKeyPath:@"hidden" options:0 context:NULL];
    }
    return self;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    self.pipButton.alpha = self.sourceButton.alpha;
    if (self.sourceButton.hidden) self.pipButton.hidden = YES;
    // Un-hiding is owned by the visibility refresh (autoplay gate + owned-
    // player check), not mirrored — an image page (or a gated video page)
    // must keep the button hidden while the X shows.
}

- (void)dealloc {
    [_sourceButton removeObserver:self forKeyPath:@"alpha"];
    [_sourceButton removeObserver:self forKeyPath:@"hidden"];
}

@end

static const void *kPiPFullscreenButtonKey = &kPiPFullscreenButtonKey;
static const void *kPiPFullscreenMirrorKey = &kPiPFullscreenMirrorKey;

// A loop-suppressed video parks at its end (rate 0, currentTime == duration).
// Calling play() on an at-end item is a no-op and never re-fires the end
// notification, so without a rewind the video stays frozen on its last frame
// once PiP hands it back. Seek a stopped-at-end player to the start so the
// next play() resumes normal (looping) inline playback.
static BOOL PiPPlayerStoppedAtEnd(AVPlayer *player) {
    if (!player || player.rate != 0) return NO;
    AVPlayerItem *item = player.currentItem;
    if (!item || !CMTIME_IS_NUMERIC(item.duration)) return NO;
    CGFloat duration = CMTimeGetSeconds(item.duration);
    if (duration <= 0) return NO;
    return CMTimeGetSeconds(item.currentTime) >= duration - 0.25;
}

static void PiPRewindIfStoppedAtEnd(AVPlayer *player) {
    if (PiPPlayerStoppedAtEnd(player)) {
        [player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    }
}

// Tighter variant: paused with the playhead AT the end (not merely near it).
// This is the one spot where play() is a dead no-op even with Loop ON — the
// end notification only fires when playback REACHES the end, so a paused
// seek-to-end (system PiP's own skip controls can do this) parks the player
// where neither Apollo's loop nor our suppression path will ever run again.
static BOOL PiPPlayerParkedAtExactEnd(AVPlayer *player) {
    if (!player || player.rate != 0) return NO;
    AVPlayerItem *item = player.currentItem;
    if (!item || !CMTIME_IS_NUMERIC(item.duration)) return NO;
    CGFloat duration = CMTimeGetSeconds(item.duration);
    if (duration <= 0) return NO;
    return CMTimeGetSeconds(item.currentTime) >= duration - 0.05;
}

// =============================================================================
// MARK: - Window / views
// =============================================================================

// Passthrough window: only touches inside the floating card are consumed;
// everything else falls through to Apollo's own windows. Returning consistent
// results also satisfies iOS 18's double hit-test per UIEvent.
@interface ApolloPiPWindow : UIWindow
@property (nonatomic, weak) UIView *interactiveView;
@end

@implementation ApolloPiPWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (!hit) return nil;
    UIView *card = self.interactiveView;
    if (card && !card.hidden && (hit == card || [hit isDescendantOfView:card])) {
        return hit;
    }
    return nil;
}

// Never become the key window. The status-bar "scroll to top" tap searches
// ONLY the key window's registered scroll-to-top views (UIKit:
// _UIScrollsToTopInitiatorView.touchesEnded → -[UIApplication
// _keyWindowForScreen:] → -[UIWindow _scrollToTopViewsUnderScreenPointIfNecessary:]
// — it never falls through to other windows). UIKit promotes a window to key
// when the user touches it (gated on -canBecomeKeyWindow at UIWindow
// makeKeyWindow), so once the user tapped/dragged the floating card this
// full-screen overlay — which registers no scroll views — became key and
// Apollo's feed/comments silently stopped scrolling to top. Declining key
// keeps Apollo's window key; touch delivery, the overlay buttons, and the
// card gestures are all hit-test/tracking based and do not need key status
// (the card hosts no text input / first responder).
- (BOOL)canBecomeKeyWindow {
    return NO;
}
@end

@interface ApolloPiPRootViewController : UIViewController
@property (nonatomic, copy) void (^onTransitionToSize)(void);
@end

@implementation ApolloPiPRootViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
}
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    __weak __typeof(self) weakSelf = self;
    [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
        if (weakSelf.onTransitionToSize) weakSelf.onTransitionToSize();
    }];
}
@end

@interface ApolloPiPPlayerView : UIView
@property (nonatomic, readonly) AVPlayerLayer *playerLayer;
@end

@implementation ApolloPiPPlayerView
+ (Class)layerClass { return [AVPlayerLayer class]; }
- (AVPlayerLayer *)playerLayer { return (AVPlayerLayer *)self.layer; }
@end

// Controls overlay that re-lays-out its buttons whenever its bounds change
// (pinch, double-tap resize, rotation — including mid-animation frames).
// Explicit layout rather than autoresizing masks: masks distribute size deltas
// by each view's creation-time margins, which would push the asymmetric skip
// buttons off-center into the corner buttons at other card sizes.
@interface ApolloPiPOverlayView : UIView
@property (nonatomic, copy) void (^onLayout)(void);
@end

@implementation ApolloPiPOverlayView
- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.onLayout) self.onLayout();
}
@end

// =============================================================================
// MARK: - Controller
// =============================================================================

static void *kPiPRateContext = &kPiPRateContext;
static void *kPiPMutedContext = &kPiPMutedContext;
static void *kPiPReadyContext = &kPiPReadyContext;
static void *kPiPTimeControlContext = &kPiPTimeControlContext;

static const CGFloat kPiPMinWidth = 150.0;
static const CGFloat kPiPEdgeMargin = 10.0;
// Default/large card footprints are defined by AREA, not width: a fixed width
// fraction makes a portrait video balloon to most of the screen (its height =
// width / aspect). We instead pick a target area calibrated so a 16:9 video
// lands at ~half the screen width, then preserve that area across any aspect
// ratio — landscape stays wide-and-short, portrait stays narrow-and-tall with
// the SAME on-screen footprint. These constants express the calibration as the
// landscape (16:9) width fraction the area corresponds to.
static const CGFloat kPiPDefaultLandscapeWidthFraction = 0.5; // spawn size
static const CGFloat kPiPLargeLandscapeWidthFraction = 0.82;  // double-tap "zoom"
static const CGFloat kPiPReferenceAspect = 16.0 / 9.0;        // calibration aspect
static const CGFloat kPiPStashVisibleWidth = 18.0; // sliver left on screen while stashed
// Below this release speed (pt/s) the card stays exactly where the finger
// left it — no momentum, no drift.
static const CGFloat kPiPFlingVelocityThreshold = 250.0;
// A stash requires a decisive horizontal fling at least this fast.
static const CGFloat kPiPStashVelocityThreshold = 300.0;
static const NSTimeInterval kPiPControlsAutoHideDelay = 3.0;

@interface ApolloPiPController : NSObject <UIGestureRecognizerDelegate>

// Ownership state
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerItem *playerItem;   // keeps item alive for non-shareable
@property (nonatomic, weak) id richMediaNode;
@property (nonatomic, weak) id videoNode;
@property (nonatomic, strong) id link;                    // RDKLink, for same-post detection
// YES when the taken-over video is NON-shareable (compact mode): its player is
// not shared with a feed cell, so it can never be reclaimed/restored into the
// feed. Captured at takeover because videoNode is weak and may be gone by the
// time we return to the feed.
@property (nonatomic, assign) BOOL ownedNonShareable;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, assign) BOOL restoring;
@property (nonatomic, assign) NSUInteger generation;      // invalidates stale async blocks
@property (nonatomic, assign) BOOL resumeOnForeground;
// YES once this PiP session has played audibly (it claimed the Playback audio
// session at some point) — closing must hand the session back even if the
// user muted the card just before closing.
@property (nonatomic, assign) BOOL sessionClaimedAudibly;
// YES when this card holds GIF content — silent inline content with no audio
// track. Such a card must never claim the Playback session audibly (it would
// interrupt the user's music for a silent GIF) nor block Apollo's Ambient
// downgrade; the mute button is hidden for it too.
@property (nonatomic, assign) BOOL cardIsGifContent;

// UI
@property (nonatomic, strong) ApolloPiPWindow *window;
@property (nonatomic, strong) ApolloPiPRootViewController *rootViewController;
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) ApolloPiPPlayerView *playerView;
@property (nonatomic, strong) ApolloPiPOverlayView *controlsOverlay;
@property (nonatomic, strong) UIButton *playPauseButton;
@property (nonatomic, strong) UIButton *muteButton;
@property (nonatomic, strong) UIButton *closeButton;
// Optional overlay extras (settings-gated): skip back/ahead by sPiPSkipSeconds,
// plus a read-only progress strip along the bottom edge.
@property (nonatomic, strong) UIButton *skipBackButton;
@property (nonatomic, strong) UIButton *skipForwardButton;
@property (nonatomic, strong) UIView *progressTrack;
@property (nonatomic, strong) UIView *progressFill;
@property (nonatomic, assign) CGFloat progressFraction;  // last computed fill fraction
@property (nonatomic, strong) NSTimer *controlsTimer;
@property (nonatomic, strong) UIViewPropertyAnimator *animator;
@property (nonatomic, assign) CGFloat aspectRatio;        // width / height
@property (nonatomic, assign) BOOL cardRevealed;
@property (nonatomic, assign) BOOL observingPlayer;
@property (nonatomic, strong) AVPlayer *observedPlayer;   // KVO removal safety
@property (nonatomic, strong) id timeObserverToken;       // periodic progress ticks

// Edge stash (native-PiP-style "swipe off the side to hide")
@property (nonatomic, assign) NSInteger stashedSide;      // 0 = docked, -1 = left edge, +1 = right edge
@property (nonatomic, strong) UIImageView *stashHandle;   // chevron tab shown while stashed

// Native (system) PiP — on the floating card's layer while PiP is active
@property (nonatomic, strong) AVPictureInPictureController *nativePiP;
// Native (system) PiP — armed on Apollo's INLINE player layer while an
// eligible video plays on screen (no floating card), so swiping to the home
// screen hands the inline video to system PiP too.
@property (nonatomic, strong) AVPictureInPictureController *inlineNativePiP;
@property (nonatomic, weak) AVPlayer *inlineNativePlayer;
@property (nonatomic, weak) id inlineNativeVideoNode;
// An inline player we paused on backgrounding because System PiP never
// started (avoids a background-audio leak); resumed on foreground.
@property (nonatomic, weak) AVPlayer *backgroundPausedInlinePlayer;
// Whether that player was DELIBERATELY audible when the failsafe paused it —
// captured before the handback resets the session (the live session read in
// PiPPlayerIsDeliberatelyAudible is meaningless afterwards). Gates the
// foreground re-claim: only a deliberately-audible video may retake exclusive
// (non-mixable) audio focus on resume; a silent fresh player reads muted == NO
// and must not (issue #560).
@property (nonatomic, assign) BOOL backgroundPausedInlineWasAudible;
// Set by claimHandoffSessionIfNeeded (resign-time claim); released — with the
// resume cue for any music it paused — once it no longer serves a handoff:
// PiP never started, X-closed from the home screen, or back in the foreground.
// Mutually exclusive with a deliberate-unmute claim (those leave the category
// at Playback, so the handoff claim is skipped).
@property (nonatomic, assign) BOOL handoffSessionClaimed;
// Did the app actually background since the last resign? A Control-Center/
// alert bounce never fires willEnterForeground, so didBecomeActive uses this
// to downgrade a stale handoff flag to an ordinary standing claim.
@property (nonatomic, assign) BOOL enteredBackground;
// Was the session category Playback at controller creation? AVKit latches
// auto-start eligibility at birth: Ambient-born controllers never auto-start
// and must be recreated under a claim (the heals); Playback-born ones stay
// viable even if the session later dips to Ambient, so the resign-time
// recreate must not destroy them (a resign-born replacement gets no warm-up
// time — possible=0).
@property (nonatomic, assign) BOOL nativePiPBornUnderPlayback;
@property (nonatomic, assign) BOOL inlineNativePiPBornUnderPlayback;

// YES for a card created from the fullscreen viewer's PiP button. Such a card
// has no inline video-node identity (owned players only) — it floats until
// closed, and the feed back-pop walk must not misread it as stranded.
@property (nonatomic, assign) BOOL cardFromFullscreen;

@end

@implementation ApolloPiPController

// Returns the singleton WITHOUT creating it — used by the hot-path predicates
// so an untouched feature costs one nil check.
static ApolloPiPController *sPiPSharedController = nil;

// Set while PiP itself hands the audio session back (Ambient + deactivate):
// ApolloPiP_ShouldBlockAudioSessionDowngrade consults this, and without the
// bypass the ApolloVideoUnmute blocking hooks would swallow our own downgrade
// — e.g. the card background failsafe hands back while the card is still
// active, which the predicate's first clause would otherwise block.
static BOOL sPiPSessionHandbackInProgress = NO;

+ (instancetype)sharedController {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sPiPSharedController = [[ApolloPiPController alloc] init];
    });
    return sPiPSharedController;
}

- (instancetype)init {
    if ((self = [super init])) {
        _aspectRatio = 16.0 / 9.0;

        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        __weak __typeof(self) weakSelf = self;
        [center addObserverForName:UIApplicationWillResignActiveNotification object:nil
                             queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            [weakSelf claimHandoffSessionIfNeeded];
        }];
        [center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil
                             queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            [weakSelf handleDidEnterBackground];
        }];
        [center addObserverForName:UIApplicationWillEnterForegroundNotification object:nil
                             queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            [weakSelf handleWillEnterForeground];
        }];
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                             queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            [weakSelf handleDidBecomeActive];
        }];
        [center addObserverForName:ApolloPictureInPictureChangedNotification object:nil
                             queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            __typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            // The mini-player and native PiP are independently togglable.
            if (!sPiPEnabled && strongSelf.active) {
                ApolloLog(@"[PiP] Mini-player disabled in settings — closing active PiP");
                [strongSelf teardownKeepPlaying:NO];
            }
            if (!sPiPNativeEnabled) {
                [strongSelf destroyNativePiP];
                [strongSelf disarmInlineNativePiPIfIdle];
            } else if (strongSelf.active) {
                [strongSelf setupNativePiP];
            }
            // (Enabling native PiP with an inline video on screen re-arms on
            // the next scroll tick via the visibility handler.)

            // Re-evaluate an inline-armed (not-yet-handed-off) controller against
            // the possibly-changed activation mode — switching away from "All
            // Videos & GIFs" must disarm a GIF that armed inline System PiP, or
            // it would still hand off on background. No visibility event fires on
            // a settings change, so the visibility-handler disarm can't catch it.
            if (sPiPNativeEnabled && strongSelf.inlineNativePiP
                && !strongSelf.inlineNativePiP.pictureInPictureActive
                && strongSelf.inlineNativePlayer
                && !PiPIsEligibleForInlineNativePiP(strongSelf.inlineNativeVideoNode,
                                                    strongSelf.inlineNativePlayer)) {
                ApolloLog(@"[PiP] Activation mode change made the inline-armed video ineligible — disarming");
                [strongSelf disarmInlineNativePiPIfIdle];
            }

            // Overlay extras (skip buttons / progress bar) toggled while the
            // card's controls are showing: refresh them in place.
            if (strongSelf.active && !strongSelf.controlsOverlay.hidden) {
                [strongSelf syncControlIcons];
            }
        }];
    }
    return self;
}

// =============================================================================
// MARK: Visibility-event entry point
// =============================================================================

// Returns YES when the caller's %orig must be skipped (we own this cell's
// player and Apollo's synchronous play/pause must not run).
- (BOOL)handleVisibilityEventForCell:(id)cellNode
                       richMediaNode:(id)richMediaNode
                               event:(unsigned long long)event {
    if (!richMediaNode) return NO;
    id videoNode = PiPVideoNodeFromRichMedia(richMediaNode);
    if (!videoNode) return NO;

    if (self.active) {
        if (self.restoring) return NO;
        AVPlayer *player = ApolloVideoUnmute_GetPlayerFromVideoNode(videoNode);
        BOOL owned = (player && player == self.player)
                  || (self.videoNode && videoNode == self.videoNode);
        if (!owned) {
            // Same post re-opened with a RECREATED player (compact-mode fresh
            // player, or the shared layer was released while we were away):
            // identity checks fail but the content is ours. Close the stale
            // PiP — otherwise the video displays (and can play audio) twice.
            // Only when the cell actually HAS a player: a home with no player
            // (autoplay off — the header shows a static poster) can't double-
            // display anything, and a fullscreen-initiated card legitimately
            // floats over exactly that cell.
            id cellLink = PiPGetIvar(richMediaNode, "link");
            BOOL sameLink = self.link && cellLink
                         && (cellLink == self.link || [cellLink isEqual:self.link]);
            // Fullscreen-origin cards legitimately float over their own post's
            // static poster (autoplay off) — for THEM a playerless same-link
            // cell is fine, and the deferred recheck below covers the fresh
            // player attaching asynchronously. Every other card keeps the
            // shipped behavior: close on any same-link sighting (the fresh
            // player often attaches ~500ms after the event, with no event of
            // its own — waiting for it would double-play).
            if (sameLink && (player || !self.cardFromFullscreen)) {
                ApolloLog(@"[PiP] Same post re-entered with a new player — closing stale PiP");
                [self teardownKeepPlaying:NO];
            } else if (sameLink) {
                [self scheduleSameLinkRecheckForCell:cellNode
                                       richMediaNode:richMediaNode
                                           videoNode:videoNode];
            }
            return NO;
        }

        if (PiPIsVideoMidpointVisible(videoNode, cellNode)) {
            // The video's inline home is back on screen — hand back. Apollo's
            // %orig runs after we return NO; its [player play] is harmless.
            [self restoreInline];
            return NO;
        }
        return YES; // still scrolled away: suppress Apollo's pause
    }

    // Either feature keeps this handler live: the in-app mini-player
    // (sPiPEnabled) takes over on scroll-away; System PiP (sPiPNativeEnabled)
    // arms a system-PiP controller on the inline player while it plays. They
    // are independent — only the takeover at the bottom requires sPiPEnabled.
    if (!sPiPEnabled && !sPiPNativeEnabled) return NO;
    if (event == 2) {
        // Cell fully gone: clear tracking — a takeover at this point would
        // pop the card in with no anchor.
        objc_setAssociatedObject(cellNode, kPiPPrevVisibleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (videoNode == self.inlineNativeVideoNode) {
            // Leaving the foreground fires a spurious Invisible event for
            // every visible cell (ASCellNode.didExitVisibleState →
            // handleVisibilityChange — the same churn the mute-dance shield
            // guards). Disarming HERE would destroy the controller at the
            // exact moment iOS evaluates auto-PiP for the home-swipe handoff
            // ("System PiP enabled but nothing happens"). Background churn is
            // distinguished from a REAL disappearance racing the home-swipe
            // (e.g. a flick still decelerating) by geometry: churn leaves the
            // cell where it was (midpoint still visible), a real scroll-away
            // moved it off. Disarm for a real in-comments scroll-away — BUT a
            // back-pop also fires this event while the SAME player is reclaimed
            // onto the feed (and keeps playing); disarming there kills the
            // controller mid-reclaim, so defer to the feed side (which re-arms,
            // and the controller survives the pop intact).
            BOOL backgroundChurn =
                [UIApplication sharedApplication].applicationState != UIApplicationStateActive
                && PiPIsVideoMidpointVisible(videoNode, cellNode);
            BOOL navigatingBack = ApolloVideoUnmute_IsNavigatingBack();
            if (!backgroundChurn && !navigatingBack) {
                [self disarmInlineNativePiPIfIdle];
            } else {
                ApolloLog(@"[PiP] Keeping inline native PiP armed through %@ invisible event",
                          navigatingBack ? @"back-pop" : @"background-churn");
            }
        }
        return NO;
    }
    if (event > 2) {
        // Drag bookkeeping (WillBeginDragging/DidEndDragging): keep the
        // baseline — clearing it here would blind the next real event.
        return NO;
    }

    BOOL visible = PiPIsVideoMidpointVisible(videoNode, cellNode);
    NSNumber *prev = objc_getAssociatedObject(cellNode, kPiPPrevVisibleKey);
    objc_setAssociatedObject(cellNode, kPiPPrevVisibleKey, @(visible), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    AVPlayer *player = ApolloVideoUnmute_GetPlayerFromVideoNode(videoNode);

    // A visible GIF should be playing — GIFs autoplay and loop — but Apollo
    // pauses the comments-header GIF while it's off-screen and doesn't auto-resume
    // it on the way back, leaving it at rate==0 (which blocks both the inline arm
    // and a fresh takeover). Nudge a loaded, visible, paused GIF back to playing.
    if (sPiPEnabled && PiPGifsActivated() && visible && !self.active
        && player && player.rate == 0
        && player.currentItem.status == AVPlayerItemStatusReadyToPlay
        && PiPNodeURLIsGif(videoNode, player)) {
        ApolloLog(@"[PiP] Resuming paused visible GIF for re-activation");
        PiPRewindIfStoppedAtEnd(player);
        [player play];
    }

    // System PiP also covers INLINE playback: while an eligible video plays on
    // screen, keep a system PiP controller armed on Apollo's own inline player
    // layer so backgrounding hands it off.
    if (sPiPNativeEnabled && visible) {
        // Unmuted-Only keys on a deliberate unmute, NOT raw player.muted — a
        // fresh comments player reads muted == NO while the user hears silence
        // (Ambient session), and gating on it armed (and session-claimed) videos
        // the user never unmuted (issue #560).
        if (player && player.rate != 0
            && !(sPiPActivationMode == ApolloPiPActivationModeUnmutedOnly
                 && !PiPPlayerIsDeliberatelyAudible(player))
            && PiPIsEligibleForInlineNativePiP(videoNode, player)) {
            [self armInlineNativePiPForVideoNode:videoNode player:player];
        } else if (!player || player.rate == 0) {
            // Fresh navigation: the shared layer/player is adopted (and starts
            // playing) AFTER the cell's first visibility event, and without
            // scrolling no further events arrive — the controller would never
            // arm and a home-swipe would not enter PiP. Retry off-event.
            if (!objc_getAssociatedObject(cellNode, kPiPArmRetryPendingKey)) {
                objc_setAssociatedObject(cellNode, kPiPArmRetryPendingKey, @YES,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                ApolloLog(@"[PiP] Inline arm: player not ready at visibility event — scheduling retries");
                [self retryInlineArmForCell:cellNode videoNode:videoNode attempts:4];
            }
        } else if (videoNode == self.inlineNativeVideoNode) {
            // Playing but no longer eligible (e.g. switched away from "All Videos
            // & GIFs" while this GIF stayed visible) — disarm, mirroring the feed
            // path's arm/disarm symmetry. Otherwise a stale GIF would still hand
            // off to System PiP on background in a mode that excludes GIFs.
            [self disarmInlineNativePiPIfIdle];
        }
    }

    if (!prev || prev.boolValue == visible || visible) return NO;

    // visible → hidden transition: the "about to pause" moment. From here down
    // is in-app mini-player takeover, which requires its own toggle.
    if (!sPiPEnabled) return NO;
    if (!player || player.rate == 0.0f) return NO;
    // "All Videos & GIFs" widens the in-app card to GIFs the strict audio guard
    // otherwise rejects. (The inline System-PiP arm admits GIFs in the same mode
    // via PiPIsEligibleForInlineNativePiP; the feed stays GIF-free because feed
    // GIFs autoplay muted.)
    BOOL gifByURL = PiPNodeURLIsGif(videoNode, player);
    BOOL strictlyEligible = PiPIsEligibleVideo(videoNode, player);
    if (gifByURL || !strictlyEligible) {
        // GIF content: a GIF by origin URL (e.g. a Reddit .gif served as MP4,
        // which is strictly eligible only because its MP4 carries a silent audio
        // track), or a non-strictly-eligible silent inline video. Admit only in
        // the "All Videos & GIFs" activation mode. For the non-URL case require
        // ReadyToPlay so a still-loading audio video (transiently not strictly
        // eligible) re-evaluates on the strict path instead of slipping in here;
        // URL-identified GIFs are reliable pre-load. GIFs bypass Unmuted-Only —
        // no audio to unmute.
        if (!PiPGifsActivated()) return NO;
        if (!gifByURL) {
            AVPlayerItem *item = player.currentItem;
            if (!item || item.status != AVPlayerItemStatusReadyToPlay) return NO;
        }
    } else if (sPiPActivationMode == ApolloPiPActivationModeUnmutedOnly
               && !PiPPlayerIsDeliberatelyAudible(player)) {
        // Unmuted-Only governs audio-bearing videos — keyed on a deliberate
        // unmute (see PiPPlayerIsDeliberatelyAudible), not raw player.muted.
        return NO;
    }
    if ([self isInlineNativePiPActive]) return NO; // system PiP owns rendering right now

    [self takeOverFromCell:cellNode richMediaNode:richMediaNode videoNode:videoNode player:player];
    return YES;
}

// Deferred arm of the same-link stale-card guard above: the cell's fresh
// player attaches asynchronously (no visibility event fires for it), so poll
// a few times and close the card if a DIFFERENT live player starts rendering
// our post. The video node is re-derived from the rich media node at fire
// time — the node itself can be recreated rather than given a player.
- (void)sameLinkRecheckWithRichMediaNode:(__weak id)weakRich attempts:(NSUInteger)attempts
                              generation:(NSUInteger)generation cell:(__weak id)weakCell {
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __typeof(self) strongSelf = weakSelf;
        BOOL done = YES;
        if (strongSelf && strongSelf.active && strongSelf.generation == generation) {
            // Re-verify against CURRENT content — cell reuse can swap the post.
            id cellLink = PiPGetIvar(weakRich, "link");
            BOOL sameLink = strongSelf.link && cellLink
                         && (cellLink == strongSelf.link || [cellLink isEqual:strongSelf.link]);
            if (sameLink) {
                id videoNode = PiPVideoNodeFromRichMedia(weakRich);
                AVPlayer *fresh = videoNode ? ApolloVideoUnmute_GetPlayerFromVideoNode(videoNode) : nil;
                // Not while a back-swipe is in flight (a fire mid-gesture must
                // not close a card a cancelled gesture would keep) — retry.
                if (fresh && fresh != strongSelf.player && fresh.rate != 0
                    && !ApolloVideoUnmute_IsNavigatingBack()) {
                    ApolloLog(@"[PiP] Same post's fresh player materialized — closing stale PiP");
                    [strongSelf teardownKeepPlaying:NO];
                } else if (attempts > 1) {
                    done = NO;
                    [strongSelf sameLinkRecheckWithRichMediaNode:weakRich attempts:attempts - 1
                                                      generation:generation cell:weakCell];
                }
            }
        }
        if (done) {
            id cell = weakCell;
            if (cell) {
                objc_setAssociatedObject(cell, kPiPSameLinkRecheckKey, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    });
}

- (void)scheduleSameLinkRecheckForCell:(id)cellNode
                         richMediaNode:(id)richMediaNode
                             videoNode:(id)videoNode {
    if (!cellNode || objc_getAssociatedObject(cellNode, kPiPSameLinkRecheckKey)) return;
    objc_setAssociatedObject(cellNode, kPiPSameLinkRecheckKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self sameLinkRecheckWithRichMediaNode:richMediaNode attempts:3
                                generation:self.generation cell:cellNode];
}

// =============================================================================
// MARK: Takeover / restore / teardown
// =============================================================================

- (void)takeOverFromCell:(id)cellNode richMediaNode:(id)richMediaNode
               videoNode:(id)videoNode player:(AVPlayer *)player {
    if (self.active) {
        ApolloLog(@"[PiP] New takeover while active — closing previous PiP");
        [self teardownKeepPlaying:NO];
    }

    self.generation++;
    self.player = player;
    self.playerItem = player.currentItem;
    self.richMediaNode = richMediaNode;
    self.videoNode = videoNode;
    self.link = PiPGetIvar(richMediaNode, "link");
    self.ownedNonShareable = !PiPNodeIsShareable(videoNode);
    // GIF content (always loops, no audio session, no mute button): a GIF by
    // origin URL — incl. a Reddit .gif served as MP4 that carries a silent audio
    // track and would otherwise read as a video — or a non-strictly-eligible
    // silent inline video. v.redd.it/Streamable real videos stay non-GIF.
    self.cardIsGifContent = PiPNodeIsGifContent(videoNode, player);
    self.cardFromFullscreen = NO; // fullscreen resolution flips it after takeover
    self.active = YES;
    self.restoring = NO;
    self.resumeOnForeground = NO;
    // Keyed on a deliberate unmute, not raw player.muted: a silent fresh player
    // reads muted == NO, and marking it "claimed audibly" would make teardown
    // downgrade a session the card never really owned.
    self.sessionClaimedAudibly = PiPPlayerIsDeliberatelyAudible(player) && !self.cardIsGifContent;

    UIView *videoView = PiPViewForNode(videoNode);
    CGSize videoViewSize = videoView ? videoView.bounds.size : CGSizeZero;

    CGSize presentation = player.currentItem.presentationSize;
    if (presentation.width > 1 && presentation.height > 1) {
        self.aspectRatio = presentation.width / presentation.height;
    } else if (videoViewSize.width > 1 && videoViewSize.height > 1) {
        // Inline view's aspect as fallback until presentationSize is known.
        self.aspectRatio = videoViewSize.width / videoViewSize.height;
    } else {
        self.aspectRatio = 16.0 / 9.0;
    }

    ApolloLog(@"[PiP] Taking over player %p (muted=%d, aspect=%.2f)",
              player, player.muted, self.aspectRatio);

    [self ensureWindowForAnchorView:videoView];
    [self buildCardIfNeeded];

    self.cardRevealed = NO;
    self.stashedSide = 0;
    self.stashHandle.hidden = YES;
    self.card.hidden = YES;
    [self hideControlsOverlay]; // also cancels a previous video's fill animation
    self.progressFraction = 0;  // don't carry the previous video's fill into a layout pass
    self.playerView.playerLayer.player = player;

    [self installPlayerObservers];

    // Reveal happens on the new layer's readyForDisplay (KVO) so there is no
    // black flash — the inline layer keeps rendering until then because we
    // suppressed Apollo's pause. Safety net in case the KVO never fires.
    NSUInteger generation = self.generation;
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf.active && strongSelf.generation == generation
            && !strongSelf.cardRevealed) {
            ApolloLog(@"[PiP] readyForDisplay timeout — revealing card anyway");
            [strongSelf revealCard];
        }
    });

    if (sPiPNativeEnabled) {
        // The floating card's controller takes over native-PiP duty from the
        // inline one (only one armed controller at a time).
        [self disarmInlineNativePiPIfIdle];
        [self setupNativePiP];
    }
}

- (void)restoreInline {
    if (!self.active || self.restoring) return;

    ApolloLog(@"[PiP] Restoring inline (fade out)");

    // If the clip ran out while the card presented it (Loop off), rewind now —
    // synchronously, before we return to Apollo's visibility handler, whose
    // [player play] would otherwise no-op on the at-end item and leave the
    // inline video frozen on its last frame.
    PiPRewindIfStoppedAtEnd(self.player);

    if (!self.cardRevealed) {
        [self teardownKeepPlaying:YES];
        return;
    }

    self.restoring = YES;
    [self cancelAnimator];
    [self hideControlsOverlay];
    // Touches must not reach the card while restoring: a gesture would cancel
    // this animator, its completion (the ONLY path to teardown) would be
    // skipped, and the state machine would wedge in active+restoring forever.
    // (Gesture handlers also early-out on restoring as a second line of
    // defense.)
    self.card.userInteractionEnabled = NO;

    // Simple fade — the inline video has been rendering the same frames all
    // along, so the card just dissolves away.
    __weak __typeof(self) weakSelf = self;
    UIViewPropertyAnimator *animator =
        [[UIViewPropertyAnimator alloc] initWithDuration:0.2
                                                   curve:UIViewAnimationCurveEaseOut
                                              animations:^{
            weakSelf.card.alpha = 0.0;
        }];
    [animator addCompletion:^(UIViewAnimatingPosition finalPosition) {
        [weakSelf teardownKeepPlaying:YES];
    }];
    self.animator = animator;
    [animator startAnimation];
}

// Tear down the floating UI. keepPlaying=YES hands the (still playing) player
// back to Apollo's inline machinery untouched; keepPlaying=NO applies the
// state Apollo expects for a scrolled-away video: paused + muted + Ambient.
- (void)teardownKeepPlaying:(BOOL)keepPlaying {
    AVPlayer *player = self.player;
    id richMediaNode = self.richMediaNode;
    BOOL sessionWasClaimed = self.sessionClaimedAudibly;
    BOOL wasGifContent = self.cardIsGifContent;

    // A player parked at its end (Loop off) must never be handed back as-is:
    // Apollo's next inline play() would no-op on the at-end item and freeze
    // the video on its last frame with no recovery (the card's rescue paths
    // are gone, and rate==0 blocks a fresh takeover). Covers the close (X)
    // path and a clip that runs out during restoreInline's fade — restore's
    // own entry rewind can't catch an end that arrives mid-animation.
    PiPRewindIfStoppedAtEnd(player);

    self.generation++;
    [self removePlayerObservers];
    [self destroyNativePiP];
    [self.controlsTimer invalidate];
    self.controlsTimer = nil;
    [self cancelAnimator];

    self.playerView.playerLayer.player = nil;
    [self.progressFill.layer removeAllAnimations]; // could otherwise run for the clip's remaining length
    self.card.hidden = YES;
    self.card.alpha = 1.0;
    self.card.transform = CGAffineTransformIdentity;
    self.card.userInteractionEnabled = YES; // restore-path disables it
    self.cardRevealed = NO;
    self.stashedSide = 0;
    self.stashHandle.hidden = YES;
    self.window.hidden = YES;

    self.active = NO;
    self.restoring = NO;
    self.resumeOnForeground = NO;
    self.sessionClaimedAudibly = NO;
    self.cardIsGifContent = NO;
    self.player = nil;
    self.playerItem = nil;
    self.link = nil;
    self.richMediaNode = nil;
    self.videoNode = nil;

    if (!keepPlaying && wasGifContent && player) {
        // A GIF should keep looping inline, so leave it as-is rather than
        // pausing/muting — a pause would block the next takeover (rate==0) and
        // Apollo won't auto-resume it. It's silent, so off-screen playback is
        // harmless; scrolling back re-activates the card normally.
        ApolloLog(@"[PiP] Closing GIF — leaving it playing inline (loops)");
    } else if (!keepPlaying && player) {
        ApolloLog(@"[PiP] Closing — applying scrolled-away state (pause + mute)");
        [player pause];
        // Our own AVPlayer.setMuted: hook blocks mutes on the protected player;
        // drop that protection first so this mute goes through.
        ApolloVideoUnmute_ClearProtectionIfPlayer(player);
        [player setMuted:YES];
        if (richMediaNode) {
            ApolloVideoUnmute_SyncMuteButtonIcon(richMediaNode, YES);
        }
        if (sessionWasClaimed) {
            // This PiP session claimed the Playback audio session at some
            // point (even if the card is muted right now) — hand it back,
            // mirroring the mute dance's T+50ms downgrade, so e.g. the user's
            // interrupted music gets its resume cue. self.active is already
            // NO so our own blocking predicate passes this; if ANOTHER
            // protected player exists, the ApolloVideoUnmute hooks block it,
            // which is the correct outcome.
            AVAudioSession *session = [AVAudioSession sharedInstance];
            [session setCategory:AVAudioSessionCategoryAmbient error:nil];
            [session setActive:NO
                   withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                         error:nil];
        }
    }
}

- (void)cancelAnimator {
    if (self.animator.isRunning) {
        [self.animator stopAnimation:YES];
    }
    self.animator = nil;
}

// =============================================================================
// MARK: Window + card UI
// =============================================================================

- (void)ensureWindowForAnchorView:(UIView *)anchorView {
    UIWindowScene *scene = anchorView.window.windowScene;
    if (!scene) {
        for (UIScene *candidate in [UIApplication sharedApplication].connectedScenes) {
            if ([candidate isKindOfClass:[UIWindowScene class]]
                && candidate.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)candidate;
                break;
            }
        }
    }

    if (self.window && (!scene || self.window.windowScene == scene)) {
        self.window.hidden = NO;
        return;
    }

    ApolloPiPWindow *window = scene
        ? [[ApolloPiPWindow alloc] initWithWindowScene:scene]
        : [[ApolloPiPWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    window.windowLevel = UIWindowLevelNormal + 50; // above app UI, below alerts/keyboard
    window.backgroundColor = [UIColor clearColor];

    ApolloPiPRootViewController *rootVC = [[ApolloPiPRootViewController alloc] init];
    __weak __typeof(self) weakSelf = self;
    rootVC.onTransitionToSize = ^{
        [weakSelf refitCardAnimated:NO];
    };
    window.rootViewController = rootVC;

    self.window = window;
    self.rootViewController = rootVC;
    window.hidden = NO;

    if (self.card) {
        [rootVC.view addSubview:self.card];
        window.interactiveView = self.card;
    }
}

- (void)buildCardIfNeeded {
    if (self.card) {
        if (self.card.superview != self.rootViewController.view) {
            [self.rootViewController.view addSubview:self.card];
            self.window.interactiveView = self.card;
        }
        return;
    }

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 200, 112)];
    card.backgroundColor = [UIColor blackColor];
    card.layer.cornerRadius = 12.0;
    card.layer.masksToBounds = YES;
    card.layer.borderWidth = 0.5;
    card.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;

    ApolloPiPPlayerView *playerView = [[ApolloPiPPlayerView alloc] initWithFrame:card.bounds];
    playerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    playerView.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    playerView.userInteractionEnabled = NO;
    [card addSubview:playerView];

    ApolloPiPOverlayView *overlay = [[ApolloPiPOverlayView alloc] initWithFrame:card.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    overlay.hidden = YES;
    __weak __typeof(self) weakOverlaySelf = self;
    overlay.onLayout = ^{
        [weakOverlaySelf layoutOverlayControls];
    };
    [card addSubview:overlay];

    UIImageSymbolConfiguration *bigConfig =
        [UIImageSymbolConfiguration configurationWithPointSize:26 weight:UIImageSymbolWeightSemibold];
    UIImageSymbolConfiguration *smallConfig =
        [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];

    UIButton *(^makeButton)(NSString *, UIImageSymbolConfiguration *, SEL) =
        ^UIButton *(NSString *symbol, UIImageSymbolConfiguration *config, SEL action) {
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            [button setImage:[UIImage systemImageNamed:symbol withConfiguration:config]
                    forState:UIControlStateNormal];
            button.tintColor = [UIColor whiteColor];
            [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
            [overlay addSubview:button];
            return button;
        };

    // All control frames are owned by layoutOverlayControls (run from the
    // overlay's layoutSubviews) — no autoresizing masks on the controls.
    self.playPauseButton = makeButton(@"pause.fill", bigConfig, @selector(playPauseTapped));

    // Optional skip buttons flanking play/pause (hidden unless Skip Buttons is
    // on AND the card is big enough to host them collision-free — see
    // layoutOverlayControls; numbered glyphs are applied in syncControlIcons).
    UIImageSymbolConfiguration *mediumConfig =
        [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold];
    self.skipBackButton = makeButton(@"gobackward.10", mediumConfig, @selector(skipBackTapped));
    self.skipBackButton.hidden = YES;
    self.skipForwardButton = makeButton(@"goforward.10", mediumConfig, @selector(skipForwardTapped));
    self.skipForwardButton.hidden = YES;

    // Optional read-only progress strip along the bottom edge (hidden unless
    // Progress Bar is on). The fill is sized from progressFraction on every
    // layout pass, so resizes keep the filled FRACTION correct between ticks.
    // Inserted at the back so on short cards (where the strip's band can graze
    // the center row's bottom edge) it passes UNDER the button glyphs.
    UIView *progressTrack = [[UIView alloc] initWithFrame:CGRectZero];
    progressTrack.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.35];
    progressTrack.layer.cornerRadius = 1.5;
    progressTrack.layer.masksToBounds = YES;
    progressTrack.userInteractionEnabled = NO;
    progressTrack.hidden = YES;
    [overlay insertSubview:progressTrack atIndex:0];
    self.progressTrack = progressTrack;

    UIView *progressFill = [[UIView alloc] initWithFrame:CGRectZero];
    progressFill.backgroundColor = [UIColor whiteColor];
    progressFill.userInteractionEnabled = NO;
    [progressTrack addSubview:progressFill];
    self.progressFill = progressFill;

    self.closeButton = makeButton(@"xmark", smallConfig, @selector(closeTapped));
    self.muteButton = makeButton(@"speaker.slash.fill", smallConfig, @selector(muteTapped));

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    UITapGestureRecognizer *doubleTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
    doubleTap.numberOfTapsRequired = 2;
    // Deliberately NO requireGestureRecognizerToFail: between them — that
    // would delay the controls overlay by the double-tap timeout (~350ms),
    // which reads as lag. Instead the first tap shows controls instantly and
    // a double-tap re-hides them before resizing (handleDoubleTap).
    //
    // delaysTouchesEnded (default YES) would buffer touch-ended delivery to
    // the overlay BUTTONS while the double-tap window decides, making ✕/mute/
    // play feel laggy. The delegate additionally routes control-originated
    // touches straight to the buttons (shouldReceiveTouch:).
    tap.delaysTouchesEnded = NO;
    tap.delegate = self;
    doubleTap.delaysTouchesEnded = NO;
    doubleTap.delegate = self;
    [card addGestureRecognizer:tap];
    [card addGestureRecognizer:doubleTap];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    pan.delegate = self;
    [card addGestureRecognizer:pan];

    UIPinchGestureRecognizer *pinch =
        [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinch:)];
    pinch.delegate = self;
    [card addGestureRecognizer:pinch];

    // Chevron tab shown on the exposed sliver while the card is stashed off
    // an edge (native-PiP-style). Frame is set by updateStashHandleForSide:.
    UIImageView *stashHandle = [[UIImageView alloc] initWithFrame:CGRectZero];
    stashHandle.contentMode = UIViewContentModeCenter;
    stashHandle.tintColor = [UIColor whiteColor];
    stashHandle.layer.shadowColor = [UIColor blackColor].CGColor;
    stashHandle.layer.shadowOpacity = 0.6;
    stashHandle.layer.shadowOffset = CGSizeZero;
    stashHandle.layer.shadowRadius = 2.0;
    stashHandle.hidden = YES;
    [card addSubview:stashHandle];
    self.stashHandle = stashHandle;

    self.card = card;
    self.playerView = playerView;
    self.controlsOverlay = overlay;

    [self.rootViewController.view addSubview:card];
    self.window.interactiveView = card;
}

- (void)revealCard {
    if (!self.active || self.cardRevealed) return;
    self.cardRevealed = YES;

    // Simple pop-in at the default position — the inline video keeps rendering,
    // so the card just materializes. It may start hidden (tucked off an edge)
    // per the Default Position / Hidden by Default settings.
    [self cancelAnimator];
    NSInteger startSide = 0;
    self.card.frame = [self startingFrameStashSide:&startSide];
    self.stashedSide = startSide;
    [self updateStashHandleForSide:startSide]; // hides the handle when shown
    self.card.hidden = NO;
    self.card.alpha = 0;
    // A hidden start fades the sliver in; a shown start adds the scale pop.
    self.card.transform = startSide != 0 ? CGAffineTransformIdentity
                                         : CGAffineTransformMakeScale(0.88, 0.88);
    if (startSide == 0) [self syncControlIcons];

    __weak __typeof(self) weakSelf = self;
    [UIView animateWithDuration:0.35 delay:0
         usingSpringWithDamping:0.8 initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        weakSelf.card.alpha = 1.0;
        weakSelf.card.transform = CGAffineTransformIdentity;
    } completion:nil];
}

// =============================================================================
// MARK: Geometry
// =============================================================================

// Clamp a desired card WIDTH to the on-screen limits, deriving height from the
// current aspect ratio (and re-clamping width if a tall video would exceed the
// height cap). The single sizing primitive everything else funnels through.
- (CGSize)cardSizeForWidth:(CGFloat)width {
    CGRect bounds = self.window.bounds;
    CGFloat aspect = MAX(self.aspectRatio, 0.1);
    CGFloat maxWidth = bounds.size.width - 2 * kPiPEdgeMargin;
    width = MAX(kPiPMinWidth, MIN(maxWidth, width));
    CGFloat height = width / aspect;
    CGFloat maxHeight = bounds.size.height * 0.5;
    if (height > maxHeight) {
        // Tall video: clamp height and re-clamp the recomputed width too —
        // AspectFill absorbs any residual mismatch for degenerate aspects.
        height = maxHeight;
        width = MAX(kPiPMinWidth, MIN(maxWidth, height * aspect));
    }
    return CGSizeMake(width, height);
}

// Card size for a target AREA, preserving the current aspect ratio:
// width = sqrt(area * aspect), height = sqrt(area / aspect) → width*height = area.
// Clamps absorb the limits (aspect kept, area approximate at the extremes).
- (CGSize)cardSizeForArea:(CGFloat)area {
    if (area <= 0) return [self cardSizeForWidth:kPiPMinWidth];
    return [self cardSizeForWidth:sqrt(area * MAX(self.aspectRatio, 0.1))];
}

// The on-screen area a 16:9 card of the given screen-width fraction would
// occupy — the calibration that turns a "landscape width fraction" into the
// aspect-independent area target used for every video.
- (CGFloat)areaForLandscapeWidthFraction:(CGFloat)fraction {
    CGFloat width = self.window.bounds.size.width * fraction;
    return width * (width / kPiPReferenceAspect);
}

// Default spawn size: the calibrated footprint, applied to THIS video's aspect.
- (CGSize)defaultCardSize {
    return [self cardSizeForArea:[self areaForLandscapeWidthFraction:kPiPDefaultLandscapeWidthFraction]];
}

// The size a freshly-revealed card should use. Only Last Position remembers a
// user-chosen size (as an area fraction, so a differently-shaped next video
// keeps the same footprint rather than the same width); every fixed-corner
// Default Position uses the sensible calibrated default each time.
- (CGSize)spawnCardSize {
    if (sPiPStartPosition == ApolloPiPStartPositionLastPosition) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if ([defaults objectForKey:UDKeyPictureInPictureAreaFraction]) {
            CGFloat areaFraction = [defaults floatForKey:UDKeyPictureInPictureAreaFraction];
            CGFloat w = self.window.bounds.size.width;
            if (areaFraction > 0.0001 && !isnan(areaFraction) && w > 1) {
                return [self cardSizeForArea:areaFraction * w * w];
            }
        }
    }
    return [self defaultCardSize];
}

- (CGPoint)centerForCorner:(NSInteger)corner size:(CGSize)size {
    CGRect bounds = self.window.bounds;
    UIEdgeInsets insets = self.window.safeAreaInsets;
    CGFloat leftX = insets.left + kPiPEdgeMargin + size.width / 2;
    CGFloat rightX = bounds.size.width - insets.right - kPiPEdgeMargin - size.width / 2;
    CGFloat topY = insets.top + kPiPEdgeMargin + size.height / 2;
    CGFloat bottomY = bounds.size.height - insets.bottom - kPiPEdgeMargin - size.height / 2;
    switch (corner) {
        case 0:  return CGPointMake(leftX, topY);
        case 1:  return CGPointMake(rightX, topY);
        case 2:  return CGPointMake(leftX, bottomY);
        default: return CGPointMake(rightX, bottomY);
    }
}

// Record the card's current size as an area fraction (card area / screenWidth²,
// resolution-independent). Only consumed by spawnCardSize in Last Position mode,
// but written on every resize so that mode always has the latest footprint.
- (void)persistCardArea {
    CGFloat w = self.window.bounds.size.width;
    if (w < 1) return;
    CGFloat areaFraction = (self.card.bounds.size.width * self.card.bounds.size.height) / (w * w);
    [[NSUserDefaults standardUserDefaults] setFloat:(float)areaFraction
                                             forKey:UDKeyPictureInPictureAreaFraction];
}

// Free docking: the card may rest anywhere, clamped fully on-screen within
// the safe area + margin.
- (CGPoint)clampedCenter:(CGPoint)center forSize:(CGSize)size {
    CGRect bounds = self.window.bounds;
    UIEdgeInsets insets = self.window.safeAreaInsets;
    CGFloat minX = insets.left + kPiPEdgeMargin + size.width / 2;
    CGFloat maxX = bounds.size.width - insets.right - kPiPEdgeMargin - size.width / 2;
    CGFloat minY = insets.top + kPiPEdgeMargin + size.height / 2;
    CGFloat maxY = bounds.size.height - insets.bottom - kPiPEdgeMargin - size.height / 2;
    if (maxX < minX) maxX = minX;
    if (maxY < minY) maxY = minY;
    return CGPointMake(MAX(minX, MIN(maxX, center.x)), MAX(minY, MIN(maxY, center.y)));
}

// The resting position persists as a NORMALIZED center (fraction of window
// bounds), so it survives rotation and different card sizes: a new video with
// a different aspect ratio reuses the same screen-relative spot, re-clamped
// to fit its own dimensions.
// Records the resting position: normalized center (so it survives rotation and
// differing card sizes) plus the hidden side (0 shown, ±1 tucked off an edge),
// so a Last-Position start restores both. Call at every rest point.
- (void)persistCardCenter {
    CGRect bounds = self.window.bounds;
    if (bounds.size.width < 1 || bounds.size.height < 1) return;
    CGPoint center = self.card.center;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setFloat:(float)(center.x / bounds.size.width) forKey:UDKeyPictureInPictureLastCenterX];
    [defaults setFloat:(float)(center.y / bounds.size.height) forKey:UDKeyPictureInPictureLastCenterY];
    [defaults setInteger:self.stashedSide forKey:UDKeyPictureInPictureLastStashSide];
}

- (CGRect)frameForCenter:(CGPoint)center size:(CGSize)size {
    return CGRectMake(center.x - size.width / 2, center.y - size.height / 2,
                      size.width, size.height);
}

// Reads the persisted normalized resting center scaled to the current window
// bounds. NO when nothing has been persisted yet.
- (BOOL)readPersistedCenter:(CGPoint *)outCenter {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults objectForKey:UDKeyPictureInPictureLastCenterX]
        || ![defaults objectForKey:UDKeyPictureInPictureLastCenterY]) {
        return NO;
    }
    CGRect bounds = self.window.bounds;
    *outCenter = CGPointMake([defaults floatForKey:UDKeyPictureInPictureLastCenterX] * bounds.size.width,
                             [defaults floatForKey:UDKeyPictureInPictureLastCenterY] * bounds.size.height);
    return YES;
}

// Where a fresh card first appears and whether it starts hidden (tucked off an
// edge). Outputs the stash side (0 = shown, ±1 = hidden left/right) and returns
// the frame to place the card at:
//   - Last Position: remembered center + remembered hidden side.
//   - Corner + Hidden by Default off: docked at the corner.
//   - Corner + Hidden by Default on: tucked off the corner's edge at the corner's Y.
- (CGRect)startingFrameStashSide:(NSInteger *)outStashSide {
    CGSize size = [self spawnCardSize];

    if (sPiPStartPosition == ApolloPiPStartPositionLastPosition) {
        CGPoint center;
        BOOL haveCenter = [self readPersistedCenter:&center];
        NSInteger lastSide = [[NSUserDefaults standardUserDefaults]
                              integerForKey:UDKeyPictureInPictureLastStashSide];
        if (haveCenter && (lastSide == -1 || lastSide == 1)) {
            *outStashSide = lastSide;
            CGPoint clamped = [self clampedCenter:center forSize:size];
            return [self stashFrameForSide:lastSide size:size centerY:clamped.y];
        }
        *outStashSide = 0;
        if (!haveCenter) center = [self centerForCorner:ApolloPiPStartPositionTopRight size:size];
        return [self frameForCenter:[self clampedCenter:center forSize:size] size:size];
    }

    NSInteger corner = (sPiPStartPosition >= ApolloPiPStartPositionTopLeft
                        && sPiPStartPosition <= ApolloPiPStartPositionBottomRight)
        ? sPiPStartPosition : ApolloPiPStartPositionTopRight;
    CGPoint center = [self clampedCenter:[self centerForCorner:corner size:size] forSize:size];
    if (sPiPStartHidden) {
        *outStashSide = (corner == ApolloPiPStartPositionTopLeft
                         || corner == ApolloPiPStartPositionBottomLeft) ? -1 : 1;
        return [self stashFrameForSide:*outStashSide size:size centerY:center.y];
    }
    *outStashSide = 0;
    return [self frameForCenter:center size:size];
}

// Re-fit the card after bounds/size changes (rotation, resize): keep the
// persisted screen-relative position, re-clamped for the current size.
- (void)refitCardAnimated:(BOOL)animated {
    if (!self.active || !self.cardRevealed || self.restoring) return;
    if (self.stashedSide != 0) {
        // Rotation while stashed: recompute the stash position for the new bounds.
        self.card.frame = [self stashFrameForSide:self.stashedSide];
        [self updateStashHandleForSide:self.stashedSide];
        return;
    }
    // Preserve the card's CURRENT size across the bounds change (re-clamped),
    // not a persisted fraction — within a session the live card is the source
    // of truth, so a stale cross-session size can't snap it on rotation.
    CGSize size = [self cardSizeForWidth:self.card.bounds.size.width];
    CGPoint center;
    if (![self readPersistedCenter:&center]) {
        center = self.card.center;
    }
    CGRect frame = [self frameForCenter:[self clampedCenter:center forSize:size] size:size];
    if (!animated) {
        self.card.frame = frame;
        return;
    }
    [self cancelAnimator];
    __weak __typeof(self) weakSelf = self;
    UIViewPropertyAnimator *animator =
        [[UIViewPropertyAnimator alloc] initWithDuration:0.45 dampingRatio:0.8 animations:^{
            weakSelf.card.frame = frame;
        }];
    self.animator = animator;
    [animator startAnimation];
}

// =============================================================================
// MARK: Edge stash (native-PiP-style hide)
// =============================================================================

// Stash frame for a given card size, keeping the given on-screen center Y
// (clamped). Only kPiPStashVisibleWidth of the card stays on screen.
- (CGRect)stashFrameForSide:(NSInteger)side size:(CGSize)size centerY:(CGFloat)centerY {
    CGRect bounds = self.window.bounds;
    UIEdgeInsets insets = self.window.safeAreaInsets;
    CGFloat y = centerY - size.height / 2;
    CGFloat minY = insets.top + kPiPEdgeMargin;
    CGFloat maxY = bounds.size.height - insets.bottom - kPiPEdgeMargin - size.height;
    y = MAX(minY, MIN(maxY, y));
    CGFloat x = (side < 0) ? (kPiPStashVisibleWidth - size.width)
                           : (bounds.size.width - kPiPStashVisibleWidth);
    return CGRectMake(x, y, size.width, size.height);
}

- (CGRect)stashFrameForSide:(NSInteger)side {
    return [self stashFrameForSide:side size:self.card.bounds.size centerY:self.card.center.y];
}

- (void)updateStashHandleForSide:(NSInteger)side {
    if (side == 0) {
        self.stashHandle.hidden = YES;
        return;
    }
    // Chevron points inward — the direction to pull the card back out.
    NSString *symbol = (side < 0) ? @"chevron.compact.right" : @"chevron.compact.left";
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightBold];
    self.stashHandle.image = [UIImage systemImageNamed:symbol withConfiguration:config];
    CGSize cardSize = self.card.bounds.size;
    CGFloat x = (side < 0) ? (cardSize.width - kPiPStashVisibleWidth) : 0;
    self.stashHandle.frame = CGRectMake(x, 0, kPiPStashVisibleWidth, cardSize.height);
    self.stashHandle.hidden = NO;
    [self.card bringSubviewToFront:self.stashHandle];
}

- (void)stashToSide:(NSInteger)side {
    ApolloLog(@"[PiP] Stashing card to %@ edge", side < 0 ? @"left" : @"right");
    self.stashedSide = side;
    [self hideControlsOverlay];
    [self updateStashHandleForSide:side];

    CGRect frame = [self stashFrameForSide:side];
    [self cancelAnimator];
    __weak __typeof(self) weakSelf = self;
    UIViewPropertyAnimator *animator =
        [[UIViewPropertyAnimator alloc] initWithDuration:0.45 dampingRatio:0.85 animations:^{
            weakSelf.card.frame = frame;
        }];
    self.animator = animator;
    [animator startAnimation];
    // Model frame is the stash frame now — record the hidden state + Y.
    [self persistCardCenter];
}

- (void)unstash {
    if (self.stashedSide == 0) return;
    ApolloLog(@"[PiP] Unstashing card");
    self.stashedSide = 0;
    [self updateStashHandleForSide:0];
    // Pull fully on-screen at the current height: clamping the mostly
    // offscreen center lands it flush against the stash-side edge.
    CGPoint center = [self clampedCenter:self.card.center forSize:self.card.bounds.size];
    CGRect frame = [self frameForCenter:center size:self.card.bounds.size];
    [self cancelAnimator];
    __weak __typeof(self) weakSelf = self;
    UIViewPropertyAnimator *animator =
        [[UIViewPropertyAnimator alloc] initWithDuration:0.45 dampingRatio:0.8 animations:^{
            weakSelf.card.frame = frame;
        }];
    self.animator = animator;
    [animator startAnimation];
    // The animator sets the model frame at start, so this records the
    // unstashed target position.
    [self persistCardCenter];
}

// =============================================================================
// MARK: Gestures
// =============================================================================

// Touches that start on a control (the overlay buttons) belong to that
// control alone: the buttons respond instantly and the card's tap gesture
// can't toggle the overlay underneath a button press.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    return ![touch.view isKindOfClass:[UIControl class]];
}

// Pan + pinch may run together (system-PiP-like feel); taps stay exclusive.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    BOOL panOrPinch = [gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]
                   || [gestureRecognizer isKindOfClass:[UIPinchGestureRecognizer class]];
    BOOL otherPanOrPinch = [other isKindOfClass:[UIPanGestureRecognizer class]]
                        || [other isKindOfClass:[UIPinchGestureRecognizer class]];
    return panOrPinch && otherPanOrPinch;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (self.restoring) return;
    UIView *container = self.rootViewController.view;
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            [self cancelAnimator];
            break;
        case UIGestureRecognizerStateChanged: {
            CGPoint translation = [pan translationInView:container];
            CGPoint center = self.card.center;
            self.card.center = CGPointMake(center.x + translation.x, center.y + translation.y);
            [pan setTranslation:CGPointZero inView:container];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            CGPoint velocity = [pan velocityInView:container];
            CGFloat speed = sqrt(velocity.x * velocity.x + velocity.y * velocity.y);
            CGPoint center = self.card.center;
            CGRect bounds = self.window.bounds;

            // Gentle release: the card stays EXACTLY where the finger left it
            // (clamped on-screen). Only a real fling earns momentum, and even
            // that is heavily damped (see PiPProjectOffset).
            CGPoint projected = center;
            if (speed >= kPiPFlingVelocityThreshold) {
                projected.x += PiPProjectOffset(velocity.x);
                projected.y += PiPProjectOffset(velocity.y);
            }

            NSInteger startSide = self.stashedSide;
            if (startSide != 0) {
                // Gesture began from a stash. It may push back into the SAME
                // edge or pull inward to unstash — never fly across to the
                // opposite edge.
                BOOL stillOffSameSide = (startSide < 0)
                    ? (projected.x < 0)
                    : (projected.x > bounds.size.width);
                if (stillOffSameSide) {
                    [self stashToSide:startSide];
                    break;
                }
                self.stashedSide = 0;
                [self updateStashHandleForSide:0];
                projected.x = MAX(kPiPEdgeMargin,
                                  MIN(bounds.size.width - kPiPEdgeMargin, projected.x));
            } else {
                // Stashing requires INTENT: the card physically dragged past
                // the edge (center offscreen), or a decisive horizontally-
                // dominant fling toward that edge. Vertical or casual flicks
                // near an edge never stash.
                BOOL horizontalFling = fabs(velocity.x) > kPiPStashVelocityThreshold
                                    && fabs(velocity.x) > fabs(velocity.y);
                if (center.x < 0 || (projected.x < 0 && horizontalFling && velocity.x < 0)) {
                    [self stashToSide:-1];
                    break;
                }
                if (center.x > bounds.size.width
                    || (projected.x > bounds.size.width && horizontalFling && velocity.x > 0)) {
                    [self stashToSide:1];
                    break;
                }
            }

            // Free positioning: settle where the (possibly projected) release
            // landed, clamped fully on-screen.
            CGPoint target = [self clampedCenter:projected forSize:self.card.bounds.size];
            CGFloat dx = target.x - center.x, dy = target.y - center.y;
            if (fabs(dx) < 1.0 && fabs(dy) < 1.0) {
                // Released in place — no settle animation, no drift.
                [self persistCardCenter];
                break;
            }
            CGFloat distance = MAX(1.0, sqrt(dx * dx + dy * dy));
            UISpringTimingParameters *spring =
                [[UISpringTimingParameters alloc] initWithDampingRatio:0.85
                                                       initialVelocity:CGVectorMake(speed / distance, speed / distance)];
            UIViewPropertyAnimator *animator =
                [[UIViewPropertyAnimator alloc] initWithDuration:0.4 timingParameters:spring];
            __weak __typeof(self) weakSelf = self;
            [animator addAnimations:^{ weakSelf.card.center = target; }];
            [self cancelAnimator];
            self.animator = animator;
            [animator startAnimation];
            // Model center is already at the target — record the new resting spot.
            [self persistCardCenter];
            break;
        }
        default:
            break;
    }
}

- (void)handlePinch:(UIPinchGestureRecognizer *)pinch {
    if (self.restoring || self.stashedSide != 0) return;
    static CGFloat startWidth = 0;
    switch (pinch.state) {
        case UIGestureRecognizerStateBegan:
            [self cancelAnimator];
            startWidth = self.card.bounds.size.width;
            break;
        case UIGestureRecognizerStateChanged: {
            CGRect bounds = self.window.bounds;
            CGFloat width = startWidth * pinch.scale;
            width = MAX(kPiPMinWidth, MIN(bounds.size.width - 2 * kPiPEdgeMargin, width));
            CGFloat height = width / MAX(self.aspectRatio, 0.1);
            CGPoint center = self.card.center;
            self.card.bounds = CGRectMake(0, 0, width, height);
            self.card.center = center;
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            // Remember the new footprint (Last Position size memory).
            [self persistCardArea];
            // Stay where pinched; just nudge back on-screen if the resize
            // pushed an edge out of bounds.
            [self persistCardCenter];
            [self refitCardAnimated:YES];
            break;
        }
        default:
            break;
    }
}

// Every hide goes through here: the progress fill's animation runs for the
// clip's entire remaining length, so leaving it active behind a hidden
// overlay would burn render-server work for minutes — and a stale previous-
// video animation could survive a teardown onto the reused fill view.
- (void)hideControlsOverlay {
    self.controlsOverlay.hidden = YES;
    [self.progressFill.layer removeAllAnimations];
}

- (void)handleTap:(UITapGestureRecognizer *)tap {
    if (self.restoring) return;
    if (self.stashedSide != 0) {
        [self unstash];
        return;
    }
    if (self.controlsOverlay.hidden) {
        self.controlsOverlay.hidden = NO;
        [self syncControlIcons];
        [self restartControlsTimer];
    } else {
        [self hideControlsOverlay];
    }
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)tap {
    if (self.restoring || self.stashedSide != 0) return;
    // The first tap of the double-tap already toggled the controls overlay
    // (no failure dependency between the recognizers, see buildCardIfNeeded) —
    // hide it again for a clean resize.
    [self hideControlsOverlay];
    [self.controlsTimer invalidate];
    self.controlsTimer = nil;

    // Toggle between the default and large FOOTPRINTS (area), so the zoom feels
    // the same for landscape and portrait. Pick whichever the current area is
    // farther from.
    CGFloat currentArea = self.card.bounds.size.width * self.card.bounds.size.height;
    CGFloat defaultArea = [self areaForLandscapeWidthFraction:kPiPDefaultLandscapeWidthFraction];
    CGFloat largeArea = [self areaForLandscapeWidthFraction:kPiPLargeLandscapeWidthFraction];
    CGFloat targetArea = (fabs(currentArea - defaultArea) < fabs(currentArea - largeArea))
        ? largeArea : defaultArea;

    // Resize anchored to the card's nearest screen corner — when the card
    // sits top-right, its top-right edges stay put and the size change grows
    // or shrinks inward (center-anchored resizing makes a docked card appear
    // to jump away from its corner).
    CGSize newSize = [self cardSizeForArea:targetArea];
    CGRect old = self.card.frame;
    CGRect bounds = self.window.bounds;
    BOOL anchorRight = CGRectGetMidX(old) > bounds.size.width / 2.0;
    BOOL anchorBottom = CGRectGetMidY(old) > bounds.size.height / 2.0;
    CGFloat x = anchorRight ? CGRectGetMaxX(old) - newSize.width : CGRectGetMinX(old);
    CGFloat y = anchorBottom ? CGRectGetMaxY(old) - newSize.height : CGRectGetMinY(old);
    CGPoint center = [self clampedCenter:CGPointMake(x + newSize.width / 2.0, y + newSize.height / 2.0)
                                 forSize:newSize];
    CGRect frame = [self frameForCenter:center size:newSize];

    [self cancelAnimator];
    __weak __typeof(self) weakSelf = self;
    UIViewPropertyAnimator *animator =
        [[UIViewPropertyAnimator alloc] initWithDuration:0.4 dampingRatio:0.85 animations:^{
            weakSelf.card.frame = frame;
        }];
    self.animator = animator;
    [animator startAnimation];
    // Model frame is the target now — record the new footprint + position.
    [self persistCardArea];
    [self persistCardCenter];
}

- (void)restartControlsTimer {
    [self.controlsTimer invalidate];
    __weak __typeof(self) weakSelf = self;
    self.controlsTimer = [NSTimer scheduledTimerWithTimeInterval:kPiPControlsAutoHideDelay
                                                         repeats:NO
                                                           block:^(NSTimer *timer) {
        [weakSelf hideControlsOverlay];
    }];
}

// =============================================================================
// MARK: Controls
// =============================================================================

// Single source of truth for control frames, run on every overlay layout pass
// (bounds changes from pinch/double-tap/rotation) and from syncControlIcons.
//
// Geometry: close/mute pin to the top corners (hit rects end at y=40). The
// center row (play/pause, optionally flanked by the skip buttons) is sized
// down on short cards and lowered just enough that the skip buttons' hit
// rects clear the corner buttons' — at the default ~165x93 card a centered
// 40pt row would reach y=26, deep into the corners' band. When even that
// can't fit collision-free (very short/narrow cards), the skip buttons hide
// and the layout reverts to the original lone centered play/pause.
- (void)layoutOverlayControls {
    UIView *overlay = self.controlsOverlay;
    if (!overlay) return;
    CGFloat w = overlay.bounds.size.width, h = overlay.bounds.size.height;
    if (w < 1 || h < 1) return;

    self.closeButton.frame = CGRectMake(6, 6, 34, 34);
    self.muteButton.frame = CGRectMake(w - 40, 6, 34, 34);
    // A silent GIF has no audio to toggle — hide the mute control for it (also
    // avoids an unmute tap spuriously claiming the Playback session).
    self.muteButton.hidden = self.cardIsGifContent;
    self.progressTrack.frame = CGRectMake(10, h - 9, w - 20, 3);
    [self syncProgressAnimation]; // re-fit the fill (and its animation) to the new track width

    BOOL compact = h < 120; // short card: shrink the row to make room
    CGFloat ppSize = (sPiPSkipButtons && compact) ? 44 : 52;
    CGFloat skipSize = compact ? 36 : 40;

    BOOL showSkips = sPiPSkipButtons;
    CGFloat rowCenterY = h / 2;
    CGFloat offset = ppSize / 2 + 8 + skipSize / 2; // skip-button center to card center
    if (showSkips) {
        CGFloat minRowCenterY = 42 + skipSize / 2;    // skips clear of close/mute (y <= 40)
        CGFloat maxRowCenterY = h - 4 - ppSize / 2;   // row fully on the card
        CGFloat maxOffset = w / 2 - 6 - skipSize / 2; // skips fully on the card
        if (rowCenterY < minRowCenterY) rowCenterY = minRowCenterY;
        if (offset > maxOffset) offset = maxOffset;
        if (rowCenterY > maxRowCenterY || offset < ppSize / 2 + 2 + skipSize / 2) {
            // No collision-free room — drop the skips, restore the lone
            // centered play/pause.
            showSkips = NO;
            ppSize = 52;
            rowCenterY = h / 2;
        }
    }

    self.playPauseButton.frame = CGRectMake(w / 2 - ppSize / 2, rowCenterY - ppSize / 2,
                                            ppSize, ppSize);
    self.skipBackButton.hidden = !showSkips;
    self.skipForwardButton.hidden = !showSkips;
    if (showSkips) {
        self.skipBackButton.frame = CGRectMake(w / 2 - offset - skipSize / 2,
                                               rowCenterY - skipSize / 2, skipSize, skipSize);
        self.skipForwardButton.frame = CGRectMake(w / 2 + offset - skipSize / 2,
                                                  rowCenterY - skipSize / 2, skipSize, skipSize);
    }
}

- (void)applyProgressFraction {
    CGRect bounds = self.progressTrack.bounds;
    self.progressFill.frame = CGRectMake(0, 0, bounds.size.width * self.progressFraction,
                                         bounds.size.height);
}

// Continuous progress: rather than stepping the fill once per observer tick,
// park the model at the true position and run ONE linear animation to the
// track's end paced at the player's rate — Core Animation then advances the
// bar every frame. Re-synced (cheaply: cancel + restart from ground truth)
// on every tick, seek, rate change, and layout pass, so drift from stalls or
// resizes never exceeds one correction interval.
- (void)syncProgressAnimation {
    UIView *fill = self.progressFill;
    if (!fill) return;
    [fill.layer removeAllAnimations];
    [self applyProgressFraction]; // model at the true (player-time) position

    if (!sPiPProgressBar || self.progressTrack.hidden || self.controlsOverlay.hidden) return;

    AVPlayer *player = self.player;
    AVPlayerItem *item = player.currentItem;
    if (!player || player.rate <= 0 || !item || !CMTIME_IS_NUMERIC(item.duration)) return;
    // rate is the DESIRED rate — during a rebuffer it stays 1.0 while media
    // time is frozen (timeControlStatus == waiting), and neither the media-
    // time-paced observer nor the rate KVO fires. Animating then would march
    // the bar over a frozen video; stay static until actually playing (the
    // timeControlStatus KVO re-syncs on the stall/resume transitions).
    if (player.timeControlStatus != AVPlayerTimeControlStatusPlaying) return;
    CGFloat duration = CMTimeGetSeconds(item.duration);
    if (duration <= 0) return;
    CGFloat remaining = (duration - CMTimeGetSeconds(item.currentTime)) / player.rate;
    if (remaining <= 0.05) return; // the end notification re-syncs via the time-jump tick

    CGRect bounds = self.progressTrack.bounds;
    CGRect fullFrame = CGRectMake(0, 0, bounds.size.width, bounds.size.height);
    [UIView animateWithDuration:remaining
                          delay:0
                        options:UIViewAnimationOptionCurveLinear
                     animations:^{
        fill.frame = fullFrame;
    } completion:nil];
}

- (void)syncControlIcons {
    UIImageSymbolConfiguration *bigConfig =
        [UIImageSymbolConfiguration configurationWithPointSize:26 weight:UIImageSymbolWeightSemibold];
    UIImageSymbolConfiguration *smallConfig =
        [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];

    BOOL playing = self.player.rate != 0;
    [self.playPauseButton setImage:[UIImage systemImageNamed:(playing ? @"pause.fill" : @"play.fill")
                                           withConfiguration:bigConfig]
                          forState:UIControlStateNormal];

    BOOL muted = self.player.muted;
    [self.muteButton setImage:[UIImage systemImageNamed:(muted ? @"speaker.slash.fill" : @"speaker.wave.2.fill")
                                      withConfiguration:smallConfig]
                     forState:UIControlStateNormal];

    // Optional extras (settings-gated, re-read on every overlay reveal so
    // settings changes apply to a live card). Skip-button visibility and all
    // frames are owned by the layout pass.
    [self layoutOverlayControls];
    if (sPiPSkipButtons) {
        UIImageSymbolConfiguration *mediumConfig =
            [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold];
        // Numbered glyphs exist for every offered amount (5/10/15/30); plain
        // gobackward/goforward is a just-in-case fallback.
        UIImage *backImage = [UIImage systemImageNamed:[NSString stringWithFormat:@"gobackward.%ld", (long)sPiPSkipSeconds]
                                      withConfiguration:mediumConfig]
            ?: [UIImage systemImageNamed:@"gobackward" withConfiguration:mediumConfig];
        UIImage *forwardImage = [UIImage systemImageNamed:[NSString stringWithFormat:@"goforward.%ld", (long)sPiPSkipSeconds]
                                         withConfiguration:mediumConfig]
            ?: [UIImage systemImageNamed:@"goforward" withConfiguration:mediumConfig];
        [self.skipBackButton setImage:backImage forState:UIControlStateNormal];
        [self.skipForwardButton setImage:forwardImage forState:UIControlStateNormal];
    }

    self.progressTrack.hidden = !sPiPProgressBar;
    if (sPiPProgressBar) [self updateProgressBar];
}

// Read-only progress strip: filled fraction = currentTime / duration,
// animated continuously between corrections (see syncProgressAnimation).
// Called from the periodic time observer while the overlay is showing, plus
// one-shot refreshes on reveal, rate changes, and after seeks.
- (void)updateProgressBar {
    AVPlayerItem *item = self.player.currentItem;
    CGFloat fraction = 0;
    if (item && CMTIME_IS_NUMERIC(item.duration)) {
        CGFloat duration = CMTimeGetSeconds(item.duration);
        if (duration > 0) {
            fraction = CMTimeGetSeconds(item.currentTime) / duration;
            fraction = MAX(0.0, MIN(1.0, fraction));
        }
    }
    self.progressFraction = fraction;
    [self syncProgressAnimation];
}

- (void)skipBackTapped {
    [self seekBySeconds:-(NSTimeInterval)sPiPSkipSeconds];
}

- (void)skipForwardTapped {
    [self seekBySeconds:(NSTimeInterval)sPiPSkipSeconds];
}

// Relative seek for the skip buttons. Plain AVPlayer seek on the shared
// player — the same operation Apollo's fullscreen scrubber performs — so
// inline state stays consistent. Play/pause state is deliberately untouched
// (system PiP behaves the same way).
- (void)seekBySeconds:(NSTimeInterval)offset {
    AVPlayer *player = self.player;
    AVPlayerItem *item = player.currentItem;
    if (!player || !item) return;

    CGFloat target = CMTimeGetSeconds(item.currentTime) + offset;
    if (target < 0) target = 0;
    if (CMTIME_IS_NUMERIC(item.duration)) {
        CGFloat duration = CMTimeGetSeconds(item.duration);
        // Land forward skips just SHORT of the end, never exactly on it: a
        // seek-to-end on a PAUSED player posts no end notification, so with
        // Loop ON neither Apollo's loop nor anything else would ever move the
        // playhead again and play() would no-op — a dead play button. From
        // duration-0.1 a subsequent play() reaches the end normally and both
        // loop paths behave (loop on replays via didPlayToEnd, loop off parks
        // via the suppression hook + the play button's replay handling).
        if (duration > 0 && target > duration - 0.1) target = MAX(0, duration - 0.1);
    }
    // Zero tolerance: skips land exactly where the label promises (the
    // periodic time observer also fires on the jump, updating the bar).
    [player seekToTime:CMTimeMakeWithSeconds(target, 600)
       toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    [self restartControlsTimer];
}

- (void)playPauseTapped {
    AVPlayer *player = self.player;
    if (!player) return;
    if (player.rate != 0) {
        [player pause];
    } else {
        // With looping off, a finished video is parked at the end; tapping play
        // should replay it from the start rather than no-op at the last frame.
        // Gated on Loop being off so a video the user merely paused near the
        // end (loop on) resumes from the pause point instead of rewinding.
        // Exception: parked at the EXACT end (a paused seek-to-end — system
        // PiP's own skip controls can do this), play() is a dead no-op with
        // either loop setting, so always rewind from there.
        if ((!sPiPLoop && PiPPlayerStoppedAtEnd(player)) || PiPPlayerParkedAtExactEnd(player)) {
            [player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
        }
        [player play];
    }
    [self restartControlsTimer];
}

- (void)muteTapped {
    AVPlayer *player = self.player;
    if (!player) return;
    if (player.muted) {
        // Unmute: session must be Playback + active first — Apollo's default
        // Ambient silences AVPlayer audio even with muted == NO (mirrors the
        // native unmute sub_100341894).
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setCategory:AVAudioSessionCategoryPlayback
                        mode:AVAudioSessionModeDefault options:0 error:nil];
        [session setActive:YES withOptions:0 error:nil];
        [player setMuted:NO];
        self.sessionClaimedAudibly = YES;
        if (self.richMediaNode) ApolloVideoUnmute_SyncMuteButtonIcon(self.richMediaNode, NO);
    } else {
        BOOL wasPlaying = player.rate != 0;
        ApolloVideoUnmute_ClearProtectionIfPlayer(player);
        [player setMuted:YES];
        if (self.richMediaNode) ApolloVideoUnmute_SyncMuteButtonIcon(self.richMediaNode, YES);
        // Deliberately do NOT touch the audio session here. Deactivating it —
        // even after a synchronous pause — raises an ASYNC media-services
        // interruption that would re-pause the player a beat later. The session
        // is handed back when the PiP closes (after a real pause);
        // sessionClaimedAudibly stays set for that.
        if (wasPlaying) {
            // Safety net: if anything (interruption, dance stragglers) paused
            // the player right after the mute, resume it.
            NSUInteger generation = self.generation;
            __weak __typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                __typeof(self) strongSelf = weakSelf;
                if (!strongSelf || !strongSelf.active || strongSelf.generation != generation) return;
                AVPlayer *current = strongSelf.player;
                if (current && current.rate == 0) {
                    ApolloLog(@"[PiP] muteTapped: player got paused ~150ms after mute — resuming");
                    [current play];
                }
            });
        }
    }
    [self restartControlsTimer];
}

- (void)closeTapped {
    if (self.restoring) return;
    if (!self.cardRevealed) {
        [self teardownKeepPlaying:NO];
        return;
    }
    // Quick shrink-and-fade before teardown — reuse the restoring guards so
    // gestures/visibility events can't interfere mid-animation.
    self.restoring = YES;
    self.card.userInteractionEnabled = NO;
    [self cancelAnimator];
    [self hideControlsOverlay];
    __weak __typeof(self) weakSelf = self;
    UIViewPropertyAnimator *animator =
        [[UIViewPropertyAnimator alloc] initWithDuration:0.2
                                                   curve:UIViewAnimationCurveEaseIn
                                              animations:^{
            weakSelf.card.alpha = 0.0;
            weakSelf.card.transform = CGAffineTransformMakeScale(0.85, 0.85);
        }];
    [animator addCompletion:^(UIViewAnimatingPosition finalPosition) {
        [weakSelf teardownKeepPlaying:NO];
    }];
    self.animator = animator;
    [animator startAnimation];
}

// =============================================================================
// MARK: Player observation
// =============================================================================

- (void)installPlayerObservers {
    [self removePlayerObservers];
    AVPlayer *player = self.player;
    if (!player) return;
    [player addObserver:self forKeyPath:@"rate"
                options:NSKeyValueObservingOptionNew context:kPiPRateContext];
    [player addObserver:self forKeyPath:@"muted"
                options:NSKeyValueObservingOptionNew context:kPiPMutedContext];
    // Stall/resume transitions (rebuffering keeps rate at 1.0 while media time
    // freezes) — re-sync the progress animation so it never animates a stall.
    [player addObserver:self forKeyPath:@"timeControlStatus"
                options:NSKeyValueObservingOptionNew context:kPiPTimeControlContext];
    [self.playerView.playerLayer addObserver:self forKeyPath:@"readyForDisplay"
                                     options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial
                                     context:kPiPReadyContext];

    // Progress-bar ticks (4 Hz, also fired on seeks/time jumps). Installed
    // unconditionally while PiP is active so toggling the setting mid-session
    // just works; the block is a near-free early-out when not needed.
    __weak __typeof(self) weakSelf = self;
    self.timeObserverToken = [player addPeriodicTimeObserverForInterval:CMTimeMake(1, 4)
                                                                  queue:dispatch_get_main_queue()
                                                             usingBlock:^(CMTime time) {
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.active) return;
        if (!sPiPProgressBar || strongSelf.controlsOverlay.hidden) return;
        [strongSelf updateProgressBar];
    }];

    self.observedPlayer = player;
    self.observingPlayer = YES;
}

- (void)removePlayerObservers {
    if (!self.observingPlayer) return;
    if (self.timeObserverToken) {
        @try {
            [self.observedPlayer removeTimeObserver:self.timeObserverToken];
        } @catch (NSException *exception) {
            ApolloLog(@"[PiP] removeTimeObserver exception: %@", exception);
        }
        self.timeObserverToken = nil;
    }
    @try {
        [self.observedPlayer removeObserver:self forKeyPath:@"rate" context:kPiPRateContext];
        [self.observedPlayer removeObserver:self forKeyPath:@"muted" context:kPiPMutedContext];
        [self.observedPlayer removeObserver:self forKeyPath:@"timeControlStatus" context:kPiPTimeControlContext];
        [self.playerView.playerLayer removeObserver:self forKeyPath:@"readyForDisplay" context:kPiPReadyContext];
    } @catch (NSException *exception) {
        ApolloLog(@"[PiP] removeObserver exception: %@", exception);
    }
    self.observedPlayer = nil;
    self.observingPlayer = NO;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    if (context == kPiPRateContext || context == kPiPMutedContext) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.active && !self.controlsOverlay.hidden) [self syncControlIcons];
        });
        return;
    }
    if (context == kPiPTimeControlContext) {
        // Stall began or playback resumed: freeze the bar at ground truth /
        // restart the linear animation. Only matters while the bar is showing.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.active && sPiPProgressBar && !self.controlsOverlay.hidden) {
                [self updateProgressBar];
            }
        });
        return;
    }
    if (context == kPiPReadyContext) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.active && self.playerView.playerLayer.readyForDisplay) {
                [self revealCard];
            }
        });
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

// =============================================================================
// MARK: Native (system) PiP — optional handoff on app exit
// =============================================================================

- (void)setupNativePiP {
    if (@available(iOS 15.0, *)) {
        if (self.nativePiP) return;
        if (![AVPictureInPictureController isPictureInPictureSupported]) {
            ApolloLog(@"[PiP] Native PiP not supported on this device");
            return;
        }

        // Audible card (sessionClaimedAudibly, race-proof unlike raw
        // player.muted): re-assert the exclusive claim its unmute already
        // holds — a no-op re-set, never a fresh interruption. Muted/GIF cards:
        // mixable claim, only when no other audio is playing (music wins;
        // mirrors the inline arm). Must precede controller creation — AVKit
        // never auto-starts an Ambient-born controller.
        AVAudioSession *session = [AVAudioSession sharedInstance];
        if (self.sessionClaimedAudibly) {
            [session setCategory:AVAudioSessionCategoryPlayback
                            mode:AVAudioSessionModeDefault options:0 error:nil];
            [session setActive:YES withOptions:0 error:nil];
        } else if (![session.category isEqualToString:AVAudioSessionCategoryPlayback]
                   && !session.isOtherAudioPlaying) {
            PiPClaimMixablePlaybackSession();
        }

        AVPictureInPictureControllerContentSource *source =
            [[AVPictureInPictureControllerContentSource alloc] initWithPlayerLayer:self.playerView.playerLayer];
        AVPictureInPictureController *controller =
            [[AVPictureInPictureController alloc] initWithContentSource:source];
        controller.delegate = (id<AVPictureInPictureControllerDelegate>)self;
        controller.canStartPictureInPictureAutomaticallyFromInline = YES;
        self.nativePiP = controller;
        self.nativePiPBornUnderPlayback =
            [[AVAudioSession sharedInstance].category isEqualToString:AVAudioSessionCategoryPlayback];
        ApolloLog(@"[PiP] Native PiP controller armed (auto-start on background, playbackBorn=%d)",
                  (int)self.nativePiPBornUnderPlayback);
    }
}

- (void)destroyNativePiP {
    if (@available(iOS 15.0, *)) {
        AVPictureInPictureController *controller = self.nativePiP;
        if (!controller) return;
        if (controller.pictureInPictureActive) {
            [controller stopPictureInPicture];
        }
        controller.delegate = nil;
        self.nativePiP = nil;
    }
}

// ---------------------------------------------------------------------------
// Inline-playback native PiP: armed on Apollo's OWN inline AVPlayerLayer while
// an eligible comments video plays on screen (no floating card involved), so
// swiping to the home screen mid-watch hands the inline video to system PiP.
//
// Scope: a back-pop DISARMS (the comments cell's Invisible event fires while
// the app is still active), so the controller never carries into the feed on
// its own. Feed videos arm only through the mute-button unmute path
// (ApolloPiP_NoteInlineVideoAudible) — deliberate engagement with one video.
// Untouched muted feed autoplay can therefore never reach system PiP.
// ---------------------------------------------------------------------------

- (BOOL)isInlineNativePiPActive {
    if (@available(iOS 15.0, *)) {
        return self.inlineNativePiP != nil && self.inlineNativePiP.pictureInPictureActive;
    }
    return NO;
}

- (void)armInlineNativePiPForVideoNode:(id)videoNode player:(AVPlayer *)player {
    if (@available(iOS 15.0, *)) {
        if (self.active) return; // the floating card's controller owns native PiP
        if (self.inlineNativePiP) {
            if (self.inlineNativePlayer == player) {
                // Already armed on this player — but rebind the bookkeeping node
                // if it changed. On a back-pop the shared layer is reclaimed from
                // the comments cell into the FEED cell (same AVPlayer, different
                // videoNode); refreshing the node keeps disarm decisions keyed on
                // the current cell, so the comments cell's later Invisible event
                // (which compares against inlineNativeVideoNode) no longer
                // disarms it out from under the feed.
                self.inlineNativeVideoNode = videoNode;
                // Heal an Ambient-born controller (music was playing at arm
                // time, so the claim was skipped and AVKit will never
                // auto-start it): if the audio has gone idle since — this
                // re-runs on every visibility tick — fall through to recreate
                // it under a proper claim.
                AVAudioSession *session = [AVAudioSession sharedInstance];
                if ([session.category isEqualToString:AVAudioSessionCategoryPlayback]
                    || session.isOtherAudioPlaying
                    || self.inlineNativePiP.pictureInPictureActive) {
                    return;
                }
                ApolloLog(@"[PiP] Audio idle now — recreating Ambient-born inline controller");
                [self disarmInlineNativePiPIfIdle];
            } else {
                if (self.inlineNativePiP.pictureInPictureActive) return; // never retarget mid-PiP
                [self disarmInlineNativePiPIfIdle];
            }
        }
        if (![AVPictureInPictureController isPictureInPictureSupported]) return;

        SEL playerLayerSel = NSSelectorFromString(@"playerLayer");
        if (![videoNode respondsToSelector:playerLayerSel]) return;
        id layer = ((id (*)(id, SEL))objc_msgSend)(videoNode, playerLayerSel);
        if (![layer isKindOfClass:[AVPlayerLayer class]]) return;

        // Claim BEFORE creating the controller — AVKit never auto-starts an
        // Ambient-born controller (device-confirmed: deferring the claim to
        // willResignActive/didEnterBackground produced no PiP). Only when no
        // other audio is playing: with music on, the muted video's System PiP
        // yields (the heals and claimHandoffSessionIfNeeded re-check once the
        // music stops).
        AVAudioSession *session = [AVAudioSession sharedInstance];
        if (![session.category isEqualToString:AVAudioSessionCategoryPlayback]
            && !session.isOtherAudioPlaying) {
            ApolloLog(@"[PiP] Inline arm: claiming Playback+Mix session (idle audio, was=%@)",
                      session.category);
            PiPClaimMixablePlaybackSession();
        }

        AVPictureInPictureControllerContentSource *source =
            [[AVPictureInPictureControllerContentSource alloc] initWithPlayerLayer:(AVPlayerLayer *)layer];
        AVPictureInPictureController *controller =
            [[AVPictureInPictureController alloc] initWithContentSource:source];
        controller.delegate = (id<AVPictureInPictureControllerDelegate>)self;
        controller.canStartPictureInPictureAutomaticallyFromInline = YES;
        self.inlineNativePiP = controller;
        self.inlineNativePlayer = player;
        self.inlineNativeVideoNode = videoNode;
        self.inlineNativePiPBornUnderPlayback =
            [[AVAudioSession sharedInstance].category isEqualToString:AVAudioSessionCategoryPlayback];
        ApolloLog(@"[PiP] Inline native PiP armed on player %p (playbackBorn=%d)",
                  player, (int)self.inlineNativePiPBornUnderPlayback);
    }
}

// Off-event retry for the fresh-navigation case: poll a few times until the
// player exists and is playing, then arm. Mirrors the unmute feature's 500ms
// player-not-ready retry (same underlying Apollo timing).
- (void)retryInlineArmForCell:(id)cellNode videoNode:(id)videoNode attempts:(NSUInteger)attempts {
    __weak id weakCell = cellNode;
    __weak id weakVideo = videoNode;
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __typeof(self) strongSelf = weakSelf;
        id cell = weakCell;
        id video = weakVideo;
        if (!strongSelf || !cell || !video) return;

        void (^finish)(void) = ^{
            objc_setAssociatedObject(cell, kPiPArmRetryPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        };

        if (!sPiPNativeEnabled || strongSelf.active) {
            finish();
            return;
        }
        AVPlayer *player = ApolloVideoUnmute_GetPlayerFromVideoNode(video);
        if (player && player.rate != 0) {
            // Deliberate-unmute gate, not raw player.muted — see the visibility
            // handler; the retry window (fresh player, +0.5–2s) is exactly when
            // muted reads NO for silent videos (issue #560).
            if (!(sPiPActivationMode == ApolloPiPActivationModeUnmutedOnly
                  && !PiPPlayerIsDeliberatelyAudible(player))
                && PiPIsEligibleForInlineNativePiP(video, player)
                && PiPIsVideoMidpointVisible(video, cell)) {
                ApolloLog(@"[PiP] Inline arm retry: player ready — arming");
                [strongSelf armInlineNativePiPForVideoNode:video player:player];
            }
            finish();
            return;
        }
        if (attempts > 1) {
            [strongSelf retryInlineArmForCell:cell videoNode:video attempts:attempts - 1];
        } else {
            ApolloLog(@"[PiP] Inline arm retry: player never became ready — giving up");
            finish();
        }
    });
}

- (void)disarmInlineNativePiPIfIdle {
    if (@available(iOS 15.0, *)) {
        AVPictureInPictureController *controller = self.inlineNativePiP;
        if (!controller) return;
        if (controller.pictureInPictureActive) return; // system PiP running — leave it
        controller.delegate = nil;
        self.inlineNativePiP = nil;
        self.inlineNativePlayer = nil;
        self.inlineNativeVideoNode = nil;
        ApolloLog(@"[PiP] Inline native PiP disarmed");
    }
}

- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)controller {
    ApolloLog(@"[PiP] Native PiP starting — hiding in-app card");
    self.card.hidden = YES;
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)controller {
    ApolloLog(@"[PiP] Native PiP stopped");
    // X-closed from the home screen (app still backgrounded): the handoff is
    // over and the player is stopped — release the handoff claim so music we
    // paused gets its resume cue now. A stop that restores into the app runs
    // after willEnterForeground already released it (no-op here).
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
        [self releaseHandoffSessionClaim];
    } else {
        // PiP collapsed back into the running app: the foreground release and
        // the didBecomeActive heal both ran while PiP was still active (the
        // heal skips then), leaving an armed controller on an Ambient session
        // — heal now that it's idle, or the next home-swipe gets no PiP.
        [self healAmbientBornControllersIfAudioIdle];
    }
    if (self.active && self.cardRevealed) self.card.hidden = NO;
    // Inline system PiP dismissed with the clip parked at its end (Loop off,
    // e.g. X-closed from the home screen — handleDidBecomeActive's rewind
    // only covers PiP still active at app activation): rewind so Apollo's
    // next inline play() isn't a dead no-op. No play() here — the app may
    // still be backgrounded.
    if (controller == self.inlineNativePiP) {
        PiPRewindIfStoppedAtEnd(self.inlineNativePlayer);
    }
}

- (void)pictureInPictureController:(AVPictureInPictureController *)controller
restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler {
    ApolloLog(@"[PiP] Native PiP restore requested — showing in-app card");
    if (self.active && self.cardRevealed) self.card.hidden = NO;
    completionHandler(YES);
}

- (void)pictureInPictureController:(AVPictureInPictureController *)controller
    failedToStartPictureInPictureWithError:(NSError *)error {
    ApolloLog(@"[PiP] Native PiP failed to start: %@", error);
}

// =============================================================================
// MARK: App lifecycle
// =============================================================================

// Resign-time re-check of the handoff session (issue #560). Auto-start needs
// an ACTIVE Playback session when iOS evaluates the handoff (between
// willResignActive and didEnterBackground — the latter is too late,
// device-confirmed), but a claim must interrupt nobody:
//   • exclusive Playback held (deliberate unmute): already active — skip.
//   • mixable Playback standing (our earlier claim): re-activate — harmless
//     on an already-Playback session (device-confirmed).
//   • Ambient + no other audio: flip + activate — interrupts no one.
//   • Ambient + other audio: SKIP — the muted video's PiP yields to the
//     user's music (the OS won't allow both; unmuted videos still PiP via
//     their unmute's own claim).
- (void)claimHandoffSessionIfNeeded {
    if (@available(iOS 15.0, *)) {
        BOOL inlineCandidate = self.inlineNativePiP != nil
            && self.inlineNativePlayer != nil && self.inlineNativePlayer.rate != 0;
        BOOL cardCandidate = self.active && sPiPNativeEnabled && self.nativePiP != nil
            && self.player != nil && self.player.rate != 0;
        if (!inlineCandidate && !cardCandidate) return;

        AVAudioSession *session = [AVAudioSession sharedInstance];
        if ([session.category isEqualToString:AVAudioSessionCategoryPlayback]) {
            if (!(session.categoryOptions & AVAudioSessionCategoryOptionMixWithOthers)) {
                return; // exclusive claim held by a deliberate unmute — already active
            }
            ApolloLog(@"[PiP] Resign with %@ handoff candidate — re-activating standing Playback+Mix session",
                      inlineCandidate ? @"inline" : @"card");
            [session setActive:YES withOptions:0 error:nil];
            self.handoffSessionClaimed = YES;
            return;
        }
        if (session.isOtherAudioPlaying) {
            ApolloLog(@"[PiP] Resign with %@ handoff candidate — other audio playing, NOT claiming (muted-video PiP yields to the user's audio)",
                      inlineCandidate ? @"inline" : @"card");
            return;
        }
        ApolloLog(@"[PiP] Resign with %@ handoff candidate — claiming Playback+Mix session (no other audio, was=%@)",
                  inlineCandidate ? @"inline" : @"card", session.category);
        PiPClaimMixablePlaybackSession();
        self.handoffSessionClaimed = YES;

        // Recreate an AMBIENT-born controller under the fresh claim.
        // Best-effort only: AVKit needs runloop time after birth to allow
        // auto-start (a resign-time rebuild logged possible=0), so the heals
        // are the real fix — this catches audio that went idle in the final
        // moments. A PLAYBACK-born controller whose session merely dipped
        // (mute dance after a re-mute) stays viable: the claim above suffices,
        // and destroying it would swap a working controller for a doomed one.
        if (inlineCandidate && !self.inlineNativePiPBornUnderPlayback) {
            id videoNode = self.inlineNativeVideoNode;
            AVPlayer *player = self.inlineNativePlayer;
            [self disarmInlineNativePiPIfIdle];
            [self armInlineNativePiPForVideoNode:videoNode player:player];
            ApolloLog(@"[PiP] Recreated Ambient-born inline controller after late claim (possible=%d)",
                      (int)self.inlineNativePiP.isPictureInPicturePossible);
        } else if (cardCandidate && !self.nativePiPBornUnderPlayback) {
            [self destroyNativePiP];
            [self setupNativePiP];
            ApolloLog(@"[PiP] Recreated Ambient-born card controller after late claim (possible=%d)",
                      (int)self.nativePiP.isPictureInPicturePossible);
        }
    }
}

// Hand back a handoff claim that no longer serves anything (System PiP never
// started, or was closed from the home screen): the fresh activation can have
// paused the user's music (see claimHandoffSessionIfNeeded), and only a
// deactivation with NotifyOthersOnDeactivation gives it the resume cue.
- (void)releaseHandoffSessionClaim {
    if (!self.handoffSessionClaimed) return;
    self.handoffSessionClaimed = NO;
    // Only ours to release: a deliberate unmute may have claimed the session
    // exclusively since we activated (its lifecycle belongs to Apollo's mute
    // dance, not to us) — never downgrade a non-mixable Playback session.
    AVAudioSession *current = [AVAudioSession sharedInstance];
    if (![current.category isEqualToString:AVAudioSessionCategoryPlayback]
        || !(current.categoryOptions & AVAudioSessionCategoryOptionMixWithOthers)) {
        return;
    }
    sPiPSessionHandbackInProgress = YES;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryAmbient error:nil];
    [session setActive:NO
           withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                 error:nil];
    sPiPSessionHandbackInProgress = NO;
    ApolloLog(@"[PiP] Handoff session claim released");
}

- (void)handleDidEnterBackground {
    self.enteredBackground = YES;
    // Inline-only System PiP (no card): nothing pauses the inline player here —
    // we rely on iOS auto-starting system PiP. If it doesn't (the user's "Start
    // PiP Automatically" is off, low power, iOS declines, etc.) the inline
    // player would keep playing audible video in the background with no PiP
    // window and no UI to stop it (the shield suppresses the mute dance). Check
    // shortly after backgrounding and pause if PiP never actually started.
    if (@available(iOS 15.0, *)) {
        if (!self.active && self.inlineNativePiP && self.inlineNativePlayer
            && self.inlineNativePlayer.rate != 0) {
            __weak __typeof(self) weakSelf = self;
            __weak AVPlayer *weakInline = self.inlineNativePlayer;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                __typeof(self) strongSelf = weakSelf;
                AVPlayer *inlinePlayer = weakInline;
                if (!strongSelf || !inlinePlayer) return;
                if (strongSelf.inlineNativePiP.pictureInPictureActive) return; // PiP took over — fine
                if ([UIApplication sharedApplication].applicationState != UIApplicationStateBackground) return; // user already returned — don't pause a foreground video
                if (inlinePlayer.rate == 0) return;
                ApolloLog(@"[PiP] Inline System PiP never started on background — pausing to avoid background audio");
                strongSelf.backgroundPausedInlinePlayer = inlinePlayer;
                strongSelf.backgroundPausedInlineWasAudible = PiPPlayerIsDeliberatelyAudible(inlinePlayer);
                [inlinePlayer pause];
                // The handoff has definitively failed: drop the shield and —
                // for an audible video — hand the Playback session back so
                // audio we interrupted (the user's music) gets its resume cue
                // now rather than whenever Apollo is next opened. Mirrors the
                // card-close handback in teardownKeepPlaying:. Foreground
                // resume re-claims the session (handleWillEnterForeground);
                // the controller re-arms on the next visibility tick/unmute.
                [strongSelf disarmInlineNativePiPIfIdle];
                // Keyed on the captured deliberate-audibility, not raw
                // player.muted — a silent fresh player reads muted == NO but
                // never held exclusive focus, so there is nothing to hand back
                // (its claim was mixable).
                if (strongSelf.backgroundPausedInlineWasAudible) {
                    ApolloVideoUnmute_ClearProtectionIfPlayer(inlinePlayer);
                    AVAudioSession *session = [AVAudioSession sharedInstance];
                    [session setCategory:AVAudioSessionCategoryAmbient error:nil];
                    [session setActive:NO
                           withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                 error:nil];
                }
                // Muted counterpart (mutually exclusive with the audible
                // handback above).
                [strongSelf releaseHandoffSessionClaim];
            });
        }
    }

    if (!self.active) return;
    BOOL nativeMayTakeOver = NO;
    if (@available(iOS 15.0, *)) {
        nativeMayTakeOver = sPiPNativeEnabled && self.nativePiP != nil;
    }
    if (nativeMayTakeOver) {
        // Don't pause synchronously — System PiP may be auto-starting (WWDC19
        // 503). But iOS can decline auto-start ("Start PiP Automatically" off,
        // low power), and then nothing stops the card's player — an unmuted card
        // keeps playing audibly in the background with no PiP window. Failsafe
        // (mirrors the inline path): pause shortly after if PiP never started.
        if (@available(iOS 15.0, *)) {
            __weak __typeof(self) weakSelf = self;
            __weak AVPlayer *weakCardPlayer = self.player;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                __typeof(self) strongSelf = weakSelf;
                AVPlayer *cardPlayer = weakCardPlayer;
                if (!strongSelf || !cardPlayer) return;
                // Card gone or took over a different player — nothing to pause.
                if (!strongSelf.active || strongSelf.player != cardPlayer) return;
                if ([UIApplication sharedApplication].applicationState != UIApplicationStateBackground) return;
                if (strongSelf.nativePiP.pictureInPictureActive) return; // PiP took over — fine
                if (cardPlayer.rate == 0) return; // already paused
                ApolloLog(@"[PiP] Card System PiP never started on background — pausing to avoid background audio");
                strongSelf.resumeOnForeground = YES;
                [cardPlayer pause];
                // Handoff failed and the card just went silent: if it held
                // audio focus, hand the session back now so interrupted music
                // gets its resume cue (mirrors the inline failsafe).
                // sessionClaimedAudibly stays set — the foreground path
                // re-claims, and teardown's later handback is a no-op.
                if (strongSelf.sessionClaimedAudibly) {
                    ApolloVideoUnmute_ClearProtectionIfPlayer(cardPlayer);
                    // Bypass our own downgrade-blocking predicate (card still active).
                    sPiPSessionHandbackInProgress = YES;
                    AVAudioSession *session = [AVAudioSession sharedInstance];
                    [session setCategory:AVAudioSessionCategoryAmbient error:nil];
                    [session setActive:NO
                           withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                 error:nil];
                    sPiPSessionHandbackInProgress = NO;
                    ApolloLog(@"[PiP] Card handoff failed — audio session handed back");
                }
                // Muted/GIF card counterpart (mutually exclusive with the
                // audible handback above).
                [strongSelf releaseHandoffSessionClaim];
            });
        }
        return;
    }
    if (self.player.rate != 0) {
        ApolloLog(@"[PiP] App backgrounded without native PiP — pausing");
        self.resumeOnForeground = YES;
        [self.player pause];
    }
}

- (void)handleWillEnterForeground {
    // Back in the app: a handoff claim no longer serves anything (whether PiP
    // ran and is collapsing back in, or the background trip was too brief for
    // the failsafe) — release it so paused music resumes. The deactivation can
    // raise an async media-services interruption that pauses the still-playing
    // inline player (same hazard muteTapped documents), so nudge it back.
    if (self.handoffSessionClaimed) {
        AVPlayer *armedPlayer = self.inlineNativePlayer ?: self.player;
        BOOL wasPlaying = armedPlayer.rate != 0;
        [self releaseHandoffSessionClaim];
        if (armedPlayer && wasPlaying) {
            __weak AVPlayer *weakArmed = armedPlayer;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                AVPlayer *p = weakArmed;
                if (p && p.rate == 0) {
                    ApolloLog(@"[PiP] Handoff release paused the inline player — resuming");
                    [p play];
                }
            });
        }
    }
    if (self.active && self.resumeOnForeground) {
        ApolloLog(@"[PiP] App foregrounded — resuming");
        self.resumeOnForeground = NO;
        // The background failsafe handed an audible card's session back —
        // re-claim before resuming or the card comes back silent (Ambient
        // silences AVPlayer audio even unmuted). !muted guards the re-muted
        // card: it keeps sessionClaimedAudibly by design, but an exclusive
        // re-claim for a silent card would re-pause the just-resumed music
        // (muted == YES is the reliable direction of that flag).
        if (self.sessionClaimedAudibly && !self.player.muted) {
            AVAudioSession *session = [AVAudioSession sharedInstance];
            [session setCategory:AVAudioSessionCategoryPlayback
                            mode:AVAudioSessionModeDefault options:0 error:nil];
            [session setActive:YES withOptions:0 error:nil];
        }
        [self.player play];
    }
    // Resume an inline player we paused because System PiP didn't start. The
    // failed-handoff cleanup handed the audio session back (Ambient, which
    // silences AVPlayer audio even unmuted) — re-claim Playback first so an
    // audible video comes back audible.
    AVPlayer *pausedInline = self.backgroundPausedInlinePlayer;
    if (pausedInline) {
        BOOL wasAudible = self.backgroundPausedInlineWasAudible;
        self.backgroundPausedInlinePlayer = nil;
        self.backgroundPausedInlineWasAudible = NO;
        if (pausedInline.rate == 0) {
            // Exclusive re-claim only if the video deliberately held audio
            // focus before the failed handoff (captured flag — a silent fresh
            // player reads muted == NO and must not interrupt the user's
            // music; issue #560).
            if (wasAudible) {
                AVAudioSession *session = [AVAudioSession sharedInstance];
                [session setCategory:AVAudioSessionCategoryPlayback
                                mode:AVAudioSessionModeDefault options:0 error:nil];
                [session setActive:YES withOptions:0 error:nil];
            }
            [pausedInline play];
        }
    }
}

// Returning to Apollo via the app icon or switcher (not the PiP restore
// button) leaves system PiP floating over the app — collapse it back into
// the app instead, the way native players do. The stop runs the normal
// restore/didStop delegate flow: the floating card un-hides, or the inline
// layer simply resumes rendering. (When the user DID use the restore button,
// PiP is already stopping by the time this fires and the extra stop is a
// no-op.)
// Recreate an Ambient-born controller (claim skipped because music was
// playing; AVKit will never auto-start it) once the audio goes idle.
// Visibility ticks cover scrolling; this covers the no-scroll paths — called
// from didBecomeActive (pausing music via Control Center bounces
// resign→active) and from a PiP stop while the app is active.
- (void)healAmbientBornControllersIfAudioIdle {
    if (@available(iOS 15.0, *)) {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        if ([session.category isEqualToString:AVAudioSessionCategoryPlayback]) return;
        if (session.isOtherAudioPlaying) return;

        if (self.inlineNativePiP && !self.inlineNativePiP.pictureInPictureActive
            && self.inlineNativePlayer && self.inlineNativePlayer.rate != 0
            && self.inlineNativeVideoNode) {
            ApolloLog(@"[PiP] Audio idle on activate — recreating Ambient-born inline controller");
            id videoNode = self.inlineNativeVideoNode;
            AVPlayer *player = self.inlineNativePlayer;
            [self disarmInlineNativePiPIfIdle];
            [self armInlineNativePiPForVideoNode:videoNode player:player];
        } else if (self.active && sPiPNativeEnabled && self.nativePiP
                   && !self.nativePiP.pictureInPictureActive
                   && self.player && self.player.rate != 0) {
            ApolloLog(@"[PiP] Audio idle on activate — recreating Ambient-born card controller");
            [self destroyNativePiP];
            [self setupNativePiP];
        }
    }
}

- (void)handleDidBecomeActive {
    // A resign→active bounce (Control Center, alert) never fires
    // willEnterForeground, so its claim's flag would linger and make a LATER
    // real background cycle spuriously release the session. Downgrade to an
    // ordinary standing claim (mixable, harmless).
    if (self.handoffSessionClaimed && !self.enteredBackground) {
        ApolloLog(@"[PiP] Resign bounce without backgrounding — keeping session, clearing handoff flag");
        self.handoffSessionClaimed = NO;
    }
    self.enteredBackground = NO;
    [self healAmbientBornControllersIfAudioIdle];
    if (@available(iOS 15.0, *)) {
        if (self.nativePiP.pictureInPictureActive) {
            ApolloLog(@"[PiP] App active with card system PiP still running — dismissing into app");
            [self.nativePiP stopPictureInPicture];
        }
        if (self.inlineNativePiP.pictureInPictureActive) {
            ApolloLog(@"[PiP] App active with inline system PiP still running — dismissing into app");
            [self.inlineNativePiP stopPictureInPicture];
            // If the clip ended during system PiP (Loop off), the inline player
            // is parked at its last frame; rewind and resume so inline looping
            // continues instead of freezing. (Player rate/time are independent
            // of the PiP stop animation, so this is safe to check now.)
            AVPlayer *inlinePlayer = self.inlineNativePlayer;
            if (PiPPlayerStoppedAtEnd(inlinePlayer)) {
                [inlinePlayer seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
                [inlinePlayer play];
            }
        }
    }
}

@end

// =============================================================================
// MARK: - Exported C API (consumed by ApolloVideoUnmute.xm and hooks below)
// =============================================================================

BOOL ApolloPiP_HandleCommentsVisibilityEvent(id cellNode, id richMediaNode,
                                             unsigned long long event) {
    ApolloPiPController *controller = sPiPSharedController;
    // Don't spin up the singleton until at least one capability is enabled
    // (or one is already active).
    if (!controller && !sPiPEnabled && !sPiPNativeEnabled) return NO;
    return [[ApolloPiPController sharedController] handleVisibilityEventForCell:cellNode
                                                                  richMediaNode:richMediaNode
                                                                          event:event];
}

BOOL ApolloPiP_IsOwnedPlayer(AVPlayer *player) {
    ApolloPiPController *controller = sPiPSharedController;
    return controller && controller.active && player && controller.player == player;
}

// Loop kill-switch. The inline video's auto-repeat is driven solely by
// -[ASVideoNode didPlayToEnd:] (a per-item observer on the feed node that
// seeks to zero and replays). Returns YES when that handler should be
// suppressed for this item: when "Loop Videos" is off AND the item is the one
// a PiP mode is actively presenting (the floating card, or system PiP). The
// player then pauses at the end on its own (actionAtItemEnd defaults to Pause)
// and nothing restarts it. Only applies while ACTIVELY presenting — a video
// merely playing inline (even with System PiP armed) keeps looping normally.
BOOL ApolloPiP_ShouldSuppressLoopForItem(AVPlayerItem *item) {
    if (sPiPLoop || !item) return NO;
    ApolloPiPController *controller = sPiPSharedController;
    if (!controller) return NO;
    // In-app card presenting this player (covers the card and its system PiP).
    if (controller.active && controller.player && controller.player.currentItem == item) {
        // GIFs always loop in PiP regardless of the Loop Videos setting; other
        // content honors the (off) setting and stops at its end.
        return !controller.cardIsGifContent;
    }
    // Inline-armed system PiP actively showing this player. A Reddit .gif-as-MP4
    // is strictly eligible (silent audio track) so it can arm here too; keep it
    // looping. URL-only GIF check — the only GIFs that arm inline are URL-GIFs.
    if (@available(iOS 15.0, *)) {
        if (controller.inlineNativePiP.pictureInPictureActive
            && controller.inlineNativePlayer
            && controller.inlineNativePlayer.currentItem == item) {
            return !PiPNodeURLIsGif(controller.inlineNativeVideoNode, controller.inlineNativePlayer);
        }
    }
    return NO;
}

// Shield for the INLINE-armed native-PiP player. When the app backgrounds (or
// system PiP is already running), the window/hierarchy churn (privacy padlock
// etc.) can fire TouchHintVideoNode.didExitVisibleState and run the mute dance
// — pausing, muting, and downgrading the session out from under the system PiP
// handoff ("video continues, audio gone"). Engaged ONLY while the app is
// non-active or system PiP is active, so normal in-app behavior is untouched.
static BOOL PiPInlineShieldEngaged(AVPlayer *player) {
    ApolloPiPController *controller = sPiPSharedController;
    if (!controller || !player) return NO;
    if (!controller.inlineNativePiP || controller.inlineNativePlayer != player) return NO;
    if (controller.inlineNativePiP.pictureInPictureActive) return YES;
    return [UIApplication sharedApplication].applicationState != UIApplicationStateActive;
}

BOOL ApolloPiP_ShouldBlockAudioSessionDowngrade(void) {
    if (sPiPSessionHandbackInProgress) return NO;
    ApolloPiPController *controller = sPiPSharedController;
    if (!controller) return NO;
    // A silent GIF card produces no sound, so there is no audio session worth
    // holding against Apollo's Ambient downgrade.
    if (controller.active && controller.player
        && !controller.player.muted && !controller.cardIsGifContent) return YES;
    // Protect the inline-armed player's session through the background handoff
    // window even when muted: System PiP still needs an active Playback session to
    // start, and in the "All Videos" modes a muted video is eligible.
    AVPlayer *inlinePlayer = controller.inlineNativePlayer;
    return inlinePlayer && PiPInlineShieldEngaged(inlinePlayer);
}

// Consulted by ApolloVideoUnmute.xm's AVPlayer.setMuted: hook — blocks the
// mute dance's T+100ms setMuted:YES on the inline-armed player during the
// background handoff window.
BOOL ApolloPiP_ShouldBlockMuteOfPlayer(AVPlayer *player) {
    return PiPInlineShieldEngaged(player);
}

// A video just became audible inline (mute-button tap or auto-unmute) — no
// scroll event fires for that, so arm the inline native-PiP controller here
// (matters in "Unmuted Videos Only" mode, where the muted autoplay never
// armed it).
void ApolloPiP_NoteInlineVideoAudible(id videoNode, AVPlayer *player) {
    // Inline-arming only needs System PiP — the mini-player toggle is irrelevant.
    if (!sPiPNativeEnabled || !videoNode || !player) return;
    ApolloPiPController *controller = [ApolloPiPController sharedController];
    if (controller.active) return;
    if (player.rate == 0) return;
    if (!PiPIsEligibleForInlineNativePiP(videoNode, player)) return;
    if (!PiPIsVideoMidpointVisible(videoNode, nil)) return;
    [controller armInlineNativePiPForVideoNode:videoNode player:player];
}

// A player just got muted and the mute took effect (manual mute button, or the
// mute dance as a video scrolled off — both reach AVPlayer.setMuted:YES, which
// the ApolloVideoUnmute hook blocks only during the background handoff). Drop
// the inline system-PiP arm so a home-swipe can't hand off a muted video: for
// the feed this enforces requirement #4 (only deliberately-unmuted videos), and
// for comments it matches "Unmuted Videos Only". No-op while a card presents
// (it owns the player) or while system PiP is already running.
void ApolloPiP_NoteInlinePlayerMuted(AVPlayer *player) {
    ApolloPiPController *controller = sPiPSharedController;
    if (!controller || !player) return;
    if (controller.active) return;
    if (controller.inlineNativePlayer != player) return;

    // "Unmuted Videos Only": a muted video is no longer eligible, so a home-swipe
    // must not hand it off — disarm.
    if (sPiPActivationMode == ApolloPiPActivationModeUnmutedOnly) {
        ApolloLog(@"[PiP] Inline-armed player muted (Unmuted Only) — disarming system PiP");
        [controller disarmInlineNativePiPIfIdle];
        return;
    }

    // "All Videos" / "All Videos & GIFs": a muted PLAYING video stays eligible,
    // so keep the arm. Apollo's mute just ran the mute dance (session back to
    // Ambient + deactivated) — no synchronous re-assert HERE: with the user's
    // music playing a Playback claim would pause it (issue #560). The
    // visibility-tick / didBecomeActive heals reclaim and rebuild the arm once
    // the audio is idle; while music plays, the muted video's handoff yields.
    ApolloLog(@"[PiP] Inline-armed player muted (All Videos) — kept armed, session heal deferred");
}

// Audio arbitration: a DIFFERENT video is about to play audibly (the user
// unmuted a feed/comments video, or auto-unmute fired on entering another
// post). The user has moved on to other content, so dismiss the PiP entirely
// rather than leaving a now-muted card floating.
//
// Deliberately does NOT gate on owned.muted: when the new video is unmuted via
// Apollo's native handler, VideoSharingManager.setActiveAudioPlayer
// (sub_1005e6124) has ALREADY muted the previous active audio player — our
// PiP's player — by the time we run (we're called after %orig). Bailing on
// owned.muted there would leave the card floating muted, the exact symptom
// being fixed. Same content (the PiP's own video / its shared inline
// counterpart) is the same AVPlayer object and never matches.
void ApolloPiP_YieldAudioToPlayer(AVPlayer *newAudiblePlayer) {
    ApolloPiPController *controller = sPiPSharedController;
    if (!controller || !controller.active || controller.restoring) return;
    AVPlayer *owned = controller.player;
    if (!owned || owned == newAudiblePlayer) return;

    ApolloLog(@"[PiP] Different video unmuted — dismissing PiP");
    // Clear sessionClaimedAudibly FIRST so the teardown does NOT downgrade the
    // audio session to Ambient: the newly-audible video owns the Playback
    // session now, and a downgrade would silence it.
    //
    // Tear down SYNCHRONOUSLY (not the animated closeTapped) so controller.active
    // flips to NO right now. The unmute path arms the NEW video for System PiP
    // on the very next line (ApolloPiP_NoteInlineVideoAudible), and that arm —
    // like armInlineNativePiPForVideoNode — early-returns while a card is still
    // active. An animated/deferred teardown keeps .active YES through its 0.2s
    // fade and blocks the arm, so a home-swipe right after unmuting would not
    // enter system PiP. teardownKeepPlaying:NO also pauses + mutes our player,
    // clears its protection, and syncs the mute-button icon.
    controller.sessionClaimedAudibly = NO;
    [controller teardownKeepPlaying:NO];
}

static BOOL PiPShouldSuppressVideoNodeExit(id videoNode) {
    ApolloPiPController *controller = sPiPSharedController;
    if (!controller || !videoNode) return NO;
    AVPlayer *player = ApolloVideoUnmute_GetPlayerFromVideoNode(videoNode);
    if (controller.active) {
        if (videoNode == controller.videoNode) return YES;
        if (player && player == controller.player) return YES;
    }
    // Backgrounding/system-PiP handoff: don't let hierarchy churn fire the
    // mute dance for the inline-armed player.
    return player && PiPInlineShieldEngaged(player);
}

// System PiP on the feed (no card presenting): keep the inline system-PiP
// controller armed on an eligible UNMUTED, playing, on-screen feed video — one
// reclaimed after a comments back-pop, or unmuted directly in the feed — so a
// home-swipe hands it off. UNMUTED-ONLY by design: a feed can show many videos
// autoplaying muted, and only the one the user deliberately unmuted should
// trigger system PiP (so this gate is unmuted regardless of Activate For).
// Disarms the armed video once it's no longer eligible (muted/paused/off-screen).
static void PiPManageInlineNativeForFeedCell(id cellNode) {
    if (!sPiPNativeEnabled) return;
    ApolloPiPController *controller = sPiPSharedController;
    if (!controller || controller.active) return; // a card owns native PiP

    id richMediaNode = PiPRichMediaNodeFromCell(cellNode);
    id videoNode = PiPVideoNodeFromRichMedia(richMediaNode);
    if (!videoNode) return;

    AVPlayer *player = ApolloVideoUnmute_GetPlayerFromVideoNode(videoNode);
    // Deliberate-unmute gate, not raw !player.muted: a freshly created feed
    // player can read muted == NO while silent (issue #560), and the feed must
    // only arm for a video the user actually turned on.
    BOOL eligible = player && player.rate != 0
                 && PiPPlayerIsDeliberatelyAudible(player)
                 && PiPIsEligibleForInlineNativePiP(videoNode, player)
                 && PiPIsVideoMidpointVisible(videoNode, cellNode);
    if (eligible) {
        [controller armInlineNativePiPForVideoNode:videoNode player:player];
    } else if (videoNode == controller.inlineNativeVideoNode) {
        [controller disarmInlineNativePiPIfIdle];
    }
}

static BOOL PiPHandleFeedVisibilityEvent(id cellNode, unsigned long long event) {
    ApolloPiPController *controller = sPiPSharedController;
    if (!controller) return NO;
    if (!controller.active) {
        // No card — manage inline system PiP for an eligible unmuted feed video.
        PiPManageInlineNativeForFeedCell(cellNode);
        return NO;
    }

    id richMediaNode = PiPRichMediaNodeFromCell(cellNode);
    id videoNode = PiPVideoNodeFromRichMedia(richMediaNode);
    if (!videoNode) return NO;

    AVPlayer *player = ApolloVideoUnmute_GetPlayerFromVideoNode(videoNode);
    if (!player || player != controller.player) {
        // Same-post dedupe: a feed cell playing a DIFFERENT live player for the
        // post our card holds would double-render — close the card, the inline
        // cell wins. Scoped to fullscreen-origin cards (the only cards that
        // float over feeds with no identity home; comments-origin cards defer
        // to the appeared-walk on back-pop). The immediate teardown defers
        // through interactive back-swipes — these events fire mid-gesture even
        // when the gesture is cancelled, mirroring the owned path's deferral
        // below.
        if (controller.cardFromFullscreen && !controller.restoring && controller.link) {
            id cellLink = PiPGetIvar(richMediaNode, "link");
            BOOL sameLink = cellLink
                && (cellLink == controller.link || [cellLink isEqual:controller.link]);
            if (sameLink && player && player.rate != 0
                && !ApolloVideoUnmute_IsNavigatingBack()) {
                ApolloLog(@"[PiP] Feed cell playing our post with a different player — closing card");
                [controller teardownKeepPlaying:NO];
            } else if (sameLink) {
                // Playerless/paused at event time (async attach, or the mute
                // dance's pause window) — poll like the comments path does, or
                // the double-render lasts until the next scroll tick.
                [controller scheduleSameLinkRecheckForCell:cellNode
                                             richMediaNode:richMediaNode
                                                 videoNode:videoNode];
            }
        }
        return NO;
    }

    if (PiPIsVideoMidpointVisible(videoNode, cellNode)) {
        // The video's feed cell is on screen — never double-display; hand back.
        // EXCEPT mid back-swipe: the feed slides in behind comments and fires this
        // before the pop commits, so restoring here tears the card down early (and
        // even if the gesture is cancelled). Defer to PiPHandleFeedViewControllerAppeared
        // (viewDidAppear), which runs only on a committed pop; keep the card and
        // suppress the feed's pause meanwhile.
        if (ApolloVideoUnmute_IsNavigatingBack()) return YES;
        [controller restoreInline];
        return NO; // %orig's [player play] is harmless
    }
    return YES; // suppress the feed handler's pause of our player
}

// Find the feed's UITableView. ASTableViewController feeds nest it as a direct
// subview; ASDKViewController<ASTableNode> feeds (search/lite) ARE the table; the
// friends feed buries an ASTableNode a couple levels down. Depth-limited DFS
// covers all three without matching unrelated deep tables.
static UITableView *PiPFindFeedTableView(UIView *view, int depth) {
    if (!view || depth < 0) return nil;
    if ([view isKindOfClass:[UITableView class]]) return (UITableView *)view;
    for (UIView *subview in view.subviews) {
        UITableView *found = PiPFindFeedTableView(subview, depth - 1);
        if (found) return found;
    }
    return nil;
}

// After a back-pop the feed doesn't scroll, so no visibility events fire even
// though the reclaimed video's cell may be fully visible. Walk visible cells
// once on feed appear: hand a still-presenting card back, or (no card) re-arm
// inline system PiP for the reclaimed unmuted video — the comments cell's
// invisible event disarms it during the pop, and without this a home-swipe
// from the feed would not enter system PiP.
static void PiPHandleFeedViewControllerAppeared(UIViewController *feedVC) {
    ApolloPiPController *controller = sPiPSharedController;
    if (!controller || !feedVC) return;

    // An active card floats above forward navigation by design; only a back-pop
    // "returns to the feed" the video lives in, where the card hands back inline
    // or dismisses. Distinguish via THIS VC's own state: isMovingToParent is YES
    // only when it's being pushed (forward nav, e.g. a subreddit/user link in
    // comments), NO when revealed by a child pop (the back-pop we want). Using the
    // appearing VC's own flag avoids the cross-VC race an interactive swipe-pop has
    // with sIsNavigatingBack (CommentsVC.viewDidDisappear can clear it first).
    if (controller.active && [feedVC isMovingToParentViewController]) return;

    // Fullscreen-origin cards are homeless BY DESIGN (no inline identity —
    // autoplay off / compact feed / fullscreen-owned player): the dismiss
    // branches below would misread one as a stranded back-pop card. Also skip
    // while a fullscreen→PiP resolution from the same dismissal is in flight —
    // the modal dismissal fires this feed VC's viewDidAppear, whose ordering
    // against MediaPageViewController.viewDidDisappear is undefined.
    if (controller.active
        && (controller.cardFromFullscreen
            || sFSPiPPending
            || CFAbsoluteTimeGetCurrent() - sFSPiPResolvedAt < 1.5)) {
        return;
    }

    // A non-shareable (compact-mode) card's video is never reclaimed into a feed
    // cell — the compact feed shows a thumbnail, not the shared player — so on a
    // back-pop there is no inline home to restore into; dismiss it (it would
    // otherwise float forever). Shareable (large-thumbnail) cards fall through to
    // the restore walk below.
    if (controller.active && controller.ownedNonShareable) {
        ApolloLog(@"[PiP] Back-pop to feed with a non-shareable (compact) card — dismissing");
        [controller closeTapped];
        return;
    }

    if (!controller.active && !sPiPNativeEnabled) return; // nothing to manage

    UITableView *tableView = PiPFindFeedTableView(feedVC.view, 4);
    // tableView may be nil (feed not laid out the usual way) — the loop simply
    // doesn't run, and we fall through to the dismiss below.
    for (UITableViewCell *cell in tableView.visibleCells) {
        SEL nodeSel = NSSelectorFromString(@"node");
        if (![cell respondsToSelector:nodeSel]) continue;
        id cellNode = ((id (*)(id, SEL))objc_msgSend)(cell, nodeSel);

        if (!controller.active) {
            PiPManageInlineNativeForFeedCell(cellNode);
            continue;
        }

        id richMediaNode = PiPRichMediaNodeFromCell(cellNode);
        id videoNode = PiPVideoNodeFromRichMedia(richMediaNode);
        if (!videoNode) continue;

        AVPlayer *player = ApolloVideoUnmute_GetPlayerFromVideoNode(videoNode);
        if (player && player == controller.player
            && PiPIsVideoMidpointVisible(videoNode, cellNode)) {
            ApolloLog(@"[PiP] Feed appeared with our video visible — restoring inline");
            [controller restoreInline];
            return;
        }
    }

    // Back-popped, still presenting after the restore walk: our video's feed cell
    // isn't on screen — scrolled below the autoplay threshold, or off-screen
    // entirely — so there is no visible inline home to hand back to. Without this a
    // shareable (large-thumbnail) card floats over the feed until the user happens
    // to scroll the cell into view. Dismiss it instead; the shared player returns
    // to its feed-cell paused/muted state and re-autoplays when the cell scrolls
    // back on screen, matching normal feed behavior.
    if (controller.active) {
        ApolloLog(@"[PiP] Back-pop to feed, our video's cell not on screen — dismissing card");
        [controller closeTapped];
    }
}

// =============================================================================
// MARK: - Fullscreen → PiP entry point (issue #528)
// =============================================================================

// Set in %ctor. The fullscreen pager (MediaPageViewController) hosts one child
// viewer per media item; only MediaViewerController children can hold a player.
static Class sPiPMediaViewerClass = Nil;
static Class sPiPMediaPageVCClass = Nil;

// The fullscreen pager a child viewer belongs to, via the UIKit containment
// chain. (The parentMediaPageViewController ivar is a Swift weak box — reading
// it raw through object_getIvar would be unsafe.)
static UIViewController *PiPMediaPageVCForChild(UIViewController *child) {
    UIViewController *parent = child.parentViewController;
    while (parent && (!sPiPMediaPageVCClass || ![parent isKindOfClass:sPiPMediaPageVCClass])) {
        parent = parent.parentViewController;
    }
    return parent;
}

// The current page's OWNED player: MediaViewerController's `player` ivar, set
// only when the viewer created the player itself (Apollo's togglePlayPause
// treats it and the adopted playerLayerContainerView layer as disjoint). nil
// for image pages AND adopted shared-layer pages — a shared player has a live
// inline home the card would double-render.
static AVPlayer *PiPOwnedPlayerFromMediaPageVC(id pageVC) {
    if (!pageVC || ![pageVC respondsToSelector:@selector(viewControllers)]) return nil;
    id mediaVC = [[(UIPageViewController *)pageVC viewControllers] firstObject];
    if (!mediaVC || (sPiPMediaViewerClass && ![mediaVC isKindOfClass:sPiPMediaViewerClass])) return nil;
    return PiPGetIvar(mediaVC, "player");
}

// Spoiler/NSFW-tagged posts never autoplay inline: RichMediaNode's video setup
// (sub_10057c93c) evaluates AutoplayGIFs only when obscuredType is nil, so
// obscured posts take the blurred-poster path unconditionally — their
// fullscreen is as PiP-safe as autoplay-off. If the user disabled blurring
// (the post then autoplays like any other), the owned-player check still
// hides the button for adopted shared layers.
static BOOL PiPPagerLinkNeverAutoplays(id pageVC) {
    id link = PiPGetIvar(pageVC, "link"); // RDKLink
    if (!link) return NO;
    // getter=isSpoiler / getter=isNSFW — the binary has no plain `spoiler`
    // getter (verified: only -[RDKLink isSpoiler] / -[RDKLink isNSFW] exist).
    SEL spoilerSel = NSSelectorFromString(@"isSpoiler");
    if ([link respondsToSelector:spoilerSel]
        && ((BOOL (*)(id, SEL))objc_msgSend)(link, spoilerSel)) return YES;
    SEL nsfwSel = NSSelectorFromString(@"isNSFW");
    return [link respondsToSelector:nsfwSel]
        && ((BOOL (*)(id, SEL))objc_msgSend)(link, nsfwSel);
}

// URL-opened viewers (markdown/inline-media links via the URL router
// sub_100078db0, plus tip jar/SPCA-album easter eggs) carry no RDKLink —
// every post-media entry passes one (verified across all pager-init call
// sites). No link means no inline player home, so an owned player is as
// PiP-safe as autoplay-off. Image-only nil-link viewers are filtered by the
// owned-player check.
static BOOL PiPPagerIsURLOpened(id pageVC) {
    return pageVC && PiPGetIvar(pageVC, "link") == nil;
}

// Restore the user's fullscreen playback state on the card after the native
// dismissal's mute dance settles (T+0 force-mute, T+50ms Ambient downgrade,
// T+100ms setMuted:YES — relative to viewDidDisappear).
static void PiPScheduleFullscreenFixup(AVPlayer *player, BOOL wasMuted, BOOL wasPlaying,
                                       ApolloPiPController *cardController) {
    __weak AVPlayer *weakPlayer = player;
    __weak ApolloPiPController *weakController = cardController;
    NSUInteger generation = cardController.generation;
    // fullRestore = YES only on the first run (+250ms, dance settled): it may
    // touch mute/session state. The second run (+700ms) is a rate-only net for
    // stragglers (a trailing unpause/interruption can re-pause a beat later)
    // and must never override a mute the user may have set since.
    void (^fixup)(BOOL) = ^(BOOL fullRestore) {
        AVPlayer *fixupPlayer = weakPlayer;
        if (!fixupPlayer) return;
        ApolloPiPController *card = weakController;
        if (!card || !card.active || card.generation != generation
            || card.player != fixupPlayer) {
            return; // the card this fixup was scheduled for is gone
        }
        // wasPlaying gates the audible restore too: an unmuted-but-PAUSED video
        // must not claim the exclusive Playback session (it would stop other
        // apps' audio behind a card playing nothing).
        if (fullRestore && !wasMuted && !card.cardIsGifContent && wasPlaying) {
            // Mirror the card's own unmute path (muteTapped): exclusive
            // Playback first — Apollo's Ambient silences an unmuted player.
            if (fixupPlayer.muted) {
                AVAudioSession *session = [AVAudioSession sharedInstance];
                [session setCategory:AVAudioSessionCategoryPlayback
                                mode:AVAudioSessionModeDefault options:0 error:nil];
                [session setActive:YES withOptions:0 error:nil];
                [fixupPlayer setMuted:NO];
            }
            card.sessionClaimedAudibly = YES;
        }
        if (wasPlaying && fixupPlayer.rate == 0) {
            PiPRewindIfStoppedAtEnd(fixupPlayer);
            [fixupPlayer play];
        }
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ fixup(YES); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ fixup(NO); });
}

// Runs after the dismissal completes (MediaPageViewController.viewDidDisappear).
// One landing shape: the button only offers fullscreen-OWNED players, which
// have no inline home — the card takes the captured player directly.
static void PiPResolveFullscreenPiPRequest(void) {
    if (!sFSPiPPending) return;
    AVPlayer *player = sFSPiPPlayer;
    BOOL wasMuted = sFSPiPWasMuted;
    BOOL wasPlaying = sFSPiPWasPlaying;
    id link = sFSPiPLink;
    // Consume on the next runloop turn: ApolloVideoUnmute's own
    // viewDidDisappear hook (order against ours is undefined) must still see
    // the pending flag and skip its "Remember from Full Screen" re-unmute.
    // Token-guarded so the deferred clear can never clobber a NEWER request.
    NSUInteger token = sFSPiPRequestToken;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sFSPiPRequestToken != token) return;
        sFSPiPPending = NO;
        sFSPiPPlayer = nil;
        sFSPiPLink = nil;
    });
    if (!player) return;
    sFSPiPResolvedAt = CFAbsoluteTimeGetCurrent();

    ApolloPiPController *controller = [ApolloPiPController sharedController];
    ApolloLog(@"[PiP] Fullscreen PiP: card takeover on owned player");
    [controller takeOverFromCell:nil richMediaNode:nil videoNode:nil player:player];
    if (controller.active) {
        // No richMediaNode lent a link, so backfill it from the pager's — the
        // same-post dedupe guards key on controller.link, and without it
        // re-opening this post would double-render against the card.
        controller.cardFromFullscreen = YES;
        if (!controller.link && link) controller.link = link;
    }
    PiPScheduleFullscreenFixup(player, wasMuted, wasPlaying, controller);
}

// Build/refresh the fullscreen "enter PiP" button. Called from the pager's
// viewDidLayoutSubviews (page swipes, rotation) and the child viewer's (the
// player can materialize without a parent re-layout). Mirrors the native
// closeButton: frame reflected onto the trailing edge (native layout already
// resolves notch vs legacy insets) and alpha KVO-mirrored for the chrome fade.
static void PiPRefreshFullscreenPiPButton(id pageVC) {
    if (!pageVC) return;
    UIViewController *pageViewController = (UIViewController *)pageVC;
    UIButton *closeButton = PiPGetIvar(pageVC, "closeButton");
    UIButton *pipButton = objc_getAssociatedObject(pageVC, kPiPFullscreenButtonKey);
    if (!closeButton || !closeButton.superview || !pageViewController.isViewLoaded) {
        pipButton.hidden = YES;
        return;
    }
    if (!sPiPEnabled) {
        pipButton.hidden = YES;
        return;
    }
    if (!pipButton) {
        UIImageSymbolConfiguration *config =
            [UIImageSymbolConfiguration configurationWithPointSize:18
                                                            weight:UIImageSymbolWeightMedium];
        UIImage *icon = [UIImage systemImageNamed:@"pip.enter" withConfiguration:config];
        if (!icon) return;
        pipButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [pipButton setImage:icon forState:UIControlStateNormal];
        pipButton.tintColor = [UIColor whiteColor];
        pipButton.accessibilityLabel = @"Picture in Picture";
        [pipButton addTarget:pageVC action:NSSelectorFromString(@"apolloPiP_enterTapped:")
            forControlEvents:UIControlEventTouchUpInside];
        if (@available(iOS 13.4, *)) {
            pipButton.pointerInteractionEnabled = YES;
        }
        objc_setAssociatedObject(pageVC, kPiPFullscreenButtonKey, pipButton,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloPiPFullscreenButtonMirror *mirror =
            [[ApolloPiPFullscreenButtonMirror alloc] initWithSource:closeButton
                                                          pipButton:pipButton];
        objc_setAssociatedObject(pageVC, kPiPFullscreenMirrorKey, mirror,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (pipButton.superview != closeButton.superview) {
        [closeButton.superview addSubview:pipButton];
    }
    CGRect closeFrame = closeButton.frame;
    CGFloat width = closeButton.superview.bounds.size.width;
    pipButton.frame = CGRectMake(width - closeFrame.origin.x - closeFrame.size.width,
                                 closeFrame.origin.y,
                                 closeFrame.size.width, closeFrame.size.height);
    pipButton.alpha = closeButton.alpha;
    // Only when the video can't be autoplaying inline (setting off, a
    // spoiler/NSFW post — those never autoplay — or a URL-opened viewer,
    // which has no inline home at all) AND the page has a fullscreen-OWNED
    // player (image pages and adopted shared-layer pages keep the X alone).
    // Live checks — every layout/page-swipe pass re-evaluates.
    pipButton.hidden = closeButton.hidden
        || (PiPOwnedPlayerFromMediaPageVC(pageVC) == nil)
        || !(ApolloNativeAutoplayEffectivelyOff() || PiPPagerIsURLOpened(pageVC)
             || PiPPagerLinkNeverAutoplays(pageVC));
}

// Consulted by ApolloVideoUnmute.xm's MediaPageViewController.viewDidDisappear
// hook: while a fullscreen→PiP request is in flight, the PiP side owns the
// post-dismissal mute state — "Remember/Always from Full Screen" must not
// fight it.
BOOL ApolloPiP_WillHandleFullscreenDismiss(void) {
    return sFSPiPPending;
}

// =============================================================================
// MARK: - Hooks
// =============================================================================

// ---------------------------------------------------------------------------
// TouchHintVideoNode.didExitVisibleState fires when a video node fully leaves
// the screen and is THE trigger for Apollo's mute dance (sub_10058cb30 →
// sub_1003414cc: pause-all broadcast, Ambient downgrade, setMuted:YES).
// While PiP owns this node's player, skip it entirely — the fork's super
// implementation is an empty stub, so nothing else is lost. This also covers
// the FEED cell hosting the same shared player scrolling away.
// ---------------------------------------------------------------------------
%hook TouchHintVideoNode

- (void)didExitVisibleState {
    if (PiPShouldSuppressVideoNodeExit(self)) {
        ApolloLog(@"[PiP] Suppressing didExitVisibleState (mute dance) for owned video");
        return;
    }
    %orig;
}

%end

// ---------------------------------------------------------------------------
// ASVideoNode.didPlayToEnd: — the sole loop driver for inline v.redd.it video.
// It seeks to zero and replays when _shouldAutorepeat is set, ignoring the
// notification's item. Skip it for the item a PiP mode is actively presenting
// while "Loop Videos" is off; the player then pauses at the end on its own.
// (Hooks the base ASVideoNode class — TouchHintVideoNode doesn't override it.)
// ---------------------------------------------------------------------------
%hook ASVideoNode

- (void)didPlayToEnd:(NSNotification *)notification {
    id object = [notification object];
    if ([object isKindOfClass:[AVPlayerItem class]]
        && ApolloPiP_ShouldSuppressLoopForItem((AVPlayerItem *)object)) {
        ApolloLog(@"[PiP] Suppressing loop (didPlayToEnd) — video parked at end");
        return;
    }
    %orig;
}

%end

// ---------------------------------------------------------------------------
// RichMediaNode hooks:
//
// pauseAllAVPlayers...: posted at T+0 of ANY video's mute dance and pauses
// every registered player unconditionally (sub_1005823dc). Skip for the
// PiP-owned player so other videos' dances can't pause it.
//
// didExitPreloadState: destroys player/asset for NON-shareable videos
// (sub_10057aff4 → resetToPlaceholder + setPlayer:nil). Compact-mode comments
// players are non-shareable; skip the teardown while PiP owns one. (Skipping
// also leaves videoNodeStatus flags intact, which matches reality: the asset
// and player still exist.)
// ---------------------------------------------------------------------------
%hook RichMediaNode

- (void)pauseAllAVPlayersNotificationReceivedWithNotification:(id)notification {
    id videoNode = PiPGetIvar(self, "videoNode");
    if (videoNode) {
        AVPlayer *player = ApolloVideoUnmute_GetPlayerFromVideoNode(videoNode);
        if (player && (ApolloPiP_IsOwnedPlayer(player) || PiPInlineShieldEngaged(player))) {
            ApolloLog(@"[PiP] Suppressing pauseAllAVPlayers for owned/shielded video");
            return;
        }
    }
    %orig;
}

- (void)didExitPreloadState {
    id videoNode = PiPGetIvar(self, "videoNode");
    if (videoNode && !PiPNodeIsShareable(videoNode)) {
        AVPlayer *player = ApolloVideoUnmute_GetPlayerFromVideoNode(videoNode);
        if (player && ApolloPiP_IsOwnedPlayer(player)) {
            ApolloLog(@"[PiP] Suppressing didExitPreloadState teardown for owned non-shareable video");
            return;
        }
    }
    %orig;
}

%end

// ---------------------------------------------------------------------------
// LargePostCellNode: the feed analog of the comments visibility handler (same
// midpoint test, directly play/pauses shareable players every ≥5pt scroll).
// While PiP owns a player that lands back on a feed cell (after back-pop
// reclaim), restore when visible and suppress the pause while hidden.
// Feed-initiated takeover is intentionally out of scope.
// ---------------------------------------------------------------------------
%hook LargePostCellNode

- (void)cellNodeVisibilityEvent:(unsigned long long)event
                   inScrollView:(id)scrollView
                  withCellFrame:(CGRect)frame {
    if (PiPHandleFeedVisibilityEvent(self, event)) {
        return;
    }
    %orig;
}

%end

// ---------------------------------------------------------------------------
// MediaViewerController adopts the shared player layer in viewDidLayoutSubviews
// (sub_100366fa4) when fullscreen opens. If fullscreen takes the player we own,
// yield: close the card but keep playback running — fullscreen owns it now.
// When fullscreen dismisses, native scrolled-away behavior resumes (and a new
// PiP can engage on the next scroll).
// ---------------------------------------------------------------------------
%hook MediaViewerController

- (void)viewDidLayoutSubviews {
    %orig;

    // The child's layout pass is where the player materializes (shared-layer
    // adoption or own-player creation) without any parent re-layout — refresh
    // the parent's PiP button visibility from here too.
    if (sPiPEnabled) {
        UIViewController *pager = PiPMediaPageVCForChild((UIViewController *)self);
        if (pager) PiPRefreshFullscreenPiPButton(pager);
    }

    ApolloPiPController *controller = sPiPSharedController;
    if (!controller) return;
    if (!controller.active && !controller.inlineNativePiP) return;

    AVPlayer *fullscreenPlayer = PiPGetIvar(self, "player");
    if (!fullscreenPlayer) {
        id container = PiPGetIvar(self, "playerLayerContainerView");
        id playerLayer = container ? PiPGetIvar(container, "playerLayer") : nil;
        if ([playerLayer isKindOfClass:[AVPlayerLayer class]]) {
            fullscreenPlayer = [(AVPlayerLayer *)playerLayer player];
        }
    }
    if (!fullscreenPlayer) return;

    if (controller.active && fullscreenPlayer == controller.player) {
        ApolloLog(@"[PiP] Fullscreen viewer adopted our player — yielding");
        [controller teardownKeepPlaying:YES];
    } else if (controller.active && controller.link) {
        // Same post re-opened in fullscreen with a DIFFERENT player (a
        // fullscreen-origin card's player was never adopted by an inline
        // node, so re-tapping the post media creates a fresh one). Two live
        // players of the same content — close the card, fullscreen wins.
        UIViewController *pager = PiPMediaPageVCForChild((UIViewController *)self);
        id pageLink = pager ? PiPGetIvar(pager, "link") : nil;
        if (pageLink && (pageLink == controller.link || [pageLink isEqual:controller.link])) {
            ApolloLog(@"[PiP] Fullscreen re-opened our post with a new player — closing card");
            // Clear sessionClaimedAudibly FIRST (mirrors
            // ApolloPiP_YieldAudioToPlayer): fullscreen owns the session now —
            // its native Unmute-When-Opened claim carries no sAutoUnmutedPlayer
            // protection, so the teardown's Ambient + setActive:NO handback
            // would land on top of it, interrupting the fresh player (opens
            // stopped) and leaving it muted==NO-but-silent (#560 signature).
            // The music resume cue is merely deferred to the fullscreen's own
            // dismissal mute dance.
            controller.sessionClaimedAudibly = NO;
            [controller teardownKeepPlaying:NO];
        }
    } else if (controller.active) {
        // Nil-link card (URL-opened inline video): no link to dedupe on, so
        // match the fresh fullscreen player's asset URL against the card's.
        // Same two-live-players situation and session-handback hazard as the
        // link-match branch above.
        NSURL *cardURL = PiPAssetURLForNode(nil, controller.player);
        if (cardURL && [cardURL isEqual:PiPAssetURLForNode(nil, fullscreenPlayer)]) {
            ApolloLog(@"[PiP] Fullscreen re-opened our video (asset URL match) — closing card");
            controller.sessionClaimedAudibly = NO;
            [controller teardownKeepPlaying:NO];
        }
    }
    // Fullscreen creates its own (dormant) AVPictureInPictureController on the
    // shared layer — retire our inline one to avoid two controllers on it.
    if (fullscreenPlayer == controller.inlineNativePlayer) {
        [controller disarmInlineNativePiPIfIdle];
    }
}

%end

// ---------------------------------------------------------------------------
// MediaPageViewController (the fullscreen pager, hosts the chrome): the "enter
// PiP" button + the dismissal that resolves a pending PiP request. See the
// "Fullscreen → PiP entry point" section above.
// ---------------------------------------------------------------------------
%hook MediaPageViewController

- (void)viewDidLayoutSubviews {
    %orig;
    PiPRefreshFullscreenPiPButton(self);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig; // native force-mute + mute dance scheduling happen in here
    PiPResolveFullscreenPiPRequest();
}

// Album page swipes: viewControllers (and so the current page's player) only
// updates when the transition completes — no reliable layout pass follows, so
// refresh the button's visibility here too.
- (void)pageViewController:(id)pageViewController didFinishAnimating:(BOOL)finished
   previousViewControllers:(id)previousViewControllers transitionCompleted:(BOOL)completed {
    %orig;
    if (completed) PiPRefreshFullscreenPiPButton(self);
}

%new
- (void)apolloPiP_enterTapped:(id)sender {
    if (![self respondsToSelector:NSSelectorFromString(@"close")]) return;
    // Re-check the gate at tap time: visibility only re-evaluates on layout
    // passes, so a reachability flip while the viewer sits open can leave the
    // button stale-visible. Hide and stand down instead of acting.
    if (!ApolloNativeAutoplayEffectivelyOff() && !PiPPagerIsURLOpened(self)
        && !PiPPagerLinkNeverAutoplays(self)) {
        ApolloLog(@"[PiP] Fullscreen PiP tapped but the gate closed — hiding button");
        PiPRefreshFullscreenPiPButton(self);
        return;
    }
    AVPlayer *player = PiPOwnedPlayerFromMediaPageVC(self);
    if (!player) {
        PiPRefreshFullscreenPiPButton(self); // same stale-visible recovery
        return;
    }
    sFSPiPPending = YES;
    sFSPiPPlayer = player; // strong — must outlive the viewer (it owns the player)
    // Deliberate audibility, NOT raw player.muted: a preference-muted
    // fullscreen player reads muted == NO under an Ambient session, and
    // restoring "unmuted" from that would claim the exclusive Playback session
    // for content the user never audibly played (issue #560).
    sFSPiPWasMuted = !PiPPlayerIsDeliberatelyAudible(player);
    sFSPiPWasPlaying = player.rate != 0;
    sFSPiPLink = PiPGetIvar(self, "link");
    NSUInteger token = ++sFSPiPRequestToken;
    ApolloLog(@"[PiP] Fullscreen PiP button tapped (muted=%d, playing=%d) — dismissing viewer",
              sFSPiPWasMuted, sFSPiPWasPlaying);
    // Failsafe: if the dismissal never completes, drop the request so stale
    // state can't hijack a later dismissal. Token-keyed — a second request can
    // legitimately start within this window, which the first request's expiry
    // must not clobber.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (sFSPiPPending && sFSPiPRequestToken == token) {
            ApolloLog(@"[PiP] Fullscreen PiP request expired unresolved — dropping");
            sFSPiPPending = NO;
            sFSPiPPlayer = nil;
            sFSPiPLink = nil;
        }
    });
    // The native X path: haptic + closeMethod=0 + dismissViewControllerAnimated.
    ((void (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"close"));
}

%end

// ---------------------------------------------------------------------------
// Feed view controllers: restore PiP into a visible feed cell right after a
// back-pop (no scroll events fire on pop, so the visibility hook alone would
// leave the video double-displayed until the user scrolls). MUST cover every
// feed that hosts LargePostCellNode — the cell's visibility hook defers its
// restore here during a back-swipe, so a feed without this hook would strand the
// card: the main/subreddit feed, saved/profile feeds, the search-results and
// lite/peek feeds, and the friends feed.
// ---------------------------------------------------------------------------
%hook PostsViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    PiPHandleFeedViewControllerAppeared((UIViewController *)self);
}

%end

%hook SavedPostsCommentsViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    PiPHandleFeedViewControllerAppeared((UIViewController *)self);
}

%end

%hook ProfileViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    PiPHandleFeedViewControllerAppeared((UIViewController *)self);
}

%end

%hook PostsSearchResultsViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    PiPHandleFeedViewControllerAppeared((UIViewController *)self);
}

%end

%hook LitePostsViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    PiPHandleFeedViewControllerAppeared((UIViewController *)self);
}

%end

%hook FriendsViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    PiPHandleFeedViewControllerAppeared((UIViewController *)self);
}

%end

// =============================================================================
// MARK: - Constructor
// =============================================================================

%ctor {
    Class touchHintVideoNodeClass = objc_getClass("_TtC6Apollo18TouchHintVideoNode");
    Class richMediaNodeClass = objc_getClass("_TtC6Apollo13RichMediaNode");
    Class largePostCellClass = objc_getClass("_TtC6Apollo17LargePostCellNode");
    Class mediaViewerClass = objc_getClass("_TtC6Apollo21MediaViewerController");
    Class mediaPageVCClass = objc_getClass("_TtC6Apollo23MediaPageViewController");
    Class postsVCClass = objc_getClass("_TtC6Apollo19PostsViewController");
    Class savedPostsVCClass = objc_getClass("_TtC6Apollo32SavedPostsCommentsViewController");
    Class profileVCClass = objc_getClass("_TtC6Apollo21ProfileViewController");
    // Also LargePostCellNode-hosting feeds — see the feed VC hook comment above.
    Class searchResultsVCClass = objc_getClass("_TtC6Apollo32PostsSearchResultsViewController");
    Class litePostsVCClass = objc_getClass("_TtC6Apollo23LitePostsViewController");
    Class friendsVCClass = objc_getClass("_TtC6Apollo21FriendsViewController");
    Class asVideoNodeClass = objc_getClass("ASVideoNode"); // loop kill-switch

    ApolloLog(@"[PiP] ctor: TouchHintVideoNode=%p RichMediaNode=%p LargePostCellNode=%p MediaViewerController=%p PostsVC=%p SavedPostsVC=%p ProfileVC=%p ASVideoNode=%p",
              (void *)touchHintVideoNodeClass, (void *)richMediaNodeClass,
              (void *)largePostCellClass, (void *)mediaViewerClass,
              (void *)postsVCClass, (void *)savedPostsVCClass, (void *)profileVCClass,
              (void *)asVideoNodeClass);

    if (!touchHintVideoNodeClass || !richMediaNodeClass || !largePostCellClass
        || !mediaViewerClass || !mediaPageVCClass || !postsVCClass || !asVideoNodeClass) {
        ApolloLog(@"[PiP] ctor: FATAL — required classes not found, PiP disabled");
        return;
    }

    sPiPMediaViewerClass = mediaViewerClass;
    sPiPMediaPageVCClass = mediaPageVCClass;

    %init(
        TouchHintVideoNode = touchHintVideoNodeClass,
        RichMediaNode = richMediaNodeClass,
        LargePostCellNode = largePostCellClass,
        MediaViewerController = mediaViewerClass,
        MediaPageViewController = mediaPageVCClass,
        PostsViewController = postsVCClass,
        SavedPostsCommentsViewController = savedPostsVCClass ?: postsVCClass,
        ProfileViewController = profileVCClass ?: postsVCClass,
        PostsSearchResultsViewController = searchResultsVCClass ?: postsVCClass,
        LitePostsViewController = litePostsVCClass ?: postsVCClass,
        FriendsViewController = friendsVCClass ?: postsVCClass,
        ASVideoNode = asVideoNodeClass
    );

    ApolloLog(@"[PiP] ctor: hooks initialized");
}
