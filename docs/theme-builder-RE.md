# Theme Builder — runtime RE notes

How the Theme Builder (src/ApolloThemeBuilder.xm + ApolloThemeBuilderViewController.m)
works and the runtime-derived data behind it. Companion to
docs/theme-creator-feasibility.md (the original spike that proposed this
approach).

## Why a donor-slot hijack

Apollo's `AppColorTheme` enum (18 cases incl. the hidden `chumbus`) resolves
every theme color in **stripped Swift switch statements** — there is no
data-driven storage to edit, no `@objc` getters, and the `*-color-theme`
asset-catalog images are only 25×25 preview swatches for the picker. All theme
colors funnel through `UIColor(red:green:blue:alpha:)` (one Swift thunk,
`0x1007530c8` in 1.15.11), which routes through ObjC `-[UIColor
initWithRed:green:blue:alpha:]` — a hookable choke point.

So the builder:

1. Selects **outrun** in Apollo's own theme system (group defaults key
   `AppColorTheme` = `"outrun"`, in-memory `ThemeManager.appColorTheme` raw
   byte = 5) — the donor slot.
2. Hooks the UIColor RGB constructors and, when the donor is active, swaps
   outrun's role constants for the user's colors. Matching is by exact RGB
   byte triple + alpha == 1.0 + call site inside the Apollo binary, and the
   replacement re-invokes `%orig` with substituted components so ownership and
   derived colors (alpha variants etc.) behave exactly like stock.

Outrun was chosen because its 14 constants (7 light + 7 dark) are distinctive
periwinkle/navy values with effectively zero collision risk against system
colors, other Apollo constants, or content. If the user picks a different
theme in Apollo's picker, the constants stop being produced, the remap
deactivates, and an `NSUserDefaults setObject:forKey:` hook clears the
enabled flag so the builder UI stays truthful.

## Live switching without relaunch

- `AppColorTheme` enum raw values are linear in declaration order (verified at
  runtime by logging the ivar byte against the group-defaults name on every
  switch): `default`=0, `nefertiti`=1, `fieryStare`=2, `spookyPumpkin`=3,
  `solarized`=4, `outrun`=5, `sunset`=6, `sepia`=7, `monochromatic`=8,
  `navy`=9, `skiesOnSkies`=10, `majesticPurple`=11, `magentasplosion`=12,
  `sniffingWalnut`=13, `fisherKing`=14, `chumbus`=15, `dracula`=16, `mint`=17.
- `ThemeManager` is captured via its ObjC-visible `-init` (no fishhook
  needed); enabling the custom theme writes raw byte 5 into the
  `appColorTheme` ivar.
- Repaints are forced by flipping each window's `overrideUserInterfaceStyle`
  for one runloop turn — this drives the same trait-change cascade as a system
  light/dark switch, and Apollo re-creates all theme colors on that path
  (verified: every theme getter re-fires on `simctl ui appearance` changes).
- Theme switches post **no NSNotification** (Combine publishers + a listeners
  NSHashTable internally); the defaults write to `AppColorTheme` is the only
  reliable observable marker. Apollo also writes `ChangedAppColorTheme_Date`
  (app domain) on each switch.

## Role model

Each role has one hardcoded constant per theme per mode. The "getter"
addresses below are the Swift switch-arm call sites observed in backtraces
(Hopper-style, Apollo 1.15.11) — note multiple arms can belong to one logical
getter. Roles were identified empirically by remapping each donor constant to
a garish color and screenshotting:

| Role key | Painted surfaces (empirical) | Light arm | Dark arm |
|---|---|---|---|
| accent | tint: buttons, links, selected tab, switches | 0x10068bd98 / 0x10068b9f8 | 0x10068bd24 / 0x10068b9f8 |
| primaryBG | cells/cards (light); full-screen content bg (dark) | 0x10068b014 | 0x10068b014 |
| secondaryBG | page background + nav/tab chrome wash | 0x10068b014 | 0x10068b014 |
| tertiaryBG | dimmed/auxiliary background | 0x10068d660 | 0x10068d660 |
| separator | row separators + search/input field fills | 0x10068d8e8 | 0x10068d8e8 |
| bar | bar backgrounds (pre-Liquid-Glass chrome) | 0x10068e538 | 0x10068e538 |
| gray | neutral gray (placeholders, disabled) | 0x10068cf48 | 0x10068cf48 |

