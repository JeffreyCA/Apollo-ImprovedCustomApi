#!/bin/bash
set -euo pipefail

# Re-sign an already-provisioned IPA (e.g. a Sideloadly "Export IPA" artifact)
# with Apple's `codesign`, inside-out.
#
# Why: zsign-based signers (Sideloadly, some AltStore/Feather builds) can produce
# app-extension executables that iOS 26 AMFI rejects at launch with
#   "AMFI: constraint violation … <appex> has entitlements but is not a main binary"
# (the appex crashes during launch; the share action "does nothing"). Apple's
# `codesign` sets CS_EXECSEG_MAIN_BINARY on the app + appex executables and
# applies entitlements only to main binaries, which iOS 26 accepts. It also signs
# every dylib (so an injected ApolloOpenInFix.dylib in Frameworks/ is covered).
#
# Entitlements are reused from each target's own embedded.mobileprovision (the
# same source Xcode uses), so app/appex identities stay consistent.
#
# IMPORTANT: install the OUTPUT without re-signing — e.g.
#   ideviceinstaller -i <output.ipa>
#   xcrun devicectl device install app --device <id> <output.ipa>
#   Apple Configurator (drag-install)
# Re-signing it again through Sideloadly/AltStore would undo this fix.

usage() {
    echo "Usage: $0 <input.ipa> <signing-identity> [--profile <p.mobileprovision>] [-o <output.ipa>]"
    echo ""
    echo "  <signing-identity>  e.g. \"Apple Development: you@example.com (ABCDE12345)\""
    echo "                      list yours with: security find-identity -v -p codesigning"
    echo "                      use \"-\" for an ad-hoc dry run (mechanics check only)."
    echo "  --profile <file>    iOS App Development provisioning profile (your team + device);"
    echo "                      a wildcard App ID (TEAMID.*) covers the app + all appexes."
    echo "                      REQUIRED if the input IPA has no embedded.mobileprovision"
    echo "                      (e.g. a Sideloadly export) — otherwise it won't install."
    echo "  -o <output.ipa>     default: <input>-resigned.ipa"
}

[[ $# -lt 2 || "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && exit 0; exit 1; }

IPA="$1"; IDENTITY="$2"; shift 2
OUT=""; PROFILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output) OUT="$2"; shift 2 ;;
        -p|--profile) PROFILE="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; usage; exit 1 ;;
    esac
