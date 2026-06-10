# Deleted Comments Manual Validation

- Open a comments thread with visible `[deleted]` or `[removed]` comments and confirm recovered bodies render with a red recovery badge.
- Open a comments thread where removed replies are hidden behind "more replies" and confirm recoverable deleted children appear inline.
- With Arctic Shift slow or blocked, confirm the thread still shows Apollo's normal comments after the short timeout instead of waiting 10-20 seconds.
- Reload the same recovered thread and confirm cached archive data is reused without another visible loading penalty.
- Trigger "load more comments" on a thread with deleted replies and confirm recovery still works without delaying the full thread.
- Toggle "Show Deleted Comments" off, reload the same thread, and confirm Apollo returns to its native deleted/removed output.
- Confirm normal user flair and moderator flair do not receive the recovered-comment red badge styling.
