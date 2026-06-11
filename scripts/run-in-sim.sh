#!/usr/bin/env bash
#
# run-in-sim.sh — build the tweak for the iOS Simulator and launch Apollo with it
# injected, for fast local iteration (no device, no certificates, no sideload).
#
# Why this is possible at all:
#   * Apollo's decrypted binary is built for device iOS. We patch each Mach-O's
#     LC_BUILD_VERSION platform from iOS (2) to iOS-Simulator (7) and re-sign it
#     ad-hoc, which makes the simulator's dyld accept the (same-arch) arm64 code.
#   * The tweak is built against the simulator SDK with the *internal* Logos
#     generator, so it uses ObjC-runtime swizzling and has no CydiaSubstrate
#     dependency, and with APOLLO_SIM_BUILD=1 so it skips device-only FFmpegKit.
#   * The dylib is injected via DYLD_INSERT_LIBRARIES (passed through simctl's
#     SIMCTL_CHILD_ prefix). Code-only changes just rebuild + relaunch in seconds.
#
# Usage:
#   scripts/run-in-sim.sh                 # build tweak, (re)prepare app, launch injected
#   scripts/run-in-sim.sh --no-build      # skip tweak rebuild, just relaunch
#   scripts/run-in-sim.sh --fresh-app     # re-patch the base IPA from scratch
#   scripts/run-in-sim.sh --logs          # stream the app's ApolloLog output after launch
#   scripts/run-in-sim.sh --drive         # after launch, run an idb UI smoke test (tree + screenshot)
#
# Env overrides:
#   BASE_IPA (./apollo-base.ipa)  BUNDLE_ID (com.christianselig.Apollo)
#   SIM_NAME (Apollo-Sim)  SIM_DEVICE_TYPE (iPhone 16 Pro)  SIM_RUNTIME (newest iOS)
#   DEPLOY_MIN (14.0)  WORK_DIR (./.sim)  IDB (idb on PATH)
#
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

BASE_IPA="${BASE_IPA:-./apollo-base.ipa}"
BUNDLE_ID="${BUNDLE_ID:-com.christianselig.Apollo}"
SIM_NAME="${SIM_NAME:-Apollo-Sim}"
SIM_DEVICE_TYPE="${SIM_DEVICE_TYPE:-iPhone 16 Pro}"
SIM_RUNTIME="${SIM_RUNTIME:-}"
DEPLOY_MIN="${DEPLOY_MIN:-14.0}"
WORK_DIR="${WORK_DIR:-./.sim}"
IDB="${IDB:-idb}"

DO_BUILD=1; FRESH_APP=0; DO_LOGS=0; DO_DRIVE=0
for arg in "$@"; do
    case "$arg" in
        --no-build)   DO_BUILD=0 ;;
        --fresh-app)  FRESH_APP=1 ;;
        --logs)       DO_LOGS=1 ;;
        --drive)      DO_DRIVE=1 ;;
        -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "$WORK_DIR"
APP_DIR="$WORK_DIR/Payload/Apollo.app"
DYLIB_DST="$WORK_DIR/ApolloReborn.dylib"
PATCH_PY="$WORK_DIR/patch_platform.py"

# ----------------------------------------------------------------------------
# Mach-O platform patcher: LC_BUILD_VERSION platform iOS(2) -> iOS-Simulator(7).
# ----------------------------------------------------------------------------
write_patcher() {
cat > "$PATCH_PY" <<'PYEOF'
import struct, sys
LC_BUILD_VERSION = 0x32
PLATFORM_IOS, PLATFORM_IOSSIMULATOR = 2, 7
def patch(path):
    data = bytearray(open(path, 'rb').read())
    if struct.unpack('<I', data[0:4])[0] != 0xFEEDFACF:
        return "skip (not 64-bit LE mach-o)"
    ncmds = struct.unpack('<I', data[16:20])[0]; off = 32; acts = []
    for _ in range(ncmds):
        cmd, sz = struct.unpack('<II', data[off:off+8])
        if cmd == LC_BUILD_VERSION:
            plat = struct.unpack('<I', data[off+8:off+12])[0]
            if plat == PLATFORM_IOS:
                struct.pack_into('<I', data, off+8, PLATFORM_IOSSIMULATOR); acts.append("iOS->sim")
            else:
                acts.append(f"plat={plat}")
        off += sz
    open(path, 'wb').write(data)
    return ", ".join(acts) or "no build-version cmd"
for p in sys.argv[1:]:
    print(f"  {p.split('/')[-1]}: {patch(p)}")
PYEOF
}

