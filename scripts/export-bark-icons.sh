#!/usr/bin/env bash
#
# export-bark-icons.sh — extract Apollo's app icons into assets/bark-icons/
# for Bark notification icon passthrough.
#
# Bark's `icon` push parameter takes an image URL, which the Bark app
# downloads (once — cached per URL) and shows in place of its own icon on the
# notification. The tweak points it at these files via raw.githubusercontent
# URLs, keyed by the CFBundleAlternateIcons name the user selected in Apollo
# (UIApplication.alternateIconName), with default.png for the stock icon.
#
# The PNGs come straight out of Apollo's own app bundle, which ships every
# alternate icon as a loose file (app-icon-iphone-<name>@2x.png, 120x120 —
# plenty for a notification icon). Re-run against a newer IPA if Apollo's
# icon set ever changes:
#
#   scripts/export-bark-icons.sh ./apollo-base.ipa
#   scripts/export-bark-icons.sh ./.sim/Payload/Apollo.app
#
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="${1:-./apollo-base.ipa}"
OUT="assets/bark-icons"

WORK=""
cleanup() { if [[ -n "$WORK" ]]; then rm -rf "$WORK"; fi; }
trap cleanup EXIT

if [[ -d "$SRC" ]]; then
    APP_DIR="$SRC"
elif [[ -f "$SRC" ]]; then
    WORK="$(mktemp -d)"
    unzip -q "$SRC" 'Payload/*.app/app-icon-iphone-*@2x.png' \
                    'Payload/*.app/AppIcon60x60@2x.png' \
                    'Payload/*.app/Info.plist' -d "$WORK"
    APP_DIR="$(find "$WORK/Payload" -maxdepth 1 -name '*.app' -type d | head -1)"
else
    echo "error: $SRC is neither an .ipa nor an .app directory" >&2
    exit 1
fi

[[ -f "$APP_DIR/Info.plist" ]] || { echo "error: no Info.plist in $APP_DIR" >&2; exit 1; }

mkdir -p "$OUT"

# The bundle's PNGs are iOS-optimized (Apple's proprietary CgBI variant:
# byte-swapped channels, nonstandard zlib framing). They render fine inside
# iOS apps but not in standard decoders — and these files get served over
# HTTP to whatever fetches them — so revert them to standard PNG on the way
# out. pngcrush ships with Xcode.
PNGCRUSH="$(xcrun --find pngcrush 2>/dev/null || command -v pngcrush || true)"
[[ -n "$PNGCRUSH" ]] || { echo "error: pngcrush not found (install Xcode)" >&2; exit 1; }
export_png() { # export_png <src> <dest>
    "$PNGCRUSH" -q -revert-iphone-optimizations "$1" "$2" >/dev/null 2>&1 || cp "$1" "$2"
}
export PNGCRUSH
export -f export_png

# The stock icon, under the fixed name the tweak/backend default to.
export_png "$APP_DIR/AppIcon60x60@2x.png" "$OUT/default.png"

# One PNG per alternate icon, named by its CFBundleAlternateIcons key — the
# exact string UIApplication.alternateIconName returns when it's selected.
# python maps key -> bundle file; the copy runs through export_png above.
count=0
while IFS=$'\t' read -r name src; do
    if [[ ! -f "$src" ]]; then
        echo "warning: no @2x file for alternate icon '$name'" >&2
        continue
    fi
    export_png "$src" "$OUT/$name.png"
    count=$((count + 1))
done < <(plutil -convert json -o - "$APP_DIR/Info.plist" | python3 -c '
import json, sys, os

app_dir = sys.argv[1]
info = json.load(sys.stdin)
alternates = info.get("CFBundleIcons", {}).get("CFBundleAlternateIcons", {})
if not alternates:
    sys.exit("error: no CFBundleAlternateIcons in Info.plist")
for name, entry in sorted(alternates.items()):
    files = entry.get("CFBundleIconFiles") or []
    src = os.path.join(app_dir, files[0] + "@2x.png") if files else ""
    print(name + "\t" + src)
' "$APP_DIR")

echo "exported $count alternate icons + default.png -> $OUT"
