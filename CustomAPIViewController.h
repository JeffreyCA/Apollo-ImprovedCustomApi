#import <UIKit/UIKit.h>

@interface CustomAPIViewController : UIViewController <UITextFieldDelegate, UIDocumentPickerDelegate> {
    BOOL _isRestoreOperation;
}
@end

NSString *sRedditClientId;
NSString *sImgurClientId;
NSString *sRandomSubredditsSource;
NSString *sRandNsfwSubredditsSource;
NSString *sTrendingSubredditsSource;
NSString *sTrendingSubredditsLimit;

BOOL sBlockAnnouncements;
