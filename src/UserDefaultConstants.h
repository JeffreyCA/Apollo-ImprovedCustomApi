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
// Per-account Reddit OAuth credential overrides (see ApolloAccountCredentials.{h,m}).
// Flat dictionary: lowercased username -> {clientId, clientSecret, redirectURI}.
// An account with no entry here falls back to the global client id/secret/redirect
// URI above.
static NSString *const UDKeyPerAccountCredentials = @"PerAccountAPICredentials";
static NSString *const UDKeyUseCustomOAuthSignIn = @"UseCustomOAuthSignIn";
static NSString *const UDKeyUserAgent = @"UserAgent";
static NSString *const UDKeyBlockAnnouncements = @"DisableApollonouncements";
static NSString *const UDKeyEnableFLEX = @"EnableFlexDebugging";
// Login-persistence debug (dev-only, gated behind FLEX). Force the account keychain read to
// miss (simulate the broken-keychain -25300), and/or disable enumeration recovery, so the
// wipe->recover chain can be exercised on any device. Inert unless set.
static NSString *const UDKeyDebugForceAccountReadMiss = @"ApolloDebugForceAccountReadMiss";
static NSString *const UDKeyDebugDisableKeychainRecovery = @"ApolloDebugDisableKeychainRecovery";
static NSString *const UDKeyShowRandNsfw = @"ShowRandNsfwButton";
static NSString *const UDKeyRandomSubredditsSource = @"RandomSubredditsSource";
static NSString *const UDKeyRandNsfwSubredditsSource = @"RandNsfwSubredditsSource";
static NSString *const UDKeyTrendingSubredditsSource = @"TrendingSubredditsSource";
static NSString *const UDKeyTrendingSubredditsLimit = @"TrendingSubredditsLimit";
// Master toggle (short-term fix) for all subreddit list polish/enhancements. Default
// YES. Modern Subreddit Dividers depends on it — that row hides when this is off.
static NSString *const UDKeySubredditListEnhancements = @"SubredditListEnhancements";
// Subreddits the user moderates but chose to hide from the Subreddits list
// (Reddit offers no way to leave or delete some dead subreddits). Array of
// display names, compared case-insensitively.
static NSString *const UDKeyHiddenModeratorSubreddits = @"HiddenModeratorSubreddits";
static NSString *const UDKeyModernSubredditDividers = @"ModernSubredditDividers";
static NSString *const ApolloModernSubredditDividersChangedNotification = @"ApolloModernSubredditDividersChangedNotification";
// Color post (link) and user/author flairs with Reddit's assigned colors. Default NO.
static NSString *const UDKeyEnableFlairColors = @"EnableFlairColors";
static NSString *const ApolloFlairColorsChangedNotification = @"ApolloFlairColorsChangedNotification";
static NSString *const UDKeyReadPostMaxCount = @"ReadPostMaxCount";
static NSString *const UDKeyShowRecentlyReadThumbnails = @"ShowRecentlyReadThumbnails";
static NSString *const UDKeyPreferredGIFFallbackFormat = @"PreferredGIFFallbackFormat";
static NSString *const UDKeyUnmuteCommentsVideos = @"UnmuteCommentsVideos";
// "Hold for Video Speed": press-and-hold the right side of a fullscreen video to
// play at a chosen speed while held. Master toggle (default YES via
// registerDefaults — preserves the original always-on behaviour) and the speed
// applied while held (one of 0.25/0.5/0.75/1.25/1.5/2.0; default 2.0×). See
// ApolloVideoHoldSpeed.xm.
static NSString *const UDKeyVideoHoldSpeedEnabled = @"VideoHoldSpeedEnabled";
static NSString *const UDKeyVideoHoldSpeed = @"VideoHoldSpeed";
static NSString *const UDKeyOpenLinksInSteamApp = @"OpenLinksInSteamApp";
// Apollo NATIVE key, mirrored by Reborn's "Open in App" settings screen
// (ApolloOpenInAppViewController) so the scattered native "open in app" rows can
// be gathered in one place and hidden from Apollo's own General settings. We
// read/write the same key Apollo uses, so the two stay in sync.
static NSString *const UDKeyOpenVideosInYouTubeApp = @"OpenVideosInYouTubeApp";
// Reborn "Open in App" deep-link toggles — open these services' links in their
// app via Universal Links (see ApolloShareLinks.xm). Default OFF (opt-in). The
// key string literals are duplicated in ApolloShareLinks.xm; keep them in sync.
static NSString *const UDKeyOpenLinksInGitHubApp  = @"OpenLinksInGitHubApp";
static NSString *const UDKeyOpenLinksInBlueskyApp = @"OpenLinksInBlueskyApp";
static NSString *const UDKeyCollapsePinnedComments = @"CollapsePinnedComments";
static NSString *const UDKeyShowDeletedComments = @"ShowDeletedComments";
static NSString *const UDKeyTapToRevealDeletedComments = @"TapToRevealDeletedComments";
// Passive mode: deleted comments stay off globally, but can be turned on for a
// single comment thread from the comments "..." menu; the per-thread switch
// resets when that thread is left. See ApolloDeletedCommentsMenu.xm.
static NSString *const UDKeyPassiveDeletedComments = @"PassiveDeletedComments";
static NSString *const UDKeyLegacyRevealDeletedComments = @"RevealDeletedComments";
static NSString *const UDKeyFilterNSFWRecentlyRead = @"FilterNSFWRecentlyRead";
static NSString *const UDKeyProxyImgurDDG = @"ProxyImgurDDG";
static NSString *const UDKeyImageUploadProvider = @"ImageUploadProvider";
// Secondary host for images added in the COMMENT/REPLY editor (CommentLinkHost
// enum). Off (default) keeps comment uploads on the Media Upload Host above;
// Imgur/Img Chest route comment-editor uploads there and post the result as a
// plain link (no native Reddit media) so they work in subreddits that disallow
// image/GIF comments. See ApolloMarkdownToolbarGif.xm + ApolloImageUploadHost.xm.
static NSString *const UDKeyCommentLinkHost = @"CommentLinkHost";
// Posted after sCommentLinkHost changes so open composers re-apply the comment
// media-permission gating (the image button un-blocks while a link host is set).
static NSString *const ApolloCommentLinkHostChangedNotification = @"ApolloCommentLinkHostChangedNotification";
static NSString *const UDKeyShowUserAvatars = @"ShowUserAvatars";
static NSString *const UDKeyUseProfileAvatarTabIcon = @"UseProfileAvatarTabIcon";
// When ON (default), profile pages show Reborn's detailed profile — the banner,
// large avatar/snoovatar, display name, bio, and the Social Links band. When OFF,
// the profile page reverts to Apollo's compact stock layout: the detailed header is
// not installed, and any header already on screen is torn down (restoring Apollo's
// native table header). Independent of "Show User Profile Pictures"
// (UDKeyShowUserAvatars), which governs the inline avatars next to usernames.
// See ApolloUserAvatars.xm and ApolloProfileSocialLinks.m. Default YES.
static NSString *const UDKeyShowDetailedProfiles = @"ShowDetailedProfiles";
static NSString *const UDKeyShowSubredditHeaders = @"ShowSubredditHeaders";
// Backing values for the single Community Highlights picker. Keeping the old
// keys maps existing settings naturally: both YES = Full, master only = Partial,
// master NO = Off.
static NSString *const UDKeyCommunityHighlights = @"CommunityHighlights";
static NSString *const UDKeyCommunityHighlightsWeb = @"CommunityHighlightsWeb";
static NSString *const UDKeyAutoHideTabBarShowOnIdle = @"AutoHideTabBarShowOnIdle";
// Which side the iOS 26 minimized (Liquid Glass) tab bar pill docks on when
// "Hide Bars on Scroll" collapses it: 0 = Left (system default), 1 = Right.
// Only meaningful while the native tabBarMinimizeBehavior path is active
// (Liquid Glass); the pre-26 hide-bars path has no pill. The Left/Right/Off
// choice is surfaced on Apollo's native Settings > General > "Hide Bars on
// Scroll" row (Off = the native toggle off). See ApolloTabBarCollapseSide.xm.
static NSString *const UDKeyTabBarCollapseSide = @"TabBarCollapseSide";
// When ON, focusing the main feed / subreddit search keeps the nav bar and the search
// field in place (results populate the feed below the field) instead of Apollo's stock
// "search takeover" (nav slides away + fades, field docks to the top and grows). Mutually
// exclusive with the default nav-hide mode. Liquid Glass only. Default NO. See ApolloSearchInPlace.xm.
static NSString *const UDKeyKeepSearchBarInPlace = @"KeepSearchBarInPlace";
// iPad only, Liquid Glass only. When ON, forces the iOS 26 floating tab bar to
// dock at the BOTTOM (classic tab bar) instead of the top-center pill, which on
// iPad overlaps Apollo's search bar. Temporary stopgap for issue #387 until the
// real iPad build lands. Opt-in; default OFF via registerDefaults. See ApolloIPadTabBarBottom.xm.
static NSString *const UDKeyIPadTabBarBottom = @"IPadTabBarBottom";
static NSString *const ApolloIPadTabBarBottomChangedNotification = @"ApolloIPadTabBarBottomChangedNotification";
// When ON, press-and-hold anywhere on a post info row (score, comments,
// timestamp, 🌐 translation marker…) shows the glass-slider magnifier loupe: the
// row is zoomed in a Liquid Glass card, sliding moves the selection pill
// icon-to-icon, releasing activates it (score = upvote, comments = open at the
// comment section, timestamp = posted-ago alert, % = upvote-ratio alert,
// 🌐 = toggle title translation). Default ON via registerDefaults.
// See ApolloStatsRowTouch.xm.
static NSString *const UDKeyIconRowMagnifier = @"IconRowMagnifier";
// Per-icon "is this info-row icon tappable" switches, exposed on the Info Row
// settings sub-screen. Each defaults ON (registerDefaults) so behaviour matches
// the shipped tweak. When a switch is OFF the icon does nothing on a direct tap
// AND is skipped by the magnifier loupe (excluded from its target list):
//   Upvote     — the ↑ score (activated via the loupe; % ratio is unaffected).
//   Comments   — the direct comment-bubble tap that jumps to the comments; OFF
//                reverts to a stock tap (opens the post at the top).
//   Popup/Overlay — the display style shared by the three tappable "info" icons:
//                % upvoted (smiley), timestamp (age), and edited (pencil), all of
//                which reveal detail (a ratio or an absolute date). InfoRowPopupMode
//                shows the dismissable alert; InfoRowOverlayMode instead flashes a
//                small theme-bordered card just above the icon that fades on its own
//                after ~2s. Mutually exclusive; both off = those three icons are
//                inert (the % / edited native popups are taken over and suppressed).
//   Translation— the 🌐 marker tap beside a post's stats (feed title + comments
//                header) that toggles the title translation (ApolloTranslation.xm,
//                ApolloFeedMarkerTapTarget). Takes priority over Tap to Translate
//                / title Details: even with those on, OFF keeps the marker visible
//                but inert. Does NOT affect the inline "Translate" line under
//                comment/self-post body text. Faded on the settings screen until a
//                marker can appear (Tap to Translate or a Details toggle enabled).
static NSString *const UDKeyInfoRowTapUpvote = @"InfoRowTapUpvote";
static NSString *const UDKeyInfoRowTapComments = @"InfoRowTapComments";
static NSString *const UDKeyInfoRowPopupMode = @"InfoRowPopupMode";       // %/time/edited → popup alert
static NSString *const UDKeyInfoRowOverlayMode = @"InfoRowOverlayMode";   // %/time/edited → transient overlay
static NSString *const UDKeyInfoRowTapTranslation = @"InfoRowTapTranslation";
static NSString *const UDKeyLiveCommentsFollow = @"LiveCommentsFollow";
// Per-POST comment sort memory (issue #555). When ON, changing a post's comment sort
// is remembered for that post (capped LRU mapping below) and restored when its
// comments are reopened; every other post keeps Apollo's native chain (suggested
// sort > per-subreddit remembered > default). Opt-in; default NO via registerDefaults.
// See ApolloPerPostCommentSort.xm.
static NSString *const UDKeyPerPostCommentSort = @"PerPostCommentSort";
// Backing store for the above: { bare post id : { "s": sort raw, "t": last-use unix time } }.
static NSString *const UDKeyPerPostCommentSortMapping = @"PerPostCommentSortMapping";
// APOLLO'S OWN key (not ours) for the native Comments > "Remember Subreddit Sort"
// toggle. Named here because "Remember Post Sort" and that toggle are mutually
// exclusive (one sort-change gesture can't both pin a single post and move the
// subreddit-wide sort, so both-on is a trap state): enabling either turns the other
// off, and launch/restore normalize a stale both-on to per-post. This toggle key is
// the ONLY native default the feature ever writes. See ApolloPerPostCommentSort.xm.
static NSString *const UDKeyApolloRememberSubredditCommentsSort = @"RememberRedditCommentsSort";
// Render image URLs (i.redd.it, preview.redd.it, i.imgur.com, generic .png/.jpg/.jpeg/.webp)
// inline within post selftext and comments instead of leaving them as plain text links.
static NSString *const UDKeyEnableInlineImages = @"EnableInlineImages";
// Master toggle for the chat media enhancements: render inbound images/GIFs/emoji/snoomoji
// inline in DM/chat bubbles, rewrite outgoing media embeds so image/GIF sends work, and tap an
// image/GIF to open it full screen. OFF = stock Apollo chat (media shown as plain text links).
// Independent of "Show User Profile Pictures" (avatars have their own toggle). See ApolloChat*.xm.
static NSString *const UDKeyEnableChatMedia = @"EnableChatMedia";
// Horizontal alignment for inline media that is narrower than the row (e.g. tall portrait images).
// 0 = Center (default), 1 = Left, 2 = Right.
static NSString *const UDKeyInlineImageAlignment = @"InlineImageAlignment";
// Autoplay for inline GIF/animated media previews. 0 = legacy Default (follow
// Apollo's native "Autoplay GIFs/Videos", migrated at load), 1 = Never,
// 2 = WiFi Only, 3 = Always, 4 = Tap to Play (static cover + play button;
// tap toggles play/pause inline). Only meaningful when Inline Media Previews
// (UDKeyEnableInlineImages) is on.
static NSString *const UDKeyAutoplayInlineGIFs = @"AutoplayInlineGIFs";
// Display width of inline media (images/GIFs) in comments and selftext as a
// percentage of the row width: 50, 75, or 100 (default).
static NSString *const UDKeyInlineMediaSizePercent = @"InlineMediaSizePercent";

