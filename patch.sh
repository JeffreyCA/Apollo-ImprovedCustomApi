#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIQUID_GLASS_ASSETS_CAR="${SCRIPT_DIR}/liquid-glass/prebuilt/Assets.car"
LIQUID_GLASS_ICONS_REGISTRY="${SCRIPT_DIR}/liquid-glass/icons.json"
LIQUID_GLASS_ICON_NAME="AppIcon"
LIQUID_GLASS_IPAD_ICON_FILES=("AppIcon60x60" "AppIcon76x76")
LIQUID_GLASS_IPHONE_ICON_FILES=("AppIcon60x60")

load_liquid_glass_alternate_icons() {
    # Register every icon from icons.json as a CFBundleAlternateIcons entry
    # (including the primary, so setAlternateIconName:<primary> is a valid
    # no-op switch back to the primary asset).
    local i=0 id
    while id=$(plutil -extract "icons.${i}.id" raw -o - "$LIQUID_GLASS_ICONS_REGISTRY" 2>/dev/null); do
        echo "$id"
        ((i++))
    done
}

LIQUID_GLASS_ALTERNATE_ICONS=()
while IFS= read -r line; do
    [[ -n "$line" ]] && LIQUID_GLASS_ALTERNATE_ICONS+=("$line")
done < <(load_liquid_glass_alternate_icons)

plist_set_string() {
    local path="$1"
    local value="$2"

    if /usr/libexec/PlistBuddy -c "Print :${path}" "Info.plist" &>/dev/null; then
        /usr/libexec/PlistBuddy -c "Set :${path} ${value}" "Info.plist"
    else
        /usr/libexec/PlistBuddy -c "Add :${path} string ${value}" "Info.plist"
    fi
}

plist_ensure_dict() {
    local path="$1"

    if ! /usr/libexec/PlistBuddy -c "Print :${path}" "Info.plist" &>/dev/null; then
        /usr/libexec/PlistBuddy -c "Add :${path} dict" "Info.plist"
    fi
}

plist_replace_string_array() {
    local path="$1"
    shift

    if /usr/libexec/PlistBuddy -c "Print :${path}" "Info.plist" &>/dev/null; then
        /usr/libexec/PlistBuddy -c "Delete :${path}" "Info.plist"
    fi
    /usr/libexec/PlistBuddy -c "Add :${path} array" "Info.plist"

    for value in "$@"; do
        /usr/libexec/PlistBuddy -c "Add :${path}: string ${value}" "Info.plist"
    done
}

ensure_liquid_glass_icon_metadata() {
    plist_ensure_dict "CFBundleIcons"
    plist_ensure_dict "CFBundleIcons:CFBundlePrimaryIcon"
    plist_ensure_dict "CFBundleIcons:CFBundleAlternateIcons"
    plist_ensure_dict "CFBundleIcons~ipad"
    plist_ensure_dict "CFBundleIcons~ipad:CFBundlePrimaryIcon"
    plist_ensure_dict "CFBundleIcons~ipad:CFBundleAlternateIcons"

    plist_set_string "CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName" "${LIQUID_GLASS_ICON_NAME}"
    plist_set_string "CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconName" "${LIQUID_GLASS_ICON_NAME}"
    plist_replace_string_array "CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles" "${LIQUID_GLASS_IPHONE_ICON_FILES[@]}"
    plist_replace_string_array "CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconFiles" "${LIQUID_GLASS_IPAD_ICON_FILES[@]}"

    for icon_name in "${LIQUID_GLASS_ALTERNATE_ICONS[@]}"; do
        plist_ensure_dict "CFBundleIcons:CFBundleAlternateIcons:${icon_name}"
        plist_ensure_dict "CFBundleIcons~ipad:CFBundleAlternateIcons:${icon_name}"
        plist_set_string "CFBundleIcons:CFBundleAlternateIcons:${icon_name}:CFBundleIconName" "${icon_name}"
        plist_set_string "CFBundleIcons~ipad:CFBundleAlternateIcons:${icon_name}:CFBundleIconName" "${icon_name}"
    done
}

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
cd extract_temp

if [ ! -d "Payload" ]; then
    echo "Error: Invalid IPA structure - Payload directory not found"
    exit 1
fi

