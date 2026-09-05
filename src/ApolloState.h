#import <Foundation/Foundation.h>

@class UIScrollView;
@class UITabBar;
@class UITabBarController;
@class UINavigationItem;
@class UIViewController;

// Persisted through the legacy UDKeyTabBarCollapseSide key so existing
// Left/Right preferences and settings backups remain compatible.
typedef NS_ENUM(NSInteger, ApolloTabBarHideStyle) {
    ApolloTabBarHideStyleLeft = 0,
    ApolloTabBarHideStyleRight = 1,
    ApolloTabBarHideStyleFade = 2,
    ApolloTabBarHideStyleDown = 3,
};

static inline BOOL ApolloTabBarHideStyleUsesCustomPresentation(
    ApolloTabBarHideStyle style) {
    return style == ApolloTabBarHideStyleFade ||
           style == ApolloTabBarHideStyleDown;
}

extern NSString *sRedditClientId;
extern NSString *sRedditClientSecret;
extern NSString *sImgurClientId;
extern NSString *sImageChestAPIToken;
extern NSString *sRedirectURI;
extern NSString *sUserAgent;
extern NSString *sRandomSubredditsSource;
extern NSString *sRandNsfwSubredditsSource;
extern NSString *sTrendingSubredditsSource;
extern NSString *sTrendingSubredditsLimit;

extern BOOL sBlockAnnouncements;
extern BOOL sShowDeletedComments;
extern BOOL sTapToRevealDeletedComments;
extern BOOL sPassiveDeletedComments;
extern BOOL sShowRecentlyReadThumbnails;
extern BOOL sFeedTextPostThumbnails;
// Default-on large-feed carousel for Reddit-native multi-image galleries.
extern BOOL sFeedGalleryCarousel;
// Default-on: at the carousel's first/last image, swiping past the edge hands
// the drag to Apollo's swipe-back/forward navigation instead of rubber-banding.
extern BOOL sFeedGalleryEdgeSwipeNav;
// Default-on: scrolling the feed a few posts past where you swiped back drops
// Apollo's forward-swipe memory (ApolloForwardSwipeExpiry.xm).
extern BOOL sForwardSwipeForgetAfterScrolling;
// Default-on fullscreen-media comments pane, opened by upward flick or button.
extern BOOL sSwipeUpForComments;
// Opt-in (default OFF) live interactive Devvit posts (embedded web widget).
extern BOOL sDevvitInteractivePosts;
// Sub-toggle: Devvit widgets in large-mode feed cards too (vs comments only).
// Default on, but only consulted while the master toggle is on.
extern BOOL sDevvitFeedWidgets;
// Opt-in (default OFF) chat-heads-style floating post tabs (up to 5 bubbles
// that keep posts open). See ApolloFloatingTabs.xm.
extern BOOL sFloatingPostTabs;
// Sub-toggle: bubbles released near each other magnetize into a pile (drag
// moves the pile, tap fans it apart). Default on; only consulted while the
// master toggle is on.
extern BOOL sFloatingPostTabsMagnet;
// Sub-toggle: hold a bubble for a peek-and-pop snapshot preview (release
// opens, slide away cancels). Default on; consulted while the master is on.
extern BOOL sFloatingPostTabsPreview;
extern NSInteger sPreferredGIFFallbackFormat;

extern NSInteger sReadPostMaxCount;

// 0 = Default (off), 1 = Remember from Full Screen, 2 = Always
extern NSInteger sUnmuteCommentsVideos;

// "Unmute Videos in Feed" — how feed videos sound when they autoplay while
// scrolling. 0 = Never (default, stock behaviour), 1 = Remember (mirror the
// user's last manual mute/unmute of a feed video, stored in
// UDKeyFeedVideosUnmutedMemory), 2 = Always. See ApolloVideoUnmute.xm.
extern NSInteger sUnmuteFeedVideos;

// "Feed Video Scrubber" — when ON, press-and-hold the progress bar at the
// bottom of a feed video and slide to scrub it in place; taps keep opening the
// fullscreen viewer as stock. Default OFF. See ApolloFeedVideoScrubber.xm.
extern BOOL sFeedVideoScrubber;

