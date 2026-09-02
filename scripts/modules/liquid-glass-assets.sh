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

# Asset sources default to the Apollo-Reborn repo, but callers with their own
# copy (e.g. the workspace build.sh under scripts/patch-assets/) can override
# them via these env vars before sourcing/calling.
_LG_ASSETS_CAR="${LG_ASSETS_CAR:-${_LG_ASSETS_REPO_DIR}/liquid-glass/prebuilt/Assets.car}"
_LG_ICONS_REGISTRY="${LG_ICONS_REGISTRY:-${_LG_ASSETS_REPO_DIR}/liquid-glass/icons.json}"
# The primary icon is selected by metadata, not by requiring its asset to be
# named AppIcon. Keep historical alternate-icon IDs stable while promoting
# the Apollo design to the default shown when no alternate icon is selected.
_LG_ICON_NAME="apollo"
_LG_IPAD_ICON_FILES=("AppIcon60x60" "AppIcon76x76")
_LG_IPHONE_ICON_FILES=("AppIcon60x60")

_lg_load_alternate_icons() {
    local i=0 id group
    while id=$(plutil -extract "icons.${i}.id" raw -o - "$_LG_ICONS_REGISTRY" 2>/dev/null); do
        echo "$id"
        # Only Liquid Glass group icons have static Light/Dark clones.
        # Standard-pack additions are dynamic system-appearance icons.
        group=$(plutil -extract "icons.${i}.group" raw -o - "$_LG_ICONS_REGISTRY" 2>/dev/null || true)
        if [[ -n "$group" ]]; then
            echo "${id}__apollo_light"
            echo "${id}__apollo_dark"
        fi
        ((i++))
    done
}

# Writes the primary + alternate icon metadata in ONE plistlib pass. The
# previous PlistBuddy version spawned a process per key (several hundred for
# the full icon registry, each re-parsing the whole Info.plist) and took ~17s
# per IPA on CI runners; this takes well under a second. Existing entries under
# CFBundleIcons are preserved and only the keys we own are (re)written, matching
# the old behaviour. The plist's on-disk format (binary vs XML) is preserved.
_lg_ensure_icon_metadata() {
    local plist="$1"
    local -a alt_icons=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && alt_icons+=("$line")
    done < <(_lg_load_alternate_icons)

    LG_PLIST="$plist" \
    LG_ICON_NAME="$_LG_ICON_NAME" \
    LG_IPHONE_ICON_FILES="$(IFS=,; echo "${_LG_IPHONE_ICON_FILES[*]}")" \
    LG_IPAD_ICON_FILES="$(IFS=,; echo "${_LG_IPAD_ICON_FILES[*]}")" \
    LG_ALT_ICONS="$(IFS=,; echo "${alt_icons[*]+"${alt_icons[*]}"}")" \
    python3 - <<'PY'
import os
import plistlib

path = os.environ["LG_PLIST"]
icon_name = os.environ["LG_ICON_NAME"]
iphone_files = [f for f in os.environ["LG_IPHONE_ICON_FILES"].split(",") if f]
ipad_files = [f for f in os.environ["LG_IPAD_ICON_FILES"].split(",") if f]
alt_icons = [n for n in os.environ["LG_ALT_ICONS"].split(",") if n]

with open(path, "rb") as fh:
    raw = fh.read()
fmt = plistlib.FMT_BINARY if raw.startswith(b"bplist") else plistlib.FMT_XML
root = plistlib.loads(raw)


def ensure_dict(parent, key):
    value = parent.get(key)
    if not isinstance(value, dict):
        value = {}
        parent[key] = value
    return value


for icons_key, files in (("CFBundleIcons", iphone_files), ("CFBundleIcons~ipad", ipad_files)):
    icons = ensure_dict(root, icons_key)
    primary = ensure_dict(icons, "CFBundlePrimaryIcon")
    primary["CFBundleIconName"] = icon_name
    primary["CFBundleIconFiles"] = list(files)
    alternates = ensure_dict(icons, "CFBundleAlternateIcons")
    for name in alt_icons:
        ensure_dict(alternates, name)["CFBundleIconName"] = name

with open(path, "wb") as fh:
    plistlib.dump(root, fh, fmt=fmt)
PY
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
