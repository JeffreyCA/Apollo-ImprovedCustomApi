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
// Local crash recording (src/crash/). Default ON: reports only ever live on
// device and are shared exclusively through the user-driven review flow.
// KSCrash handlers install once per process, so flipping this takes effect on
// the next launch (the settings row says so).
static NSString *const UDKeyCrashCaptureEnabled = @"CrashCaptureEnabled";
// Report IDs (NSArray<NSNumber>) the relaunch prompt has already been shown
// for. A "Not Now" must never re-nag on every launch of a persistently
// crashing build; the pending report stays reachable under Settings instead.
// Not registered — absent means "never prompted".
static NSString *const UDKeyCrashPromptedReportIDs = @"CrashPromptedReportIDs";
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
// Master toggle for subreddit list polish/enhancements. Default YES. Feed
// Shortcuts is independent; Modern Subreddit Dividers remains a sub-option.
static NSString *const UDKeySubredditListEnhancements = @"SubredditListEnhancements";
// Home / Popular / All / Moderator icon appearance and arrangement. Independent
// of Subreddit List Enhancements. Defaults: Classic icons + Rows.
static NSString *const UDKeySubredditFeedIconStyle = @"SubredditFeedIconStyle";
static NSString *const UDKeySubredditFeedLayout = @"SubredditFeedLayout";
// Apollo-native visibility preferences for the optional meta-feed rows. Reborn
// mirrors these on Feed Shortcuts and deliberately keeps Home always visible.
static NSString *const UDKeyHideRPopularRedditList = @"HideRPopularRedditList";
static NSString *const UDKeyHideRAllRedditList = @"HideRAllRedditList";
static NSString *const UDKeyHideModeratorRedditList = @"HideModeratorRedditList";
static NSString *const ApolloFeedShortcutsChangedNotification = @"ApolloFeedShortcutsChangedNotification";
// Subreddits the user moderates but chose to hide from the Subreddits list
// (Reddit offers no way to leave or delete some dead subreddits). Array of
// display names, compared case-insensitively.
static NSString *const UDKeyHiddenModeratorSubreddits = @"HiddenModeratorSubreddits";
static NSString *const UDKeyModernSubredditDividers = @"ModernSubredditDividers";
static NSString *const ApolloModernSubredditDividersChangedNotification = @"ApolloModernSubredditDividersChangedNotification";
// Hides the description subtitles under the subreddit list's built-in feed rows
// (Home, Popular Posts, All Posts, Moderator Posts). Independent of the
// enhancements master — applies in both the classic and modern list styles.
// Default NO. See ApolloSubredditIndexPolish.xm.
static NSString *const UDKeyHideSubredditListDescriptions = @"HideSubredditListDescriptions";
static NSString *const ApolloHideSubredditListDescriptionsChangedNotification = @"ApolloHideSubredditListDescriptionsChangedNotification";
// Blank the subtitle line under multireddit rows in the subreddit list (which
// otherwise shows the multireddit's description, or the subreddits it
// contains). Default NO. See ApolloMultiredditEdit.xm.
static NSString *const UDKeyHideMultiredditDescriptions = @"HideMultiredditDescriptions";
static NSString *const ApolloHideMultiredditDescriptionsChangedNotification = @"ApolloHideMultiredditDescriptionsChangedNotification";
// Pull followed users (the u_<name> profile "subreddits" Reddit mixes into
// subscriptions) out of the A-Z sections into a dedicated FOLLOWING section in
// the Subreddits list. Default NO. See ApolloFollowingSection.xm.
static NSString *const UDKeySeparateFollowedUsers = @"SeparateFollowedUsers";
// Display order of the Favorites/Multireddits/Moderator/Following sections in
// the Subreddits list: an array of the tokens declared in
// ApolloFollowingSection.h. Missing/unknown tokens fall back to the native
// order (favorites, multireddits, moderator, following).
static NSString *const UDKeySubredditSectionOrder = @"SubredditSectionOrder";
// Custom display order of the FOLLOWING section's rows (array of u_<name>
// subscription names, matched case-insensitively). Users not in the array
// append in their natural alphabetical order.
static NSString *const UDKeyFollowedUsersOrder = @"FollowedUsersOrder";
static NSString *const ApolloSubredditSectionsChangedNotification = @"ApolloSubredditSectionsChangedNotification";
// Color post (link) and user/author flairs with Reddit's assigned colors. Default NO.
static NSString *const UDKeyEnableFlairColors = @"EnableFlairColors";
static NSString *const ApolloFlairColorsChangedNotification = @"ApolloFlairColorsChangedNotification";
static NSString *const UDKeyReadPostMaxCount = @"ReadPostMaxCount";
static NSString *const UDKeyShowRecentlyReadThumbnails = @"ShowRecentlyReadThumbnails";
static NSString *const UDKeyPreferredGIFFallbackFormat = @"PreferredGIFFallbackFormat";
static NSString *const UDKeyUnmuteCommentsVideos = @"UnmuteCommentsVideos";
// "Unmute Videos in Feed": how feed videos behave when they autoplay while
// scrolling. 0 = Never (default — Apollo's stock behaviour, always muted),
// 1 = Remember (follow the last manual mute/unmute the user made on a FEED
// video, persisted in UDKeyFeedVideosUnmutedMemory), 2 = Always (every feed
// video autoplays with sound). Only one feed video is ever audible at a time.
// See ApolloVideoUnmute.xm.
static NSString *const UDKeyUnmuteFeedVideos = @"UnmuteFeedVideos";
// Backing store for Remember mode above: YES once the user unmutes a feed video
// with the mute button, NO once they mute one again. Written ONLY by a genuine
// mute-button tap on a feed video, never by an automatic unmute. Default NO.
static NSString *const UDKeyFeedVideosUnmutedMemory = @"FeedVideosUnmutedMemory";
// "Feed Video Scrubber": press and hold the thin progress bar at the bottom of
// a feed video, then slide to scrub it, for every inline player type. Tapping
// the video (bar included) still opens it fullscreen as stock. Default NO.
// See ApolloFeedVideoScrubber.xm.
static NSString *const UDKeyFeedVideoScrubber = @"FeedVideoScrubber";
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
// Apollo NATIVE key backing its "Open Links in" browser picker (String token;
// missing = the in-app default). Verified tokens, recovered by driving the
// native picker in the sim and reading back the persisted value:
//   in-app-safari (In-App Safari), external-safari (Safari), chrome, firefox,
//   firefox-focus, edge, dolphin, brave, duckduckgo, icab
// Reborn's "Open in App" screen mirrors this key (same gather-and-hide pattern
// as UDKeyOpenVideosInYouTubeApp above; the token literal is also read in
// ApolloShareLinks.xm's ApolloOpensLinksInSystemBrowser()).
static NSString *const UDKeyNativeOpenLinksIn = @"OpenLinksIn";
// Apollo NATIVE key + change notification for its "Hide Username on Tab Bar"
// switch. Apollo observes the notification (hideUsernameOnTabBarChangedWithNotification:)
// and re-lays-out the profile tab live, so mirrors must post it after writing
// the key. Reborn's Profiles settings screen mirrors this row (gather-and-hide);
// ApolloTabBarTitles.xm clears the key while Icon-Only Tab Bar is active.
static NSString *const UDKeyNativeHideUsernameOnTabBar = @"HideUsernameOnTabBar";
static NSString *const ApolloNativeHideUsernameOnTabBarChangedNotification = @"com.christianselig.HideUsernameOnTabBarChanged";
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
// Allow non-DDG public text proxies (r.jina.ai, allorigins, codetabs) as a
// last resort for album metadata when Imgur is unreachable — DDG itself cannot
// carry JSON. Default ON; only consulted while ProxyImgurDDG is enabled.
static NSString *const UDKeyImgurAlbumFallbackProxies = @"ImgurAlbumFallbackProxies";
static NSString *const UDKeyImageUploadProvider = @"ImageUploadProvider";
// Secondary host for images added in the COMMENT/REPLY editor (CommentLinkHost
// enum). Off (default) keeps comment uploads on the Media Upload Host above;
// Imgur/Image Chest route comment-editor uploads there and post the result as a
// plain link (no native Reddit media) so they work in subreddits that disallow
// image/GIF comments. See ApolloMarkdownToolbarGif.xm + ApolloImageUploadHost.xm.
static NSString *const UDKeyCommentLinkHost = @"CommentLinkHost";
// Auto mode for the Comment Link Host (default OFF). When ON, comment-editor
// images are forced onto Reddit's NATIVE media upload (they render inline on
// every client) wherever the subreddit allows image comments; the link host
// above is used only where the subreddit disallows them — or when the
// permissions aren't known yet, since a plain link always posts. Only
// consulted while a Comment Link Host is set.
static NSString *const UDKeyCommentLinkPreferNative = @"CommentLinkPreferNative";
// Posted after sCommentLinkHost changes so open composers re-apply the comment
// media-permission gating (the image button un-blocks while a link host is set).
static NSString *const ApolloCommentLinkHostChangedNotification = @"ApolloCommentLinkHostChangedNotification";
// Outgoing Reddit URL host for Apollo share sheets (ShareLinkHost enum). Default
// keeps Apollo's stock reddit.com links; Old Reddit/vxReddit rewrite share URLs.
static NSString *const UDKeyShareLinkHost = @"ShareLinkHost";
static NSString *const UDKeyShowUserAvatars = @"ShowUserAvatars";
static NSString *const UDKeyUseProfileAvatarTabIcon = @"UseProfileAvatarTabIcon";
// When ON, the main tab bar removes its visible text labels and lets UIKit lay
// out a clean icon-only navigation menu. The original titles remain available
// to accessibility and are restored live when the setting is turned off.
// Default OFF. See ApolloTabBarTitles.xm.
static NSString *const UDKeyHideTabBarTitles = @"HideTabBarTitles";
static NSString *const ApolloTabBarTitlesChangedNotification = @"ApolloTabBarTitlesChangedNotification";
// When ON (default), profile pages show Reborn's detailed profile — the banner,
// large avatar/snoovatar, display name, bio, and the Social Links band. When OFF,
// the profile page reverts to Apollo's compact stock layout: the detailed header is
// not installed, and any header already on screen is torn down (restoring Apollo's
// native table header). Independent of "Show User Profile Pictures"
// (UDKeyShowUserAvatars), which governs the inline avatars next to usernames.
// See ApolloUserAvatars.xm and ApolloProfileSocialLinks.m. Default YES.
static NSString *const UDKeyShowDetailedProfiles = @"ShowDetailedProfiles";
// Master toggle for the profile "Badge Book" — the in-header preview strip and the
// full Achievements / Trophy Case screen (ApolloBadgeBookStrip.m,
// ApolloBadgeBookViewController.m). Off → no strip, no scraping, no entry point.
// Default YES.
static NSString *const UDKeyBadgeBookEnabled = @"BadgeBookEnabled";
static NSString *const UDKeyProfileHeaderImmersive = @"ProfileHeaderImmersive";
static NSString *const UDKeyProfileShowBanner = @"ProfileShowBanner";
static NSString *const UDKeyProfileShowStatCards = @"ProfileShowStatCards";
static NSString *const UDKeyProfileShowSocialLinks = @"ProfileShowSocialLinks";
static NSString *const UDKeyProfileShowActions = @"ProfileShowActions";
static NSString *const UDKeyProfileAvatarStyle = @"ProfileAvatarStyle";
static NSString *const UDKeyShowSubredditHeaders = @"ShowSubredditHeaders";
// New (Immersive, with the melt/ambient backdrop) vs Classic (same content,
// flat) — mirrors UDKeyProfileHeaderImmersive's semantics for subreddits.
static NSString *const UDKeySubredditHeaderImmersive = @"SubredditHeaderImmersive";
static NSString *const UDKeySubredditShowBanner = @"SubredditShowBanner";
static NSString *const UDKeySubredditShowJoinButton = @"SubredditShowJoinButton";
static NSString *const UDKeySubredditShowDisplayName = @"SubredditShowDisplayName";
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
// Liquid Glass nav bar title placement. ON (default): center the title in the
// gap between the back pill and the trailing pill so it reads balanced whatever
// the trailing cluster holds (translation globe on or off). OFF: center it on
// the screen itself, nudged just enough to clear a pill it would overlap.
// See ApolloRecenterTitleControl in ApolloLiquidGlass.xm.
static NSString *const UDKeyLGTitleGapCentering = @"LGTitleGapCentering";
// iPad only, Liquid Glass only. When ON, forces the iOS 26 floating tab bar to
// dock at the BOTTOM (classic tab bar) instead of the top-center pill, which on
// iPad overlaps Apollo's search bar. Temporary stopgap for issue #387 until the
// real iPad build lands. Opt-in; default OFF via registerDefaults. See ApolloIPadTabBarBottom.xm.
static NSString *const UDKeyIPadTabBarBottom = @"IPadTabBarBottom";
static NSString *const ApolloIPadTabBarBottomChangedNotification = @"ApolloIPadTabBarBottomChangedNotification";
// iPad only. When ON, replaces each tab's single navigation stack with a
// multi-column UISplitViewController: sidebar (the tab's own root list) →
// content → detail. Opt-in; default OFF via registerDefaults. Installation
// happens at scene connect, so a change needs a relaunch to apply — the
// settings row confirms and restarts rather than pretending it is live.
// Supersedes UDKeyIPadTabBarBottom while active (the floating pill is hidden).
// See src/ipad/ and docs/ipad-pane-layout-plan.md.
static NSString *const UDKeyIPadPaneLayout = @"IPadPaneLayout";
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
// and remains visible in the magnifier loupe, but releasing on it does nothing:
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
//                These modes also choose the presentation used when holding the
//                score on an owned comment to request author-only Comment Insights.
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
// Override for the UIScrollView top scroll edge effect (Liquid Glass, iOS 26+).
// 0 = retired System Default (migrates to 1 on iOS 26 or 2 on iOS 27),
// 1 = Soft, 2 = Hard, 3 = retired Hidden, 4 = Blur.
static NSString *const UDKeyScrollEdgeEffectStyle = @"ScrollEdgeEffectStyle";
// Render image URLs (i.redd.it, preview.redd.it, i.imgur.com, generic .png/.jpg/.jpeg/.webp)
// inline within post selftext and comments instead of leaving them as plain text links.
static NSString *const UDKeyEnableInlineImages = @"EnableInlineImages";
// Master toggle for the message media enhancements: render inbound images/GIFs/emoji/snoomoji
// inline in message bubbles, rewrite outgoing media embeds so image/GIF sends work, and tap an
// image/GIF to open it full screen. OFF = stock Apollo threads (media shown as plain text links).
// Scoped to the threads Apollo draws itself with PrivateMessageViewController — legacy Direct
// Chat, private messages, and native Moderator Mail — so turning on modern Chat/Modmail (which
// are web surfaces rendering their own media) narrows what this reaches without ever emptying
// it: private messages are always native.
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
static NSString *const UDKeyTranslationProvider = @"TranslationProvider"; // google | libre | apple | microsoft
static NSString *const UDKeyTranslationProviderUserSelected = @"TranslationProviderUserSelected";
static NSString *const UDKeyLibreTranslateURL = @"LibreTranslateURL";
static NSString *const UDKeyLibreTranslateAPIKey = @"LibreTranslateAPIKey";
// Microsoft (Azure AI Translator) — bring-your-own-key, like LibreTranslate.
// Azure's free F0 tier is 2M characters/month, so unlike the free Google
// endpoints it is an official, documented API that won't rate-limit ordinary
// use. Region is required for regional resources ("global" for global ones).
static NSString *const UDKeyMicrosoftTranslateAPIKey = @"MicrosoftTranslateAPIKey";
static NSString *const UDKeyMicrosoftTranslateRegion = @"MicrosoftTranslateRegion";
// Array<String> of 2-letter language codes to leave untranslated (detected source language).
static NSString *const UDKeyTranslationSkipLanguages = @"TranslationSkipLanguages";
// Redirects Apollo's OWN Translate button (the native action-sheet item on
// comments/posts, which normally opens Apollo's Google Translate web view) to
// iOS's on-device Translate sheet instead. Independent of UDKeyTranslationProvider,
// which governs the tweak's separate bulk in-place translation backend, not this
// button. Requires iOS 17.4+ (Translation.framework's .translationPresentation);
// has no effect while Bulk Translation is on, since that already removes the
// native Translate action from the sheet. Default OFF via registerDefaults.
static NSString *const UDKeyAppleTranslateSheet = @"AppleTranslateSheet";

