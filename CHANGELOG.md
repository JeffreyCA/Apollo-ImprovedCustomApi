# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [v3.1.1] - 2026-06-07

- Fix a **crash when sharing a post to Messages or Mail** from the share sheet — the system compose controller was misidentified as an Apollo composer, leaving GIF-toolbar injection timers that dereferenced the dismissed share UI and crashed (#378: @nickclyde)
- Fix **Reddit login on iOS 15** by automatically falling back to Old Reddit, and add an Old Reddit button to the auth view for users who need to switch manually (#377: @DeltAndy123)
- Fix **video controls** overlay rendering, including the AirPlay button getting clipped or misaligned (#383: @JeffreyCA)
- Fix **flair alignment** so post and user flairs no longer sit too low or clip their text (#389: @JeffreyCA)
- Fix **Color Flairs** reverting to grey or the wrong shade after returning to Apollo from the background (#391: @icpryde)

## [v3.1.0] - 2026-06-05

### Features

- Support **any custom redirect URI** for the Reddit API without patching the app's Info.plist, so custom URI schemes authenticate without the "address is invalid" error (also removes the need for LiveContainer users to patch manually) (#368: @DeltAndy123)
- Add **GLASS Icons** and **No Extensions + GLASS Icons** distribution variants that bundle the Liquid Glass icon catalog without opting into the iOS 26 UI runtime (#317: @nackerr)
- Add new **Glitched** (@bajader) and **Modern** / **Modern Alt** (@paulo1manso) Liquid Glass app icons (#353: @bajader, @paulo1manso)
- **Restore logged-in accounts** when restoring a settings backup, so reinstalling no longer requires re-authenticating each Reddit account (#331: @nickclyde)
- Add a **Subreddit List Enhancements** toggle in **Settings > Apollo Reborn Options > Subreddits** to fall back to Apollo's native list, working around misaligned rows and a broken index scrubber on some devices (#355: @JeffreyCA)
- Add a **Color Flairs** option in **Settings > Apollo Reborn Options > General** to color post and user flairs using Reddit's flair colors (#360: @icpryde)
- Add **Show Deleted Comments** to restore deleted or removed comments inline from archived copies when available (#300: @nunoo)
- Render comments with **two or more link previews** as compact cards instead of stacking full hero cards (#344: @icpryde)
- Show **feed thumbnails for text posts** that embed images but produce no native thumbnail, in both Large and Compact modes (#351: @icpryde)
- Fade and disable the comment **image/GIF buttons** when a subreddit doesn't allow that media type, instead of failing only at submit time (#356: @icpryde)
- Add a separate **Autoplay Inline GIFs** setting in **Settings > Apollo Reborn Options > Media** to control inline GIF autoplay independently of Apollo's native Autoplay GIFs/Videos setting (#365: @JeffreyCA)
- Ship an Apollo-Reborn **userscript** and an **"Open in Apollo" Shortcut** recipe as app-independent ways to open Reddit links in Apollo from any browser, handy for the no-extensions variant (#307: @nickclyde)

### Fixes

- Fix the bundled **"Open in Apollo" Safari extension**, which stopped opening links on sideloaded builds — its default "Automatic" mode redirected through `openinapollo.com`, whose auto-open only works for the App Store build. It now redirects straight to `apollo://` and handles `/s/` share links (#307: @nickclyde)
- Fix the bundled **"Open in Apollo" share-sheet action** so it opens Reddit links in Apollo from **any** browser (Chrome, Firefox, Edge, Brave…), not just Safari, replacing a deprecated call that iOS 18+ refused to run. On iOS 26 the extension only launches if your installer sets the appex main-binary flag — **AltStore/SideStore** do, **Sideloadly/Feather** don't, where the Shortcut remains a signer-independent fallback (#307: @nickclyde)
- Fix **Recently Read** showing no posts after a Reddit API change (#341: @JeffreyCA)
- Fix inline **Reddit GIFs in comments** staying frozen instead of autoplaying until collapsed/expanded or refreshed (#349: @icpryde)
- Fix inline **GIFs not autoplaying on cellular** when Autoplay GIFs/Videos is set to Always (#347: @JeffreyCA)
- Fix the inline **video play button** missing on post-body Reddit videos and a clipped AirPlay icon (#350: @icpryde)
- Fix laggy **subreddit header** scrolling and incorrect handling on non-subreddit feeds (#339: @JeffreyCA)
- Fix **Share as Image** not opening under the iOS 26 native action menu (#335: @icpryde)
- Fix the **Rich Link Previews – Body** setting having no effect and following the Comments setting instead (#329: @nickclyde)
- Fix a crash in the banned-profile hook (#326: @JeffreyCA)
- Fix a crash when navigating into comments from a dangling host pointer in inline image cleanup (#362: @JeffreyCA)

## [v3.0.0] - 2026-05-29

### Features

- Post **GIFs in comments**: a new **Gif** button in the compose toolbar opens a built-in Giphy browser (trending + search) and uploads selected GIFs natively to Reddit (#276: @icpryde)
    - Requires a free Giphy API key — set it in **Settings > Custom API > API Keys > Giphy API Key**. See the in-app **Giphy & ImgChest API Key Setup** guide for instructions (#285: @icpryde)
    - Inline playback honors **Settings > General > Autoplay GIFs/Videos** with a static cover + play overlay when paused
- Add **Image Chest** inline album support: bare Image Chest links show the first image inline and open an in-app album viewer with tap-to-hide controls, idle auto-hide, and per-image pinch zoom (#241: @icpryde)
    - To set up Image Chest, create an account at https://imgchest.com, generate an API token at https://imgchest.com/profile/api, and paste it into **Img Chest API Key** under **Settings > Custom API > API Keys**
- Add **Subreddit Headers**: view subreddit banners and display icons on subreddit pages, with optional tap-to-set custom local images that can be reset anytime in Settings (#266: @jordanearle, @icpryde)
- Compact **u/username** and **r/subreddit** cards in rich link previews show avatar/icon, display name, member count, and an about snippet, with long-press peek into the native profile/community view (#262: @icpryde)
- Long-press peek now works on usernames and subreddit links in threads and comments (#262: @icpryde)
- Show **banned profile state** with a dead Snoo overlay on user profiles, and surface comment author hints for banned/suspended users (#271, #278: @icpryde, @jordanearle)
- Add **editable user flair text** support to Apollo's flair selector (#255: @nunoo)
- Rich link previews now support translation alongside the rest of post and comment content (#262: @icpryde)
- Subreddit list (Modern mode) polish (#262: @icpryde)
- Add **41 new Liquid Glass icon variants** by @jryng under a new **New Variants** group, plus new **Aperture Science** and **ApollOS** icon sets by @bajader, and reorganize the in-app App Icon picker into groups to reduce clutter (#287, #254: @DeltAndy123, @jryng, @bajader)
- Add **Inline Media Alignment** option in **Settings > Custom API > Media** to left-align, center, or right-align inline images that don't fill the full content width (#273: @lampemw)
- Rename **Custom API** to **Apollo Reborn Options** in Settings, polish the **Thanks To** screen with maintainer/code/icon & design groupings sourced from `contributors.json`, and add an **Apollo Reborn Subreddit** row that opens r/ApolloReborn in-app (#294: @icpryde)
- **Mask API keys** in Custom API settings: Reddit, Reddit Secret, Imgur, Img Chest, and Giphy fields show dots when idle and reveal only while editing (#276: @icpryde)
- Add **Buy Us a Coffee** screen in Settings with maintainer links, and move Apollo's original **Tip Jar** to **Settings > About** above **What's New** (#294: @icpryde)

### Fixes

- Fix scroll freeze / loading-spinner lockup while scrolling threads with rich link previews (#262: @icpryde)
- Fix comment layout shifting around as user avatars load in (#262: @icpryde)
- Replace placeholder filler text in rich link previews with skeleton loading bars, and reduce flicker when previews reappear (#262: @icpryde)
- Fix a stray translucent star/blob on rich link previews when using Share as Image (#262: @icpryde)
- Fix visionOS (Vision Pro) use-after-free crash on multireddits (#270: @rebelancap)
- Fix X and Edit buttons touching the top of the account switcher popup on Liquid Glass (#275: @lampemw)
- General stability improvements around rapid subreddit navigation and image loading (#262, #266: @icpryde, @jordanearle)
- Smoother scrolling through threads with lots of rich link previews (#262: @icpryde)
- Keep user profile cards and peek previews up to date when an account is suspended or banned (#278: @jordanearle, @icpryde)
- Fix launch crash when opening a banned user's profile (#276: @icpryde)
- Fix crash on Reddit link previews in some comment threads (#276, #280: @JeffreyCA, @icpryde)
- Fix Reddit-hosted GIFs stopping animation after leaving and returning to a thread (#276: @icpryde)
- Fix Giphy GIFs posted from Apollo not rendering in the official Reddit iOS app (and showing a "image was probably deleted" placeholder when editing in Apollo) (#289: @icpryde)
- Fix Compact link preview cards growing to hero size and overlapping the next comment after voting on a comment that contains a link (#290: @icpryde)

## [v2.14.0] - 2026-05-20

### Features

- **Notification Backend** support (requires paid Apple Developer account): point Apollo at your own forked self-hosted [apollo-backend](https://github.com/nickclyde/apollo-backend) instance so push registrations, watchers, and inbox checks route there instead of being silently dropped. (Thanks @nickclyde!)
    - Configure in **Settings > Custom API > Notification Backend** with the backend URL and optional registration token. Leave empty to keep current blocking behavior.
    - APNs delivery still requires a paid Apple Developer account on the signing side. 
- New **Reddit API Secret** field in **Settings > Custom API > API Keys** so per-account Reddit credentials can be forwarded to a self-hosted notification backend that performs token refreshes server-side. Usually left empty for installed-app Reddit credentials. (Thanks @nickclyde!)

### Fixes

- Improve **Profile Picture Tab Icon** reliability across Liquid Glass tab bar refreshes, theme changes, and app foregrounding.
- Refine Liquid Glass **Hide Bars on Scroll** idle behavior with smoother re-collapse/re-expand handling and disable the idle setting on unsupported iOS versions.
- Improve performance and stability across subreddit list polish, rich link previews, and the media post composer.

## [v2.13.0] - 2026-05-19

### Features

- Add **Rich Link Previews**: first-party cards for YouTube, Reddit, GitHub, Wikipedia, Twitter/X, Bluesky, and a configurable preview card color (thanks @icpryde!)
    - Configurable for posts and comments separately between with Full, Compact, and Off in **Settings > Custom API > Media**
- Profile pages now include Reddit display name, about text, and an Edit button that opens Reddit's profile editor (thanks @icpryde!)
- New **Profile Picture Tab Icon** setting (**Settings > Custom API > Media**) that displays user profile picture in the tab bar.
- Polish subreddit list view with a custom alphabet index overlay, larger favourite-star hit targets, and a **Modern Subreddit Dividers** style (**Settings > Custom API > Subreddits**) (thanks @icpryde!)
- Liquid Glass: replace action sheets with native iOS action menus throughout the app
- Liquid Glass: add new **Sunset** app icon (thanks @bajader!), rename icons, and show icon designer names in the picker

### Fixes

- Fix user profile pictures appearing inside flair text
- Fix the media post body text editor in subreddits that do not expose Apollo's normal Text tab (thanks @icpryde!)
- Fix subreddit list view scroll position shifting after favouriting a subreddit
- Fix stale subreddit entries lingering after unfavouriting from Favourites section
- Liquid Glass: fix separators blocking alphabet in subreddit list view
- Update Custom API settings view to match app theme
- Add statsigapi.net to the blocked URL list 

## [v2.12.0b] - 2026-05-16

### Features

- Add an optional **Text** row to Media posts that opens Apollo's native Post Text editor (with Markdown toolbar) and submits the body text alongside Reddit-hosted media (thanks @icpryde!)
- Add a long-press menu on profile usernames to copy the username to the clipboard (thanks @icpryde!)
- Add single-video Reddit-hosted uploads from the media composer, including video selection, poster upload, and native hosted-video posts (thanks @icpryde!)
- Refresh user profile pictures on pull-to-refresh and add a **Clear Profile Picture Cache** action under **Settings > Custom API > Media**.
- Add **harunatsu** Liquid Glass app icon to Apollo's native App Icon picker (thanks @jordanearle and /u/harunatsu91202024!)
- Liquid Glass: new **Tab Bar Re-Expands When Idle** toggle in **Settings > Custom API > General** that re-expands the tab bar after a deliberate upward scroll or a longer idle timeout (thanks @icpryde!)
- New **Thanks To** screen under **About** section. Thank you to all the contributors who've helped make this tweak what it is ❤️

### Fixes

- Fix Reddit-hosted multi-image photo posts by submitting them as native Reddit galleries instead of Imgur albums, including the post-submit comments permalink Apollo opens after success (thanks @icpryde!)
- Fix the Photo Post composer thumbnail strip so all selected images can be reviewed with reliable horizontal scrolling before submit (thanks @icpryde!)
- Improve user avatar loading on multireddits

## [v2.11.0] - 2026-05-15

- **Liquid Glass app icons!** Apollo's native App Icon picker now ships with 4 community-designed Liquid Glass app icons that render with full iOS 26 Liquid Glass effects on the home screen
    - Requires re-patching your IPA using the updated `patch.sh` script or **Patch IPA** GitHub Action. Previously patched IPAs won't show them
    - Huge thanks to @jordanearle for figuring out the `.icon` → `Assets.car` build flow, @DeltAndy123 for the asset-rebuild tooling and tint fixes, and to @jryng, @iGerman00, and @metalnakls for the icon designs
- New **Show User Profile Pictures** toggle to display Reddit user avatars next to usernames in posts, comments, as well as in user profiles (thanks @icpryde for implementing this feature!)
    - Configure in **Settings > Custom API > Media > Show User Profile Pictures**
- Preserve typed text when submitting Reddit-hosted image comments (thanks @icpryde!)
- Remove duplicate **Hide Next Parent Button** setting; Apollo already provides this as **Show Jump Button** (thanks @icpryde!)
- Fix Pixel Pals receiving 3 food items on every launch (thanks @DeltAndy123!)

## [v2.10.0] - 2026-05-12

- New **Hide Next Parent Button** toggle in **Settings > Custom API > General** to hide the floating button in the bottom-right of comments views (thanks @icpryde!)
- Liquid Glass: **Hide Bars on Scroll** now uses native iOS 26 tab bar minimize behaviour so it collapses into the small pill on scroll-down and re-expands on scroll-up (thanks @icpryde!)
- Fix Reddit-hosted image uploads in text posts failing with a `BAD_URL` error
- Improve link-button hiding with inline media previews

## [v2.9.0] - 2026-05-11

- New **Inline Media Previews** option to render images, GIFs, and videos inline within posts and comments
    - Configure in **Settings > Custom API > Media > Inline Media Previews** (on by default)
    - Supports most animated GIFs (including GIFV), Reddit hosted videos, and Imgur images and albums
    - Thank you @icpryde for the collaboration and adding support for videos, Imgur albums, and thumbnail retrieval
- Fix Apollo bug where viewing MP4-style GIFs / GIFVs on subsequent loops would randomly freeze
- Fix rare crash issue caused by comment collapse hooks
- Liquid Glass: fix tab bar icon and label tinting so it adapts to light/dark mode and to bright/dark content behind the glass material (thanks @icpryde!)
- Liquid Glass: fix subreddit title being misaligned to the left in the navigation bar

## [v2.8.0] - 2026-05-08

- New **Image Upload Host** option to upload images directly to Reddit instead of Imgur (thanks @icpryde for the implementation!)
    - Configure in **Settings > Custom API > Media > Image Upload Host**
    - Reddit image upload is **experimental** and does not currently support multi-image or video uploads
        - Right after posting, Apollo may briefly show a generic preview icon while Reddit finishes processing the image. Pull to refresh and the real thumbnail should appear

## [v2.7.2] - 2026-05-07

- Bulk translation: add Bosnian language support (thanks @hllvc!)

## [v2.7.1] - 2026-05-06

- Bulk translation: fix post titles getting automatically translated when Auto Translate is off (thanks @icpryde!)
- Fix crash when searching for a URL in the Search tab. URL searches now return posts that link to that URL.

## [v2.7.0] - 2026-05-05

- New **Tag Filters** feature to blur NSFW and/or Spoiler posts (including titles) in feeds (thanks @icpryde for implementing this!)
    - Configure in **Settings > Tag Filters**
    - Tap a blurred post for a "View hidden post?" confirmation alert
    - Per-subreddit overrides let you toggle NSFW or Spoiler filtering for individual subreddits
- Bulk translation fixes (thanks @icpryde!):
    - Fix post body briefly flashing the original language after voting, and not reverting when toggling translation off while scrolled past the body
    - Fix comment cells being skipped when toggling translation, and translations appearing half-applied after returning to Apollo from another app
    - Fix plain multi-paragraph post bodies being skipped

## [v2.6.1] - 2026-05-01

- Fix tab bar disappearing after sharing content

## [v2.6.0] - 2026-04-30

- Bulk translation improvements (thanks @icpryde for continuing to refine this!)
    - New **Don't Translate** languages list in **Settings > Translation** to keep selected languages untranslated
    - New option to translate post titles in **Settings > Translation**
    - Various bug fixes and stability improvements
- Tap a comment or post's relative-time label (e.g. "2.8y") to show an alert with the absolute creation date and time, mirroring Apollo's existing "Edited" alert
- Liquid Glass: fix tab bar not reappearing on scrolling up when "Hide Bars on Scroll" is enabled (thanks @icpryde for the fix!)
- Liquid Glass: hide translucent status bar background strip that appears at the top of the screen when "Hide Bars on Scroll" is enabled
- Liquid Glass: fix first list row being clipped under nav bar in subreddit list view when "Hide Bars on Scroll" is enabled

## [v2.5.0] - 2026-04-28

- New bulk translation feature for comment threads and self posts (thanks @icpryde for implementing this feature!)
    - When enabled, loaded comments are translated in-place. Configure in **Settings > Translation**
    - Adds a per-thread globe toggle to switch between translated and original text in comments view
    - Supports both Google and LibreTranslate, with custom LibreTranslate URL and API key
    - Translations persist in place while voting, collapsing and expanding comments, opening previews, scrolling, and refreshing the thread
    - Preserves links while translated and leaves code or preformatted content untranslated

## [v2.4.0] - 2026-04-18

- Add option to proxy Imgur images through DuckDuckGo (Settings > General > Custom API > Media)
    - Only supports viewing single images; albums are not supported

## [v2.3.0] - 2026-04-09

- Add option to hide NSFW posts in Recently Read
- Show inline NSFW badge on post titles in Recently Read
- Use distinct placeholder thumbnails for self-posts vs link posts in Recently Read

## [v2.2.1] - 2026-03-25

- Block additional tracking and analytics URLs (thanks @Uranosphaerite!)
- Liquid Glass: fix header flicker issue in comments

## [v2.2.0] - 2026-03-20

- Add "Collapse Pinned Comments" setting to auto-collapse pinned/stickied comments
- Add "Can't sign in?" troubleshooting section
- Liquid Glass: fix blur overlay issue when viewing messages

## [v2.1.0] - 2025-03-12

- Add Steam store deep linking support (thanks @wdeezy for the contribution!)
    - To enable, toggle "Open Steam Links in App" in Custom API > General
- Update default recently read posts limit to be unlimited
- Fix share links opening in different Apollo app
- Fix Pixel Pals making dynamic island taller than expected on newer iPhone models

## [v2.0.0] - 2025-03-07

🎉 ***Massive*** update that enables Ultra features like saved categories, new app icons and Pixel Pals! This also brings new features like recently read posts and fixes for some longstanding Apollo bugs.

The Custom API settings view has also been redesigned and is now accessible directly from Settings.

**Note:** Ultra features that rely on push notifications do not work out of the box. Advanced users can optionally point the tweak at a self-hosted [apollo-backend](https://github.com/nickclyde/apollo-backend) fork (see **Settings > Custom API > Notification Backend**) — APNs delivery requires a paid Apple Developer account on the signing side.

| | | |
|:--:|:--:|:--:|
| <img src="img/settings.jpg" alt="Settings" width="200"> | <img src="img/custom.jpg" alt="Custom API Settings" width="200"> | <img src="img/recents.jpg" alt="Recently Read" width="200"> |

### Saved Categories
- To enable saved categories, set "Allow Saved Categories" in Settings > General > Other
- New "Saved Categories" section in Settings tab to edit and delete saved categories
- Fixed: Saved category names are now consistently sorted in menus
- **Note:** Saved categories are global, while saved items are tied to individual accounts

### Recently Read
- New "Recently Read" button in Profile tab to view and clear all recently read posts
- "Disable Marking Posts Read" **must be unchecked** in Settings > General > Mark Read / Hiding Posts
- **Note:** Recently read is global (not account-specific)

### Media Playback
- New "Unmute Videos in Comments" setting (Settings > General > Custom API)
    - **Default**: Default Apollo behaviour
    - **Remember from Fullscreen Player**: If you unmute a video in the fullscreen player, it stays unmuted when you navigate into comments
    - **Always**: Header videos are always automatically unmuted after opening comments 
- New "Preferred GIF Fallback Format" setting (Settings > General > Custom API)
    - Choose between GIF or MP4 when Apollo fetches certain animated images from Reddit API
    - Try setting to "GIF" if you find certain animated images get stuck with loading spinner

### Other Issues Fixed
- Interacting with Ultra features and settings no longer causes app to crash
    - "New Comments Highlightifier" can be toggled normally in Settings > General, and is removed from Custom API settings
- Fix multi-image Imgur uploads failing the first time
- Fix share links opening in webview on iOS 26
- Fix album image count label placement on newer iPhone models
- Fix "Processing img" in self-posts
- Liquid Glass: fix clipping when collapsing long comment chains
- Add support for YouTube Shorts links
- Various video playback fixes and improvements

### Pixel Pals
- Pixel Pals are now available on newer iPhone models
- Unlock hidden "Artificial Superintelligence" Pixel Pal

### App Icons & Themes
- Unlock hidden "Chumbus" theme
- Unlock all app icons, including:
    - Community Icon Pack
    - SPCA Animals Pack
    - Ultra Icons
    - <details>
      <summary>22 Sekrit Icons (click to expand)</summary>

        - Beans (Black Friday 2022)
        - Sloth-kun
        - iJustine / Wrapping Paper
        - America!
        - Super America
        - UK / Hugh Laurie
        - Yo. Jonathan Here. (TLD Today)
        - ApolloBook Pro
        - Wallpapers
        - ATP
        - Phil Schiller
        - Canada D'Eh
        - Ukraine
        - Ernest
        - Sus (Among Us)
        - Dave2D
        - MKBHD (Keith)
        - Peachy (Neon Peach)
        - Linus Tech Tips
        - Andru Edwards
        - Everything Apple Pro (Icons Drop Test)\*
        - Rene Ritchie
        - Snazzy Labs

         The "Icons Drop Test" icon does not show up in App Icons. To set, go to Settings > About, shake device, and input `everythingapplepro`.
      </details>

## [v1.4.5] - 2026-02-17

- Prevent certain crashes when Reddit API goes down

## [v1.4.4] - 2026-02-13

- Fix GIFs showing up as `Processing img <id>` in comments

## [v1.4.3] - 2026-02-12

- Fix inline Giphy GIFs not loading in comments

## [v1.4.2] - 2026-02-06

- Update default trending source to `https://jeffreyca.github.io/subreddits/trending-subriff-blended.txt`
    - Previous source has been discontinued
- Fix certain GIFs playing at 2x speed on 120Hz displays

## [v1.4.1] - 2026-01-23

- Fix certain Streamable links not loading in media view

## [v1.4.0] - 2026-01-10

- Support custom redirect URI and user agent (in Settings > General > Custom API)
- Liquid Glass: fix sort options alignment in comment view

## [v1.3.2] - 2026-01-07

- Fix crashes in Custom API settings on older iOS versions

## [v1.3.1] - 2026-01-03

- Liquid Glass UI improvements and fixes:
    - Restore long press gesture on account tab to open account switcher
    - Fix opaque nav bar background in dark mode
    - Fix dark band appearing in nav bar when scrolling
    - Fix misaligned tab labels on startup

## [v1.3.0] - 2025-12-28

- Backup and restore most Apollo and tweak settings (in Settings > General > Custom API)
    - Settings are exported as a .zip file with 2 plist files: preferences.plist (most Apollo and tweak settings) and group.plist (filters, theme settings)
    - Restoring settings **does not** restore or affect existing account logins. This means on a clean install, accounts need to be re-added manually. The backup .zip contains an accounts.txt with all account usernames for reference.
- Update Custom API Settings layout

## [v1.2.6] - 2025-11-08

- Fix video downloads failing on certain v.redd.it videos
    - Recently, Reddit started using [CMAF media format](https://developer.apple.com/documentation/http-live-streaming/about-the-common-media-application-format-with-http-live-streaming-hls) for serving video content, which Apollo does not natively support downloading for.

## [v1.2.5] - 2025-10-18

- Fix occassional crashes when scrolling on iOS 26 with Liquid Glass patch (thanks @dankrichtofen for the original implementation)
- Fix crashes when tapping share URL link buttons on iOS 26
    - Note that this is **not** a full fix. Tapping the link button now navigates to a webview on iOS 26. As a workaround, tap the inline text (see [comment here](https://github.com/Apollo-Reborn/Apollo-Reborn/issues/62#issuecomment-3247359652)).
- Fix debug logging on iOS 26

## [v1.2.4] - 2025-08-23

- Fix RedGIFs links loading without sound (again)

## [v1.2.3] - 2025-04-07

- Fix issue with Imgur multi-image uploads consistently failing. Note that multi-image uploads still fail on the first attempt but should succeed on the next attempt.
- Update Custom API settings with link to [new GitHub discussion](https://github.com/Apollo-Reborn/Apollo-Reborn/discussions/60) where you can share your own subreddit sources with others.

## [v1.2.2] - 2025-01-16

- Fix video downloads failing on certain v.redd.it videos
    - Note that the `.deb` file is significantly larger (several MB) because of new external dependencies needed to fix the issue (FFmpegKit)

## [v1.2.1] - 2024-12-19

- Custom random and trending subreddits - you can now specify an external URL to use as the source for random and trending subreddits (in Settings > General > Custom API)
    - Sources should be a plaintext file with one subreddit name per line, without the `/r/` prefix (see examples below)
    - Default trending source (data from [gummysearch.com](https://gummysearch.com/tools/top-subreddits/)): https://jeffreyca.github.io/subreddits/trending-gummy-daily.txt
    - Default /r/random source: https://jeffreyca.github.io/subreddits/popular.txt
    - New setting to customize how many trending subreddits to show
    - New setting to show a dedicated RandNSFW button
- Minor UI updates to the settings view
- URL optimizations (thanks [@ryannair05](https://github.com/ryannair05)!)

## [v1.1.8] - 2024-12-07

- Fix RedGIFs links loading without sound (thanks [@iCrazeiOS](https://github.com/iCrazeiOS)!)

## [v1.1.7b] - 2024-10-25

- Add rootless package (thanks [@darkxdd](https://github.com/darkxdd)!)

## [v1.1.7] - 2024-10-19

- Improve parsing `new.reddit.com` and `np.reddit.com` links

## [v1.1.6] - 2024-10-05

- Fix issue with share URLs not working after device locks
- Remove unused code for handling Imgur links

## [v1.1.5b] - 2024-09-18

- Fix rare crashing issue
- Include tweak version in Custom API settings view

## [v1.1.4] - 2024-08-28

- Improve share URL and Imgur link parsing (specifically URLs formatted like: `https://imgur.com/some-title-<imageid>`)
- Fix crashing issue when loading content

## [v1.1.3] - 2024-08-23

Fix issue with newer Imgur images and albums not loading properly

## [v1.1.2] - 2024-08-01

Update user agent to fix multireddit search

## [v1.1.1] - 2024-07-27

- Working hybrid implementation of "New Comments Highlighter" Ultra feature
- Add FLEX integration for debugging/tweaking purposes (requires app restart after enabling in Settings -> General -> Custom API)

## [v1.0.12] - 2024-07-25

Use generic user agent independent of bundle ID when sending requests to Reddit

## [v1.0.11] - 2024-02-27

Fix issue with Imgur uploads consistently failing. Note that multi-image uploads may still fail on the first attempt.

## [v1.0.10] - 2024-01-22

Add support for /u/ share links (e.g. `reddit.com/u/username/s/xxxxxx`).

## [v1.0.9] - 2023-12-29

- Randomize "trending subreddits list" so it doesn't show **iOS**, **Clock**, **Time**, **IfYouDontMind** all the time - thanks [@iCrazeiOS](https://github.com/iCrazeiOS)!
    - Context: There isn't an official Reddit API to get the currently trending subreddits. Apollo has a hardcoded mapping of dates to trending subreddits in this file called `trending-subreddits.plist` that is bundled inside the .ipa. The last date entry is `2023-9-9`, which is why Apollo has been falling back to the default **iOS**, **Clock**, **Time**, **IfYouDontMind** subreddits lately.

## [v1.0.8] - 2023-12-15

- Lower minimum iOS version requirement to 14.0
- Toggleable settings for blocking announcements and some Ultra settings (not fully working, see [#1](https://github.com/Apollo-Reborn/Apollo-Reborn/issues/1)). **These are the same as the previous experimental builds.**
    - All toggles are located in Settings -> General -> Custom API
    - New Comments Highlightifier shows new comment count badge, but doesn't highlight comments inside a thread
    - Subreddit Weather and Time widget doesn't seem to work (not showing or loads infinitely)

## [v1.0.7] - 2023-12-07

- Add support for resolving Reddit media share links ([#9](https://github.com/Apollo-Reborn/Apollo-Reborn/pull/9)) - thanks [@mmshivesh](https://github.com/mmshivesh)!

## [v1.0.5] - 2023-12-02

- Fix crash when tapping on spoiler tag

## [v1.0.4] - 2023-11-29

Add support for share links (e.g. `reddit.com/r/subreddit/s/xxxxxx`) in Apollo. These links are obfuscated and require loading them in the background to resolve them to the standard Reddit link format that can be understood by 3rd party apps.

The tweak uses the workaround and further optimizes it by pre-resolving and caching share links in the background for a smoother user experience. You may still see the occassional (brief) loading alert when tapping a share link while it resolves in the background.

There are currently a few limitations:
- Share links in private messages still open in the in-app browser
- Long-tapping share links still pop open a browser page

## [v1.0.3b] - 2023-11-26
- Treat `x.com` links as Twitter links so they can be opened in Twitter app
- Fix issue with `apollogur.download` network requests not getting blocked properly (#3)

## [v1.0.2c] - 2023-11-08
- Fix Imgur multi-image uploads (first attempt usually fails but subsequent retries should succeed)

## [v1.0.1] - 2023-10-18
- Suppress wallpaper popup entirely

## [v1.0.0] - 2023-10-13
- Initial release

[v3.1.1]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.15.11_3.1.0...v1.15.11_3.1.1
[v3.1.0]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.15.11_3.0.0...v1.15.11_3.1.0
[v3.0.0]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v2.14.0...v1.15.11_3.0.0
[v2.14.0]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v2.13.0...v2.14.0
[v2.13.0]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v2.12.0b...v2.13.0
[v2.12.0b]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v2.11.0...v2.12.0b
[v2.11.0]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v2.10.0...v2.11.0
[v2.10.0]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v2.9.0...v2.10.0
[v2.9.0]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v2.8.0...v2.9.0
[v2.8.0]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v2.7.2...v2.8.0
[v2.7.2]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v2.7.1...v2.7.2
[v2.7.1]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v2.7.0...v2.7.1
[v2.7.0]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v2.6.1...v2.7.0
[v2.6.1]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v2.6.0...v2.6.1
[v2.6.0]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v2.5.0...v2.6.0
[v2.5.0]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v2.4.0...v2.5.0
[v2.4.0]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v2.3.0...v2.4.0
[v2.3.0]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v2.2.1...v2.3.0
[v2.2.1]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v2.2.0...v2.2.1
[v2.2.0]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v2.1.0...v2.2.0
[v2.1.0]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v2.0.0...v2.1.0
[v2.0.0]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.4.5...v2.0.0
[v1.4.5]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.4.4...v1.4.5
[v1.4.4]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.4.3...v1.4.4
[v1.4.3]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.4.2...v1.4.3
[v1.4.2]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.4.1...v1.4.2
[v1.4.1]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.4.0...v1.4.1
[v1.4.0]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.3.2...v1.4.0
[v1.3.2]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.3.1...v1.3.2
[v1.3.1]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.3.0...v1.3.1
[v1.3.0]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.2.6...v1.3.0
[v1.2.6]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.2.5...v1.2.6
[v1.2.5]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.2.4...v1.2.5
[v1.2.4]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.2.3...v1.2.4
[v1.2.3]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.2.2...v1.2.3
[v1.2.2]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.2.1...v1.2.2
[v1.2.1]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.1.8...v1.2.1
[v1.1.8]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.1.7b...v1.1.8
[v1.1.7b]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.1.7...v1.1.7b
[v1.1.7]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.1.6...v1.1.7
[v1.1.6]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.1.5b...v1.1.6
[v1.1.5b]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.1.4...v1.1.5b
[v1.1.4]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.1.3...v1.1.4
[v1.1.3]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.1.2...v1.1.3
[v1.1.2]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.1.1...v1.1.2
[v1.1.1]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.0.12...v1.1.1
[v1.0.12]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.0.11...v1.0.12
[v1.0.11]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.0.10...v1.0.11
[v1.0.10]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.0.9...v1.0.10
[v1.0.9]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.0.8...v1.0.9
[v1.0.8]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.0.7...v1.0.8
[v1.0.7]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.0.5...v1.0.7
[v1.0.5]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.0.4...v1.0.5
[v1.0.4]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.0.3b...v1.0.4
[v1.0.3b]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.0.2c...v1.0.3b
[v1.0.2c]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.0.1...v1.0.2c
[v1.0.1]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.0.0...v1.0.1
[v1.0.0]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/v1.0.0