// "Hold for Video Speed": when ON (default), press-and-hold the right side of a
// fullscreen video to play it at sVideoHoldSpeed while held; release restores the
// prior rate. When OFF the right side behaves like the rest of the player (normal
// long-press menu). sVideoHoldSpeed is one of 0.25/0.5/0.75/1.25/1.5/2.0 (default
// 2.0×). Both default via registerDefaults. See ApolloVideoHoldSpeed.xm.
extern BOOL sVideoHoldSpeedEnabled;
extern float sVideoHoldSpeed;
// Snap an arbitrary stored value to the nearest supported hold speed; falls back
// to 2.0× for an unset/corrupt/out-of-set value. Keeps the runtime, the load
// paths, and the picker agreeing on exactly the six offered speeds. Wrapped in
// extern "C" so the ObjC++ (.xm) callers and the ObjC (.m) definition agree on the
// unmangled symbol name (the extern *variables* above need no guard — global
// variable names aren't C++-mangled).
#ifdef __cplusplus
extern "C" {
#endif
float ApolloSanitizedHoldSpeed(float value);
#ifdef __cplusplus
}
#endif

extern BOOL sProxyImgurDDG;
extern BOOL sImgurAlbumFallbackProxies;
extern BOOL sShowUserAvatars;
extern BOOL sUseProfileAvatarTabIcon;
// Hide the visible main-tab labels while retaining/restoring the underlying
// UITabBarItem titles. Opt-in; default OFF via registerDefaults.
extern BOOL sHideTabBarTitles;
#ifdef __cplusplus
extern "C" {
#endif
// Central setter used by the settings UI. Icon-only mode temporarily suspends
// Apollo's narrower "Hide Username on Tab Bar" preference, then restores the
// user's prior choice when tab labels return.
void ApolloSetHideTabBarTitlesEnabled(BOOL enabled);
// Suspends a persisted native setting while icon-only mode is active. Used at
// launch/restore and after external native-setting notifications.
void ApolloNormalizeNativeHideUsernameForIconOnlyTabBar(void);
#ifdef __cplusplus
}
#endif
// When ON (default), profile pages show Reborn's detailed profile — the banner,
// large avatar/snoovatar, display name, bio, and the Social Links band (Buy Me a
// Coffee, Instagram, X, …). When OFF, profiles revert to Apollo's compact stock
// layout — the detailed header is not installed and any existing one is torn down.
// Independent of sShowUserAvatars (inline avatars). The Social Links band lives
// inside this header, so it is gated on this same flag. Default ON via
// registerDefaults. See ApolloUserAvatars.xm and ApolloProfileSocialLinks.{h,m}.
extern BOOL sShowDetailedProfiles;
extern BOOL sBadgeBookEnabled;
extern BOOL sProfileHeaderImmersive;
extern BOOL sProfileShowBanner;
extern BOOL sProfileShowStatCards;
extern BOOL sProfileShowSocialLinks;
extern BOOL sProfileShowActions;
extern NSInteger sProfileAvatarStyle; // 0 Full snoovatar, 1 Circle, 2 Square
extern BOOL sShowSubredditHeaders;
// Subreddit Layout density has three user-visible states:
// New = sShowSubredditHeaders + sSubredditHeaderImmersive,
// Classic = sShowSubredditHeaders + !sSubredditHeaderImmersive,
// Native = !sShowSubredditHeaders (Apollo's current/pre-3.5 header).
extern BOOL sSubredditHeaderImmersive;
// Per-section show switches on the subreddit header (banner / Join button /
// display name) — same "turn off the bands you don't need" pattern as the
// profile header's per-section switches.
extern BOOL sSubredditShowBanner;
extern BOOL sSubredditShowJoinButton;
// Whether the community's big bold title (e.g. "Reddit Science") shows above
// the r/name line. Direct on/off choice rather than the old auto-hide-if-
// similar-to-r/name heuristic, so behavior is predictable across subreddits.
extern BOOL sSubredditShowDisplayName;
// Backing booleans for the single Community Highlights mode picker:
//   Off     = both NO
//   Partial = sCommunityHighlights YES, sCommunityHighlightsWeb NO
//   Full    = both YES
// Kept as booleans so existing preferences/backups migrate without conversion.
// The carousel shows the subreddit's pinned posts at the top of the feed.
extern BOOL sCommunityHighlights;
// Full mode uses a hidden WKWebView to harvest up to 6 highlights beyond the 2
// Reddit's REST API exposes. See ApolloSubredditHighlights.xm (ApolloHLWebFetch).
extern BOOL sCommunityHighlightsWeb;
// Posted after the Liquid Glass tab-bar scroll behavior changes so the runtime
// can cancel in-flight work and reconcile the native policy.
extern NSString *const ApolloTabBarScrollBehaviorChangedNotification;
// NO selects Two-Gesture; YES selects Classic bidirectional behavior. See
// ApolloAutoHideTabBar.xm and UDKeyClassicTabBarScrollBehavior.
extern BOOL sClassicTabBarScrollBehavior;
// Read live so a change applies without relaunch. Default Left via
// registerDefaults. The old key name is retained only for compatibility.
extern ApolloTabBarHideStyle sTabBarHideStyle;
#ifdef __cplusplus
extern "C" {
#endif
BOOL ApolloSupportsNativeTabBarScrollBehavior(void);
#ifdef __cplusplus
}
#endif
// Explicit presentation ownership shared with list geometry and other tab-bar
// owners. Never infer presentation ownership from alpha/transform or the
// global style alone.
BOOL ApolloTabBarIsHideOnScrollPresentationOwned(UITabBar *tabBar);
void ApolloRestoreHideOnScrollPresentation(UITabBarController *tabBarController,
                                           NSString *reason);