// Bulk translation feature
static NSString *const UDKeyEnableBulkTranslation = @"EnableBulkTranslation";
static NSString *const UDKeyAutoTranslateOnAppear = @"AutoTranslateOnAppear";
// Tap to Translate: everything stays in its original language with per-item tap
// affordances ("Translate" under comments, a language marker next to post
// stats); tapping translates just that item. Default OFF via registerDefaults.
static NSString *const UDKeyTapToTranslate = @"TapToTranslate";
// Per-item translation details: "Translated from ..." lines under comments/the
// post header, and the compact language marker on feed post stats. Both default
// ON via registerDefaults. Match App Colour tints the markers with the app
// accent instead of green (default OFF).
static NSString *const UDKeyShowTranslationDetails = @"ShowTranslationDetails";
static NSString *const UDKeyShowTranslationTitleDetails = @"ShowTranslationTitleDetails";
static NSString *const UDKeyTranslationMarkerUseThemeColor = @"TranslationMarkerUseThemeColor";
static NSString *const UDKeyTranslatePostTitles = @"TranslatePostTitles";
static NSString *const UDKeyTranslationTargetLanguage = @"TranslationTargetLanguage";
static NSString *const UDKeyTranslationProvider = @"TranslationProvider"; // google | libre | apple
static NSString *const UDKeyTranslationProviderUserSelected = @"TranslationProviderUserSelected";
static NSString *const UDKeyLibreTranslateURL = @"LibreTranslateURL";
static NSString *const UDKeyLibreTranslateAPIKey = @"LibreTranslateAPIKey";
// Array<String> of 2-letter language codes to leave untranslated (detected source language).
static NSString *const UDKeyTranslationSkipLanguages = @"TranslationSkipLanguages";

