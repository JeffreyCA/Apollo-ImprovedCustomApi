# Per-Account Favorites Validation

Run the Foundation-only regression harness on macOS:

```sh
sh tests/run_per_account_favorites_tests.sh
```

The harness compiles the production favorites state machine, mocks account
identity, and uses isolated preferences. It covers the queued-refresh race and
genuine edits, but does not exercise Apollo's runtime hooks or visible UI.

Before device testing, export a settings backup. Use at least two accounts with
distinct subscriptions. The setting is under Apollo Reborn > Subreddits >
Favorites > Per-Account Favorites.

- With the setting off (the default), confirm favorites remain shared across
  accounts and normal favorite/unfavorite/reorder actions still work.
- Enable it for the first time. Confirm every existing account begins with the
  previous shared favorites in the same order.
- Give accounts A and B different favorites and different favorite orders. Use
  quick switching repeatedly in both directions; confirm favorites refresh
  immediately and the Account tab, subscriptions, and selected account agree.
- Switch using the full account picker too. Drag inactive account B to another
  position while A is active; confirm this does not change the active account,
  subscriptions, or favorites. This checks the account-switcher fix inherited
  from main, not an additional favorites patch.
- Add a new account after opting in; confirm its favorites start empty without
  changing existing accounts. Check the logged-out list separately, then sign
  back in and confirm each saved list is intact.
- Disable the setting. Confirm the original shared list returns. Edit that list
  while off, re-enable, and confirm the saved per-account lists return. Disable
  again and confirm the shared edits made while off remain intact.
- Relaunch with the setting on and then off; confirm the setting, favorites,
  and favorite ordering persist in each mode.
- Export and restore a settings backup with distinct account/shared lists.
  After the required relaunch, verify the toggle and every saved list. Also
  check that a backup without per-account data keeps the default shared mode.
- Repeat the switching and toggle checks in the Liquid Glass device IPA that
  will be used for acceptance testing; verify both visible favorites surfaces
  and the native account state rather than only the Account tab label.