// iPad + Liquid Glass only. When ON, docks the iOS 26 floating tab bar at the
// bottom (classic) instead of the top-center pill. Opt-in; default OFF via
// registerDefaults. Temporary stopgap for issue #387. See ApolloIPadTabBarBottom.xm.
extern BOOL sIPadTabBarBottom;
// When ON, neutralizes Apollo's feed/subreddit search takeover (nav-hide + fade + toolbar
// dock/grow); the field stays put and results populate the feed in place. Liquid Glass only;
// mutually exclusive with the default nav-hide mode. See ApolloSearchInPlace.xm.
extern BOOL sKeepSearchBarInPlace;
// Liquid Glass title placement: ON (default) = centered in the gap between the
// back pill and the trailing pill; OFF = centered on the screen, nudged only to
// clear a pill. See ApolloRecenterTitleControl in ApolloLiquidGlass.xm.
extern BOOL sLGTitleGapCentering;
// When ON (default), press-and-hold on a post info row shows the glass-slider
// magnifier loupe: slide to pick an icon, release to activate it (upvote /
// comments / posted / % upvoted / translation). See ApolloStatsRowTouch.xm.
extern BOOL sIconRowMagnifier;
// Info Row settings sub-screen switches. Disabled icons still appear in the
// magnifier loupe but do nothing on release. Disabled direct taps keep Apollo's
// stock behavior instead of being consumed by the tweak.
// sInfoRowTapTranslation governs the 🌐 marker beside a post's stats (feed title
// + comments header) and takes priority over Tap to Translate / title Details;
// it does NOT touch the inline "Translate" affordance under comment/self-post
// body text (that stays in Translation settings).
// See ApolloStatsRowTouch.xm, ApolloCreatedAtAlert.xm, ApolloTranslation.xm.
extern BOOL sInfoRowTapUpvote;
extern BOOL sInfoRowTapComments;
// The tappable "info" icons — % upvoted, timestamp, and edited — plus owned-comment
// insights all share one display style, chosen by these two mutually-exclusive
// toggles: Popup = the dismissable alert; Overlay = the small auto-fading card above
// the icon/score. With both off, direct taps use Apollo's stock behavior, the comment
// score hold stays native, and picking an info icon in the loupe does nothing.
// Popup defaults ON; the settings UI + a load-time clamp keep them exclusive.
extern BOOL sInfoRowPopupMode;
extern BOOL sInfoRowOverlayMode;
extern BOOL sInfoRowTapTranslation;
// When ON (default), Live Update comment sort keeps the newest comments visible at the top
// while you're at the top, and shows a "N new comments" jump pill when you've scrolled down
// to read/reply. See ApolloLiveCommentsFollow.xm. Default ON via registerDefaults.
extern BOOL sLiveCommentsFollow;
// Per-post comment sort memory (issue #555): reopening a post restores the comment
// sort last picked inside it; other posts keep Apollo's native sort chain. Opt-in;
// default OFF via registerDefaults. See ApolloPerPostCommentSort.xm.
extern BOOL sPerPostCommentSort;

