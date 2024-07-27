# Changelog

All notable changes to this project will be documented in this file.

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

[v1.0.12]: https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/compare/v1.0.12...v1.1.1
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
