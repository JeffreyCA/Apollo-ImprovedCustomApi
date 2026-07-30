#!/bin/bash
# Shared PlistBuddy helpers used by patch modules.
# All functions take an explicit plist path as their first argument,
# so they work without cd-ing into the app bundle first.

plist_set_string() {
    local plist="$1" key="$2" value="$3"
    if /usr/libexec/PlistBuddy -c "Print :${key}" "$plist" &>/dev/null; then
        /usr/libexec/PlistBuddy -c "Set :${key} ${value}" "$plist"
    else
        /usr/libexec/PlistBuddy -c "Add :${key} string ${value}" "$plist"
    fi
}

plist_set_bool() {
    local plist="$1" key="$2" value="$3"
    local existing_type
    existing_type="$(plutil -type "${key}" "$plist" 2>/dev/null || true)"
    if [[ "$existing_type" == "bool" ]]; then
        /usr/libexec/PlistBuddy -c "Set :${key} ${value}" "$plist"
    else
        if /usr/libexec/PlistBuddy -c "Print :${key}" "$plist" &>/dev/null; then
            /usr/libexec/PlistBuddy -c "Delete :${key}" "$plist"
        fi
        /usr/libexec/PlistBuddy -c "Add :${key} bool ${value}" "$plist"
    fi
}

plist_ensure_dict() {
    local plist="$1" key="$2"
    if ! /usr/libexec/PlistBuddy -c "Print :${key}" "$plist" &>/dev/null; then
        /usr/libexec/PlistBuddy -c "Add :${key} dict" "$plist"
    fi
}

plist_replace_string_array() {
    local plist="$1" key="$2"; shift 2
    if /usr/libexec/PlistBuddy -c "Print :${key}" "$plist" &>/dev/null; then
        /usr/libexec/PlistBuddy -c "Delete :${key}" "$plist"
    fi
    /usr/libexec/PlistBuddy -c "Add :${key} array" "$plist"
    for value in "$@"; do
        /usr/libexec/PlistBuddy -c "Add :${key}: string ${value}" "$plist"
    done
}