// "Header Style" (user-facing name): override for the TOP scroll edge effect on
// iOS 26+ Liquid Glass. iOS 26 defaults to Soft; iOS 27 betas default to Hard,
// which some users find jarring. Only the top (header) edge is governed — the
// tab-bar/bottom edge always keeps the system's own treatment. See
// ApolloScrollEdgeEffect.xm (Soft/Hard enforcement) and
// ApolloProgressiveBlur.xm (Blur's tweak-drawn variable blur).
typedef NS_ENUM(NSInteger, ApolloScrollEdgeEffectStyle) {
    // Retired user-facing System Default value. Load-time migration resolves
    // stored 0s to an explicit Soft (iOS 26) or Hard (iOS 27) choice.
    ApolloScrollEdgeEffectStyleAutomatic = 0,
    ApolloScrollEdgeEffectStyleSoft      = 1,
    ApolloScrollEdgeEffectStyleHard      = 2,
    // 3 was Hidden, retired: visually indistinguishable from Soft, so stored 3s
    // migrate to Soft at load (Tweak.xm). Never reuse 3 for a new mode — the
    // migration could not tell an old Hidden user from a new-mode user.
    ApolloScrollEdgeEffectStyleBlur      = 4,
};
extern NSInteger sScrollEdgeEffectStyle;
// Resolves the retired Automatic value defensively if it is observed before
// load-time migration, and resolves Blur to the OS-equivalent Soft/Hard style
// when its private filter is unavailable. Anything keyed on the *look* of the
// header reads this rather than assuming the raw preference can render.
#ifdef __cplusplus
extern "C" {
#endif
NSInteger ApolloResolvedScrollEdgeEffectStyle(void);
// Whether the private CAFilter variableBlur primitive Blur mode renders with
// exists at runtime; the settings picker hides the Blur option when NO.
// Defined in ApolloProgressiveBlur.xm.
BOOL ApolloProgressiveBlurAvailable(void);
#ifdef __cplusplus
}
#endif
// Posted (main thread) after sScrollEdgeEffectStyle changes; observers restyle
// live UI. Defined in ApolloScrollEdgeEffect.xm.
extern NSString *const ApolloScrollEdgeEffectStyleChangedNotification;
// Applies the resolved header style to a scroll view's top edge effect (no-op
// pre-iOS 26 or when not Liquid Glass). Called from UIScrollView's
// didMoveToWindow hook in ApolloAutoHideTabBar.xm — kept here to avoid a
// second %hook UIScrollView didMoveToWindow, which the Logos internal
// generator silently drops as a duplicate symbol.
void ApolloApplyScrollEdgeEffectStyle(UIScrollView *scrollView);
// Applies the selected style to every scroll view owned by an Apollo list
// controller. Home, Profile, Comments, and similar screens all inherit Apollo's
// ASTableViewController, which layers an intercepting UIScrollView over its
// ASTableView. Applying at the controller level mirrors SwiftUI's inherited
// NavigationStack modifier and reaches both views.
void ApolloApplyScrollEdgeEffectStyleToViewController(UIViewController *viewController);
// Whether the nav title for this view controller should size its JumpBar to
// its actual content (with truncation if still too wide) instead of Apollo's
// fixed native width (ApolloSubredditHeaders.xm's subreddit feeds).
// Positioning stays on the existing centering formula, unchanged, everywhere.
BOOL ApolloSubredditTitleShouldTruncate(UIViewController *viewController);
// Schedules a layout pass only for the subreddit title owned by this nav item.
// ApolloTranslation.xm calls this after Apollo replaces its trailing item
// cluster; unrelated windows and navigation stacks are never traversed.
void ApolloSubredditRequestTitleRelayout(UINavigationItem *navigationItem);
extern BOOL sModernSubredditDividers;
// Master toggle for subreddit list polish; Feed Shortcuts remains independent.
extern BOOL sSubredditListEnhancements;
typedef NS_ENUM(NSInteger, ApolloSubredditFeedIconStyle) {
    ApolloSubredditFeedIconStyleClassic = 0,
    ApolloSubredditFeedIconStyleCircle = 1,
    ApolloSubredditFeedIconStyleTinted = 2,
    ApolloSubredditFeedIconStyleSoftTile = 3,
    ApolloSubredditFeedIconStyleSolidTile = 4,
};
typedef NS_ENUM(NSInteger, ApolloSubredditFeedLayout) {
    ApolloSubredditFeedLayoutRows = 0,
    ApolloSubredditFeedLayoutGrid = 1,
    ApolloSubredditFeedLayoutSideBySide = 2,
    ApolloSubredditFeedLayoutIconDock = 3,
};
// Home / Popular / All / Moderator icon appearance and arrangement. Independent
// of the subreddit-list polish master.
extern NSInteger sSubredditFeedIconStyle;
extern NSInteger sSubredditFeedLayout;

// Opt-in per-account FavoriteSubreddits projection. Defaults OFF; see
// ApolloPerAccountFavorites.{h,m}.
extern BOOL sPerAccountFavoritesEnabled;
// Hide the description subtitles under the subreddit list's built-in feed rows
// (see UDKeyHideSubredditListDescriptions). Independent of the enhancements master.
extern BOOL sHideSubredditListDescriptions;
// Blank the subtitle line under multireddit rows (see
// UDKeyHideMultiredditDescriptions). Independent of the enhancements master.
extern BOOL sHideMultiredditDescriptions;

