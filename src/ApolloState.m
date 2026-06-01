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
BOOL sShowRecentlyReadThumbnails = YES;
NSInteger sPreferredGIFFallbackFormat = 1; // 0=GIF, 1=MP4

NSInteger sReadPostMaxCount = 0;

NSInteger sUnmuteCommentsVideos = 0; // 0=Default, 1=Remember from Full Screen, 2=Always

BOOL sProxyImgurDDG = NO;
BOOL sShowUserAvatars = NO;
BOOL sUseProfileAvatarTabIcon = NO;
BOOL sShowSubredditHeaders = NO;
BOOL sAutoHideTabBarShowOnIdle = NO;
BOOL sModernSubredditDividers = YES;
BOOL sSubredditListEnhancements = YES;
BOOL sEnableInlineImages = NO;
NSInteger sInlineImageAlignment = ApolloInlineImageAlignmentCenter;
NSInteger sLinkPreviewBodyMode = ApolloLinkPreviewModeOff;
NSInteger sLinkPreviewCommentsMode = ApolloLinkPreviewModeOff;
NSInteger sLinkPreviewCardColor = ApolloLinkPreviewCardColorNeutral;
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

BOOL sTagFilterEnabled = NO;
NSString *sTagFilterMode = @"blur";
BOOL sTagFilterNSFW = YES;
BOOL sTagFilterSpoiler = YES;
NSDictionary<NSString *, NSDictionary *> *sTagFilterSubredditOverrides = nil;
