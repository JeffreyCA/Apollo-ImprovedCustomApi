#!/bin/bash
# inject_tweak_in_app <app_bundle> <deb_path>
#
# Replaces the tweak dylibs inside an already-prepared unpacked .app bundle
# from a Theos .deb, fixing install names for sideloading.
#
# "Already-prepared" means the IPA was processed by azule/cyan at least once so
# the Apollo binary already has LC_LOAD_DYLIB entries pointing at the tweak
# dylibs. This fast-path replaces just the dylib files without touching the
# binary, making it deterministic and suitable for CI iteration.
#
# Exits 2 if the IPA is not prepared (no matching load slots). In that case,
# use azule/cyan on the stock IPA first (once), then call this.
#
# Does NOT strip the CydiaSubstrate arm64e slice — run the
# strip-substrate-arm64e module after this one.

_INJECT_TWEAK_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

inject_tweak_in_app() {
    local app_bundle="$1"
    local deb_path="$2"

    local plist_path="$app_bundle/Info.plist"
    local executable_name
    executable_name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$plist_path")"
    local executable_path="$app_bundle/$executable_name"
    local frameworks_dir="$app_bundle/Frameworks"
    mkdir -p "$frameworks_dir"

    # Extract deb into a temp directory.
    local tmpdir
    tmpdir="$(mktemp -d /tmp/apollo-inject-tweak-XXXXXX)"

    mkdir -p "$tmpdir/deb"
    (cd "$tmpdir/deb" && ar -x "$deb_path") || { rm -rf "$tmpdir"; echo "Error: could not unpack .deb"; return 1; }

    local data_archive
    data_archive="$(ls "$tmpdir/deb/data.tar."* 2>/dev/null | head -1 || true)"
    if [[ -z "$data_archive" ]]; then
        rm -rf "$tmpdir"
        echo "Error: .deb did not contain data.tar.*"
        return 1
    fi
    (cd "$tmpdir/deb" && tar -xf "$data_archive") || { rm -rf "$tmpdir"; echo "Error: could not extract deb data archive"; return 1; }

    local dylib_dir="$tmpdir/deb/Library/MobileSubstrate/DynamicLibraries"
    if [[ ! -d "$dylib_dir" ]]; then
        rm -rf "$tmpdir"
        echo "Error: .deb did not contain MobileSubstrate DynamicLibraries."
        return 1
    fi

    shopt -s nullglob
    local dylibs=("$dylib_dir"/*.dylib)
    shopt -u nullglob
    if [[ "${#dylibs[@]}" -eq 0 ]]; then
        rm -rf "$tmpdir"
        echo "Error: .deb contained no dylibs to inject."
        return 1
    fi

    # Enumerate dylibs already loaded by the main executable.
    local -a ipa_loaded_dylibs=()
    while IFS= read -r loaded_path; do
        [[ -z "$loaded_path" ]] && continue
        ipa_loaded_dylibs+=("$(basename "$loaded_path")")
    done < <(otool -L "$executable_path" | tail -n +2 | awk '{print $1}' | grep '\.dylib$' || true)

    _ipa_has_loaded_or_framework() {
        local name="$1"
        local item framework_dylib
        for item in "${ipa_loaded_dylibs[@]}"; do
            [[ "$item" == "$name" ]] && return 0
        done
        for framework_dylib in "$frameworks_dir"/*.dylib; do
            [[ -f "$framework_dylib" ]] || continue
            [[ "$(basename "$framework_dylib")" == "$name" ]] && return 0
        done
        return 1
    }

    _resolve_target_dylib_name() {
        local source_name="$1"
        if _ipa_has_loaded_or_framework "$source_name"; then
            printf '%s\n' "$source_name"; return 0
        fi
        case "$source_name" in
            ApolloReborn.dylib)
                if _ipa_has_loaded_or_framework "ApolloImprovedCustomApi.dylib"; then
                    echo "Aliasing ApolloReborn.dylib -> ApolloImprovedCustomApi.dylib" >&2
                    printf '%s\n' "ApolloImprovedCustomApi.dylib"; return 0
                fi ;;
        esac
        return 1
    }

    _apply_dylib_sideload_fixes() {
        local dest_path="$1" target_name="$2" source_name="$3"
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

    local missing_loads=()
    local dylib source_name target_name dest_path
    for dylib in "${dylibs[@]}"; do
        source_name="$(basename "$dylib")"
        # ApolloOpenInFix.dylib is appex-only; the fix-openin-extension module
        # places it in Frameworks/ and wires the load command into the appex binary.
        if [[ "$source_name" == "ApolloOpenInFix.dylib" ]]; then
            echo "Skipping $source_name (appex-only; handled by fix-openin-extension module)"
            continue
        fi
        target_name="$(_resolve_target_dylib_name "$source_name" || true)"
        if [[ -z "$target_name" ]]; then
            missing_loads+=("$source_name")
            continue
        fi
        dest_path="$frameworks_dir/$target_name"
        cp "$dylib" "$dest_path"
        _apply_dylib_sideload_fixes "$dest_path" "$target_name" "$source_name"
        if otool -L "$dest_path" | grep -Fq '/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate'; then
            rm -rf "$tmpdir"
            echo "Error: $dest_path still links jailbreak CydiaSubstrate path after install_name_tool."
            return 1
        fi
        if [[ "$source_name" != "$target_name" ]]; then
            echo "Updated Frameworks/$target_name (from deb $source_name)"
        else
            echo "Updated Frameworks/$target_name"
        fi
    done

    if [[ "${#missing_loads[@]}" -gt 0 ]]; then
        rm -rf "$tmpdir"
        echo "Error: IPA is not already prepared to load: ${missing_loads[*]}"
        echo "Use azule/cyan once on the stock IPA, then pass the prepared IPA here."
        return 2
    fi

    # Copy resource bundle (ApolloReborn.bundle) if present in the deb.
    local resource_bundle="$tmpdir/deb/Library/Application Support/ApolloReborn/ApolloReborn.bundle"
    if [[ -d "$resource_bundle" ]]; then
        local resource_dest="$app_bundle/ApolloRebornResources"
        mkdir -p "$resource_dest"
        rsync -a "$resource_bundle/" "$resource_dest/"
        echo "Copied ApolloReborn resources into app bundle"
    fi

    rm -rf "$tmpdir"
}