// Color post (link) flairs and user/author flairs using Reddit's assigned
// colors (filled pill + matching text color). When NO, Apollo's default grey
// flair styling is preserved. See ApolloFlairColors.xm.
extern BOOL sEnableFlairColors;

// Render feed post titles (large + compact posts, crossposts, the post
// context above a comment) in Semibold instead of Apollo's Regular.
// Appearance > Posts > Bold Post Titles. See ApolloBoldPostTitles.xm.
extern BOOL sBoldPostTitles;

// Render image URLs inline in post selftext and comments. Defaults to YES on
// fresh installs (registerDefaults). When NO, Apollo's native behavior (text
// link + optional link card) is preserved. See ApolloInlineImages.xm.
extern BOOL sEnableInlineImages;
// Master toggle for message media enhancements (inline images/GIFs/emoji/snoomoji in message
// bubbles + working media sends + tap-to-fullscreen), in every thread Apollo draws itself:
// legacy Direct Chat, private messages, and native Moderator Mail. Default ON via
// registerDefaults; OFF = stock Apollo threads. Unaffected by the modern Chat/Modmail toggles,
// which swap their own surface for a web one that renders its own media (private messages stay
// native either way). Independent of sShowUserAvatars. See ApolloChatInlineImages/Composer.xm.
extern BOOL sEnableChatMedia;

// On-device AI summaries (Apple FoundationModels, iOS 26+). Off by default.
// When on, a post summary is rendered at the bottom of the post and a comment
// summary at the top of the comments, generated automatically on open. See
// ApolloAISummary.xm.
extern BOOL sEnableAISummaries;
// Sub-toggles (only consulted while sEnableAISummaries is on). Default YES.
extern BOOL sEnableAIPostSummaries;     // post / link / both summaries
extern BOOL sEnableAICommentSummaries;  // the "Discussion so far" summary
extern BOOL sEnableTapToSummarize;      // generate only on tap (off = automatic)
extern BOOL sEnableAIAutoExpandSummaries; // auto-open a summary card once it's ready (off = stay collapsed)
// AI summary backend selection + per-provider cloud credentials (see
// UserDefaultConstants.h). sAISummaryProvider is always one of
// apple|openrouter|gemini|custom (sanitized on load); the rest are nil when unset.
extern NSString *sAISummaryProvider;
extern NSString *sOpenRouterAPIKey;
extern NSString *sOpenRouterAIModel;
extern NSString *sGeminiAPIKey;
extern NSString *sGeminiAIModel;
extern NSString *sCustomAIAPIKey;
extern NSString *sCustomAIModel;
extern NSString *sCustomAIBaseURL;

// AI summary tuning shared by the settings UI and generation pipeline.
// The threshold applies only to a Reddit self-post body; external article
// summaries remain eligible independently of the self-text length.
typedef NS_ENUM(NSInteger, ApolloAISummaryDetail) {
    ApolloAISummaryDetailBrief = 0,
    ApolloAISummaryDetailBalanced = 1,
    ApolloAISummaryDetailInDepth = 2,
};
extern NSInteger sAIPostWordThreshold;              // 50...300, step 50
extern ApolloAISummaryDetail sAIPostSummaryDetail;  // post / link / both
extern ApolloAISummaryDetail sAICommentSummaryDetail;

// Horizontal alignment for inline media containers narrower than the row width
// (tall portrait images, height-capped images). Has no effect on full-width media.
typedef NS_ENUM(NSInteger, ApolloInlineImageAlignment) {
    ApolloInlineImageAlignmentCenter = 0,
    ApolloInlineImageAlignmentLeft   = 1,
    ApolloInlineImageAlignmentRight  = 2,
};
extern NSInteger sInlineImageAlignment;

// Autoplay policy for inline GIF/animated media previews. Decoupled from Apollo's
// native "Autoplay GIFs/Videos" setting, except for the Default mode which follows it.
// Defaults to Default. Only takes effect when Inline Media Previews
// (sEnableInlineImages) is on. See ApolloMediaAutoplay.m.
typedef NS_ENUM(NSInteger, ApolloAutoplayInlineGIFMode) {
    // Legacy value: "follow Apollo's native Autoplay GIFs/Videos setting".
    // No longer offered in the UI — resolved once at load into the explicit
    // equivalent (see ApolloResolveLegacyDefaultAutoplayGIFMode) so persisted
    // settings keep their behavior.
    ApolloAutoplayInlineGIFModeDefault   = 0,
    ApolloAutoplayInlineGIFModeNever     = 1, // static cover, no play overlay (tap opens viewer)
    ApolloAutoplayInlineGIFModeWiFiOnly  = 2, // autoplay on WiFi; Tap to Play on cellular
    ApolloAutoplayInlineGIFModeAlways    = 3,
    ApolloAutoplayInlineGIFModeTapToPlay = 4, // static cover + play button; tap toggles play/pause inline
    // 4 appended so persisted values keep meaning; display order is
    // Always, WiFi Only, Tap to Play, Never.
};
extern NSInteger sAutoplayInlineGIFMode;

