#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

IPA_PATH=""
DEB_PATH=""
OUTPUT_DIR="${REPO_DIR}/dist/out"
NAME_PREFIX="Apollo"

usage() {
    echo "Usage: $0 --ipa <Apollo.ipa> [--deb <packages/*.deb>] [--output-dir <dir>] [--name-prefix <name>]"
    echo ""
    echo "Builds the six distributable IPA variants used by AltStore/SideStore/Feather:"
    echo "  1. standard"
    echo "  2. no-extensions"
    echo "  3. standard + Liquid Glass"
    echo "  4. no-extensions + Liquid Glass"
    echo "  5. standard + Liquid Glass icons-only"
    echo "  6. no-extensions + Liquid Glass icons-only"
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

set_main_app_bundle_versions_in_ipa() {
    local ipa="$1"
    local short_version="$2"
    local build_version="$3"
    local work plist app_dir
    work="$(mktemp -d)"

    if ! (cd "$work" && unzip -q "$ipa"); then
        echo "Warning: could not unzip IPA for version update; leaving as-is."
        rm -rf "$work"
        return 0
    fi

    plist="$(find "$work/Payload" -maxdepth 2 -name Info.plist -path '*.app/Info.plist' -print -quit)"
    if [[ -z "$plist" || ! -f "$plist" ]]; then
        echo "Warning: could not find main app Info.plist in $(basename "$ipa"); leaving as-is."
        rm -rf "$work"
        return 0
    fi

    plutil -replace CFBundleShortVersionString -string "$short_version" "$plist"
    plutil -replace CFBundleVersion -string "$build_version" "$plist"

    app_dir="$(dirname "$plist")"
    rm -rf "$app_dir/_CodeSignature"

    rm -f "$ipa"
    (
        cd "$work"
        zip -qry "$ipa" Payload
    )

    rm -rf "$work"
}

strip_arm64e_from_substrate_in_ipa() {
    local ipa="$1"
    local work
    work="$(mktemp -d)"

    if ! (cd "$work" && unzip -q "$ipa"); then
        echo "Warning: could not unzip IPA for slice fix; leaving as-is."
        rm -rf "$work"
        return 0
    fi

    local framework_bin="$work/Payload/Apollo.app/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"
    if [[ ! -f "$framework_bin" ]]; then
        rm -rf "$work"
        return 0
    fi

    if ! lipo -info "$framework_bin" 2>/dev/null | grep -qw 'arm64e'; then
        rm -rf "$work"
        return 0
    fi

    echo "Stripping arm64e slice from CydiaSubstrate in $(basename "$ipa")..."
    if ! lipo -remove arm64e "$framework_bin" -output "$framework_bin.new" >/dev/null 2>&1; then
        echo "Warning: could not strip arm64e from CydiaSubstrate."
        rm -rf "$work"
        return 0
    fi
    mv -f "$framework_bin.new" "$framework_bin"
    rm -rf "$(dirname "$framework_bin")/_CodeSignature"

    rm -f "$ipa"
    (
        cd "$work"
        zip -qry "$ipa" Payload
    )

    rm -rf "$work"
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

for tool in unzip zip lipo python3 plutil; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: required tool '$tool' is not installed."
        exit 1
    fi
done

if ! command -v cyan >/dev/null 2>&1; then
    echo "Error: 'cyan' is required to build the no-extensions variants."
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

echo ""
echo "[1/6] Building standard injected IPA..."
bash "${REPO_DIR}/build-ipa.sh" --ipa "$IPA_PATH" --deb "$DEB_PATH" -o "$STANDARD_IPA"
# Repair the bundled "Open in Apollo" Safari extension. The GLASS variant below
# is derived from $STANDARD_IPA via patch.sh, so it inherits this fix; the two
# no-extensions variants have no appex and the script no-ops on them.
bash "${REPO_DIR}/scripts/fix-safari-extension.sh" "$STANDARD_IPA"
# Repair the bundled "Open in Apollo" Action extension (OpenInUIExtension.appex):
# inject ApolloOpenInFix.dylib (built by the openin-extension subproject) so the
# share-sheet action opens links in Apollo from any browser. Same inheritance as
# the Safari fix above — GLASS is derived from $STANDARD_IPA so it carries this
# too, and the no-extensions variants have no appex (the script no-ops).
bash "${REPO_DIR}/scripts/fix-openin-extension.sh" "$STANDARD_IPA"
set_main_app_bundle_versions_in_ipa "$STANDARD_IPA" "$TWEAK_VERSION" "$APP_BUILD_VERSION"

# Inject the Reborn widget extension into the STANDARD IPA so the GLASS and
# GLASSICONS variants (both derived from it via patch.sh below) inherit it. The
# no-extensions variants are built from $IPA_PATH with `cyan -e` and stay
# appex-free by design — widgets need an extension slot. Fail loudly if xcodegen
# is missing so release IPAs cannot silently ship without widgets.
if ! command -v xcodegen >/dev/null 2>&1; then
    echo "Error: xcodegen is required to build and inject Reborn widgets." >&2
    exit 1
fi
echo "==> Injecting Reborn widgets into standard IPA (Glass variants inherit; no-ext variants omit)"
bash "${REPO_DIR}/scripts/inject-widgets.sh" --ipa "$STANDARD_IPA" --build -o "${STANDARD_IPA}.ww"
mv "${STANDARD_IPA}.ww" "$STANDARD_IPA"

echo ""
echo "[2/6] Building no-extensions injected IPA..."
cyan -i "$IPA_PATH" -f "$DEB_PATH" -o "$NOEXT_IPA" -e
strip_arm64e_from_substrate_in_ipa "$NOEXT_IPA"
set_main_app_bundle_versions_in_ipa "$NOEXT_IPA" "$TWEAK_VERSION" "$APP_BUILD_VERSION"

echo ""
echo "[3/6] Applying Liquid Glass patch to standard IPA..."
bash "${REPO_DIR}/patch.sh" "$STANDARD_IPA" --liquid-glass -o "$GLASS_IPA"
set_main_app_bundle_versions_in_ipa "$GLASS_IPA" "$TWEAK_VERSION" "$APP_BUILD_VERSION"

echo ""
echo "[4/6] Applying Liquid Glass patch to no-extensions IPA..."
bash "${REPO_DIR}/patch.sh" "$NOEXT_IPA" --liquid-glass -o "$NOEXT_GLASS_IPA"
set_main_app_bundle_versions_in_ipa "$NOEXT_GLASS_IPA" "$TWEAK_VERSION" "$APP_BUILD_VERSION"

echo ""
echo "[5/6] Applying Liquid Glass icons-only patch to standard IPA..."
bash "${REPO_DIR}/patch.sh" "$STANDARD_IPA" --liquid-glass-icons -o "$GLASS_ICONS_IPA"
set_main_app_bundle_versions_in_ipa "$GLASS_ICONS_IPA" "$TWEAK_VERSION" "$APP_BUILD_VERSION"

echo ""
echo "[6/6] Applying Liquid Glass icons-only patch to no-extensions IPA..."
bash "${REPO_DIR}/patch.sh" "$NOEXT_IPA" --liquid-glass-icons -o "$NOEXT_GLASS_ICONS_IPA"
set_main_app_bundle_versions_in_ipa "$NOEXT_GLASS_ICONS_IPA" "$TWEAK_VERSION" "$APP_BUILD_VERSION"

echo ""
echo "Created:"
printf '  %s\n' "$STANDARD_IPA" "$NOEXT_IPA" "$GLASS_IPA" "$NOEXT_GLASS_IPA" \
                "$GLASS_ICONS_IPA" "$NOEXT_GLASS_ICONS_IPA"
