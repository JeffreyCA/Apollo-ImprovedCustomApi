# AGENTS.md

## Project Overview

Apollo-Reborn is an iOS tweak for the Apollo for Reddit app that adds in-app configurable API keys and several bug fixes/improvements. Built using the Theos framework, it hooks into Apollo's runtime to provide custom API credential management, sideload fixes, and media handling improvements.

## Build & Development Commands

```bash
# Sync submodules (required before first build)
git submodule update --init --recursive

# Standard build
make package

# Build a local test IPA from the persistent Apollo base IPA
./patch.sh ./Apollo-base.ipa --liquid-glass -o /tmp/Apollo-base-liquid-glass.ipa
./build-ipa.sh --ipa /tmp/Apollo-base-liquid-glass.ipa --deb ./packages/<tweak>.deb -o ./packages/Apollo-Test.ipa
```

The Makefile automatically generates `src/Version.h` from the `control` file and links FFmpegKit libraries.
`THEOS` is available at `~/theos`. Do not rely on Azule/Cyan living in `/tmp`; `build-ipa.sh` uses the repo-local `scripts/inject-deb-local.sh` first for this repo's already-injected `Apollo-base.ipa` flow, then falls back to `azule`/`cyan` only for truly stock IPAs.

### Required SDK: iOS 26.0 pinned via `$THEOS/sdks` (device builds only)

`Makefile` sets `TARGET := iphone:clang:26.0:14.0` — the tweak still supports iOS 14 users, but newer Xcode betas (Xcode 27+, shipping the iOS 27 SDK) raised the SDK's own `MinimumDeploymentTarget` to iOS 15.0 (confirmed via `iPhoneOS.sdk/SDKSettings.json` → `SupportedTargets.iphoneos.MinimumDeploymentTarget`), so compiling with `latest` against that SDK can no longer target iOS 14.0 and additionally turns on `-Werror,-Wdeprecated-declarations` for several iOS-15-deprecated UIKit APIs the tweak still legitimately uses below that floor.

The fix is to pin the build to an iOS 26.0 SDK explicitly instead of `latest`, without touching the Xcode.app bundle. Theos merges SDK candidates from both `$THEOS_SDKS_PATH` (`$THEOS/sdks`) and Xcode's bundled SDK directory (see `$THEOS/makefiles/targets/_common/darwin_head.mk`), so dropping an `iPhoneOS26.0.sdk` folder into `$THEOS/sdks/` is enough — no Xcode reinstall or modification required.

**This same trick does not work for the simulator build** (`scripts/run-in-sim.sh`) — see the "Fast iteration in the iOS Simulator" section below for why pairing an old Simulator SDK with a newer clang is a real, blocked incompatibility rather than something to route around. The simulator script instead just bumped its own floor to iOS 15.0, which only affects local dev convenience, not real device support.

Because the device build (14.0) and simulator build (15.0) have different floors, code using an iOS-15-deprecated API (`UIApplication.windows`, `UIButton.contentEdgeInsets`/`imageEdgeInsets`, `adjustsImageWhenHighlighted`/`adjustsImageWhenDisabled`, etc.) only trips `-Wdeprecated-declarations` under the simulator target, not the device one. Theos turns on `-Werror` globally (`$THEOS/makefiles/common.mk`), so without intervention that warning would fail simulator-only builds. Rather than wrapping every call site in `#pragma clang diagnostic ignored "-Wdeprecated-declarations"`, `Makefile`'s `ApolloReborn_CFLAGS` carries `-Wno-error=deprecated-declarations` — this demotes the diagnostic back to a non-fatal warning (still visible in build output) without fully hiding it via `-Wno-deprecated-declarations`, and without needing a pragma anywhere. Prefer migrating off a deprecated API outright when there's a safe non-deprecated replacement (e.g. `ApolloAllWindows()` for `UIApplication.windows`); reach for the deprecated API only when the replacement (e.g. `UIButtonConfiguration`) isn't available at the device build's iOS 14 floor.

**If `$THEOS/sdks/iPhoneOS26.0.sdk` is missing on a local dev machine** (fresh setup, etc.), get it one of these ways, in order of preference:

