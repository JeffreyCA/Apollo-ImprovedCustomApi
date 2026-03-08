# AGENTS.md

## Project Overview

Apollo-ImprovedCustomApi is an iOS tweak for the Apollo for Reddit app that adds in-app configurable API keys and several bug fixes/improvements. Built using the Theos framework, it hooks into Apollo's runtime to provide custom API credential management, sideload fixes, and media handling improvements.

## Build & Development Commands

```bash
# Sync submodules (required before first build)
git submodule update --init --recursive

# Standard build
make package
```

The Makefile automatically generates `Version.h` from the `control` file and links FFmpegKit libraries.

## Project Structure

### Core Tweak Modules

| Path | Purpose |
|------|---------|
| `Tweak.xm` / `Tweak.h` | Main tweak: keychain spoofing, Imgur upload fixes, NSURLSession hooks, URL blocking, feature unlocks, `%ctor` |
| `ApolloShareLinks.xm` | Share link resolution |
| `ApolloMedia.xm` | Media handling: Giphy metadata synthesis, GIF speed fix, v.redd.it, Streamable |
| `ApolloLiquidGlass.xm` | iOS 26 Liquid Glass UI patches (nav bar, tab bar, scroll fixes) |
| `ApolloSettings.xm` | Settings injection into Apollo's Settings screen |
| `ApolloRecentlyRead.xm` | "Recently Read" posts feature |
| `ApolloSavedCategories.xm` | Sort fix for saved categories (ActionController + UIContextMenu) |
| `ApolloVideoUnmute.xm` | Auto-unmute header video in CommentsViewController |
| `ApolloCommon.{h,m}` | Shared utilities: `ApolloLog` macro, helper functions |
| `ApolloState.{h,m}` | Global state: captured singletons, feature flags |

### Settings & UI

| Path | Purpose |
|------|---------|
| `CustomAPIViewController.{h,m}` | Settings UI for API keys, subreddit sources, backup/restore, tweak options |
| `SavedCategoriesViewController.{h,m}` | Saved post categories CRUD (add/rename/delete, stored in group NSUserDefaults) |

### Runtime & Libraries

| Path | Purpose |
|------|---------|
| `fishhook.{c,h}` | Facebook's fishhook for C function rebinding (Security framework, `swift_allocObject`) |
| `ffmpeg-kit/` | FFmpegKit static libs for v.redd.it CMAF video processing |
| `ZipArchive/` | SSZipArchive for settings backup/restore zip export |
| `Tweaks/FLEXing/` | FLEX debugging tools (git submodule) |

### Reference & Build

| Path | Purpose |
|------|---------|
| `Headers/` | Class-dump headers for Apollo |
| `packages/` | Build output (.deb files) |
| `control` | Debian package metadata (name, version, depends) |
| `Makefile` | Theos build config; auto-generates `Version.h`, links FFmpegKit |

## Theos & Logos Conventions

- Use Logos directives (`%hook`, `%orig`, `%group`, `%ctor`) for runtime patches
- Use `%hookf` for C function hooks
- Register new source files in `Makefile` under `ApolloImprovedCustomApi_FILES`
- Keep related hooks grouped together
- **`%orig` passes original arguments**: `%orig;` always calls the original method with the original captured arguments, even if you've reassigned the local parameter variables. To pass modified values, use explicit arguments: `%orig(arg1, modifiedArg2, arg3)`. This matters when normalizing URLs in blocks/callbacks — the ignoreHandler must use `%orig(textNode, attr, val, point, range)` not bare `%orig;` if `val` was modified.
- **`MSHookIvar` only works inside `%hook` blocks**: It's a Logos macro. In static helper functions, use `class_getInstanceVariable` + `object_getIvar` from the ObjC runtime instead.

## Code Style

- **Indentation**: 4 spaces
- **Braces**: Same line as statement
- **Logging**: Use `ApolloLog` for privacy-friendly diagnostics
- When iterating on a feature, if something isn't working, prefer outright replacing the implementation over adding fallback codepaths. Use generous amount of comments and diagnostic/debug logging.

## Testing

No automated test suite, must be validated manually.

## RE Notes

### Handy Hopper MCP Tools

- `Hopper/list_documents`, `Hopper/set_current_document`: select `Apollo.hop`
- `Hopper/goto_address`: jump to an address (static address Hopper uses)
- `Hopper/current_procedure`: find which function the current address is in
- `Hopper/procedure_pseudo_code`, `Hopper/procedure_assembly`: decompile/disassemble the function
- `Hopper/search_procedures`: find functions by name/regex (works well for ObjC methods)
- `Hopper/search_strings`: search embedded strings (bundle IDs, selectors, product identifiers, URLs)
- `Hopper/xrefs`: find references to a string or address
- `Hopper/list_segments`, `Hopper/list_names`: quick orientation for the binary layout
- `Hopper/procedure_callers`, `Hopper/procedure_callees`: trace call graphs (who calls this? what does this call?)

