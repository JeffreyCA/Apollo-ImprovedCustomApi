#!/usr/bin/env bash
#
# theme-golden.sh — two-mode golden-screenshot regression harness for the v2
# Theme Manager (spec/rearchitecture Pillar 8). The recurring bug pattern for
# custom themes is "wrong in one mode on one screen"; a light+dark golden suite
# across the key screens is exactly what catches that before release.
#
# It builds on the repo's existing sim driver (scripts/run-in-sim.sh): that
# script boots the simulator, injects the tweak, and records the device UDID in
# ./.sim/device.txt. This harness drives appearance + screenshots against that
# same device, so the normal inner loop is:
#
#   1. scripts/run-in-sim.sh --glass            # boot + inject (once)
#   2. In Apollo, build two representative custom themes in Theme Manager and
#      enable one: a dark-on-saturated theme and a light-on-pastel theme. They
#      persist in the sim's app-group container across relaunches.
#   3. Navigate to a screen, then capture it in BOTH modes:
#        scripts/theme-golden.sh both feed
#        scripts/theme-golden.sh both comments
#        scripts/theme-golden.sh both profile
#        scripts/theme-golden.sh both settings
#        scripts/theme-golden.sh both appearance
#        scripts/theme-golden.sh both theme-manager
#        scripts/theme-golden.sh both theme-editor
#   4. scripts/theme-golden.sh accept           # promote current/ -> baseline/
#   5. After a code change, recapture the same screens, then:
#        scripts/theme-golden.sh diff           # flags any screen that changed
#
# Screenshots live under ./.sim/golden/{current,baseline}/{light,dark}/<name>.png
# (./.sim/ is gitignored). Diff uses ImageMagick `compare` when available
# (per-pixel), else falls back to a byte compare.
#
# Subcommands:
#   capture <name> [light|dark]   screenshot current sim screen (mode: arg, else $APPEARANCE, else dark)
#   both <name>                   capture <name> in light AND dark (toggles appearance, waits to settle)
#   accept                        copy current/ over baseline/
#   diff [name]                   compare current vs baseline (all, or one screen)
#   list                          list captured screens
#   clean                         remove current/ (keeps baseline/)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM_DIR="$REPO_DIR/.sim"
GOLDEN_DIR="$SIM_DIR/golden"
SETTLE_SECONDS="${SETTLE_SECONDS:-1.2}"

log() { printf '\033[0;36m[theme-golden]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[0;31m[theme-golden] %s\033[0m\n' "$*" >&2; exit 1; }

resolve_device() {
    if [[ -n "${SIM:-}" ]]; then echo "$SIM"; return; fi
    [[ -f "$SIM_DIR/device.txt" ]] || die "No ./.sim/device.txt — run scripts/run-in-sim.sh first (or set SIM=<udid>)."
    cat "$SIM_DIR/device.txt"
}

set_appearance() {
    local dev="$1" mode="$2"
    xcrun simctl ui "$dev" appearance "$mode" >/dev/null 2>&1 || true
    sleep "$SETTLE_SECONDS"
}

shot() {
    local dev="$1" mode="$2" name="$3"
    local out="$GOLDEN_DIR/current/$mode"
    mkdir -p "$out"
    xcrun simctl io "$dev" screenshot "$out/$name.png" >/dev/null 2>&1 \
        || die "screenshot failed (is the simulator booted?)"
    log "captured $mode/$name.png"
}

cmd_capture() {
    local name="${1:?usage: capture <name> [light|dark]}"
    local mode="${2:-${APPEARANCE:-dark}}"
    local dev; dev="$(resolve_device)"
    shot "$dev" "$mode" "$name"
}

cmd_both() {
    local name="${1:?usage: both <name>}"
    local dev; dev="$(resolve_device)"
    set_appearance "$dev" light; shot "$dev" light "$name"
    set_appearance "$dev" dark;  shot "$dev" dark  "$name"
}

cmd_accept() {
    [[ -d "$GOLDEN_DIR/current" ]] || die "Nothing captured yet."
    rm -rf "$GOLDEN_DIR/baseline"
    cp -R "$GOLDEN_DIR/current" "$GOLDEN_DIR/baseline"
    log "baseline updated from current."
}

compare_one() {
    local rel="$1" base="$2" cur="$3"
    if [[ ! -f "$base" ]]; then echo "NEW      $rel"; return 1; fi
    if [[ ! -f "$cur" ]];  then echo "MISSING  $rel"; return 1; fi
    if command -v compare >/dev/null 2>&1; then
        local diffpng="${cur%.png}.diff.png" px
        px="$(compare -metric AE "$base" "$cur" "$diffpng" 2>&1 || true)"
        px="${px%%[^0-9]*}"; [[ -z "$px" ]] && px=0
        if [[ "$px" -gt 0 ]]; then echo "CHANGED  $rel  (${px}px, see $(basename "$diffpng"))"; return 1; fi
        rm -f "$diffpng"
    else
        if ! cmp -s "$base" "$cur"; then echo "CHANGED  $rel  (byte diff; install imagemagick for pixel counts)"; return 1; fi
    fi
    echo "ok       $rel"; return 0
}

cmd_diff() {
    local only="${1:-}"
    [[ -d "$GOLDEN_DIR/baseline" ]] || die "No baseline — run 'accept' first."
    local fail=0
    while IFS= read -r -d '' cur; do
        local rel="${cur#"$GOLDEN_DIR/current/"}"
        [[ "$rel" == *.diff.png ]] && continue
        [[ -n "$only" && "$rel" != *"/$only.png" ]] && continue
        compare_one "$rel" "$GOLDEN_DIR/baseline/$rel" "$cur" || fail=1
    done < <(find "$GOLDEN_DIR/current" -name '*.png' ! -name '*.diff.png' -print0 2>/dev/null | sort -z)
    [[ "$fail" -eq 0 ]] && log "no differences." || log "differences found (above)."
    return "$fail"
}

cmd_list() {
    [[ -d "$GOLDEN_DIR/current" ]] || { log "nothing captured."; return; }
    find "$GOLDEN_DIR/current" -name '*.png' ! -name '*.diff.png' | sed "s#$GOLDEN_DIR/current/##" | sort
}

cmd_clean() { rm -rf "$GOLDEN_DIR/current"; log "removed current/."; }

case "${1:-}" in
    capture) shift; cmd_capture "$@" ;;
    both)    shift; cmd_both "$@" ;;
    accept)  cmd_accept ;;
    diff)    shift; cmd_diff "${1:-}" ;;
    list)    cmd_list ;;
    clean)   cmd_clean ;;
    *) die "usage: theme-golden.sh {capture <name> [mode]|both <name>|accept|diff [name]|list|clean}" ;;
esac
