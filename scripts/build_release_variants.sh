#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

IPA_PATH=""
DEB_PATH=""
OUTPUT_DIR="${REPO_DIR}/dist/out"
NAME_PREFIX="Apollo"
BUILD_GLASS_ICONS=1
WIDGET_APPEX=""

usage() {
    echo "Usage: $0 --ipa <Apollo.ipa> [--deb <packages/*.deb>] [--output-dir <dir>] [--name-prefix <name>]"
    echo "          [--no-glass-icons] [--widget-appex <ApolloRebornWidgets.appex>]"
    echo ""
    echo "Builds the six distributable IPA variants used by AltStore/SideStore/Feather:"
    echo "  1. standard"
    echo "  2. no-extensions"
    echo "  3. standard + Liquid Glass"
    echo "  4. no-extensions + Liquid Glass"
    echo "  5. standard + Liquid Glass icons-only"
    echo "  6. no-extensions + Liquid Glass icons-only"
    echo ""
    echo "  --no-glass-icons   skip variants 5 and 6 (PR test builds)"
    echo "  --widget-appex     inject this prebuilt ApolloRebornWidgets.appex instead of"
    echo "                     building it with xcodegen + xcodebuild (CI cache hit)"
}

absolute_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$PWD" "${1#./}" ;;
    esac
}

