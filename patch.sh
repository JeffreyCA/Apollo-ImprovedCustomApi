#!/bin/bash
set -e

# Cleanup on exit (success or failure)
cleanup() {
    if [ -d "extract_temp" ]; then
        rm -rf extract_temp
    fi
}
trap cleanup EXIT

# Generic IPA patching script
# Supports:
# - Liquid Glass patch for iOS 26 (credit: @ryannair05)
# - Custom URL schemes injection

# --- Argument Parsing ---
INPUT_IPA=""
OUTPUT_IPA="Apollo-Patched.ipa"
REMOVE_CODE_SIGNATURE="false"
LIQUID_GLASS="false"
URL_SCHEMES=""

print_usage() {
    echo "Usage: $0 <path_to_ipa> [options]"
    echo ""
    echo "Options:"
    echo "  -o, --output <file>           Output IPA filename (default: Apollo-Patched.ipa)"
    echo "  --remove-code-signature       Remove code signature from the binary"
    echo "  --liquid-glass                Apply Liquid Glass patch for iOS 26"
    echo "  --url-schemes <schemes>       Comma-separated list of URL schemes to add"
    echo "                                (e.g., 'custom,test,myapp')"
    echo ""
    echo "Examples:"
    echo "  $0 Apollo.ipa --liquid-glass"
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

if [ ! -f "$INPUT_IPA" ]; then
    echo "Error: Input IPA file not found: $INPUT_IPA"
    exit 1
fi

echo "Starting IPA patch process..."
echo "Input IPA: ${INPUT_IPA}"
echo "Output IPA: ${OUTPUT_IPA}"
echo "Remove code signature: ${REMOVE_CODE_SIGNATURE}"
echo "Liquid Glass patch: ${LIQUID_GLASS}"
echo "URL schemes: ${URL_SCHEMES:-none}"

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
zip -qr "../${OUTPUT_IPA}" Payload/
cd .. # Back to original directory

# Note: Cleanup handled by trap on EXIT

# --- 5. Final Verification ---
file_size=$(wc -c < "${OUTPUT_IPA}")
echo "Patched IPA created: ${OUTPUT_IPA} (Size: ${file_size} bytes)"

# Output the name for the workflow
echo "${OUTPUT_IPA}"
