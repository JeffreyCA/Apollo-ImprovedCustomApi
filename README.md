# Apollo-ImprovedCustomApi
[![Build and release](https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/actions/workflows/buildapp.yml/badge.svg)](https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/actions/workflows/buildapp.yml)

Apollo for Reddit with in-app configurable API keys and several fixes and improvements. Tested on version 1.15.11.

<img src="img/demo.gif" alt="demo" width="250"/>

## Features
- Use Apollo for Reddit with your own Reddit and Imgur API keys
- Customizable redirect URI and user agent
- Working Imgur integration (view, delete, and upload single images and multi-image albums) 
- Handle x.com links as Twitter links so that they can be opened in the Twitter app
- Suppress unwanted messages on app startup (wallpaper popup, in-app announcements, etc)
- Support /s/ share links (reddit.com/r/subreddit/s/xxxxxx) natively
- Support media share links (reddit.com/media?url=) natively
- Working "New Comments Highlightifier" Ultra feature (must enable in Custom API settings)
- FLEX debugging
- Support custom external sources for random and trending subreddits
- Working v.redd.it video downloads
- Backup and restore Apollo and tweak settings
- Liquid Glass UI enhancements

## Known issues
- Apollo Ultra features may cause app to crash 
- Imgur multi-image upload
    - Uploads usually fail on the first attempt but subsequent retries should succeed
- Share URLs in private messages and long-tapping them still open in the in-app browser
    - On iOS 26, share URLs in link buttons also open in the in-app browser. As a workaround, tap the inline text link (see [comment here](https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/issues/62#issuecomment-3247359652))

## Looking for IPA?
One source where you can get the fully tweaked IPA is [Balackburn/Apollo](https://github.com/Balackburn/Apollo).

## Safari integration

I recommend using the [Open-In-Apollo](https://github.com/AnthonyGress/Open-In-Apollo) userscript to automatically open Reddit links in Apollo. It has enhanced search engine integration so Reddit links on search result pages (Google, Bing, etc.) open directly in Apollo without first redirecting to reddit.com.

## Patching IPA

The `patch.sh` script and **Patch IPA** GitHub Action can be used to apply optional patches to Apollo IPAs:

| Patch | Description |
|-------|-------------|
| **Liquid Glass** | Enables Liquid Glass UI on iOS 26 |
| **Custom URL Schemes** | Adds custom redirect URI schemes for OAuth login |

> [!NOTE]
> These patches **do not** inject the tweak itself. They work with both stock and tweaked Apollo IPAs.
>
> Credit for the Liquid Glass patching method goes to [@ryannair05](https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/issues/63).

### Local Script

```bash
./patch.sh <path_to_ipa> [options]
```

**Options:**
| Option | Description |
|--------|-------------|
| `--liquid-glass` | Apply Liquid Glass patch for iOS 26 |
| `--url-schemes <schemes>` | Comma-separated URL schemes to add (e.g., `custom,myapp`) |
| `--remove-code-signature` | Remove code signature from the binary |
| `-o, --output <file>` | Output filename (default: `Apollo-Patched.ipa`) |

### GitHub Action

Fork this repo and navigate to **Actions** > **Patch IPA**. The workflow accepts:

- **IPA source**: Direct URL or a release artifact from this repository
- **Liquid Glass**: Enable/disable the iOS 26 patch
- **URL Schemes**: Comma-separated list of schemes to add (e.g., `custom,test`)
- **Remove Code Signature**: Optionally strip the code signature

The workflow creates a draft release with the patched IPA.

## Custom Redirect URI

To use a custom redirect URI (e.g. `custom://reddit-oauth`), you'll need to also patch the IPA's `Info.plist` file and add the URI scheme (the part before `://`) to `CFBundleURLSchemes`. Otherwise, you won't be able to login to accounts.

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>twitterkit-xyz</string>
      <string>apollo</string>
      <string>custom</string> <!-- add if you want to use custom://reddit-oauth -->
    </array>
  </dict>
</array>
```

You can use `patch.sh` or the GitHub action mentioned above to do this.

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
