#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^ApolloThemeAICompletion)(NSDictionary *_Nullable result, NSError *_Nullable error);

// True when the Swift FoundationModels bridge is present and reports a model
// ready to generate. UI can still call ApolloThemeAIUnavailableMessage() for
// friendly copy when this is false.
BOOL ApolloThemeAIIsAvailable(void);
NSString *ApolloThemeAIUnavailableMessage(void);

// Generates an app-safe theme dictionary:
// {
//   name, shortDescription, colors, qualityLabel, qualitySummary,
//   notes, suggestedTweaks, validationScore, originalPrompt
// }
void ApolloThemeAIGenerateTheme(NSString *prompt, ApolloThemeAICompletion completion);
void ApolloThemeAIModifyTheme(NSDictionary *themeResult, NSString *instruction, ApolloThemeAICompletion completion);
void ApolloThemeAICancel(void);

// Lightweight deterministic validation used by both AI output and the manual
// editor. Returns {score, passed, issues, warnings, summary}.
NSDictionary *ApolloThemeAIValidateColors(NSDictionary<NSString *, NSString *> *colors, NSString *_Nullable prompt);

NS_ASSUME_NONNULL_END