find_latest_deb() {
    ls -1t "${REPO_DIR}"/packages/*.deb 2>/dev/null | head -1 || true
}

extract_apollo_version() {
    local ipa="$1"
    local plist
    plist="$(mktemp)"
    # plutil reads both binary and XML plists; App Store IPAs ship a binary
    # Info.plist, which the old grep/sed (XML-only) approach could not parse.
    unzip -p "$ipa" 'Payload/*.app/Info.plist' > "$plist" 2>/dev/null
    plutil -extract CFBundleShortVersionString raw -o - "$plist" 2>/dev/null \
        | tr -d '[:space:]'
    rm -f "$plist"
}

read_source_build_version() {
    python3 - <<'PY'
from pathlib import Path
import json

config = json.loads(Path("distribution/config.json").read_text(encoding="utf-8"))
print(config["app"]["buildVersion"])
PY
}

# Default URL schemes baked into every released IPA so the native
# ASWebAuthenticationSession sign-in works out-of-the-box for the most common
# shared-key workarounds (Dystopia / RedReader) without manual Info.plist edits.
DEFAULT_URL_SCHEMES="dystopia,redreader"

# The per-variant patch steps are now composed from shared modules run through
# the single-unpack orchestrator (scripts/apply-patches.sh). The previous inline
# helpers (inject_default_url_schemes_in_place, set_main_app_bundle_versions_in_ipa,
# strip_arm64e_from_substrate_in_ipa) each did their own unpack/repack; the
# orchestrator collapses a variant's whole patch chain into one unpack/repack.
APPLY_PATCHES="${SCRIPT_DIR}/apply-patches.sh"

# Run apply-patches.sh on an IPA in place (read it, write a temp, move back).
apply_patches_in_place() {
    local ipa="$1"; shift
    local tmp="${ipa}.patched.tmp"
    bash "$APPLY_PATCHES" --ipa "$ipa" -o "$tmp" "$@"
    mv -f "$tmp" "$ipa"
}

# Build the Reborn widget extension appex once, up front. The inject-widgets
# module injects this prebuilt appex; fail loudly if xcodegen is missing so a
# release can't silently ship widget-less.
build_widget_appex() {
    if ! command -v xcodegen >/dev/null 2>&1; then
        echo "Error: xcodegen is required to build and inject Reborn widgets." >&2
        exit 1
    fi
    echo "==> Building Reborn widget extension (xcodegen + xcodebuild)"
    (
        cd "${REPO_DIR}/widgets"
        xcodegen generate
        xcodebuild -project ApolloRebornWidgets.xcodeproj -scheme ApolloRebornWidgets \
                   -sdk iphoneos -configuration Release CODE_SIGNING_ALLOWED=NO \
                   -derivedDataPath build build
    )
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ipa)
            IPA_PATH="$2"
            shift 2
            ;;
        --deb)
            DEB_PATH="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --name-prefix)
            NAME_PREFIX="$2"
            shift 2
            ;;
        --no-glass-icons)
            BUILD_GLASS_ICONS=0
            shift
            ;;
        --widget-appex)
            WIDGET_APPEX="$2"
            shift 2
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

if [[ -z "$IPA_PATH" ]]; then
    echo "Error: --ipa is required."
    exit 1
fi

IPA_PATH="$(absolute_path "$IPA_PATH")"
OUTPUT_DIR="$(absolute_path "$OUTPUT_DIR")"

if [[ ! -f "$IPA_PATH" ]]; then
    echo "Error: IPA not found: $IPA_PATH"
    exit 1
fi

if [[ -z "$DEB_PATH" ]]; then
    DEB_PATH="$(find_latest_deb)"
    if [[ -z "$DEB_PATH" ]]; then
        echo "Error: no .deb found in packages/. Run 'make package' first or pass --deb."
        exit 1
    fi
fi
DEB_PATH="$(absolute_path "$DEB_PATH")"

if [[ ! -f "$DEB_PATH" ]]; then
    echo "Error: .deb not found: $DEB_PATH"
    exit 1
fi

if [[ -n "$WIDGET_APPEX" ]]; then
    WIDGET_APPEX="$(absolute_path "$WIDGET_APPEX")"
    if [[ ! -d "$WIDGET_APPEX" ]]; then
        echo "Error: widget appex not found: $WIDGET_APPEX"
        exit 1
    fi
fi

for tool in unzip zip lipo python3 plutil; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: required tool '$tool' is not installed."
        exit 1
    fi
done

if ! command -v cyan >/dev/null 2>&1; then
    echo "Error: 'cyan' is required to inject the tweak into the stock IPA."
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

APOLLO_VERSION="$(extract_apollo_version "$IPA_PATH")"
if [[ -z "$APOLLO_VERSION" ]]; then
    echo "Error: could not determine Apollo version from $IPA_PATH"
    exit 1
fi

TWEAK_VERSION="$(python3 - <<'PY'
from pathlib import Path
import re

control = Path("control").read_text(encoding="utf-8")
match = re.search(r"^Version:\s*(.+)$", control, re.MULTILINE)
if not match:
    raise SystemExit("missing Version in control")
# Drop the trailing dpkg packaging revision (e.g. 2.14.0-33 -> 2.14.0) so the
# IPA name and in-app version track the semantic tweak version.
print(re.sub(r"-[0-9]+$", "", match.group(1).replace("~", "-")))
PY
)"
APP_BUILD_VERSION="$(read_source_build_version)"

BASE_NAME="${NAME_PREFIX}-Reborn-${TWEAK_VERSION}"
STANDARD_IPA="${OUTPUT_DIR}/${BASE_NAME}.ipa"
NOEXT_IPA="${OUTPUT_DIR}/${BASE_NAME}-NOEXTENSIONS.ipa"
GLASS_IPA="${OUTPUT_DIR}/${BASE_NAME}-GLASS.ipa"
NOEXT_GLASS_IPA="${OUTPUT_DIR}/${BASE_NAME}-GLASS-NOEXTENSIONS.ipa"
GLASS_ICONS_IPA="${OUTPUT_DIR}/${BASE_NAME}-GLASSICONS.ipa"
NOEXT_GLASS_ICONS_IPA="${OUTPUT_DIR}/${BASE_NAME}-GLASSICONS-NOEXTENSIONS.ipa"

echo "Input IPA     : $IPA_PATH"
echo "Tweak DEB     : $DEB_PATH"
echo "Apollo version: $APOLLO_VERSION"
echo "Tweak version : $TWEAK_VERSION"
echo "Build version : $APP_BUILD_VERSION"
echo "Output dir    : $OUTPUT_DIR"

rm -f "$STANDARD_IPA" "$NOEXT_IPA" "$GLASS_IPA" "$NOEXT_GLASS_IPA" \
      "$GLASS_ICONS_IPA" "$NOEXT_GLASS_ICONS_IPA"

# Build the widget appex once; the inject-widgets module injects this prebuilt
# product into the standard variant (Glass variants inherit it). A caller that
# already has the product (CI cache hit) passes it via --widget-appex.
WIDGETS_MODULE="inject-widgets"
if [[ -n "$WIDGET_APPEX" ]]; then
    echo "==> Using prebuilt Reborn widget extension: $WIDGET_APPEX"
    WIDGETS_MODULE="inject-widgets:${WIDGET_APPEX}"
else
    build_widget_appex
fi

# Module spec fragments reused across variants.
VERSIONS_MODULE="patch-bundle-versions:${TWEAK_VERSION}:${APP_BUILD_VERSION}"
SCHEMES_MODULE="inject-url-schemes:${DEFAULT_URL_SCHEMES}"

if [[ $BUILD_GLASS_ICONS -eq 1 ]]; then
    TOTAL_STEPS=6
else
    TOTAL_STEPS=4
fi

echo ""
echo "[1/${TOTAL_STEPS}] Building standard injected IPA..."
# cyan injects the tweak dylibs + CydiaSubstrate.framework into the stock base
# IPA. Its output is only an intermediate that apply-patches.sh unpacks again
# right away, so write it stored (-c 0): deflating ~300 MB of app contents is
# the bulk of cyan's runtime, and the orchestrator recompresses on repack.
# (build-ipa.sh's repo-local injector only works on an IPA that was already
# injected once, which the stock base never is; calling cyan directly here
# skips that doomed attempt and matches the no-extensions path below.)
cyan -i "$IPA_PATH" -f "$DEB_PATH" -o "$STANDARD_IPA" -c 0
# Everything else for the standard variant in ONE unpack/repack: strip the
# CydiaSubstrate arm64e slice, install the manual + legacy Safari extensions,
# repair the Open-in-Apollo share extension, set versions, and inject the
# widget extension. The GLASS and GLASSICONS variants are derived from this IPA
# below and inherit all of it; the no-extensions variants have no appex and
# omit the extension/widget modules.
apply_patches_in_place "$STANDARD_IPA" \
    --module enable-promotion \
    --module strip-substrate-arm64e \
    --module fix-safari-extension \
    --module fix-openin-extension \
    --module "$VERSIONS_MODULE" \
    --module "$SCHEMES_MODULE" \
    --module "$WIDGETS_MODULE" \
    --module stamp-build-variant:ipa

echo ""
echo "[2/${TOTAL_STEPS}] Building no-extensions injected IPA..."
# `cyan -e` injects the tweak AND strips all PlugIns (the no-extensions variant);
# the orchestrator then strips the CydiaSubstrate arm64e slice, sets versions,
# and injects the default URL schemes in one unpack/repack.
cyan -i "$IPA_PATH" -f "$DEB_PATH" -o "$NOEXT_IPA" -e -c 0
apply_patches_in_place "$NOEXT_IPA" \
    --module enable-promotion \
    --module strip-substrate-arm64e \
    --module "$VERSIONS_MODULE" \
    --module "$SCHEMES_MODULE" \
    --module stamp-build-variant:ipa-noext

echo ""
echo "[3/${TOTAL_STEPS}] Applying Liquid Glass patch to standard IPA..."
bash "$APPLY_PATCHES" --ipa "$STANDARD_IPA" -o "$GLASS_IPA" \
    --module liquid-glass-binary \
    --module liquid-glass-assets \
    --module "$VERSIONS_MODULE" \
    --module stamp-build-variant:glass

echo ""
echo "[4/${TOTAL_STEPS}] Applying Liquid Glass patch to no-extensions IPA..."
bash "$APPLY_PATCHES" --ipa "$NOEXT_IPA" -o "$NOEXT_GLASS_IPA" \
    --module liquid-glass-binary \
    --module liquid-glass-assets \
    --module "$VERSIONS_MODULE" \
    --module stamp-build-variant:glass-noext

if [[ $BUILD_GLASS_ICONS -eq 1 ]]; then
    echo ""
    echo "[5/6] Applying Liquid Glass icons-only patch to standard IPA..."
    bash "$APPLY_PATCHES" --ipa "$STANDARD_IPA" -o "$GLASS_ICONS_IPA" \
        --module liquid-glass-assets \
        --module "$VERSIONS_MODULE" \
        --module stamp-build-variant:glassicons

    echo ""
    echo "[6/6] Applying Liquid Glass icons-only patch to no-extensions IPA..."
    bash "$APPLY_PATCHES" --ipa "$NOEXT_IPA" -o "$NOEXT_GLASS_ICONS_IPA" \
        --module liquid-glass-assets \
        --module "$VERSIONS_MODULE" \
        --module stamp-build-variant:glassicons-noext
fi

echo ""
echo "Created:"
printf '  %s\n' "$STANDARD_IPA" "$NOEXT_IPA" "$GLASS_IPA" "$NOEXT_GLASS_IPA"
if [[ $BUILD_GLASS_ICONS -eq 1 ]]; then
    printf '  %s\n' "$GLASS_ICONS_IPA" "$NOEXT_GLASS_ICONS_IPA"
fi
