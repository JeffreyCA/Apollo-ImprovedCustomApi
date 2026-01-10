#import <UIKit/UIKit.h>

@interface CustomAPIViewController : UIViewController <UITextFieldDelegate, UIDocumentPickerDelegate> {
    BOOL _isRestoreOperation;
}
@end

NSString *sRedditClientId;
NSString *sImgurClientId;
NSString *sRedirectURI;
NSString *sUserAgent;
NSString *sRandomSubredditsSource;
NSString *sRandNsfwSubredditsSource;
NSString *sTrendingSubredditsSource;
NSString *sTrendingSubredditsLimit;

BOOL sBlockAnnouncements;
