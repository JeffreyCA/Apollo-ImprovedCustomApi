# iPad Pane Layout — Engineering Plan

Branch: `je/ipad-pane-layout` (experimental, off `main`)

Tracking issues: [#225](https://github.com/Apollo-Reborn/Apollo-Reborn/issues/225) (iPad support),
[#635](https://github.com/Apollo-Reborn/Apollo-Reborn/issues/635) (tab bar over search bar),
[#782](https://github.com/Apollo-Reborn/Apollo-Reborn/issues/782) (jump bar hover jank),
[#387](https://github.com/Apollo-Reborn/Apollo-Reborn/issues/387) (floating menu placement — closed, stopgap shipped as #557).

> This is the largest UI change the tweak has attempted. The plan is deliberately
> staged so that every phase is independently shippable and independently
> revertable, and so that the riskiest assumption is tested before any
> architecture is committed to.

---

## 1. What we are building

A three-column, opt-in iPad layout:

```
┌────────────┬───────────────────┬──────────────────────┐
│  SIDEBAR   │   POST LIST       │   COMMENTS / DETAIL  │
│            │                   │                      │
│ ◉ Home     │ r/apple      ⌄ ⋯  │  ← Post title        │
│ ○ Search   │ ───────────────── │  ══════════════════  │
│ ○ Profile  │ ▸ Post one        │  [ media / body ]    │
│ ○ Inbox    │ ▸ Post two        │                      │
│ ○ Settings │ ▸ Post three      │  ┌ u/abc   ▲ 42      │
│ ────────── │ ▸ Post four       │  │ comment text…     │
│ ⭐ Home    │ ▸ Post five       │  │ ┌ u/def  ▲ 12     │
│ 🔥 Popular │ ▸ Post six        │  │ │ reply text…     │
│ 🌐 All     │ ▸ Post seven      │  └ u/ghi   ▲ 3       │
│ ────────── │ ▸ Post eight      │                      │
│ r/apple    │ ▸ Post nine       │  ┌ u/jkl   ▲ 8       │
│ r/ios      │ ▸ Post ten        │  │ comment text…     │
└────────────┴───────────────────┴──────────────────────┘
```

Non-goals for this branch: a bespoke iPad *visual* design language, a Mac
Catalyst build, or reimplementing any Apollo screen. Every column hosts a real
Apollo view controller.

### Design principles

1. **Opt-in and reversible.** Default OFF, iPad-only, iPhone code paths never
   execute the new code. A user who never enables it must not be able to tell
   this shipped.
2. **Reuse Apollo's real view controllers.** We re-host, never reimplement. The
   subreddit list keeps its section index, edit mode, multireddits and
   drag-reorder because it *is* `RedditListViewController`.
3. **Compact width must equal today's app.** `UISplitViewController` collapse
   already folds a triple-column layout into a single navigation stack —
   sidebar → list → detail — which is exactly today's push hierarchy. The
   fallback is free and correct, and it covers Slide Over, small Stage Manager
   windows, and portrait on smaller iPads.
4. **Allowlist routing, never blocklist.** Only view controller classes we have
   explicitly classified get routed to a different column. Everything else
   pushes in place, i.e. behaves exactly as it does today. Apollo has ~90 view
   controllers and the tweak adds its own; an allowlist is the only safe default.
5. **`ApolloTabBarController` keeps its identity and index space.** It stays the
   window's root view controller with the same five children in the same order.
   This is what keeps deep links, quick actions, the settings router, the crash
   prompt coordinator and `ApolloMainTabBarController()` working.

---

## 2. Ground truth (verified, not assumed)

Everything in this section was confirmed against the shipping binary,
`Apollo.app/Info.plist`, or the existing tweak source.

### App capabilities

| Fact | Value | Source | Why it matters |
|---|---|---|---|
| `UIDeviceFamily` | `[1, 2]` | `Apollo.app/Info.plist` | Apollo is already a native iPad app, not in compatibility mode. |
| `UIRequiresFullScreen` | absent | `Apollo.app/Info.plist` | Multitasking is already on, so Apollo **already survives compact width on iPad today**. The compact fallback is proven code, not new risk. |
| `UIApplicationSupportsMultipleScenes` | `true` | `Apollo.app/Info.plist` | Stage Manager / multi-window is available for free later. |
| `MinimumOSVersion` | `15.0` | `Apollo.app/Info.plist` | The real floor is iOS 15, not the tweak's 14.0 target. |

### Container hierarchy

Recovered from `-[SceneDelegate scene:willConnectToSession:options:]`
(`sub_1000879c0`) and the tab bar factory (`sub_100087244`):

- `sub_100087244()` builds `ApolloTabBarController` and sets exactly **five**
  `ApolloNavigationController` children.
- The scene delegate then does `[window setRootViewController:tabBarController]`,
  stores it in its own `tabBarController` ivar, and calls `makeKeyAndVisible`.
- **Consequence:** hooking `scene:willConnectToSession:options:` and
  post-processing after `%orig` is a clean install point. The scene delegate's
  `tabBarController` ivar still points at the real tab bar controller, so
  `ApolloMainTabBarController()` keeps working untouched.
- Tab index 2 is Profile (`-[ApolloTabBarController goToProfileTab]` →
  `setSelectedIndex:2`), matching `ApolloProfileTabIndex` in `ApolloUserAvatars.xm`.
- Tab 0's root is `RedditListViewController` — asserted with `isMemberOfClass:`
  by `ApolloQuickActions.xm`.
- Tab 0 can launch with a **two-deep** stack (subreddit list + a restored
  `PostsViewController`). That restore state maps one-to-one onto
  sidebar + list columns, which is a useful signal that the split is natural.
- The factory calls `loadViewIfNeeded` and `waitUntilAllUpdatesAreProcessed` on
  several roots — Apollo pre-warms these synchronously at launch, so any
  restructuring must happen *after* `%orig` returns.

### Push pipeline internals (`sub_10015c720`)

`-[ApolloNavigationController pushViewController:animated:]` is a thin ObjC shim
over one Swift body, `sub_10015c720`. Decompiled, it:

1. **Silently drops duplicate pushes** — if the incoming VC is already in
   `viewControllers`, the whole body no-ops. A router that moves a VC between
   columns must remove it from the source stack first, or later Apollo-side
   pushes of that same instance will silently do nothing.
2. Sets `extendedLayoutIncludesOpaqueBars = YES` on every pushed VC before
   calling super.
3. Sets the `pushing` ivar, which the custom `ApolloNavigationAnimator` and the
   interactive-pop machinery read.
4. If the nav bar is hidden and the `HideBarsOnScroll` default is set, it
   schedules ~100 escalating `asyncAfter` re-layout attempts on the main queue.
   With hide-bars active in three columns, these timer storms run per column.

**Consequence for the router:** reroute by *calling the destination column's
navigation controller's normal `pushViewController:`*, never by splicing
`viewControllers` arrays. That way Apollo's own body runs on the destination —
dedupe, extended-layout, `pushing` flag, nav-bar re-show — and every per-nav
invariant stays coherent. (This is also why the ObjC-level hook is the right
interception point: Logos hooks the shim, so a reroute can return without ever
running Apollo's Swift body on the wrong nav.)

### Forward stack: `poppedViewControllers` + `goForward`

Confirmed by decompiling `-[ApolloNavigationController goForward]`: every pop
appends to a per-nav `poppedViewControllers` array, and `goForward` re-pushes
its tail through the same push body. This powers keyboard "go forward" **and the
right-screen-edge pan gesture**. Two consequences:

- **Per-column forward stacks.** If the router clears the secondary column when
  a new list loads, those cleared VCs land in that column's forward stack.
  Policy needed: clear the forward stack on cross-column reroutes (recommended —
  a "forward" that re-pushes a comments VC for a post no longer in the list
  column is disorienting), or accept per-column forward history.
- **The gesture conflict is now concrete, not hypothetical** (see §5.4): Apollo
  installs pans on *both* edges of every nav controller, so every interior
  column boundary in a triple-column layout has an Apollo recognizer on each
  side of it, plus UIKit's own split-view show/hide gesture.

### Width-change handling — what Apollo actually does

Searched the full procedure list: **no** `viewWillTransitionToSize:` and **no**
`traitCollectionDidChange:` overrides exist on `ASTableViewController`,
`PostsViewController`, or `CommentsViewController`. (Only
`ApolloNavigationController` and `MediaViewerController` implement the former.)
All width adaptation in the content controllers is passive:
`viewDidLayoutSubviews` re-frames overlays (dark overlay, jump-bar dropdown —
both computed from `view.bounds` with a max-width clamp and centering, so they
are already column-relative), and the actual cell re-measure is Texture
framework behavior — `ASTableView.layoutSubviews` re-measures every node when
its constrained width changes (`AsyncDisplayKit.framework` is embedded in
`Apollo.app/Frameworks/`).

Two readings of this:

- **Good:** there is no custom rotation/resize code in the content controllers
  to fight. Resize correctness comes for free from Texture.
- **Correction to an earlier claim:** the `restoredViewWidth` ivars on
  Posts/Comments/Inbox are **state-restoration** bookkeeping (scale the saved
  scroll offset when the restored width differs), *not* live-resize support.
  They are evidence Apollo tolerates width differences across launches, not
  evidence the live re-measure is cheap. The entire live-resize cost is
  Texture's full re-measure, there is no incremental path, and Phase 0's
  measurement of it is *the* number this project hangs on.

### Custom presentation controllers are window-anchored

Apollo ships ~20 custom `UIPresentationController` subclasses (ActionController,
SubredditSelector, Sourdough, FlairAlert, TipJar, AccountManager, …).
Decompiled `ActionControllerPresentationController
frameOfPresentedViewInContainerView`: it sizes from **`containerView.bounds`**
(the window in a standard presentation) with a max-width clamp (`fminnm`) and
`(containerWidth − width) / 2` centering. So in the pane layout, action menus
and card sheets present **centered over the whole window**, not over the source
column. Not a crash risk — the max-width clamp means they don't stretch — but a
UX note: long-press menus on a post in the list column appear window-centered.
Acceptable for v1; column-anchored presentation would mean re-parenting Apollo's
presentation controllers and is explicitly out of scope.

Related standard-iPad requirement for tweak-drawn UI: `UIActivityViewController`
and alert-sheet presentations on iPad require a popover `sourceView`/`sourceRect`
or they throw. Apollo handles its own; every *tweak* share-sheet call site that
becomes reachable from a new column context needs a popover source audit.

### UIKit API availability

| API | Introduced | Usable here? |
|---|---|---|
| `UISplitViewController(style: .tripleColumn)` | iOS 14 | **Yes** — this is the backbone. Covers the whole iOS 15+ floor. |
| `UITabBarController.mode` / `.sidebar` | **iOS 18** | Optional enhancement only. Cannot be the backbone. |
| `UITab` / `UITabGroup` / `UISearchTab` | **iOS 18** | Not used — see below. |

**Why not build on `mode = .tabSidebar`.** It renders a sidebar from static
`UITab`/`UITabGroup` objects. Apollo's sidebar content is the *subreddit list*:
dynamic, sectioned, editable, reorderable, with multireddits and a section index.
Expressing that as `UITab` objects would mean reimplementing subscription
management, which violates principle 2 and would regress behavior users rely on.
It is also iOS 18+, so it could never be the only path. We may offer it later as
a cosmetic variant for the destinations rail specifically.

---

## 3. Architecture

### Topology

One `UISplitViewController` **per tab**, replacing that tab's navigation
controller as the tab bar controller's child:

```
UIWindow.rootViewController
└── ApolloTabBarController                    ← unchanged object, tabBar hidden when panes are on
    ├── tab 0  ApolloPaneSplitViewController  (.tripleColumn)
    │            ├─ .primary        ApolloPaneSidebarViewController
    │            │                    ├─ destinations rail  (tweak-drawn: Home/Search/Profile/Inbox/Settings)
    │            │                    └─ RedditListViewController      ← embedded child, Apollo's real VC
    │            ├─ .supplementary  ApolloNavigationController         ← list stack (PostsViewController…)
    │            └─ .secondary      ApolloNavigationController         ← detail stack (CommentsViewController…)
    ├── tab 1  ApolloPaneSplitViewController  (Search:  results  → post → comments)
    ├── tab 2  ApolloPaneSplitViewController  (Profile: sections → list → detail)
    ├── tab 3  ApolloPaneSplitViewController  (Inbox:   mailboxes → thread list → message)
    └── tab 4  ApolloPaneSplitViewController  (Settings: sections → detail)
```

**Why per-tab rather than one global split view.** Each tab keeps its own
column state, so leaving Inbox and coming back restores the subreddit and post
you were reading. It also means the tab bar controller's children array is the
only thing that changes shape, which keeps the audit surface to one list of call
sites (§5).

**The destinations rail is duplicated per tab and that is deliberate.** It is
cheap tweak-drawn UI, stateless apart from the selected index, and pinned to the
same position in every sidebar — so switching tabs reads as "the lower part of
the sidebar changed", not as a rail flicker. `UITabBarController` swaps children
without animation, so there is no cross-fade to suppress. If this reads badly in
the spike, the fallback is a single shared rail view moved between sidebars.

**No `.compact` column is set.** `UISplitViewController` collapses a triple
column by pushing supplementary and secondary onto the primary's navigation
controller, which reproduces today's push hierarchy exactly. Setting an explicit
compact controller would mean maintaining a second layout by hand.

### Column routing

A single interception point classifies pushes and redirects them.

`ApolloSwipeUpComments.xm` already proves this technique in this codebase: it
hooks `-[UINavigationController pushViewController:animated:]`, recognizes
`_TtC6Apollo22CommentsViewController`, intercepts it before it lands, and
re-presents it somewhere else. The pane router is the same mechanism with a
class table instead of a single class.

| Class | Column | Notes |
|---|---|---|
| `RedditListViewController` (drill-in, e.g. multireddit) | primary | Pushed within the sidebar's own stack. |
| `PostsViewController`, `LitePostsViewController` | supplementary | Replaces the list column; clears the detail column. |
| `SearchViewController` results, `SubredditSearchResultsViewController`, `PostsSearchResultsViewController` | supplementary | |
| `InboxListViewController`, `ModmailInboxViewController`, `ModQueueViewController` | supplementary | |
| `AllSubredditCommentsViewController`, `SavedPostsCommentsViewController`, `UserCommentsViewController` | supplementary | Comment *lists*, not comment threads — despite the names. Tapping a row in them opens a real `CommentsViewController`, which routes secondary. |
| `CommentsViewController` | secondary | The headline case. |
| `PrivateMessageViewController`, `MessagesViewController` | secondary | |
| `ProfileViewController`, `UserCommentsViewController` | secondary | When pushed from a comment/post author. |
| `SubredditSidebarViewController`, `SubredditRulesViewController` | secondary | |
| **everything else** | **push in place** | Default. Settings sub-screens, composers, media viewers, web views, and every tweak-owned VC keep today's behavior until explicitly classified. |

Rules:
- Pushing a list-class VC clears the secondary column to its placeholder.
- Pushing a detail-class VC **replaces** the secondary stack rather than
  appending, unless it was pushed *from within* the secondary column (e.g.
  tapping a link inside comments), in which case it appends.
- Modal presentations are never rerouted.

### Where the code lives

New directory `src/ipad/`:

| File | Purpose |
|---|---|
| `ApolloPaneLayout.{h,m}` | Feature gate, capability check, change notification, the `sPaneLayoutEnabled` state read. Single source of truth for "are panes active right now". |
| `ApolloPaneInstall.xm` | Hooks `-[SceneDelegate scene:willConnectToSession:options:]`; builds/tears down the split controllers after `%orig`. |
| `ApolloPaneSplitViewController.{h,m}` | `UISplitViewController` subclass + delegate: collapse/expand behavior, column widths, placeholder detail VC, theming. |
| `ApolloPaneSidebarViewController.{h,m}` | Destinations rail + embedded tab root VC. Accent from `ApolloThemeAccentColor()`. |
| `ApolloPaneRouter.xm` | The push interception and column classification table. |
| `ApolloPaneChrome.xm` | Per-column nav bar / immersive header / scroll-edge reconciliation (§5.3). |

### Settings gate

Follows the existing `IPadTabBarBottom` pattern end to end:

- `UserDefaultConstants.h`: `UDKeyIPadPaneLayout` + `ApolloIPadPaneLayoutChangedNotification`
- `ApolloState.{h,m}`: `extern BOOL sIPadPaneLayout;` default `NO`
- `Tweak.xm`: `registerDefaults` entry + `%ctor` read
- `settings/CustomAPIViewController.m`: an iPad-only row under General, hidden
  entirely on iPhone (same `userInterfaceIdiom` guard as the existing row).

Because installation happens at scene connect, toggling requires a relaunch.
Present it as an explicit "Requires restart" row with a confirm-and-restart
action rather than pretending it applies live. When panes are ON, the existing
"Move Tab Bar to Bottom" row is hidden — it is meaningless without the floating
pill.

---

## 4. Phases

Each phase is independently shippable and independently revertable.

### Phase 0 — Spike (throwaway code, do not merge)

Purpose: falsify the riskiest assumptions before committing to architecture.
Force panes on for the Home tab only, hardcoded, no settings, no polish.

Inner loop:
```bash
SIM_DEVICE_TYPE="iPad Pro 13-inch (M5)" scripts/run-in-sim.sh --glass --dark
```
(iPad simulators are present; `run-in-sim.sh` already parameterizes the device
type, so no script changes are needed to start.)

Exit criteria — all must hold before Phase 1 begins:

1. `RedditListViewController` renders and behaves in a ~320pt primary column:
   section index titles, edit mode, swipe actions, multireddits.
2. `PostsViewController` (an `ASTableNode`) re-measures correctly when its column
   width changes, including a Stage Manager drag-resize, without visible cell
   corruption.
3. `CommentsViewController` renders in the secondary column with correct comment
   indentation at reduced width.
4. Collapse to compact (Slide Over) and re-expand does not lose the navigation
   stack or crash.
5. Frame rate during a continuous Stage Manager resize is acceptable, and memory
   with three live columns is measured and recorded.

If (2) or (5) fail, stop and reassess: ASDK re-measure cost under continuous
resize is the assumption most likely to sink this design, and it is cheaper to
learn now.

> **Status (branch `je/ipad-pane-layout`).** Phases 1 and 2 are built. Phase 0's
> spike was folded into Phase 1 rather than thrown away — the container work was
> the same either way, so the exit criteria are being answered against real code.
>
> **Working today**, verified on an iPad Pro 13" simulator with a signed-in
> account: the Home tab runs three columns (subreddits → feed → comments), the
> other four run two, tapping a post opens its thread beside the feed, and a
> sidebar toggle reaches the subreddit list in portrait. The floating tab bar is
> still present — the destinations rail that would replace it is not built.
>
> Phase 0 exit criteria:
> | # | Criterion | Status |
> |---|---|---|
> | 1 | Subreddit list behaves in a narrow column | **Pass** — favorites, multireddits, moderator sections, A–Z index, Edit all intact |
> | 2 | Feed re-measures on width change | **Partially** — correct at each discrete width; the continuous drag-resize case is untested |
> | 3 | Comments render at reduced width | **Pass** — after the column-host fix (§5.2a) |
> | 4 | Collapse/expand keeps the stack | **Pass** — both cases, via the `compact on\|off` sim command |
> | 5 | Resize frame rate + three-column memory measured | **Not done** |
>
> Criterion 4 is now testable without Slide Over: `echo "compact on" >
> /tmp/apollofix-tap.txt` (see `ApolloSimDebugTap.xm`) forces a compact
> horizontal size class onto every pane, which is exactly what makes a split view
> collapse. Verified in both directions — a pane with a thread open collapses
> onto the secondary column and comes back intact, and a pane with an empty
> detail collapses onto the primary without dragging its placeholder along.
>
> Criteria 2 and 5 still need a real device or a driven window resize, which the
> simulator inner loop cannot produce. **They remain the outstanding risk**, and
> §5.2 is still the assumption this design hangs on.
>
> Also verified: iPhone is completely untouched with the layout code compiled in
> — zero pane log lines across a full launch and a normal single-column UI.

### Phase 1 — Foundation (no visible change)

- Settings key, state, gate, iPad-only row, relaunch flow.
- `ApolloPaneLayout` capability check.
- Install/uninstall of split controllers at scene connect.
- **The hierarchy-assumption audit (§5.1)** — the ~15 call sites, routed through
  one shared helper.
- Routing table present but empty: *every* push still lands in place.

Ship state: with the toggle on, the app looks essentially like today (single
wide column) but is structurally split. This isolates "did the container change
break anything" from "did the routing break anything", which is the single most
valuable thing this phase buys.

### Phase 2 — Home tab

Sidebar rail + subreddit list, posts column, comments column. Placeholder detail
state. Selection persistence when switching tabs.

### Phase 3 — Remaining tabs

Search, Profile, Inbox, Settings — one at a time, each behind the same gate.
Inbox and Modmail carry their own selector and compose flows and should be last.

### Phase 4 — iPad-native polish

This is what stops it feeling like a stretched iPhone app, and much of it is
cheap because Apollo already implements the hard part:

- **Keyboard.** `ApolloNavigationController` already exposes `keyCommands` for
  `selectNextCell`, `goIntoCell`, `goBack`, `pageUp`, `scrollToTop`,
  `goToJumpBar`, `openMedia`. With panes these become genuinely desktop-class —
  they just need to target the focused column via the responder chain.
- **Pointer.** Hover states on rows and the jump bar. Fixes
  [#782](https://github.com/Apollo-Reborn/Apollo-Reborn/issues/782), whose hover
  handling currently drops the Liquid Glass effect and clips the title.
- **Context menus and drag & drop.** Drag a subreddit onto the list column; drag
  a post into a new window.
- **Multi-window.** `UIApplicationSupportsMultipleScenes` is already true — "open
  post in new window" is largely plumbing.

### Phase 5 — Adaptivity hardening + regression sweep

Slide Over, all Stage Manager sizes, both rotations, iPad multitasking splits,
and a full iPhone regression pass to prove the dormant path is really dormant.

---

## 5. Known costs and risks

### 5.1 Hierarchy assumptions (bounded, mechanical)

Roughly 15 call sites assume `tabBarController.viewControllers[i]` is a
`UINavigationController`. Confirmed in: `ApolloDirectChatWeb.xm` (several),
`ApolloUserAvatars.xm`, `ApolloQuickActions.xm`, `ApolloLiquidGlass.xm`,
`Tweak.xm`, `ApolloAutoHideTabBar.xm`, `ApolloAutoHideMetaFeeds.xm`,
`ApolloImageUploadHost.xm`, `ApolloSwipeUpComments.xm`,
`ApolloBadgeBookViewController.m`, `UIWindow+Apollo.m`, `ApolloPictureInPicture.xm`.

Fix: add one helper to `ApolloCommon` that unwraps a tab child to its active
navigation controller (identity today, split-view-aware when panes are on), and
route every site through it. Mechanical, enumerable, and testable on iPhone
where it must be a no-op.

### 5.2 ASDK re-measure under column resize — **highest risk**

Apollo's feed and comments are `ASTableNode`-backed; cells measure against a
constrained width. Column resize means Texture re-measures **every node** in the
table (`ASTableView.layoutSubviews` on constrained-width change — framework
behavior, no incremental path). The binary confirms there is no custom resize
handling to help or hinder: no `viewWillTransitionToSize:` or
`traitCollectionDidChange:` on any content controller (§2). The
`restoredViewWidth` ivars are state-restoration offset-scaling, not live-resize
support — the app tolerating width *differences across launches* is weaker
evidence than previously stated. What does still count in our favor: Apollo runs
resizable on iPad today, so single-column live resize (Slide Over, Split View)
already exercises this path in production. What's new in the pane layout is
*three* live node graphs re-measuring on one drag — which interacts badly with
the memory pressure recorded in the August 2026 OOM wave. Phase 0 exists to put
a number on exactly this.

One cheap mitigation if the spike shows churn: `UISplitViewController` column
resizes step through discrete widths (display-mode changes) far more often than
they animate continuously — continuous re-measure mainly bites during Stage
Manager window drags, where a debounce (re-measure on drag end, letterbox during)
is an accepted pattern.

### 5.2a iPadOS 26 floats the sidebar over a FULL-WIDTH secondary — **confirmed, and it bites Texture immediately**

Found while building Phase 1, from a live hierarchy dump on an iPad Pro 13":

```
secondary  _UISplitViewControllerAdaptiveColumnView  (0, 0, 1032, 1312)   ← full window
primary    _UISplitViewControllerAdaptiveColumnView  (10, 86,  413, 1216) ← inset glass panel
```

The secondary column is laid out at the **full window width** and the sidebar
floats over it as a Liquid Glass panel. This is the iPadOS 26 design, not a
misconfiguration — `preferredSplitBehavior = .tile` does not change it.

UIKit expects content to respect the resulting left safe-area inset. **Texture
does not**: `ASTableView` measures its nodes against its own bounds, not its
adjusted content inset. Every comment measured 1032pt wide, got pushed right by
the inset, and ran off the right edge of the screen.

Fix shipped: `ApolloPaneColumnHostViewController` wraps the detail column's
navigation controller and pins it leading/trailing to the safe area (top/bottom
still to the view, so the nav bar keeps extending under the status bar). The
navigation controller's view is then genuinely only as wide as the uncovered
region, and Texture measures correctly with no changes to Apollo or ASDK.

**Generalize this.** Any column we add later inherits the same problem, and so
does any tweak-drawn UI placed in the secondary column. The rule is: never let
Texture content size itself from a view that the sidebar overlaps.

### 5.3 Full-width chrome assumptions — **largest hidden cost**

- 19 tweak modules touch `navigationBar`.
- 33 tweak modules read `UIScreen.mainScreen`.

Modules that assume a single full-width nav bar need per-column awareness:
`ApolloImmersiveHeaderBackground`, `ApolloProgressiveBlur`,
`ApolloScrollEdgeEffect`, `ApolloLiquidGlass` (title centering),
`ApolloAutoHideTabBar`, `ApolloSubredditHeaders`, `ApolloSearchInPlace`.

This is very likely a bigger line-count cost than the split view controller
itself. `ApolloPaneChrome.xm` exists to hold the reconciliation, and the
`UIScreen.mainScreen` readers should migrate to the owning view's window/traits
regardless of this project — that migration is independently correct.

### 5.4 Gesture conflicts — now concrete

`ApolloNavigationController` installs a left screen-edge pan (interactive pop),
a **right screen-edge pan (go forward — confirmed: it re-pushes the tail of the
per-nav `poppedViewControllers` array)**, and a nav-bar pan for hide-on-swipe.
In a triple-column layout every interior column boundary therefore has an Apollo
recognizer on each side of it — the supplementary column's *right*-edge
(go-forward) pan sits exactly on the boundary with the secondary column, whose
*left*-edge (pop) pan sits on the same line — plus `UISplitViewController`'s own
`presentsWithGesture` show/hide pan on the primary edge. "Screen-edge" pans are
actually view-edge relative, so they will fire at column boundaries, not just
screen edges. Plan: disable Apollo's edge pans on interior edges (keep pop on
the leftmost visible column, drop go-forward inside columns — ⌘] still covers
it), and decide `presentsWithGesture` explicitly rather than inheriting it.
Also define the router's forward-stack policy: clear `poppedViewControllers` on
cross-column reroutes so "go forward" never resurrects a detail VC whose list
context is gone.

### 5.5 Entry points that must keep working

Deep links (`apollo://`), Siri intents, home-screen quick actions
(`ApolloQuickActions`), the settings router, the crash prompt coordinator, and
push notification taps all target the tab bar controller and then walk into a
navigation controller. All are covered by §5.1's helper, but each needs an
explicit smoke test — a deep link that lands in the wrong column is a worse bug
than one that fails outright.

### 5.6 What panes do *not* fix

[#635](https://github.com/Apollo-Reborn/Apollo-Reborn/issues/635) (search bar
under the floating tab bar) disappears when panes are ON, because the floating
pill is hidden. It **still affects every iPad user who leaves panes OFF**, which
is the default. Folding it into this work means those users stay broken until
they opt in. If that becomes unacceptable before Phase 2 lands, pull it back out
as a standalone fix — `ApolloSearchHeaderOverlapFix.xm` already exists as the
natural home.

---

## 6. Implementation best practices

Rules distilled from the binary findings above plus Apple's iPad guidance
(the tab-bar/sidebar and desktop-class articles). These bind Phases 1–4.

**Split view API traps (learned the hard way)**
- `supplementaryColumnWidth` and its preferred/min/max siblings **throw** on a
  double-column split view: `"UISplitViewController supplementaryColumnWidth
  properties unsupported for style = DoubleColumn"`. Reading one in shared code
  that runs for every pane crashes the app the first time a two-column tab lays
  out. Guard every access on the pane actually being three-column.
- `oneBesideSecondary` means *one*: in a three-column layout it shows one of
  primary/supplementary and **hides the other**. Three-column panes need
  `twoBesideSecondary`.
- UIKit treats `preferredDisplayMode` as a request and silently downgrades
  `twoBesideSecondary` → `oneBesideSecondary` when the width cannot take three
  tiles (measured: honored at 1366pt landscape, downgraded at 1032pt portrait on
  a 13" iPad). The downgrade hides the **primary** column, so any layout relying
  on three columns must ship a `showColumn:`/`hideColumn:` toggle or the sidebar
  becomes unreachable. Log the *resolved* `displayMode`/`splitBehavior` rather
  than trusting the preference.
- `displayModeButtonItem` renders as an empty capsule inside Apollo's Liquid
  Glass navigation bar — present and tappable, but with no glyph. Use an explicit
  `UIBarButtonItem` with your own symbol and accent.

**Split view configuration**
- `UISplitViewController(style: .tripleColumn)`, `preferredSplitBehavior = .tile`,
  `preferredDisplayMode = .twoBesideSecondary`. Never `.overlay` for the
  supplementary column — content panes that float over other content re-create
  the "blown-up iPhone app" feel this project exists to kill.
- Set `presentsWithGesture` deliberately (likely `false`), because Apollo's own
  edge pans occupy the same edges (§5.4).
- Let the system collapse/expand do the work. Implement
  `splitViewController(_:topColumnForCollapsingToProposedTopColumn:)` only to
  choose the surviving top VC; do not hand-merge stacks. On expand, rebuild
  columns from the router's classification of the collapsed stack.
- Hide the tab bar via the tab bar controller (`hidesBottomBarWhenPushed` /
  LG minimize APIs are irrelevant here) — the `ApolloTabBarController` object
  itself must keep existing untouched (§3).

**Routing**
- Intercept at the ObjC shim (`pushViewController:animated:`) and reroute by
  calling the destination nav's normal push — never splice `viewControllers`
  arrays. Apollo's Swift push body (dedupe, `extendedLayoutIncludesOpaqueBars`,
  `pushing` flag, nav-bar re-show loop) must run on whichever nav actually hosts
  the VC (§2).
- Remove a VC from its source stack *before* pushing it elsewhere, or Apollo's
  duplicate-push guard silently eats later pushes of the same instance (§2).
- Never reroute modals, and never reroute during an in-flight transition
  (`pushing`/`popping` ivars are readable via `MSHookIvar` inside hooks).
- Clear the destination column's `poppedViewControllers` on cross-column
  reroutes (§5.4).

**Presentation**
- Tweak-drawn share sheets / alert-sheet presentations reachable from new column
  contexts must set popover `sourceView`/`sourceRect` (iPad hard requirement).
- Apollo's own card presentations center over the window, not the column (§2) —
  leave as-is for v1.

**Sizing & chrome**
- New tweak UI in panes must derive geometry from the owning view's bounds /
  window, never `UIScreen.mainScreen` — and §5.3's migration moves existing
  modules the same way.
- Per-column nav bars each resolve their own traits; resolve dynamic colors
  against the column's own view (`resolvedColorWithTraitCollection:`), the same
  rule the theme runtime already enforces for `.CGColor` uses.
- Readable width: cap the secondary column's content at ~`UIView.
  readableContentGuide` behavior for very wide windows rather than letting
  comments stretch edge-to-edge on a 13" landscape iPad.

**Desktop-class polish (Phase 4, iOS 16+ where available)**
- `UIFindInteraction` for comments search (`isFindInteractionEnabled` on the
  scroll view) instead of extending Apollo's hand-rolled search toolbar.
- `UINavigationItem.style = .browser` on the supplementary/secondary columns'
  nav items is worth an experiment for density; it is cosmetic and safely
  gated on `respondsToSelector:`.
- Keyboard focus follows the responder chain — route Apollo's existing
  `keyCommands` (`selectNextCell`, `goIntoCell`, `goBack`, `pageUp`, …) by
  making the focused column's nav controller first responder, not by
  duplicating the commands.

## 7. Open questions

1. **Sidebar destinations rail styling** — a compact icon rail, a full-width
   list, or a segmented control at the top of the sidebar? Decide from the
   Phase 0 spike screenshots rather than on paper.
2. **Detail column empty state.** Apollo has no "no post selected" artwork.
   Options: a themed empty state, or auto-select the first post on load (Mail's
   behavior). Auto-select costs a network fetch on every subreddit change.
3. **Does the sidebar persist across tabs visually?** Per-tab duplication is the
   plan; verify it reads as stable in the spike.
4. **iOS 18+ `mode = .tabSidebar`** as an alternative destinations rail — worth
   revisiting only after Phase 3, and only if the hand-rolled rail feels wrong.
