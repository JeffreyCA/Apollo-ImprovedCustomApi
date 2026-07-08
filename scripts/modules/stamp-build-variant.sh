#!/bin/bash
# stamp_build_variant_in_app <app_bundle> <variant>
#
# Sets ARBuildVariant in the main app's Info.plist so the anonymous usage
# heartbeat (ApolloUsageHeartbeat.m) can include release-channel metadata, read
# back at runtime via ApolloBuildVariant().

stamp_build_variant_in_app() {
    local app_bundle="$1"
    local variant="$2"
    local plist="$app_bundle/Info.plist"

    if [[ ! -f "$plist" ]]; then
        echo "Error: Info.plist not found: $plist"
        return 1
    fi
    if [[ -z "$variant" ]]; then
        echo "Error: stamp-build-variant requires a variant string"
        return 1
    fi

    # -replace creates the key if absent and overwrites it if present, so a
    # variant derived from an already-stamped IPA (e.g. GLASS from STANDARD)
    # re-stamps cleanly to its own value.
    plutil -replace ARBuildVariant -string "$variant" "$plist"
    # Plist edits invalidate the existing code signature.
    rm -rf "$app_bundle/_CodeSignature"
    echo "Build variant stamped: $variant"
}
