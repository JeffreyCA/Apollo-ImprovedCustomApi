#import <UIKit/UIKit.h>

// Full-screen live camera scanner for Apollo theme QR codes (the third import
// route, next to "From File…" and "From Photo…"). Present modally
// (UIModalPresentationFullScreen). Handles the camera-permission flow itself
// (Apollo's Info.plist already declares NSCameraUsageDescription) and shows a
// graceful alert when no camera is available (e.g. the Simulator).
@interface ApolloThemeQRScanViewController : UIViewController

// Called on the main thread, after the scanner has dismissed itself, with the
// already-decoded parsed-import dict (the -[ApolloThemeStore
// parseImportData:error:] shape — ready for importParsedTheme:). Not called on
// cancel, permission denial, or missing camera. Non-Apollo QR codes are
// silently ignored (scanning continues).
@property (nonatomic, copy) void (^onScan)(NSDictionary *parsed);

@end
