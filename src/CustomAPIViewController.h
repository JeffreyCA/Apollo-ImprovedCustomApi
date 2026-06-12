#import "ApolloSettingsTableViewController.h"
#import "ApolloState.h"

@interface CustomAPIViewController : ApolloSettingsTableViewController <UITextFieldDelegate, UITextViewDelegate, UIDocumentPickerDelegate> {
    BOOL _isRestoreOperation;
}
@end

@interface ApolloBuyUsACoffeeViewController : ApolloSettingsTableViewController
@end
