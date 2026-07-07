#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// Reborn gathers Apollo's native "Open Links in" (default browser) and "Open
// Videos in YouTube App" settings into its own "Open in App" screen
// (ApolloOpenInAppViewController), reached from Reborn's General settings. To
// avoid the same setting appearing in two places, we hide those two native rows
// from Apollo's own Settings → General ("Other" section).
//
// Apollo's General screen is a Eureka FormViewController
// (_TtC6Apollo29SettingsGeneralViewController). Rather than mutate the Swift Form
// or remap the table's row indices (which would desync Eureka's internal index
// from the displayed index and can crash when *other* "Other"-section rows update
// themselves by index), we take the low-blast-radius route: leave the rows in the
// form but collapse them to zero height and hide their cells. Eureka's model is
// untouched — only the two positively-identified target cells are affected; every
// other row and section is returned by %orig unchanged.
//
// The rows have no stable Eureka tag, so they're matched by exact cell title
// (RE-confirmed: "Open Links in" and "Open Videos in YouTube App").

static NSString *const kApolloHideTitleBrowser = @"Open Links in";
static NSString *const kApolloHideTitleYouTube = @"Open Videos in YouTube App";

static char kApolloHideTargetCellKey;

static BOOL ApolloHideIsTargetTitle(NSString *title) {
    if (![title isKindOfClass:[NSString class]]) return NO;
    NSString *trimmed = [title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return [trimmed isEqualToString:kApolloHideTitleBrowser]
        || [trimmed isEqualToString:kApolloHideTitleYouTube];
}

// Eureka rows use custom cells, so the title may live on a custom UILabel rather
// than the cell's standard textLabel. Scan the whole cell for a matching label.
static BOOL ApolloHideViewHasTargetTitle(UIView *view, int depth) {
    if ([view isKindOfClass:[UILabel class]] && ApolloHideIsTargetTitle(((UILabel *)view).text)) {
        return YES;
    }
    if (depth < 6) {
        for (UIView *sub in view.subviews) {
            if (ApolloHideViewHasTargetTitle(sub, depth + 1)) return YES;
        }
    }
    return NO;
}

static BOOL ApolloHideCellIsTarget(UITableViewCell *cell) {
    if (ApolloHideIsTargetTitle(cell.textLabel.text)) return YES;
    return ApolloHideViewHasTargetTitle(cell.contentView, 0);
}

%hook _TtC6Apollo29SettingsGeneralViewController

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = %orig;
    BOOL target = ApolloHideCellIsTarget(cell);
    // Tag the cell so heightForRow can recognize it without re-deriving the title.
    objc_setAssociatedObject(cell, &kApolloHideTargetCellKey, target ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (target) {
        cell.hidden = YES;
        cell.contentView.hidden = YES;
        cell.userInteractionEnabled = NO;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        // Push the separator off-screen so a 0-height row leaves no hairline.
        cell.separatorInset = UIEdgeInsetsMake(0.0, tableView.bounds.size.width + 100.0, 0.0, 0.0);
    }
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    // Eureka caches each row's cell, so asking for it here is cheap and lets us
    // collapse exactly the target rows to zero height. self is a forward-declared
    // Swift class, so cast to UITableViewController to send the data-source message.
    UITableViewCell *cell = [(UITableViewController *)self tableView:tableView cellForRowAtIndexPath:indexPath];
    if ([objc_getAssociatedObject(cell, &kApolloHideTargetCellKey) boolValue]) {
        return 0.0;
    }
    return %orig;
}

%end
