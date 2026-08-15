# Implementation Plan: Feed Video Scrubber + Unmute Videos in Feed

Status: PLAN — written by the planning session, to be implemented by a coding session.
Branch: `claude/apollo-feed-video-scrubbing-6fbf66` (freshly reset onto `apollo-reborn/main` @ `d18a402`).
Delete this file (or move its content into the PR body) before the PR is marked ready, unless the user wants it kept.

Two independent features plus one native-settings shortcut row. Both features are
feed-video work and share helpers, but they must each work with the other toggled off.

---

## Feature A — Feed Video Scrubber (tap → inline progress bar → drag to scrub)

### UX spec (agreed with user)

- New toggle, **default OFF**: when ON, tapping a feed video that is *playing* does NOT
  open the fullscreen viewer. Instead it shows a small "player details" overlay at the
  bottom of the video: a progress bar + elapsed/total time. Dragging on the bar scrubs
  the video; tapping a point on the bar seeks there (tap-to-seek is REQUIRED — it is
  also the only scrub gesture idb can drive in the sim).
- While the overlay is visible, tapping the video anywhere *outside* the bar hides the
  overlay and opens the fullscreen viewer (normal behavior). So the viewer is always at
  most two taps away. The overlay also auto-hides after ~4s without interaction.
- Long-press context menu, the mute button, GIF play/pause badges, gallery carousels,
  and (fullscreen-only) hold-for-speed must all keep working. Note: hold-for-speed does
  NOT exist on feed videos (`ApolloVideoHoldSpeed.xm` installs only on
  `MediaViewerController`), so the feed tap gesture has no conflict with it.
- When the video is not playing / has no player / has an invalid duration (live or
  indefinite), the tap behaves natively (`%orig`). GIFs-as-video with a real finite
  duration MAY scrub too — keep the gate "player exists && duration finite && > ~1s",
  not "is not a GIF".
- Comments-header videos (`RichMediaNode.isShownInCommentsHeader == YES`): include them
  (same node class, same overlay); it costs nothing and is consistent. If it causes
  trouble, scope to feed only with that ivar — make it a single `static BOOL` gate so
  it's a one-line flip.

### Step 0 — verify the tap entry point (do this first, ~10 min)

The tweak does not currently hook the feed-video tap. Binary selectors on
`_TtC6Apollo13RichMediaNode`: `intermediaryNodeTappedWithSender:` (primary candidate —
`intermediaryNode` is the overlay node covering the media area),
`thumbnailTappedWithSender:`, `albumThumbnailButtonTappedWithSender:`,
`gifPlayPauseButtonTappedWithSender:`, `linkButtonTappedWithSender:`.

Verify empirically: `%hook RichMediaNode`, log + `%orig` in each candidate, run
`scripts/run-in-sim.sh`, tap a playing feed video, read the `apollofix` os_log. Confirm
which selector fires and that suppressing `%orig` suppresses the viewer. Optionally
cross-check in Hopper (`hopper-apollo`; the carousel handoff comment at
`src/ApolloFeedGalleryCarousel.xm:696-757` documents Apollo's viewer-open route
`sub_10058c634` / `sub_100321eac` — the video tap should funnel into the same area).
If the tap turns out to be an ASControlNode action rather than one of these selectors,
find the action selector via `idb describe-all` + runtime inspection before writing the
real hook.

### Implementation

**New file `src/ApolloFeedVideoScrubber.xm`**, registered in `Makefile`'s
`ApolloReborn_FILES` next to the video block (after `src/ApolloVideoUnmute.xm`,
Makefile:160-165 area). Works in sim builds (pure AVFoundation/UIKit — no
`APOLLO_SIM_BUILD` guards needed).

**Tap hook** (assuming `intermediaryNodeTappedWithSender:` verifies):

```objc
%hook RichMediaNode
- (void)intermediaryNodeTappedWithSender:(id)sender {
    if (!sFeedVideoScrubber) { %orig; return; }
    id videoNode = MSHookIvar<id>(self, "videoNode");           // via class_getInstanceVariable outside %hook
    AVPlayer *player = videoNode ? ApolloVideoUnmute_GetPlayerFromVideoNode(videoNode) : nil;
    if (!ScrubbableState(player)) { %orig; return; }            // no player / not started / bad duration
    if (OverlayVisibleOnNode(self)) { HideOverlay(self); %orig; return; }  // 2nd tap = open viewer
    ShowScrubOverlay(self, videoNode, player);                  // 1st tap = show bar, swallow tap
}
%end
```

