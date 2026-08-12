# iPad Pane Layout PR #886 — Implementation and Verification Tracker

Reviewed branch: `je/ipad-pane-layout`  
Review baseline: `5f6ea269d14904d02817d4335ef2535e708b0d70`

This tracked file is the source of truth for taking the experimental iPad pane layout
from review findings to merge-ready behavior. Tasks are ordered by dependency,
not by the numbering in the review report.

## Completion rules

- `[ ]` — not started.
- `[~]` — implementation or verification is in progress.
- `[x]` — implementation is complete and its focused simulator scenario plus
  the standard pane smoke checks passed.
- `[!]` — implementation may be complete, but the task still requires a real
  device, OS version, external service, accessibility peripheral, or Instruments
  verification that the simulator cannot honestly provide.
- Every completed task records the tested commit, commands/scenario, evidence,
  and any remaining coverage limitation.
- A successful build alone is not enough to mark a behavioral task complete.
- After every task, re-run the standard pane smoke checks before moving on.

## Standard pane smoke checks

1. Build and launch with `scripts/run-in-sim.sh --glass --drive`.
2. Confirm `apollofix` logs show pane installation for all five tabs.
3. Open a Home post in detail; verify primary remains visible and usable.
4. Switch Home → Search → Inbox → Profile → Settings → Home.
5. Exercise Back in detail, then select a different primary item.
6. Exercise regular → compact → regular and confirm the visible destination,
   Back path, primary/detail ownership, and navigation-bar geometry.
7. Relaunch once without rebuilding and confirm pane/sidebar state is coherent.
8. Inspect the captured screenshot and recent `apollofix` logs for exceptions,
   UIKit hierarchy warnings, routing loops, or layout regressions.
9. Reset every simulator-only presentation override (including forced compact
   mode) and capture a final regular-width screenshot. A task is not complete
   while the shared simulator is still displaying a synthetic test state.

## Dependency-ordered implementation tasks

### Navigation foundations

- [x] **01 — Return the real primary and detail navigation controllers.**
  Replace direct-column class inference in the shared helpers with the pane's
  explicit column API, while preserving a generic UIKit fallback for unrelated
  split controllers. Audit AutoHideTabBar, Liquid Glass, User Avatars, and
  Direct Chat callers against the returned stacks.
  - Focused simulator test: populate detail; prove enumeration returns primary
    and the inner detail nav exactly once, never the wrapper; repeat collapsed.
  - Evidence: `navdump` returned exactly two controllers for every pane. Home's
    secondary was the inner Apollo nav with `[Apollo.CommentsViewController]`,
    parented by `ApolloPaneColumnHostViewController`; UIKit's wrapper was absent.
    The result remained correct through compact collapse and re-expansion. The
    stock iPhone layout still returned exactly one controller per tab.

- [x] **02 — Make compact navigation a coherent, escapable stack.**
  Preserve a native Back path from a root detail destination to its list when
  the split collapses, without exposing duplicate nested navigation bars.
  - Focused simulator test: open a root-only thread, collapse, use button Back,
    edge Back, VoiceOver escape equivalent where available, then expand.

- [x] **03 — Make visible-controller discovery match the actual compact column.**
  Return the populated detail controller when secondary survives collapse and
  the list controller otherwise; require an attached visible view where useful.
  - Focused simulator test: present alert/share-sheet probes from populated and
    empty compact panes and verify their presenter hierarchy.

- [x] **04 — Classify navigation performed while compact.**
  Preserve logical list/detail ownership through compact pushes and migrate it
  correctly when the window expands.
  - Focused simulator test: collapse empty → open post → expand; repeat with an
    existing detail stack and with Back/Forward history.
  - Evidence: on the worktree based on `5f6ea269`, an empty compact pane built
    `[RedditList, Posts, Comments]` in the one physical stack and expansion
    migrated the logical detail suffix to `[Comments]`, leaving
    `[RedditList, Posts]` in primary. Popping Comments before expansion left
    detail empty. Apollo's own Forward action re-pushed the popped Comments
    controller through the router and expansion again produced the correct two
    stacks. A detail populated before collapse survived secondary collapse and
    re-expansion unchanged. All five tab panes attached in regular width, a
    no-build relaunch restored regular two-column state, `git diff --check`
    passed, and `make package` produced
    `com.apollo.reborn_3.5.1-27+debug_iphoneos-arm.deb`.

