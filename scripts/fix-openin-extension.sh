#!/bin/bash
set -euo pipefail

# Thin IPA wrapper around the fix-openin-extension module. The bundle mutation
# (install ApolloOpenInFix.dylib into Apollo.app/Frameworks/, add an @rpath
# LC_LOAD_DYLIB to OpenInUIExtension.appex, strip its signature) lives in
# scripts/modules/fix-openin-extension.sh and is shared with patch.sh and the
# apply-patches.sh orchestrator. This wrapper only unpacks the IPA, calls the
# module, and repacks. No-op when the IPA has no OpenInUIExtension.appex.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=modules/fix-openin-extension.sh
source "$SCRIPT_DIR/modules/fix-openin-extension.sh"

DYLIB_SRC=""

usage() {
    echo "Usage: $0 <path-to-ipa> [--dylib <ApolloOpenInFix.dylib>]"
    echo ""
    echo "Injects ApolloOpenInFix.dylib into Apollo.app/Frameworks/, wires an"
    echo "@rpath LC_LOAD_DYLIB into OpenInUIExtension.appex, and removes the appex"
    echo "code signature so the user's signer re-seals it. Exits 0 if the IPA has"
    echo "no OpenInUIExtension.appex."
}

if [[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && exit 0
    exit 1
fi

IPA_PATH="$1"; shift
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dylib) DYLIB_SRC="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

if [[ ! -f "$IPA_PATH" ]]; then
    echo "Error: IPA not found: $IPA_PATH"
    exit 1
fi
case "$IPA_PATH" in /*) : ;; *) IPA_PATH="$PWD/$IPA_PATH" ;; esac
if [[ -n "$DYLIB_SRC" ]]; then
    case "$DYLIB_SRC" in /*) : ;; *) DYLIB_SRC="$PWD/$DYLIB_SRC" ;; esac
fi

work="$(mktemp -d)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

if ! (cd "$work" && unzip -q "$IPA_PATH"); then
    echo "Error: could not unzip IPA: $IPA_PATH"
    exit 1
fi

app="$(find "$work/Payload" -maxdepth 1 -type d -name '*.app' -print -quit 2>/dev/null || true)"
if [[ -z "$app" || ! -d "$app" ]]; then
    echo "Error: no .app bundle found in IPA."
    exit 1
fi

fix_openin_extension_in_app "$app" "$DYLIB_SRC"

rm -f "$IPA_PATH"
if ! (cd "$work" && zip -qry "$IPA_PATH" Payload); then
    echo "Error: could not re-zip IPA after Open-in-Apollo fix."
    exit 1
fi
