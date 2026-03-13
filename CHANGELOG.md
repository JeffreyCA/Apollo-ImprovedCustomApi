# Changelog

All notable changes to this project will be documented in this file.

## [v2.1.0] - 2025-03-12

- Add Steam store deep linking support (thanks @wdeezy for the contribution!)
    - To enable, toggle "Open Steam Links in App" in Custom API > General
- Update default recently read posts limit to be unlimited
- Fix share links opening in different Apollo app
- Fix Pixel Pals making dynamic island taller than expected on newer iPhone models

## [v2.0.0] - 2025-03-07

🎉 ***Massive*** update that enables Ultra features like saved categories, new app icons and Pixel Pals! This also brings new features like recently read posts and fixes for some longstanding Apollo bugs.

The Custom API settings view has also been redesigned and is now accessible directly from Settings.

**Note:** Ultra features that rely on push notifications **still do not work**, and are unlikely to ever be supported.

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
    - Note that this is **not** a full fix. Tapping the link button now navigates to a webview on iOS 26. As a workaround, tap the inline text (see [comment here](https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/issues/62#issuecomment-3247359652)).
- Fix debug logging on iOS 26

## [v1.2.4] - 2025-08-23

- Fix RedGIFs links loading without sound (again)

## [v1.2.3] - 2025-04-07

- Fix issue with Imgur multi-image uploads consistently failing. Note that multi-image uploads still fail on the first attempt but should succeed on the next attempt.
- Update Custom API settings with link to [new GitHub discussion](https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/discussions/60) where you can share your own subreddit sources with others.

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
- Toggleable settings for blocking announcements and some Ultra settings (not fully working, see [#1](https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/issues/1)). **These are the same as the previous experimental builds.**
    - All toggles are located in Settings -> General -> Custom API
    - New Comments Highlightifier shows new comment count badge, but doesn't highlight comments inside a thread
    - Subreddit Weather and Time widget doesn't seem to work (not showing or loads infinitely)

## [v1.0.7] - 2023-12-07

- Add support for resolving Reddit media share links ([#9](https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/pull/9)) - thanks [@mmshivesh](https://github.com/mmshivesh)!

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

[v2.1.0]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v2.0.0...v2.1.0
[v2.0.0]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.4.5...v2.0.0
[v1.4.5]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.4.4...v1.4.5
[v1.4.4]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.4.3...v1.4.4
[v1.4.3]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.4.2...v1.4.3
[v1.4.2]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.4.1...v1.4.2
[v1.4.1]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.4.0...v1.4.1
[v1.4.0]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.3.2...v1.4.0
[v1.3.2]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.3.1...v1.3.2
[v1.3.1]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.3.0...v1.3.1
[v1.3.0]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.2.6...v1.3.0
[v1.2.6]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.2.5...v1.2.6
[v1.2.5]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.2.4...v1.2.5
[v1.2.4]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.2.3...v1.2.4
[v1.2.3]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.2.2...v1.2.3
[v1.2.2]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.2.1...v1.2.2
[v1.2.1]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.1.8...v1.2.1
[v1.1.8]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.1.7b...v1.1.8
[v1.1.7b]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.1.7...v1.1.7b
[v1.1.7]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.1.6...v1.1.7
[v1.1.6]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.1.5b...v1.1.6
[v1.1.5b]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.1.4...v1.1.5b
[v1.1.4]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.1.3...v1.1.4
[v1.1.3]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.1.2...v1.1.3
[v1.1.2]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.1.1...v1.1.2
[v1.1.1]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.0.12...v1.1.1
[v1.0.12]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.0.11...v1.0.12
[v1.0.11]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.0.10...v1.0.11
[v1.0.10]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.0.9...v1.0.10
[v1.0.9]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.0.8...v1.0.9
[v1.0.8]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.0.7...v1.0.8
[v1.0.7]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.0.5...v1.0.7
[v1.0.5]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.0.4...v1.0.5
[v1.0.4]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.0.3b...v1.0.4
[v1.0.3b]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.0.2c...v1.0.3b
[v1.0.2c]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.0.1...v1.0.2c
[v1.0.1]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.0.0...v1.0.1
[v1.0.0]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.0.0
