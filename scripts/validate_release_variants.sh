#!/bin/bash
set -euo pipefail

OUT_DIR="${1:-dist/out}"

usage() {
    echo "Usage: $0 <dist/out>"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ ! -d "$OUT_DIR" ]]; then
    echo "Error: output directory not found: $OUT_DIR" >&2
    exit 1
fi

for tool in unzip grep plutil; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: required tool '$tool' is not installed." >&2
        exit 1
    fi
done

find_variant() {
    local matches

    matches="$(find "$OUT_DIR" -maxdepth 1 -name '*.ipa' -type f \
        ! -name '*-NOEXTENSIONS.ipa' \
        ! -name '*-GLASS.ipa' \
        ! -name '*-GLASS-NOEXTENSIONS.ipa' \
        ! -name '*-GLASSICONS.ipa' \
        ! -name '*-GLASSICONS-NOEXTENSIONS.ipa' \
        | sort)"

    if [[ "$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')" != "1" ]]; then
        echo "Error: expected exactly one standard IPA, found:" >&2
        printf '%s\n' "$matches" >&2
        exit 1
    fi

    printf '%s\n' "$matches"
}

require_file() {
    local path="$1"
    local name="$2"

    if [[ ! -f "$path" ]]; then
        echo "Error: missing $name IPA: $path" >&2
        exit 1
    fi
}

contains_path() {
    local ipa="$1"
    local pattern="$2"

    unzip -Z1 "$ipa" | grep -Eq "$pattern"
}

require_widget_variant() {
    local ipa="$1"
    local name="$2"
    local work app_dir appex plist bundle_id executable ext_point

    if ! contains_path "$ipa" '^Payload/[^/]+\.app/PlugIns/ApolloRebornWidgets\.appex/'; then
        echo "Error: $name is missing ApolloRebornWidgets.appex" >&2
        exit 1
    fi

    if contains_path "$ipa" '^Payload/[^/]+\.app/PlugIns/AthenaWidgetExtension\.appex/'; then
        echo "Error: $name still contains stock AthenaWidgetExtension.appex" >&2
        exit 1
    fi

    work="$(mktemp -d)"
    unzip -q "$ipa" -d "$work"
    app_dir="$(find "$work/Payload" -maxdepth 1 -name '*.app' -type d -print -quit)"
    appex="$app_dir/PlugIns/ApolloRebornWidgets.appex"
    plist="$appex/Info.plist"
    executable="$appex/ApolloRebornWidgets"

    if [[ ! -f "$plist" || ! -f "$executable" ]]; then
        echo "Error: $name has an incomplete ApolloRebornWidgets.appex" >&2
        rm -rf "$work"
        exit 1
    fi

    bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$plist" 2>/dev/null || true)"
    ext_point="$(plutil -extract NSExtension.NSExtensionPointIdentifier raw -o - "$plist" 2>/dev/null || true)"
    if [[ "$bundle_id" != "com.christianselig.Apollo.RebornWidgets" ]]; then
        echo "Error: $name widget bundle id is '$bundle_id'" >&2
        rm -rf "$work"
        exit 1
    fi
    if [[ "$ext_point" != "com.apple.widgetkit-extension" ]]; then
        echo "Error: $name widget extension point is '$ext_point'" >&2
        rm -rf "$work"
        exit 1
    fi

    rm -rf "$work"
}

require_safari_extensions() {
    local ipa="$1"
    local name="$2"
    local work app_dir app_id manual legacy manual_id legacy_id manual_name legacy_name

    if ! contains_path "$ipa" '^Payload/[^/]+\.app/PlugIns/Apollofari\.appex/'; then
        echo "Error: $name is missing Apollofari.appex" >&2
        exit 1
    fi
    if ! contains_path "$ipa" '^Payload/[^/]+\.app/PlugIns/ApollofariLegacy\.appex/'; then
        echo "Error: $name is missing ApollofariLegacy.appex" >&2
        exit 1
    fi

    work="$(mktemp -d)"
    unzip -q "$ipa" -d "$work"
    app_dir="$(find "$work/Payload" -maxdepth 1 -name '*.app' -type d -print -quit)"
    manual="$app_dir/PlugIns/Apollofari.appex"
    legacy="$app_dir/PlugIns/ApollofariLegacy.appex"

    app_id="$(plutil -extract CFBundleIdentifier raw -o - "$app_dir/Info.plist" 2>/dev/null || true)"
    manual_id="$(plutil -extract CFBundleIdentifier raw -o - "$manual/Info.plist" 2>/dev/null || true)"
    legacy_id="$(plutil -extract CFBundleIdentifier raw -o - "$legacy/Info.plist" 2>/dev/null || true)"
    manual_name="$(plutil -extract CFBundleDisplayName raw -o - "$manual/Info.plist" 2>/dev/null || true)"
    legacy_name="$(plutil -extract CFBundleDisplayName raw -o - "$legacy/Info.plist" 2>/dev/null || true)"

    if [[ "$manual_id" != "${app_id}.Apollofari" ||
          "$legacy_id" != "${app_id}.ApollofariLegacy" ]]; then
        echo "Error: $name has invalid Safari extension bundle identifiers:" >&2
        echo "  app:    $app_id" >&2
        echo "  manual: $manual_id" >&2
        echo "  legacy: $legacy_id" >&2
        rm -rf "$work"
        exit 1
    fi
    if [[ "$manual_name" != "Open in Apollo (Manual Fallback)" ||
          "$legacy_name" != "Open in Apollo (Legacy)" ]]; then
        echo "Error: $name has invalid Safari extension display names:" >&2
        echo "  manual: $manual_name" >&2
        echo "  legacy: $legacy_name" >&2
        rm -rf "$work"
        exit 1
    fi

    rm -rf "$work"
}

