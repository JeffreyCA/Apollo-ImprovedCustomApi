#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString * const ApolloRichPreviewTranslationDidUpdateNotification;

BOOL ApolloRichPreviewTranslationShouldTranslateForNode(id node);
NSString *ApolloRichPreviewTranslatedTextIfAvailable(NSURL *url, NSString *field, NSString *sourceText, id ownerNode);

// Settles a vote-reconfigured comment/header cell's body back to its cached
// translation. Called by the vote-flicker module immediately before each of
// its synchronous display flushes, so a flush can never paint the
// untranslated text a vote's node rebuild briefly leaves behind. Exact-gate
// no-op when the body already shows the translation.
BOOL ApolloTranslationReapplySynchronouslyForVoteReconfigure(id cellNode);

// Preserves the exact on-screen translated comment body while Apollo replaces
// its Texture node during a vote. The returned opaque token must be removed
// with ApolloTranslationRemoveVoteBodyCover after the replacement settles.
id ApolloTranslationInstallVoteBodyCover(id cellNode);
void ApolloTranslationRemoveVoteBodyCover(id coverToken);
// Warms the same snapshot cache and briefly presents the identical cover so
// Core Animation commits its layer before a vote. Safe to call for every
// visible comment; it is an exact no-op outside translated mode or when this
// cell/fullname already has a ready cover.
void ApolloTranslationPrimeVoteBodySnapshot(id cellNode);
void ApolloTranslationDiscardVoteBodySnapshot(id cellNode);

// Maps the stored LibreTranslate URL setting to a usable endpoint: empty —
// or the dead libretranslate.de public instance the tweak defaulted to before
// it shut down (issue #995) — becomes the current default instance. Callers:
// %ctor settings load, backup-restore statics re-sync, settings screen.
// extern "C": defined in ApolloTranslation.xm (ObjC++) but also called from
// plain ObjC (.m) TUs, so it needs unmangled linkage.
__BEGIN_DECLS
NSString *ApolloNormalizedLibreTranslateURLSetting(NSString *stored);

// True when LibreTranslate cannot work as currently configured: the effective
// URL points at a keyed public instance and no API key is entered. Keyless
// self-hosted instances return NO. Shared by the request leg's fail-fast, the
// cross-provider fallback chooser, and the settings screen's key warning.
BOOL ApolloLibreTranslateNeedsAPIKey(void);
__END_DECLS

#if APOLLO_SIM_BUILD
// Sim debug-bridge probe (see ApolloSimDebugTap.xm): run `text` through a
// translation provider leg and ApolloLog the outcome, bypassing all UI/feed
// gating. `spec` is "<google|libre|auto> <text>"; auto = the user-selected
// provider with the normal cross-provider fallback.
void ApolloTranslationDebugProbe(NSString *spec);
#endif
