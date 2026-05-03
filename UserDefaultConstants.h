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
static NSString *const UDKeyReadPostMaxCount = @"ReadPostMaxCount";
static NSString *const UDKeyShowRecentlyReadThumbnails = @"ShowRecentlyReadThumbnails";
static NSString *const UDKeyPreferredGIFFallbackFormat = @"PreferredGIFFallbackFormat";
static NSString *const UDKeyUnmuteCommentsVideos = @"UnmuteCommentsVideos";
static NSString *const UDKeyOpenLinksInSteamApp = @"OpenLinksInSteamApp";
static NSString *const UDKeyCollapsePinnedComments = @"CollapsePinnedComments";
static NSString *const UDKeyFilterNSFWRecentlyRead = @"FilterNSFWRecentlyRead";
static NSString *const UDKeyProxyImgurDDG = @"ProxyImgurDDG";

// Bulk translation feature
static NSString *const UDKeyEnableBulkTranslation = @"EnableBulkTranslation";
static NSString *const UDKeyAutoTranslateOnAppear = @"AutoTranslateOnAppear";
static NSString *const UDKeyTranslatePostTitles = @"TranslatePostTitles";
static NSString *const UDKeyTranslationTargetLanguage = @"TranslationTargetLanguage";
static NSString *const UDKeyTranslationProvider = @"TranslationProvider"; // google | libre
static NSString *const UDKeyTranslationProviderUserSelected = @"TranslationProviderUserSelected";
static NSString *const UDKeyLibreTranslateURL = @"LibreTranslateURL";
static NSString *const UDKeyLibreTranslateAPIKey = @"LibreTranslateAPIKey";
// Array<String> of 2-letter language codes to leave untranslated (detected source language).
static NSString *const UDKeyTranslationSkipLanguages = @"TranslationSkipLanguages";

// Tag filters (NSFW / Spoiler) — hide or blur posts in the feed based on
// Reddit's built-in tags. Brand Affiliate is intentionally absent because
// Apollo's RDKLink does not deserialize that field.
static NSString *const UDKeyTagFilterEnabled = @"TagFilterEnabled";        // master switch
static NSString *const UDKeyTagFilterMode = @"TagFilterMode";              // "hide" | "blur"
static NSString *const UDKeyTagFilterNSFW = @"TagFilterNSFW";              // global NSFW
static NSString *const UDKeyTagFilterSpoiler = @"TagFilterSpoiler";        // global Spoiler
// Per-subreddit overrides: dictionary keyed by lowercased subreddit name.
// Each value is a dictionary with optional keys:
//   "nsfw"    -> NSNumber BOOL  (overrides global NSFW for this sub)
//   "spoiler" -> NSNumber BOOL  (overrides global Spoiler for this sub)
//   "mode"    -> NSString       ("hide" | "blur"; overrides global mode)
// Missing keys fall back to global settings.
static NSString *const UDKeyTagFilterSubredditOverrides = @"TagFilterSubredditOverrides";