### Effective Hopper Investigation Patterns

**Discovering class layout via `.cxx_destruct`**: Search for `-[ClassName .cxx_destruct]` and decompile it. This reveals every ivar in the class, their types (ObjC objects use `objc_release`, Swift structs use type metadata accessors, bridged objects use `swift_bridgeObjectRelease`), and their ivar offset symbols. This is the fastest way to understand a Swift class's storage layout from ObjC.

**Tracing from a known entry point**: When you know the ObjC method (e.g. `linkButtonTappedWithSender:`), decompile it to find the `sub_XXXX` helper it delegates to. Then decompile that helper. This "peel the onion" approach is how you find the actual navigation/logic functions buried under Swift thunks.

**Fix transition bugs at the source**: For media/navigation regressions, start from the method that initiates the behavior (`commentsButtonTapped:`, `didExitVisibleState`, reclaim helpers, MediaViewer dismiss callbacks) and trace forward in Hopper before adding new hooks. In this repo, the durable fixes usually came from understanding the native transition or async completion block first, not from stacking more downstream notification hooks.

**Identifying Swift property access patterns**: Swift stored properties on classes don't always have ObjC getters. Check `search_procedures` for the class — if no `-[Class property]` method exists, the property is NOT `@objc`-visible. You'll need alternative access strategies (reading from display nodes, using runtime ivar access, etc.) rather than `objc_msgSend`.

**Reading Swift function calls in pseudocode**: Hopper labels Swift stdlib/Foundation calls like `Foundation.URL.absoluteString.getter()`, `Swift.String._bridgeToObjectiveC()`, etc. These tell you what types are in play even when the pseudocode is hard to follow. Look for these labels to understand data flow.

**Pseudocode constant folding of base registers**: Hopper's decompiler sometimes loses track of a base register and folds it into offset constants, producing misleading absolute-looking addresses. For example, if the assembly is `madd x8, x21, x8, x22` then `str w0, [x8, #0x20]` (meaning `buffer + index*stride + 0x20`), the pseudocode may render this as `*(stride * index + 0x50)` — collapsing `buffer + 0x20` into a single constant `0x50`. This is a critical trap: the pseudocode appears to say elements start at offset 0x50, when they actually start at buffer+0x20. **Always verify struct/array element offsets from the raw assembly** (look for `madd`/`add` base register calculations and `ldr`/`str` displacement operands) rather than trusting the pseudocode constants.

**Decoding Swift small strings from assembly**: Strings <=15 bytes are stored inline in two registers (x0/x1) rather than as heap pointers. Hopper's decompiler hides the actual values behind `_bridgeToObjectiveC()` calls — you must read the raw assembly. Layout: x0 holds bytes 0-7 (little-endian), x1 holds bytes 8-14 in bits 0-55 plus a discriminator byte in bits 56-63 (discriminator = `0xE0 + length`). Each `mov`/`movk` with `#0xXXYY` stores two ASCII bytes in little-endian order (YY first, XX second). Strings >15 bytes use buffer pointers (`x1 = addr | 0x8000000000000000`, UTF-8 at `addr+0x20`) and appear in Hopper's string table. See `docs/sekrit-icon-keys-RE.md` for a worked example.

### Mapping Runtime PCs To Hopper Addresses

Crash logs typically show:

- A loaded image base, e.g. `Apollo 0x10444c000 + 7746680`
- A program counter (PC), e.g. `0x104baf478`

The offset is `PC - imageBase`. Hopper usually uses a Mach-O "file base" of `0x100000000`, so:

- `hopperAddr = 0x100000000 + (PC - imageBase)`

Once you have `hopperAddr`:

- `Hopper/goto_address` -> `Hopper/current_procedure` -> decompile around the trap/crash site.

### Swift Struct Ivars and iOS Version Pitfalls