done
# A Sideloadly "Export IPA" omits embedded.mobileprovision, so the result isn't
# device-installable. Pass --profile <wildcard.mobileprovision> (an iOS App
# Development profile for your team + device, ideally a wildcard App ID like
# TEAMID.*) to embed it into the app + every appex and sign with its entitlements.
if [[ -n "$PROFILE" ]]; then
    [[ -f "$PROFILE" ]] || { echo "Error: profile not found: $PROFILE"; exit 1; }
    case "$PROFILE" in /*) : ;; *) PROFILE="$PWD/$PROFILE" ;; esac
fi

[[ -f "$IPA" ]] || { echo "Error: IPA not found: $IPA"; exit 1; }
case "$IPA" in /*) : ;; *) IPA="$PWD/$IPA" ;; esac
[[ -z "$OUT" ]] && OUT="${IPA%.ipa}-resigned.ipa"
case "$OUT" in /*) : ;; *) OUT="$PWD/$OUT" ;; esac

for tool in unzip zip codesign security /usr/libexec/PlistBuddy; do
    command -v "$tool" >/dev/null 2>&1 || [[ -x "$tool" ]] || { echo "Error: missing tool: $tool"; exit 1; }
done

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
(cd "$work" && unzip -q "$IPA")

app="$(find "$work/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
[[ -n "$app" && -d "$app" ]] || { echo "Error: no .app in IPA"; exit 1; }

# Extract the Entitlements dict from an embedded.mobileprovision into a plist.
ent_from_profile() {
    local prov="$1" out="$2"
    [[ -f "$prov" ]] || return 1
    security cms -D -i "$prov" > "$work/_prof.plist" 2>/dev/null || return 1
    /usr/libexec/PlistBuddy -x -c "Print :Entitlements" "$work/_prof.plist" > "$out" 2>/dev/null || return 1
    return 0
}

# Resolve a wildcard application-identifier (TEAMID.*) in an entitlements plist to
# the bundle's concrete id (TEAMID.<CFBundleIdentifier>). Required so the signed
# app-id matches the bundle id (install validity) AND the already-installed app's
# id (clean in-place upgrade — a literal "TEAMID.*" string mismatches it).
resolve_appid() {  # resolve_appid <ent.plist> <bundle-dir>
    local ent="$1" bundle="$2" bid team cur
    bid="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$bundle/Info.plist" 2>/dev/null || true)"
    [[ -n "$bid" ]] || return 0
    team="$(/usr/libexec/PlistBuddy -c "Print :com.apple.developer.team-identifier" "$ent" 2>/dev/null || true)"
    if [[ -z "$team" ]]; then
        cur="$(/usr/libexec/PlistBuddy -c "Print :application-identifier" "$ent" 2>/dev/null || true)"
        team="${cur%%.*}"
    fi
    [[ -n "$team" ]] || return 0
    /usr/libexec/PlistBuddy -c "Set :application-identifier $team.$bid" "$ent" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :application-identifier string $team.$bid" "$ent"
}

sign() {  # sign <path> [entitlements-plist]
    if [[ -n "${2:-}" ]]; then
        codesign -f -s "$IDENTITY" --entitlements "$2" --generate-entitlement-der "$1"
    else
        codesign -f -s "$IDENTITY" "$1"
    fi
}

echo "Re-signing $(basename "$IPA") with identity: $IDENTITY"

# 1) All dylibs (no entitlements) — deepest first is irrelevant for loose dylibs.
while IFS= read -r d; do
    echo "  sign dylib: ${d#$app/}"; sign "$d"
done < <(find "$app" -type f -name "*.dylib")

# 2) All .framework bundles (no entitlements), deepest first.
while IFS= read -r fw; do
    echo "  sign framework: ${fw#$app/}"; sign "$fw"
done < <(find "$app" -type d -name "*.framework" | awk '{print length, $0}' | sort -rn | cut -d' ' -f2-)

# Embed --profile (if given) into a bundle and return the profile path to use.
profile_for() {  # profile_for <bundle-dir>  -> echoes profile path or empty
    local bundle="$1"
    if [[ -n "$PROFILE" ]]; then
        cp "$PROFILE" "$bundle/embedded.mobileprovision"
        printf '%s\n' "$bundle/embedded.mobileprovision"
    elif [[ -f "$bundle/embedded.mobileprovision" ]]; then
        printf '%s\n' "$bundle/embedded.mobileprovision"
    fi
}

# 3) Each .appex (entitlements from its embedded/--profile mobileprovision), deepest first.
while IFS= read -r ax; do
    ent="$work/$(basename "$ax").ent.plist"; prov="$(profile_for "$ax")"
    if [[ -n "$prov" ]] && ent_from_profile "$prov" "$ent"; then
        resolve_appid "$ent" "$ax"
        echo "  sign appex (w/ provisioned entitlements): ${ax#$app/}"; sign "$ax" "$ent"
    else
        echo "  WARNING: no provisioning for ${ax#$app/}; signing without entitlements (won't install on device)"; sign "$ax"
    fi
done < <(find "$app/PlugIns" -type d -name "*.appex" 2>/dev/null | awk '{print length, $0}' | sort -rn | cut -d' ' -f2-)

# 4) The app bundle last (entitlements from its embedded/--profile mobileprovision).
app_ent="$work/app.ent.plist"; app_prov="$(profile_for "$app")"
if [[ -n "$app_prov" ]] && ent_from_profile "$app_prov" "$app_ent"; then
    resolve_appid "$app_ent" "$app"
    echo "  sign app (w/ provisioned entitlements): $(basename "$app")"; sign "$app" "$app_ent"
else
    echo "  WARNING: no app provisioning; signing without entitlements (won't install on device)"; sign "$app"
fi

echo "Verifying…"
codesign -v --strict --verbose=2 "$app" 2>&1 | sed 's/^/  /' || { echo "Error: app failed codesign verification"; exit 1; }

rm -f "$OUT"
(cd "$work" && zip -qry "$OUT" Payload)
echo "Re-signed IPA: $OUT"
echo "Install WITHOUT re-signing (ideviceinstaller -i / devicectl / Apple Configurator)."
