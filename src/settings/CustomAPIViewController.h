#import "settings/ApolloSettingsForm.h"
#import "ApolloState.h"

// Root "Apollo Reborn" settings screen (Data, API Keys, General, Apollo AI,
// Rich Link Previews, Media, Subreddits, Notification Backend, About).
// Declarative form — see -buildForm. The API-key/source text fields keep the
// tag-based UITextFieldDelegate machinery (index-immune by design), wrapped in
// custom rows.
@interface CustomAPIViewController : ApolloSettingsFormViewController <UITextFieldDelegate, UITextViewDelegate, UIDocumentPickerDelegate> {
    BOOL _isRestoreOperation;
}
@end