- [!] **05 — Repair deep links, handoff, notification/Siri entry points, and
  cold-start stack normalization.**
  Update Apollo-facing hierarchy assumptions and classify stacks created before
  pane installation.
  - Simulator coverage: killed/warm universal links and debug route injection.
  - Device/external coverage: notification taps, handoff, Siri, restoration.
  - Evidence: the native AppDelegate URL route now sees a scoped compatibility
    hierarchy and routed a warm Reddit thread into detail without replacing the
    real split/tab hierarchy. A pre-install cold injection built Apollo's stock
    `[RedditList, Posts, Comments]` stack; pane construction normalized it to
    primary `[RedditList, Posts]` and detail `[Comments]`. Cold and warm
    `apollo://reborn/settings/theme-manager` routes selected Settings and put
    Theme Manager in its detail column. Native `Search` and
    `FavoriteSubreddit` UIApplication shortcuts completed successfully; Search
    selected tab 3 and focused through Apollo's indexed-child path, while the
    favourite route pushed Posts on the selected primary stack. The router now
    hooks ApolloNavigationController's actual ObjC push shim, and a weak owner
    map kept routing correct during the synchronous interval after an offscreen
    tab was selected but before UIKit reattached its containment tree. Compact
    URL routing expanded with Comments in detail, all five tabs switched and
    reattached, a clean relaunch ended in regular width with no forced compact
    override, and the final screenshot showed the normal two-column empty
    state. `git diff --check` passed and the device build produced
    `com.apollo.reborn_3.5.1-28+debug_iphoneos-arm.deb`.
  - Remaining gate: Xcode 27 did not deliver `simctl openurl` custom-scheme
    callbacks to the re-signed app, so deterministic simulator-only injections
    exercised the exact AppDelegate/SceneDelegate methods instead. Real APNs
    notification taps, cross-device Handoff, Siri intents, and UIKit state
    restoration still require their external/device environments.

- [x] **06 — Complete Inbox and remaining index/detail routing.**
  Route messages, author profiles, subreddit/rules destinations, and modern
  Inbox quick actions consistently using the rightward-only ownership rule.
  - Focused simulator test: each tab's index remains on the left while each
    classified destination opens on the right with correct Back behavior.
  - Evidence: the real signed-in Inbox opened with Boxes alone in primary and
    Inbox in detail. Selecting Messages replaced detail with its Inbox list;
    selecting a real thread produced `[InboxView, PrivateMessage]`, and the
    column-aware Back probe returned to Inbox without touching Boxes. Tapping
    that conversation's username appended Profile in detail. Independently,
    tapping a feed author replaced stale detail with Profile while preserving
    the complete RedditList/Posts/subreddit stack on the left. A real subreddit
    menu routed Sidebar to detail, Sidebar's Rules button appended Rules, Back
    returned to Sidebar, and the direct Rules menu route correctly replaced the
    detail root. Modern Chat and Modmail notification URLs each produced one
    `ApolloDirectChatWebViewController` in detail and kept InboxList primary;
    native Modmail with the modern preference off produced the native
    ModmailInbox detail instead. Native-Modmail normalization now happens before
    cross-column re-homing, removing the old source-order dependency between the
    pane and modern-mailbox hooks. A compact/regular cycle preserved populated
    Home and Inbox primary/detail stacks exactly. That cycle also exposed and
    fixed iPadOS truncating an empty-detail primary stack from
    `[RedditList, Posts]` to `[RedditList]`: collapse now transactionally restores
    only a strict prefix of the captured primary stack. The simulator ended in
    regular width. `git diff --check` passed and the device build produced
    `com.apollo.reborn_3.5.1-29+debug_iphoneos-arm.deb`.

### State, history, and transition safety

- [x] **07 — Centralize and preserve sidebar visibility ownership.**
  Prevent per-pane state from fighting the global tab sidebar; do not overwrite
  a user's persistent choice or strand an automatically hidden sidebar after
  relaunch. Reconsider whether automatic hiding should exist at all.
  - Focused simulator test: manual and automatic show/hide across all tabs,
    detail clear, rotation/compact transitions, termination, and relaunch.
  - Evidence: removed pane-driven auto-hide entirely. UIKit's one global
    `UITabBarControllerSidebar` is now the sole visibility owner; production has
    no `sidebar.hidden` writer and no per-pane ownership flags. This fixes the
    concrete failure where one populated tab hid the global sidebar, another
    pane could not restore it, and UIKit carried that stranded state into a
    later launch. Using UIKit's real `Toggle sidebar` control, the visible
    sidebar stayed visible while Comments filled detail, through all five tab
    selections, and across forced compact/regular transitions; navigation
    stacks were unchanged and logs contained no pane visibility writes. With
    the sidebar closed, classified detail routing and all tabs remained
    reachable through UIKit's floating tab bar. A no-build termination/relaunch
    restored UIKit's own closed-overlay state while the two content columns
    remained intact, confirming the tweak no longer forces or persists a
    competing preference. The simulator ended regular with no compact override.
    `git diff --check` passed and the device build produced
    `com.apollo.reborn_3.5.1-30+debug_iphoneos-arm.deb`.

