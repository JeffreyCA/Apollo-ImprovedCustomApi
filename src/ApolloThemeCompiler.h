#import "ApolloThemeTokens.h"

// ApolloThemeCompiler — turns a small editable theme input into a complete
// semantic token table for both appearance modes (spec §7).
//
// The compiler is the only place colour derivation lives: text tiers,
// separators, fills, selection, placeholder and disabled are all *derived* from
// the five (optionally eight) user colours, with contrast repair applied so a
// careless palette still renders readably. It is pure Foundation/UIKit logic —
// no Logos, no Apollo internals — so it can be exercised in isolation.

__BEGIN_DECLS

// An immutable compiled palette: every token resolved for light and dark.
@interface ApolloCompiledTheme : NSObject

// Compile a theme `input` dict (the v2 schema's "input" object: keys "light"
// and "dark", each a dict of input colour keys -> "RRGGBB" string or NSNull /
// missing for unset advanced overrides) into a full token table.
//
// `input` may be partial or invalid; the compiler validates every hex, fills
// missing advanced overrides, and never returns nil — a wholly-empty input
// yields a sane neutral palette.
//
// `advancedEnabled` gates the three optional overrides (text/mutedText/
// separator): when NO they are ignored even if present in `input` and those
// tokens are auto-derived instead. The Store never deletes a stored override
// when the user turns Advanced off — the theme dict keeps its `input` intact,
// only the flag flips — so toggling Advanced back on restores exactly what
// was there before, without the compiler ever seeing stale hidden values in
// the meantime.
+ (instancetype)compiledThemeWithInput:(NSDictionary *)input
                               variant:(ApolloThemeVariant)variant
                       advancedEnabled:(BOOL)advancedEnabled;

// Resolved 0xRRGGBB for a token in a mode. Out-of-range -> 0.
- (uint32_t)rgbForToken:(ApolloThemeToken)token mode:(ApolloThemeMode)mode;

// Token table as a {"light":{tokenKey:hex,...},"dark":{...}} dict — for the
// debug compiled-cache and the spec's §5.3 representation.
- (NSDictionary *)tokenDictionary;

@end

// Generate the opposite appearance mode's input colours from one mode's, by
// inverting luminance while preserving hue/saturation — backs the editor's
// "Generate dark from light" / "Generate light from dark" actions (spec §4.3).
// `srcMode` is the populated mode; returns a fresh single-mode input dict
// (input colour keys -> "RRGGBB"), advanced overrides included only if present
// in the source.
NSDictionary<NSString *, NSString *> *
ApolloThemeGenerateOppositeModeInput(NSDictionary<NSString *, NSString *> *source,
                                     ApolloThemeMode srcMode);

__END_DECLS