`ScrubbableState`: player != nil, `player.currentItem` != nil, duration is numeric
(`CMTIME_IS_NUMERIC`, not indefinite), duration ≥ ~1s, and the video has actually
started (`rate > 0 || currentTime > 0.1s`). Player access MUST use
`ApolloVideoUnmute_GetPlayerFromVideoNode(videoNode)` (`ApolloVideoUnmute.xm:1406`) —
do not add a fourth copy of the player-walk helpers.

**Overlay UI** — one small container view added to the RichMediaNode's video area view
(`videoNode.view` or the richMediaNode's own view; pick whichever survives layout best
in the sim), tracked per-node via associated object:

- A custom **UIControl subclass** scrub bar (NOT UISlider — iOS 26 attaches a private
  `_UIFluidSliderInteraction` to every UISlider that plays a continuous scrub haptic;
  the repo already fought this in `ApolloIMDetentSlider`. A plain UIControl avoids it
  entirely). Track = full width minus insets, ~3pt visual height inside a ~28pt-tall
  touch strip; filled portion uses `ApolloThemeAccentColor() ?: tintColor ?: systemBlue`
  resolved with `resolvedColorWithTraitCollection:` against the in-hierarchy view before
  any `.CGColor` use; unfilled track = white/dim with a subtle dark backdrop
  (UIVisualEffectView or a 40%-black rounded rect) so it reads on bright video.
- Time labels: elapsed (left) and total duration (right), small
  monospaced-digit font, white with shadow or on the backdrop.
- Layout the bar so the native bottom-right mute button (`muteUnmuteButtonNode`) is not
  covered — either end the track before the button's x, or place the strip just above
  it. Verify visually in the sim; iterate with the user.
- Apollo's own thin feed progress strip (`RichMediaNode.videoGIFProgressView`, class
  `_TtC6Apollo20VideoGIFProgressView`, ivars `vibrancyEffectView`/`progressBarView`/
  `progress`) may already be showing on long videos. While our overlay is up, hide it
  (`hidden = YES` on its view) and restore on overlay teardown, so there aren't two bars.

**Progress updates** — `addPeriodicTimeObserverForInterval:CMTimeMake(1,4)` on the main
queue while the overlay is shown (PiP precedent at `ApolloPictureInPicture.xm:2208`).
Retain BOTH the token and the player it was added to; `removeTimeObserver:` must be
called on that same player instance on teardown (`ApolloPictureInPicture.xm:2221-2241`
shows the pattern). Re-resolve the player on every overlay show — shareable v.redd.it
players get swapped by fullscreen/comments round-trips.

**Scrub gesture** — stateless UIControl tracking (`beginTracking`/`continueTracking`/
`endTracking`), mapping x → fraction → `CMTime`:

- While dragging: throttled "chase" seeks — keep a `pendingSeekTime`; only issue
  `seekToTime:` (default tolerance) when no seek is in flight, issue the next from the
  completion handler. On end: one final `seekToTime:toleranceBefore:kCMTimeZero
  toleranceAfter:kCMTimeZero`.
- **Do NOT pause the player during the scrub.** Apollo has multiple
  capture-rate→restore-rate paths (fullscreen scrub, mute-dance unpause) and the
  hold-speed feature already got burned by rate-snapshot ordering (see
  `ApolloVideoHoldSpeed.xm:52-70`). Seeking a playing player avoids that entire class
  of bug.
- Tap-to-seek: a simple touch-down+up inside the bar with no movement seeks to that
  fraction (this is what idb can exercise).
- Any interaction (tap-to-seek, drag) resets the ~4s auto-hide timer.

**Competing gestures** (the risky part — budget sim time here):