# Find the app bundle dynamically
app_bundle=$(ls Payload/ | grep '\.app$' | head -1)
if [ -z "$app_bundle" ]; then
    echo "Error: No .app bundle found in Payload directory"
    exit 1
fi
echo "Found app bundle: ${app_bundle}"

# Get the executable name from Info.plist
PLIST_PATH="Payload/${app_bundle}/Info.plist"
EXECUTABLE_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$PLIST_PATH")
echo "Executable name: ${EXECUTABLE_NAME}"

# --- 2. Apply Modifications ---
echo "Applying modifications..."
cd "Payload/${app_bundle}"

# --- 2a. Liquid Glass Patch ---
if [ "${LIQUID_GLASS}" == "true" ]; then
    echo "Applying Liquid Glass patch for iOS 26..."

    # Install vtool if not available
    if ! command -v vtool &> /dev/null; then
        echo "Installing vtool..."
        brew install vtool
    fi

    # Apply vtool modifications for iOS 26 compatibility
    echo "Running vtool to set build version for iOS 26..."
    vtool -set-build-version ios 15.0 19.0 -replace -output "${EXECUTABLE_NAME}" "${EXECUTABLE_NAME}"

    # Check for duplicate @executable_path/Frameworks LC_RPATH entries
    echo "Checking for duplicate LC_RPATH entries..."
    executable_path_count=$(otool -l "${EXECUTABLE_NAME}" | grep -A 2 LC_RPATH | grep "@executable_path/Frameworks" | wc -l | tr -d ' ')
    echo "Found $executable_path_count @executable_path/Frameworks LC_RPATH entries"

    if [ "$executable_path_count" -gt 1 ]; then
        echo "Removing duplicate @executable_path/Frameworks LC_RPATH entry..."
        install_name_tool -delete_rpath "@executable_path/Frameworks" "${EXECUTABLE_NAME}"
        echo "Duplicate LC_RPATH entry removed"
    fi

    if [ ! -f "${LIQUID_GLASS_ASSETS_CAR}" ]; then
        echo "Error: Liquid Glass asset catalog not found at ${LIQUID_GLASS_ASSETS_CAR}"
        exit 1
    fi

    # Sanity check against a truncated/corrupt asset catalog. The real
    # Assets.car is ~80 MB; patching with a stub silently produces a broken
    # IPA that crashes on launch (see issue #314), so fail early with a fix.
    asset_size=$(wc -c < "${LIQUID_GLASS_ASSETS_CAR}" | tr -d ' ')
    if [ "${asset_size}" -lt 4096 ]; then
        echo "Error: ${LIQUID_GLASS_ASSETS_CAR} looks truncated or corrupt (${asset_size} bytes), not the real asset catalog."
        echo "       Re-fetch the repository contents and try again."
        exit 1
    fi

    echo "Replacing Assets.car with prebuilt Liquid Glass asset catalog..."
    cp "${LIQUID_GLASS_ASSETS_CAR}" "Assets.car"

    echo "Updating app icon metadata for Liquid Glass multi-icon catalog..."
    ensure_liquid_glass_icon_metadata
fi

# --- 2a-icons. Liquid Glass icons-only Patch ---
# Same Assets.car + plist work as --liquid-glass, but skip the vtool
# build-version bump. That bump is what opts the app into the iOS 26 Liquid
# Glass UI runtime, which replaces several legacy UIKit behaviors (notably
# the bottom-tab horizontal swipe gesture). Users who want the new icon
# catalog without that runtime swap can use this variant instead.
if [ "${LIQUID_GLASS_ICONS_ONLY}" == "true" ]; then
    echo "Applying Liquid Glass icons-only patch (no iOS 26 UI chrome)..."

    if [ ! -f "${LIQUID_GLASS_ASSETS_CAR}" ]; then
        echo "Error: Liquid Glass asset catalog not found at ${LIQUID_GLASS_ASSETS_CAR}"
        exit 1
    fi

    echo "Replacing Assets.car with prebuilt Liquid Glass asset catalog..."
    cp "${LIQUID_GLASS_ASSETS_CAR}" "Assets.car"

    echo "Updating app icon metadata for Liquid Glass multi-icon catalog..."
    ensure_liquid_glass_icon_metadata
fi

