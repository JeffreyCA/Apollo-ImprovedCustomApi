// UserDefaults keys
static NSString *const UDKeyRedditClientId = @"RedditApiClientId";
static NSString *const UDKeyImgurClientId = @"ImgurApiClientId";
static NSString *const UDKeyRedirectURI = @"RedirectURI";
static NSString *const UDKeyUserAgent = @"UserAgent";
static NSString *const UDKeyBlockAnnouncements = @"DisableApollonouncements";
static NSString *const UDKeyEnableFLEX = @"EnableFlexDebugging";
static NSString *const UDKeyShowRandNsfw = @"ShowRandNsfwButton";
static NSString *const UDKeyRandomSubredditsSource = @"RandomSubredditsSource";
static NSString *const UDKeyRandNsfwSubredditsSource = @"RandNsfwSubredditsSource";
static NSString *const UDKeyTrendingSubredditsSource = @"TrendingSubredditsSource";
static NSString *const UDKeyTrendingSubredditsLimit = @"TrendingSubredditsLimit";

static NSString *const UDKeyApolloShowUnreadComments = @"ShowUnreadComments";

/*
    The UserDefaults key 'PostCommentsSnapshots' stores a snapshot JSON array of post IDs and their last-read timestamps and total comments:
    [
        "<post id 1>",
        {
            "timestamp": 726627090.96476996, // Reference date of January 2001
            "totalComments": 442
        },
        "<post id 2>",
        {
            "timestamp": 726627790.97460103,
            "totalComments": 62
        },
        ...
    ]
*/
static NSString *const UDKeyApolloPostCommentsSnapshots = @"PostCommentsSnapshots";
