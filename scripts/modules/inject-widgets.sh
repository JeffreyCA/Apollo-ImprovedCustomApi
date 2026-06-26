#!/bin/bash
# inject_widgets_in_app <app_bundle> [appex_path]
#
# Removes the stock AthenaWidgetExtension.appex and injects the Apollo Reborn
# ApolloRebornWidgets.appex into an unpacked .app bundle's PlugIns/, in place.
#
# A crash-looping widget extension poisons WidgetKit's enumeration of ALL of the
# host app's widgets, so the stock AthenaWidgetExtension.appex (which has no
# valid API keys after the Reddit API shutdown) is removed first.
#
# Returns 1 if the appex to inject is missing (caller asked for widgets but the
# extension wasn't built); pass --keep-stock via the orchestrator to retain the
# stock widget.

_WIDGETS_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_WIDGETS_REPO_DIR="$(cd "${_WIDGETS_MODULE_DIR}/../.." && pwd)"
_WIDGETS_DEFAULT_APPEX="${_WIDGETS_REPO_DIR}/widgets/build/Build/Products/Release-iphoneos/ApolloRebornWidgets.appex"

# Set to 1 to keep the stock AthenaWidgetExtension.appex.
INJECT_WIDGETS_KEEP_STOCK="${INJECT_WIDGETS_KEEP_STOCK:-0}"

inject_widgets_in_app() {
    local app_bundle="$1"
    local appex_path="${2:-$_WIDGETS_DEFAULT_APPEX}"

    if [[ ! -d "$appex_path" ]]; then
        echo "Error: widget appex not found: $appex_path"
        return 1
    fi

    local plugins="$app_bundle/PlugIns"
    mkdir -p "$plugins"

    if [[ "$INJECT_WIDGETS_KEEP_STOCK" != "1" && -d "$plugins/AthenaWidgetExtension.appex" ]]; then
        echo "Removing stock AthenaWidgetExtension.appex (prevents WidgetKit enumeration poisoning)..."
        rm -rf "$plugins/AthenaWidgetExtension.appex"
    fi

    local appex_name
    appex_name="$(basename "$appex_path")"
    rm -rf "$plugins/$appex_name"
    cp -R "$appex_path" "$plugins/"
    # Strip any stale signature so the re-signer starts clean.
    rm -rf "$plugins/$appex_name/_CodeSignature"
    echo "Injected $appex_name"
}