Non-tinted themes (default, nefertiti, fieryStare, spookyPumpkin,
monochromatic, navy, skiesOnSkies, majesticPurple, magentasplosion,
sniffingWalnut, fisherKing, chumbus, mint) share stock neutrals and only vary
the accent. The five tinted themes (solarized, outrun, sunset, sepia, dracula)
have bespoke palettes for every role.

## Per-theme constants (1.15.11, runtime-captured)

Accents (light / dark):

| Theme | Light | Dark |
|---|---|---|
| default | 007AFF | 2399FF |
| nefertiti | 01A200 | 01A200 |
| fieryStare | FF0000 | FD0000 |
| spookyPumpkin | FF6200 | F25D00 |
| solarized | 268BD2 | 268BD2 |
| outrun | C400A6 | FF00D8 |
| sunset | FF6600 | FF7D00 |
| sepia | B88023 | D3AC72 |
| monochromatic | 000000 | FFFFFF |
| navy | 0058B8 | 0060C9 |
| skiesOnSkies | 00B5F2 | 01ADE8 |
| majesticPurple | 8800FF | 9C2CFF |
| magentasplosion | FF00B2 | E800A2 |
| sniffingWalnut | A74E00 | A74E00 |
| fisherKing | 808286 | 76787D |
| chumbus | F8F8F8 | 20242B* |
| dracula | 9760FF | AD81FF |
| mint | 37BB98 | 62DFA7 |

*chumbus dark becomes 000000 with UsePureBlackDarkMode (050505 with PureBlackModeReduceSmearing on top).

Tinted-theme palettes (primary/secondary/tertiary bg, separator, bar, gray):

| Theme | Mode | primary | secondary | tertiary | separator | bar | gray |
|---|---|---|---|---|---|---|---|
| solarized | light | FDF6E3 | E6DFCF | F2ECDA | E0DCCD | F1ECDC | CCCCCC |
| solarized | dark | 002B36 | 003745 | 00181F | 002836 | 00171F | 323740 |
| outrun | light | CFD7E8 | BAC1D1 | C1C8D9 | B5B9C7 | C5CAD9 | ABABAB |
| outrun | dark | 061636 | 081D47 | 041129 | 06214D | 031229 | 484E5B |
| sunset | light | FFE3D0 | F2D8C7 | (n/c) | E0CBBD | F1DACB | CCCCCC |
| sunset | dark | 000F29 | 12223D | (n/c) | 061B40 | 000B1F | 323740 |
| sepia | light | F1EAD9 | DBD5CA | E6DFCF | D4CEC0 | E6E0D1 | CCCCCC |
| sepia | dark | 211E1A | 38332C | 141310 | 29271F | 14130F | 323740 |
| dracula | light | F8F8F3 | EDEDE8 | (n/c) | D7D3E0 | E6E4EB | ABABAB |
| dracula | dark | 1A1D29 | 222636 | (n/c) | 242838 | 12141C | 484E5B |

Standard neutrals (all non-tinted themes): light FFFFFF / F2F3F7 / F8F8F8 /
EEEEEF / FBFBFB / CCCCCC; dark 131516 / 000000 / 1A1A1A / 232323 / 131516
(bar≈bg) / 323740. (n/c) = not captured during the mapping run.

Theme-independent constants (same across all themes — vote green 00B23B/00940F,
gray text 919191/84878C, separators C7C7CC/646466, link blue 94C6FF/45658D,
etc.) are intentionally not remapped.

## Text contrast (auto-derived) and opacity

A key finding from the second RE pass: **Apollo's tinted themes only retint
backgrounds + accent.** The secondary/tertiary *text* grays are
theme-independent neutral grays, emitted by shared getters regardless of the
active theme (verified via backtrace: getter `0x1002cbad8` above the central
UIColor thunk `0x1007530c8` produces `919191` in light / `84878C` in dark for
every theme; tertiary/metadata grays `666666`/`858585` come from
`0x100689f68`). Apollo's own themes stay legible only because their
backgrounds are light/muted. The builder lets the user pick saturated or dark
backgrounds, against which a fixed gray goes low-contrast (the original
illegible-secondary-text bug).

There are *many* such grays (secondary/tertiary text, icon tints, faint
usernames, timestamps, quoted text, separators), so enumerating constants is
brittle and never complete. Instead the fix is **generic** (`ApolloThemeBuilder.xm`,
all RGB-keyed — no hardcoded getter addresses on the hot path):

