#!/usr/bin/env bash
#
# export-bark-sounds.sh — convert Apollo's notification sounds into
# assets/bark-sounds/ as .caf files for Bark sound passthrough.
#
# Apollo's own pushes always say sound=traloop.wav; the app's bundled
# NotificationServiceExtension swaps in the user's picked sound (group
# defaults key "NotificationSound", a camelCase id like diabolicalDoorbell
# for diabolical-doorbell.wav). That extension never runs for Bark
# deliveries, and the Bark app can only play its built-ins or .caf files
# imported into it (Bark copies imports verbatim and lists only .caf). So:
#
#   - each Apollo .wav is converted to <camelCaseId>.caf, named so the tweak
#     can pass the stored NotificationSound value verbatim as the push URL's
#     ?sound= parameter (bark-server appends ".caf" to extensionless values)
#   - the user imports the .caf for their picked sound into the Bark app
#     once; unimported sounds fall back to the default alert sound
#   - happySighs is Apollo's "random sigh" — the extension picks sigh1-4 at
#     random. Bark plays one fixed file, so happySighs.caf is sigh1.
#
# Re-run against a newer IPA if Apollo's sound set ever changes:
#
#   scripts/export-bark-sounds.sh ./apollo-base.ipa
#   scripts/export-bark-sounds.sh ./.sim/Payload/Apollo.app
#
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="${1:-./apollo-base.ipa}"
OUT="assets/bark-sounds"

command -v afconvert >/dev/null || { echo "error: afconvert not found (macOS only)" >&2; exit 1; }

WORK=""
cleanup() { if [[ -n "$WORK" ]]; then rm -rf "$WORK"; fi; }
trap cleanup EXIT

if [[ -d "$SRC" ]]; then
    APP_DIR="$SRC"
elif [[ -f "$SRC" ]]; then
    WORK="$(mktemp -d)"
    unzip -q "$SRC" 'Payload/*.app/*.wav' -d "$WORK"
    APP_DIR="$(find "$WORK/Payload" -maxdepth 1 -name '*.app' -type d | head -1)"
else
    echo "error: $SRC is neither an .ipa nor an .app directory" >&2
    exit 1
fi

mkdir -p "$OUT"

# kebab-case wav basename -> the camelCase id Apollo stores in group
# defaults ("diabolical-doorbell" -> "diabolicalDoorbell"). Verified against
# the id strings embedded in NotificationServiceExtension.
camel() {
    python3 -c '
import sys
parts = sys.argv[1].split("-")
print(parts[0] + "".join(p.capitalize() for p in parts[1:]))
' "$1"
}

count=0
for wav in "$APP_DIR"/*.wav; do
    base="$(basename "$wav" .wav)"
    # -f caff -d LEI16: plain linear PCM in a CAF container — a lossless
    # rewrap, which is all Library/Sounds needs.
    afconvert -f caff -d LEI16 "$wav" "$OUT/$(camel "$base").caf"
    count=$((count + 1))
done

if [[ -f "$APP_DIR/sigh1.wav" ]]; then
    afconvert -f caff -d LEI16 "$APP_DIR/sigh1.wav" "$OUT/happySighs.caf"
    count=$((count + 1))
fi

echo "exported $count sounds -> $OUT"
