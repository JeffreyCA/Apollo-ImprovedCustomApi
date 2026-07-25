# Patch modules

Each file here is one **patch module**: a shell function that mutates an
already-unpacked `Apollo.app` bundle in place. Modules are the single source of
truth for every IPA modification Apollo-Reborn performs, shared by:

- `scripts/apply-patches.sh` — the orchestrator (unpack once → run modules → repack once)
- `patch.sh`, `build-ipa.sh`, `scripts/build_release_variants.sh`
- the workspace `Apollo/scripts/build.sh` (sources these via the sibling checkout)
- the thin per-IPA wrappers (`scripts/inject-widgets.sh`, `scripts/fix-*-extension.sh`)

## Convention

A module `foo-bar.sh` defines:

```sh
foo_bar_in_app() {
    local app_bundle="$1"     # path to an unpacked *.app
    # ...mutate $app_bundle in place...
    # strip $app_bundle/_CodeSignature (or the appex's) if you changed a
    # signed binary/plist, so the user's signer re-seals cleanly.
}
```

Rules:

- **Operate on the passed bundle path.** Never assume the current working
  directory or hardcode `Info.plist`; use `"$app_bundle/Info.plist"`. Plist
  edits go through the path-taking helpers in `_plist-helpers.sh`.
- **Be best-effort.** If the module's target (an appex, a framework) is absent,
  print a short note and `return 0`. The one exception is `inject-tweak`, which
  hard-fails (`return 2`) when the IPA isn't prepared.
- **No unpack/repack inside the module.** The orchestrator owns that. (A module
  may use its own temp dir for intermediate work, e.g. `inject-tweak` extracting
  a `.deb`, but it must not unzip/rezip the IPA.)
- Resolve repo-relative asset paths from `${BASH_SOURCE[0]}` (the module file),
  not from `$0` (the caller).

## Registering a module with the orchestrator

Add one line to the `module_function` case in `scripts/apply-patches.sh` mapping
the module name to its function:

```sh
foo-bar)  echo "foo_bar_in_app" ;;
```

Then it's usable as `--module foo-bar` (or `--module 'foo-bar:arg1:arg2'`, which
calls `foo_bar_in_app "$app_bundle" arg1 arg2`).

## Adding a new patch (end-to-end)

1. Write `scripts/modules/<feature>.sh` following the convention above.
2. Register it in `apply-patches.sh` (one `case` line).
3. Add `--module <feature>` to the relevant variant(s) in
   `scripts/build_release_variants.sh` (and `Apollo/scripts/build.sh` if it
   should ship in local builds).

No new unpack/repack script, no edits to the other build paths.

## Current modules

| Module | Function | Purpose |
|---|---|---|
| `inject-tweak` | `inject_tweak_in_app` | replace tweak dylibs from a `.deb` (prepared IPA) |
| `strip-substrate-arm64e` | `strip_substrate_arm64e_in_app` | strip CydiaSubstrate arm64e slice (iOS 26 dyld) |
| `patch-bundle-versions` | `patch_bundle_versions_in_app` | set `CFBundleShortVersionString` / `CFBundleVersion` |
| `enable-promotion` | `enable_promotion_in_app` | unlock adaptive refresh rates above 60 Hz on iPhone |
| `inject-url-schemes` | `inject_url_schemes_in_app` | append `CFBundleURLTypes` schemes |
| `fix-safari-extension` | `fix_safari_extension_in_app` | repair `Apollofari.appex` |
| `fix-openin-extension` | `fix_openin_extension_in_app` | repair `OpenInUIExtension.appex` |
| `inject-widgets` | `inject_widgets_in_app` | swap stock widget for `ApolloRebornWidgets.appex` |
| `liquid-glass-binary` | `patch_liquid_glass_binary_in_app` | vtool SDK bump + duplicate `LC_RPATH` removal |
| `liquid-glass-assets` | `patch_liquid_glass_assets_in_app` | `Assets.car` swap + icon metadata |

`_plist-helpers.sh` is a shared support file (path-taking PlistBuddy helpers),
not a module.