// On-device AI summaries (Apple FoundationModels, iOS 26+). Off by default.
static NSString *const UDKeyEnableAISummaries = @"EnableAISummaries";
// Sub-toggles, only meaningful while EnableAISummaries is on. Both default ON, so
// turning the master on keeps the original behaviour (post + comment summaries).
static NSString *const UDKeyEnableAIPostSummaries = @"EnableAIPostSummaries";       // post / link / both
static NSString *const UDKeyEnableAICommentSummaries = @"EnableAICommentSummaries"; // discussion
// User-selectable AI summary tuning. Text posts must meet the word threshold
// (50...300 in 50-word steps; default 150). Post/link and discussion detail are
// stored independently as ApolloAISummaryDetail values (Brief/Balanced/In-depth).
static NSString *const UDKeyAIPostWordThreshold = @"AIPostWordThreshold";
static NSString *const UDKeyAIPostSummaryDetail = @"AIPostSummaryDetail";
static NSString *const UDKeyAICommentSummaryDetail = @"AICommentSummaryDetail";
// When on, summaries are generated only when the user taps the card (rather than
// automatically on open). Off by default. Cached summaries still show instantly.
static NSString *const UDKeyEnableTapToSummarize = @"EnableTapToSummarize";
// When on, a summary card opens (expands) by itself as soon as its summary is
// ready, instead of staying collapsed until the user taps it. Off by default
// (current behaviour: cards open on tap). Tapping an idle "Tap to summarize"
// card always opens it once loaded, regardless of this setting.
static NSString *const UDKeyEnableAIAutoExpandSummaries = @"EnableAIAutoExpandSummaries";
// AI summary backend. "apple" (on-device FoundationModels, the default) or a
// cloud provider reached through an OpenAI-compatible chat-completions API:
// "openrouter" | "gemini" | "custom". Cloud providers need a user-supplied API
// key; "custom" additionally needs a base URL. Keys/models are stored
// per-provider so switching back and forth never loses them.
static NSString *const UDKeyAISummaryProvider = @"AISummaryProvider"; // apple | openrouter | gemini | custom
static NSString *const UDKeyOpenRouterAPIKey  = @"OpenRouterAPIKey";
static NSString *const UDKeyOpenRouterAIModel = @"OpenRouterAIModel";
static NSString *const UDKeyGeminiAPIKey      = @"GeminiAPIKey";
static NSString *const UDKeyGeminiAIModel     = @"GeminiAIModel";
static NSString *const UDKeyCustomAIAPIKey    = @"CustomAIAPIKey";
static NSString *const UDKeyCustomAIModel     = @"CustomAIModel";
static NSString *const UDKeyCustomAIBaseURL   = @"CustomAIBaseURL"; // OpenAI-compatible base URL, e.g. https://api.example.com/v1

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
// Local override for Apollo's native NSFW media blur (media blurred, title
// visible — driven by the account's pref_no_profanity). 0 = follow the Reddit
// account setting (default), 1 = always blur, 2 = never blur. Independent of
// Tag Filters; never synced to Reddit (Apollo only PATCHes media prefs).
static NSString *const UDKeyNSFWBlurOverride = @"NSFWBlurOverride";

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
// Reddit's modern web Chat, for API-key and API-key-free accounts alike. Off
// means Apollo's own Direct Chat, which needs Reddit API credentials.
static NSString *const UDKeyUseModernRedditChat = @"UseModernRedditChat";
// Independently, Reddit's current web Modmail. Off means Apollo's native
// Moderator Mail, whose new-Modmail endpoints require OAuth credentials.
static NSString *const UDKeyUseModernRedditModmail = @"UseModernRedditModmail";
// One-shot marker: the two keys above became a plain user preference (they
// used to be force-enabled for web-session accounts by a derived gate). Set
// once ApolloMigrateModernMailboxPreferences has recorded the previously
// implied value, so that never runs twice and re-flips a deliberate choice.
static NSString *const UDKeyModernMailboxChoiceMigrated = @"ModernMailboxChoiceMigrated";
// Modern Chat unread poller (ApolloChatUnreadPoller.m). Per-account high-water
// marks of the unread/requests counts already announced through Bark, so a
// relaunch doesn't re-push the same unread messages. Not user-facing.
static NSString *const UDKeyChatUnreadNotifiedWatermarks = @"ChatUnreadNotifiedWatermarks";
// Debug-only overrides for the poller (never surfaced in settings): point the
// Matrix homeserver at a local mock, and shorten the poll cadence, so the
// whole badge/notification pipeline can be exercised in the simulator.
static NSString *const UDKeyChatPollerHomeserverOverride = @"ChatPollerHomeserverOverride";
static NSString *const UDKeyChatPollerIntervalOverride = @"ChatPollerIntervalOverride";
// Debug-only override (seconds, >= 5) for how long the modern Chat surface
// must be hidden/inactive before returning to it auto-refreshes the list.
static NSString *const UDKeyChatStaleRefreshOverride = @"ChatStaleRefreshOverride";
// Native Polls (ApolloPollVoting.xm / ApolloPollCompose.xm). Off by default —
// an experimental feature that lets you vote in and create polls via a
// per-account reddit.com web session (harvested once, then silent). Independent
// of UDKeyWebJSONEnabled: turning polls on does NOT reroute the request
// pipeline; it only unlocks the poll tap handler and the compose "Poll" type.
static NSString *const UDKeyPollsEnabled = @"PollsEnabled";
// Horizontal alignment of poll option text (ApolloPollOptionAlignment).
// Default Center (0).
static NSString *const UDKeyPollOptionAlignment = @"PollOptionAlignment";
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
// Replaces Apollo's fixed two/three-tile Reddit-gallery mosaic in large feed
// cards with a horizontally paging image carousel. Default YES. See
// ApolloFeedGalleryCarousel.xm.
static NSString *const UDKeyFeedGalleryCarousel = @"FeedGalleryCarousel";
// NSNotification name (not a defaults key): posted by the settings toggle so
// already-measured feed cells swap presentation live; the carousel's
// layoutSpecThatFits reads the flag on each measurement.
static NSString *const ApolloFeedGalleryCarouselChangedNotification = @"ApolloFeedGalleryCarouselChangedNotification";
// When the feed gallery carousel sits on its first (or last) image, continuing
// to swipe toward the edge hands the drag to Apollo's swipe-back (or
// swipe-forward) page navigation instead of rubber-banding, but only when a
// previous (or forward) page actually exists. Default NO: handing a gallery
// swipe to page navigation surprises people who only meant to bounce, so it's
// opt-in (#996 review). Read live at gesture time, so no change notification
// is needed (same reasoning as UDKeySwipeUpForComments below). See
// ApolloFeedGalleryCarousel.xm.
static NSString *const UDKeyFeedGalleryEdgeSwipeNav = @"FeedGalleryEdgeSwipeNavigation";
// Apollo's forward-swipe (right edge, plus the gallery edge-swipe hand-off)
// re-opens the screen you last swiped back from, and that memory natively
// survives unlimited feed scrolling. With this on, scrolling the feed a few
// posts away from where you popped back drops the stale forward memory, so a
// much-later accidental swipe doesn't teleport to an old post. Default NO:
// forward-swipe is a common enough gesture that changing what it does is
// opt-in (#996 review). Read live per scroll tick, so no change notification
// is needed. See ApolloForwardSwipeExpiry.xm.
static NSString *const UDKeyForwardSwipeForgetAfterScrolling = @"ForwardSwipeForgetAfterScrolling";
// In the fullscreen viewer for post-backed images, galleries, GIFs, and video,
// an upward vertical flick or comments-button tap opens a media-owned comments
// pane. The normal downward flick still dismisses when the pane is closed.
// Default YES. See ApolloSwipeUpComments.xm. No change notification: the flag
// is read live at gesture/tap time, so a toggle applies immediately without
// any cached state to invalidate (unlike the carousel above).
static NSString *const UDKeySwipeUpForComments = @"SwipeUpForComments";