// Display width of inline media (images/GIFs) in comments/selftext as a
// percentage of the row width (50/75/100, default 100). Plain scalar — read
// from Texture background layout threads (layoutSpecThatFits:), so keep it a
// simple aligned integer, never an object.
extern NSInteger sInlineMediaSizePercent;

typedef NS_ENUM(NSInteger, ApolloLinkPreviewMode) {
    ApolloLinkPreviewModeOff = 0,
    ApolloLinkPreviewModeCompact = 1,
    ApolloLinkPreviewModeFull = 2,
};

typedef NS_ENUM(NSInteger, ApolloLinkPreviewCardColor) {
    ApolloLinkPreviewCardColorNeutral = 0,
    ApolloLinkPreviewCardColorGray = 1,
    ApolloLinkPreviewCardColorRed = 2,
    ApolloLinkPreviewCardColorOrange = 3,
    ApolloLinkPreviewCardColorYellow = 4,
    ApolloLinkPreviewCardColorGreen = 5,
    ApolloLinkPreviewCardColorMint = 6,
    ApolloLinkPreviewCardColorTeal = 7,
    ApolloLinkPreviewCardColorCyan = 8,
    ApolloLinkPreviewCardColorBlue = 9,
    ApolloLinkPreviewCardColorIndigo = 10,
    ApolloLinkPreviewCardColorPurple = 11,
    ApolloLinkPreviewCardColorPink = 12,
    ApolloLinkPreviewCardColorBrown = 13,
    ApolloLinkPreviewCardColorCoral = 14,
    ApolloLinkPreviewCardColorLime = 15,
    ApolloLinkPreviewCardColorOlive = 16,
    ApolloLinkPreviewCardColorLavender = 17,
    ApolloLinkPreviewCardColorSlate = 18,
};

// Rich link previews (Open Graph / oEmbed) for link cards in body/feed and comments.
extern NSInteger sLinkPreviewBodyMode;
extern NSInteger sLinkPreviewCommentsMode;
// Legacy preset enum, retained only for one-time migration to the hex below.
extern NSInteger sLinkPreviewCardColor;
// Free-form preview card color, 6-digit "RRGGBB" hex. nil/empty = Default (no
// custom fill). When set, the whole card is painted this exact color.
// MAIN-THREAD ONLY: read/written by the settings UI and persistence. The card
// renderer runs on Texture background layout threads and must NOT touch this
// NSString* (racing a strong-pointer reassign risks a use-after-free); it reads
// the packed snapshot below instead. Both are updated together via
// ApolloSetLinkPreviewCardColorHex().
extern NSString *sLinkPreviewCardColorHex;
// Render-safe snapshot of the card color, readable from any thread through the
// __atomic load/store helpers. 0 = Default; otherwise
// (1<<24) | (R<<16) | (G<<8) | B.
extern uint32_t sLinkPreviewCardColorPacked;

// Media upload host selection. Imgur is the default; Reddit uses Apollo's signed-in
// session to upload directly to Reddit's media storage; ImgChest uploads to
// imgchest.com via the user's API token (see ApolloImgChestUpload.m).
typedef NS_ENUM(NSInteger, ImageUploadProvider) {
    ImageUploadProviderImgur = 0,
    ImageUploadProviderReddit = 1,
    ImageUploadProviderImgChest = 2,
};
extern NSInteger sImageUploadProvider;

// Comment Link Host: secondary host for images added in the COMMENT/REPLY editor.
// Off (default) keeps comment uploads on the Media Upload Host above. Imgur/ImgChest
// route comment-editor uploads to that host and post the result as a plain link in
// the comment body (no native Reddit media), so image/GIF replies still work in
// subreddits that disallow media comments. Posts and chat are unaffected. Armed per
// photo-button tap in ApolloMarkdownToolbarGif.xm; routed in ApolloImageUploadHost.xm.
typedef NS_ENUM(NSInteger, CommentLinkHost) {
    CommentLinkHostOff = 0,
    CommentLinkHostImgur = 1,
    CommentLinkHostImgChest = 2,
};
extern NSInteger sCommentLinkHost;
// Auto mode (UDKeyCommentLinkPreferNative): comment images go to Reddit's native
// upload where the subreddit allows image comments; the link host is only the
// fallback. Consulted at photo-button arming time in ApolloMarkdownToolbarGif.xm.
extern BOOL sCommentLinkPreferNative;

