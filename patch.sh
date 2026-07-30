#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULES_DIR="${SCRIPT_DIR}/scripts/modules"

# The patch operations now live in shared modules (also used by the
# apply-patches.sh orchestrator), so patch.sh and the release builder can't
# drift. This script keeps its long-standing CLI and does a single
# unpack → apply modules → repack.
# shellcheck source=scripts/modules/liquid-glass-binary.sh
source "${MODULES_DIR}/liquid-glass-binary.sh"
# shellcheck source=scripts/modules/liquid-glass-assets.sh
source "${MODULES_DIR}/liquid-glass-assets.sh"
# shellcheck source=scripts/modules/inject-url-schemes.sh
source "${MODULES_DIR}/inject-url-schemes.sh"
# shellcheck source=scripts/modules/fix-safari-extension.sh
source "${MODULES_DIR}/fix-safari-extension.sh"
# shellcheck source=scripts/modules/fix-openin-extension.sh
source "${MODULES_DIR}/fix-openin-extension.sh"
# shellcheck source=scripts/modules/enable-promotion.sh
source "${MODULES_DIR}/enable-promotion.sh"

# Cleanup on exit (success or failure)
cleanup() {
    if [ -d "extract_temp" ]; then
        rm -rf extract_temp
    fi
}
trap cleanup EXIT

# Generic IPA patching script (DOES NOT inject the tweak)
# Supports:
# - Liquid Glass patch for iOS 26 (credit: @ryannair05)
# - Liquid Glass icons only (icon catalog + plist metadata, no iOS 26 UI chrome)
# - Custom URL schemes injection

# --- Argument Parsing ---
INPUT_IPA=""
OUTPUT_IPA="Apollo-Patched.ipa"
REMOVE_CODE_SIGNATURE="false"
LIQUID_GLASS="false"
LIQUID_GLASS_ICONS_ONLY="false"
URL_SCHEMES=""
OUTPUT_IPA_PATH=""
FIX_SAFARI_EXTENSION="false"
FIX_OPENIN_EXTENSION="false"

print_usage() {
    echo "Usage: $0 <path_to_ipa> [options]"
    echo ""
    echo "Options:"
    echo "  -o, --output <file>           Output IPA filename (default: Apollo-Patched.ipa)"
    echo "  --remove-code-signature       Remove code signature from the binary"
    echo "  --liquid-glass                Apply Liquid Glass patch for iOS 26"
    echo "  --fix-safari-extension        Repair the bundled 'Open in Apollo' Safari extension"
    echo "  --fix-openin-extension        Repair the bundled 'Open in Apollo' share-sheet action"
    echo "                                (needs the openin-extension dylib; run 'make package' first)"
    echo "  --liquid-glass-icons          Bundle the Liquid Glass icon catalog only,"
    echo "                                without the iOS 26 UI chrome (no vtool"
    echo "                                build-version bump). Cannot be combined"
    echo "                                with --liquid-glass."
    echo "  --url-schemes <schemes>       Comma-separated list of URL schemes to add"
    echo "                                (e.g., 'custom,test,myapp')"
    echo ""
    echo "Examples:"
    echo "  $0 Apollo.ipa --liquid-glass"
    echo "  $0 Apollo.ipa --liquid-glass-icons"
    echo "  $0 Apollo.ipa --url-schemes 'custom,test'"
    echo "  $0 Apollo.ipa --liquid-glass --url-schemes 'custom' -o MyApp.ipa"
}

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -o|--output)
            OUTPUT_IPA="$2"
            shift; shift
            ;;
        --remove-code-signature)
            REMOVE_CODE_SIGNATURE="true"
            shift
            ;;
        --liquid-glass)
            LIQUID_GLASS="true"
            shift
            ;;
        --fix-safari-extension)
            FIX_SAFARI_EXTENSION="true"
            shift
            ;;
        --fix-openin-extension)
            FIX_OPENIN_EXTENSION="true"
            shift
            ;;
        --liquid-glass-icons)
            LIQUID_GLASS_ICONS_ONLY="true"
            shift
            ;;
        --url-schemes)
            URL_SCHEMES="$2"
            shift; shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        -*)
            echo "Error: Unknown option $1"
            print_usage
            exit 1
            ;;
        *)
            INPUT_IPA="$1"
            shift
            ;;
    esac
done

# Input validation
if [ -z "$INPUT_IPA" ]; then
    print_usage
    exit 1
fi

# --liquid-glass and --liquid-glass-icons are mutually exclusive: the former
# bumps LC_BUILD_VERSION to opt the app into the iOS 26 UI runtime, which is
# the exact behavior the icons-only build is meant to avoid.
if [ "${LIQUID_GLASS}" == "true" ] && [ "${LIQUID_GLASS_ICONS_ONLY}" == "true" ]; then
    echo "Error: --liquid-glass and --liquid-glass-icons are mutually exclusive."
    exit 1
