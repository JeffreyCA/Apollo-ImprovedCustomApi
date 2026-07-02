#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^ApolloThemeAICompletion)(NSDictionary *_Nullable result, NSError *_Nullable error);

// ApolloThemeAI — the AI half of theme generation. The model is asked exactly
// ONE thing (the three colours most iconic to the prompt: accent + two surface
// tones, as plain "three hex codes" text); everything else — surface
// hierarchy, light/dark staging, intensity tiers, contrast guarantees — is
// computed deterministically by ApolloThemePaletteEngine. This split exists
// because the on-device model reliably recalls iconic colours but reliably
// fails at composing readable UI palettes (three separate palette-generation
// designs failed before this one).

// True when the Swift FoundationModels bridge is present and the device is
// capable of running the model (iOS 26+, eligible hardware). Deliberately
// does NOT require the model to report ready: on iOS 27 the availability API
// misreports "Apple Intelligence not enabled" to sideloaded apps even when
// generation works, so the only trustworthy gate is attempting a request and
// surfacing its real error. Use ApolloThemeAIUnavailableMessage() for
// friendly copy when this is false.
BOOL ApolloThemeAIIsAvailable(void);
NSString *ApolloThemeAIUnavailableMessage(void);

// Pre-build + prewarm the model session the next generation will use. Call
// when the prompt UI opens — session setup then overlaps the user's typing
// instead of delaying the first visible token. Cheap and idempotent.
void ApolloThemeAIPrewarm(void);

// Generates a theme GENERATION SET from a prompt:
// {
//   originalPrompt, name, shortDescription,
//   seeds: { accent, primary, secondary },   // "RRGGBB" — the model's only output
//   allowMonochrome: @YES/@NO,               // inferred from the prompt's wording
//   rawModelOutput,                          // the model's literal reply, for debugging
//   themeJSON,                               // serialized seeds (refine round-trips, storage)
//   variants: [                              // one per intensity, engine-derived
//     { intensity ("subtle"/"balanced"/"bold"), name, shortDescription,
//       colors (flat "inputKey.mode" -> hex, both modes) },
//   ]
// }
//
// The reply is parsed defensively (any three hex codes in order, with
// deterministic repair when fewer parse) and retried once on a fully
// unparseable reply before failing.
void ApolloThemeAIGenerateThemeSet(NSString *prompt, ApolloThemeAICompletion completion);

// Adjusts the SEEDS of an existing generation set with `instruction` (free
// text, e.g. "shift the palette toward warmer tones"), then rebuilds all
// variants through the engine. `selectedIntensity` is accepted for UI
// symmetry but doesn't change the request — every intensity is rebuilt from
// the refined seeds.
void ApolloThemeAIRefineThemeSet(NSDictionary *themeSet,
                                 NSString *_Nullable selectedIntensity,
                                 NSString *instruction,
                                 ApolloThemeAICompletion completion);

void ApolloThemeAICancel(void);

// YES when `error` is the bridge's user-cancellation sentinel (fires after
// ApolloThemeAICancel). Callers must swallow it silently — the user asked for
// the cancel; an error alert on top of it is noise.
BOOL ApolloThemeAIErrorIsCancellation(NSError *_Nullable error);

NS_ASSUME_NONNULL_END
