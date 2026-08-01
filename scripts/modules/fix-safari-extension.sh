#!/bin/bash
# fix_safari_extension_in_app <app_bundle>
#
# Overlays the manual-fallback Safari Web Extension assets onto Apollofari.appex inside an
# unpacked .app bundle, in place. No-op (return 0) when the bundle has no
# Apollofari.appex (the no-extensions variants).
#
# Automatic opening is owned by the Safari extension embedded in the separately
# signed Link Companion app. This Apollo-bundled extension intentionally remains
# passive so the two extensions never race; it only provides a delayed, real
# user-tappable Universal Link when a Reddit page remains in Safari.

_SAFARI_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# modules/ lives under scripts/, so the repo root is two levels up.
_SAFARI_REPO_DIR="$(cd "${_SAFARI_MODULE_DIR}/../.." && pwd)"

fix_safari_extension_in_app() {
    local app_bundle="$1"
    local asset_dir="${_SAFARI_REPO_DIR}/safari-extension"

    local asset
    for asset in link-utils.js content.js content.css manifest.json popup.html; do
        if [[ ! -f "$asset_dir/$asset" ]]; then
            echo "Error: missing overlay asset: $asset_dir/$asset"
            return 1
        fi
    done

    local appex
    appex="$(find "$app_bundle/PlugIns" -type d -name "Apollofari.appex" -print -quit 2>/dev/null || true)"
    if [[ -z "$appex" || ! -d "$appex" ]]; then
        echo "No Apollofari.appex — skipping Safari extension fix."
        return 0
    fi

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
        -c "Set :CFBundleDisplayName Open in Apollo (Manual Fallback)" \
        "$appex/Info.plist"
    # The appex's prior signature covers the now-modified web assets.
    rm -rf "$appex/_CodeSignature"
    echo "Safari fallback installed: Reddit-only button, manifest, popup, and display name overlaid."
}
