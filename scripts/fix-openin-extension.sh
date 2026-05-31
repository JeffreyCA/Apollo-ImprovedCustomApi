#!/bin/bash
set -euo pipefail

# Repairs Apollo's bundled "Open in Apollo" share-sheet Action extension
# (OpenInUIExtension.appex) inside an IPA, in place.
#
# The stock -[ActionViewController openURL:] walks the UIResponder chain and
# calls the DEPRECATED single-arg -[UIApplication openURL:] via performSelector:.
# iOS 18+ force-fails that exact selector ("BUG IN CLIENT OF UIKIT ... Force
# returning false (NO)."), so the bundled action does nothing from any browser.
#
# We inject ApolloOpenInFix.dylib and add an LC_LOAD_DYLIB to the appex so it
# loads. Its constructor swizzles -[ActionViewController openURL:] to open the
# (already apollo://) URL via a NON-deprecated path: responder chain -> real
# UIApplication -> openURL:options:completionHandler: (Technique A), falling back
# to -[NSExtensionContext openURL:completionHandler:] (Technique B).
#
# Placement: the dylib goes in the SHARED Apollo.app/Frameworks/ (NOT the appex
# root) and is loaded into the appex via @rpath. This matters for signing: the
# user's signer (Sideloadly/zsign, AltStore, ...) reliably re-signs dylibs in
# Frameworks/ -- the main tweak dylib lives there too -- but a loose dylib in the
# appex root is skipped, left unsigned, and iOS 26's code-signing monitor then
# kills the extension at launch ("CODESIGNING Invalid Page"). The appex already
# has an rpath (@executable_path/../../Frameworks) that resolves to the app's
# Frameworks/, so @rpath/ApolloOpenInFix.dylib loads from there.
#
# The tweak dylib can't do this at runtime -- the extension runs in its own
# process the main-app tweak can't reach -- so the repair happens at IPA-package
# time. Mirrors scripts/fix-safari-extension.sh.
#
# No-op (exit 0) when the IPA has no OpenInUIExtension.appex (no-extensions variants).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Where to find the built dylib. Override with --dylib. When not overridden it is
# resolved from the openin-extension Theos subproject's build output below — the
# subproject builds into its OWN .theos/obj (debug for `make package`, the
# unsuffixed dir for FINALPACKAGE=1 release builds).
DYLIB_SRC=""
DYLIB_CANDIDATES=(
    "${REPO_DIR}/openin-extension/.theos/obj/debug/ApolloOpenInFix.dylib"
    "${REPO_DIR}/openin-extension/.theos/obj/ApolloOpenInFix.dylib"
)
DYLIB_NAME="ApolloOpenInFix.dylib"
STALE_NAMES=("ApolloOpenInHook.dylib")  # dead prior-attempt artifacts, removed if present

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
# Resolve the dylib from the subproject build output unless --dylib was given.
if [[ -z "$DYLIB_SRC" ]]; then
    for cand in "${DYLIB_CANDIDATES[@]}"; do
        if [[ -f "$cand" ]]; then DYLIB_SRC="$cand"; break; fi
    done
fi
if [[ -z "$DYLIB_SRC" || ! -f "$DYLIB_SRC" ]]; then
    echo "Error: ApolloOpenInFix.dylib not found."
    echo "  Build it first (it is a SUBPROJECT of the root Makefile): make package"
    echo "  Looked in:"
    printf '    %s\n' "${DYLIB_CANDIDATES[@]}"
    echo "  Or pass an explicit --dylib <path>."
    exit 1
fi
for tool in unzip zip otool python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: required tool '$tool' is not installed."
        exit 1
    fi
done

# Resolve to absolute so the re-zip targets the same file regardless of cwd.
case "$IPA_PATH" in /*) : ;; *) IPA_PATH="$PWD/$IPA_PATH" ;; esac
case "$DYLIB_SRC" in /*) : ;; *) DYLIB_SRC="$PWD/$DYLIB_SRC" ;; esac

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

appex="$(find "$app/PlugIns" -type d -name "OpenInUIExtension.appex" -print -quit 2>/dev/null || true)"
if [[ -z "$appex" || ! -d "$appex" ]]; then
    echo "No OpenInUIExtension.appex in $(basename "$IPA_PATH") — skipping Open-in-Apollo fix."
    exit 0
fi

appex_bin="$appex/OpenInUIExtension"
if [[ ! -f "$appex_bin" ]]; then
    echo "Error: appex executable missing: $appex_bin"
    exit 1
fi

echo "Repairing Open-in-Apollo action extension in $(basename "$IPA_PATH")..."

# Drop any dead prior-attempt dylibs (loose in the appex, or a stale copy of ours).
for stale in "${STALE_NAMES[@]}" "$DYLIB_NAME"; do
    if [[ -f "$appex/$stale" ]]; then
        rm -f "$appex/$stale"
        echo "  removed stale $appex/$stale"
    fi
done

# Place the dylib in the shared Frameworks dir where the signer will sign it,
# and load it into the appex via @rpath (resolves through the appex's existing
# @executable_path/../../Frameworks rpath).
frameworks="$app/Frameworks"
mkdir -p "$frameworks"
cp "$DYLIB_SRC" "$frameworks/$DYLIB_NAME"
echo "  installed Frameworks/$DYLIB_NAME"

# Add the load command (idempotent; verified safe via the header-slack patcher).
python3 "$SCRIPT_DIR/macho_add_load_dylib.py" "$appex_bin" "@rpath/$DYLIB_NAME"

# Sanity: the load command must now be present.
if ! otool -L "$appex_bin" | grep -q "@rpath/$DYLIB_NAME"; then
    echo "Error: LC_LOAD_DYLIB for $DYLIB_NAME not present after patch."
    exit 1
fi

# The appex's prior signature covers the now-modified binary — remove it so the
# user's signer re-seals cleanly (mirrors fix-safari-extension.sh). The app-level
# seal is left for the signer to regenerate, matching the inject-deb-local flow
# that likewise adds dylibs to Frameworks/ without stripping the app seal.
rm -rf "$appex/_CodeSignature"

rm -f "$IPA_PATH"
if ! (cd "$work" && zip -qry "$IPA_PATH" Payload); then
    echo "Error: could not re-zip IPA after Open-in-Apollo fix."
    exit 1
fi

echo "Open-in-Apollo extension repaired: Frameworks/$DYLIB_NAME + @rpath LC_LOAD_DYLIB added, appex _CodeSignature removed."
