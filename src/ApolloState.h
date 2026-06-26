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
extern BOOL sShowRecentlyReadThumbnails;
extern BOOL sFeedTextPostThumbnails;
extern NSInteger sPreferredGIFFallbackFormat;

extern NSInteger sReadPostMaxCount;

// 0 = Default (off), 1 = Remember from Full Screen, 2 = Always
extern NSInteger sUnmuteCommentsVideos;

extern BOOL sProxyImgurDDG;
extern BOOL sShowUserAvatars;
extern BOOL sUseProfileAvatarTabIcon;
// When ON, a redditor's profile social links (Buy Me a Coffee, Instagram, X, …) are
// shown in the profile header between the username and bio: a tappable pill for a
// single link, or a row of brand badges that opens a slide-up sheet for several.
// Rendered inside the tweak's custom profile header, so it needs sShowUserAvatars ON.
// See ApolloProfileSocialLinks.{h,m}.
extern BOOL sSocialLinksInProfile;
extern BOOL sShowSubredditHeaders;
// When ON, a horizontally-scrolling "Community Highlights" carousel of the
// subreddit's pinned/stickied posts is shown at the top of the feed (mirrors
// new-Reddit / the official app). See ApolloSubredditHighlights.xm.
extern BOOL sCommunityHighlights;
// When ON (and sCommunityHighlights ON), a hidden WKWebView loads the subreddit's
// new-Reddit page to harvest the FULL highlights set (up to 6), beyond the 2 the
// REST API exposes. Heavier (loads the web page per sub); opt-in. See
// ApolloSubredditHighlights.xm (ApolloHLWebFetch).
extern BOOL sCommunityHighlightsWeb;
extern BOOL sAutoHideTabBarShowOnIdle;
// When ON, neutralizes Apollo's feed/subreddit search takeover (nav-hide + fade + toolbar
// dock/grow); the field stays put and results populate the feed in place. Liquid Glass only;
// mutually exclusive with the default nav-hide mode. See ApolloSearchInPlace.xm.
extern BOOL sKeepSearchBarInPlace;
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
    ApolloAutoplayInlineGIFModeDefault  = 0, // follow Apollo's Autoplay GIFs/Videos
    ApolloAutoplayInlineGIFModeNever    = 1,
    ApolloAutoplayInlineGIFModeWiFiOnly = 2,
    ApolloAutoplayInlineGIFModeAlways   = 3,
};
extern NSInteger sAutoplayInlineGIFMode;

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

// Most recently observed Reddit bearer token, captured from outgoing Authorization
// headers. Used by the native Reddit image upload path. nil if Apollo hasn't made an
// authenticated Reddit API call yet.
extern NSString *sLatestRedditBearerToken;

extern BOOL sEnableBulkTranslation;
extern BOOL sAutoTranslateOnAppear;
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

// Tag filter feature (NSFW / Spoiler).
extern BOOL sTagFilterEnabled;
extern NSString *sTagFilterMode;          // @"hide" or @"blur"
extern BOOL sTagFilterNSFW;
extern BOOL sTagFilterSpoiler;
// Lowercased subreddit name -> dictionary with optional keys:
//   nsfw (NSNumber BOOL), spoiler (NSNumber BOOL), mode (NSString).
extern NSDictionary<NSString *, NSDictionary *> *sTagFilterSubredditOverrides;
