#import <UIKit/UIKit.h>

// ApolloThemeManagerViewController — the v2 Theme Manager UI (spec §13).
//
// Two roles in one class:
//   * list mode (default init): enable switch, theme list, new/import/export.
//   * editor mode (initEditorForThemeID:): name, variant, light/dark colours,
//     advanced overrides, live preview, apply.
@interface ApolloThemeManagerViewController : UITableViewController

- (instancetype)initEditorForThemeID:(NSString *)themeID;

@end
