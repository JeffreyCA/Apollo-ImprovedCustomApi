#!/bin/bash
set -e

# Credit for the patching method goes to @ryannair05:
# https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/issues/63

# --- Argument Parsing ---
INPUT_IPA=""
REMOVE_CODE_SIGNATURE="false"
OUTPUT_IPA="Apollo-Patched.ipa"

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
        *)
            INPUT_IPA="$1"
            shift
            ;;
    esac
done

# Input validation
if [ -z "$INPUT_IPA" ]; then
    echo "Usage: $0 <path_to_ipa> [--remove-code-signature] [-o|--output <output_file>]"
    exit 1
fi

echo "Starting IPA patch process..."
echo "Input IPA: ${INPUT_IPA}"
echo "Output IPA: ${OUTPUT_IPA}"
echo "Remove code signature: ${REMOVE_CODE_SIGNATURE}"

# --- 1. Extract IPA ---
echo "Extracting ${INPUT_IPA}..."
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

# --- 2. Apply Modifications ---
echo "Applying modifications..."
cd "Payload/${app_bundle}"

# Install vtool if not available
if ! command -v vtool &> /dev/null; then
  echo "Installing vtool..."
  brew install vtool
fi

# Apply vtool modifications for iOS 26 compatibility
echo "Running vtool to set build version for iOS 26..."
vtool -set-build-version ios 15.0 19.0 -replace -output "Apollo" "Apollo"

# Check for duplicate @executable_path/Frameworks LC_RPATH entries
echo "Checking for duplicate LC_RPATH entries..."
executable_path_count=$(otool -l "Apollo" | grep -A 2 LC_RPATH | grep "@executable_path/Frameworks" | wc -l | tr -d ' ')
echo "Found $executable_path_count @executable_path/Frameworks LC_RPATH entries"

if [ "$executable_path_count" -gt 1 ]; then
  echo "Removing duplicate @executable_path/Frameworks LC_RPATH entry..."
  install_name_tool -delete_rpath "@executable_path/Frameworks" "Apollo"
  echo "Duplicate LC_RPATH entry removed"
fi

# Remove code signature if requested
if [ "${REMOVE_CODE_SIGNATURE}" == "true" ]; then
  echo "Removing code signature..."
  codesign --remove-signature "Apollo" || true
else
  echo "Keeping code signature."
fi

cd ../.. # Back to extract_temp directory

# --- 3. Repackage IPA ---
echo "Repackaging modified IPA..."
zip -qr "../${OUTPUT_IPA}" Payload/
cd .. # Back to original directory

# --- 4. Cleanup ---
rm -rf extract_temp
echo "Cleanup complete."

# --- 5. Final Verification ---
file_size=$(wc -c < "${OUTPUT_IPA}")
echo "✅ Patched IPA created: ${OUTPUT_IPA} (Size: ${file_size} bytes)"

# Output the name for the workflow
echo "${OUTPUT_IPA}"
