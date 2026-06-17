#!/bin/bash
# Strip the legacy arm64e slice from bundled CydiaSubstrate. iOS 26 dyld rejects
# the arm64e.old mach-o subtype and aborts at launch on arm64e devices.

strip_substrate_arm64e_in_app() {
    local app_bundle="$1"
    local framework_bin="$app_bundle/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"

    if [[ ! -f "$framework_bin" ]]; then
        return 0
    fi

    if ! command -v lipo >/dev/null 2>&1; then
        echo "Warning: lipo not installed; skipping CydiaSubstrate arm64e strip."
        return 0
    fi

    if ! lipo -info "$framework_bin" 2>/dev/null | grep -qw 'arm64e'; then
        return 0
    fi

    echo "Stripping arm64e slice from CydiaSubstrate (iOS 26 dyld fix)..."
    if ! lipo -remove arm64e "$framework_bin" -output "$framework_bin.new" 2>&1; then
        echo "Warning: lipo -remove arm64e failed; IPA may crash on iOS 26."
        return 0
    fi
    mv -f "$framework_bin.new" "$framework_bin"
    rm -rf "$(dirname "$framework_bin")/_CodeSignature"
}

# Thin IPA wrapper: unpack → strip → repack. Used by callers that operate on a
# whole IPA rather than an unpacked bundle.
strip_substrate_arm64e_in_ipa() {
    local ipa="$1"
    local work
    work="$(mktemp -d)"

    if ! (cd "$work" && unzip -q "$ipa"); then
        echo "Warning: could not unzip IPA for slice fix; leaving as-is."
        rm -rf "$work"
        return 0
    fi

    local app_bundle
    app_bundle="$(find "$work/Payload" -maxdepth 1 -name '*.app' -type d | head -1)"
    if [[ -n "$app_bundle" ]]; then
        strip_substrate_arm64e_in_app "$app_bundle"
    fi

    rm -f "$ipa"
    if ! (cd "$work" && zip -qry "$ipa" Payload); then
        echo "Error: could not re-zip IPA after slice fix."
        rm -rf "$work"
        return 1
    fi

    rm -rf "$work"
}

# Backward-compatible aliases used by inject-deb-local.sh and any callers that
# pre-date the modules refactor.
strip_arm64e_from_substrate_in_app() { strip_substrate_arm64e_in_app "$@"; }
strip_arm64e_from_substrate_in_ipa() { strip_substrate_arm64e_in_ipa "$@"; }
