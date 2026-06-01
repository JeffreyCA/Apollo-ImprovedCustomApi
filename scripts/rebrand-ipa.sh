#!/bin/bash
set -euo pipefail

# Rebrand an Apollo IPA to a new bundle ID (app + every app-extension), in the
# same way Sideloadly's "Change Bundle ID" does — but as a repo script so you can
# feed a rebranded IPA to a signer that DOESN'T offer that (e.g. AltStore/SideStore).
#
# Why you'd want this
# -------------------
# Push notifications require the app to register for APNs under an EXPLICIT App ID
# that has Push enabled. `com.christianselig.Apollo` is globally owned by Apollo's
# team, so you can't enable Push on it under your own team — you must rebrand to a
# bundle ID you own (e.g. com.nickclyde.Leto). Sideloadly does this for you but
# doesn't set the iOS-26 appex main-binary flag (so the "Open in Apollo" share
# action stays broken). AltStore/SideStore DO set that flag but won't rebrand. This
# script bridges the gap: rebrand here, then install via AltStore/SideStore (or
# codesign) → push AND the share action both work from one build.
#
# What it changes — and DELIBERATELY does NOT
# -------------------------------------------
# Changes ONLY each bundle's CFBundleIdentifier:
#   - the app:           com.christianselig.Apollo            -> <new base>
#   - every .appex:      com.christianselig.Apollo.<Suffix>   -> <new base>.<Suffix>
#     (extensions MUST stay prefixed by the app id, so the suffix is preserved).
#
# Leaves untouched, on purpose:
#   - The App Group `group.com.christianselig.apollo`. The ApolloReborn tweak
#     hardcodes this group and reads it "no matter the bundle ID"
#     (src/CustomAPIViewController.m), and Apollo's own binaries reference it too;
#     rewriting only the plist would desync the binaries. The group id is team-
#     scoped (not globally unique), so your signer can provision it as-is.
#   - The `apollo://` URL scheme (literal in CFBundleURLTypes, not derived from the
#     bundle id) — so the share action still routes to the app after rebranding.
#   - `com.christianselig.Apollo.StateRestoration.activity` (an NSUserActivityType
#     that must match the app binary), keychain/Valet service names, etc.
#
# After rebranding, sign+install with a signer that sets the appex main-binary flag
# (AltStore/SideStore, or scripts/resign-ipa-codesign.sh), and uninstall any build
# still using the old bundle id to avoid an apollo:// scheme collision.

usage() {
    echo "Usage: $0 <input.ipa> <new-bundle-id> [-o <output.ipa>]"
    echo ""
    echo "  <new-bundle-id>   a bundle id you own + can enable Push on, e.g. com.nickclyde.Leto"
    echo "  -o <output.ipa>   default: <input>-rebranded.ipa"
    echo ""
    echo "Example:"
    echo "  $0 Apollo-Reborn.ipa com.nickclyde.Leto -o Leto.ipa"
}

[[ $# -lt 2 || "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && exit 0; exit 1; }

IPA="$1"; NEW_BASE="$2"; shift 2
OUT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output) OUT="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

[[ -f "$IPA" ]] || { echo "Error: IPA not found: $IPA"; exit 1; }
case "$IPA" in /*) : ;; *) IPA="$PWD/$IPA" ;; esac
[[ -z "$OUT" ]] && OUT="${IPA%.ipa}-rebranded.ipa"
case "$OUT" in /*) : ;; *) OUT="$PWD/$OUT" ;; esac

# Basic reverse-DNS sanity (letters/digits/hyphen segments separated by dots).
if ! [[ "$NEW_BASE" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
    echo "Error: '$NEW_BASE' doesn't look like a valid bundle id (e.g. com.nickclyde.Leto)"; exit 1
fi

for tool in unzip zip /usr/libexec/PlistBuddy; do
    command -v "$tool" >/dev/null 2>&1 || [[ -x "$tool" ]] || { echo "Error: missing tool: $tool"; exit 1; }
done
PB=/usr/libexec/PlistBuddy

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
(cd "$work" && unzip -q "$IPA")

app="$(find "$work/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
[[ -n "$app" && -d "$app" ]] || { echo "Error: no .app in IPA"; exit 1; }

OLD_BASE="$("$PB" -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
[[ -n "$OLD_BASE" ]] || { echo "Error: app has no CFBundleIdentifier"; exit 1; }

echo "Rebranding $(basename "$IPA")"
echo "  $OLD_BASE  ->  $NEW_BASE"

if [[ "$OLD_BASE" == "$NEW_BASE" ]]; then
    echo "  (already $NEW_BASE — nothing to change)"
fi

# App bundle id.
"$PB" -c "Set :CFBundleIdentifier $NEW_BASE" "$app/Info.plist"
echo "  app:   $NEW_BASE"

# Each appex: replace the OLD_BASE prefix, keep the suffix (must stay prefixed by
# the app id or the extension won't install).
shopt -s nullglob
for ax in "$app"/PlugIns/*.appex; do
    plist="$ax/Info.plist"
    [[ -f "$plist" ]] || continue
    id="$("$PB" -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
    [[ -n "$id" ]] || { echo "  WARN: $(basename "$ax") has no CFBundleIdentifier; skipped"; continue; }
    if [[ "$id" == "$OLD_BASE" ]]; then
        new_id="$NEW_BASE"
    elif [[ "$id" == "$OLD_BASE."* ]]; then
        new_id="${NEW_BASE}.${id#$OLD_BASE.}"
    else
        echo "  WARN: $(basename "$ax") id '$id' isn't prefixed by '$OLD_BASE'; left unchanged"
        continue
    fi
    "$PB" -c "Set :CFBundleIdentifier $new_id" "$plist"
    echo "  appex: $new_id"
done
shopt -u nullglob

# The plist edits invalidate the existing signatures; strip them so the downstream
# signer (AltStore/SideStore/codesign) re-seals from scratch cleanly.
find "$app" -name "_CodeSignature" -type d -prune -exec rm -rf {} +

rm -f "$OUT"
(cd "$work" && zip -qry "$OUT" Payload)
echo "Rebranded IPA: $OUT"
echo ""
echo "Next: sign + install with a signer that sets the appex main-binary flag"
echo "  (AltStore/SideStore, or scripts/resign-ipa-codesign.sh) so the 'Open in"
echo "  Apollo' action works, and uninstall any build still using '$OLD_BASE' to"
echo "  avoid an apollo:// scheme collision. Push works once '$NEW_BASE' is signed"
echo "  with a profile whose App ID has Push enabled."
