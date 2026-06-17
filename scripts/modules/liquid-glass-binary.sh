#!/bin/bash
# patch_liquid_glass_binary_in_app <app_bundle>
#
# Applies the iOS 26 Liquid Glass BINARY patches to the main app executable:
#   * vtool build-version bump (ios 15.0 / sdk 19.0) — flips IsLiquidGlass() on,
#     opting the app into the iOS 26 Liquid Glass UI runtime.
#   * removal of the duplicate @executable_path/Frameworks LC_RPATH entry, which
#     iOS 26 dyld rejects at launch.
#
# This does NOT touch the icon catalog — run the liquid-glass-assets module for
# that. Credit: @ryannair05.

patch_liquid_glass_binary_in_app() {
    local app_bundle="$1"
    local plist="$app_bundle/Info.plist"

    local executable_name
    executable_name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$plist")"
    local executable_path="$app_bundle/$executable_name"

    if ! command -v vtool >/dev/null 2>&1; then
        echo "Error: vtool not installed (brew install vtool)."
        return 1
    fi

    echo "vtool: bumping build version to ios 15.0 / sdk 19.0..."
    vtool -set-build-version ios 15.0 19.0 -replace -output "$executable_path" "$executable_path"

    echo "Checking for duplicate @executable_path/Frameworks LC_RPATH entries..."
    local rpath_count
    rpath_count=$(otool -l "$executable_path" | grep -A 2 LC_RPATH | grep "@executable_path/Frameworks" | wc -l | tr -d ' ')
    echo "  Found $rpath_count entries"
    if [[ "$rpath_count" -gt 1 ]]; then
        echo "  Removing duplicate..."
        install_name_tool -delete_rpath "@executable_path/Frameworks" "$executable_path"
    fi

    # vtool / install_name_tool invalidate the existing signature.
    rm -rf "$app_bundle/_CodeSignature"
}
