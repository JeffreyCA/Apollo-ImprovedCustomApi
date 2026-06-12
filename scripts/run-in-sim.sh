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
#   scripts/run-in-sim.sh --dark          # boot the simulator in dark mode (--light forces light)
#   scripts/run-in-sim.sh --glass         # apply the iOS 26 Liquid Glass patch (--no-glass disables)
#   BUNDLE_ID=com.you.Build scripts/run-in-sim.sh
#                                         # run under a custom bundle id (rebrands the app + appex
#                                         # so it matches your installed device build)
#   scripts/run-in-sim.sh --backup my.zip # preload an Apollo settings backup (API keys + account)
#
# Env overrides:
#   BASE_IPA (./apollo-base.ipa)  BUNDLE_ID (com.christianselig.Apollo)
#   SIM_NAME (Apollo-Sim)  SIM_DEVICE_TYPE (iPhone 16 Pro)  SIM_RUNTIME (newest iOS)
#   DEPLOY_MIN (14.0)  WORK_DIR (./.sim)  IDB (idb on PATH)
#   BACKUP_ZIP (--backup)  APPEARANCE (light|dark, --dark/--light)  GLASS (0|1, --glass)
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
DEFAULT_BUNDLE_ID="com.christianselig.Apollo"
APP_GROUP_SUITE="group.com.christianselig.apollo"   # tweak hardcodes this regardless of bundle id
BACKUP_ZIP="${BACKUP_ZIP:-}"
APPEARANCE="${APPEARANCE:-}"
GLASS="${GLASS:-0}"

DO_BUILD=1; FRESH_APP=0; DO_LOGS=0; DO_DRIVE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-build)   DO_BUILD=0 ;;
        --fresh-app)  FRESH_APP=1 ;;
        --logs)       DO_LOGS=1 ;;
        --drive)      DO_DRIVE=1 ;;
        --dark)       APPEARANCE=dark ;;
        --light)      APPEARANCE=light ;;
        --glass)      GLASS=1 ;;
        --no-glass)   GLASS=0 ;;
        --backup)     BACKUP_ZIP="${2:-}"; shift ;;
        --backup=*)   BACKUP_ZIP="${1#*=}" ;;
        -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done
# Convention: if no backup was named, auto-load ./.sim/backup.zip when present, so
# agents/devs can drop a settings backup there once and have it preloaded on every
# run. (./.sim/ is gitignored; a backup zip carries live credentials — never commit
# it.) Pass --backup '' or BACKUP_ZIP='' explicitly to opt out.
DEFAULT_BACKUP="$WORK_DIR/backup.zip"
if [[ -z "$BACKUP_ZIP" && -f "$DEFAULT_BACKUP" ]]; then
    BACKUP_ZIP="$DEFAULT_BACKUP"
fi
[[ -n "$BACKUP_ZIP" && ! -f "$BACKUP_ZIP" ]] && { echo "error: backup zip not found: $BACKUP_ZIP" >&2; exit 2; }

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
# The cached shell carries one specific bundle id; if a different BUNDLE_ID is
# requested, re-prepare from the base IPA so the app + appex CFBundleIdentifiers
# match. Read the id straight from the cached Info.plist so this is robust even
# without a marker file.
if [[ -f "$APP_DIR/Info.plist" ]]; then
    CACHED_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DIR/Info.plist" 2>/dev/null || true)"
    if [[ -n "$CACHED_ID" && "$CACHED_ID" != "$BUNDLE_ID" ]]; then
        log "Requested BUNDLE_ID '$BUNDLE_ID' differs from prepared '$CACHED_ID' — re-preparing app"
        FRESH_APP=1
    fi
