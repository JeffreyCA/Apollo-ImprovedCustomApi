#!/bin/bash
# inject_url_schemes_in_app <app_bundle> <comma_separated_schemes>
#
# Appends custom URL schemes to CFBundleURLTypes in the main app's Info.plist so
# other apps (e.g. Dystopia, RedReader) can deep-link into Apollo. Idempotent:
# schemes already present are skipped.

inject_url_schemes_in_app() {
    local app_bundle="$1"
    local url_schemes="$2"
    local plist="$app_bundle/Info.plist"

    [[ -z "$url_schemes" ]] && return 0
    if [[ ! -f "$plist" ]]; then
        echo "Error: Info.plist not found: $plist"
        return 1
    fi

    echo "Adding custom URL schemes: $url_schemes"

    local url_type_index=0
    local found_schemes=false

    if /usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes" "$plist" &>/dev/null; then
        while /usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes:${url_type_index}" "$plist" &>/dev/null; do
            if /usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes:${url_type_index}:CFBundleURLSchemes" "$plist" &>/dev/null; then
                found_schemes=true
                break
            fi
            url_type_index=$((url_type_index + 1))
        done
        if [[ "$found_schemes" == "false" ]]; then
            /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$plist"
            url_type_index=0
            found_schemes=true
        fi
    else
        /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array"         "$plist"
        /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0 dict"        "$plist"
        /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$plist"
        url_type_index=0
        found_schemes=true
    fi

    local SCHEMES scheme existing
    IFS=',' read -ra SCHEMES <<< "$url_schemes"
    for scheme in "${SCHEMES[@]}"; do
        scheme=$(echo "$scheme" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$scheme" ]] && continue
        existing=$(/usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes:${url_type_index}:CFBundleURLSchemes" "$plist" 2>/dev/null | grep -cxF "    ${scheme}" || true)
        if [[ "$existing" -eq 0 ]]; then
            echo "  + ${scheme}"
            /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:${url_type_index}:CFBundleURLSchemes: string ${scheme}" "$plist"
        else
            echo "  ~ ${scheme} (already present, skipping)"
        fi
    done

    # Plist edits invalidate the existing code signature.
    rm -rf "$app_bundle/_CodeSignature"
}
