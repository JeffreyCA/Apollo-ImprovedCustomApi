# Contributing

This project is an iOS tweak built with [Theos](https://theos.dev/) and [Logos](https://theos.dev/docs/logos-syntax.html). Development relies heavily on reverse engineering Apollo's binary, so an AI-assisted workflow with MCP (Model Context Protocol) tools can be super helpful.

## Getting Started

```bash
# Clone and init submodules
git submodule update --init --recursive

# Build
make package
```

## Testing in the iOS Simulator

You don't need a physical device to iterate on most changes. `scripts/run-in-sim.sh` builds the tweak for the iOS Simulator and launches Apollo with it injected, so a code change goes from edit to running app in seconds — no IPA, no certificates, no sideloading.

```bash
scripts/run-in-sim.sh              # build the sim tweak, prepare Apollo, launch it injected
scripts/run-in-sim.sh --no-build   # relaunch without rebuilding (e.g. after killing the app)
scripts/run-in-sim.sh --logs       # also stream the tweak's ApolloLog output after launch
scripts/run-in-sim.sh --fresh-app  # re-prepare the app after dropping in a new apollo-base.ipa
scripts/run-in-sim.sh --dark       # boot the simulator in dark mode (--light forces light)
scripts/run-in-sim.sh --glass      # apply the iOS 26 Liquid Glass patch (--no-glass disables)
scripts/run-in-sim.sh --backup B.zip  # preload a settings backup (API keys + account)
```

Requirements: Xcode with an iOS Simulator runtime installed, and the same `apollo-base.ipa` used for device builds in the repo root. The first run prepares a cached, simulator-compatible copy of Apollo under `./.sim/` (a few seconds); subsequent runs reuse it.

How it works, briefly: Apollo's App Store binary is built for device iOS, so the script rewrites each Mach-O's platform tag to iOS-Simulator and re-signs it ad-hoc (the arm64 code is identical on an Apple Silicon Mac). The tweak itself is built against the simulator SDK with Logos's *internal* generator — pure ObjC-runtime swizzling with no CydiaSubstrate dependency — and with `APOLLO_SIM_BUILD=1`, which skips the device-only FFmpegKit libraries. It's then injected with `DYLD_INSERT_LIBRARIES`.

**Liquid Glass.** By default the simulator shows the standard (pre-iOS-26) Apollo UI, because the base IPA is linked against an older SDK. Pass `--glass` to apply the iOS 26 Liquid Glass patch — the floating glass tab bar, capsule nav buttons, and the in-app icon picker. It reuses `patch.sh --liquid-glass` (the same patcher the device builds use) to produce a cached glass base, so it requires the Git-LFS asset catalog to be pulled (`git lfs pull` once). Toggling `--glass` / `--no-glass` re-prepares the app.

**Custom bundle id.** If your installed device build is rebranded, run the simulator under the same id so behavior matches: `BUNDLE_ID=com.example.MyBuild scripts/run-in-sim.sh`. The script rebrands the cached app (app + every extension) to that id and caches it; switching ids triggers one re-prepare. You can also override `SIM_DEVICE_TYPE`, `SIM_RUNTIME`, and `SIM_NAME`.

**Preload a settings backup.** A fresh simulator install has no API key, so Reddit content won't load. Point `--backup` at a `.zip` exported from **Settings → Backup Settings** and the script loads its API keys and browsing session into the simulator before launch, so feeds and most features populate:

```bash
scripts/run-in-sim.sh --backup ~/Downloads/Apollo_Backup_20260609.zip
# combine with a custom id + dark mode to mirror your device exactly:
BUNDLE_ID=com.example.MyBuild scripts/run-in-sim.sh --backup ~/Downloads/Apollo_Backup_20260609.zip --dark
```

Or drop the zip at `./.sim/backup.zip` once and it's auto-loaded on every run (no `--backup` needed) — handy for letting an AI agent test signed-in flows without re-specifying the path.

This restores your **API keys, app-only session, and your signed-in Reddit account** — so profile, inbox, and voting work in the simulator, not just browsing. Apollo loads accounts from the keychain (via Valet), and an ad-hoc-signed simulator app can't reach the real keychain, so the tweak virtualizes it: `Backup Settings` now captures Apollo's keychain account items into the backup (`keychain.plist`), and in the simulator the tweak serves them from a file-backed store. **This needs a backup exported by a build that includes this feature** — older backups have no `keychain.plist`, so the account won't restore (you'll see a note to that effect) and the Account tab stays at "sign in"; everything else still loads. Re-export a backup from your device to capture the account.