// On-device AI summaries (Apple FoundationModels, iOS 26+). Off by default.
static NSString *const UDKeyEnableAISummaries = @"EnableAISummaries";
// Sub-toggles, only meaningful while EnableAISummaries is on. Both default ON, so
// turning the master on keeps the original behaviour (post + comment summaries).
static NSString *const UDKeyEnableAIPostSummaries = @"EnableAIPostSummaries";       // post / link / both
static NSString *const UDKeyEnableAICommentSummaries = @"EnableAICommentSummaries"; // discussion
// When on, summaries are generated only when the user taps the card (rather than
// automatically on open). Off by default. Cached summaries still show instantly.
static NSString *const UDKeyEnableTapToSummarize = @"EnableTapToSummarize";
// When on, a summary card opens (expands) by itself as soon as its summary is
// ready, instead of staying collapsed until the user taps it. Off by default
// (current behaviour: cards open on tap). Tapping an idle "Tap to summarize"
// card always opens it once loaded, regardless of this setting.
static NSString *const UDKeyEnableAIAutoExpandSummaries = @"EnableAIAutoExpandSummaries";

// Picture-in-Picture: floating in-app mini-player for comments-page videos.
static NSString *const UDKeyPictureInPictureEnabled = @"PictureInPictureEnabled";       // master switch
// 0 = All Videos, 1 = Unmuted Videos Only, 2 = All Videos & GIFs (ApolloPiPActivationMode).
static NSString *const UDKeyPictureInPictureActivation = @"PictureInPictureActivation";
// Hand off to iOS' system Picture in Picture when the app backgrounds.
static NSString *const UDKeyPictureInPictureNative = @"PictureInPictureNative";
// Replay videos in the PiP window when they reach the end. Default YES.
static NSString *const UDKeyPictureInPictureLoop = @"PictureInPictureLoop";
// Open the miniplayer tucked off the edge (hidden) for corner Starting
// Positions. Ignored for Last Position, which remembers hidden state itself.
static NSString *const UDKeyPictureInPictureStartHidden = @"PictureInPictureStartHidden";
// Optional overlay extras on the floating window. Skip buttons jump back or
// ahead by SkipSeconds (5/10/15/30, default 10); the progress bar is a
// read-only playback position strip. Both default NO.
static NSString *const UDKeyPictureInPictureSkipButtons = @"PictureInPictureSkipButtons";
static NSString *const UDKeyPictureInPictureSkipSeconds = @"PictureInPictureSkipSeconds";
static NSString *const UDKeyPictureInPictureProgressBar = @"PictureInPictureProgressBar";
// 0–3 = fixed corner (TL/TR/BL/BR), 4 = remember last position (ApolloPiPStartPosition).
static NSString *const UDKeyPictureInPictureStartPosition = @"PictureInPictureStartPosition";
// Internal (no settings UI): persisted floating-card geometry. The resting
// position is a normalized center (fraction of window bounds) so it survives
// rotation and differing video aspect ratios. The size is stored as an AREA
// fraction (card area / screenWidth²) rather than a width fraction, so a
// remembered footprint applied to a differently-shaped next video stays the
// same size on screen instead of ballooning (portrait) — only Last Position
// reuses it; fixed corners always spawn at the calibrated default.
static NSString *const UDKeyPictureInPictureAreaFraction = @"PictureInPictureAreaFraction";
static NSString *const UDKeyPictureInPictureLastCenterX = @"PictureInPictureLastCenterX";
static NSString *const UDKeyPictureInPictureLastCenterY = @"PictureInPictureLastCenterY";
// Whether the card was hidden (tucked off an edge) at rest: 0 = no, -1/+1 = left/right edge.
static NSString *const UDKeyPictureInPictureLastStashSide = @"PictureInPictureLastStashSide";

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

