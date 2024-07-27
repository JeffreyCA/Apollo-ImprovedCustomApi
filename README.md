# Apollo-ImprovedCustomApi
[![Build and release](https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/actions/workflows/buildapp.yml/badge.svg)](https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/actions/workflows/buildapp.yml)

Apollo for Reddit with in-app configurable API keys and several fixes and improvements. Tested on version 1.15.11.

<img src="img/demo.gif" alt="demo" width="250"/>

## Features
- Use Apollo for Reddit with your own Reddit and Imgur API keys
- Working Imgur integration (view, delete, and upload single images and multi-image albums) 
- Handle x.com links as Twitter links so that they can be opened in the Twitter app
- Suppress unwanted messages on app startup (wallpaper popup, in-app announcements, etc)
- Support new share link format (reddit.com/r/subreddit/s/xxxxxx) so they open like any other post and not in a browser
- Support media share links (reddit.com/media?url=)
- **Fully working** "New Comments Highlightifier" Ultra feature
- Randomize "trending subreddits list" so it doesn't show **iOS**, **Clock**, **Time**, **IfYouDontMind** all the time
- Use generic user agent for requests to Reddit
- Support FLEX debugging

## Known issues
- Apollo Ultra features may cause app to crash 
- Imgur multi-image upload
    - Uploads usually fail on the first attempt but subsequent retries should succeed
- Share URLs in private messages and long-tapping them still open in the in-app browser

## Sideloadly
Recommended configuration:
- **Use automatic bundle ID**: *unchecked*
    - Enter a custom one (e.g. com.foo.Apollo)
- **Signing Mode**: Apple ID Sideload
- **Inject dylibs/frameworks**: *checked*
    - Add the .deb file using **+dylib/deb/bundle**
    - **Cydia Substrate**: *checked*
    - **Substitute**: *unchecked*
    - **Sideload Spoofer**: *unchecked*

## Build
### Requirements
- [Theos](https://github.com/theos/theos)

1. `git clone`
2. `git submodule update --init --recursive`
2. `make package`

## Credits
- [Apollo-CustomApiCredentials](https://github.com/EthanArbuckle/Apollo-CustomApiCredentials) by [@EthanArbuckle](https://github.com/EthanArbuckle)
- [ApolloAPI](https://github.com/ryannair05/ApolloAPI) by [@ryannair05](https://github.com/ryannair05)
- [ApolloPatcher](https://github.com/ichitaso/ApolloPatcher) by [@ichitaso](https://github.com/ichitaso)
- [GitHub Copilot](https://github.com/features/copilot)
