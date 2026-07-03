#import "ApolloState.h"

NSString *sRedditClientId = nil;
NSString *sRedditClientSecret = nil;
NSString *sImgurClientId = nil;
NSString *sImageChestAPIToken = nil;
NSString *sRedirectURI = nil;
NSString *sUserAgent = nil;
NSString *sRandomSubredditsSource = nil;
NSString *sRandNsfwSubredditsSource = nil;
NSString *sTrendingSubredditsSource = nil;
NSString *sTrendingSubredditsLimit = nil;

BOOL sBlockAnnouncements = NO;
BOOL sShowDeletedComments = NO;
BOOL sTapToRevealDeletedComments = NO;
BOOL sPassiveDeletedComments = NO;
BOOL sShowRecentlyReadThumbnails = YES;
BOOL sFeedTextPostThumbnails = YES;
NSInteger sPreferredGIFFallbackFormat = 1; // 0=GIF, 1=MP4

NSInteger sReadPostMaxCount = 0;

NSInteger sUnmuteCommentsVideos = 0; // 0=Default, 1=Remember from Full Screen, 2=Always

BOOL sVideoHoldSpeedEnabled = YES;   // effective default ON via registerDefaults (UDKeyVideoHoldSpeedEnabled)
float sVideoHoldSpeed = 2.0f;        // effective default 2.0× via registerDefaults (UDKeyVideoHoldSpeed)

BOOL sProxyImgurDDG = NO;
BOOL sShowUserAvatars = NO;
BOOL sUseProfileAvatarTabIcon = NO;
BOOL sShowDetailedProfiles = YES;   // effective default ON via registerDefaults (UDKeyShowDetailedProfiles)
BOOL sShowSubredditHeaders = NO;
BOOL sCommunityHighlights = NO;
BOOL sCommunityHighlightsWeb = NO;
BOOL sAutoHideTabBarShowOnIdle = NO;
BOOL sIPadTabBarBottom = NO;   // opt-in (default OFF via registerDefaults, UDKeyIPadTabBarBottom); iPad-gated in the module
BOOL sKeepSearchBarInPlace = NO;
BOOL sIconRowMagnifier = YES;   // effective default ON via registerDefaults (UDKeyIconRowMagnifier)
BOOL sModernSubredditDividers = YES;
BOOL sSubredditListEnhancements = YES;
BOOL sEnableFlairColors = NO;
BOOL sEnableInlineImages = NO;
BOOL sEnableChatMedia = NO;   // effective default YES via registerDefaults (UDKeyEnableChatMedia)
BOOL sEnableAISummaries = NO;
BOOL sLiveCommentsFollow = YES;   // effective default ON via registerDefaults (UDKeyLiveCommentsFollow)
BOOL sEnableAIPostSummaries = YES;
BOOL sEnableAICommentSummaries = YES;
BOOL sEnableTapToSummarize = NO;
BOOL sEnableAIAutoExpandSummaries = NO;
NSInteger sInlineImageAlignment = ApolloInlineImageAlignmentCenter;
NSInteger sAutoplayInlineGIFMode = ApolloAutoplayInlineGIFModeDefault;
NSInteger sLinkPreviewBodyMode = ApolloLinkPreviewModeOff;
NSInteger sLinkPreviewCommentsMode = ApolloLinkPreviewModeOff;
NSInteger sLinkPreviewCardColor = ApolloLinkPreviewCardColorNeutral;
NSString *sLinkPreviewCardColorHex = nil;
volatile uint32_t sLinkPreviewCardColorPacked = 0;
NSInteger sImageUploadProvider = ImageUploadProviderImgur;
NSInteger sCommentLinkHost = CommentLinkHostOff;

NSString *sLatestRedditBearerToken = nil;

BOOL sEnableBulkTranslation = NO;
BOOL sAutoTranslateOnAppear = YES;
BOOL sTranslatePostTitles = NO;
NSString *sTranslationTargetLanguage = nil;
NSString *sTranslationProvider = nil;
NSString *sLibreTranslateURL = nil;
NSString *sLibreTranslateAPIKey = nil;
NSArray<NSString *> *sTranslationSkipLanguages = nil;

BOOL sWebJSONEnabled = NO;
NSString *sWebSessionCookieHeader = nil;
NSString *sWebSessionModhash = nil;
NSString *sWebSessionUsername = nil;
BOOL sPiPEnabled = NO;
NSInteger sPiPActivationMode = ApolloPiPActivationModeUnmutedOnly;
NSInteger sPiPStartPosition = ApolloPiPStartPositionTopRight;
BOOL sPiPNativeEnabled = NO;
BOOL sPiPLoop = YES;
BOOL sPiPStartHidden = NO;
BOOL sPiPSkipButtons = NO;
NSInteger sPiPSkipSeconds = 10;
BOOL sPiPProgressBar = NO;

BOOL sTagFilterEnabled = NO;
NSString *sTagFilterMode = @"blur";
BOOL sTagFilterNSFW = YES;
BOOL sTagFilterSpoiler = YES;
NSDictionary<NSString *, NSDictionary *> *sTagFilterSubredditOverrides = nil;

NSDictionary<NSString *, NSDictionary *> *sPostFilterSubreddits = nil;
NSArray<NSString *> *sPostFilterNameSubstrings = nil;

float ApolloSanitizedHoldSpeed(float value) {
    // The exact speeds offered by the picker (mirrors the video player's menu,
    // minus 1.0× — holding at normal speed would be a no-op).
    static const float kSupported[] = { 0.25f, 0.5f, 0.75f, 1.25f, 1.5f, 2.0f };
    for (size_t i = 0; i < sizeof(kSupported) / sizeof(kSupported[0]); i++) {
        if (fabsf(value - kSupported[i]) < 0.001f) return kSupported[i];
    }
    return 2.0f;   // unset (0) / corrupt / unsupported → default boost
}
