#import "ApolloState.h"

NSString *sRedditClientId = nil;
NSString *sImgurClientId = nil;
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