// Post filters (Reborn) — device-wide content filters layered onto Apollo's
// native Filters & Blocks screen. Independent of Apollo's account-synced filter
// prefs (filteredSubreddits / blockedUsers) and of the Tag Filters feature above.
// Per-subreddit rules: dictionary keyed by lowercased subreddit name. Each value
// is a dictionary with optional keys:
//   "keywords" -> NSArray<NSString *>  (lowercased; hide posts whose title/link contains any)
//   "flairs"   -> NSArray<NSString *>  (lowercased; hide posts whose flair label equals any)
static NSString *const UDKeyPostFilterSubreddits = @"PostFilterSubreddits";
// Subreddit-name substrings: NSArray<NSString *> (lowercased). Hide any subreddit
// whose name CONTAINS one of these substrings — both posts in feeds and the
// subreddit's own search suggestions (e.g. "circlejerk" hides r/carscirclejerk).
static NSString *const UDKeyPostFilterNameSubstrings = @"PostFilterNameSubstrings";

// Web JSON spike (see ApolloWebJSON.m). Master switch for re-pointing
// whitelisted listing reads at cookie-authenticated www.reddit.com JSON.
static NSString *const UDKeyWebJSONEnabled = @"WebJSONEnabled";
// Legacy NSUserDefaults location of the harvested "name=value; ..." Cookie
// header. The cookie is now stored in the keychain (ApolloWebJSON.m); this key
// is retained only so ApolloWebJSONLoadPersistedCredentials can migrate an older
// build's value into the keychain and then delete it.
static NSString *const UDKeyWebSessionCookieHeader = @"WebSessionCookieHeader";
// Set when an account is synthesized from a *mid-session* web login (the login VC
// path), so AccountManager — which only loads accounts at launch — hasn't picked
// it up yet and the account tab is blank until a relaunch. Drives the
// "restart to activate" indicator on the Web Session Login settings row, and is
// cleared in %ctor on the next launch (where the fresh account load resolves it).
static NSString *const UDKeyWebJSONPendingRestart = @"WebJSONPendingRestart";
// The username the pending-restart synthesis above was for. Sessions are now
// per-account (ApolloWebSessionStore), so this is the only way the "quit &
// reopen to activate" UI knows WHICH account to name — the single global
// sWebSessionUsername is migration scratch only and isn't touched by a fresh
// per-account harvest. Set alongside UDKeyWebJSONPendingRestart; cleared with it.
static NSString *const UDKeyWebJSONPendingRestartUsername = @"WebJSONPendingRestartUsername";