// Share Link Host: rewrites outgoing Reddit URLs in Apollo share sheets. Default
// preserves Apollo's original reddit.com links; Old Reddit/vxReddit swap only
// the host/scheme while preserving the path and query.
typedef NS_ENUM(NSInteger, ShareLinkHost) {
    ShareLinkHostDefault = 0,
    ShareLinkHostOldReddit = 1,
    ShareLinkHostVXReddit = 2,
    ShareLinkHostFXReddit = 3,
};
// extern "C" so the ObjC++ (.xm) caller in ApolloShareAsImageLink.xm and the
// ObjC (.m) definitions in ApolloState.m agree on the unmangled symbol name.
#ifdef __cplusplus
extern "C" {
#endif
// nil for ShareLinkHostDefault — callers keep Apollo's original host.
NSString *ApolloShareLinkHostDomain(ShareLinkHost host);
// Settings-facing label for the picker row and its detail text.
NSString *ApolloShareLinkHostDisplayName(ShareLinkHost host);
#ifdef __cplusplus
}
#endif
extern NSInteger sShareLinkHost;

// Most recently observed Reddit bearer token, captured from outgoing Authorization
// headers. Used by the native Reddit image upload path. nil if Apollo hasn't made an
// authenticated Reddit API call yet.
extern NSString *sLatestRedditBearerToken;

extern BOOL sEnableBulkTranslation;
extern BOOL sAutoTranslateOnAppear;
extern BOOL sTapToTranslate;
extern BOOL sShowTranslationDetails;
extern BOOL sShowTranslationTitleDetails;
extern BOOL sTranslationMarkerUseThemeColor;
extern BOOL sTranslatePostTitles;
extern NSString *sTranslationTargetLanguage;
extern NSString *sTranslationProvider; // @"google", @"libre", @"apple", or @"microsoft"
extern NSString *sLibreTranslateURL;
extern NSString *sLibreTranslateAPIKey;
extern NSString *sMicrosoftTranslateAPIKey;
extern NSString *sMicrosoftTranslateRegion;
// Lowercased 2-letter language codes the user has opted out of translating.
extern NSArray<NSString *> *sTranslationSkipLanguages;
// Redirects Apollo's own Translate button to iOS's on-device Translate sheet
// instead of Apollo's Google Translate web view. See UDKeyAppleTranslateSheet.
extern BOOL sAppleTranslateSheet;

#ifdef __OBJC__
// Whether the on-device Apple translation backend (ApolloAppleTranslation.swift,
// Translation.framework) can run on this OS. iOS 18.0+. Used to gate the "apple"
// provider in Settings and during settings hydration.
static inline BOOL IsAppleTranslationSupported(void) {
    if (@available(iOS 18.0, *)) return YES;
    return NO;
}
#endif

