#import "ApolloThemeTokens.h"

// ApolloThemeRuntime — the runtime seam (spec §8–§12).
//
// Consumes a compiled token table and serves it to Apollo as cached *dynamic*
// UIColors via two clean seams:
//   1. donor-constant swap: Apollo's hardcoded outrun role constants (the
//      private runtime probe) are mapped to semantic tokens on the UIColor
//      constructor hot path;
//   2. semantic UIKit accessor override: +[UIColor secondarySystemBackground...]
//      etc. return the corresponding token.
// Both return cached dynamic colours so light/dark resolves natively with no
// currentTraitCollection guessing and no per-frame allocation.
//
// The runtime is deliberately small and deterministic: it knows nothing about
// prompts, editor state, or variant generation — only the compiled light/dark
// token table the Store + Compiler hand it, plus a recovered table of the
// stock Apollo themes' accents (served through ApolloThemeAccentColor for
// tweak-drawn UI when no custom theme is active).

__BEGIN_DECLS

// YES while a custom theme is active and the table is compiled.
BOOL ApolloThemeRuntimeIsActive(void);

// Cached dynamic colour for a token, or nil if inactive / out of range.
UIColor *ApolloThemeRuntimeColor(ApolloThemeToken token);

// The EFFECTIVE accent for tweak-drawn UI: the custom theme's accent when one
// is active, else the stock Apollo theme's (from a table recovered from the
// binary's accent switch). nil only if neither can be determined — callers
// supply their own last-resort (typically a view tint or systemBlue).
UIColor *ApolloThemeAccentColor(void);

// The EFFECTIVE card/cell background for tweak-drawn UI: the custom theme's
// card color when one is active, else the stock theme's (Pure Black Dark
// Mode aware). nil only if neither can be determined — callers supply their
// own last-resort (typically secondarySystemGroupedBackgroundColor).
UIColor *ApolloThemeCardBackgroundColor(void);

// Re-derive a caller-provided system font in the active theme's system design.
// Returns `base` unchanged when the theme runtime is inactive or the active
// theme uses the default system font.
UIFont *ApolloThemeRuntimeFont(UIFont *base);

// Mark a text control whose font the tweak sets DELIBERATELY in a specific
// design (the theme editor's font-picker tiles and preview rows): the font
// sink hooks and the live font-refresh walk leave pinned views untouched.
void ApolloThemeRuntimeSetFontPinned(id view, BOOL pinned);

// Walk the app's windows and re-derive system-design fonts on Apollo-owned
// labels / text fields / text views (plus vetted nav/tab-bar chrome) into the
// active theme's font — the live-update path after a font change. Also runs
// as part of ApolloThemeRuntimeInvalidate. Main thread only.
void ApolloThemeRuntimeRefreshFonts(void);

// Monotonic counter bumped whenever the compiled token table or the
// enabled/disabled state changes (reload/enable/disable). ApolloThemeRuntimeColor
// itself always allocates a fresh dynamic-provider colour (a shared/cached
// instance over-releases at certain UIKit cell-prep call sites — see the
// Runtime's implementation comment), so callers that want to skip redundant
// re-application of an unchanged colour (e.g. on every layoutSubviews pass)
// should cache this epoch alongside their own applied state instead of
// comparing UIColor pointers, which are never equal across calls.
uint64_t ApolloThemeRuntimeEpoch(void);

// Recompile from the Store's active theme and rebuild the runtime tables.
// Honours the enabled flag and the crash kill-switch. Call after any edit.
void ApolloThemeRuntimeReload(void);

// Enable: save the user's current Apollo theme, hijack the donor slot, compile,
// activate, and repaint — no relaunch needed (spec §8.2).
void ApolloThemeRuntimeEnable(void);
// Disable: restore the previously-selected Apollo theme and clear tables (§8.3).
void ApolloThemeRuntimeDisable(void);

// Repaint visible UI after activation/edit via Apollo's own theme-change
// notifications (plus the legacy window-style flip while the fallback is on).
void ApolloThemeRuntimeInvalidate(void);

// Legacy repaint fallback (window-style flip). Default ON for one release while
// the native-notification path is validated (spec §12.2).
BOOL ApolloThemeRuntimeUseLegacyRepaintFallback(void);
void ApolloThemeRuntimeSetLegacyRepaintFallback(BOOL on);

// Debug instrumentation (spec §17). Off by default.
void ApolloThemeRuntimeSetDebugLogging(BOOL on);
BOOL ApolloThemeRuntimeDebugLogging(void);

__END_DECLS