A backup `.zip` now contains your live Reddit **account credentials** (keychain) in addition to API keys — keep it out of the repo (the `./.sim/` working dir is gitignored) and don't commit one.

**Optional — automate the UI with idb.** To tap, type, and screenshot programmatically, install Facebook's [idb](https://fbidb.io/): `brew install facebook/fb/idb-companion`, then install the `fb-idb` Python client **into a Python 3.11 venv** (it relies on an asyncio API removed in Python 3.12+). Point the script at it and pass `--drive` to capture the accessibility tree and a screenshot after launch:

```bash
python3.11 -m venv ~/.idb-venv && ~/.idb-venv/bin/pip install fb-idb
IDB=~/.idb-venv/bin/idb scripts/run-in-sim.sh --drive   # writes ./.sim/uitree.json and ./.sim/screenshot.png
```

**What the simulator can't test:** push notifications (so Live Activities push-to-start needs a real device), the FFmpeg-based v.redd.it audio remux (compiled out of sim builds), and any other genuinely device-only behavior. Validate those on a device IPA. Everything else — settings, navigation, Liquid Glass, layout, media playback UI — works in the simulator, which runs the same iOS version family as a modern device.

## Agent-Assisted Development

This project includes an [AGENTS.md](AGENTS.md) file that gives coding agents full context about the codebase, conventions, and RE techniques.

## Disassembler MCP Setup

A disassembler with MCP support lets agents query the binary directly. This guide covers [Hopper Disassembler](https://www.hopperapp.com/) which has one built in, but other tools like Ghidra work too.

1. **Install Hopper** from [hopperapp.com](https://www.hopperapp.com/).
2. **Open Apollo's binary** in Hopper (extract from the `.ipa` → `Payload/Apollo.app/Apollo`).
3. **Configure the MCP server** in your coding agent's MCP config using the STDIO transport protocol (syntax varies):

```json
{
    "mcpServers": {
        "HopperMCPServer": {
            "command": "/Applications/Hopper Disassembler.app/Contents/MacOS/HopperMCPServer",
            "args": [],
            "env": {}
        }
    }
}
```

See [AGENTS.md](AGENTS.md) for detailed Hopper MCP tools and investigation patterns.

## Apple Developer Docs MCP Setup

The [apple-docs-mcp](https://github.com/kimsungwhee/apple-docs-mcp) server gives agents live access to Apple Developer documentation, WWDC transcripts, and framework symbol search.

```json
{
    "mcpServers": {
        "apple-dev": {
            "command": "npx",
            "args": ["-y", "apple-docs-mcp@latest"]
        }
    }
}
```

## iOS 26 Runtime Headers (for Liquid Glass work)

For iOS 26 / Liquid Glass-specific tweaks, clone these into the repo root so agents can grep them directly. Both are gitignored.

```bash
# RuntimeBrowser-style ObjC headers for every framework
git clone https://github.com/qingralf/iOS26-Runtime-Headers.git

# IDA-style decompilation of iOS 26.1. The full repo is huge; sparse-checkout
# just UIKitCore.framework (the only slice that's typically needed).
git clone --depth 1 --filter=blob:none --sparse https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore.git
cd iPhone18-3_26.1_23B85_Restore
git sparse-checkout set System/Library/PrivateFrameworks/UIKitCore.framework
cd ..
```

See [AGENTS.md](AGENTS.md) for usage notes.

## Adding a New Feature

Tips for prompting effectively:

**Describe the behavior, not the implementation** — focus on what you want from the user's perspective.

> "When I scroll past an unmuted video in comments, the audio stops. Can you make it keep playing?"

**Provide runtime context** — paste crash backtraces, `ApolloLog` console output, and screenshots so the agent can diagnose quickly.
