# Apollo-ImprovedCustomApi (v2)
[![Build and release](https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/actions/workflows/buildapp.yml/badge.svg)](https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/actions/workflows/buildapp.yml) ![GitHub Release](https://img.shields.io/github/v/release/JeffreyCA/Apollo-ImprovedCustomApi)

iOS tweak for [Apollo for Reddit app](https://apolloapp.io/) that lets you continue using Apollo with your own API keys after its shutdown in June 2023. The tweak also unlocks several Ultra features and includes several enhancements and fixes.

| | | |
|:--:|:--:|:--:|
| <img src="img/settings.jpg" alt="Settings" width="250"> | <img src="img/custom.jpg" alt="Custom API Settings" width="250"> | <img src="img/recents.jpg" alt="Recently Read" width="250"> |

## Features

### General

- Use Apollo with your own Reddit and Imgur API keys ([don't have one?](#dont-have-an-api-key))
- Customizable redirect URI and user agent
- Fully working Imgur integration (view, delete, upload single and multi-image albums)
- Liquid Glass UI enhancements for iOS 26
- Suppress wallpaper popups and in-app announcements
- Pixel Pals support on newer iPhone models
- Reddit `/s/` share links support
- Image viewer and video playback fixes and enhancements
- Deep linking support for Steam, YouTube Shorts

### Unlocked Ultra Features and Easter Eggs

- New Comments Highlightifier
- Saved Categories
- App Icons + Wallpapers (Community Icon Pack, SPCA Animals, Ultra Icons, "sekrit" app icons)
- Pixel Pals (including hidden "Artificial Superintelligence")
- Themes (including hidden "Chumbus" theme)

### New Features

- **Backup & Restore**: Export and import Apollo and tweak settings as a .zip
- **Custom Subreddit Sources**: Use external URLs for random and trending subreddits
- **Recently Read Posts**: View all recently read posts from the Profile tab
- **Editable Saved Categories**: Add, rename, and delete saved post categories (Settings > Saved Categories)

## Known Issues

- Long-tapping share links open in the in-app browser

## Safari integration

I recommend using the [Open-In-Apollo](https://github.com/AnthonyGress/Open-In-Apollo) userscript to automatically open Reddit links in Apollo.

## Looking for IPA?

One source where you can get the fully tweaked IPA is [Balackburn/Apollo](https://github.com/Balackburn/Apollo).

## Don't have an API key?

> [!IMPORTANT]
> Reddit and Imgur no longer allow new API key creation so you'll need to share or use existing keys.

See [this guide](https://github.com/wchill/patcheddit?tab=readme-ov-file#what-if-i-dont-have-a-client-id) for workarounds (proceed at your own risk).

When using credentials from another app, set the **Reddit API Key** (OAuth client ID), **Redirect URI**, and **User Agent** in the tweak settings to match the app's values. You'll also need to register the redirect URI scheme in the IPA (see [below](#custom-redirect-uri)).

More discussion in [#82](https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/issues/82).

## Custom Redirect URI

The redirect URI scheme (the part before `://`) must be registered in the Apollo IPA's `Info.plist` under `CFBundleURLTypes`, otherwise the OAuth callback won't return to Apollo.

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>twitterkit-xyz</string>
      <string>apollo</string>
      <string>custom</string> <!-- add 'custom' you want to use custom://reddit-oauth -->
    </array>
  </dict>
</array>
```

You can use `patch.sh` or the GitHub action mentioned below to add URL schemes.

## Patching IPA

`patch.sh` and the **Patch IPA** GitHub Action can apply optional patches (Liquid Glass for iOS 26, custom URL schemes) to Apollo IPAs. These do **not** inject the tweak itself.

```bash
./patch.sh <path_to_ipa> [--liquid-glass] [--url-schemes <schemes>] [--remove-code-signature] [-o <output>]
```

To use the GitHub Action, fork this repo and navigate to **Actions** > **Patch IPA**. The workflow accepts:

- **IPA source**: Direct URL or a release artifact from this repository
- **Liquid Glass**: Enable/disable the iOS 26 patch
- **URL Schemes**: Comma-separated list of schemes to add (e.g., `custom,test`)
- **Remove Code Signature**: Optionally strip the code signature

Credit for the Liquid Glass patching method goes to [@ryannair05](https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/issues/63).

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

**Requirements:**
- [Theos](https://github.com/theos/theos)

**Instructions:**
1. `git clone https://github.com/JeffreyCA/Apollo-ImprovedCustomApi`
2. `cd Apollo-ImprovedCustomApi`
3. `git submodule update --init --recursive`
4. `make package` or `make package THEOS_PACKAGE_SCHEME=rootless` for rootless variant

## Credits
- [Apollo-CustomApiCredentials](https://github.com/EthanArbuckle/Apollo-CustomApiCredentials) by [@EthanArbuckle](https://github.com/EthanArbuckle)
- [ApolloAPI](https://github.com/ryannair05/ApolloAPI) by [@ryannair05](https://github.com/ryannair05)
- [ApolloPatcher](https://github.com/ichitaso/ApolloPatcher) by [@ichitaso](https://github.com/ichitaso)
- [GitHub Copilot](https://github.com/features/copilot) and [Claude Code](https://claude.com/product/claude-code)