- [x] **08 — Clear Apollo forward history when detail is replaced.**
  Invalidate `poppedViewControllers` or introduce a detail-history generation
  when a new primary selection starts a new branch.
  - Focused simulator test: A → child → Back → select B → Forward must not
    resurrect A; repeat with keyboard/gesture routing where available.
  - Evidence: Apollo's private history is a native Swift
    `[UIViewController]`, not an Objective-C `NSArray`. Added an ABI-safe Swift
    bridge and a runtime-gated pane helper that validates the exact Apollo
    navigation class, main-thread access, and the expected one-word ivar layout
    before clearing it. Semantic detail replacements, detail-to-placeholder
    clears, and compact logical ownership migrations now invalidate only the
    affected physical histories; ordinary push/pop and current-branch Forward
    remain Apollo-native. The simulator bridge now accepts
    `navforward primary|detail`. On a signed-in simulator, the exact real-data
    chain Inbox → Comments → Back → Moderator Mail → Forward cleared native
    history `1 -> 0` and remained exactly `[ModmailInbox]`; a fresh Inbox →
    Comments → Back → Forward restored `[Inbox, Comments]`. A separate Home
    primary Back/Forward survived an Inbox detail replacement. Comments →
    Profile → Back → new subreddit feed cleared detail to the placeholder and
    Forward stayed on the placeholder. A compact Chat route migrated back to
    regular width as detail, cleared the prior detail history, and Forward did
    not resurrect the old controller in either column. The simulator ended in
    regular width with compact override off. `git diff --check` passed and the
    device build produced
    `com.apollo.reborn_3.5.1-31+debug_iphoneos-arm.deb`.

- [x] **09 — Clear or reconcile stale detail when primary context changes.**
  Cover pops, tab reset/reselection, in-place feed changes, title menus, and
  primary-root replacement—not only classified Posts pushes.
  - Focused simulator test: change every supported primary context and verify
    detail is retained only when it still belongs to that context.
  - Evidence: detail ownership is now tracked against both the exact primary
    source and its semantic feed controller, with a stable synchronous feed
    scope and coalesced reconciliation after navigation settles. Detail was
    retained across tab switches, title-menu cancellation, sort changes, a
    no-op primary stack replacement, and regular/compact/regular migration.
    It was cleared after primary pop, primary push/root replacement, native tab
    reselection reset, an in-place Home → Apple feed change, and account changes
    on the account-scoped Home/Inbox/Profile tabs while Settings detail stayed
    intact. Compact account clearing removed the logical detail suffix from
    `[RedditList, Posts, Comments]`, invalidated Forward, and expanded to clean
    primary `[RedditList, Posts]` plus the detail placeholder. All five tabs
    passed the final regular-width smoke, recent logs had no navigation/hierarchy
    warnings, `git diff --check` passed, and the device build produced
    `com.apollo.reborn_3.5.1-32+debug_iphoneos-arm.deb`.

- [x] **10 — Stop mutating navigation items for arbitrary pushes.**
  Restrict forced Back/leading-item behavior to known pane destinations.
  - Focused simulator test: known detail, known list, composer, settings, login,
    and modal-like controllers retain their intended leading items.
  - Evidence: the two blanket post-push mutations were replaced by one shared
    logical-detail policy whose exact allowlist contains only the demonstrated
    tab-root exception, `ProfileViewController`. Deterministic unknown probes on
    both primary and detail preserved `hidesBackButton=YES`,
    `leftItemsSupplementBackButton=NO`, and the identical native left item. Real
    Comments roots, a rightward Posts list, Reborn Settings → Theme Manager,
    Web Login, New Comment, alert, and share flows all retained their native
    leading controls and stack ownership. Regular and compact Comments → Profile
    produced exactly one Back plus Profile's Accounts/action items, and Back
    returned to Comments. Compact chrome now removes only its injected item by
    identity instead of restoring stale item/flag snapshots: a simulated native
    `Dynamic` item and both changed Back flags survived expansion, two cycles
    produced no duplicate pane item, and the final regular-width five-tab smoke
    was clean. `git diff --check` passed, the warning scan found no navigation or
    hierarchy diagnostics, and the device build produced
    `com.apollo.reborn_3.5.1-33+debug_iphoneos-arm.deb`.

