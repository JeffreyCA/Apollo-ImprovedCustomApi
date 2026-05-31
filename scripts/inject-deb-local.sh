#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=strip-substrate-arm64e.sh
source "$SCRIPT_DIR/strip-substrate-arm64e.sh"

IPA_PATH=""
DEB_PATH=""
OUTPUT_IPA=""

usage() {
    echo "Usage: $0 --ipa <Apollo.ipa> --deb <packages/*.deb> -o <output.ipa>"
    echo ""
    echo "Local replacement injector for this repo's already-injected Apollo base IPA."
    echo "It replaces tweak dylibs from a Theos .deb inside Payload/*.app/Frameworks."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ipa)
            IPA_PATH="$2"
            shift 2
            ;;
        --deb)
            DEB_PATH="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_IPA="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$IPA_PATH" || -z "$DEB_PATH" || -z "$OUTPUT_IPA" ]]; then
    usage
    exit 1
fi

absolute_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$PWD" "${1#./}" ;;
    esac
}

IPA_PATH="$(absolute_path "$IPA_PATH")"
DEB_PATH="$(absolute_path "$DEB_PATH")"
OUTPUT_IPA="$(absolute_path "$OUTPUT_IPA")"

if [[ ! -f "$IPA_PATH" ]]; then
    echo "Error: IPA not found: $IPA_PATH"
    exit 1
fi

if [[ ! -f "$DEB_PATH" ]]; then
    echo "Error: .deb not found: $DEB_PATH"
    exit 1
fi
mkdir -p "$(dirname "$OUTPUT_IPA")"

for tool in ar install_name_tool tar unzip zip otool; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: required tool '$tool' is not installed."
        exit 1
    fi
done

tmpdir="$(mktemp -d /tmp/apollo-local-inject-XXXXXX)"
cleanup() {
    rm -rf "$tmpdir"
}
trap cleanup EXIT

mkdir -p "$tmpdir/ipa" "$tmpdir/deb"
unzip -q "$IPA_PATH" -d "$tmpdir/ipa"

app_bundle="$(find "$tmpdir/ipa/Payload" -maxdepth 1 -name '*.app' -type d | head -1)"
if [[ -z "$app_bundle" ]]; then
    echo "Error: no .app bundle found in IPA."
    exit 1
fi

plist_path="$app_bundle/Info.plist"
executable_name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$plist_path")"
executable_path="$app_bundle/$executable_name"
frameworks_dir="$app_bundle/Frameworks"
mkdir -p "$frameworks_dir"

(
    cd "$tmpdir/deb"
    ar -x "$DEB_PATH"
    data_archive="$(ls data.tar.* 2>/dev/null | head -1)"
    if [[ -z "$data_archive" ]]; then
        echo "Error: .deb did not contain data.tar.*"
        exit 1
    fi
    tar -xf "$data_archive"
)

dylib_dir="$tmpdir/deb/Library/MobileSubstrate/DynamicLibraries"
if [[ ! -d "$dylib_dir" ]]; then
    echo "Error: .deb did not contain MobileSubstrate DynamicLibraries."
    exit 1
fi

