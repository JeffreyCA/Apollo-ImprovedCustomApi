#import "ApolloHiddenContentViewController.h"
#import "ApolloCommon.h"
#import <objc/runtime.h>

#pragma mark - Pill badge

// Plain UILabel cell accessory (not the Texture chip-image approach in
// ApolloDeletedCommentsUI.xm -- this is a plain UIKit table, no text node).
@interface ApolloHiddenContentPillLabel : UILabel
@end

@implementation ApolloHiddenContentPillLabel

- (instancetype)initWithText:(NSString *)text backgroundColor:(UIColor *)backgroundColor textColor:(UIColor *)textColor {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        self.text = text;
        self.font = [UIFont boldSystemFontOfSize:11.0];
        self.textColor = textColor;
        self.backgroundColor = backgroundColor;
        self.textAlignment = NSTextAlignmentCenter;
        self.layer.cornerRadius = 8.0;
        self.layer.masksToBounds = YES;
        [self sizeToFit];
        CGRect frame = self.frame;
        frame.size.width += 14.0;
        frame.size.height = 16.0;
        self.frame = frame;
    }
    return self;
}

- (void)drawTextInRect:(CGRect)rect {
    [super drawTextInRect:UIEdgeInsetsInsetRect(rect, UIEdgeInsetsMake(0, 7, 0, 7))];
}

@end

static UIColor *ApolloHiddenContentPillBackgroundColor(ApolloHiddenContentReason reason) {
    switch (reason) {
        case ApolloHiddenContentReasonDeleted: return [UIColor colorWithRed:1.0 green:0.66 blue:0.64 alpha:1.0];  // salmon, matches deleted-comments chip
        case ApolloHiddenContentReasonRemoved: return [UIColor colorWithRed:1.0 green:0.71 blue:0.42 alpha:1.0];  // orange, between hidden and deleted
        case ApolloHiddenContentReasonHidden: default: return [UIColor colorWithRed:1.0 green:0.84 blue:0.55 alpha:1.0]; // amber
    }
}

static UIColor *ApolloHiddenContentPillTextColor(ApolloHiddenContentReason reason) {
    switch (reason) {
        case ApolloHiddenContentReasonDeleted: return [UIColor colorWithRed:0.42 green:0.06 blue:0.06 alpha:1.0];
        case ApolloHiddenContentReasonRemoved: return [UIColor colorWithRed:0.42 green:0.18 blue:0.02 alpha:1.0];
        case ApolloHiddenContentReasonHidden: default: return [UIColor colorWithRed:0.42 green:0.24 blue:0.02 alpha:1.0];
    }
}

static NSString *ApolloHiddenContentPillLabelText(ApolloHiddenContentReason reason) {
    switch (reason) {
        case ApolloHiddenContentReasonDeleted: return @"DELETED";
        case ApolloHiddenContentReasonRemoved: return @"REMOVED";
        case ApolloHiddenContentReasonHidden: default: return @"HIDDEN";
    }
}

#pragma mark - Cell

@interface ApolloHiddenContentCell : UITableViewCell
@end

@implementation ApolloHiddenContentCell

- (void)configureWithItem:(ApolloHiddenContentItem *)item {
    // UIListContentConfiguration rather than the deprecated
    // textLabel/detailTextLabel pair -- it's iOS 14+, same as the device floor.
    UIListContentConfiguration *content = [self defaultContentConfiguration];
    NSString *preview = item.title.length > 0 ? item.title : item.body;
    content.text = preview.length > 0 ? preview : @"(no text)";
    content.textProperties.numberOfLines = 2;
    content.secondaryTextProperties.numberOfLines = 1;
    content.secondaryTextProperties.font = [UIFont systemFontOfSize:12.0];
    content.secondaryTextProperties.color = [UIColor secondaryLabelColor];

    // kind (Post/Comment) omitted -- redundant with the screen's own segmented control.
    NSMutableArray<NSString *> *subtitleParts = [NSMutableArray array];
    if (item.subreddit.length > 0) [subtitleParts addObject:[@"r/" stringByAppendingString:item.subreddit]];
    if (item.createdDate) {
        static NSDateFormatter *formatter;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            formatter = [NSDateFormatter new];
            formatter.dateStyle = NSDateFormatterMediumStyle;
            formatter.timeStyle = NSDateFormatterNoStyle;
        });
        [subtitleParts addObject:[formatter stringFromDate:item.createdDate]];
    }
    if (item.removalDetail.length > 0) [subtitleParts addObject:item.removalDetail];
    content.secondaryText = [subtitleParts componentsJoinedByString:@" · "];
    self.contentConfiguration = content;

    self.accessoryView = [[ApolloHiddenContentPillLabel alloc] initWithText:ApolloHiddenContentPillLabelText(item.reason)
                                                              backgroundColor:ApolloHiddenContentPillBackgroundColor(item.reason)
                                                                    textColor:ApolloHiddenContentPillTextColor(item.reason)];
}

