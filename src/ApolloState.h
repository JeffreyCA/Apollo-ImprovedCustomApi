#import <Foundation/Foundation.h>

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
extern NSInteger sPreferredGIFFallbackFormat;

extern NSInteger sReadPostMaxCount;

// 0 = Default (off), 1 = Remember from Full Screen, 2 = Always
extern NSInteger sUnmuteCommentsVideos;

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
extern BOOL sShowUserAvatars;
extern BOOL sUseProfileAvatarTabIcon;
// When ON (default), profile pages show Reborn's detailed profile — the banner,
// large avatar/snoovatar, display name, bio, and the Social Links band (Buy Me a
// Coffee, Instagram, X, …). When OFF, profiles revert to Apollo's compact stock
// layout — the detailed header is not installed and any existing one is torn down.
// Independent of sShowUserAvatars (inline avatars). The Social Links band lives
// inside this header, so it is gated on this same flag. Default ON via
// registerDefaults. See ApolloUserAvatars.xm and ApolloProfileSocialLinks.{h,m}.
extern BOOL sShowDetailedProfiles;
extern BOOL sShowSubredditHeaders;
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
extern BOOL sAutoHideTabBarShowOnIdle;
// Which side the iOS 26 minimized (Liquid Glass) tab bar pill docks on:
// 0 = Left (system default), 1 = Right. Read live at layout time so a change
// applies without relaunch. Default 0 via registerDefaults
// (UDKeyTabBarCollapseSide). See ApolloTabBarCollapseSide.xm.
extern NSInteger sTabBarCollapseSide;
// iPad + Liquid Glass only. When ON, docks the iOS 26 floating tab bar at the
// bottom (classic) instead of the top-center pill. Opt-in; default OFF via
// registerDefaults. Temporary stopgap for issue #387. See ApolloIPadTabBarBottom.xm.
extern BOOL sIPadTabBarBottom;
// When ON, neutralizes Apollo's feed/subreddit search takeover (nav-hide + fade + toolbar
// dock/grow); the field stays put and results populate the feed in place. Liquid Glass only;
// mutually exclusive with the default nav-hide mode. See ApolloSearchInPlace.xm.
extern BOOL sKeepSearchBarInPlace;
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
// The tappable "info" icons — % upvoted, timestamp, and edited — all share one
// display style, chosen by these two mutually-exclusive toggles: Popup = the
// dismissable alert; Overlay = the small auto-fading card above the icon. With both
// off, direct taps use Apollo's stock behavior; picking one in the loupe does nothing.
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
extern BOOL sModernSubredditDividers;
// Master toggle for subreddit list enhancements (see UDKeySubredditListEnhancements).
extern BOOL sSubredditListEnhancements;

// Color post (link) flairs and user/author flairs using Reddit's assigned
// colors (filled pill + matching text color). When NO, Apollo's default grey
// flair styling is preserved. See ApolloFlairColors.xm.
extern BOOL sEnableFlairColors;

// Render image URLs inline in post selftext and comments. Defaults to YES on
// fresh installs (registerDefaults). When NO, Apollo's native behavior (text
// link + optional link card) is preserved. See ApolloInlineImages.xm.
extern BOOL sEnableInlineImages;
// Master toggle for chat media enhancements (inline images/GIFs/emoji/snoomoji in DM/chat
// bubbles + working media sends + tap-to-fullscreen). Default ON via registerDefaults; OFF =
// stock Apollo chat. Independent of sShowUserAvatars. See ApolloChatInlineImages/Composer.xm.
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
// Render-safe snapshot of the card color, readable from any thread (an aligned
// 32-bit volatile load is atomic on arm64). 0 = Default; otherwise
// (1<<24) | (R<<16) | (G<<8) | B.
extern volatile uint32_t sLinkPreviewCardColorPacked;

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
extern NSString *sTranslationProvider; // @"google", @"libre", or @"apple"
extern NSString *sLibreTranslateURL;
extern NSString *sLibreTranslateAPIKey;
// Lowercased 2-letter language codes the user has opted out of translating.
extern NSArray<NSString *> *sTranslationSkipLanguages;

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