- [x] **11 — Serialize cross-column changes with interactive transitions.**
  Defer or coalesce replacements until detail push/pop transitions complete.
  - Focused simulator test: completed and cancelled detail pops while rapidly
    selecting multiple primary rows (latest wins), plus route/clear ordering.
    Repeat through empty-primary-survivor and populated-secondary-survivor
    regular → compact → regular transitions. Prove stale/deallocated sources are
    dropped, Forward/context ownership is correct, compact Back/chrome remains
    coherent, the queue drains, and no nested/unbalanced transition, hierarchy,
    crash, or dead-gesture diagnostics appear.
  - Completed 2026-08-10. Cross-column mutations now use a latest-intent queue
    gated by navigation gestures, transition coordinators, topology changes and
    compact Back settlement. Public primary pushes, pops and stack replacements
    carry source-aware mutation provenance; committed app navigation always
    invalidates stale repair work. The iPadOS 26 compact merge is repaired only
    for its observed `popToViewController:animated:YES` identity shape under the
    same immutable restore lineage, expected stack and mutation owner, including
    the compact→regular generation handoff. Rejected coordinator registration,
    cancelled gestures and late UIKit writes cannot strand the queue or chrome.
    Simulator coverage passed deterministic latest-wins gating, real Apollo edge
    cancel and commit, compact Back followed immediately by expansion, a newer
    route arriving during compact Back, and account-context clearing. The exact
    regression that reduced Home from `[subreddit list, feed]` to the root now
    logs the topology normalization capture and finishes with primary depth 2;
    the newer-route race finishes with `Transition Probe NewDuringBackFinal` in
    detail and `{blocked=0 active=0 pending=0}`. The final screenshot is
    `.sim/task11-final-regular.png`; `git diff --check` passed, no Task 11 error,
    hierarchy or dead-gesture diagnostics appeared, and the device build produced
    `com.apollo.reborn_3.5.1-35+debug_iphoneos-arm.deb`.

- [x] **12 — Make pane installation atomic and exception-safe.**
  Construct and validate before committing, isolate sidebar setup, and restore
  the original hierarchy on failure so opt-in cannot create a launch crash loop.
  - Focused simulator test: injected construction/configuration failures at
    each phase leave all original tab children intact and launchable.
  - Evidence: installation is now an explicit per-tab-controller transaction.
    It snapshots the exact child identities/order, selected child/index, every
    original navigation stack, and each controller's opaque-bar flag; detaches
    stock children before staging so no navigation controller has two parents;
    requires every eligible tab to construct; validates primary/detail
    containment, owner registrations, tab-item identity, and exact cold-stack
    reconstruction; and publishes the converted array only after all five panes
    pass. Factory exceptions clean up gesture targets/owner-map entries and
    containment, pending callbacks are invalidated, mixed or partial hierarchies
    are rejected, and any core exception restores the complete stock snapshot.
    Sidebar setup has its own exception boundary and restores the prior mode,
    retaining the coherent floating-tab-bar fallback rather than undoing valid
    panes. Simulator-only launch injection covered `preflight`, stock detach,
    construction begin/nil/complete, detail creation, cold normalization,
    primary/secondary attachment, staging validation, child-array commit,
    selection commit, and final postcondition; every core phase reported five
    original `ApolloNavigationController` children, zero panes, and
    `rollbackExact=true`. Both sidebar-before/after failures retained five live
    panes with `active=true` and mode 0. A rollback launch selected all five
    original tabs successfully and stayed alive; the injection-free control
    selected all five pane tabs and ended with 5/5 panes active. Final screenshot:
    `.sim/task12-final.png`. `git diff --check` passed, the simulator build passed,
    and the pinned iOS 26 device build produced
    `com.apollo.reborn_3.5.1-36+debug_iphoneos-arm.deb`.