1. Feed table (ASTableView) vertical scroll steal: `%hook` the feed table view class's
   `touchesShouldCancelInContentView:` → return NO when the view is our scrub control
   (class check), `%orig` otherwise. UIScrollView's default already returns NO for
   UIControls, but ASTableView may override — verify, and keep the hook either way as
   belt-and-braces. Accept the default `delaysContentTouches` ~150ms delivery delay
   (press-then-drag scrubbing feels fine; do NOT flip `delaysContentTouches` on Apollo's
   feed table globally — it changes every control in every cell).
2. Nav swipe-back + ancestor pans: on `beginTracking`, suspend the navigation
   controller's `interactivePopGestureRecognizer` and pan-like ancestors exactly the way
   `ApolloStatsRowTouch.xm`'s `SRTDisableCompetingPans` does (fetch the pop recognizer
   explicitly from the nav controller; also match class name containing
   "ParallaxTransition"). Restore on `endTracking`/`cancelTracking` AND unconditionally
   on overlay teardown — idb synthetic swipes never fire endTracking, and a
   restore-only-on-end design leaves state stuck (proven lesson from the inline-media
   slider work).
3. Non-glass shells: `hidesBarsOnSwipe`'s `_UIBarPanGestureRecognizer` cancelled raw
   overlay touches in the A–Z scroller work (PR #936, not yet merged). UIControl
   tracking is more robust than raw touches, but explicitly test the scrub on a
   NON-GLASS shell; if the bar pan steals the drag, suspend it in `beginTracking` with
   the same pattern as (2). If #936 merges first, reuse whatever it shipped.
4. Long-press context menu: we only handle discrete taps; the UIControl must not delay
   or cancel long-presses on the rest of the video (`cancelsTouchesInView` is a
   recognizer concept — with UIControl tracking confined to the bar's own bounds nothing
   outside the strip is affected). Verify long-press on the video still opens the menu
   with the overlay visible.

**Teardown paths** (all must remove the overlay, kill the timer, remove the time
observer, restore `videoGIFProgressView`, restore suspended gestures):

- Auto-hide timer fires.
- Second tap opens the viewer.
- Node goes invisible: hook `TouchHintVideoNode -didExitVisibleState` (note PiP already
  hooks this at `ApolloPictureInPicture.xm:3443`; a second `%hook` in another TU chains
  fine — ours runs, `%orig` reaches theirs or vice-versa depending on ctor order; do not
  fight over return values, just tear down our overlay and call `%orig`). Alternatively
  hook the cell-level `cellNodeVisibilityEvent` `event == 2`. Pick ONE.
- `RichMediaNode` dealloc safety: associated objects die with the node, but the timer
  and time observer must not outlive it — hold them in a small helper object whose
  `dealloc` cleans up (same pattern as hold-speed's handler `dealloc` fallback).

### Settings for Feature A

Follow the 5-step recipe in `src/settings/README.md` exactly:

1. `src/UserDefaultConstants.h`: `UDKeyFeedVideoScrubber = @"FeedVideoScrubber"` with a
   comment (BOOL, default NO).
2. `src/ApolloState.{h,m}`: `sFeedVideoScrubber` (default NO).
3. `src/Tweak.xm`: register `@NO` in `registerDefaults` (~:3429 block) and load with its
   neighbors (~:3553 block).
4. Row in `ApolloMediaSettingsViewController`'s Playback section
   (`CustomAPIViewController.m` `buildMediaPlaybackSection` :1672-1722): switch row
   `media.feedScrubber`, title **"Feed Video Scrubber"**, placed just before
   `media.unmuteComments`. Handler mirrors `proxyImgurDDGSwitchToggled:` (write global +
   defaults). Extend the section footer with one sentence ("Tap a playing feed video to
   show a scrub bar; tap again to open it fullscreen.").
5. Hook code reads `sFeedVideoScrubber`.

Do NOT touch `ApolloBackupRestore.m` (standardUserDefaults keys ride backups for free;
the statics re-sync list is intentionally partial).

---

## Feature B — Unmute Videos in Feed (Never / Remember / Always)

### UX spec (agreed with user)

New 3-option setting, mirroring the existing "Unmute Videos in Comments" pattern:

- **Never (default = current behavior):** feed autoplay stays muted. Manually tapping
  the mute button still unmutes that one video (native behavior); the next video is
  muted again.
- **Always:** every feed video is unmuted as it starts playing while you scroll — audio
  just plays. (Manual mute mutes that video; the *next* video still auto-unmutes,
  because the mode is Always.)
- **Remember:** a persisted bool remembers the user's last manual choice made via the
  feed mute button. Unmute one video → subsequent feed videos autoplay unmuted. Mute
  one again → subsequent videos autoplay muted. Only the FEED mute button writes this
  memory (fullscreen unmute is governed by Apollo's native "Unmute Videos When Opened";
  comments-header videos by "Unmute Videos in Comments" — don't cross the streams).

### Where the code goes

**Extend `src/ApolloVideoUnmute.xm`** — do NOT create a new module. Everything needed is
already there and mostly static/file-local:

- `UnmuteRichMediaNode()` (:461-529) — the full, correct unmute sequence: session
  `Playback`+active, `setMuted:NO` under `sIsAutoUnmuting`, videoNode `_muted` sync,
  `sAutoUnmutedPlayer` protection, `SyncMuteButtonIcon`, PiP yield calls.
- The three mute-dance shields keyed on `sAutoUnmutedPlayer` (AVPlayer `setMuted:` hook
  :1073, AVAudioSession hooks :1116, `ShouldProtectAudioSession()` :1112).
- `EnumerateVisibleRichMediaNodes` (:175) incl. crosspost nodes,
  `GetVideoNodeFromRichMediaNode` (:142), `SyncVisibleFeedMuteButtons` (:431).
- The existing `%hook RichMediaNode muteUnmuteButtonTappedWithSender:` (:769-851) —
  the exact place to record Remember-mode state.

### Trigger: "a feed video started playing"

Recommended primary: **hook `-[ASVideoNode play]`** (hooking the implementing class —
note `%hook TouchHintVideoNode` for an inherited method actually hooks ASVideoNode's
IMP, affecting ALL ASVideoNode instances, so gate carefully inside):

```text
on play:
  if sUnmuteFeedVideos == 0 → %orig only.
  walk supernodes to find the owning RichMediaNode
    (no RichMediaNode ancestor → fullscreen/other context → bail)
  if richMediaNode.isShownInCommentsHeader → bail (comments setting owns that)
  if PiP owns this player → bail
  if mode == Always, or (mode == Remember && FeedAudibleMemory() == YES):
    schedule ApplyFeedUnmute(richMediaNode) after a short delay (~200-500ms retry —
    the player may not be fully wired at play-time; the comments flow already retries
    3× at :531-558, reuse that shape)
```

`ApplyFeedUnmute` = transfer protection + unmute:

1. If `sAutoUnmutedPlayer` exists and is a *different* player: clear its protection
   (`ApolloVideoUnmute_ClearProtectionIfPlayer` or direct), explicitly
   `setMuted:YES` it, and `SyncMuteButtonIcon` its node (find via
   `EnumerateVisibleRichMediaNodes` + `RichMediaNodeContainsPlayer`). Exactly one feed
   player is audible at a time — no overlapping audio.
2. Call `UnmuteRichMediaNode(...)` for the new node/player.

Secondary triggers (both needed, both cheap):

- **Return from fullscreen / back-pop:** the same video keeps playing via a shared
  player and `play` may not fire again, while the mute dance has re-muted it. PiP
  already handles the analogous reclaim via feed-VC `viewDidAppear:` hooks
  (`ApolloPictureInPicture.xm:3696-3748`). Add our own `%hook` on the same six feed VCs
  (or a shared callout if cleaner *within this file*): after appear, find the visible
  midpoint-playing video and re-apply the mode. Delay ~300ms so the dance finishes
  first (the T+0/50/100ms sequence).
- **Visibility exit of the protected node:** when the audible video's node goes
  invisible (`event == 2` on its cell, or `didExitVisibleState`), clear
  `sAutoUnmutedPlayer` protection so the native dance can mute it and downgrade the
  session normally when no successor video starts (mirrors what the comments flow does
  on `event == 2` at :700-737). Without this, the session stays `Playback` and the
  `setMuted:` veto shields a player that should die.

### Remember-mode persistence

In the existing `muteUnmuteButtonTappedWithSender:` hook, after `%orig` and after the
existing logic: if the node is NOT `isShownInCommentsHeader` and
`sUnmuteFeedVideos == 1` (Remember), read the post-toggle muted state of the player and
persist `!muted` into `UDKeyFeedVideosUnmutedMemory`. Also:

- Manual unmute in Remember mode: additionally protect this player
  (`sAutoUnmutedPlayer = player` + session Playback via the same code path) so the
  dance doesn't immediately re-mute it, and mute/transfer away from any previously
  protected player.
- Manual mute (any mode): the existing code already clears protection before `%orig` so
  the tap isn't vetoed — keep that; in Remember mode also write memory = NO.
- Auto-unmutes must NOT write the memory — only genuine button taps do.

### Mode/value mapping and keys

Match the `sUnmuteCommentsVideos` convention (index == stored int):

- `UDKeyUnmuteFeedVideos = @"UnmuteFeedVideos"`, NSInteger: `0 = Never` (register `@0`),
  `1 = Remember`, `2 = Always`. Global `sUnmuteFeedVideos`.
- `UDKeyFeedVideosUnmutedMemory = @"FeedVideosUnmutedMemory"`, BOOL, register `@NO`.
  Read it live from defaults at decision time (cheap, avoids another global that can go
  stale across backup restore).

### Settings for Feature B

Same 5-step recipe. Row in the Playback section directly ABOVE "Unmute Videos in
Comments": value row `media.unmuteFeed`, title **"Unmute Videos in Feed"**, using the
shared picker exactly like :269-292 / :1690-1697:

```objc
ApolloSettingsPresentPicker(self, sourceView, @"Unmute Videos in Feed",
                            @[@"Never", @"Remember", @"Always"],
                            sUnmuteFeedVideos, ^(NSInteger idx){ ... });
```

`.configure = disclosure` for the chevron; detail block returns the current mode name.
Remember the picker fires `apply` even when re-picking the current option — keep the
apply idempotent. Extend the Playback footer with a sentence explaining
Remember/Always/Never (footer text is the right place per the user's style — rows stay
plain).

Routed screens are auto-indexed by settings search — no search bookkeeping.

---

## Native-settings shortcut row

In `src/settings/ApolloSettingsNativeInjections.xm`'s `%ctor` (:88-115), add a fifth
disclosure row using the existing helper — this is the "Picture-in-Picture anchored on
Manage Uploads" precedent, one line plus a cache key:

```objc
static const void *kApolloInjFeedUnmuteKey = &kApolloInjFeedUnmuteKey;
...
ApolloRegisterGeneralDisclosureRow(@"Unmute Videos in Feed",
                                   @"Unmute Videos When Opened",
                                   kApolloInjFeedUnmuteKey, @"media");
```

- Anchor: the native "Unmute Videos When Opened" row (native General screen, Media
  section — confirmed at `ApolloSettingsSearchNativeIndex.h:47`). Check
  `ApolloSettingsGeneralTable.h:39-60` for exact anchor/marker semantics; the title is
  unique in General so the section marker can be nil. The injected row lands adjacent
  to ("just below") the anchor.
- Route `media` already exists (`ApolloSettingsRouter.m:65`) and pushes
  `ApolloMediaSettingsViewController` — the screen holding the real picker. No new
  route (route ids are append-only public URL surface; reusing beats adding).
- The registry + NSProxy remapper make this safe against the native rows ("doesn't
  break the other settings" requirement); fail-soft if the anchor title is missing.
  NEVER `%hook` the native General table methods directly.
- Injected native rows theme from the donor cell, not the tweak base — the helper
  already handles this.

---

## Cross-cutting risks / review checklist

- `%orig;` passes ORIGINAL args — use explicit `%orig(...)` if any argument was
  modified (CLAUDE.md rule).
- `MSHookIvar` only inside `%hook`; use `class_getInstanceVariable` + `object_getIvar`
  in static helpers. `isShownInCommentsHeader` is a Swift Bool ivar — read by offset
  like `SyncMuteButtonIcon` does (:384-412), not via a getter.
- No layout-driving writes from `layoutSubviews` hooks (overlay positioning should be
  done on show + on a `visibleRectChanged` event or frame observation, not by hooking
  layout).
- PiP interplay: PiP hooks `cellNodeVisibilityEvent`, `didExitVisibleState`,
  `pause/unpauseAllAVPlayers…` and sometimes swallows `%orig`. Skip auto-unmute for
  PiP-owned players; call `ApolloPiP_YieldAudioToPlayer` / `_NoteInlineVideoAudible`
  exactly as `UnmuteRichMediaNode` already does (going through that function gives this
  for free). Test with a PiP session active.
- Open PR #796 (audio-session handback on viewer teardown) touches the same
  AVAudioSession territory — if it merges first, re-test the feed-unmute session
  protection around fullscreen open/close.
- The scrub overlay and feed-unmute must not regress: "Unmute Videos in Comments" (all
  3 modes), the search-results shareable re-resume (:820-851), the GIF inline overlay
  taps (`ApolloMediaAutoplay`), gallery carousel taps, and #934's gallery edge-swipe
  (now in main).
- Em-dash in `ApolloLog` format strings makes `strings | grep` miss them (UTF-16) —
  ASCII-only log lines for anything you'll grep.
- Deprecated-API warnings fail only sim builds (`-Wno-error=deprecated-declarations` is
  already set) — prefer non-deprecated APIs per CLAUDE.md.

## Verification matrix (all required before PR)

Standard three checks (standing rule) plus feature-specifics; sim first, device IPA for
the user after:

1. **Glass + keyless** (e.g. Sim3 container, `[WebJSON] Rewrote` lines confirm mode) and
   **API-key account** (account switcher = long-press profile tab). Both features are
   render/playback-side so modes should behave identically — verify anyway.
2. **Non-glass shell** (vtool-downgrade recipe from memory: `vtool -set-build-version 7
   15.0 16.0 -replace` on the prepped shell binary + re-codesign + `--no-build`; verify
   by pixels — labeled tab bar). Non-glass is where `hidesBarsOnSwipe`'s bar-pan lives —
   scrub-drag test is mandatory here.
3. Feature A: toggle OFF → taps unchanged. ON → tap shows bar (screenshot); tap-on-bar
   seeks (idb-testable: watch the time label / periodic-observer log); second tap opens
   viewer; long-press menu still appears; mute button still tappable; native
   `videoGIFProgressView` hidden while overlay up, restored after; overlay gone after
   scroll-away and after viewer open; no feed scroll-steal while dragging the bar
   (drag needs a real finger on device — idb swipes are unreliable for drags; sim
   validates tap-to-seek + layout, user validates drag feel on device).
4. Feature B: Never → unchanged. Always → scrolling plays each video with audio,
   exactly one audible at a time, icon syncs, audio stops when the video scrolls off
   with no successor. Remember → manual unmute then scroll = subsequent videos audible;
   manual mute then scroll = muted; state survives relaunch. Comments-header videos
   still governed by the comments setting. Fullscreen round-trip keeps the feed video
   audible in Always/Remember-on. PiP unaffected.
   **Sim audio caveat:** v.redd.it CMAF/MPEG-TS audio remux is FFmpeg (device-only,
   stubbed in sim) — pick test videos whose audio works in the sim (standard DASH
   v.redd.it, Streamable/RedGifs MP4s), and verify `player.muted` + session category via
   ApolloLog where the ear can't confirm.
5. Settings: rows render + persist on the Reborn Media screen; picker shows "(Current)";
   native General → Media shows the shortcut row below "Unmute Videos When Opened" and
   tapping it pushes the Reborn Media screen; the other native rows are unshifted;
   settings search finds "Unmute Videos in Feed" and "Feed Video Scrubber" with a
   Media breadcrumb; Backup → Restore round-trip keeps both settings + the Remember
   memory (they ride preferences.plist automatically).

## PR

- Push branch to `origin` (icpryde fork), PR against `Apollo-Reborn:main`.
- PR body: feature description in the user's casual voice (no Claude attribution,
  no Co-Authored-By per standing rule), screenshots of the overlay + the two settings
  rows + the native shortcut row, note device testing pending (drag-scrub feel +
  real-speaker audio need the user's device).
