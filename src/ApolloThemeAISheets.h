#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Lean, hand-built UIKit sheets for creating a theme, prompting the AI, and
// previewing the result. Presented modally from ApolloThemeManagerViewController
// and call back into its flows via blocks — no theme logic is duplicated here.
// They are deliberately plain (system grouped backgrounds, an accent tint
// passed in by the presenter); no gradients.

// AI prompt sheet: multi-line prompt field, suggestion chips that FILL the
// field (not auto-submit), a guardrails note, and Cancel / Generate.
@interface ApolloThemeGenerateSheetViewController : UIViewController
@property (nonatomic, strong, nullable) UIColor *accentColor;
@property (nonatomic, copy, nullable) NSString *initialPrompt;
@property (nonatomic, copy, nullable) void (^onGenerate)(NSString *prompt);
@end

// Result cards — one per intensity tier (Subtle / Balanced / Bold), each with
// name, description, and a swatch row of the engine-derived palette. Below
// them, a fixed set of generic refinement chips (applied to the theme's seed
// colours) and Use / Edit Manually / Regenerate actions operate on whichever
// card is currently selected.
@interface ApolloThemeVariantSetSheetViewController : UIViewController
@property (nonatomic, strong, nullable) UIColor *accentColor;
@property (nonatomic, copy) NSDictionary *themeSet; // ApolloThemeAI generation-set dict
@property (nonatomic, copy) NSString *mode;         // "light" / "dark" — which mode's swatches to preview
// Pre-selected card ("subtle"/"balanced"/"bold"); nil = balanced. Refine passes
// the previous selection through so it survives the rebuild.
@property (nonatomic, copy, nullable) NSString *initialSelectedIntensity;
@property (nonatomic, copy, nullable) void (^onUse)(NSString *selectedIntensity);
@property (nonatomic, copy, nullable) void (^onEdit)(NSString *selectedIntensity);
@property (nonatomic, copy, nullable) void (^onRegenerate)(void);
@property (nonatomic, copy, nullable) void (^onRefine)(NSString *selectedIntensity, NSString *instruction);
@end

NS_ASSUME_NONNULL_END
