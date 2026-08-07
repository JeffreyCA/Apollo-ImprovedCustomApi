#!/bin/bash
# fix_safari_extension_in_app <app_bundle>
#
# Turns Apollofari.appex into the manual-fallback Safari Web Extension and
# installs a second ApollofariLegacy.appex containing the former automatic
# opener. No-op (return 0) when the bundle has no Apollofari.appex (the
# no-extensions variants).
#
# Automatic opening is owned by the Safari extension embedded in the separately
# signed Link Companion app. This Apollo-bundled extension intentionally remains
# passive so it never races the Companion. The separately named legacy copy is
# retained for users who deliberately prefer the old automatic approach; it
# must not be enabled at the same time as the Companion extension.

_SAFARI_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# modules/ lives under scripts/, so the repo root is two levels up.
_SAFARI_REPO_DIR="$(cd "${_SAFARI_MODULE_DIR}/../.." && pwd)"

fix_safari_extension_in_app() {
    local app_bundle="$1"
    local asset_dir="${_SAFARI_REPO_DIR}/safari-extension"
    local legacy_asset_dir="${asset_dir}/legacy"

    local asset
    for asset in link-utils.js content.js content.css manifest.json popup.html; do
        if [[ ! -f "$asset_dir/$asset" ]]; then
            echo "Error: missing overlay asset: $asset_dir/$asset"
            return 1
        fi
    done
    for asset in content.js manifest.json popup.html popup.js; do
        if [[ ! -f "$legacy_asset_dir/$asset" ]]; then
            echo "Error: missing legacy overlay asset: $legacy_asset_dir/$asset"
            return 1
        fi
    done

    local appex="$app_bundle/PlugIns/Apollofari.appex"
    if [[ -z "$appex" || ! -d "$appex" ]]; then
        echo "No Apollofari.appex — skipping Safari extension fix."
        return 0
    fi

    local app_bundle_id
    app_bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app_bundle/Info.plist" 2>/dev/null || true)"
    if [[ -z "$app_bundle_id" ]]; then
        echo "Error: app bundle has no CFBundleIdentifier: $app_bundle/Info.plist"
        return 1
    fi

    local legacy_appex="$app_bundle/PlugIns/ApollofariLegacy.appex"
    if [[ ! -d "$legacy_appex" ]]; then
        echo "Creating legacy automatic Safari extension..."
        cp -R "$appex" "$legacy_appex"
    else
        echo "Refreshing existing legacy automatic Safari extension..."
    fi

    # Keep the previous Apollo Reborn automatic opener as a separately named,
    # opt-in extension. Overlay every behavior-bearing web asset so repatching
    # an IPA is deterministic even when Apollofari.appex is already the manual
    # fallback from an earlier run.
    cp "$asset_dir/link-utils.js" "$legacy_appex/link-utils.js"
    cp "$legacy_asset_dir/content.js" "$legacy_appex/content.js"
    cp "$legacy_asset_dir/manifest.json" "$legacy_appex/manifest.json"
    cp "$legacy_asset_dir/popup.html" "$legacy_appex/popup.html"
    cp "$legacy_asset_dir/popup.js" "$legacy_appex/popup.js"
    rm -f "$legacy_appex/content.css"
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleIdentifier ${app_bundle_id}.ApollofariLegacy" \
        -c "Set :CFBundleDisplayName Open in Apollo (Legacy)" \
        "$legacy_appex/Info.plist"
    # A copied provisioning profile names the original Apollofari bundle ID and
    # cannot cover this new sibling. Downstream signers must provision the new
    # identifier rather than accidentally reusing that stale profile.
    rm -f "$legacy_appex/embedded.mobileprovision"
    rm -rf "$legacy_appex/_CodeSignature"

    echo "Installing manual Safari fallback extension..."
    cp "$asset_dir/link-utils.js" "$appex/link-utils.js"
    cp "$asset_dir/content.js" "$appex/content.js"
    cp "$asset_dir/content.css" "$appex/content.css"
    cp "$asset_dir/manifest.json" "$appex/manifest.json"
    cp "$asset_dir/popup.html" "$appex/popup.html"
    # A previously patched IPA may still contain the old toggle script. The new
    # popup does not reference it, but remove it so the bundle has one unambiguous
    # implementation when inspected or repatched.
    rm -f "$appex/popup.js"
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleIdentifier ${app_bundle_id}.Apollofari" \
        -c "Set :CFBundleDisplayName Open in Apollo (Manual Fallback)" \
        "$appex/Info.plist"
    # The appex's prior signature covers the now-modified web assets.
    rm -rf "$appex/_CodeSignature"
    echo "Safari extensions installed: manual fallback plus opt-in legacy automatic opener."
}
