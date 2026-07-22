#import "ApolloSettingsForm.h"

// "Translation" sub-screen pushed from the tweak settings: the bulk
// translation master switch (Auto Translate and Translate Post Titles grey
// out while it's off), Target Language and Primary Provider pickers, the
// Don't Translate skip-language list (add via action sheet; remove via tap,
// trash button, or swipe), and the LibreTranslate endpoint text fields.
// Declarative form — see -buildForm; the skip section is rebuilt via
// -rebuildForm whenever a language is added or removed.
@interface TranslationSettingsViewController : ApolloSettingsFormViewController <UITextFieldDelegate>
@end