// Web JSON spike (see ApolloWebJSON.m): when enabled, whitelisted subreddit
// listing reads are re-pointed from oauth.reddit.com to www.reddit.com/...json,
// authenticated with a WKWebView-harvested session cookie instead of a bearer
// token. Dormant escape hatch for Reddit API-key revocation waves. Default NO.
extern BOOL sWebJSONEnabled;
// Native Polls (ApolloPollVoting.xm / ApolloPollCompose.xm): master gate for
// the experimental poll voting + creation feature. Default NO. Cached here (not
// re-read from NSUserDefaults per call) because the poll node's layoutSubviews
// hook checks it; loaded at launch and updated live by the Polls settings
// toggle. Read through ApolloPollsFeatureEnabled() (ApolloCommon.h).
extern BOOL sPollsFeatureEnabled;
// Horizontal alignment of the option text next to its radio glyph in a native
// poll (ApolloPollVoting.xm, PollOptionNode layoutSpecThatFits: hook). Default
// Center — matches Apollo's own pre-radio-glyph poll option layout.
typedef NS_ENUM(NSInteger, ApolloPollOptionAlignment) {
    ApolloPollOptionAlignmentCenter = 0,
    ApolloPollOptionAlignmentLeft   = 1,
};
extern NSInteger sPollOptionAlignment;
// Serialized "name=value; name=value" Cookie header harvested from a
// www.reddit.com web login (must include reddit_session). nil until the user
// completes the Web Session Login flow. Persisted in the keychain (it's a full
// account credential) via ApolloWebJSON; migrated out of standardUserDefaults
// on first launch after the keychain switch.
extern NSString *sWebSessionCookieHeader;
// Modhash for the harvested session, read from /api/me.json (data.modhash) at
// login time — NOT a cookie. Attached as X-Modhash on web write actions
// (vote/comment/save/...). nil for anonymous or when the probe returned none.
extern NSString *sWebSessionModhash;
// Username the harvested cookie session authenticates as (/api/me.json
// data.name), captured at login. Used by the identity layer to label the
// cookie account. nil until a successful harvest.
extern NSString *sWebSessionUsername;
// Picture-in-Picture: floating in-app mini-player for comments-page videos
// scrolled out of view. See ApolloPictureInPicture.xm and docs/pip-design.md.
typedef NS_ENUM(NSInteger, ApolloPiPActivationMode) {
    ApolloPiPActivationModeAllVideos = 0,       // any playing video (muted or not)
    ApolloPiPActivationModeUnmutedOnly = 1,     // only videos playing unmuted
    ApolloPiPActivationModeAllVideosAndGifs = 2, // all videos PLUS silent GIFs (in-app card)
};
// Where a fresh PiP card first appears. 0–3 match the corner indices used by
// the geometry code (TL/TR/BL/BR); LastPosition restores the remembered
// screen-relative center, re-clamped for the new video's card size.
typedef NS_ENUM(NSInteger, ApolloPiPStartPosition) {
    ApolloPiPStartPositionTopLeft = 0,
    ApolloPiPStartPositionTopRight = 1,
    ApolloPiPStartPositionBottomLeft = 2,
    ApolloPiPStartPositionBottomRight = 3,
    ApolloPiPStartPositionLastPosition = 4,
};
extern BOOL sPiPEnabled;          // in-app floating mini-player
extern NSInteger sPiPActivationMode;
extern NSInteger sPiPStartPosition;
// Hand off to iOS' system Picture in Picture when the app backgrounds.
// Independent of sPiPEnabled — works for the inline player on its own.
extern BOOL sPiPNativeEnabled;
// Replay the clip when it reaches the end while PiP is presenting it.
// Default YES (Apollo's native inline behavior).
extern BOOL sPiPLoop;
// Open the miniplayer tucked off the edge (hidden). Applies to corner
// Starting Positions only; Last Position remembers hidden state itself.
extern BOOL sPiPStartHidden;
// Optional extra controls on the floating window's overlay. Skip buttons jump
// back/ahead by sPiPSkipSeconds (5/10/15/30); the progress bar is a read-only
// playback position indicator along the bottom edge. Both default OFF.
extern BOOL sPiPSkipButtons;
extern NSInteger sPiPSkipSeconds;
extern BOOL sPiPProgressBar;

// Native NSFW media blur override: 0 follow Reddit setting, 1 always, 2 never.
extern NSInteger sNSFWBlurOverride;
// Tag filter feature (NSFW / Spoiler).
extern BOOL sTagFilterEnabled;
extern NSString *sTagFilterMode;          // @"hide" or @"blur"
extern BOOL sTagFilterNSFW;
extern BOOL sTagFilterSpoiler;
// Lowercased subreddit name -> dictionary with optional keys:
//   nsfw (NSNumber BOOL), spoiler (NSNumber BOOL), mode (NSString).
extern NSDictionary<NSString *, NSDictionary *> *sTagFilterSubredditOverrides;

// Post filters (Reborn) feature — see UserDefaultConstants.h.
// Lowercased subreddit -> @{ @"keywords": NSArray<NSString*>, @"flairs": NSArray<NSString*> }.
extern NSDictionary<NSString *, NSDictionary *> *sPostFilterSubreddits;
// Lowercased subreddit-name substrings (hide any subreddit whose name contains one).
extern NSArray<NSString *> *sPostFilterNameSubstrings;

#pragma mark - Cross-module predicates

#ifdef __cplusplus
extern "C" {
#endif
// Whether this CommentsViewController is the media-owned glass pane
// (implemented in ApolloSwipeUpComments.xm). Other comment-screen features
// (e.g. the collapse-cover machinery in ApolloCommentsCollapse.xm) branch on
// this: the pane's cells are deliberately transparent, so stock
// cover/animation treatments designed for the opaque screen misrender there.
BOOL ApolloSwipeCommentsIsPaneCommentsController(UIViewController *controller);
#ifdef __cplusplus
}
#endif