# --- 2b. URL Schemes Patch ---
if [ -n "$URL_SCHEMES" ]; then
    echo "Adding custom URL schemes..."

    # Check if CFBundleURLTypes exists and find entry with CFBundleURLSchemes
    url_type_index=0
    found_schemes=false

    if /usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes" "Info.plist" &>/dev/null; then
        # CFBundleURLTypes exists, find entry with CFBundleURLSchemes
        while /usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes:${url_type_index}" "Info.plist" &>/dev/null; do
            if /usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes:${url_type_index}:CFBundleURLSchemes" "Info.plist" &>/dev/null; then
                found_schemes=true
                break
            fi
            url_type_index=$((url_type_index + 1))
        done

        if [ "$found_schemes" == "false" ]; then
            # CFBundleURLTypes exists but no entry has CFBundleURLSchemes, add to first entry
            echo "Adding CFBundleURLSchemes to existing URL type entry..."
            /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "Info.plist"
            url_type_index=0
            found_schemes=true
        fi
    else
        # CFBundleURLTypes doesn't exist, create it
        echo "Creating CFBundleURLTypes array..."
        /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" "Info.plist"
        /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0 dict" "Info.plist"
        /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "Info.plist"
        url_type_index=0
        found_schemes=true
    fi

    # Get current schemes for display
    echo "Current URL schemes:"
    /usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes:${url_type_index}:CFBundleURLSchemes" "Info.plist" 2>/dev/null || echo "  (none)"

    # Parse comma-separated schemes, trim whitespace, and add each one
    IFS=',' read -ra SCHEMES <<< "$URL_SCHEMES"
    for scheme in "${SCHEMES[@]}"; do
        # Trim leading and trailing whitespace
        scheme=$(echo "$scheme" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        if [ -n "$scheme" ]; then
            # Check if scheme already exists (use grep -F for literal match)
            # PlistBuddy output format has leading spaces, so we check if the scheme appears as a word
            existing=$(/usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes:${url_type_index}:CFBundleURLSchemes" "Info.plist" 2>/dev/null | grep -cxF "    ${scheme}" || true)

            if [ "$existing" -eq 0 ]; then
                echo "Adding URL scheme: ${scheme}"
                /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:${url_type_index}:CFBundleURLSchemes: string ${scheme}" "Info.plist"
            else
                echo "URL scheme already exists, skipping: ${scheme}"
            fi
        fi
    done

    echo "Updated URL schemes:"
    /usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes:${url_type_index}:CFBundleURLSchemes" "Info.plist"
fi

# --- 2c. Remove Code Signature ---
if [ "${REMOVE_CODE_SIGNATURE}" == "true" ]; then
    echo "Removing code signature..."
    codesign --remove-signature "${EXECUTABLE_NAME}" || true
else
    echo "Keeping code signature."
fi

cd ../.. # Back to extract_temp directory

# --- 3. Repackage IPA ---
echo "Repackaging modified IPA..."
zip -qr "${OUTPUT_IPA_PATH}" Payload/
cd .. # Back to original directory

# --- 4. Fix Safari Extension ---
# Done after repackaging so it operates on the finished IPA (it re-zips in
# place). No-op if the IPA has no Apollofari.appex.
if [ "${FIX_SAFARI_EXTENSION}" == "true" ]; then
    echo "Repairing bundled Safari extension..."
    bash "${SCRIPT_DIR}/scripts/fix-safari-extension.sh" "${OUTPUT_IPA_PATH}"
fi

# --- 4b. Fix Open-in-Apollo Action extension ---
# Same timing/rationale as the Safari fix. No-op if the IPA has no
# OpenInUIExtension.appex. Resolves the dylib from the openin-extension subproject
# build output (run 'make package' first, or pass it via the script's --dylib).
if [ "${FIX_OPENIN_EXTENSION}" == "true" ]; then
    echo "Repairing bundled Open-in-Apollo action extension..."
    bash "${SCRIPT_DIR}/scripts/fix-openin-extension.sh" "${OUTPUT_IPA_PATH}"
fi

# Note: Cleanup handled by trap on EXIT

# --- 5. Final Verification ---
file_size=$(wc -c < "${OUTPUT_IPA_PATH}")
echo "Patched IPA created: ${OUTPUT_IPA_PATH} (Size: ${file_size} bytes)"

# Output the name for the workflow
echo "${OUTPUT_IPA_PATH}"