shopt -s nullglob
dylibs=("$dylib_dir"/*.dylib)
shopt -u nullglob
if [[ "${#dylibs[@]}" -eq 0 ]]; then
    echo "Error: .deb contained no dylibs to inject."
    exit 1
fi

declare -a ipa_loaded_dylibs=()
while IFS= read -r loaded_path; do
    [[ -z "$loaded_path" ]] && continue
    ipa_loaded_dylibs+=("$(basename "$loaded_path")")
done < <(otool -L "$executable_path" | tail -n +2 | awk '{print $1}' | grep '\.dylib$' || true)

ipa_has_loaded_or_framework() {
    local name="$1"
    local item

    for item in "${ipa_loaded_dylibs[@]}"; do
        if [[ "$item" == "$name" ]]; then
            return 0
        fi
    done

    for framework_dylib in "$frameworks_dir"/*.dylib; do
        [[ -f "$framework_dylib" ]] || continue
        if [[ "$(basename "$framework_dylib")" == "$name" ]]; then
            return 0
        fi
    done

    return 1
}

resolve_target_dylib_name() {
    local source_name="$1"

    if ipa_has_loaded_or_framework "$source_name"; then
        printf '%s\n' "$source_name"
        return 0
    fi

    case "$source_name" in
        ApolloReborn.dylib)
            if ipa_has_loaded_or_framework "ApolloImprovedCustomApi.dylib"; then
                echo "Aliasing ApolloReborn.dylib -> ApolloImprovedCustomApi.dylib" >&2
                printf '%s\n' "ApolloImprovedCustomApi.dylib"
                return 0
            fi
            ;;
    esac

    return 1
}

apply_dylib_sideload_fixes() {
    local dest_path="$1"
    local target_name="$2"
    local source_name="$3"

    install_name_tool -id "@rpath/$target_name" "$dest_path" 2>/dev/null || true
    install_name_tool -change \
        "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate" \
        "@rpath/CydiaSubstrate.framework/CydiaSubstrate" \
        "$dest_path" 2>/dev/null || true
    install_name_tool -change \
        "/Library/MobileSubstrate/DynamicLibraries/$source_name" \
        "@rpath/$target_name" \
        "$dest_path" 2>/dev/null || true
    if [[ "$source_name" != "$target_name" ]]; then
        install_name_tool -change \
            "/Library/MobileSubstrate/DynamicLibraries/$target_name" \
            "@rpath/$target_name" \
            "$dest_path" 2>/dev/null || true
    fi
}

verify_dylib_substrate_linkage() {
    local dest_path="$1"
    if otool -L "$dest_path" | grep -Fq '/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate'; then
        echo "Error: $dest_path still links jailbreak CydiaSubstrate path after install_name_tool."
        return 1
    fi
    return 0
}

missing_loads=()
for dylib in "${dylibs[@]}"; do
    source_name="$(basename "$dylib")"
    # The Open-in-Apollo dylib is for the OpenInUIExtension appex, not the main
    # app. It's injected separately by scripts/fix-openin-extension.sh (built as
    # a LIBRARY subproject, normally staged to /usr/lib so it shouldn't land here
    # at all — this guard is belt-and-suspenders). Never inject it into the app.
    if [[ "$source_name" == "ApolloOpenInFix.dylib" ]]; then
        echo "Skipping $source_name (appex-only; handled by fix-openin-extension.sh)"
        continue
    fi
    target_name="$(resolve_target_dylib_name "$source_name" || true)"
    if [[ -z "$target_name" ]]; then
        missing_loads+=("$source_name")
        continue
    fi

    dest_path="$frameworks_dir/$target_name"
    cp "$dylib" "$dest_path"
    apply_dylib_sideload_fixes "$dest_path" "$target_name" "$source_name"
    verify_dylib_substrate_linkage "$dest_path"
    if [[ "$source_name" != "$target_name" ]]; then
        echo "Updated Frameworks/$target_name (from deb $source_name)"
    else
        echo "Updated Frameworks/$target_name"
    fi
done

if [[ "${#missing_loads[@]}" -gt 0 ]]; then
    echo "Error: IPA is not already prepared to load: ${missing_loads[*]}"
    echo "Use azule/cyan once for a truly stock IPA, then this local injector can update it deterministically."
    exit 2
fi

strip_arm64e_from_substrate_in_app "$app_bundle"

resource_bundle="$tmpdir/deb/Library/Application Support/ApolloReborn/ApolloReborn.bundle"
if [[ -d "$resource_bundle" ]]; then
    resource_dest="$app_bundle/ApolloRebornResources"
    mkdir -p "$resource_dest"
    rsync -a "$resource_bundle/" "$resource_dest/"
    echo "Copied ApolloReborn resources into app bundle"
fi

rm -f "$OUTPUT_IPA"
(
    cd "$tmpdir/ipa"
    zip -qr "$OUTPUT_IPA" Payload
)

echo "Injected IPA created at: $OUTPUT_IPA"