# ----------------------------------------------------------------------------
# 1. Build the tweak for the simulator (internal generator, no FFmpeg).
# ----------------------------------------------------------------------------
if [[ "$DO_BUILD" == 1 ]]; then
    log "Building tweak for the simulator SDK (internal generator, APOLLO_SIM_BUILD=1)"
    make TARGET="simulator:clang:latest:${DEPLOY_MIN}" \
         LOGOS_DEFAULT_GENERATOR=internal \
         APOLLO_SIM_BUILD=1 -j"$(sysctl -n hw.ncpu)"
fi

DYLIB_SRC="$(find .theos/obj/iphone_simulator -maxdepth 2 -name 'ApolloReborn.dylib' \
              ! -path '*.dSYM*' 2>/dev/null | head -1)"
BUNDLE_SRC="$(find .theos/obj/iphone_simulator -maxdepth 2 -name 'ApolloReborn.bundle' \
              -type d 2>/dev/null | head -1)"
[[ -n "$DYLIB_SRC" ]] || die "no simulator ApolloReborn.dylib found — run without --no-build first"

# Sanity: confirm we built a simulator-platform dylib, not a stale device one.
if ! vtool -show-build "$DYLIB_SRC" 2>/dev/null | grep -q 'IOSSIMULATOR'; then
    die "$DYLIB_SRC is not an iOS-Simulator binary; run a clean: make clean && scripts/run-in-sim.sh"
fi
cp "$DYLIB_SRC" "$DYLIB_DST"
codesign -f -s - "$DYLIB_DST" >/dev/null 2>&1
log "Tweak dylib ready: $DYLIB_DST"