// Self-hosted notification backend (forked apollo-backend). Empty disables —
// the legacy hosts remain in the blocklist and requests are silently dropped.
static NSString *const UDKeyNotificationBackendURL = @"NotificationBackendURL";
// Optional shared secret matching the backend's REGISTRATION_SECRET env var.
// When set, sent as X-Registration-Token on the three POST registration
// endpoints (/v1/device, /v1/device/{apns}/account[s]).
static NSString *const UDKeyNotificationBackendRegistrationToken = @"NotificationBackendRegistrationToken";

// Bark delivery for free-account sideloads (no aps-environment entitlement).
// When enabled AND a valid Bark push URL is set AND the backend above is
// configured, the tweak feeds Apollo a synthetic device token so its native
// notification/watcher registration runs, and the backend delivers via an
// HTTP POST to the Bark push URL instead of APNs. On builds with a real push
// entitlement this instead flips the existing (real-token) backend device row
// between transport=apns and transport=bark.
static NSString *const UDKeyBarkNotificationsEnabled = @"BarkNotificationsEnabled";
// Full Bark push URL: https://api.day.app/<device_key> or a self-hosted
// bark-server equivalent. The device key is a bearer capability — treat it
// like a password.
static NSString *const UDKeyBarkPushURL = @"BarkPushURL";
// The synthetic 64-hex device token registered with the backend in place of
// an APNs token. Generated once (SecRandomCopyBytes) and persisted so the
// backend device row stays stable across launches; travels in settings
// backups automatically (whole-plist backup).
static NSString *const UDKeyBarkSyntheticDeviceToken = @"BarkSyntheticDeviceToken";
// Lowercase hex of the device token from the most recent registration Apollo
// completed (the real APNs token on entitled builds, the synthetic one on
// free sideloads). Stashed by the didRegister hook so the settings UI can
// address the backend device row directly when flipping transports.
static NSString *const UDKeyLastDeviceTokenHex = @"BarkLastDeviceTokenHex";
// The CFBundleAlternateIcons key of the app icon the user selected in
// Apollo's settings (absent = stock icon). Mirrored from
// UIApplication.alternateIconName by the setAlternateIconName hook so Bark
// URL construction can read it from any thread; used to pin the matching
// hosted icon on Bark notifications via the push URL's ?icon= parameter.
static NSString *const UDKeyBarkSelectedIconName = @"BarkSelectedIconName";

