#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Lean, hand-built UIKit sheets that replace the cramped UIAlertControllers the
// Theme Builder used for creating a theme, prompting the AI, and previewing the
// result. All three are presented modally from ApolloThemeBuilderViewController
// and call back into its existing flows via blocks — no theme logic is
// duplicated here. They are deliberately plain (system grouped backgrounds, an
// accent tint passed in by the presenter); no gradients.

// "New Theme" entry sheet: three creation cards (AI / manual / import).
@interface ApolloNewThemeSheetViewController : UIViewController
@property (nonatomic, strong, nullable) UIColor *accentColor;
@property (nonatomic, assign) BOOL aiAvailable; // hides the AI card when NO
@property (nonatomic, copy, nullable) void (^onGenerateAI)(void);
@property (nonatomic, copy, nullable) void (^onCreateManually)(void);
@property (nonatomic, copy, nullable) void (^onImport)(void);
@end

// AI prompt sheet: multi-line prompt field, suggestion chips that FILL the
// field (not auto-submit), a guardrails note, and Cancel / Generate.
@interface ApolloThemeGenerateSheetViewController : UIViewController
@property (nonatomic, strong, nullable) UIColor *accentColor;
@property (nonatomic, copy, nullable) NSString *initialPrompt;
@property (nonatomic, copy, nullable) void (^onGenerate)(NSString *prompt);
@end

// Lean result preview: name, description, swatch row, quality summary, and
// Use / Edit Manually / Regenerate plus up to three suggested-tweak buttons.
@interface ApolloThemeResultSheetViewController : UIViewController
@property (nonatomic, strong, nullable) UIColor *accentColor;
@property (nonatomic, copy) NSDictionary *result; // ApolloThemeAI result dict
@property (nonatomic, copy) NSString *mode;        // "light" / "dark"
@property (nonatomic, copy, nullable) void (^onUse)(void);
@property (nonatomic, copy, nullable) void (^onEdit)(void);
@property (nonatomic, copy, nullable) void (^onRegenerate)(void);
@property (nonatomic, copy, nullable) void (^onTweak)(NSString *instruction);
@end

NS_ASSUME_NONNULL_END
