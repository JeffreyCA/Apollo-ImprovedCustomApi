#!/bin/bash
# enable_promotion_in_app <app_bundle>
#
# Unlocks the full iPhone ProMotion refresh-rate range. Apple keeps iPhone apps
# at the system default (at most 60 Hz) unless the main bundle explicitly sets
# CADisableMinimumFrameDurationOnPhone=true. UIKit/Core Animation then choose
# the actual adaptive rate; this does not force a continuous 120 Hz render loop.

_enable_promotion_module_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/modules/_plist-helpers.sh
source "${_enable_promotion_module_dir}/_plist-helpers.sh"

enable_promotion_in_app() {
    local app_bundle="$1"
    local plist="$app_bundle/Info.plist"

    if [[ ! -f "$plist" ]]; then
        echo "Note: ProMotion patch skipped (Info.plist not found: $plist)"
        return 0
    fi

    plist_set_bool "$plist" "CADisableMinimumFrameDurationOnPhone" true
    rm -rf "$app_bundle/_CodeSignature"
    echo "Enabled adaptive ProMotion refresh rates in the main app bundle."
}
