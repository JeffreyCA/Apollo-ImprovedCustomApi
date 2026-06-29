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
// prompts, editor state, theme names, or variant generation — only the compiled
// light/dark token table the Store + Compiler hand it.

__BEGIN_DECLS

// YES while a custom theme is active and the table is compiled.
BOOL ApolloThemeRuntimeIsActive(void);

// Cached dynamic colour for a token, or nil if inactive / out of range.
UIColor *ApolloThemeRuntimeColor(ApolloThemeToken token);

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