1. **Extract from a locally installed Xcode 26.x** (most trustworthy — it's your own Apple-issued copy):
   ```bash
   cp -R "/Applications/Xcode_26.x.x.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk" \
         "$THEOS/sdks/iPhoneOS26.0.sdk"
   ```
2. **[theos/sdks](https://github.com/theos/sdks)** — the Theos org's own collection of extracted SDKs. Best-vetted third-party source, but only goes up to iOS 16.5 as of writing, so this source cannot be used for now.
3. **[xybp888/iOS-SDKs](https://github.com/xybp888/iOS-SDKs)** — broader version coverage (including iOS 26) and bundles private framework headers/symbols. Less centrally vetted than `theos/sdks` (an individual's repo, not Theos org), but SDK bundles are just headers/`.tbd` stubs/plists — nothing executes at build time — so the practical risk is "bad headers cause a miscompile," not a code-execution supply-chain attack. Reasonable to use when you need a version you can't extract yourself.

Whichever source, the result must land at `$THEOS/sdks/iPhoneOS26.0.sdk` (folder name matters — Theos matches `iPhoneOS<version>.sdk`) for `TARGET := iphone:clang:26.0:14.0` to resolve. Verify with:
```bash
xcodebuild -showsdks 2>&1  # confirms what Xcode itself sees (won't show $THEOS/sdks entries)
ls "$THEOS/sdks/"          # confirms Theos has it
```
This SDK lives outside the repo (`$THEOS/sdks` is a local Theos install path, not checked into git) — a new contributor needs to repeat this step once.

**CI does this differently.** The GitHub Actions `macos-15` runner image ships several Xcode versions side by side, including `/Applications/Xcode_26.0.1.app` (full iOS 26.0 SDK included) alongside the default active Xcode (16.4, which doesn't have it). So the build/release/PR-build workflows just run `sudo xcode-select -s /Applications/Xcode_26.0.1.app` before `make package`, rather than copying anything into `$THEOS/sdks`. This is simpler than the local-dev approach and carries no version-skew risk for CI specifically, because the runner's default Xcode is *older* than 26.0.1, not newer — switching to it is a strict upgrade of the whole toolchain, not a deliberate old-SDK/new-clang pairing the way the local dev setup is. (That pairing risk is real, though — see the Simulator SDK note above — so don't reach for a global `xcode-select` switch on a machine where the default Xcode is *newer* than the SDK you need.)

### Fast iteration in the iOS Simulator

For UI/settings/nav-bar/Liquid Glass work, `scripts/run-in-sim.sh` runs the tweak inside the iOS Simulator so you can test a change in seconds without building an IPA, signing, or sideloading. **Use this as the default inner loop**; fall back to a device IPA only for the things the simulator can't do (see limits below).

```bash
scripts/run-in-sim.sh              # build the sim tweak, (re)prepare Apollo, launch it injected
scripts/run-in-sim.sh --no-build   # relaunch without rebuilding the tweak
scripts/run-in-sim.sh --logs       # also stream ApolloLog (os_log subsystem "apollofix") after launch
scripts/run-in-sim.sh --drive      # after launch, capture the idb accessibility tree + a screenshot to ./.sim/
scripts/run-in-sim.sh --fresh-app  # re-patch the base IPA from scratch (after a new apollo-base.ipa)
scripts/run-in-sim.sh --dark       # boot the simulator in dark mode (--light forces light)
scripts/run-in-sim.sh --glass      # apply the iOS 26 Liquid Glass patch (--no-glass disables)
scripts/run-in-sim.sh --backup B.zip  # preload an Apollo settings backup (API keys + account)
BUNDLE_ID=com.you.Build scripts/run-in-sim.sh   # run under a custom (rebranded) bundle id
```

How it works (and why each piece is needed):

- **Apollo runs in the sim** because the script patches every Mach-O in `Payload/Apollo.app` (main binary + appex + frameworks) from `LC_BUILD_VERSION` platform iOS (2) to iOS-Simulator (7) and re-signs ad-hoc. The arm64 code is identical on an Apple Silicon Mac; only the platform tag blocks loading. This shell is cached under `./.sim/` and only re-prepared on `--fresh-app`.
- **The tweak is built for the sim** with `make TARGET=simulator:clang:latest:15.0 LOGOS_DEFAULT_GENERATOR=internal APOLLO_SIM_BUILD=1`. Unlike the device build, this deliberately uses `latest` rather than pinning to an older SDK: a simulator binary runs in-process on the build host, dynamically linking against *this Mac's actual* libSystem/Foundation/libc++, not a separate per-version runtime the way a real device has its own matching system libraries. Pairing the iOS 26.0 Simulator SDK with a newer (iOS 27-era) clang hits a hard, intentional block — `module '_c_standard_library_obsolete' requires feature 'found_incompatible_headers__check_search_paths'` — which is Apple's clang correctly refusing a genuinely unsafe combination, not a quirk to route around. So the simulator build's floor was bumped to iOS 15.0 (`DEPLOY_MIN` in `scripts/run-in-sim.sh`) instead of SDK-pinning like the device build does; this only affects local dev/testing convenience, not real iOS 14 device support (which is fully covered by the shipped device build's `iphone:clang:26.0:14.0` target). The *internal* Logos generator swizzles via the ObjC runtime, so the dylib has **no CydiaSubstrate dependency** (the shipped device build links CydiaSubstrate, which can't load in the sim). `APOLLO_SIM_BUILD=1` makes the Makefile skip device-only **FFmpegKit** and the FLEX/openin subprojects, and `ApolloMedia.xm` stubs its FFmpeg v.redd.it audio fix under the same macro. `MSHookIvar` still works (it's a header-only ObjC-runtime template, force-included via `-include substrate.h`).
- **The tweak is injected** via `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` pointing at `./.sim/ApolloReborn.dylib`. Code-only changes are just `scripts/run-in-sim.sh` again (rebuild + relaunch); no reinstall.
- **The bundle id is configurable** via `BUNDLE_ID=...` (defaults to `com.christianselig.Apollo`). When it differs from the cached shell's id, the script re-prepares and rebrands the app + every appex `CFBundleIdentifier` (mirroring `scripts/rebrand-ipa.sh`; the `apollo://` scheme and the `group.com.christianselig.apollo` app group are left intact). Switching ids forces one re-prep (~15s), then caches. Device/runtime are overridable via `SIM_NAME`, `SIM_DEVICE_TYPE`, `SIM_RUNTIME`.
- **Settings backups preload via `--backup file.zip`** (or `BACKUP_ZIP=...`, or by dropping the zip at `./.sim/backup.zip`, which is auto-loaded when no `--backup` is given): the script uninstalls first (wiping the data container + cfprefsd cache), reinstalls, then copies the backup's `preferences.plist` to `<container>/Library/Preferences/<BUNDLE_ID>.plist`, `group.plist` to `…/group.com.christianselig.apollo.plist`, and (if present) `keychain.plist` to `…/Library/Caches/ApolloKeychainSeed.plist`. In the simulator both the app and app-group domains live in the app data container (the group suite falls back there without full app-group provisioning), matching the tweak's own `NSHomeDirectory()`-based restore path. **A backup contains live account credentials; keep test zips out of the repo** (`./.sim/` is gitignored).
  - **What loads:** the API keys (Reddit/Imgur/Giphy/ImageChest), the app-only OAuth session, **and your signed-in Reddit user account** — so profile, inbox, and voting work, not just browsing.
  - **How the account restore works (and why it used to fail):** Apollo's `AccountManager` loads logged-in accounts on launch from the **keychain via Valet** (key `2RedditAccounts2`), and the *whole* load is gated behind `Valet.canAccessKeychain()`. An ad-hoc-signed simulator app has no `application-identifier`/`keychain-access-groups` entitlement, so securityd rejects every `Sec*` call with `errSecMissingEntitlement` (-34018) even after we strip `kSecAttrAccessGroup` — `canAccessKeychain()` returns NO, the load is skipped, and the restored account is pruned (`RedditAccounts2` ~50KB → ~219-byte empty array). Adding the entitlement is a dead end (the iOS-26 simulator refuses to launch an ad-hoc app carrying it). **Fix:** the tweak virtualizes Valet's keychain in the sim (`#if APOLLO_SIM_BUILD` in `Tweak.xm` — a plist-backed store under `Library/Caches/ApolloSimKeychain.plist` that backs `SecItemAdd/CopyMatching/Update/Delete` for Valet queries, so `canAccessKeychain()` passes and reads/writes work). The account blob can't be synthesized from the NSUserDefaults mirror — Apollo's keychain format is an array of `[String:String]` dicts, not the `[RDKClient]` archive the defaults hold — so `Backup Settings` now **captures Apollo's real Valet keychain items** (`src/settings/ApolloBackupRestore.m` → `keychain.plist`), and the sim seeds the virtual store from them. **Requires a backup exported by a build with this feature**; older backups have no `keychain.plist` and the account won't restore (the script prints a note). Device restore replays the same items into the real keychain.
- **Appearance** is set with `xcrun simctl ui <DEV> appearance dark|light` via `--dark`/`--light` (or `APPEARANCE=`); it persists on the device until changed.
- **Liquid Glass** is off by default (the raw `apollo-base.ipa` links against the iOS 16 SDK, so `IsLiquidGlass()` is NO and both UIKit's iOS-26 chrome and the tweak's LG hooks stay dormant). `--glass` (or `GLASS=1`) prepares the shell from a `patch.sh --liquid-glass` base — the canonical glass patcher, reused so it stays in sync: it bumps the main binary's linked SDK to iOS 26 (which flips `IsLiquidGlass()`, since `GetLinkedSDKVersion()` reads that field), drops the duplicate `@executable_path/Frameworks` LC_RPATH (iOS-26 dyld rejects it — otherwise the launch dies with an `SBMainWorkspace` denial), swaps in the prebuilt `Assets.car`, and writes the `CFBundleAlternateIcons` metadata that turns on the in-app icon picker. The glass base is cached at `./.sim/glass-base.ipa` (regenerated only when `apollo-base.ipa` changes); toggling `--glass`/`--no-glass` re-prepares the app shell (detected from the cached main binary's SDK).

**Verify the tweak actually loaded** (don't assume from a clean launch): check os_log for the `apollofix` subsystem — module load lines and `... hook installed ...` confirm the internal-generator hooks took:

```bash
xcrun simctl spawn "$(cat .sim/device.txt)" log show --last 2m --predicate 'subsystem == "apollofix"' | grep ApolloFix
```

**Driving the UI yourself (idb):** `brew install facebook/fb/idb-companion`. The `fb-idb` Python client breaks on Python 3.12+ (`asyncio.get_event_loop()` was removed), so install it into a **Python 3.11 venv** (`uv venv ~/.idb-venv --python 3.11 && uv pip install --python ~/.idb-venv/bin/python fb-idb` is the easiest path) and point the script at it: `IDB=/path/to/venv/bin/idb scripts/run-in-sim.sh --drive`. Useful idb commands: `idb ui describe-all --udid <DEV>` (accessibility tree with labels + frames), `idb ui tap <x> <y>`, `idb ui text "..."`, `idb screenshot --udid <DEV> out.png`. Read screenshots back to confirm visual changes.

**Xcode 27 / Device Hub:** Simulator.app is now Device Hub (`com.apple.dt.Devices`); `run-in-sim.sh` opens whichever exists. `--drive` captures its screenshot via `simctl io screenshot` instead of `idb screenshot` — idb_companion's screenshot RPC fails ("No Image available to encode") against Xcode 27's iOS-27 sims, while `idb ui describe-all` still works. idb's HID commands (`idb ui tap`/`text`/swipe) are currently broken under Xcode 27 — idb_companion 1.1.8 looks for `SimulatorKit.framework` at the pre-27 path (`Contents/Developer/Library/PrivateFrameworks/`), which moved to `Contents/SharedFrameworks/`, and Xcode.app is write-protected so the path can't be symlinked back. Drive taps manually in Device Hub until idb_companion is updated.

**Simulator limits — use a device IPA for these:** APNs push (so Live Activities push-to-start can't be exercised in the sim), the FFmpeg v.redd.it CMAF/MPEG-TS audio remux (stubbed out), and anything genuinely device-only. (A signed-in user account *does* work in the sim now, via the keychain-capture backup above — provided the backup was exported by a build with that feature.) The sim *is* the same iOS 26.x family as the test device, so Liquid Glass nav-bar/tab-bar behavior reproduces faithfully.

## Project Structure

### Core Tweak Modules

| Path | Purpose |
|------|---------|
| `src/Tweak.xm` / `src/Tweak.h` | Main tweak entry point and core runtime hooks |
| `src/Apollo*.xm` | Feature-focused Logos modules; see `Makefile` for the current build list |
| `src/ApolloCommon.{h,m}` | Shared utilities, including `ApolloLog` and helper functions |
| `src/ApolloState.{h,m}` | Global state, captured singletons, and feature flags |

### Settings & UI (`src/settings/`)

Tweak-owned settings screens live under `src/settings/` and are built on a
declarative form layer — rows are data, indices are derived, no index math in
screens. See `docs/settings-form-refactor-plan.md`.

| Path | Purpose |
|------|---------|
| `src/settings/ApolloSettingsForm.{h,m}` | Declarative row/section model + `ApolloSettingsFormViewController` base (visibility snapshot + diff, identity-based reloads, shared "(Current)" picker). Subclass, override `-buildForm`. |
| `src/settings/ApolloSettingsTableViewController.{h,m}` | Theming base (accent walk) all settings screens share |
| `src/settings/CustomAPIViewController.{h,m}` | Root "Apollo Reborn" settings screen (API keys, General, Media, Subreddits, About, ...) — a form subclass |
| `src/settings/ApolloBackupRestore.{h,m}` | Backup/restore engine (zip build, plist replay, Valet keychain capture/replay); the VC keeps only the UI |
| `src/settings/ApolloContributors.{h,m}` + `ApolloThanksTo`/`ApolloBuyUsACoffee` VCs | contributors.json fetch/parse + the two About screens (dynamic lists, hand-rolled) |
| `src/settings/ApolloSettingsGeneralTable.{h,xm}` | Single owner of Apollo's NATIVE Settings > General table geometry (row hide/inject registry + NSProxy remapper) — for the table we don't own |
| `src/settings/SavedCategoriesViewController.{h,m}` | Saved post categories CRUD (add/rename/delete, stored in group NSUserDefaults; not a form — dynamic list) |

**Working on settings? Read `src/settings/README.md` first** — it has the 5-step add-a-setting recipe, the form-layer rules, and the Eureka facts. The hard rules: tweak-owned screens declare rows in `-buildForm` (never hand-rolled index math); Apollo's native General screen is modified ONLY through `ApolloSettingsGeneralTable`'s registry (never `%hook` its table methods — one remapper per screen); new settings do NOT get added to `ApolloBackupRestore`'s statics re-sync (restore force-exits; `%ctor` re-reads on relaunch).

### Runtime & Libraries

| Path | Purpose |
|------|---------|
| `src/fishhook.{c,h}` | Facebook's fishhook for C function rebinding (Security framework, `swift_allocObject`) |
| `modules/ffmpeg-kit/` | FFmpegKit static libs for v.redd.it CMAF video processing |
| `modules/ZipArchive/` | SSZipArchive for settings backup/restore zip export |
| `modules/FLEXing/` | FLEX debugging tools (git submodule) |

### Reference & Build

| Path | Purpose |
|------|---------|
| `Headers/` | Class-dump headers for Apollo |
| `packages/` | Build output (.deb files) |
| `control` | Debian package metadata (name, version, depends) |
| `Makefile` | Theos build config; auto-generates `src/Version.h`, links FFmpegKit |

## Theos & Logos Conventions

- Use Logos directives (`%hook`, `%orig`, `%group`, `%ctor`) for runtime patches
- Use `%hookf` for C function hooks
- Register new source files in `Makefile` under `ApolloReborn_FILES`
- Keep related hooks grouped together
- **`%orig` passes original arguments**: `%orig;` always calls the original method with the original captured arguments, even if you've reassigned the local parameter variables. To pass modified values, use explicit arguments: `%orig(arg1, modifiedArg2, arg3)`. This matters when normalizing URLs in blocks/callbacks — the ignoreHandler must use `%orig(textNode, attr, val, point, range)` not bare `%orig;` if `val` was modified.
- **`MSHookIvar` only works inside `%hook` blocks**: It's a Logos macro. In static helper functions, use `class_getInstanceVariable` + `object_getIvar` from the ObjC runtime instead.
- **Avoid layout-driving writes inside `layoutSubviews` hooks**: Writing `frame`, `bounds`, `layoutMargins`, `separatorInset`, stack spacing, or other Auto Layout inputs from `layoutSubviews` can loop during rotation. Do one-shot row/cell prep from non-layout entry points such as `tableView:willDisplayCell:forRowAtIndexPath:` and clear flags in `prepareForReuse`.

## Code Style

- **Indentation**: 4 spaces
- **Braces**: Same line as statement
- **Logging**: Use `ApolloLog` for privacy-friendly diagnostics
- When iterating on a feature, if something isn't working, prefer outright replacing the implementation over adding fallback codepaths. Use generous amount of comments and diagnostic/debug logging.

## Theme Accent in Tweak-Drawn UI

- Any accent color in tweak-drawn UI comes from `ApolloThemeAccentColor()` (`ApolloThemeRuntime.h`): the custom theme's accent when one is active, else the stock Apollo theme's (all 18 themes; `kStockThemes` table in `ApolloThemeRuntime.xm`, values recovered from the binary — see docs/theme-builder-RE.md). Chain as `ApolloThemeAccentColor() ?: someView.tintColor ?: systemBlue`; never hand-roll nav/tab-bar tintColor walks (they only ever approximated the accent).
- `UIView.tintColor` never returns nil for a real view (it inherits, bottoming out at system blue) — a fallback arm after a guaranteed-non-nil tint read is dead code. Nil only arrives via messaging a nil view, which is what the `?: systemBlue` tail covers.
- The returned accent is a dynamic provider color. Before any `.CGColor` use (layer borders, ASDK background-thread layout), resolve it with `resolvedColorWithTraitCollection:` against an in-hierarchy view's traits — ambient resolution can pick the wrong light/dark variant when Apollo overrides the window style.
- Text drawn on an accent fill needs `ApolloColorIsLight()` (ApolloCommon) to choose black vs white — stock monochromatic (dark) and chumbus (light) accents are near-white.

## Testing

No automated test suite, must be validated manually.

## RE Notes

### Handy Hopper MCP Tools

- `Hopper/list_documents`, `Hopper/set_current_document`: select `Apollo.hop`
- `Hopper/goto_address`: jump to an address (static address Hopper uses)
- `Hopper/current_procedure`: find which function the current address is in
- `Hopper/procedure_pseudo_code`, `Hopper/procedure_assembly`: decompile/disassemble the function
- `Hopper/search_procedures`: find functions by name/regex (works well for ObjC methods)
- `Hopper/search_strings`: search embedded strings (bundle IDs, selectors, product identifiers, URLs)
- `Hopper/xrefs`: find references to a string or address
- `Hopper/list_segments`, `Hopper/list_names`: quick orientation for the binary layout
- `Hopper/procedure_callers`, `Hopper/procedure_callees`: trace call graphs (who calls this? what does this call?)

### Effective Hopper Investigation Patterns

**Discovering class layout via `.cxx_destruct`**: Search for `-[ClassName .cxx_destruct]` and decompile it. This reveals every ivar in the class, their types (ObjC objects use `objc_release`, Swift structs use type metadata accessors, bridged objects use `swift_bridgeObjectRelease`), and their ivar offset symbols. This is the fastest way to understand a Swift class's storage layout from ObjC.

**Tracing from a known entry point**: When you know the ObjC method (e.g. `linkButtonTappedWithSender:`), decompile it to find the `sub_XXXX` helper it delegates to. Then decompile that helper. This "peel the onion" approach is how you find the actual navigation/logic functions buried under Swift thunks.

**Fix transition bugs at the source**: For media/navigation regressions, start from the method that initiates the behavior (`commentsButtonTapped:`, `didExitVisibleState`, reclaim helpers, MediaViewer dismiss callbacks) and trace forward in Hopper before adding new hooks. In this repo, the durable fixes usually came from understanding the native transition or async completion block first, not from stacking more downstream notification hooks.

**Identifying Swift property access patterns**: Swift stored properties on classes don't always have ObjC getters. Check `search_procedures` for the class — if no `-[Class property]` method exists, the property is NOT `@objc`-visible. You'll need alternative access strategies (reading from display nodes, using runtime ivar access, etc.) rather than `objc_msgSend`.

**Reading Swift function calls in pseudocode**: Hopper labels Swift stdlib/Foundation calls like `Foundation.URL.absoluteString.getter()`, `Swift.String._bridgeToObjectiveC()`, etc. These tell you what types are in play even when the pseudocode is hard to follow. Look for these labels to understand data flow.

**Pseudocode constant folding of base registers**: Hopper's decompiler sometimes loses track of a base register and folds it into offset constants, producing misleading absolute-looking addresses. For example, if the assembly is `madd x8, x21, x8, x22` then `str w0, [x8, #0x20]` (meaning `buffer + index*stride + 0x20`), the pseudocode may render this as `*(stride * index + 0x50)` — collapsing `buffer + 0x20` into a single constant `0x50`. This is a critical trap: the pseudocode appears to say elements start at offset 0x50, when they actually start at buffer+0x20. **Always verify struct/array element offsets from the raw assembly** (look for `madd`/`add` base register calculations and `ldr`/`str` displacement operands) rather than trusting the pseudocode constants.

**Decoding Swift small strings from assembly**: Strings <=15 bytes are stored inline in two registers (x0/x1) rather than as heap pointers. Hopper's decompiler hides the actual values behind `_bridgeToObjectiveC()` calls — you must read the raw assembly. Layout: x0 holds bytes 0-7 (little-endian), x1 holds bytes 8-14 in bits 0-55 plus a discriminator byte in bits 56-63 (discriminator = `0xE0 + length`). Each `mov`/`movk` with `#0xXXYY` stores two ASCII bytes in little-endian order (YY first, XX second). Strings >15 bytes use buffer pointers (`x1 = addr | 0x8000000000000000`, UTF-8 at `addr+0x20`) and appear in Hopper's string table. See `docs/sekrit-icon-keys-RE.md` for a worked example.

**Extracting Swift enum metadata from jump tables**: Swift switch helpers for enum titles/icons often compile to a small dispatcher that masks the enum case, loads a jump-table offset, adds it to a code base, then `br`s there. In assembly this looks like `and x8, x0, #0xffff` + `ldrh/ldrsw` from a table + `add x10, base, offset` + `br x10`. To replace a private helper safely, extract the table data and emulate each target block offline instead of calling a hardcoded app address at runtime. For the Apollo action menu metadata this recovered the exact `actionKind -> title/icon asset` mapping used in `ApolloNativeActionMetadata.h`.

**Emulating simple Swift string-returning blocks**: For switch arms that return strings, a tiny ARM64 emulator is often faster and safer than manual transcription. Use the Mach-O `__TEXT` base (`0x100000000` for Apollo) to map `vmaddr -> file offset`, read the jump table bytes, then emulate the small instruction subset used by these blocks: `mov`, `movk`, `adrp`, `adr`, `add`, `sub`, `orr`, `b`, `ret`, and sometimes `bl` to a known Swift/Foundation bridge or image-loading helper. Decode x0/x1 as a Swift small or long string. Validate a few known UI strings via `Hopper/search_strings`/xrefs before trusting the generated table.

**Avoid runtime calls to private binary helper addresses**: Hardcoded Apollo helper addresses like `0x1007xxxxx` can appear to work, but they are version-fragile and can crash or silently mislabel UI when the app binary shifts. Prefer one of: ObjC-visible selectors, stable ivar data, generated metadata tables checked into the tweak, or hook/capture points around the original call path. If a generated table is used, include a source note and spot-check entries whose labels/icons are user-visible.

### iOS 26 Runtime Headers And Decompiled Internals

Two external repos are useful to reference for Liquid Glass / iOS 26 work. Both are gitignored — clone them into the repo root before starting:

```bash
git clone https://github.com/qingralf/iOS26-Runtime-Headers.git

# Full repo is huge; sparse-checkout just UIKitCore.framework.
git clone --depth 1 --filter=blob:none --sparse https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore.git
cd iPhone18-3_26.1_23B85_Restore
git sparse-checkout set System/Library/PrivateFrameworks/UIKitCore.framework
cd ..
```

- `iOS26-Runtime-Headers/` — RuntimeBrowser-style ObjC headers for every framework. Use to discover ivars, properties, and selectors on private classes (e.g. `_UINavigationBarTitleControl`, `_UINavigationBarContentViewLayout`).
- `iPhone18-3_26.1_23B85_Restore/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore/` — IDA-style decompilation of UIKitCore as one `.mm` file per class. Use to read actual setter/method bodies (e.g. checking whether a setter is a synthesized ivar setter or actually does work). UIKitCore is the most useful framework here for nav bar / tab bar / Liquid Glass investigations.

### Mapping Runtime PCs To Hopper Addresses

Crash logs typically show:

- A loaded image base, e.g. `Apollo 0x10444c000 + 7746680`
- A program counter (PC), e.g. `0x104baf478`

The offset is `PC - imageBase`. Hopper usually uses a Mach-O "file base" of `0x100000000`, so:

- `hopperAddr = 0x100000000 + (PC - imageBase)`

Once you have `hopperAddr`:

- `Hopper/goto_address` -> `Hopper/current_procedure` -> decompile around the trap/crash site.

### Symbolicating User Crash Reports With Release dSYMs

Release IPAs are built with `FINALPACKAGE=1`, so the shipped tweak dylib is optimized and stripped. Public release IPAs always come from the `Apollo-Reborn/Apollo-Reborn` release workflow:

```text
https://github.com/Apollo-Reborn/Apollo-Reborn/actions/workflows/release-ipa-variants.yml
```

That workflow publishes a matching `*-dSYMs.zip` release asset alongside the IPA/deb assets; use that dSYM for `.ips` reports instead of asking users to reproduce on debug builds.

First identify the release that produced the user's IPA from the IPA filename, release tag, or app/tweak version shown in the `.ips`. Then download and unpack symbols with `gh`:

```bash
mkdir -p /tmp/apollo-reborn-symbols
gh release download <release-tag> \
  --repo Apollo-Reborn/Apollo-Reborn \
  --pattern '*-dSYMs.zip' \
  --dir /tmp/apollo-reborn-symbols
unzip -q /tmp/apollo-reborn-symbols/*-dSYMs.zip -d /tmp/apollo-reborn-symbols/unpacked
find /tmp/apollo-reborn-symbols/unpacked -name 'ApolloReborn.dylib.dSYM' -type d
```

If the tag is unknown, inspect recent releases and asset names:

```bash
gh release list --repo Apollo-Reborn/Apollo-Reborn --limit 20
gh release view <release-tag> --repo Apollo-Reborn/Apollo-Reborn --json assets --jq '.assets[].name'
```

For tweak frames like:

```text
ApolloReborn.dylib  0x103bbca90 0x103ad4000 + 952976
```

1. Match the `ApolloReborn.dylib` UUID in the `.ips` `usedImages` / `binaryImages` section against:

```bash
dwarfdump --uuid /tmp/apollo-reborn-symbols/unpacked/symbols/rootful/ApolloReborn.dylib.dSYM
```

2. Symbolicate every `ApolloReborn.dylib` frame from the crashed thread:

```bash
atos -arch arm64 \
  -o /tmp/apollo-reborn-symbols/unpacked/symbols/rootful/ApolloReborn.dylib.dSYM/Contents/Resources/DWARF/ApolloReborn.dylib \
  -l 0x103ad4000 \
  0x103bbca90
```

Use the image load address as `-l` and the frame PC/address as the final argument. If the crash only provides an offset, compute `address = imageLoadAddress + offset`. Once frames resolve to source files/lines, investigate the Logos hook/block at that location and use the rest of the crashed thread plus exception type to infer runtime state.

### Swift Struct Ivars and iOS Version Pitfalls

Swift value types (structs like `Foundation.URL`) stored as ivars in a class are laid out inline — they are NOT object pointers. `MSHookIvar<NSURL *>` on a `URL` ivar works by accident on older iOS (where `URL`'s first field happened to be an `NSURL *`) but breaks when Apple changes the struct layout (e.g. iOS 26 swift-foundation changes). When you need data from a Swift struct ivar:

1. Check if there's an `@objc` getter (search Hopper for `-[Class property]`)
2. If not, look for ObjC display nodes or other ObjC objects that hold the same data (e.g. `urlTextNode.attributedText.string` for a URL shown in a button)
3. As a last resort, study the struct layout via `.cxx_destruct` and the type metadata accessor

### Capturing Swift Singletons via fishhook

Pure Swift classes (no ObjC-visible methods) that use `dispatch_once` singletons can't be accessed through normal hooking. Use `fishhook` to briefly hook `swift_allocObject`, match on the class's type metadata pointer (which equals the `objc_getClass` result for Swift classes), capture the instance, and immediately unhook:

```objc
static __unsafe_unretained id sSingleton = nil;
static void *sTargetMetadata = NULL;
static void *(*orig_swift_allocObject)(void *type, size_t size, size_t alignMask);

static void *hooked_swift_allocObject(void *type, size_t size, size_t alignMask) {
    void *obj = orig_swift_allocObject(type, size, alignMask);
    if (type == sTargetMetadata && !sSingleton) {
        sSingleton = (__bridge id)obj;
        rebind_symbols((struct rebinding[1]){{"swift_allocObject", (void *)orig_swift_allocObject, NULL}}, 1);
    }
    return obj;
}

// In %ctor:
sTargetMetadata = (__bridge void *)objc_getClass("_TtC6Module12ClassName");
if (sTargetMetadata) {
    rebind_symbols((struct rebinding[1]){{"swift_allocObject", (void *)hooked_swift_allocObject, (void **)&orig_swift_allocObject}}, 1);
}
```

Once captured, access ivars via `class_copyIvarList` + `object_getIvar` (by name for robustness, with fallback by type). This avoids hardcoded binary addresses and works across binary versions as long as the class/property names are stable.

### ASVideoNode Player Access — Shareable vs Non-Shareable

Apollo uses two distinct video player paths depending on content type:

**Two player paths:**
- **Shareable** (v.redd.it): player shared via AVPlayerLayer between feed and comments. ASVideoNode's `_player` ivar is nil — player lives on `[[videoNode playerLayer] player]`.
- **Non-shareable** (GIFs, Giphy, Streamable): player on `[videoNode player]` directly.
- **Always use `[[videoNode playerLayer] player]`** (the native mute handler's path), fall back to `[videoNode player]` if playerLayer returns nil.

**Transition-specific behavior:**
- **Compact posts**: feed -> fullscreen -> comments often creates a fresh comments `AVPlayer` asynchronously. Do not assume the fullscreen player and comments player are the same object; expect to retry after async asset/player preparation completes.
- **Non-compact posts**: feed/comments/fullscreen may all be manipulating the same shared player layer. Fixes must update the real player state first, then separately resync the mute button/icon if Apollo's UI falls out of sync.
- **Crossposts**: when scanning visible media or resyncing state, inspect both the cell's `richMediaNode` and `crosspostNode.richMediaNode`.

**Unmuting requires (in order):**
1. `setCategory:AVAudioSessionCategoryPlayback` — Apollo defaults to `Ambient`, which silences audio even when `player.muted=NO`.
2. `[player setMuted:NO]` directly (for shareable, `[videoNode setMuted:NO]` alone won't reach the real player since `_player` is nil) + `[videoNode setMuted:NO]` to sync the internal `_muted` flag.
3. Blocking session reversion to `Ambient` — Apollo resets the session after player setup. Handled by AVAudioSession hooks keyed on `sAutoUnmutedPlayer`.

**Mute dance** (`sub_1003414cc`): Apollo's async mute sequence, fired when a video exits the visible area (`TouchHintVideoNode.didExitVisibleState` → `sub_10058cb30`) or when fullscreen MediaViewer dismisses. T+0: pause all, T+50ms: `setCategory:Ambient` + `setActive:NO`, T+100ms: `setMuted:YES` + unpause all. The native unmute (`sub_100341894`) survives this because it registers the player with `VideoSharingManager.activeAudioPlayer`; our auto-unmute survives via `sAutoUnmutedPlayer` + hook blocking. The native unpause handler only resumes non-shareable videos — shareable comments header videos stay paused, fixed in our `RichMediaNode.unpauseAllAVPlayersNotificationReceivedWithNotification:` hook.

**Mute button:** Icon names `"small-mute"` / `"small-unmute"` on MuteUnmuteVideoButtonNode's `icon` ASImageNode, with `isMuted` Swift Bool ivar. Don't use `muteUnmuteButtonTappedWithSender:` for programmatic unmuting — it's a toggle (mutes if already unmuted) and depends on a weak `actionDelegate` that may be nil.

**Best hook for comments header video:** `RichMediaHeaderCellNode.cellNodeVisibilityEvent:` — event-driven, comments-only (no context check needed). Player may not exist on event=0; use ~500ms retry.

## Headers And Runtime Introspection Tips

- For methods you only need to call defensively, prefer `objc_getClass` + `NSSelectorFromString` + `objc_msgSend` over adding brittle headers.
- If a class is only forward-declared, cast `self` to `UIViewController *` (or `id`) before sending UIKit messages to keep clang happy.