fi

if [ ! -f "$INPUT_IPA" ]; then
    echo "Error: Input IPA file not found: $INPUT_IPA"
    exit 1
fi

echo "Starting IPA patch process..."
echo "Input IPA: ${INPUT_IPA}"
echo "Output IPA: ${OUTPUT_IPA}"
echo "Remove code signature: ${REMOVE_CODE_SIGNATURE}"
echo "Liquid Glass patch: ${LIQUID_GLASS}"
echo "Fix Safari extension: ${FIX_SAFARI_EXTENSION}"
echo "Fix Open-in-Apollo action: ${FIX_OPENIN_EXTENSION}"
echo "Liquid Glass icons only: ${LIQUID_GLASS_ICONS_ONLY}"
echo "URL schemes: ${URL_SCHEMES:-none}"

if [[ "${OUTPUT_IPA}" = /* ]]; then
    OUTPUT_IPA_PATH="${OUTPUT_IPA}"
else
    OUTPUT_IPA_PATH="$(pwd)/${OUTPUT_IPA}"
fi

# --- 1. Extract IPA ---
echo "Extracting ${INPUT_IPA}..."
rm -rf extract_temp
unzip -q "${INPUT_IPA}" -d extract_temp

if [ ! -d "extract_temp/Payload" ]; then
    echo "Error: Invalid IPA structure - Payload directory not found"
    exit 1
fi

# Find the app bundle dynamically (absolute path so the modules don't depend on
# the current working directory).
app_bundle_name=$(ls extract_temp/Payload/ | grep '\.app$' | head -1)
if [ -z "$app_bundle_name" ]; then
    echo "Error: No .app bundle found in Payload directory"
    exit 1
fi
APP_BUNDLE="$(pwd)/extract_temp/Payload/${app_bundle_name}"
echo "Found app bundle: ${app_bundle_name}"

# --- 2. Apply Modifications (via shared modules) ---
echo "Applying modifications..."

# Every patched Apollo build should expose the device's full adaptive refresh
# range, regardless of whether Liquid Glass is also enabled.
enable_promotion_in_app "$APP_BUNDLE"

# 2a. Liquid Glass (binary + assets)
if [ "${LIQUID_GLASS}" == "true" ]; then
    echo "Applying Liquid Glass patch for iOS 26..."
    # Convenience: auto-install vtool if missing (long-standing patch.sh behavior).
    if ! command -v vtool &>/dev/null; then
        echo "Installing vtool..."
        brew install vtool
    fi
    patch_liquid_glass_binary_in_app "$APP_BUNDLE"
    patch_liquid_glass_assets_in_app "$APP_BUNDLE"
fi

# 2a-icons. Liquid Glass icons-only (assets only, no SDK bump)
if [ "${LIQUID_GLASS_ICONS_ONLY}" == "true" ]; then
    echo "Applying Liquid Glass icons-only patch (no iOS 26 UI chrome)..."
    patch_liquid_glass_assets_in_app "$APP_BUNDLE"
fi

# 2b. URL schemes
if [ -n "$URL_SCHEMES" ]; then
    inject_url_schemes_in_app "$APP_BUNDLE" "$URL_SCHEMES"
fi

# 2c. Extension fixes (operate on the unpacked bundle, before repack — no extra
# unpack/repack cycle). Each no-ops if its appex is absent.
if [ "${FIX_SAFARI_EXTENSION}" == "true" ]; then
    fix_safari_extension_in_app "$APP_BUNDLE"
fi
if [ "${FIX_OPENIN_EXTENSION}" == "true" ]; then
    fix_openin_extension_in_app "$APP_BUNDLE"
fi

# 2d. Remove code signature
if [ "${REMOVE_CODE_SIGNATURE}" == "true" ]; then
    echo "Removing code signature..."
    executable_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "${APP_BUNDLE}/Info.plist")
    codesign --remove-signature "${APP_BUNDLE}/${executable_name}" || true
else
    echo "Keeping code signature."
fi

# --- 3. Repackage IPA ---
echo "Repackaging modified IPA..."
( cd extract_temp && zip -qr "${OUTPUT_IPA_PATH}" Payload/ )

# Note: Cleanup handled by trap on EXIT

# --- 4. Final Verification ---
file_size=$(wc -c < "${OUTPUT_IPA_PATH}")
echo "Patched IPA created: ${OUTPUT_IPA_PATH} (Size: ${file_size} bytes)"

# Output the name for the workflow
echo "${OUTPUT_IPA_PATH}"
