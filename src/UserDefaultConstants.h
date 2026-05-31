// UserDefaults keys
static NSString *const UDKeyRedditClientId = @"RedditApiClientId";
// Reddit OAuth client secret. Empty for installed-app credentials; required
// when the self-hosted notification backend stores per-account creds and
// performs refresh-token exchanges server-side.
static NSString *const UDKeyRedditClientSecret = @"RedditApiClientSecret";
static NSString *const UDKeyImgurClientId = @"ImgurApiClientId";
static NSString *const UDKeyGiphyAPIKey = @"GiphyAPIKey";
static NSString *const UDKeyImageChestAPIToken = @"ImageChestAPIToken";
static NSString *const UDKeyRedirectURI = @"RedirectURI";
static NSString *const UDKeyUserAgent = @"UserAgent";
static NSString *const UDKeyBlockAnnouncements = @"DisableApollonouncements";
static NSString *const UDKeyEnableFLEX = @"EnableFlexDebugging";
static NSString *const UDKeyShowRandNsfw = @"ShowRandNsfwButton";
static NSString *const UDKeyRandomSubredditsSource = @"RandomSubredditsSource";
static NSString *const UDKeyRandNsfwSubredditsSource = @"RandNsfwSubredditsSource";
static NSString *const UDKeyTrendingSubredditsSource = @"TrendingSubredditsSource";
static NSString *const UDKeyTrendingSubredditsLimit = @"TrendingSubredditsLimit";
// Master toggle (short-term fix) for all subreddit list polish/enhancements. Default
// YES. Modern Subreddit Dividers depends on it — that row hides when this is off.
static NSString *const UDKeySubredditListEnhancements = @"SubredditListEnhancements";
static NSString *const UDKeyModernSubredditDividers = @"ModernSubredditDividers";
static NSString *const ApolloModernSubredditDividersChangedNotification = @"ApolloModernSubredditDividersChangedNotification";
static NSString *const UDKeyReadPostMaxCount = @"ReadPostMaxCount";
static NSString *const UDKeyShowRecentlyReadThumbnails = @"ShowRecentlyReadThumbnails";
static NSString *const UDKeyPreferredGIFFallbackFormat = @"PreferredGIFFallbackFormat";
static NSString *const UDKeyUnmuteCommentsVideos = @"UnmuteCommentsVideos";
static NSString *const UDKeyOpenLinksInSteamApp = @"OpenLinksInSteamApp";
static NSString *const UDKeyCollapsePinnedComments = @"CollapsePinnedComments";
static NSString *const UDKeyFilterNSFWRecentlyRead = @"FilterNSFWRecentlyRead";
static NSString *const UDKeyProxyImgurDDG = @"ProxyImgurDDG";
static NSString *const UDKeyImageUploadProvider = @"ImageUploadProvider";
static NSString *const UDKeyShowUserAvatars = @"ShowUserAvatars";
static NSString *const UDKeyUseProfileAvatarTabIcon = @"UseProfileAvatarTabIcon";
static NSString *const UDKeyShowSubredditHeaders = @"ShowSubredditHeaders";
static NSString *const UDKeyAutoHideTabBarShowOnIdle = @"AutoHideTabBarShowOnIdle";
// Render image URLs (i.redd.it, preview.redd.it, i.imgur.com, generic .png/.jpg/.jpeg/.webp)
// inline within post selftext and comments instead of leaving them as plain text links.
static NSString *const UDKeyEnableInlineImages = @"EnableInlineImages";
// Horizontal alignment for inline media that is narrower than the row (e.g. tall portrait images).
// 0 = Center (default), 1 = Left, 2 = Right.
static NSString *const UDKeyInlineImageAlignment = @"InlineImageAlignment";

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

// Self-hosted notification backend (forked apollo-backend). Empty disables —
// the legacy hosts remain in the blocklist and requests are silently dropped.
static NSString *const UDKeyNotificationBackendURL = @"NotificationBackendURL";
// Optional shared secret matching the backend's REGISTRATION_SECRET env var.
// When set, sent as X-Registration-Token on the three POST registration
// endpoints (/v1/device, /v1/device/{apns}/account[s]).
static NSString *const UDKeyNotificationBackendRegistrationToken = @"NotificationBackendRegistrationToken";

// Rich link preview cards: 0 = Off, 1 = Compact, 2 = Full.
static NSString *const UDKeyLinkPreviewBodyMode = @"LinkPreviewBodyMode";
static NSString *const UDKeyLinkPreviewCommentsMode = @"LinkPreviewCommentsMode";
static NSString *const UDKeyLinkPreviewCardColor = @"LinkPreviewCardColor";
static NSString *const ApolloLinkPreviewModeDidChangeNotification = @"ApolloLinkPreviewModeDidChangeNotification";
