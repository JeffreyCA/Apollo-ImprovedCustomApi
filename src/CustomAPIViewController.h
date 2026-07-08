#import "ApolloSettingsTableViewController.h"
#import "ApolloState.h"

@interface CustomAPIViewController : ApolloSettingsTableViewController <UITextFieldDelegate, UITextViewDelegate, UIDocumentPickerDelegate> {
    BOOL _isRestoreOperation;
    // Snapshot of the derived state SectionAPIKeys renders from, so
    // -viewWillAppear can skip its section reload when nothing changed and
    // avoid the inset-grouped card flashing full-width during the push.
    NSString *_apollo_lastAPIKeysSignature;
}
@end

@interface ApolloBuyUsACoffeeViewController : ApolloSettingsTableViewController
@end