// Sports-clip host links (streamff/streamin/streamain/…) play inline as native
// video via the Streamable pipeline (off = link-preview card, stock behavior).
static NSString *const UDKeySportsClipsInlineVideo = @"SportsClipsInlineVideo";

// Live interactive Devvit ("Developer Platform") posts — match threads, games
// — render their real web widget inline (comments header + large-mode feed
// cards) instead of the "not supported on old Reddit" fallback text.
// Default OFF (opt-in): each widget is a full embedded shreddit page, so the
// cost is real and users choose to pay it.
static NSString *const UDKeyDevvitInteractivePosts = @"DevvitInteractivePosts";
// Sub-toggle: also render the widget in large-mode FEED cards (the costly
// surface — comments is one widget at a time by construction). Default ON;
// only consulted while DevvitInteractivePosts is on.
static NSString *const UDKeyDevvitFeedWidgets = @"DevvitFeedWidgets";

// Floating Post Tabs: chat-heads-style bubbles (max 5) that keep posts open
// for instant return, created from the comments "..." menu. Default OFF
// (opt-in). See ApolloFloatingTabs.xm.
static NSString *const UDKeyFloatingPostTabs = @"FloatingPostTabs";
// Sub-toggle: bubbles released near each other magnetize into a draggable
// pile (tap fans it apart). Default ON; only consulted while the master
// toggle is on. Turning it off fans existing piles out.
static NSString *const UDKeyFloatingPostTabsMagnet = @"FloatingPostTabsMagnet";
// Sub-toggle: holding a bubble pops a snapshot preview card with
// peek-and-pop semantics (release opens the post, slide away first to
// cancel). Default ON; only consulted while the master toggle is on. Off =
// long-press does nothing (bubbles only tap and drag).
static NSString *const UDKeyFloatingPostTabsPreview = @"FloatingPostTabsPreview";
// Persisted open tabs (array of dicts: linkKey/permalink/title/subreddit +
// dock state), rewritten on every tab mutation so bubbles survive relaunch.
// Deliberately NOT registered with a default — absent means "no tabs".
static NSString *const UDKeyFloatingPostTabsSaved = @"FloatingPostTabsSaved";

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

// The last TWEAK_VERSION (without the leading "v") the What's New sheet was
// shown for (or silently advanced past, when a version has no catalog entry).
// Deliberately never registered with a default value, and an absent value is
// deliberately NOT treated as "fresh install, skip": it is indistinguishable
// from an upgrade off a build that predates this feature — the actual target
// audience for the release this ships in. See the gating doc in
// ApolloWhatsNew.xm.
static NSString *const UDKeyLastSeenWhatsNewVersion = @"LastSeenWhatsNewVersion";
