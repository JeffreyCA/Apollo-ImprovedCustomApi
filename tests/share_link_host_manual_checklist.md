# Share Link Host Manual Validation
Manual validation steps for the Share Link Host feature.

## Settings

- Open **Settings → Features → Media → Sharing**.
- Confirm **Share Link Host** appears in the Sharing section.
- Confirm the current selection matches the selected picker option.
- Change the host, leave the screen, return, and confirm the selection persists.

## Reddit

- Select **Reddit**.
- Use **Copy Link** on a Reddit post and confirm the copied URL uses `reddit.com`.
- Share the post to Messages and confirm the shared URL uses `reddit.com`.
- Share as Image with **Include Link** enabled and confirm the included URL uses `reddit.com`.

## old.reddit

- Select **old.reddit**.
- Use **Copy Link** and confirm the copied URL uses `old.reddit.com`.
- Share the post to Messages and confirm the shared URL uses `old.reddit.com`.
- Share as Image with **Include Link** enabled and confirm the included URL uses `old.reddit.com`.

## vxReddit

- Select **vxReddit**.
- Use **Copy Link** and confirm the copied URL uses `vxreddit.com`.
- Share the post to Messages, Discord, and Telegram and confirm the shared URL uses `vxreddit.com`.
- Wait briefly for rich-preview metadata to load where supported.
- Share as Image with **Include Link** enabled and confirm the included URL uses `vxreddit.com`.
- Wait briefly for link previews to load before sending when testing Messages.

## fxReddit (fxddit.com)

- Select **fxReddit (fxddit.com)**.
- Use **Copy Link** and confirm the copied URL uses `fxddit.com`.
- Share the post to Messages, Discord, and Telegram and confirm the shared URL uses `fxddit.com`.
- Wait briefly for rich-preview metadata to load where supported.
- Share as Image with **Include Link** enabled and confirm the included URL uses `fxddit.com`.
- Wait briefly for link previews to load before sending when testing Messages.

## URL Preservation

- Confirm the subreddit, post ID, title slug, and comment path remain unchanged.
- Confirm query parameters remain unchanged.
- Confirm URL fragments remain unchanged.
- Confirm only the hostname changes for supported Reddit URLs.

## Unsupported URLs

- Confirm `redd.it` short links remain unchanged.
- Confirm `i.redd.it`, `v.redd.it`, `preview.redd.it`, and other media hosts remain unchanged.
- Confirm unrelated external URLs remain unchanged.

## Share as Image

- Enable **Include Link** and confirm the selected Share Link Host is used.
- Disable **Include Link** and confirm no Reddit link is attached.
- Confirm no duplicate link is added when another share path already supplies one.

## Copy Link

- Confirm Apollo's custom **Copy Link** activity copies the selected host.
- Confirm Copy Link does not fall back to `reddit.com`.
- Re-test Copy Link whenever the share-sheet or activity-item handling code changes.

## Regression

- Confirm standard sharing still works.
- Confirm image-only activities remain image-only.
- Confirm the app does not crash when opening or dismissing the share sheet.
- Confirm changing Share Link Host does not affect Media Upload Host or Comment Link Host.
