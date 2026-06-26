#!/bin/bash
# fix_openin_extension_in_app <app_bundle> [dylib_path]
#
# Injects ApolloOpenInFix.dylib into Apollo.app/Frameworks/ and wires an @rpath
# LC_LOAD_DYLIB into OpenInUIExtension.appex inside an unpacked .app bundle, in
# place. No-op (return 0) when the bundle has no OpenInUIExtension.appex.
#
# The stock action calls the deprecated single-arg -[UIApplication openURL:]
# which iOS 18+ force-fails. The dylib swizzles it to a non-deprecated path. The
# dylib goes in the SHARED Frameworks/ (not the appex root) so the user's signer
# re-signs it; the appex's existing rpath resolves @rpath/ from there.

_OPENIN_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# modules/ lives under scripts/, so scripts/ is one level up and the repo two.
_OPENIN_SCRIPT_DIR="$(cd "${_OPENIN_MODULE_DIR}/.." && pwd)"
_OPENIN_REPO_DIR="$(cd "${_OPENIN_MODULE_DIR}/../.." && pwd)"

_OPENIN_DYLIB_NAME="ApolloOpenInFix.dylib"
_OPENIN_STALE_NAMES=("ApolloOpenInHook.dylib")

fix_openin_extension_in_app() {
    local app_bundle="$1"
    local dylib_src="${2:-}"

    # Resolve the dylib from the openin-extension subproject build output unless
    # an explicit path was given.
    if [[ -z "$dylib_src" ]]; then
        local candidates=(
            "${_OPENIN_REPO_DIR}/openin-extension/.theos/obj/${_OPENIN_DYLIB_NAME}"
            "${_OPENIN_REPO_DIR}/.theos/obj/${_OPENIN_DYLIB_NAME}"
            "${_OPENIN_REPO_DIR}/openin-extension/.theos/obj/debug/${_OPENIN_DYLIB_NAME}"
            "${_OPENIN_REPO_DIR}/.theos/obj/debug/${_OPENIN_DYLIB_NAME}"
        )
        local cand
        for cand in "${candidates[@]}"; do
            if [[ -f "$cand" ]]; then dylib_src="$cand"; break; fi
        done
    fi

    local appex
    appex="$(find "$app_bundle/PlugIns" -type d -name "OpenInUIExtension.appex" -print -quit 2>/dev/null || true)"
    if [[ -z "$appex" || ! -d "$appex" ]]; then
        echo "No OpenInUIExtension.appex — skipping Open-in-Apollo fix."
        return 0
    fi

    if [[ -z "$dylib_src" || ! -f "$dylib_src" ]]; then
        echo "Error: ApolloOpenInFix.dylib not found. Build it (make package) or pass an explicit path."
        return 1
    fi

    local appex_bin="$appex/OpenInUIExtension"
    if [[ ! -f "$appex_bin" ]]; then
        echo "Error: appex executable missing: $appex_bin"
        return 1
    fi

    echo "Repairing Open-in-Apollo action extension..."

    # Drop any dead prior-attempt dylibs (loose in the appex, or a stale copy).
    local stale
    for stale in "${_OPENIN_STALE_NAMES[@]}" "$_OPENIN_DYLIB_NAME"; do
        if [[ -f "$appex/$stale" ]]; then
            rm -f "$appex/$stale"
            echo "  removed stale $appex/$stale"
        fi
    done

    local frameworks="$app_bundle/Frameworks"
    mkdir -p "$frameworks"
    cp "$dylib_src" "$frameworks/$_OPENIN_DYLIB_NAME"
    echo "  installed Frameworks/$_OPENIN_DYLIB_NAME"

    python3 "$_OPENIN_SCRIPT_DIR/macho_add_load_dylib.py" "$appex_bin" "@rpath/$_OPENIN_DYLIB_NAME"

    if ! otool -L "$appex_bin" | grep -q "@rpath/$_OPENIN_DYLIB_NAME"; then
        echo "Error: LC_LOAD_DYLIB for $_OPENIN_DYLIB_NAME not present after patch."
        return 1
    fi

    rm -rf "$appex/_CodeSignature"
    echo "Open-in-Apollo extension repaired: Frameworks/$_OPENIN_DYLIB_NAME + @rpath LC_LOAD_DYLIB added."
}