Swift value types (structs like `Foundation.URL`) stored as ivars in a class are laid out inline — they are NOT object pointers. `MSHookIvar<NSURL *>` on a `URL` ivar works by accident on older iOS (where `URL`'s first field happened to be an `NSURL *`) but breaks when Apple changes the struct layout (e.g. iOS 26 swift-foundation changes). When you need data from a Swift struct ivar:

1. Check if there's an `@objc` getter (search Hopper for `-[Class property]`)
2. If not, look for ObjC display nodes or other ObjC objects that hold the same data (e.g. `urlTextNode.attributedText.string` for a URL shown in a button)
3. As a last resort, study the struct layout via `.cxx_destruct` and the type metadata accessor

### Capturing Swift Singletons via fishhook

Pure Swift classes (no ObjC-visible methods) that use `dispatch_once` singletons can't be accessed through normal hooking. Use `fishhook` to briefly hook `swift_allocObject`, match on the class's type metadata pointer (which equals the `objc_getClass` result for Swift classes), capture the instance, and immediately unhook:

```objc
static __unsafe_unretained id sSingleton = nil;
static void *sTargetMetadata = NULL;
static void *(*orig_swift_allocObject)(void *type, size_t size, size_t alignMask);

static void *hooked_swift_allocObject(void *type, size_t size, size_t alignMask) {
    void *obj = orig_swift_allocObject(type, size, alignMask);
    if (type == sTargetMetadata && !sSingleton) {
        sSingleton = (__bridge id)obj;
        rebind_symbols((struct rebinding[1]){{"swift_allocObject", (void *)orig_swift_allocObject, NULL}}, 1);
    }
    return obj;
}

// In %ctor:
sTargetMetadata = (__bridge void *)objc_getClass("_TtC6Module12ClassName");
if (sTargetMetadata) {
    rebind_symbols((struct rebinding[1]){{"swift_allocObject", (void *)hooked_swift_allocObject, (void **)&orig_swift_allocObject}}, 1);
}
```

Once captured, access ivars via `class_copyIvarList` + `object_getIvar` (by name for robustness, with fallback by type). This avoids hardcoded binary addresses and works across binary versions as long as the class/property names are stable.

### ASVideoNode Player Access — Shareable vs Non-Shareable

Apollo uses two distinct video player paths depending on content type:

**Two player paths:**
- **Shareable** (v.redd.it): player shared via AVPlayerLayer between feed and comments. ASVideoNode's `_player` ivar is nil — player lives on `[[videoNode playerLayer] player]`.
- **Non-shareable** (GIFs, Giphy, Streamable): player on `[videoNode player]` directly.
- **Always use `[[videoNode playerLayer] player]`** (the native mute handler's path), fall back to `[videoNode player]` if playerLayer returns nil.

**Transition-specific behavior:**
- **Compact posts**: feed -> fullscreen -> comments often creates a fresh comments `AVPlayer` asynchronously. Do not assume the fullscreen player and comments player are the same object; expect to retry after async asset/player preparation completes.
- **Non-compact posts**: feed/comments/fullscreen may all be manipulating the same shared player layer. Fixes must update the real player state first, then separately resync the mute button/icon if Apollo's UI falls out of sync.
- **Crossposts**: when scanning visible media or resyncing state, inspect both the cell's `richMediaNode` and `crosspostNode.richMediaNode`.

**Unmuting requires (in order):**
1. `setCategory:AVAudioSessionCategoryPlayback` — Apollo defaults to `Ambient`, which silences audio even when `player.muted=NO`.
2. `[player setMuted:NO]` directly (for shareable, `[videoNode setMuted:NO]` alone won't reach the real player since `_player` is nil) + `[videoNode setMuted:NO]` to sync the internal `_muted` flag.
3. Blocking session reversion to `Ambient` — Apollo resets the session after player setup. Handled by AVAudioSession hooks keyed on `sAutoUnmutedPlayer`.

**Mute dance** (`sub_1003414cc`): Apollo's async mute sequence, fired when a video exits the visible area (`TouchHintVideoNode.didExitVisibleState` → `sub_10058cb30`) or when fullscreen MediaViewer dismisses. T+0: pause all, T+50ms: `setCategory:Ambient` + `setActive:NO`, T+100ms: `setMuted:YES` + unpause all. The native unmute (`sub_100341894`) survives this because it registers the player with `VideoSharingManager.activeAudioPlayer`; our auto-unmute survives via `sAutoUnmutedPlayer` + hook blocking. The native unpause handler only resumes non-shareable videos — shareable comments header videos stay paused, fixed in our `RichMediaNode.unpauseAllAVPlayersNotificationReceivedWithNotification:` hook.

**Mute button:** Icon names `"small-mute"` / `"small-unmute"` on MuteUnmuteVideoButtonNode's `icon` ASImageNode, with `isMuted` Swift Bool ivar. Don't use `muteUnmuteButtonTappedWithSender:` for programmatic unmuting — it's a toggle (mutes if already unmuted) and depends on a weak `actionDelegate` that may be nil.

**Best hook for comments header video:** `RichMediaHeaderCellNode.cellNodeVisibilityEvent:` — event-driven, comments-only (no context check needed). Player may not exist on event=0; use ~500ms retry.

## Headers And Runtime Introspection Tips

- For methods you only need to call defensively, prefer `objc_getClass` + `NSSelectorFromString` + `objc_msgSend` over adding brittle headers.
- If a class is only forward-declared, cast `self` to `UIViewController *` (or `id`) before sending UIKit messages to keep clang happy.