@end

#pragma mark - Deleted/removed-item detail

// A deleted or removed item's live reddit.com page just shows Reddit's own
// tombstone ("[removed]"/"[deleted by user]"), not anything useful, so this
// shows the already-fetched archived title/body directly instead.
@interface ApolloHiddenContentDetailViewController : UIViewController
@property (nonatomic, strong) ApolloHiddenContentItem *item;
@end

@implementation ApolloHiddenContentDetailViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    BOOL isPost = self.item.kind == ApolloHiddenContentKindPost;
    self.title = self.item.reason == ApolloHiddenContentReasonRemoved
        ? (isPost ? @"Removed Post" : @"Removed Comment")
        : (isPost ? @"Deleted Post" : @"Deleted Comment");
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    UIBarButtonItem *shareItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                                                 target:self action:@selector(apollo_share)];
    UIBarButtonItem *arcticShiftItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"safari"]
                                                                          style:UIBarButtonItemStylePlain
                                                                         target:self action:@selector(apollo_openInArcticShift)];
    arcticShiftItem.accessibilityLabel = @"Open in Arctic Shift";
    self.navigationItem.rightBarButtonItems = @[shareItem, arcticShiftItem];

    UITextView *textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    textView.editable = NO;
    textView.font = [UIFont systemFontOfSize:16.0];
    textView.textContainerInset = UIEdgeInsetsMake(16.0, 16.0, 16.0, 16.0);
    textView.text = [self apollo_archivedText];
    [self.view addSubview:textView];
}

- (NSString *)apollo_archivedText {
    NSMutableString *text = [NSMutableString string];
    if (self.item.subreddit.length > 0) [text appendFormat:@"r/%@\n\n", self.item.subreddit];
    if (self.item.title.length > 0) [text appendFormat:@"%@\n\n", self.item.title];
    if (self.item.removalDetail.length > 0) {
        NSString *verb = self.item.reason == ApolloHiddenContentReasonDeleted ? @"Deleted by" : @"Removed by";
        [text appendFormat:@"%@: %@\n\n", verb, self.item.removalDetail];
    }
    [text appendString:self.item.body.length > 0 ? self.item.body : @"(no body text in the archive)"];
    return text;
}

- (void)apollo_share {
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[[self apollo_archivedText]]
                                                                             applicationActivities:nil];
    // iPad presents this as a popover, which crashes without an anchor.
    activity.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
    [self presentViewController:activity animated:YES completion:nil];
}

// Arctic Shift has no per-item permalink route -- it's a single-page search UI
// that auto-runs a search from ?fun=ids&ids=<fullname> in the URL, which is
// what "ID Lookup" does manually (confirmed against the site's bundled JS).
- (void)apollo_openInArcticShift {
    if (self.item.fullName.length == 0) return;
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://arctic-shift.photon-reddit.com/search"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"fun" value:@"ids"],
        [NSURLQueryItem queryItemWithName:@"ids" value:self.item.fullName],
    ];
    if (components.URL) [[UIApplication sharedApplication] openURL:components.URL options:@{} completionHandler:nil];
}

@end

#pragma mark - View controller

// Associated-object flag lives on the presenting profile screen, not this
// sheet -- the sheet is dismissed and deallocated. See the header doc on
// ApolloHiddenContentConsumePendingResume.
static void const *kApolloHiddenContentPendingResumeKey = &kApolloHiddenContentPendingResumeKey;

