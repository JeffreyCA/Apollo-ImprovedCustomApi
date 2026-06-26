#!/bin/bash
# patch_bundle_versions_in_app <app_bundle> <short_version> <build_version>
#
# Sets CFBundleShortVersionString and CFBundleVersion in the main app's
# Info.plist so that the in-app version display and AltStore/Feather update
# checks reflect the Apollo-Reborn version rather than the original Apollo
# version baked into the stock IPA.

patch_bundle_versions_in_app() {
    local app_bundle="$1"
    local short_version="$2"
    local build_version="$3"
    local plist="$app_bundle/Info.plist"

    if [[ ! -f "$plist" ]]; then
        echo "Error: Info.plist not found: $plist"
        return 1
    fi

    plutil -replace CFBundleShortVersionString -string "$short_version" "$plist"
    plutil -replace CFBundleVersion            -string "$build_version"  "$plist"
    # Plist edits invalidate the existing code signature.
    rm -rf "$app_bundle/_CodeSignature"
    echo "Bundle versions set: $short_version ($build_version)"
}
