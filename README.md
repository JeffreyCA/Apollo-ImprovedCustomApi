# Apollo-ImprovedCustomApi
[![Build and release](https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/actions/workflows/buildapp.yml/badge.svg)](https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/actions/workflows/buildapp.yml)

Apollo for Reddit with in-app configurable API keys and several fixes and improvements. Tested on version 1.15.11.

<img src="img/demo.gif" alt="demo" width="250"/>

## Features
- Use Apollo for Reddit with your own Reddit and Imgur API keys
- Working Imgur integration (view, delete, and upload single images and multi-image albums) 
- Handle x.com links as Twitter links so that they can be opened in the Twitter app
- Suppress unwanted messages on app startup (wallpaper popup, in-app announcements, etc)
- Support /s/ share links (reddit.com/r/subreddit/s/xxxxxx) natively
- Support media share links (reddit.com/media?url=) natively
- **Fully working** "New Comments Highlightifier" Ultra feature
- Use generic user agent for requests to Reddit
- FLEX debugging
- Support custom external sources for random and trending subreddits
- Working v.redd.it video downloads

## Known issues
- Apollo Ultra features may cause app to crash 
- Imgur multi-image upload
    - Uploads usually fail on the first attempt but subsequent retries should succeed
- Share URLs in private messages and long-tapping them still open in the in-app browser

## Looking for IPA?
One source where you can get the fully tweaked IPA is [Balackburn/Apollo](https://github.com/Balackburn/Apollo).

## iOS 26 Liquid Glass Patch
To enable Liquid Glass in Apollo on iOS 26, the IPA must be patched using the `liquid_glass.sh` script or GitHub Action.

> [!NOTE]
> This **does not** inject the tweak itself; it only enables Liquid Glass. This supports both non-tweaked and tweaked Apollo IPAs.
>
> Credit for the patching method goes to [@ryannair05](https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/issues/63).

### 1. Local Script
Run the `liquid_glass.sh` script to patch the IPA on your machine.
```bash
./liquid_glass.sh <path_to_ipa> [--remove-code-signature] [-o|--output <output_file>]
```

### 2. GitHub Action
Fork this repo and navigate to the **Actions** tab. Run the **Enable Liquid Glass (iOS 26 only)** workflow.

You can provide the IPA via a direct URL or reference a GitHub release artifact. The workflow will create a draft release with the patched IPA.

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

1. `git clone https://github.com/JeffreyCA/Apollo-ImprovedCustomApi`
2. `cd Apollo-ImprovedCustomApi`
3. `git submodule update --init --recursive`
4. `make package` or `make package THEOS_PACKAGE_SCHEME=rootless` for rootless variant

## Credits
- [Apollo-CustomApiCredentials](https://github.com/EthanArbuckle/Apollo-CustomApiCredentials) by [@EthanArbuckle](https://github.com/EthanArbuckle)
- [ApolloAPI](https://github.com/ryannair05/ApolloAPI) by [@ryannair05](https://github.com/ryannair05)
- [ApolloPatcher](https://github.com/ichitaso/ApolloPatcher) by [@ichitaso](https://github.com/ichitaso)
- [GitHub Copilot](https://github.com/features/copilot)