- [x] **13 — Use resolved column/display state at constrained regular widths.**
  Stop treating `!isCollapsed` as proof that primary is tiled and visible;
  provide a recoverable show-list affordance whenever UIKit hides it.
  - Focused simulator test: regular, compact, overlay, and secondary-only debug
    modes; real Stage Manager validation remains a device gate.
  - Evidence: centralized resolved-state helpers now use iOS 26's
    `isShowingColumn:` (with documented display-mode fallback below iOS 26) and
    distinguish tiled `OneBesideSecondary`, foreground `OneOverSecondary`,
    hidden-primary `SecondaryOnly`, and true compact collapse. Detail geometry
    and the divider grabber operate only on a settled, intersecting tiled
    boundary; overlay/hidden frames can no longer drive constraints or display a
    fake resize handle. Visible-controller lookup now presents from primary in
    overlay, detail/placeholder in SecondaryOnly, and the semantic populated
    column when tiled. Hidden-primary deferred sources are rejected, and a
    primary-overlay row selection dismisses the overlay after committing detail.
    Because UIKit documents `displayModeButtonItem` as unsupported for
    column-style splits (and Apollo hides the wrapper bar), the visible inner
    detail nav owns one identity-merged native bar button only in resolved
    SecondaryOnly. It is labelled `Show List`, calls public `showColumn:Primary`,
    preserves destination items/Back policy, and is absent from tiled, visible
    overlay and compact states; regular display transitions are logged and
    reconciled outside layout passes. The simulator reproduced the exact former
    trap (`collapsed=0 primaryAPI=0 primaryGeometry=0`) with one enabled button;
    idb exposed `ApolloPaneShowPrimary`, label `Show List`, Button trait and the
    correct hint. Activation resolved to overlay with primary API/geometry 1,
    item count 0 and idle navigation state. Five repeated hide/recover cycles
    never duplicated the item. Populated compact had regular item count 0 and
    compact Back count 1; reset restored tiled mode and the same detail stack.
    Empty-detail SecondaryOnly moved the item to the placeholder and recovered;
    tab 0 → 4 → 0 preserved each pane's independent mode; the native-item
    mutation probe remained `retained=1`; and visible presentation in
    SecondaryOnly resolved to the attached placeholder rather than hidden
    primary. Screenshots: `.sim/task13-regular.png`, `task13-overlay.png`,
    `task13-secondary.png`, `task13-recovered-overlay.png`, `task13-compact.png`,
    and `task13-final.png`. Real Stage Manager continuous resizing remains the
    stated device gate. `git diff --check`, simulator build and pinned iOS 26
    device build passed; package:
    `com.apollo.reborn_3.5.1-37+debug_iphoneos-arm.deb`.

- [x] **14 — Preserve master selection semantics.**
  Keep the row corresponding to visible detail selected in Settings, Inbox, and
  other list/detail sources, including the VoiceOver selected trait.
  - Focused simulator test: selection follows detail replacement, Back, clear,
    tab changes, and compact/expanded transitions.
  - Evidence: pane-owned selection intents now retain a stable item identity
    for Texture/ListAdapter sources, re-resolve rows after updates, and keep
    exactly one visible master row selected while its detail branch remains
    active. UIKit and Texture cells expose `UIAccessibilityTraitSelected` in
    regular mode; compact mode retains only the logical selection and restores
    the visual/accessibility selection on expansion. Real Home, Inbox, native
    Settings, and the tweak-owned Apollo Reborn Settings row passed replacement,
    detail continuation/Back, clear, five-tab switching, and compact/regular
    scenarios. The injected Settings rows now explicitly stage an intent before
    their early-return push path. A no-build relaunch restored five coherent
    regular pane trees. `git diff --check`, the simulator build, and the pinned
    iOS 26 device build passed; package:
    `com.apollo.reborn_3.5.1-7+debug_iphoneos-arm.deb`.

### Performance and layout polish

- [x] **15 — Restore lazy loading for offscreen tabs.**
  Move view-backed pane configuration into lifecycle methods so all five pane
  hierarchies are not forced to load during scene connection.
  - Focused simulator test: record which pane views load before/after visiting
    each tab; compare cold-launch timing and resident memory.
  - Evidence: pane theming, grabber creation, layout invalidation, and
    navigation-gesture observation now begin in `viewDidLoad`; trait and display
    refresh paths use `viewIfLoaded` and cannot materialize an offscreen pane.
    A simulator-only `loadstatus` probe showed one loaded/attached pane after
    cold launch, then loaded counts 2, 3, 4, and 5 only as the four untouched
    tabs were first selected; exactly one pane remained attached throughout.
    The comparable cold install interval fell from about 1.39s to 0.62–0.68s,
    and a single fixed-window RSS sample fell from 563,920KB to 554,608KB
    (informational simulator measurements, not release-gate performance data).
    Deferred gesture observers remained functional through detail Back and
    compact/regular transitions. Injected `configure-secondary:3` failure still
    rolled back exactly without loading cleanup views. `git diff --check`, the
    simulator build, and pinned iOS 26 device build passed; package:
    `com.apollo.reborn_3.5.1-8+debug_iphoneos-arm.deb`.

- [ ] **16 — Remove hot-scroll allocations outside pane mode.**
  Add direct-navigation/allocation-free fast paths for AutoHideTabBar scans.
  - Focused simulator test: allocation/signpost comparison on iPhone layout-off
    and iPad pane-on scrolling; behavior must remain unchanged.

