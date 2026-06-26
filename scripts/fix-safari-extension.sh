#!/bin/bash
set -euo pipefail

# Thin IPA wrapper around the fix-safari-extension module. The bundle mutation
# (overlay safari-extension/{content.js,manifest.json} onto Apollofari.appex,
# strip its signature) lives in scripts/modules/fix-safari-extension.sh and is
# shared with patch.sh and the apply-patches.sh orchestrator. This wrapper only
# unpacks the IPA, calls the module, and repacks. No-op when the IPA has no
# Apollofari.appex (the no-extensions variants).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=modules/fix-safari-extension.sh
source "$SCRIPT_DIR/modules/fix-safari-extension.sh"

usage() {
    echo "Usage: $0 <path-to-ipa>"
    echo ""
    echo "Overlays safari-extension/{content.js,manifest.json} onto Apollofari.appex"
    echo "and removes the appex code signature so the user's signer re-seals it."
    echo "Exits 0 without changes if the IPA contains no Apollofari.appex."
}

if [[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && exit 0
    exit 1
fi

IPA_PATH="$1"
if [[ ! -f "$IPA_PATH" ]]; then
    echo "Error: IPA not found: $IPA_PATH"
    exit 1
fi
case "$IPA_PATH" in /*) : ;; *) IPA_PATH="$PWD/$IPA_PATH" ;; esac

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

fix_safari_extension_in_app "$app"

rm -f "$IPA_PATH"
if ! (cd "$work" && zip -qry "$IPA_PATH" Payload); then
    echo "Error: could not re-zip IPA after Safari extension fix."
    exit 1
fi
