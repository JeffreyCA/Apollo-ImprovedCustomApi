#!/bin/bash
# fix_safari_extension_in_app <app_bundle>
#
# Overlays the fixed Safari Web Extension assets onto Apollofari.appex inside an
# unpacked .app bundle, in place. No-op (return 0) when the bundle has no
# Apollofari.appex (the no-extensions variants).
#
# The stock extension's "Automatic" mode redirected through openinapollo.com,
# whose auto-open relies on an iOS Smart App Banner bound to the App Store
# Apollo. A sideloaded build is not that app, so the banner never fires. We
# overlay direct apollo:// redirect assets from safari-extension/.

_SAFARI_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# modules/ lives under scripts/, so the repo root is two levels up.
_SAFARI_REPO_DIR="$(cd "${_SAFARI_MODULE_DIR}/../.." && pwd)"

fix_safari_extension_in_app() {
    local app_bundle="$1"
    local asset_dir="${_SAFARI_REPO_DIR}/safari-extension"

    local asset
    for asset in content.js manifest.json; do
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

    echo "Repairing Safari extension..."
    cp "$asset_dir/content.js" "$appex/content.js"
    cp "$asset_dir/manifest.json" "$appex/manifest.json"
    # The appex's prior signature covers the now-modified web assets.
    rm -rf "$appex/_CodeSignature"
    echo "Safari extension repaired: content.js + manifest.json overlaid."
}
