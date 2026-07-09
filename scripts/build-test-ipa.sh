#!/bin/bash
# Build a Liquid Glass test IPA from the current branch.
# Requires PR #262 (origin/general-fixes) to be merged so link previews,
# comment avatars, and subreddit cards are included in every test build.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PR262_REF="${PR262_REF:-origin/general-fixes}"
BUILD_DIR="${BUILD_DIR:-/tmp/apollo-fix-push-build}"
OUTPUT_IPA="${OUTPUT_IPA:-$REPO_ROOT/packages/Apollo-Test-LiquidGlass.ipa}"
BASE_IPA="${BASE_IPA:-$REPO_ROOT/Apollo-base.ipa}"
PATCHED_IPA="${PATCHED_IPA:-/tmp/Apollo-base-liquid-glass.ipa}"
THEOS="${THEOS:-$HOME/theos}"

usage() {
    echo "Usage: $0 [-o <output.ipa>] [--skip-verify]"
    echo ""
    echo "Builds make package + Liquid Glass patch + local deb inject."
    echo "Fails unless PR #262 ($PR262_REF) is merged into the current branch."
    echo ""
    echo "Options:"
    echo "  -o, --output <file>   Output IPA path (default: packages/Apollo-Test-LiquidGlass.ipa)"
    echo "  --skip-verify         Skip PR #262 ancestry check"
    echo "  -h, --help            Show this help"
}

SKIP_VERIFY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)
            OUTPUT_IPA="$2"
            shift 2
            ;;
        --skip-verify)
            SKIP_VERIFY=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

case "$OUTPUT_IPA" in
    /*) ;;
    *) OUTPUT_IPA="$REPO_ROOT/$OUTPUT_IPA" ;;
esac

mkdir -p "$(dirname "$OUTPUT_IPA")"

if [[ "$SKIP_VERIFY" -eq 0 ]]; then
    git -C "$REPO_ROOT" fetch origin general-fixes >/dev/null 2>&1 || true
    if ! git -C "$REPO_ROOT" merge-base --is-ancestor "$PR262_REF" HEAD 2>/dev/null; then
        echo "Error: PR #262 ($PR262_REF) is not merged into the current branch."
        echo "Run: git fetch origin general-fixes && git merge origin/general-fixes"
        exit 1
    fi
    echo "PR #262 included ($(git -C "$REPO_ROOT" rev-parse --short "$PR262_REF"))"
fi

if [[ ! -f "$BASE_IPA" ]]; then
    echo "Error: base IPA not found: $BASE_IPA"
    exit 1
fi

export THEOS

echo "Syncing repo to $BUILD_DIR (Theos path must not contain spaces)..."
rsync -a --delete \
    --exclude '.git' \
    --exclude 'packages/*.ipa' \
    --exclude 'Tweaks/FLEXing' \
    --exclude 'ffmpeg-kit' \
    --exclude 'iOS26-Runtime-Headers' \
    --exclude 'iPhone18-3_26.1_23B85_Restore' \
    "$REPO_ROOT/" "$BUILD_DIR/"

cd "$BUILD_DIR"
echo "Building tweak..."
make package

DEB_PATH="$(ls -1t "$BUILD_DIR"/packages/com.apollo.reborn_*.deb 2>/dev/null | head -1 || true)"
if [[ -z "$DEB_PATH" ]]; then
    echo "Error: no com.apollo.reborn .deb found after make package"
    exit 1
fi
echo "Using deb: $DEB_PATH"

echo "Patching base IPA for Liquid Glass..."
"$BUILD_DIR/patch.sh" "$BASE_IPA" --liquid-glass -o "$PATCHED_IPA"

echo "Injecting tweak..."
"$BUILD_DIR/build-ipa.sh" --ipa "$PATCHED_IPA" --deb "$DEB_PATH" -o "$OUTPUT_IPA"

# Inject the Reborn widget extension so test builds match what ships. Guarded on
# xcodegen so the script still produces a (widget-less) IPA where it's absent.
if command -v xcodegen >/dev/null 2>&1; then
    echo "Injecting Reborn widgets..."
    "$BUILD_DIR/scripts/inject-widgets.sh" --ipa "$OUTPUT_IPA" --build -o "$OUTPUT_IPA.ww"
    mv "$OUTPUT_IPA.ww" "$OUTPUT_IPA"
else
    echo "Warning: xcodegen not found — test IPA will NOT include Reborn widgets."
fi

# Stamp the usage-heartbeat build variant (ARBuildVariant in Info.plist) so this
# test install reports a channel to beat.apolloreborn.app. Without it
# ApolloBuildVariant() falls back to "unknown", which the server stores as
# c=null. Default to a dedicated "dev" channel so local test-device beats stay
# out of the real release-variant counts (glass/ipa/…). NOTE: "dev" must be in
# the Worker's CHANNELS allowlist, otherwise the server stores it as null too.
# Override with BUILD_VARIANT=glass to simulate a specific release channel.
BUILD_VARIANT="${BUILD_VARIANT:-dev}"
echo "Stamping build variant: $BUILD_VARIANT"
"$BUILD_DIR/scripts/apply-patches.sh" --ipa "$OUTPUT_IPA" -o "$OUTPUT_IPA.bv" \
    --module "stamp-build-variant:$BUILD_VARIANT"
mv "$OUTPUT_IPA.bv" "$OUTPUT_IPA"

echo "Verifying CydiaSubstrate linkage..."
VERIFY_DIR="$(mktemp -d /tmp/apollo-ipa-verify-XXXXXX)"
unzip -q "$OUTPUT_IPA" -d "$VERIFY_DIR"
DYLIB="$VERIFY_DIR/Payload/Apollo.app/Frameworks/ApolloImprovedCustomApi.dylib"
if [[ -f "$DYLIB" ]]; then
    if otool -L "$DYLIB" | grep -Fq '/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate'; then
        echo "Error: injected dylib still links jailbreak CydiaSubstrate path"
        rm -rf "$VERIFY_DIR"
        exit 1
    fi
    otool -L "$DYLIB" | grep CydiaSubstrate || true
fi
rm -rf "$VERIFY_DIR"

echo "Test IPA ready: $OUTPUT_IPA"
