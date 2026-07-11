# LinkHop — Universal Link bounce app for seamless Reddit → Apollo opens

A tiny, **generic** App Store app that makes tapping a reddit.com link open
Apollo-Reborn with **zero confirmation dialogs**. This directory is
self-contained and designed to be extracted into its own repository
(`git filter-repo` / `git subtree split`, or just copy it out).

## Why this app exists

iOS shows a mandatory "Open in 'Apollo'?" dialog for **any** custom-scheme
(`apollo://`) navigation that originates from web content — the Safari
extension's redirect included. No code trick suppresses it; it's OS policy.

Two launch paths are exempt from that dialog:

1. **Universal Links** — an HTTPS link to a domain whose
   `apple-app-site-association` (AASA) file lists the app. Resolves silently.
2. **App-to-app scheme opens** — an app calling `UIApplication.open()` on
   another app's scheme.

Apollo-Reborn itself can never use Universal Links: sideloading re-signs the
app with a **different Team ID per user**, and AASA files require exact
`TeamID.BundleID` entries. But *this* app is published once, through the App
Store, with one fixed identity — so it can claim the bounce domain, and then
hand off to whatever Apollo-Reborn build is installed via path 2.

### The end-to-end flow (Reddit app must NOT be installed)

```
tap reddit.com link
  → Safari starts loading reddit.com
  → Apollo-Reborn's Safari extension redirects to https://open.apolloreborn.app/<path>
  → iOS resolves that as a Universal Link → launches LinkHop silently
  → LinkHop rewrites the path to apollo://reddit.com/<path> and opens it (silent)
  → Apollo opens on the right post/subreddit
```

If the official Reddit app is installed, iOS routes reddit.com taps to it
before Safari ever loads the page — nothing downstream (extension, this app)
gets a chance to run. That's Reddit's Universal Link claim on its own domain
and is not circumventable.

## App Review strategy (read before submitting)

Researched against the current [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/):

- **4.2 Minimum Functionality / 4.2.3(i)** — *"Your app should work on its own
  without requiring installation of another app to function."* This is the
  guideline that kills naive "bounce and die" apps. LinkHop is built as a
  generic link router to clear it:
  - A standalone **paste-a-link → open in app** tool with multiple built-in,
    toggleable rules (Reddit/Apollo, YouTube, Spotify) and a recents list.
  - When a target app isn't installed (which is how a reviewer will test it),
    the open **falls back to a chooser** — open in browser / copy link — so
    the app is never a dead end and never *requires* Apollo.
  - The Worker likewise 302s browsers back to reddit.com, so bounce links work
    for people without the app.
  - Precedent: this is an established App Store genre —
    [Opener](https://apps.apple.com/us/app/opener-open-links-in-apps/id989565871)
    (since ~2015) and
    [Link Opener](https://apps.apple.com/us/app/link-opener-save-all-urls/id6459935966)
    do exactly this.
- **4.1 Copycats / 5.2.1 Intellectual Property / 2.3.7 Metadata** — keep
  **"Apollo"**, **"Reddit"**, and their icons/branding **out of** the app
  name, icon, subtitle, keywords, and screenshots' framing. Factual in-app
  references to app names in routing rules are what Opener does and is fine.
  Rename "LinkHop" if the name is taken on App Store Connect; pick any neutral
  name. Consider a bundle ID that doesn't contain "apollo" (the placeholder is
  `com.example.linkhop` — change it).
- **If rejected under 4.2 anyway**: respond in Resolution Center pointing at
  the standalone utility + the Opener precedent; if that fails, add more
  standalone value (a Share-sheet extension, more built-in services, an
  in-app browser choice) and resubmit. Review outcomes in this genre are
  somewhat reviewer-dependent — budget for one rejection cycle.

## Building

```bash
brew install xcodegen
cd router-app
xcodegen                     # generates LinkHop.xcodeproj
open LinkHop.xcodeproj
```

Then in Xcode: set your team on the LinkHop target, change
`PRODUCT_BUNDLE_IDENTIFIER`, and make sure the Associated Domains capability
shows `applinks:open.apolloreborn.app` (from `Config/LinkHop.entitlements`).
Associated Domains requires a **paid** Apple Developer account.

## Server setup (one small Cloudflare Worker)

`aasa/worker.js` is the entire backend — deploy it with a route for
`open.apolloreborn.app/*` (same pattern as the existing
`beat.apolloreborn.app` Worker). It serves the AASA file and 302s human
visitors back to reddit.com. **Replace `TEAMID.com.example.linkhop`** in the
Worker (and `aasa/apple-app-site-association`, kept as the canonical copy)
with the real identity after enrolling.

Verify the AASA with:

```bash
curl -s https://open.apolloreborn.app/.well-known/apple-app-site-association | python3 -m json.tool
```

and check Apple's CDN view of it at
`https://app-site-association.cdn-apple.com/a/v1/open.apolloreborn.app`.
Apple's CDN caches for hours; devices refresh the AASA on app install/update,
so always test with a fresh install.

## Rollout order (deliberately not done yet in this repo)

1. Enroll in the Apple Developer Program; finalize name + bundle ID.
2. Deploy the Worker; verify the AASA from Apple's CDN endpoint.
3. Ship LinkHop through App Review.
4. **Only after it's live**: switch `safari-extension/content.js` and
   `userscript/open-in-apollo.user.js` from `apollo://…` to
   `https://open.apolloreborn.app/…`, ideally behind the extension popup's
   existing preference so users can pick "direct (dialog)" vs "bounce
   (seamless, needs LinkHop)". Flipping the redirect before the app is live
   would strand users on the Worker's reddit.com fallback redirect.

## Risks, honestly

- **App Review** may reject under 4.2 despite the mitigations (see above).
- **Single point of failure**: if the app is ever pulled or the domain lapses,
  bounce links degrade to the Worker's reddit.com redirect (or, with no
  Worker, break). The extension keeps working if its direct-`apollo://` mode
  remains available as a fallback preference — keep it.
- **Maintenance**: an App Store app is a permanent commitment (yearly fee,
  occasional SDK-requirement rebuilds, review on every update).
