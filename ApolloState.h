#import <Foundation/Foundation.h>

extern NSString *sRedditClientId;
extern NSString *sImgurClientId;
extern NSString *sRedirectURI;
extern NSString *sUserAgent;
extern NSString *sRandomSubredditsSource;
extern NSString *sRandNsfwSubredditsSource;
extern NSString *sTrendingSubredditsSource;
extern NSString *sTrendingSubredditsLimit;

extern BOOL sBlockAnnouncements;
extern BOOL sShowRecentlyReadThumbnails;
extern NSInteger sPreferredGIFFallbackFormat;

extern NSInteger sReadPostMaxCount;

// 0 = Default (off), 1 = Remember from Full Screen, 2 = Always
extern NSInteger sUnmuteCommentsVideos;

extern BOOL sProxyImgurDDG;

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
