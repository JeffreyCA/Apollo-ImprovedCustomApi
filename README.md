# Apollo-Reborn
[![Subreddit](https://img.shields.io/reddit/subreddit-subscribers/ApolloReborn?style=flat&logoColor=purple&label=join%20r%2FApolloReborn&color=%238a02fe)](https://www.reddit.com/r/ApolloReborn/) ![GitHub Release](https://img.shields.io/github/v/release/Apollo-Reborn/Apollo-Reborn)

iOS tweak for [Apollo for Reddit app](https://apolloapp.io/) that lets you continue using Apollo with your own API keys after its shutdown in June 2023. The tweak also unlocks several Ultra features and includes several enhancements and fixes.

> [!NOTE]
> **Apollo-ImprovedCustomApi** is now **Apollo-Reborn**
>
> _May 22, 2026_ — This project is now under team-based maintainership to keep Apollo polished and sustainably maintained for the community - join us at [r/ApolloReborn](https://www.reddit.com/r/ApolloReborn/)!
>
> **Apollo Reborn team:** @JeffreyCA, @icpryde, @jordanearle, @nickclyde, @DeltAndy123 ❤️

## Install

Pre-built IPAs and AltStore Classic/SideStore/Feather sources are now available at **[apolloreborn.app](https://apolloreborn.app/#download)**!

### Which build should I install?

The download page offers **Standard / GLASS** builds (with Apollo's app extensions plus the Apollo-Reborn widgets) and **No Extensions** builds. They are the same app — the difference is how much it costs to sideload:

- **Standard / GLASS** bundle ~6 app extensions, so a sideload registers about **7 App IDs** (one per extension plus the app). A **free Apple ID** can register only **10 App IDs per 7 days**, so a clean single install fits — but it's easy to exceed by installing under more than one bundle ID, reinstalling within the same week, or sideloading other extension-bearing apps. If an install fails with an App ID error, install a **No Extensions** build or wait for older App IDs to expire. A **paid** Apple Developer account has a much higher cap. ([AltStore explains the limit](https://faq.altstore.io/altstore-classic/app-ids).)
- **No Extensions** strips all app extensions (including widgets), so it only needs **1 App ID** — the reliable choice on a free Apple ID that's running low.

> This is separate from whether an installed extension actually *launches* on iOS 26, which depends on your installer — see the caveat in [Opening links in Apollo](#opening-links-in-apollo).

## Don't have an API key?

> [!IMPORTANT]
> Reddit and Imgur no longer allow new API key creation so you'll need to share or use existing keys.
>
> Reddit has also recently started revoking API keys that are specifically used for Apollo or any other third party client. If you still have your own working key, see [Avoiding API key revocations](#avoiding-api-key-revocations).

Reddit has a special deal with [Dystopia](https://apps.apple.com/us/app/dystopia-for-reddit/id1430599061) and [RedReader](https://play.google.com/store/apps/details?id=org.quantumbadger.redreader) to use the API for free for accessibility reasons. It is possible to use the client ID from one of those apps on either iOS or Android:

1. Install [Dystopia](https://apps.apple.com/us/app/dystopia-for-reddit/id1430599061) from the App Store (if running iOS) or [RedReader](https://play.google.com/store/apps/details?id=org.quantumbadger.redreader) from the Play Store (if running Android).
2. Log in with your Reddit account in Dystopia/RedReader and allow it access to your account.
3. After logging in, you should receive an email from Reddit with the subject "You’ve authorized a new app in your Reddit account". Open the email and look for the text after "App ID". Copy that value.
4. In Apollo Reborn's settings, go to **Custom API** and enter the following values:
    - **Reddit API Key**: Paste the App ID you copied from the email
    - **Redirect URI**:
        - If using Dystopia: `dystopia://response`
        - If using RedReader: `redreader://rr_oauth_redir`
    - **User Agent**:
        - If using Dystopia: `ios:com.CarbonDev.Dystopia:v1.0.1(by /u/DystopiaForReddit)`
        - If using RedReader: `RedReader/1.25.1`
5. Log in to Reddit in Apollo normally. Reddit should ask to connect your Reddit account with Dystopia/RedReader instead of your own Reddit app. Accept the connection and you should be good to go!

Credits to [this guide](https://github.com/wchill/patcheddit?tab=readme-ov-file#what-if-i-dont-have-a-client-id) for the original workaround with RedReader.

More discussion in [#82](https://github.com/Apollo-Reborn/Apollo-Reborn/issues/82) and [#367](https://github.com/Apollo-Reborn/Apollo-Reborn/issues/367).

## Avoiding API key revocations

> [!NOTE]
> This section is for users who still have their **own** Reddit API key. If you're using the Dystopia/RedReader client IDs from the section above, do **not** change any of these values — that setup only works because it matches those apps' settings exactly.

Reddit doesn't publish how it decides which keys to revoke, but past revocation waves appear to target keys that identifiably belong to third-party clients. Keys whose settings don't mention Apollo have tended to survive. There are no guarantees, but you can remove the obvious signals. Reddit can see:

1. Your API app's registered settings at [reddit.com/prefs/apps](https://www.reddit.com/prefs/apps): name, description, about URL, and redirect URI.
2. The `redirect_uri` sent with every sign-in request.
3. The `User-Agent` header on all API traffic.

To scrub these:

1. **Rename your Reddit API app.** At [reddit.com/prefs/apps](https://www.reddit.com/prefs/apps), edit your app so the name, description, and about URL don't contain "Apollo", "Reborn", or the name of any other third-party client. Something generic and personal works best (e.g. `my-ios-app`).
2. **Change the redirect URI.** In the same edit form, replace `apollo://reddit-oauth` with a personal scheme (e.g. `myscheme://reddit-oauth`), then enter the **exact same value** in Apollo Reborn's settings under **Custom API** → **Redirect URI**. On v3.1.0 or later no IPA patching is needed — any scheme works (see [Custom Redirect URI](#custom-redirect-uri) if you're on an older version). You won't be signed out: the redirect URI is only checked at sign-in time, so existing sessions keep refreshing normally.
3. **Set a custom User Agent.** In **Custom API** → **User Agent**, don't leave the field blank — the built-in default is the same browser string for every Apollo Reborn user, which is itself a fingerprint. Use Reddit's recommended format, personalized to you: `ios:<your.bundle.id>:v1.0 (by /u/<your_username>)`.
4. **(Sideloaders, optional) Pick a bundle ID without "Apollo".** The bundle ID isn't sent to Reddit directly, so this is the least important signal, but it keeps "Apollo" out of any string that could end up in your user agent and costs nothing to change at signing time.

Finally, **don't copy these examples verbatim**. If everyone adopts the same "safe" name and redirect URI, that just becomes the next thing to scan for. The goal is to look like a small one-off personal script, which means values unique to you.

## Features

| | | | |
|:--:|:--:|:--:|:--:|
| <img src="img/settings.jpg" alt="Settings" width="250"> | <img src="img/custom.jpg" alt="Custom API Settings" width="250"> | <img src="img/recents.jpg" alt="Recently Read" width="250"> | <img src="img/inline.jpg" alt="Inline Images" width="250"> |
| <img src="img/lg-icons.jpg" alt="Liquid Glass Icons" width="250"> | <img src="img/avatar-profile.jpg" alt="User Profile Avatars" width="250"> | <img src="img/avatar-comments.jpg" alt="Comment Avatars" width="250"> | <img src="img/translation.jpg" alt="Translation" width="250"> |

### General

- Use Apollo with your own Reddit and Imgur API keys ([don't have one?](#dont-have-an-api-key))
- Fully working Imgur integration
- Native Reddit media upload support (images, albums, and videos)
- Liquid Glass icons and UI enhancements for iOS 26+
- Reddit `/s/` share links support
- Pixel Pals support on newer iPhone models
- Image viewer and video playback fixes and enhancements
- Proxy Imgur images through DuckDuckGo for regional blocks
- Deep linking support for Steam, YouTube Shorts
- Auto-collapse pinned comments

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
- **Bulk in-place translation**: Translate posts and comments in-place with configurable provider and target language (Settings > Translation)
- **Tap timestamp for creation date**: Tap a comment or post's relative-time label to see the absolute creation date and time
- **Tag Filters**: Blur NSFW and/or Spoiler posts (including titles) in feeds, with per-subreddit overrides (Settings > Tag Filters)
- **Inline Media Previews**: Render images, GIFs, videos, and Imgur albums inline within posts and comments (Settings > Custom API > Media > Inline Media Previews)
- **Rich Link Previews**: Render metadata-rich link cards in post bodies and comments (Settings > Custom API > Media)
- **User Profile Pictures**: Show Reddit user avatars next to usernames in feeds, comments, and user profiles (Settings > Custom API > Media > Show User Profile Pictures)
- **Self-hosted Notifications** (advanced): Optionally route push registrations, watchers, and inbox checks through your own [apollo-backend](https://github.com/Apollo-Reborn/apollo-backend) instance instead of having those requests silently dropped — delivered over native APNs (paid Apple Developer account) or the free [Bark](https://apps.apple.com/us/app/bark-custom-notifications/id1403753865) app, which works even on free-Apple-ID sideloads (Settings > Custom API > Notification Backend)

### Not seeing thumbnails or inline previews?

> [!TIP]
> If thumbnails or inline media previews aren't showing up, it's usually a Reddit account setting rather than a tweak issue. Open [old.reddit.com/prefs](https://old.reddit.com/prefs) and log in, then under the **Media** section:
>
> - Set **Thumbnails** to *"show thumbnails next to links"*
> - Set **Media previews** to *"auto-expand media previews"*
>
> Save your preferences and relaunch Apollo.

### Self-hosted notifications (advanced)

The legacy Apollo push backends went dark in June 2023 and are otherwise blocked by the tweak. If you run your own instance of [apollo-backend](https://github.com/Apollo-Reborn/apollo-backend), you can set the URL under **Settings > Custom API > Notification Backend** and the tweak will route all `apollopushserver.xyz`, `beta.apollonotifications.com`, and `apolloreq.com` traffic to that host instead. Leave the field empty to keep the current "silently dropped" behavior.

Notifications can be delivered two ways — pick the one that matches your Apple account:

- **Native push (APNs) — requires a paid Apple Developer account ($99/year).** Real APNs delivery needs an `aps-environment` entitlement, which Apple only grants to paid teams, plus an explicit App ID with Push Notifications enabled (not the wildcard profile most sideloading tools create). This path supports everything, including Live Activities. Follow the backend's [Getting Started guide](https://github.com/Apollo-Reborn/apollo-backend/blob/main/GETTING_STARTED.md).
- **Bark — free, no Apple Developer account.** Enable **Bark Delivery** under the same Notification Backend settings and notifications are relayed through the free [Bark](https://apps.apple.com/us/app/bark-custom-notifications/id1403753865) App Store app instead of APNs. This is the path for free-Apple-ID sideloads, which can never receive APNs pushes. Apollo's native notification and watcher UI works unmodified, taps deep-link back into Apollo, and Apollo's icons and notification sounds carry over. Follow the backend's [Bark Getting Started guide](https://github.com/Apollo-Reborn/apollo-backend/blob/main/GETTING_STARTED_BARK.md). Trade-offs: Live Activities remain APNs-only, and notification content transits the Bark relay (self-host `bark-server` — bundled with the backend — to keep it off Bark's hosted `api.day.app`).

> [!IMPORTANT]
> A free-account sideload has no push entitlement, so native APNs pushes can never arrive on it no matter how the backend is configured — **Bark is the supported path there** (the tweak detects the missing entitlement and explains this in the Notifications settings). Paid-certificate installs can use either delivery method and switch between them in place.

## Known Issues

- Long-tapping share links open in the in-app browser

## Opening links in Apollo

There are a few ways to open Reddit links in Apollo, depending on your browser and which IPA variant you installed.

### Safari — built-in extension (zero setup)

Apollo's bundled **"Open in Apollo"** Safari extension now works again on sideloaded builds (it previously got stranded on an `openinapollo.com` interstitial). Enable it under **Settings > Safari > Extensions > Open in Apollo**, allow it on `reddit.com`, and Reddit links will open straight in Apollo. Available on the **standard** and **Liquid Glass** IPA variants (the extension is removed from the *no-extensions* variants).

### Safari — userscript (works with any variant)

If you installed a **no-extensions** variant, or you're on a jailbreak/`.deb` install, use the app-independent userscript instead:

1. Install the free [**Userscripts**](https://apps.apple.com/app/userscripts/id1463298887) app (a Safari extension) and enable it for `reddit.com` in **Settings > Safari > Extensions**.
2. Open [`userscript/open-in-apollo.user.js`](userscript/open-in-apollo.user.js) in Safari, tap the **aA** menu → **Userscripts**, and install it.

It auto-redirects Reddit pages to Apollo and rewrites Reddit links on Google/Bing/DuckDuckGo results. (Search-result rewriting is inspired by [AnthonyGress's userscript](https://github.com/AnthonyGress/Open-In-Apollo), which also works.)

### Any other browser (Chrome, Firefox, Edge, Brave) — share sheet

Apollo's bundled **"Open in Apollo"** share-sheet action is fixed in this build and works from **any** browser: on a Reddit page tap **Share → Open in Apollo** and it opens straight in Apollo. (This was previously believed impossible — the stock action called the deprecated `-[UIApplication openURL:]` that iOS 18+ force-fails — but it now opens the link via a non-deprecated path.) Available on the **standard** and **Liquid Glass** variants.

> ⚠️ **Depends on how you install.** The action runs inside an app extension, which on **iOS 26** only launches if your installer sets the appex's *main-binary* code-signing flag. **AltStore and SideStore do this** (confirmed), as do Xcode and Apple's `codesign` (`scripts/resign-ipa-codesign.sh` re-signs an IPA this way for direct `ideviceinstaller`/Configurator install). **Sideloadly and Feather currently do not** — with them the extension is killed at launch and the action silently does nothing. If you installed with one of those, use the **Shortcut** below; it's signer-independent.

#### Fallback — "Open in Apollo" Shortcut (works on any install)

A one-time **Shortcut** does the same thing from the share sheet on any browser. It rewrites the `reddit.com` URL to Apollo's `apollo://` scheme and runs **Open URLs** — the one launch path iOS always allows from the share sheet (no private APIs; works on any sideload or jailbreak).

<details>
<summary><b>Build the "Open in Apollo" shortcut</b> (about a minute)</summary>

In the **Shortcuts** app, create a shortcut named **Open in Apollo** with these actions, in order:

1. **Get URLs from Shortcut Input** — coerces the shared link/web page into a URL.
2. **Replace Text** — Find `^https?://([a-z0-9-]+\.)*reddit\.com`, Replace `apollo://reddit.com`, **Regular Expression: On**, input = the URLs from step 1.
3. *(optional, for `redd.it` links)* **Replace Text** — Find `^https?://([a-z0-9-]+\.)*redd\.it`, Replace `apollo://redd.it`, **Regular Expression: On**, input = the Updated Text from step 2.
4. **Open URLs** — input = the Updated Text from the last Replace Text.

Then in the shortcut's settings (ⓘ) turn on **Show in Share Sheet** and, under **Share Sheet Types**, leave only **URLs** enabled.

Only the scheme + host are rewritten, so the full path/query is preserved — comment permalinks, profiles, and `/s/` share links all open correctly (the same `apollo://reddit.com/<path>` form the Safari extension and userscript produce). To share it with others, open the shortcut → **Share → Copy iCloud Link**.
</details>

Then, in any browser, on a Reddit page tap **Share → Open in Apollo**.

## Custom Redirect URI

> [!NOTE]
> Starting with Apollo Reborn v3.1.0, patching the `Info.plist` is no longer required to use a custom redirect URI. This section will remain for older versions, but if you're on v3.1.0 or later you can just enter your custom redirect URI in the tweak settings and it will work without any additional patching.

The redirect URI scheme (the part before `://`) must be registered in the Apollo IPA's `Info.plist` under `CFBundleURLTypes`, otherwise the OAuth callback won't return to Apollo. Add your scheme with [`patch.sh`](#patching-ipa) or the **Build IPA** GitHub Action:

```bash
./patch.sh Apollo.ipa --url-schemes custom
```

Resulting `Info.plist` entry:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>twitterkit-xyz</string>
      <string>apollo</string>
      <string>custom</string> <!-- enables custom://reddit-oauth -->
    </array>
  </dict>
</array>
```

## Patching IPA

`patch.sh` and the **Build IPA** GitHub Action apply optional patches to a stock Apollo IPA. By default they do **not** inject the tweak (the Action has an `inject_tweak` toggle for that) - locally use [Sideloadly](#sideloadly) or [`build-ipa.sh`](#build-injected-ipa-locally) to inject.

```bash
./patch.sh <path_to_ipa> [--liquid-glass | --liquid-glass-icons] [--url-schemes <schemes>] [--remove-code-signature] [-o <output>]
```

Available patches:

- **`--liquid-glass`** - enables the iOS 26 Liquid Glass UI and installs a pack of Liquid Glass icons that can be switched between in the tweak's in-app icon picker.
- **`--liquid-glass-icons`** - installs the Liquid Glass icon catalog **only**, without the iOS 26 UI chrome (skips the `vtool` build-version bump that opts the app into the iOS 26 runtime, so legacy UIKit behaviors like the bottom-tab swipe gesture are preserved). Mutually exclusive with `--liquid-glass`.
- **`--url-schemes <list>`** - adds comma-separated URL schemes to `CFBundleURLTypes` (see [Custom Redirect URI](#custom-redirect-uri), obsolete on v3.1.0+).
- **`--remove-code-signature`** - strips the existing code signature.

To run via GitHub Actions, fork this repo and trigger **Actions** > **Build IPA**. It can inject the tweak (`inject_tweak`), strip extensions (`no_extensions`), apply Liquid Glass (`liquid_glass`) or Liquid Glass icons only (`liquid_glass_icons`), add URL schemes, and remove the code signature in one run, from an Apollo IPA URL.

## Sideloadly

Recommended configuration:

- **Use automatic bundle ID**: unchecked — pick a bundle ID that doesn't contain "Apollo" (e.g. `com.foo.bar`, see [Avoiding API key revocations](#avoiding-api-key-revocations))
- **Signing Mode**: Apple ID Sideload
- **Inject dylibs/frameworks**: checked - add the `.deb` via **+dylib/deb/bundle**
  - **Cydia Substrate**: checked
  - **Substitute** / **Sideload Spoofer**: unchecked

## Build Injected IPA Locally

`build-ipa.sh` builds the tweak `.deb` and injects it into an Apollo IPA. For this repo's already-injected `Apollo-base.ipa`, it uses the repo-local `scripts/inject-deb-local.sh` replacement injector first, so `azule`/`cyan` are not required for normal test builds. For a truly stock IPA without the injection scaffold, install `azule` or `cyan`; signing/sideloading is still handled by your preferred signer.

```bash
make package
./build-ipa.sh --ipa ./Apollo.ipa [--deb ./packages/<tweak>.deb] [-o ./packages/Apollo-Tweaked.ipa]
```

## Distribution

For the in-house four-variant IPA release flow, AltStore Classic/SideStore/Feather source generation, and the meaning of the “No Extensions” builds, see [DISTRIBUTION.md](DISTRIBUTION.md). Apollo-Reborn is intended for AltStore Classic, not AltStore PAL.

## Build

**Requirements:**
- [Theos](https://github.com/theos/theos)

**Instructions:**
1. `git clone https://github.com/Apollo-Reborn/Apollo-Reborn`
2. `cd Apollo-Reborn`
3. `git submodule update --init --recursive`
4. `make package` or `make package THEOS_PACKAGE_SCHEME=rootless` for rootless variant

## Contributors ✨

Thank you to these wonderful people:

<!-- CONTRIBUTORS-LIST:START - Generated by .agents/skills/update-contributors/generate-readme-contributors.py -->

### Code Contributors

<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/JeffreyCA"><img src="https://avatars.githubusercontent.com/u/9157833?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="JeffreyCA"/></a><br /><sub><b>JeffreyCA</b></sub><br /><a href="#maintainer-JeffreyCA" title="Maintainer">Maintainer</a><br /><a href="https://buymeacoffee.com/jeffreyca" title="Buy Me a Coffee">☕</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/icpryde"><img src="https://avatars.githubusercontent.com/u/29389746?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="icpryde"/></a><br /><sub><b>icpryde</b></sub><br /><a href="#maintainer-icpryde" title="Maintainer">Maintainer</a><br /><a href="https://buymeacoffee.com/icpryde" title="Buy Me a Coffee">☕</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/jordanearle"><img src="https://avatars.githubusercontent.com/u/1413231?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="jordanearle"/></a><br /><sub><b>jordanearle</b></sub><br /><a href="#maintainer-jordanearle" title="Maintainer">Maintainer</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/nickclyde"><img src="https://avatars.githubusercontent.com/u/9121162?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="nickclyde"/></a><br /><sub><b>nickclyde</b></sub><br /><a href="#maintainer-nickclyde" title="Maintainer">Maintainer</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/DeltAndy123"><img src="https://avatars.githubusercontent.com/u/105518328?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="DeltAndy123"/></a><br /><sub><b>DeltAndy123</b></sub><br /><a href="#maintainer-DeltAndy123" title="Maintainer">Maintainer</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/EthanArbuckle"><img src="https://avatars.githubusercontent.com/u/4250718?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="EthanArbuckle"/></a><br /><sub><b>EthanArbuckle</b></sub><br /><a href="https://github.com/Apollo-Reborn/Apollo-Reborn/commits?author=EthanArbuckle" title="Code">Code</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/iCrazeiOS"><img src="https://avatars.githubusercontent.com/u/39101269?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="iCrazeiOS"/></a><br /><sub><b>iCrazeiOS</b></sub><br /><a href="https://github.com/Apollo-Reborn/Apollo-Reborn/commits?author=iCrazeiOS" title="Code">Code</a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/hllvc"><img src="https://avatars.githubusercontent.com/u/10849058?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="hllvc"/></a><br /><sub><b>hllvc</b></sub><br /><a href="https://github.com/Apollo-Reborn/Apollo-Reborn/commits?author=hllvc" title="Code">Code</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/yodaluca23"><img src="https://avatars.githubusercontent.com/u/67206487?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="yodaluca23"/></a><br /><sub><b>yodaluca23</b></sub><br /><a href="https://github.com/Apollo-Reborn/Apollo-Reborn/commits?author=yodaluca23" title="Code">Code</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/ep0chzero"><img src="https://avatars.githubusercontent.com/u/79633135?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="ep0chzero"/></a><br /><sub><b>ep0chzero</b></sub><br /><a href="https://github.com/Apollo-Reborn/Apollo-Reborn/commits?author=ep0chzero" title="Code">Code</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/mmshivesh"><img src="https://avatars.githubusercontent.com/u/23611514?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="mmshivesh"/></a><br /><sub><b>mmshivesh</b></sub><br /><a href="https://github.com/Apollo-Reborn/Apollo-Reborn/commits?author=mmshivesh" title="Code">Code</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/Uranosphaerite"><img src="https://avatars.githubusercontent.com/u/258388038?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="Uranosphaerite"/></a><br /><sub><b>Uranosphaerite</b></sub><br /><a href="https://github.com/Apollo-Reborn/Apollo-Reborn/commits?author=Uranosphaerite" title="Code">Code</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/wdeezy"><img src="https://avatars.githubusercontent.com/u/188708293?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="wdeezy"/></a><br /><sub><b>wdeezy</b></sub><br /><a href="https://github.com/Apollo-Reborn/Apollo-Reborn/commits?author=wdeezy" title="Code">Code</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/ryannair05"><img src="https://avatars.githubusercontent.com/u/23365226?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="ryannair05"/></a><br /><sub><b>ryannair05</b></sub><br /><a href="https://github.com/Apollo-Reborn/Apollo-Reborn/commits?author=ryannair05" title="Code">Code</a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/ichitaso"><img src="https://avatars.githubusercontent.com/u/980215?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="ichitaso"/></a><br /><sub><b>ichitaso</b></sub><br /><a href="https://github.com/Apollo-Reborn/Apollo-Reborn/commits?author=ichitaso" title="Code">Code</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/epheterson"><img src="https://avatars.githubusercontent.com/u/151483?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="epheterson"/></a><br /><sub><b>epheterson</b></sub><br /><a href="https://github.com/Apollo-Reborn/Apollo-Reborn/commits?author=epheterson" title="Code">Code</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/nunoo"><img src="https://avatars.githubusercontent.com/u/50464167?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="nunoo"/></a><br /><sub><b>nunoo</b></sub><br /><a href="https://github.com/Apollo-Reborn/Apollo-Reborn/commits?author=nunoo" title="Code">Code</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/lampemw"><img src="https://avatars.githubusercontent.com/u/6135609?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="lampemw"/></a><br /><sub><b>lampemw</b></sub><br /><a href="https://github.com/Apollo-Reborn/Apollo-Reborn/commits?author=lampemw" title="Code">Code</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/rebelancap"><img src="https://avatars.githubusercontent.com/u/7285817?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="rebelancap"/></a><br /><sub><b>rebelancap</b></sub><br /><a href="https://github.com/Apollo-Reborn/Apollo-Reborn/commits?author=rebelancap" title="Code">Code</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/nackerr"><img src="https://avatars.githubusercontent.com/u/25311402?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="nackerr"/></a><br /><sub><b>nackerr</b></sub><br /><a href="https://github.com/Apollo-Reborn/Apollo-Reborn/commits?author=nackerr" title="Code">Code</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/Alstruit"><img src="https://avatars.githubusercontent.com/u/34786806?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="Alstruit"/></a><br /><sub><b>Alstruit</b></sub><br /><a href="https://github.com/Apollo-Reborn/Apollo-Reborn/commits?author=Alstruit" title="Code">Code</a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/federgilad"><img src="https://avatars.githubusercontent.com/u/38831140?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="federgilad"/></a><br /><sub><b>federgilad</b></sub><br /><a href="https://github.com/Apollo-Reborn/Apollo-Reborn/commits?author=federgilad" title="Code">Code</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/ostechgit"><img src="https://avatars.githubusercontent.com/u/50818622?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="ostechgit"/></a><br /><sub><b>ostechgit</b></sub><br /><a href="https://github.com/Apollo-Reborn/Apollo-Reborn/commits?author=ostechgit" title="Code">Code</a></td>
    </tr>
  </tbody>
</table>

### Icon & Design Contributors

<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/iGerman00"><img src="https://avatars.githubusercontent.com/u/36676880?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="iGerman00"/></a><br /><sub><b>iGerman00</b></sub><br /><a href="https://github.com/Apollo-Reborn/Apollo-Reborn/tree/main/liquid-glass#bundled-icons" title="Icon and design">Design</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/jryng"><img src="https://avatars.githubusercontent.com/u/16271550?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="jryng"/></a><br /><sub><b>jryng</b></sub><br /><a href="https://github.com/Apollo-Reborn/Apollo-Reborn/tree/main/liquid-glass#bundled-icons" title="Icon and design">Design</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/bajader"><img src="https://avatars.githubusercontent.com/u/98495831?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="bajader"/></a><br /><sub><b>bajader</b></sub><br /><a href="https://github.com/Apollo-Reborn/Apollo-Reborn/tree/main/liquid-glass#bundled-icons" title="Icon and design">Design</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/metalnakls"><img src="https://avatars.githubusercontent.com/u/15786688?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="metalnakls"/></a><br /><sub><b>metalnakls</b></sub><br /><a href="https://github.com/Apollo-Reborn/Apollo-Reborn/tree/main/liquid-glass#bundled-icons" title="Icon and design">Design</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/paulo1manso"><img src="https://avatars.githubusercontent.com/u/77062284?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="paulo1manso"/></a><br /><sub><b>paulo1manso</b></sub><br /><a href="https://github.com/Apollo-Reborn/Apollo-Reborn/tree/main/liquid-glass#bundled-icons" title="Icon and design">Design</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/lilacvibes"><img src="https://avatars.githubusercontent.com/u/61892971?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="lilacvibes"/></a><br /><sub><b>lilacvibes</b></sub><br /><a href="https://github.com/Apollo-Reborn/Apollo-Reborn/tree/main/liquid-glass#bundled-icons" title="Icon and design">Design</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/harshb16"><img src="https://avatars.githubusercontent.com/u/49092079?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="harshb16"/></a><br /><sub><b>harshb16</b></sub><br /><a href="https://github.com/Apollo-Reborn/Apollo-Reborn/tree/main/liquid-glass#bundled-icons" title="Icon and design">Design</a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/IllIIllIllIllII"><img src="https://avatars.githubusercontent.com/u/132845378?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="IllIIllIllIllII"/></a><br /><sub><b>IllIIllIllIllII</b></sub><br /><a href="https://github.com/Apollo-Reborn/Apollo-Reborn/tree/main/liquid-glass#bundled-icons" title="Icon and design">Design</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://www.reddit.com/user/harunatsu91202024/"><img src="https://i.redd.it/snoovatar/avatars/ef90ed21-4a24-4a78-b535-848d4efc6378.png?s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="harumatsu"/></a><br /><sub><b>harumatsu</b></sub><br /><a href="https://github.com/Apollo-Reborn/Apollo-Reborn/tree/main/liquid-glass#bundled-icons" title="Icon and design">Design</a></td>
    </tr>
  </tbody>
</table>

<!-- CONTRIBUTORS-LIST:END -->