// Anonymous MAU heartbeat. ON by default; this is the opt-OUT, mirroring the
// DisableApollonouncements pattern (a disable flag that defaults to NO gives us
// on-by-default). See ApolloUsageHeartbeat.{h,m}.
static NSString *const UDKeyDisableUsageHeartbeat = @"DisableUsageHeartbeat";
// Internal bookkeeping for the heartbeat (not user-facing).
static NSString *const UDKeyHeartbeatMonth   = @"UsageHeartbeatMonth";   // "2026-07"
static NSString *const UDKeyHeartbeatToken   = @"UsageHeartbeatToken";   // monthly UUID
static NSString *const UDKeyHeartbeatLastDay = @"UsageHeartbeatLastDay"; // "2026-07-05"

// Feed thumbnails for text posts with embedded images (off = native behavior).
static NSString *const UDKeyFeedTextPostThumbnails = @"FeedTextPostThumbnails";

// Sports-clip host links (streamff/streamin/streamain/…) play inline as native
// video via the Streamable pipeline (off = link-preview card, stock behavior).
static NSString *const UDKeySportsClipsInlineVideo = @"SportsClipsInlineVideo";

// Rich link preview cards: 0 = Off, 1 = Compact, 2 = Full.
static NSString *const UDKeyLinkPreviewBodyMode = @"LinkPreviewBodyMode";
static NSString *const UDKeyLinkPreviewCommentsMode = @"LinkPreviewCommentsMode";
// Legacy preset color (ApolloLinkPreviewCardColor enum). Superseded by the
// free-form hex below; still read once at launch to migrate an old selection.
static NSString *const UDKeyLinkPreviewCardColor = @"LinkPreviewCardColor";
// Free-form preview card color as a 6-digit "RRGGBB" hex string. Empty string
// means "Default" (no custom fill — the standard neutral card). A non-empty
// hex paints the whole card that exact color, with auto-contrasted text.
static NSString *const UDKeyLinkPreviewCardColorHex = @"LinkPreviewCardColorHex";
static NSString *const ApolloLinkPreviewModeDidChangeNotification = @"ApolloLinkPreviewModeDidChangeNotification";
// Posted by the Inline Media settings screen when size/alignment changes so
// visible comments re-measure their inline media immediately.
static NSString *const ApolloInlineMediaLayoutDidChangeNotification = @"ApolloInlineMediaLayoutDidChangeNotification";
