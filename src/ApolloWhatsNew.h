#import <Foundation/Foundation.h>

// Both declarations are defined in ApolloWhatsNew.xm (Objective-C++) but
// called from plain ObjC (.m) call sites (ApolloWhatsNewPresentForDebug from
// CustomAPIViewController.m) as well as from within the .xm itself — wrapped
// in extern "C" so both sides agree on the unmangled symbol name, matching
// the identical note on ApolloSanitizedHoldSpeed in ApolloState.h.
#ifdef __cplusplus
extern "C" {
#endif

// Presents the "What's New" sheet over the current top view controller if the
// running TWEAK_VERSION has curated content (whats-new/releases/*.json) the
// user hasn't seen yet. An absent seen-marker counts as unseen — it is
// indistinguishable between a fresh install and an upgrade from a build that
// predates this feature, and the upgrade case is the target audience (see the
// gating doc in ApolloWhatsNew.xm). Safe to call from any thread; hops to
// main itself. Idempotent once a presentation commits for the current version.
void ApolloWhatsNewPresentIfNeeded(void);

// TEMPORARY (dev/debug only): presents the sheet immediately on the main
// thread, ignoring UDKeyLastSeenWhatsNewVersion entirely — never touches it,
// so it's safe to call repeatedly. Falls back to the 3.5.0 catalog entry when
// the running TWEAK_VERSION has none of its own. Wired to a FLEX-gated debug
// row in CustomAPIViewController; remove both once the real gated flow has
// shipped and this is no longer needed for testing.
void ApolloWhatsNewPresentForDebug(void);

#ifdef __cplusplus
}
#endif