- **Auto-contrast neutral grays** (`NeutralGrayReplacement`): any color Apollo
  builds that is *near-neutral* (`max-min channel ≤ 8/255`) and not
  near-black/near-white (`0.10 < L < 0.92`) is re-mapped onto a contrast ramp
  against the user's `primaryBG` for the active mode (`sPrimaryLum[]`, Rec.709;
  mode from `UITraitCollection.currentTraitCollection`). The gray's relative
  prominence is preserved (faint stays subtle, strong stays strong) but it's
  forced onto the readable side of the background. Covers text *and* icon
  template tints in one rule. Also hooks `colorWithWhite:`/`initWithWhite:`
  (inherently neutral) through the same path.
- **Opacity**: the RGB match no longer requires `alpha == 1.0`. Role colors
  used at reduced opacity (overlays, pressed states) now remap too, with the
  original alpha preserved (`%orig(r,g,b, a)`).

Near-black/near-white are intentionally left alone (primary text,
white-on-accent, glyph fills); saturated colors (real theme/content colors,
vote green, link blue) are excluded by the neutrality test. Theme-tinted
bluish text grays (`9399A6`, `94969D`) come through the background getter
`0x10068b014` and aren't neutral, so they ride the background remap instead.

## Profile/menu glyph icons

The profile menu glyphs (Posts, Comments, Saved, Friends, ...) were the main
light-mode outlier. The signed-in profile list is not a UIKit table cell; it
is `Apollo.IconTextCellNode`, a Texture `ASCellNode` with `iconImage` and
`iconNode` (`ASImageNode`) ivars. Under the outrun donor, the light-mode glyph
image can arrive as original-rendered, so Apollo's normal tint write has no
visible effect. Stock light themes such as nefertiti and spooky pumpkin use
the same native row path with template-rendered glyphs and accent tint.

The builder fixes this at the narrow row boundary rather than by rewriting
arbitrary images: `_TtC6Apollo16IconTextCellNode` normalizes its `iconImage`
onto `iconNode` with `UIImageRenderingModeAlwaysTemplate`, then sets the node
and backing view tint to the active builder accent during layout. The UIKit
settings/action variants (`_TtC6Apollo21IconTextTableViewCell`,
`_TtC6Apollo23IconActionTableViewCell`) do the equivalent for their
`iconImageView`. This follows Apollo's native template+tint behavior without
touching content images or full-color settings icons.

## Persistence

- Tweak settings (standard defaults, ride into Backup/Restore zips):
  `ApolloRebornCustomThemeEnabled` (BOOL),
  `ApolloRebornCustomThemeColors` ({"<role>.<light|dark>": "RRGGBB"}).
- Apollo's own keys: `AppColorTheme` (group, theme name string), `Theme`
  (group, "light"/"dark"), `ChangedAppColorTheme_Date` (app domain).

## Re-running the mapping (new Apollo versions)

The instrumentation module `src/ApolloThemeRE.xm` is kept in-tree but only
builds with `APOLLO_THEME_RE=1`:

```bash
APOLLO_THEME_RE=1 scripts/run-in-sim.sh --glass
# tap through Apollo's theme picker (Settings → Appearance → Themes), both modes
xcrun simctl spawn "$(cat .sim/device.txt)" log show --last 10m \
  --predicate 'subsystem == "apollofix"' | grep ThemeRE
```

It logs every unique (constructor, RGBA, Apollo call site) with a short
backtrace, marks `THEME SWITCH -> <name>` sections via the `AppColorTheme`
defaults write, logs the `appColorTheme` raw byte per switch, and resets its
dedup table per switch so each theme re-logs its full constant set. Update the
`kSlots` table in ApolloThemeBuilder.xm and the preset palettes in
ApolloThemeBuilderViewController.m if constants move.

## Simulator gotcha (iOS 26.4 runtime)

`DYLD_INSERT_LIBRARIES` pointing into `~/Developer/...` is **silently
ignored** at app launch on the 26.4 simulator runtime (the same dylib loads
fine via in-process `dlopen`, and inserts from `/tmp` work). Workaround used
during this work:

```bash
cp .sim/ApolloReborn.dylib /tmp/ApolloRebornSim.dylib
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=/tmp/ApolloRebornSim.dylib \
  xcrun simctl launch "$(cat .sim/device.txt)" com.christianselig.Apollo
```