# ----------------------------------------------------------------------------
# 2. Prepare the Apollo.app shell (platform-patched + ad-hoc signed). Cached.
# ----------------------------------------------------------------------------
if [[ "$FRESH_APP" == 1 || ! -d "$APP_DIR" ]]; then
    [[ -f "$BASE_IPA" ]] || die "base IPA not found at $BASE_IPA (set BASE_IPA=...)"
    log "Preparing simulator app shell from $BASE_IPA (one-time; re-run with --fresh-app to redo)"
    rm -rf "$WORK_DIR/Payload"
    unzip -q "$BASE_IPA" 'Payload/*' -d "$WORK_DIR"
    [[ -d "$APP_DIR" ]] || die "extracted IPA has no Payload/Apollo.app"

    write_patcher
    # Patch every Mach-O in the bundle (main binary + appex + frameworks).
    mapfile -t MACHOS < <(find "$APP_DIR" -type f -print0 \
        | while IFS= read -r -d '' f; do file "$f" 2>/dev/null | grep -q 'Mach-O' && printf '%s\n' "$f"; done)
    log "Patching ${#MACHOS[@]} Mach-O files to iOS-Simulator platform"
    python3 "$PATCH_PY" "${MACHOS[@]}"

    # Re-sign ad-hoc inside-out (frameworks, then plugins, then the app).
    log "Re-signing ad-hoc"
    if [[ -d "$APP_DIR/Frameworks" ]]; then
        find "$APP_DIR/Frameworks" -maxdepth 1 -name '*.framework' -print0 \
            | while IFS= read -r -d '' fw; do codesign -f -s - "$fw" >/dev/null 2>&1; done
    fi
    if [[ -d "$APP_DIR/PlugIns" ]]; then
        for ext in "$APP_DIR/PlugIns"/*.appex; do
            [[ -e "$ext" ]] && codesign -f -s - "$ext" >/dev/null 2>&1
        done
    fi
    codesign -f -s - "$APP_DIR" >/dev/null 2>&1
fi

# Stage the tweak's resource bundle inside the app so ApolloBundledResourcePath()
# resolves (<App>.app/ApolloReborn.bundle/). Cheap; refresh every run.
if [[ -n "$BUNDLE_SRC" ]]; then
    rm -rf "$APP_DIR/ApolloReborn.bundle"
    cp -R "$BUNDLE_SRC" "$APP_DIR/ApolloReborn.bundle"
    codesign -f -s - "$APP_DIR" >/dev/null 2>&1
fi

# ----------------------------------------------------------------------------
# 3. Boot the simulator (create the device if needed).
# ----------------------------------------------------------------------------
if [[ -z "$SIM_RUNTIME" ]]; then
    SIM_RUNTIME="$(xcrun simctl list runtimes 2>/dev/null \
        | grep -oE 'com.apple.CoreSimulator.SimRuntime.iOS-[0-9-]+' | sort -V | tail -1)"
    [[ -n "$SIM_RUNTIME" ]] || die "no iOS simulator runtime installed"
fi
DEV="$(xcrun simctl list devices 2>/dev/null | grep -F "$SIM_NAME (" | grep -oE '[0-9A-F-]{36}' | head -1 || true)"
if [[ -z "$DEV" ]]; then
    log "Creating simulator '$SIM_NAME' ($SIM_DEVICE_TYPE, $SIM_RUNTIME)"
    DEV="$(xcrun simctl create "$SIM_NAME" "$SIM_DEVICE_TYPE" "$SIM_RUNTIME")"
fi
if ! xcrun simctl list devices booted | grep -q "$DEV"; then
    log "Booting simulator $DEV"
    xcrun simctl boot "$DEV" 2>/dev/null || true
fi
open -a Simulator >/dev/null 2>&1 || true
echo "$DEV" > "$WORK_DIR/device.txt"

# ----------------------------------------------------------------------------
# 4. Install the app and launch with the tweak injected.
# ----------------------------------------------------------------------------
log "Installing app"
xcrun simctl install "$DEV" "$APP_DIR"
xcrun simctl terminate "$DEV" "$BUNDLE_ID" >/dev/null 2>&1 || true

LOG_PID=""
if [[ "$DO_LOGS" == 1 ]]; then
    # ApolloLog() logs via os_log subsystem "apollofix" with an [ApolloFix] prefix.
    ( xcrun simctl spawn "$DEV" log stream --level debug \
        --predicate 'subsystem == "apollofix"' \
        2>/dev/null & echo $! > "$WORK_DIR/logpid" ) >/dev/null 2>&1
    LOG_PID="$(cat "$WORK_DIR/logpid" 2>/dev/null || true)"
fi

log "Launching $BUNDLE_ID with ApolloReborn.dylib injected"
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$(cd "$WORK_DIR" && pwd)/ApolloReborn.dylib" \
    xcrun simctl launch "$DEV" "$BUNDLE_ID"

# ----------------------------------------------------------------------------
# 5. Optional: idb UI smoke test (accessibility tree + screenshot).
# ----------------------------------------------------------------------------
if [[ "$DO_DRIVE" == 1 ]]; then
    if command -v "$IDB" >/dev/null 2>&1; then
        sleep 4
        log "idb: connecting and capturing UI state"
        "$IDB" connect "$DEV" >/dev/null 2>&1 || true
        "$IDB" ui describe-all --udid "$DEV" > "$WORK_DIR/uitree.json" 2>/dev/null || true
        "$IDB" screenshot --udid "$DEV" "$WORK_DIR/screenshot.png" 2>/dev/null || true
        log "idb: wrote $WORK_DIR/uitree.json and $WORK_DIR/screenshot.png"
    else
        echo "  (idb not found on PATH; set IDB=/path/to/idb — see AGENTS.md)" >&2
    fi
fi

if [[ -n "$LOG_PID" ]]; then
    log "Streaming ApolloReborn logs (Ctrl-C to stop)"
    wait "$LOG_PID" 2>/dev/null || true
fi

log "Done. Device: $DEV"
echo "  Re-run after a code change:  scripts/run-in-sim.sh            (rebuild + relaunch)"
echo "  Relaunch without rebuilding: scripts/run-in-sim.sh --no-build"