- [ ] **17 — Remove layout-driving writes from `viewDidLayoutSubviews`.**
  Move host geometry and grabber synchronization to stable transition/safe-area
  callbacks, caching resolved geometry to avoid feedback passes.
  - Focused simulator test: repeated rotation and scripted compact/regular
    changes with layout-pass logging; Stage Manager drag remains a device gate.

- [ ] **18 — Eliminate sidebar-triggered content reflow instability.**
  Stabilize column widths when opening detail, preferably by leaving sidebar
  visibility user-controlled.
  - Focused simulator test: first and repeated detail loads show no large
    sidebar-driven width jump or repeated Texture remeasurement.

- [ ] **19 — Add readable-width treatment for text-heavy detail content.**
  Constrain comments/settings text to a centered readable guide without
  restricting media and intentionally full-width surfaces.
  - Focused simulator test: representative short/long comments, Settings,
    Dynamic Type, media, portrait, and landscape screenshots.

- [ ] **20 — Coordinate divider widths across tab panes.**
  Maintain a coherent per-scene preferred primary width while allowing UIKit to
  resolve constrained windows safely.
  - Focused simulator test: resize one tab, switch through all tabs, relaunch,
    and confirm intentional persistence without compact corruption.

- [ ] **21 — Make the divider/grabber native and accessible.**
  Prefer UIKit's system affordance, or provide a real adjustable control with
  label, value, hint, hit target, pointer, and keyboard behavior.
  - Focused simulator test: accessibility tree, pointer/drag behavior, keyboard
    resizing, and every resolved display mode.

- [ ] **22 — Refresh pane-owned colors on live theme changes.**
  Observe the canonical theme notification rather than relying on trait changes.
  - Focused simulator test: change stock/custom themes and light/dark appearance
    with each tab both empty and populated.

### Settings, compatibility, privacy, and integration

- [ ] **23 — Make restart-deferred Settings rows reflect live state.**
  Separate persisted desired state from active process state after choosing
  Later so dependent rows do not lie about the current hierarchy.
  - Focused simulator test: enable/disable, choose Later, revisit Settings, then
    restart and verify both intermediate and final row sets.

- [ ] **24 — Correct pre-iOS 18 feature copy and fallback behavior.**
  Use availability-specific copy or gate the experiment if the retained tab-bar
  layout cannot meet the feature promise.
  - Simulator coverage: current runtime copy/gating.
  - Device/runtime gate: iPadOS 15 and 17.

- [ ] **25 — Make PiP bounds respect actual tab-bar/sidebar visibility.**
  Use visible intersection/presentation mode instead of `tabBar.window` alone.
  - Focused simulator test: visible and hidden tab bar, sidebar, compact mode,
    and videos intersecting the lower edge; real PiP remains a device gate.

- [ ] **26 — Route actions to the correct foreground scene.**
  Prefer the originating scene and foreground-active key scene over unordered
  `connectedScenes` enumeration.
  - Focused simulator test: two simulated windows/scenes with distinct selected
    tabs and stacks; route from each and verify isolation.

- [ ] **27 — Redact full Reddit destinations from diagnostics.**
  Log route type and privacy-safe identifiers rather than full URLs.
  - Focused simulator test: exercise every VisionOS/multiwindow route and inspect
    exported `apollofix` logs for subreddit/post/comment URL leakage.

## Additional release gates

- [ ] **A — Direct Chat return routing follows the actual destination stack.**
  This is expected to become fixable through tasks 01 and 06, but gets its own
  regression scenario because mailbox return state is user-visible.
- [ ] **B — Tab reset, reselection, badges, account/profile item mutations, and
  scroll-to-top behavior remain native after wrapping tab children.**
- [ ] **C — Popovers, share sheets, alerts, login, composer, and media viewers
  present from the visible scene and column in regular and compact layouts.**
- [ ] **D — Full device/OS/window matrix passes:** iPad mini, 11-inch, 13-inch;
  portrait/landscape; Split View; Slide Over; Stage Manager continuous resize;
  external display; supported iPadOS fallback versions and current releases.
- [ ] **E — Accessibility matrix passes:** VoiceOver, Full Keyboard Access,
  pointer, Dynamic Type accessibility sizes, Reduce Motion, and RTL.
- [ ] **F — Performance soak passes:** cold-launch/RSS comparison, scroll
  allocations, frame-time spikes, main-thread Texture measurement, memory
  warnings, and a ten-minute resize/rotation leak run.
- [ ] **G — Simulator IPA bake fallback is transactional and tested for signing
  failure, insufficient Mach-O padding, malformed/fat binaries, interrupted
  writes, and idempotence.**

## Verification log

Add one entry per completed task. Never replace prior evidence; append a new
entry if a later regression requires reopening and re-verifying a task.

