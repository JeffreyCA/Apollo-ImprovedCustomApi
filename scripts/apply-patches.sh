#!/bin/bash
set -euo pipefail

# apply-patches.sh — single-unpack IPA patch orchestrator.
#
# Unpacks an IPA ONCE, runs a chosen ordered list of patch modules against the
# single unpacked .app bundle, then repacks ONCE. Each module is a shell
# function in scripts/modules/<name>.sh operating on an unpacked bundle path
# (the *_in_app convention modeled on strip-substrate-arm64e.sh).
#
# Usage:
#   apply-patches.sh --ipa <in.ipa> -o <out.ipa> [--deb <tweak.deb>] \
#     --module <name[:arg1[:arg2...]]> [--module ...]
#
# Module names (and their args):
#   inject-tweak[:<deb>]            inject tweak dylibs (deb defaults to --deb)
#   strip-substrate-arm64e         strip CydiaSubstrate arm64e slice
#   patch-bundle-versions:<short>:<build>   set CFBundleShortVersionString/CFBundleVersion
#   stamp-build-variant:<variant>  set ARBuildVariant (usage-heartbeat "c" field)
#   inject-url-schemes:<csv>       append URL schemes to CFBundleURLTypes
#   fix-safari-extension           repair Apollofari.appex
#   fix-openin-extension[:<dylib>] repair OpenInUIExtension.appex
#   inject-widgets[:<appex>]       remove stock widget, inject ApolloRebornWidgets.appex
#   liquid-glass-binary            vtool SDK bump + LC_RPATH cleanup
#   liquid-glass-assets            Assets.car swap + icon metadata
#
# Example:
#   apply-patches.sh --ipa Apollo.ipa -o out.ipa --deb tweak.deb \
#     --module inject-tweak \
#     --module strip-substrate-arm64e \
#     --module fix-safari-extension \
#     --module fix-openin-extension \
#     --module 'patch-bundle-versions:3.0.0:300' \
#     --module 'inject-url-schemes:dystopia,redreader' \
#     --module inject-widgets \
#     --module liquid-glass-binary \
#     --module liquid-glass-assets

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULES_DIR="$SCRIPT_DIR/modules"

IPA_PATH=""
OUTPUT_IPA=""
DEB_PATH=""
MODULE_SPECS=()

usage() {
    sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'
}

# Map a module name to the shell function it defines. Names that don't map by a
# simple substitution are listed explicitly.
module_function() {
    case "$1" in
        inject-tweak)            echo "inject_tweak_in_app" ;;
        strip-substrate-arm64e)  echo "strip_substrate_arm64e_in_app" ;;
        patch-bundle-versions)   echo "patch_bundle_versions_in_app" ;;
        stamp-build-variant)     echo "stamp_build_variant_in_app" ;;
        inject-url-schemes)      echo "inject_url_schemes_in_app" ;;
        fix-safari-extension)    echo "fix_safari_extension_in_app" ;;
        fix-openin-extension)    echo "fix_openin_extension_in_app" ;;
        inject-widgets)          echo "inject_widgets_in_app" ;;
        liquid-glass-binary)     echo "patch_liquid_glass_binary_in_app" ;;
        liquid-glass-assets)     echo "patch_liquid_glass_assets_in_app" ;;
        *) return 1 ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ipa)    IPA_PATH="$2";    shift 2 ;;
        -o|--output) OUTPUT_IPA="$2"; shift 2 ;;
        --deb)    DEB_PATH="$2";    shift 2 ;;
        --module) MODULE_SPECS+=("$2"); shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

[[ -z "$IPA_PATH" ]]    && { echo "Error: --ipa is required" >&2; exit 1; }
[[ -z "$OUTPUT_IPA" ]]  && { echo "Error: -o/--output is required" >&2; exit 1; }
[[ ! -f "$IPA_PATH" ]]  && { echo "Error: IPA not found: $IPA_PATH" >&2; exit 1; }
[[ "${#MODULE_SPECS[@]}" -eq 0 ]] && { echo "Error: at least one --module is required" >&2; exit 1; }

absolute_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *)  printf '%s/%s\n' "$PWD" "${1#./}" ;;
    esac
}
IPA_PATH="$(absolute_path "$IPA_PATH")"
OUTPUT_IPA="$(absolute_path "$OUTPUT_IPA")"
[[ -n "$DEB_PATH" ]] && DEB_PATH="$(absolute_path "$DEB_PATH")"

# Validate every module up front (name resolvable + file present) so we fail
# before unpacking rather than mid-pipeline.
for spec in "${MODULE_SPECS[@]}"; do
    name="${spec%%:*}"
    if ! module_function "$name" >/dev/null; then
        echo "Error: unknown module: $name" >&2; exit 1
    fi
    if [[ ! -f "$MODULES_DIR/$name.sh" ]]; then
        echo "Error: module file not found: $MODULES_DIR/$name.sh" >&2; exit 1
    fi
done

work="$(mktemp -d /tmp/apollo-apply-patches-XXXXXX)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

echo "==> Unpacking $(basename "$IPA_PATH")"
unzip -q "$IPA_PATH" -d "$work"

app_bundle="$(find "$work/Payload" -maxdepth 1 -name '*.app' -type d | head -1)"
[[ -z "$app_bundle" ]] && { echo "Error: no .app bundle found in IPA." >&2; exit 1; }
echo "    App bundle: $(basename "$app_bundle")"

for spec in "${MODULE_SPECS[@]}"; do
    name="${spec%%:*}"
    # Split the remaining colon-separated args into an array (empty if none).
    args=()
    if [[ "$spec" == *:* ]]; then
        rest="${spec#*:}"
        IFS=':' read -ra args <<< "$rest"
    fi

    # inject-tweak defaults its deb argument to --deb when not given inline.
    if [[ "$name" == "inject-tweak" && "${#args[@]}" -eq 0 ]]; then
        [[ -z "$DEB_PATH" ]] && { echo "Error: inject-tweak needs a deb (--deb or inline)." >&2; exit 1; }
        args=("$DEB_PATH")
    fi

    fn="$(module_function "$name")"
    # shellcheck source=/dev/null
    source "$MODULES_DIR/$name.sh"
    echo "==> Module: $name"
    # ${args[@]+...} guards against the empty-array "unbound variable" error
    # under `set -u` on macOS's bash 3.2.
    "$fn" "$app_bundle" ${args[@]+"${args[@]}"}
done

# Strip the top-level app signature so the user's signer re-seals cleanly. The
# individual modules already strip the signatures of bundles they modify.
rm -rf "$app_bundle/_CodeSignature"

echo "==> Repacking $(basename "$OUTPUT_IPA")"
rm -f "$OUTPUT_IPA"
mkdir -p "$(dirname "$OUTPUT_IPA")"
( cd "$work" && zip -qry "$OUTPUT_IPA" Payload )

file_size=$(wc -c < "$OUTPUT_IPA" | tr -d ' ')
file_size_mb=$(awk "BEGIN {printf \"%.1f\", ${file_size}/1048576}")
echo "==> Done: $OUTPUT_IPA (${file_size_mb} MB)"
