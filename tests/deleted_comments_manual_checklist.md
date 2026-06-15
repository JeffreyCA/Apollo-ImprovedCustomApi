# Deleted Comments Manual Validation

- Open a comments thread with visible `[deleted]` or `[removed]` comments and confirm the normal comments render immediately.
- On a thread where Arctic responds quickly, confirm recovered deleted comments appear on the first render without leaving and reopening the thread.
- Confirm Arctic recovery starts in parallel with the Reddit comments request and first render waits no more than about 2 seconds for matching recovery data.
- Confirm visible deleted placeholders render with the translucent red cell highlight and a `REMOVED BY MOD` or `DELETED BY USER` chip before Arctic recovery finishes.
- If Arctic finishes shortly after the first render, confirm visible deleted placeholders upgrade in place to recovered comments without duplicating rows.
- Confirm long usernames do not crowd the recovered-comment reason chip.
- With "Tap to Show Deleted Comments" on, confirm unrecovered placeholders stay as stable reason chips and do not show `LOADING...`, `NOT AVAILABLE`, or native `SPOILER`.
- With "Tap to Show Deleted Comments" on, tap a recovered/cached deleted comment and confirm it toggles between the reason chip and recovered body without collapsing the whole comment.
- With "Tap to Show Deleted Comments" off, confirm recovered bodies are visible by default and still show the reason chip before the body.
- Open a comments thread where removed replies are hidden behind "more replies" and confirm recoverable deleted children appear only as part of Apollo's normal response or "more replies" response, not as a live list shift.
- With Arctic Shift slow or blocked, confirm the thread still shows Apollo's normal comments immediately instead of waiting 10-20 seconds.
- Reopen the same recovered thread and confirm cached archive data is reused without another visible loading penalty.
- Trigger "load more comments" on a thread with deleted replies and confirm recovery still works without delaying the full thread.
- Confirm background Arctic completion does not automatically expand or shift visible deleted placeholders.
- Confirm revealing recovered comments does not duplicate comments after scrolling, collapsing, or opening more replies.
- Confirm quote-block recovered comments hide and reveal correctly.
- Toggle "Show Deleted Comments" off, reload the same thread, and confirm Apollo returns to its native deleted/removed output.
- Confirm normal user flair and moderator flair remain unchanged.
