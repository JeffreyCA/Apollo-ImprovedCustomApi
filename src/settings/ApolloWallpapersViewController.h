#import <UIKit/UIKit.h>

// Hosted Goodbye Apollo wallpaper collections. Images stay off-device until
// the user chooses a device and opens the viewer.
@interface ApolloWallpapersViewController : NSObject

// Original Apollo-style device chooser used by the native Settings row.
+ (void)presentDevicePickerFromViewController:(UIViewController *)presenter
                                   sourceView:(UIView *)sourceView;

@end
