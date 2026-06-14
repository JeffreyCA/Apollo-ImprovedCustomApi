#!/bin/bash
# Inject the Apollo Reborn widget extension into an Apollo IPA.
#
# A crash-looping widget extension poisons WidgetKit's enumeration of ALL of
# the host app's widgets, so by default we REMOVE the stock crash-looping
# AthenaWidgetExtension.appex. Other extensions (Safari, Open-In, Intentions,
# notifications) are left untouched. The output IPA is unsigned in the sense
# that our appex has no signature — the user's sideload tool (Feather/AltStore/
# SideStore/Sideloadly) re-seals the whole bundle with their cert.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IPA_PATH=""
OUTPUT_IPA=""
APPEX_PATH="$REPO_ROOT/widgets/build/Build/Products/Release-iphoneos/ApolloRebornWidgets.appex"
KEEP_STOCK=0
DO_BUILD=0

usage() {
    cat <<EOF
Usage: $0 --ipa <Apollo.ipa> [-o <output.ipa>] [options]

Options:
  --ipa <file>          Base Apollo IPA to inject into (required)
  -o, --output <file>   Output IPA (default: <ipa basename>-Widgets.ipa)
  --appex <dir>         Prebuilt ApolloRebornWidgets.appex (default: widgets/build/...)
  --build               Run xcodegen + xcodebuild to (re)build the appex first
  --keep-stock-widget   Do NOT remove the stock AthenaWidgetExtension.appex
  -h, --help            Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ipa) IPA_PATH="$2"; shift 2;;
        -o|--output) OUTPUT_IPA="$2"; shift 2;;
        --appex) APPEX_PATH="$2"; shift 2;;
        --build) DO_BUILD=1; shift;;
        --keep-stock-widget) KEEP_STOCK=1; shift;;
        -h|--help) usage; exit 0;;
        *) echo "Unknown option: $1" >&2; usage; exit 1;;
    esac
done

[[ -z "$IPA_PATH" ]] && { echo "error: --ipa is required" >&2; usage; exit 1; }
[[ ! -f "$IPA_PATH" ]] && { echo "error: IPA not found: $IPA_PATH" >&2; exit 1; }
[[ -z "$OUTPUT_IPA" ]] && OUTPUT_IPA="${IPA_PATH%.ipa}-Widgets.ipa"
# Resolve output to an absolute path before we cd anywhere.
[[ "$OUTPUT_IPA" != /* ]] && OUTPUT_IPA="$PWD/$OUTPUT_IPA"

if [[ "$DO_BUILD" == "1" ]]; then
    echo "==> Building widget extension"
    BUILD_LOG="$(mktemp -t apollo-widgets-build.XXXXXX.log)"
    if ! ( cd "$REPO_ROOT/widgets" && xcodegen generate && \
           xcodebuild -project ApolloRebornWidgets.xcodeproj -scheme ApolloRebornWidgets \
                      -sdk iphoneos -configuration Release CODE_SIGNING_ALLOWED=NO \
                      -derivedDataPath build build ) >"$BUILD_LOG" 2>&1; then
        echo "error: widget build failed. Last lines of $BUILD_LOG:" >&2
        tail -40 "$BUILD_LOG" >&2
        exit 1
    fi
    rm -f "$BUILD_LOG"
fi

[[ ! -d "$APPEX_PATH" ]] && { echo "error: appex not found: $APPEX_PATH (try --build)" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Unpacking $IPA_PATH"
unzip -q "$IPA_PATH" -d "$WORK"

APP_DIR="$(find "$WORK/Payload" -maxdepth 1 -name '*.app' -type d | head -1)"
[[ -z "$APP_DIR" ]] && { echo "error: no .app in Payload" >&2; exit 1; }
PLUGINS="$APP_DIR/PlugIns"
mkdir -p "$PLUGINS"

if [[ "$KEEP_STOCK" == "0" ]]; then
    STOCK="$PLUGINS/AthenaWidgetExtension.appex"
    if [[ -d "$STOCK" ]]; then
        echo "==> Removing stock AthenaWidgetExtension.appex (prevents WidgetKit enumeration poisoning)"
        rm -rf "$STOCK"
    fi
fi

echo "==> Injecting $(basename "$APPEX_PATH")"
rm -rf "$PLUGINS/$(basename "$APPEX_PATH")"
cp -R "$APPEX_PATH" "$PLUGINS/"
# Strip any stale signature so the re-signer starts clean.
rm -rf "$PLUGINS/$(basename "$APPEX_PATH")/_CodeSignature"

echo "==> Repacking $OUTPUT_IPA"
rm -f "$OUTPUT_IPA"
( cd "$WORK" && zip -qr "$OUTPUT_IPA" Payload )

echo "==> Done: $OUTPUT_IPA"
echo "    Remaining PlugIns:"
ls "$PLUGINS" | sed 's/^/      /'
