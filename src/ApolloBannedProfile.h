#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

FOUNDATION_EXPORT NSString *ApolloBannedProfileMessageForUsername(NSString *username);
FOUNDATION_EXPORT NSString *ApolloBannedProfileBannedDescriptionText(void);
FOUNDATION_EXPORT UIImage *ApolloBannedProfileIconImage(void);
FOUNDATION_EXPORT BOOL ApolloBannedProfileCachedIsSuspended(NSString *username);
FOUNDATION_EXPORT void ApolloBannedProfileNoteListEndpoint403ForURL(NSURL *url);
FOUNDATION_EXPORT void ApolloBannedProfileClearListEndpoint403ForUsername(NSString *username);
FOUNDATION_EXPORT void ApolloBannedProfileClearDismissedOverlays(void);
FOUNDATION_EXPORT void ApolloBannedProfileRefreshViewController(UIViewController *viewController);
FOUNDATION_EXPORT void ApolloBannedProfileRefreshProfilesForUsername(NSString *username);
FOUNDATION_EXPORT void ApolloBannedProfileDecorateCommentCellIfNeeded(id cell);
FOUNDATION_EXPORT id ApolloBannedProfileWrapLinkButtonSpecWithBannedHint(id linkButtonNode, id nativeSpec, NSString *username);
FOUNDATION_EXPORT void ApolloBannedProfileRefreshLinkButtonsForUsername(NSString *username);
