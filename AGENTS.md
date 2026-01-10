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

| Path | Purpose |
|------|---------|
| `Tweak.xm` / `Tweak.h` | Main tweak logic using Logos syntax for method hooking |
| `CustomAPIViewController.{h,m}` | Settings UI for API keys and tweak options |
| `Defaults.{h,m}` | Default values |
| `UserDefaultConstants.h` | NSUserDefaults key constants |
| `UIWindow+Apollo.{h,m}` | Apollo app window extensions |
| `fishhook.{c,h}` | Runtime function hooking for Security framework workarounds |
| `ffmpeg-kit/` | FFmpegKit for video processing (v.redd.it downloads) |
| `Tweaks/FLEXing/` | FLEX debugging tools submodule |
| `ZipArchive/` | SSZipArchive for backup/restore functionality |
| `Resources/` | Image assets and encoding utilities |
| `packages/` | Build output (.deb files) |

## Key Features

1. **API Key Management**: Custom Reddit/Imgur API credential configuration
2. **Sideload Fixes**: Security framework patches for keychain access group restrictions
3. **URL Blocking**: Blocks telemetry and announcement URLs
4. **Media Handling**: v.redd.it video download fixes using FFmpegKit (due to Reddit changing their video formats)
5. **Custom Subreddit Sources**: External URL-based random/trending subreddit feeds
6. **Backup/Restore**: Settings backup via zip export with NSUserDefaults preservation
7. **FLEX Integration**: Debug tools

## Theos & Logos Conventions

- Use Logos directives (`%hook`, `%orig`, `%group`, `%ctor`) for runtime patches
- Use `%hookf` for C function hooks
- Register new source files in `Makefile` under `ApolloImprovedCustomApi_FILES`
- Keep related hooks grouped together

## Code Style

- **Indentation**: 4 spaces
- **Braces**: Same line as statement
- **Imports**: Explicit `#import` statements
- **Selectors**: Descriptive names (e.g., `fetchTrendingSubreddits:`)
- **Constants**: Uppercase with prefix (e.g., `UDKeyRedditClientId`)
- **ARC**: Enabled (`-fobjc-arc`), keep code ARC-safe
- **Logging**: Use `ApolloLog` for privacy-friendly diagnostics

## Testing

No automated test suite, must be validated manually.