fi
# Liquid Glass is an irreversible patch baked into the cached shell (SDK bump +
# Assets.car swap), so re-prepare when the requested --glass state differs from
# what's cached. The cached state is read from the main binary's linked SDK:
# >= 19.0 (iOS 26) means glass is on.
if [[ -f "$APP_DIR/Apollo" ]]; then
    CACHED_SDK_MAJOR="$(vtool -show-build "$APP_DIR/Apollo" 2>/dev/null | awk '/sdk/{split($2,v,"."); print v[1]}')"
    CACHED_GLASS=0; [[ -n "$CACHED_SDK_MAJOR" && "$CACHED_SDK_MAJOR" -ge 19 ]] && CACHED_GLASS=1
    if [[ "$CACHED_GLASS" != "$GLASS" ]]; then
        log "Requested glass=$GLASS differs from prepared glass=$CACHED_GLASS — re-preparing app"
        FRESH_APP=1
    fi
fi

if [[ "$FRESH_APP" == 1 || ! -d "$APP_DIR" ]]; then
    [[ -f "$BASE_IPA" ]] || die "base IPA not found at $BASE_IPA (set BASE_IPA=...)"

    # With --glass, prep from a Liquid-Glass-patched base produced by the canonical
    # patch.sh --liquid-glass (SDK bump to iOS 26 + duplicate-LC_RPATH fix + Assets.car
    # swap + CFBundleAlternateIcons metadata — the latter is what flips the tweak's
    # icon-picker on). Cached as ./.sim/glass-base.ipa; regenerated only when the base
    # IPA changes. The platform patch below then re-targets it at the simulator.
    SRC_IPA="$BASE_IPA"
    if [[ "$GLASS" == 1 ]]; then
        SRC_IPA="$WORK_DIR/glass-base.ipa"
        if [[ ! -f "$SRC_IPA" || "$BASE_IPA" -nt "$SRC_IPA" ]]; then
            log "Generating Liquid Glass base IPA via patch.sh --liquid-glass (cached at $SRC_IPA)"
            ./patch.sh "$BASE_IPA" --liquid-glass -o "$SRC_IPA"
        fi
    fi

    log "Preparing simulator app shell from $SRC_IPA (one-time; re-run with --fresh-app to redo)"
    rm -rf "$WORK_DIR/Payload"
    unzip -q "$SRC_IPA" 'Payload/*' -d "$WORK_DIR"
    [[ -d "$APP_DIR" ]] || die "extracted IPA has no Payload/Apollo.app"

    write_patcher
    # Patch every Mach-O in the bundle (main binary + appex + frameworks).
    mapfile -t MACHOS < <(find "$APP_DIR" -type f -print0 \
        | while IFS= read -r -d '' f; do file "$f" 2>/dev/null | grep -q 'Mach-O' && printf '%s\n' "$f"; done)
    log "Patching ${#MACHOS[@]} Mach-O files to iOS-Simulator platform"
    python3 "$PATCH_PY" "${MACHOS[@]}"

    # Optionally rebrand the bundle id (app + every appex) so it matches a custom
    # device build, mirroring scripts/rebrand-ipa.sh. Only the CFBundleIdentifier
    # changes; the apollo:// URL scheme and the group.com.christianselig.apollo app
    # group are left as-is (the tweak hardcodes that group regardless of bundle id).
    if [[ "$BUNDLE_ID" != "$DEFAULT_BUNDLE_ID" ]]; then
        PB=/usr/libexec/PlistBuddy
        OLD_BASE="$("$PB" -c 'Print :CFBundleIdentifier' "$APP_DIR/Info.plist")"
        log "Rebranding bundle id: $OLD_BASE -> $BUNDLE_ID"
        "$PB" -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_DIR/Info.plist"
        shopt -s nullglob
        for ax in "$APP_DIR"/PlugIns/*.appex; do
            axplist="$ax/Info.plist"
            [[ -f "$axplist" ]] || continue
            axid="$("$PB" -c 'Print :CFBundleIdentifier' "$axplist" 2>/dev/null || true)"
            if [[ "$axid" == "$OLD_BASE" ]]; then
                "$PB" -c "Set :CFBundleIdentifier $BUNDLE_ID" "$axplist"
            elif [[ "$axid" == "$OLD_BASE."* ]]; then
                "$PB" -c "Set :CFBundleIdentifier ${BUNDLE_ID}.${axid#$OLD_BASE.}" "$axplist"
            fi
        done
        shopt -u nullglob
    fi

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

if [[ -n "$APPEARANCE" ]]; then
    log "Setting simulator appearance: $APPEARANCE"
    xcrun simctl ui "$DEV" appearance "$APPEARANCE" >/dev/null 2>&1 || true
fi

# ----------------------------------------------------------------------------
# 4. Install the app and launch with the tweak injected.
# ----------------------------------------------------------------------------
# When preloading a backup, uninstall first so the data container (and cfprefsd's
# cached preferences) are wiped — then the injected plists are read cleanly on the
# next launch instead of being shadowed by stale cached values.
if [[ -n "$BACKUP_ZIP" ]]; then
    xcrun simctl uninstall "$DEV" "$BUNDLE_ID" >/dev/null 2>&1 || true
fi

log "Installing app"
xcrun simctl install "$DEV" "$APP_DIR"
xcrun simctl terminate "$DEV" "$BUNDLE_ID" >/dev/null 2>&1 || true

# Preload an Apollo settings backup (the .zip exported from Settings → Backup):
# preferences.plist -> the app's main prefs domain, group.plist -> the app-group
# domain. Both live in the app data container in the simulator (the group suite
# falls back there without full app-group provisioning). This signs the app in with
# the backup's account and API keys so real, logged-in features can be tested.
if [[ -n "$BACKUP_ZIP" ]]; then
    log "Preloading settings backup: $(basename "$BACKUP_ZIP")"
    BK_DIR="$(mktemp -d)"
    unzip -q -o "$BACKUP_ZIP" -d "$BK_DIR"
    BK_MAIN="$(find "$BK_DIR" -name 'preferences.plist' | head -1)"
    BK_GROUP="$(find "$BK_DIR" -name 'group.plist' | head -1)"
    BK_KEYCHAIN="$(find "$BK_DIR" -name 'keychain.plist' | head -1)"
    [[ -n "$BK_MAIN" ]] || die "backup zip has no preferences.plist"
    DATA="$(xcrun simctl get_app_container "$DEV" "$BUNDLE_ID" data)"
    PREFS="$DATA/Library/Preferences"
    mkdir -p "$PREFS"
    cp "$BK_MAIN" "$PREFS/$BUNDLE_ID.plist"
    [[ -n "$BK_GROUP" ]] && cp "$BK_GROUP" "$PREFS/$APP_GROUP_SUITE.plist"
    # Stage the captured keychain items as a seed for the tweak's simulator keychain shim
    # (Tweak.xm imports Library/Caches/ApolloKeychainSeed.plist on first keychain access).
    # This is what restores a fully signed-in *user* account in the sim — the accounts blob
    # lives only in the keychain, and the ad-hoc-signed app can't reach the real one.
    KC_SEEDED=0
    if [[ -n "$BK_KEYCHAIN" ]]; then
        mkdir -p "$DATA/Library/Caches"
        cp "$BK_KEYCHAIN" "$DATA/Library/Caches/ApolloKeychainSeed.plist"
        KC_SEEDED=1
    fi
    rm -rf "$BK_DIR"
    if [[ "$KC_SEEDED" == 1 ]]; then
        log "Backup applied (API keys + browsing session + signed-in account via keychain seed)"
    else
        # Older backup with no keychain.plist: API keys + app-only session load (feed
        # populates), but the signed-in *user* account won't restore. Re-export a backup
        # with an updated build to capture the account keychain. See AGENTS.md.
        log "Backup applied (API keys + browsing; no keychain.plist — user login won't restore, re-export to capture it)"
    fi
fi

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
