# Deleted Comments Manual Validation

- Open a comments thread with visible `[deleted]` or `[removed]` comments and confirm recovered bodies render with a translucent red cell highlight and a `REMOVED BY MOD` or `DELETED BY USER` chip.
- Confirm long usernames do not crowd the recovered-comment reason chip.
- With "Tap to Show Deleted Comments" on, confirm recovered bodies start hidden behind the reason chip and reveal after tapping the chip.
- With "Tap to Show Deleted Comments" off, confirm recovered bodies are visible by default and still show the reason chip before the body.
- Open a comments thread where removed replies are hidden behind "more replies" and confirm recoverable deleted children appear inline.
- With Arctic Shift slow or blocked, confirm the thread still shows Apollo's normal comments after the short timeout instead of waiting 10-20 seconds.
- Reload the same recovered thread and confirm cached archive data is reused without another visible loading penalty.
- Trigger "load more comments" on a thread with deleted replies and confirm recovery still works without delaying the full thread.
- Toggle "Show Deleted Comments" off, reload the same thread, and confirm Apollo returns to its native deleted/removed output.
- Confirm normal user flair and moderator flair remain unchanged.
