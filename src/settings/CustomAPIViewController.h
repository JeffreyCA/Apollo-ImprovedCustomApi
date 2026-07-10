#import "settings/ApolloSettingsForm.h"
#import "ApolloState.h"

// Root "Apollo Reborn" settings hub (Setup / Features / Data / Advanced /
// Privacy / About — the settings IA restructure). Declarative form — see
// -buildForm. The API-key/source text fields keep the tag-based
// UITextFieldDelegate machinery (index-immune by design), wrapped in custom
// rows. The group screens below are thin subclasses that override -buildForm
// with their slice of the hub's sections; every row action, cell builder and
// footer inherits from this class, so a row keeps one implementation no
// matter which screen it renders on.
@interface CustomAPIViewController : ApolloSettingsFormViewController <UITextFieldDelegate, UITextViewDelegate, UIDocumentPickerDelegate> {
    BOOL _isRestoreOperation;
}
@end

@interface ApolloAccountsAPIKeysViewController : CustomAPIViewController  // Setup → Accounts & API Keys
@end

@interface ApolloPostsFeedsViewController : CustomAPIViewController       // Features → Posts & Feeds
@end

@interface ApolloCommentsSettingsViewController : CustomAPIViewController // Features → Comments
@end

@interface ApolloMediaSettingsViewController : CustomAPIViewController    // Features → Media
@end

@interface ApolloSubredditsSettingsViewController : CustomAPIViewController // Features → Subreddits
@end

@interface ApolloProfilesSettingsViewController : CustomAPIViewController // Features → Profiles
@end

@interface ApolloInterfaceSettingsViewController : CustomAPIViewController // Features → Interface
@end

@interface ApolloNotificationBackendViewController : CustomAPIViewController // Advanced → Notification Backend
@end