<!--
### Task NN — YYYY-MM-DD — commit <sha>

- Implementation:
- Focused test:
- Standard smoke checks:
- Evidence:
- Remaining device/external gate:
-->

### Task 01 — 2026-08-09 — baseline `5f6ea269` + task working tree

- Implementation: `ApolloCommon` now dynamically asks a pane's explicit
  `apollo_navigationControllerForColumn:` accessor before using its generic
  UIKit column fallback. Added simulator-only `navdump` evidence tooling.
- Focused test: launched the real `Apollo-iPad` simulator, opened an actual
  `Apollo.CommentsViewController` from Home, dumped all five tab stacks in
  regular mode, forced compact mode, dumped again, then expanded and dumped a
  third time. Every pane returned primary plus the real nested detail nav once.
- Standard smoke checks: Home detail routing passed; all five tabs selected via
  their real floating-tab controls; regular → compact → regular retained the
  Comments detail; a no-build relaunch installed five panes and enumerated two
  stacks each. No new exception, hierarchy warning, routing loop, or crash was
  present in the focused log window.
- Stock regression check: the same simulator build on the default iPhone
  returned one direct Apollo navigation controller for each of five tabs.
- Known baseline issue observed, not introduced by task 01: the tab sidebar
  relaunched hidden after an earlier automatic hide. This remains task 07.
- Remaining device/external gate: none for the enumeration fix itself. Direct
  Chat's return-marker behavior has a separate scenario under release gate A.

### Task 02 — 2026-08-09 — baseline `5f6ea269` + task working tree

- Implementation: compact collapse now hides UIKit's otherwise duplicated
  outer navigation bar, installs one labelled detail-root Back item, and owns a
  root-only leading-edge pan plus `accessibilityPerformEscape`. Apollo's private
  left-edge recognizers and UIKit's nested pop recognizers are disabled only
  while compact and restored to their exact prior state on Back or expansion.
  Every successful cross-column escape returns to the captured primary anchor
  and clears the detached detail stack.
- Focused test: opened a real Home comments thread, forced compact traits, and
  confirmed the accessibility hierarchy contained exactly one navigation bar.
  Back-button tap hit `_UIButtonBarButton`; a 48pt edge drag cancelled without
  navigating; a committed 788pt edge drag returned to the feed; and the exact
  accessibility escape action reported `handled=1`. Button, committed edge,
  and accessibility paths each logged detail clear plus compact Back completion.
- Standard smoke checks: regular → populated compact → regular, all five real
  floating-tab controls, detail Back, cancelled/committed gestures, and a
  no-build relaunch passed. Relaunch installed panes on 5/5 tabs at 1376x1032,
  restored a 480pt primary plus empty detail, and showed no relevant exception,
  hierarchy, unbalanced-transition, nested-pop, or layout-loop diagnostics.
- Build coverage: simulator Liquid Glass build/launch passed repeatedly;
  `THEOS=/Users/Jordan.Earle/theos make package` passed for the pinned iOS 26
  device SDK / iOS 14 deployment target.
- Cleanup: forced compact mode was reset, Apollo was relaunched without a
  rebuild, and the shared iPad simulator was left in regular two-column mode.
- Remaining device/external gate: perform a physical VoiceOver two-finger scrub
  during release accessibility validation; the underlying escape action itself
  was invoked and verified directly in the simulator.

### Task 03 — 2026-08-09 — baseline `5f6ea269` + task working tree

- Implementation: pane visible-content selection no longer assumes every
  compact collapse is displayed through primary. It returns the populated,
  attached detail navigation controller when secondary survived collapse;
  otherwise it returns the attached primary. Attachment checks use
  `isViewLoaded`/`viewIfLoaded.window` and do not load detached columns merely
  to answer a presenter lookup.
- Focused test: the production `UIWindow.visibleViewController` recursion was
  driven through simulator-only `visibleprobe` commands. Regular empty resolved
  attached `PostsViewController`; empty compact resolved the attached primary
  list; regular populated and populated compact both resolved attached
  `CommentsViewController`; compact Back then resolved attached
  `PostsViewController` again.
- Presentation probes: real `UIAlertController` and `UIActivityViewController`
  instances were requested from empty-primary and populated-detail compact
  states. UIKit forwarded both through `ApolloTabBarController`, which was
  verified as the same containment branch as the requested leaf. Both rendered
  correctly (including an iPad popover anchor), and no detached-presenter or
  window-hierarchy warning was logged.
