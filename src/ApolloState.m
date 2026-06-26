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
BOOL sShowRecentlyReadThumbnails = YES;
BOOL sFeedTextPostThumbnails = YES;
NSInteger sPreferredGIFFallbackFormat = 1; // 0=GIF, 1=MP4

NSInteger sReadPostMaxCount = 0;

NSInteger sUnmuteCommentsVideos = 0; // 0=Default, 1=Remember from Full Screen, 2=Always

BOOL sProxyImgurDDG = NO;
BOOL sShowUserAvatars = NO;
BOOL sUseProfileAvatarTabIcon = NO;
BOOL sSocialLinksInProfile = YES;
BOOL sShowSubredditHeaders = NO;
BOOL sCommunityHighlights = NO;
BOOL sCommunityHighlightsWeb = NO;
BOOL sAutoHideTabBarShowOnIdle = NO;
BOOL sKeepSearchBarInPlace = NO;
BOOL sModernSubredditDividers = YES;
BOOL sSubredditListEnhancements = YES;
BOOL sEnableFlairColors = NO;
BOOL sEnableInlineImages = NO;
NSInteger sInlineImageAlignment = ApolloInlineImageAlignmentCenter;
NSInteger sAutoplayInlineGIFMode = ApolloAutoplayInlineGIFModeDefault;
NSInteger sLinkPreviewBodyMode = ApolloLinkPreviewModeOff;
NSInteger sLinkPreviewCommentsMode = ApolloLinkPreviewModeOff;
NSInteger sLinkPreviewCardColor = ApolloLinkPreviewCardColorNeutral;
NSString *sLinkPreviewCardColorHex = nil;
volatile uint32_t sLinkPreviewCardColorPacked = 0;
NSInteger sImageUploadProvider = ImageUploadProviderImgur;

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

BOOL sTagFilterEnabled = NO;
NSString *sTagFilterMode = @"blur";
BOOL sTagFilterNSFW = YES;
BOOL sTagFilterSpoiler = YES;
NSDictionary<NSString *, NSDictionary *> *sTagFilterSubredditOverrides = nil;
