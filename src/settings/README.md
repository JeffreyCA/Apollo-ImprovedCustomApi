# src/settings/ — tweak settings screens and native-settings integration

Everything settings-related lives here. Two distinct layers — pick the right one for the table you're touching:

| You're changing… | Use | Never |
|---|---|---|
| A **tweak-owned** screen (Apollo Reborn root, Deleted Comments, Translation, …) | `ApolloSettingsForm` — declare rows in `-buildForm` | Hand-roll `numberOfRows`/`cellForRow` switches or index arithmetic |
| Apollo's **native** Settings > General screen (a Eureka form we don't own) | `ApolloSettingsGeneralTable` — register a hide matcher or row injection in your `%ctor` | `%hook` that screen's table delegate/dataSource methods (two remappers desync index spaces — the PR #570 bug class) |

Other native screens have their own single owners: the Settings root and About injections live in `src/settings/ApolloSettings.xm`, the Filters screen in `src/ApolloFiltersBlocksInject.xm`. One remapper per screen, always.

## Adding a new tweak setting (the 5-step recipe)

1. **Key** — `UDKey*` constant in `src/UserDefaultConstants.h`, with a comment saying what it does and its default.
2. **Global** — `s*` BOOL/NSInteger in `src/ApolloState.{h,m}` (the header's `extern "C"` block; .xm consumers are ObjC++).
3. **Default + load** — register the default in `Tweak.xm`'s `registerDefaults` dictionary and read it into the global in the same `%ctor` block as its neighbors. Prefer `@YES` there over inverted-key tricks for default-on.
4. **Row** — add an `ApolloSettingsRow` to the right screen's `-buildForm`. For a plain toggle that's 5 lines (see any converted screen). Conditional row? Set `.visible` and call `[self visibilityDidChange]` from whatever toggle drives it — never compute indices.
5. **Consume** — read the `s*` global from your feature module.

Do **not** add the setting to `ApolloBackupRestore.m`'s statics re-sync block: settings ride `standardUserDefaults`, so they're in Backup/Restore for free, and restore always force-exits (`exit(0)`) so `%ctor` re-reads everything on relaunch. The re-sync list is intentionally partial.

## ApolloSettingsForm quick reference

Full API docs in `ApolloSettingsForm.h`. The load-bearing rules:

- **Indices are derived, never computed.** The dataSource serves a visibility snapshot; `visible` blocks are only evaluated at load and inside `visibilityDidChange` (which diffs and animates the insert/delete for you). Refer to rows by identity: `reloadRowWithID:`, `cellForRowID:` (also your popover `sourceView` anchor), `indexPathForRowID:`.
- **Row kinds**: `switchRow` (isOn/onToggle blocks, optional `.enabled`), `valueRow` (detail block; Value1), `disclosureRow` (push block), `buttonRow` (accent action text), `customRow` (escape hatch — the block owns the cell). Blocks are retained by the VC via the row model — capture `weakSelf`, not `self`, or you leak the screen.
- **`ApolloSettingsPresentPicker`** replaces the hand-rolled "(Current)" action sheets. It fires `apply` on ANY pick **including re-picking the current option** (legacy sheet semantics some handlers rely on) — apply blocks must be idempotent. Sheets needing a message body or extra actions stay bespoke; anchor them to `cellForRowID:`.
- **Dynamic row lists** (rows generated per data item inside `buildForm`, like Translation's skip-languages): refresh with `rebuildSectionContainingRowID:withRowAnimation:`, not `rebuildForm` — a full `reloadData` reconfigures every section's cells and clobbers in-progress text-field edits elsewhere on the screen.
- **When to reach for `customRow`**: bespoke cells (preview cards, status subtitles, centered labels), text-field rows (keep the tag-based `UITextFieldDelegate` machinery — it's index-immune by design), and anything whose color must NOT be the accent (e.g. destructive red — `buttonRow` tags the cell for accent action text).
- **Theming is automatic** via the `ApolloSettingsTableViewController` base (accent walk in `willDisplayCell`); don't hand-tint.
- **Testing**: no automated tests. When touching conditional rows, manually exercise the full flag matrix in the sim (`scripts/run-in-sim.sh`) with the section ON SCREEN while toggling — the insert/delete path, not just relaunch.

## Native Settings > General (Eureka) facts

Apollo's native settings screens are Eureka `FormViewController`s (Eureka ~5.5, an embedded framework in the IPA).

RE facts that make `ApolloSettingsGeneralTable`'s NSProxy approach safe (full verification notes in `ApolloSettingsGeneralTable.xm`'s header — re-check them on any base-IPA bump):

- Eureka indexes `form[indexPath.section][indexPath.row]` with **no bounds guard** — any unmapped index path reaching it is an `NSRangeException`. That's why exactly one owner may remap that screen's index space.
- Eureka touches the table's `delegate`/`dataSource` only in `viewDidLoad`'s nil-guards, never reads them back for dispatch, and never casts them; cells find their VC by walking the **responder chain**, and `form.delegate` is Eureka's own Form→VC link. That's what makes delegate interposition safe.
- The General form is built exactly once per VC instance (its hidden-conditions use empty tag arrays — evaluated once, no observers), so a single viewDidLoad scan is sound.
- Eureka caches each row's value on its Row object. Writing a defaults key under a live SwitchRow does **not** update it — flip the visible `UISwitch` and `sendActionsForControlEvents:UIControlEventValueChanged` so Eureka processes a real value change (the "cross-flip stops working" lesson from PR #570; see `PPCSTurnNativeRememberSubredditSortOff`).
- Rows have no stable tags; match by trimmed title via `ApolloGeneralTableCellHasTitle` (handles custom-label cells). Anchors are fail-soft: no match → the native screen is left untouched.