- Standard smoke checks: regular → compact → regular, compact Back, all five
  floating-tab destinations, and a no-build relaunch passed. Relaunch installed
  5/5 panes in regular width with a 480pt primary and emitted no relevant
  exception, assertion, hierarchy, transition, or layout-loop diagnostics.
- Build coverage: simulator Liquid Glass build/launch passed;
  `THEOS=/Users/Jordan.Earle/theos make package` passed for the device target.
- Cleanup: probe modals were dismissed, forced compact mode was reset, and the
  shared simulator was relaunched in regular two-column mode.
- Remaining device/external gate: none for visible-controller selection; the
  tested alert/activity presentation APIs are the same on device.

### Task 14 — 2026-08-12 — baseline `18d0f8c` + task working tree

- Implementation: the pane tracks logical master selection independently from
  UITableView/Texture presentation, uses stable ListAdapter item identities
  across refreshes, suppresses Apollo's eager deselection while detail owns the
  route, and applies/removes the selected accessibility trait with the visual
  state. Added a narrow public staging handoff for screen-specific selection
  owners; Apollo's two injected root Settings rows use it before their
  early-return push path.
- Focused test: selected two different real Home posts, continued and popped the
  detail stack, cleared detail, and verified every state with
  `selectionstatus`. Repeated with a real Inbox row, native General Settings,
  and Apollo Reborn Settings. Every active regular case reported exactly one
  selected row and `axSelected=1`; clear reported zero; compact reported a
  retained logical selection with no hidden physical/AX selection; expansion
  restored the same row with `pass=1`.
- Standard smoke checks: switched Home → Search → Inbox → Profile → Settings →
  Home, replaced detail, exercised Back and regular → compact → regular, reset
  the compact override, and performed a no-build relaunch. The final navigation
  dump contained exactly two navigation controllers for each of five tabs, and
  the final 1032x1376 screenshot showed the normal regular two-column state.
  Recent `apollofix` logs contained no relevant exception, assertion, hierarchy,
  nested-transition, routing-loop, or dead-gesture diagnostic.
- Build coverage: Liquid Glass simulator build/launch and `make package` for the
  pinned iOS 26 device SDK / iOS 14 deployment target passed. Package:
  `com.apollo.reborn_3.5.1-7+debug_iphoneos-arm.deb`.
- Remaining device/external gate: the selected accessibility trait is proven in
  the simulator; spoken VoiceOver output remains part of release gate E.

### Task 15 — 2026-08-12 — baseline `18d0f8c` + task working tree

- Implementation: moved every pane-owned view/gesture side effect out of the
  five-tab construction transaction and into the pane's `viewDidLoad`.
  Ground-theme refresh and resolved-layout invalidation now use `viewIfLoaded`,
  and rollback removes gesture targets only when a pane had actually installed
  them. Installation validation accepts the detail host's stored navigation
  ownership while its view is unloaded, then requires concrete containment once
  loaded. Added the simulator-only `loadstatus` probe, which itself never reads
  `view` from an unloaded controller.
- Focused test: a no-build cold launch reported `loadedPaneCount=1`, with Home
  loaded/attached and tabs 1–4 unloaded/unattached. Visiting Search, Inbox,
  Profile, and Settings in turn produced counts 2→3→4→5; returning Home retained
  five loaded panes but exactly one attached pane. A fresh relaunch returned to
  one loaded pane, proving visited panes are not eagerly recreated next process.
- Performance sample: in comparable simulator launches, the interval from the
  pane install hook to the five-pane commit changed from about 1.394s before the
  change to 0.618–0.679s after it. One roughly fixed-window `ps` RSS comparison
  changed from 563,920KB to 554,608KB. These are directional simulator samples;
  the controlled cold-launch/RSS soak remains release gate F.
- Standard smoke checks: opened a real Home post in detail, pushed and popped a
  continuation, switched through all five tabs, and exercised regular → compact
  → regular. Routing, selected-row state, deferred gesture observation, two-nav
  ownership, and the final regular screenshot were coherent. A no-build
  relaunch again installed 5/5 panes while loading only Home. Recent logs had no
  relevant exception, assertion, hierarchy, nested transition, routing loop, or
  dead-gesture diagnostic.
- Rollback regression: simulator fault `configure-secondary:3` restored the
  exact five stock navigation children with `rollbackExact=1`; cleanup did not
  force unloaded pane views. A following normal relaunch installed all panes.
- Build coverage: Liquid Glass simulator build/launch and `make package` for the
  pinned iOS 26 device SDK / iOS 14 deployment target passed. Package:
  `com.apollo.reborn_3.5.1-8+debug_iphoneos-arm.deb`.
- Remaining device/external gate: controlled launch/RSS statistics and memory
  pressure/soak coverage remain part of release gate F.
