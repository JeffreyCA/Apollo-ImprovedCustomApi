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
extern NSInteger sPreferredGIFFallbackFormat;

extern NSInteger sReadPostMaxCount;

// 0 = Default (off), 1 = Remember from Full Screen, 2 = Always
extern NSInteger sUnmuteCommentsVideos;

extern BOOL sProxyImgurDDG;
extern BOOL sShowUserAvatars;
extern BOOL sUseProfileAvatarTabIcon;
extern BOOL sShowSubredditHeaders;
extern BOOL sAutoHideTabBarShowOnIdle;
extern BOOL sModernSubredditDividers;
// Master toggle for subreddit list enhancements (see UDKeySubredditListEnhancements).
extern BOOL sSubredditListEnhancements;

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
extern NSInteger sLinkPreviewCardColor;

// Media upload host selection. Imgur is the default; Reddit uses Apollo's signed-in
// session to upload directly to Reddit's media storage.
typedef NS_ENUM(NSInteger, ImageUploadProvider) {
    ImageUploadProviderImgur = 0,
    ImageUploadProviderReddit = 1,
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
extern NSString *sTranslationProvider;
extern NSString *sLibreTranslateURL;
extern NSString *sLibreTranslateAPIKey;
// Lowercased 2-letter language codes the user has opted out of translating.
extern NSArray<NSString *> *sTranslationSkipLanguages;

// Tag filter feature (NSFW / Spoiler).
extern BOOL sTagFilterEnabled;
extern NSString *sTagFilterMode;          // @"hide" or @"blur"
extern BOOL sTagFilterNSFW;
extern BOOL sTagFilterSpoiler;
// Lowercased subreddit name -> dictionary with optional keys:
//   nsfw (NSNumber BOOL), spoiler (NSNumber BOOL), mode (NSString).
extern NSDictionary<NSString *, NSDictionary *> *sTagFilterSubredditOverrides;
