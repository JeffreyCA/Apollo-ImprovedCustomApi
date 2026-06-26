#!/bin/bash
# patch_liquid_glass_assets_in_app <app_bundle>
#
# Applies the iOS 26 Liquid Glass ASSETS patches to an unpacked .app bundle:
#   * replaces Assets.car with the prebuilt Liquid Glass icon catalog.
#   * writes the CFBundleIcons / CFBundleIcons~ipad primary + alternate icon
#     metadata so the in-app alternate icon picker has icons to show.
#
# This does NOT bump the SDK version, so IsLiquidGlass() stays off and the iOS 26
# UI runtime is not activated — that is the liquid-glass-binary module. Used on
# its own this is the "icons-only" variant. Credit: @ryannair05.

_LG_ASSETS_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LG_ASSETS_REPO_DIR="$(cd "${_LG_ASSETS_MODULE_DIR}/../.." && pwd)"

# shellcheck source=_plist-helpers.sh
source "${_LG_ASSETS_MODULE_DIR}/_plist-helpers.sh"

# Asset sources default to the Apollo-Reborn repo, but callers with their own
# copy (e.g. the workspace build.sh under scripts/patch-assets/) can override
# them via these env vars before sourcing/calling.
_LG_ASSETS_CAR="${LG_ASSETS_CAR:-${_LG_ASSETS_REPO_DIR}/liquid-glass/prebuilt/Assets.car}"
_LG_ICONS_REGISTRY="${LG_ICONS_REGISTRY:-${_LG_ASSETS_REPO_DIR}/liquid-glass/icons.json}"
_LG_ICON_NAME="AppIcon"
_LG_IPAD_ICON_FILES=("AppIcon60x60" "AppIcon76x76")
_LG_IPHONE_ICON_FILES=("AppIcon60x60")

_lg_load_alternate_icons() {
    local i=0 id
    while id=$(plutil -extract "icons.${i}.id" raw -o - "$_LG_ICONS_REGISTRY" 2>/dev/null); do
        echo "$id"
        ((i++))
    done
}

_lg_ensure_icon_metadata() {
    local plist="$1"
    local -a alt_icons=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && alt_icons+=("$line")
    done < <(_lg_load_alternate_icons)

    plist_ensure_dict "$plist" "CFBundleIcons"
    plist_ensure_dict "$plist" "CFBundleIcons:CFBundlePrimaryIcon"
    plist_ensure_dict "$plist" "CFBundleIcons:CFBundleAlternateIcons"
    plist_ensure_dict "$plist" "CFBundleIcons~ipad"
    plist_ensure_dict "$plist" "CFBundleIcons~ipad:CFBundlePrimaryIcon"
    plist_ensure_dict "$plist" "CFBundleIcons~ipad:CFBundleAlternateIcons"

    plist_set_string "$plist" "CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName" "$_LG_ICON_NAME"
    plist_set_string "$plist" "CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconName" "$_LG_ICON_NAME"
    plist_replace_string_array "$plist" "CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles" "${_LG_IPHONE_ICON_FILES[@]}"
    plist_replace_string_array "$plist" "CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconFiles" "${_LG_IPAD_ICON_FILES[@]}"

    local icon_name
    for icon_name in "${alt_icons[@]}"; do
        plist_ensure_dict "$plist" "CFBundleIcons:CFBundleAlternateIcons:${icon_name}"
        plist_ensure_dict "$plist" "CFBundleIcons~ipad:CFBundleAlternateIcons:${icon_name}"
        plist_set_string "$plist" "CFBundleIcons:CFBundleAlternateIcons:${icon_name}:CFBundleIconName" "$icon_name"
        plist_set_string "$plist" "CFBundleIcons~ipad:CFBundleAlternateIcons:${icon_name}:CFBundleIconName" "$icon_name"
    done
}

patch_liquid_glass_assets_in_app() {
    local app_bundle="$1"
    local plist="$app_bundle/Info.plist"

    if [[ ! -f "$_LG_ASSETS_CAR" ]]; then
        echo "Error: Liquid Glass asset catalog not found at $_LG_ASSETS_CAR"
        return 1
    fi

    # Guard against a truncated/corrupt asset catalog. The real Assets.car is
    # ~80 MB; patching with a stub silently produces a launch-crashing IPA
    # (issue #314). Applied unconditionally (the old icons-only path skipped it).
    local asset_size
    asset_size=$(wc -c < "$_LG_ASSETS_CAR" | tr -d ' ')
    if [[ "$asset_size" -lt 4096 ]]; then
        echo "Error: $_LG_ASSETS_CAR looks truncated or corrupt (${asset_size} bytes), not the real asset catalog."
        echo "       Re-fetch the repository contents and try again."
        return 1
    fi

    echo "Replacing Assets.car with prebuilt Liquid Glass asset catalog..."
    cp "$_LG_ASSETS_CAR" "$app_bundle/Assets.car"

    echo "Updating app icon metadata for Liquid Glass multi-icon catalog..."
    _lg_ensure_icon_metadata "$plist"

    rm -rf "$app_bundle/_CodeSignature"
}