require_no_extensions_variant() {
    local ipa="$1"
    local name="$2"

    if contains_path "$ipa" '^Payload/[^/]+\.app/PlugIns/[^/]+\.appex/'; then
        echo "Error: $name contains app extensions despite being a no-extensions variant" >&2
        unzip -Z1 "$ipa" | grep -E '^Payload/[^/]+\.app/PlugIns/[^/]+\.appex/' >&2
        exit 1
    fi
}

require_promotion_enabled() {
    local ipa="$1"
    local name="$2"
    local plist value value_type

    plist="$(mktemp)"
    unzip -p "$ipa" 'Payload/*.app/Info.plist' > "$plist" 2>/dev/null
    value_type="$(plutil -type CADisableMinimumFrameDurationOnPhone "$plist" 2>/dev/null || true)"
    value="$(plutil -extract CADisableMinimumFrameDurationOnPhone raw -o - "$plist" 2>/dev/null || true)"
    rm -f "$plist"

    if [[ "$value_type" != "bool" || ( "$value" != "true" && "$value" != "1" ) ]]; then
        echo "Error: $name does not enable CADisableMinimumFrameDurationOnPhone as a Boolean (type: ${value_type:-missing}, value: ${value:-missing})" >&2
        exit 1
    fi
}

STANDARD_IPA="$(find_variant)"
BASE="${STANDARD_IPA%.ipa}"
NOEXT_IPA="${BASE}-NOEXTENSIONS.ipa"
GLASS_IPA="${BASE}-GLASS.ipa"
NOEXT_GLASS_IPA="${BASE}-GLASS-NOEXTENSIONS.ipa"
GLASS_ICONS_IPA="${BASE}-GLASSICONS.ipa"
NOEXT_GLASS_ICONS_IPA="${BASE}-GLASSICONS-NOEXTENSIONS.ipa"

require_file "$NOEXT_IPA" "No Extensions"
require_file "$GLASS_IPA" "GLASS"
require_file "$NOEXT_GLASS_IPA" "GLASS No Extensions"
require_file "$GLASS_ICONS_IPA" "GLASS Icons"
require_file "$NOEXT_GLASS_ICONS_IPA" "GLASS Icons No Extensions"

require_widget_variant "$STANDARD_IPA" "standard"
require_widget_variant "$GLASS_IPA" "GLASS"
require_widget_variant "$GLASS_ICONS_IPA" "GLASS Icons"

require_safari_extensions "$STANDARD_IPA" "standard"
require_safari_extensions "$GLASS_IPA" "GLASS"
require_safari_extensions "$GLASS_ICONS_IPA" "GLASS Icons"

require_no_extensions_variant "$NOEXT_IPA" "No Extensions"
require_no_extensions_variant "$NOEXT_GLASS_IPA" "GLASS No Extensions"
require_no_extensions_variant "$NOEXT_GLASS_ICONS_IPA" "GLASS Icons No Extensions"

require_promotion_enabled "$STANDARD_IPA" "standard"
require_promotion_enabled "$NOEXT_IPA" "No Extensions"
require_promotion_enabled "$GLASS_IPA" "GLASS"
require_promotion_enabled "$NOEXT_GLASS_IPA" "GLASS No Extensions"
require_promotion_enabled "$GLASS_ICONS_IPA" "GLASS Icons"
require_promotion_enabled "$NOEXT_GLASS_ICONS_IPA" "GLASS Icons No Extensions"

echo "IPA variant validation passed:"
printf '  %s\n' \
    "$(basename "$STANDARD_IPA")" \
    "$(basename "$NOEXT_IPA")" \
    "$(basename "$GLASS_IPA")" \
    "$(basename "$NOEXT_GLASS_IPA")" \
    "$(basename "$GLASS_ICONS_IPA")" \
    "$(basename "$NOEXT_GLASS_ICONS_IPA")"
