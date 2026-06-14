#import <UIKit/UIKit.h>

@interface ApolloSettingsTableViewController : UITableViewController
- (UITableView *)apollo_sourceThemeTableView;
- (UIColor *)apollo_themeCellBackgroundColor;
- (UIColor *)apollo_themeAccentColor;
- (void)apollo_applyAccentActionTextColorToCell:(UITableViewCell *)cell;
- (void)apollo_applyThemeToCell:(UITableViewCell *)cell;
- (void)apollo_applyTheme;
@end

@interface ApolloFooterLinkTextView : UITextView
@end
