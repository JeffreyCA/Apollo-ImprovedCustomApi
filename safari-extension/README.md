# Safari extension overlays

These files convert Apollo's bundled `Apollofari.appex` into **Open in Apollo
(Manual Fallback)** and create a second `ApollofariLegacy.appex` named **Open in
Apollo (Legacy)**. They are applied at IPA-package time by
[`scripts/modules/fix-safari-extension.sh`](../scripts/modules/fix-safari-extension.sh).

Automatic Safari routing is intentionally owned by the extension embedded in
the separately installed Apollo Reborn Link Companion. That app has the stable
Apple signing identity listed by `open.apolloreborn.app`, reproducing original
Apollo's reliable topology: the extension initiating the navigation and the
app owning the Universal Link are targets in the same signed container.

Apollo itself may be signed by any sideloading service. The recommended bundled
extension therefore does not attempt automatic Universal Link navigation. This
avoids races with Link Companion while retaining a deterministic recovery path.

## Fallback behavior

- Runs only on `reddit.com`, its subdomains, and exact bare `redd.it`.
- Waits 750 ms before displaying a floating **Open in Apollo** anchor. A normal
  Companion handoff leaves the page before the button can flash onscreen.
- The anchor targets
  `https://open.apolloreborn.app/open?url=<encoded-reddit-url>`, retaining a
  real user gesture for the Universal Link.
- Updates the anchor when Reddit navigates as a single-page application.
- Never calls `window.stop()`, `location.replace()`/`assign()`, or synthetic
  click APIs; never rewrites page links; and performs no network requests.
- Requests neither All Websites access nor WebExtension storage permission.
- Rejects Reddit roots, host-suffix attacks, credentialed/custom-port URLs,
  media CDN hosts, malformed `redd.it` paths, and the Worker's one-shot
  fallback marker.

The popup has no toggle. It only explains that Link Companion owns automatic
opening and this extension is the manual recovery path.

## Legacy automatic behavior

The `legacy/` assets preserve the automatic Apollo-bundled approach that this
change replaces. That extension:

- Uses the same strict Reddit URL validation and Apollo Reborn Universal Link
  endpoint as the manual fallback.
- Redirects an eligible Reddit page automatically when its popup toggle is on.
- Retains the Worker's fallback-loop protection.
- Is packaged under the unique bundle identifier suffix
  `.ApollofariLegacy` and display name **Open in Apollo (Legacy)**.

Legacy is an opt-in alternative to **Open in Apollo (Companion)**. Users must
not enable both automatic extensions because they can compete for the same
navigation. **Open in Apollo (Manual Fallback)** is passive and safe to leave
enabled with either automatic choice.

## Packaging

Both overlays are applied automatically to extension-bearing release variants,
by the Build IPA workflow when extensions are retained, by
`patch.sh --fix-safari-extension`, and by the standalone
[`scripts/fix-safari-extension.sh`](../scripts/fix-safari-extension.sh). It is a
no-op for no-extensions variants.

Run the deterministic URL and content-script tests with:

```bash
node --test safari-extension/link-utils.test.js safari-extension/content.test.js safari-extension/legacy/content.test.js
```

The test suite executes the content script in a stub document and verifies that
the manual extension never navigates, the legacy extension does navigate when
enabled, both handle the Worker fallback marker, and both manifests remain
Reddit-only.