BOOL ApolloHiddenContentConsumePendingResume(UIViewController *profileViewController) {
    if (!profileViewController) return NO;
    NSNumber *pending = objc_getAssociatedObject(profileViewController, kApolloHiddenContentPendingResumeKey);
    if (!pending.boolValue) return NO;
    objc_setAssociatedObject(profileViewController, kApolloHiddenContentPendingResumeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

@interface ApolloHiddenContentViewController ()
@property (nonatomic, copy) NSString *username;
@property (nonatomic, assign) ApolloHiddenContentKind kind;
@property (nonatomic, copy) NSArray<ApolloHiddenContentItem *> *items;
@property (nonatomic, strong) UISegmentedControl *kindControl;
@property (nonatomic, strong) UIView *statusContainerView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *emptyStateLabel;
// The profile screen this sheet was presented from -- see didSelectRow.
@property (nonatomic, weak) UIViewController *presentingProfileViewController;
@end

@implementation ApolloHiddenContentViewController

+ (void)presentForUsername:(NSString *)username fromViewController:(UIViewController *)presenter {
    if (username.length == 0 || !presenter) return;
    ApolloHiddenContentViewController *sheet = [[ApolloHiddenContentViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    sheet.username = username;
    sheet.presentingProfileViewController = presenter;

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:sheet];
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sc = nav.sheetPresentationController;
        if (sc) {
            sc.detents = @[[UISheetPresentationControllerDetent mediumDetent], [UISheetPresentationControllerDetent largeDetent]];
            sc.prefersGrabberVisible = YES;
        }
    }
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [presenter presentViewController:nav animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Hidden & Deleted";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                                                             target:self action:@selector(apollo_close)];
    [self.tableView registerClass:[ApolloHiddenContentCell class] forCellReuseIdentifier:@"Cell"];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64.0;

    self.kind = ApolloHiddenContentKindPost;
    self.kindControl = [[UISegmentedControl alloc] initWithItems:@[@"Posts", @"Comments"]];
    self.kindControl.selectedSegmentIndex = 0;
    [self.kindControl addTarget:self action:@selector(apollo_kindChanged) forControlEvents:UIControlEventValueChanged];
    self.kindControl.frame = CGRectMake(0, 0, 220, 32);
    self.navigationItem.titleView = self.kindControl;

    UIRefreshControl *refreshControl = [UIRefreshControl new];
    [refreshControl addTarget:self action:@selector(apollo_refreshTriggered) forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = refreshControl;

    // tableView.backgroundView rather than a plain subview of self.view: it's a
    // fixed, non-scrolling layer UIKit keeps sized to the table view's bounds.
    self.statusContainerView = [[UIView alloc] initWithFrame:self.tableView.bounds];
    self.statusContainerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundView = self.statusContainerView;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    self.spinner.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin
        | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    self.spinner.center = CGPointMake(CGRectGetMidX(self.statusContainerView.bounds), CGRectGetMidY(self.statusContainerView.bounds));
    [self.statusContainerView addSubview:self.spinner];
    [self.spinner startAnimating];

    [self apollo_fetchForceRefresh:NO];
}

- (void)apollo_kindChanged {
    self.kind = self.kindControl.selectedSegmentIndex == 0 ? ApolloHiddenContentKindPost : ApolloHiddenContentKindComment;
    self.items = @[];
    [self.tableView reloadData];
    [self.emptyStateLabel removeFromSuperview];
    [self.spinner startAnimating];
    [self apollo_fetchForceRefresh:NO];
}

- (void)apollo_refreshTriggered {
    [self apollo_fetchForceRefresh:YES];
}

- (void)apollo_fetchForceRefresh:(BOOL)forceRefresh {
    [self.emptyStateLabel removeFromSuperview];
    ApolloHiddenContentKind requestedKind = self.kind;
    __weak __typeof(self) weakSelf = self;
    ApolloHiddenContentFetch(self.username, requestedKind, forceRefresh, ^(NSArray<ApolloHiddenContentItem *> *items, NSString *errorMessage) {
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        // The user may have flipped the segmented control again while this
        // request was in flight -- don't clobber a newer selection's UI state.
        if (strongSelf.kind != requestedKind) return;
        [strongSelf.spinner stopAnimating];
        [strongSelf.tableView.refreshControl endRefreshing];
        if (errorMessage) {
            [strongSelf apollo_showError:errorMessage];
            return;
        }
        strongSelf.items = items ?: @[];
        [strongSelf.tableView reloadData];
        if (strongSelf.items.count == 0) {
            [strongSelf apollo_showEmptyState];
        }
    });
}

- (void)apollo_close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

// Alert only -- deliberately does NOT dismiss the sheet, so a transient
// pull-to-refresh or segment-flip failure doesn't discard an already-loaded
// list. With nothing loaded, the status label below offers the retry path.
- (void)apollo_showError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Couldn't Fetch Hidden Content"
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
    if (self.items.count == 0) {
        [self apollo_showStatusText:@"Couldn't load results. Pull down to try again."];
    }
}

- (void)apollo_showStatusText:(NSString *)text {
    if (!self.emptyStateLabel) {
        self.emptyStateLabel = [[UILabel alloc] init];
        self.emptyStateLabel.numberOfLines = 0;
        self.emptyStateLabel.textAlignment = NSTextAlignmentCenter;
        self.emptyStateLabel.textColor = [UIColor secondaryLabelColor];
        self.emptyStateLabel.font = [UIFont systemFontOfSize:15.0];
        // Full-height inset frame + flexible width/height (UILabel centers its
        // text vertically), so the text re-flows on rotation instead of keeping
        // its creation-time width.
        self.emptyStateLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }
    self.emptyStateLabel.text = text;
    self.emptyStateLabel.frame = CGRectInset(self.statusContainerView.bounds, 32.0, 0);
    [self.statusContainerView addSubview:self.emptyStateLabel];
}

- (void)apollo_showEmptyState {
    NSString *kindName = self.kind == ApolloHiddenContentKindPost ? @"posts" : @"comments";
    [self apollo_showStatusText:[NSString stringWithFormat:@"No hidden or deleted %@ found in the archive for this account.", kindName]];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloHiddenContentCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell" forIndexPath:indexPath];
    [cell configureWithItem:self.items[indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    ApolloHiddenContentItem *item = self.items[indexPath.row];

    // Deleted and Removed items have no useful live reddit.com page (it's just
    // Reddit's own tombstone) -- show the archived copy instead. Only a
    // genuinely Hidden item (still fully intact, just excluded from the
    // account's own listing) is worth opening live.
    if (item.reason != ApolloHiddenContentReasonHidden) {
        ApolloHiddenContentDetailViewController *detail = [ApolloHiddenContentDetailViewController new];
        detail.item = item;
        [self.navigationController pushViewController:detail animated:YES];
        return;
    }

    // Route through the apollo:// scheme so it opens natively instead of
    // Safari. This screen is itself a modal sheet, so it dismisses first --
    // pushing while the sheet is still up would land the destination inside
    // the sheet's own nav stack instead of the app's normal one.
    if (item.permalink.length == 0) return;
    // NSURLComponents.path percent-encodes on assignment; +URLWithString: does
    // not, and silently returns nil for a permalink with unencoded non-ASCII
    // characters (e.g. an accented slug).
    NSURLComponents *urlComponents = [NSURLComponents new];
    urlComponents.scheme = @"https";
    urlComponents.host = @"www.reddit.com";
    urlComponents.path = item.permalink;
    NSURL *url = urlComponents.URL;
    if (!url) return;

    // Arm the pending flag *inside* the dismiss completion, not before calling
    // dismiss: dismissing this sheet reveals the profile (firing its own
    // -viewDidAppear:) before this completion block runs. Arming earlier means
    // that reveal immediately consumes the flag and re-presents the sheet
    // before the live post below is even pushed, so the post opens invisibly
    // behind it. Arming here means the flag is only seen the *next* time the
    // profile appears -- when the user backs out of the live post.
    __weak UIViewController *weakProfileVC = self.presentingProfileViewController;
    UINavigationController *presentingNav = self.navigationController;
    [presentingNav dismissViewControllerAnimated:YES completion:^{
        UIViewController *profileVC = weakProfileVC;
        if (profileVC) {
            objc_setAssociatedObject(profileVC, kApolloHiddenContentPendingResumeKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (!ApolloRouteResolvedURLViaApolloScheme(url)) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }
    }];
}

@end
