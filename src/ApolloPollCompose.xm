// Native poll creation: adds a "Poll" post type to Apollo's compose sheet.
//
// Apollo's ComposePostViewController drives its Link/Text/Image types from a
// UISegmentedControl (postTypeSegmentedControl ivar). Polls never existed in
// the official API, so instead of teaching Apollo's Swift table layout a new
// postType, we append a "Poll" segment and, when it's selected, snap the
// control back and present our own composer on top. The poll is submitted the
// way new.reddit.com does it — POST /api/submit_poll_post.json with the
// account's harvested web-session cookie + modhash (the same per-username
// session ApolloPollVoting.xm votes with; OAuth accounts harvest one on first
// use via the existing login flow).
#import "ApolloCommon.h"
#import "ApolloAccountCredentials.h"
#import "ApolloWebSessionLoginViewController.h"
#import "ApolloWebSessionStore.h"
#import "ApolloThemeRuntime.h"
#import "Defaults.h"
#import "UIWindow+Apollo.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>

static NSString *const kApolloPollSubmitEndpoint = @"https://www.reddit.com/api/submit_poll_post.json";
static const NSUInteger kApolloPollMinOptions = 2;
static const NSUInteger kApolloPollMaxOptions = 6;
static const NSInteger kApolloPollDefaultDurationDays = 3;

static const void *kApolloPollSegmentIndexKey = &kApolloPollSegmentIndexKey;
static const void *kApolloPollLastSegmentKey = &kApolloPollLastSegmentKey;
static const void *kApolloPollComposerKey = &kApolloPollComposerKey;

static id ApolloPollComposeIvar(id object, const char *name) {
    if (!object) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

// Decode a Swift String stored inline as a two-word struct ivar (Swift stored
// properties have no ObjC getter). Small strings (≤15 UTF-8 bytes) decode from
// the packed words; everything else goes through Swift's own
// String._bridgeToObjectiveC, the same technique ApolloNativeActionMenus.xm's
// ApolloDecodeSwiftString uses.
static NSString *ApolloPollComposeSwiftStringIvar(id object, const char *name) {
    if (!object) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    if (!ivar) return nil;
    uint64_t words[2] = {0, 0};
    memcpy(words, (const uint8_t *)(__bridge const void *)object + ivar_getOffset(ivar), sizeof(words));
    if (words[1] == 0) return nil;
    uint8_t discriminator = (uint8_t)(words[1] >> 56);
    if (discriminator >= 0xE0 && discriminator <= 0xEF) {
        NSUInteger count = discriminator - 0xE0;
        if (count == 0) return @"";
        char bytes[16] = {0};
        memcpy(bytes, &words[0], 8);
        uint64_t highClean = words[1] & 0x00FFFFFFFFFFFFFFULL;
        memcpy(bytes + 8, &highClean, 7);
        return [[NSString alloc] initWithBytes:bytes length:count encoding:NSUTF8StringEncoding];
    }
    typedef NSString *(*BridgeFn)(uint64_t, uint64_t);
    static BridgeFn sBridge = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sBridge = (BridgeFn)dlsym(RTLD_DEFAULT, "$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF");
    });
    return sBridge ? sBridge(words[0], words[1]) : nil;
}

// The subreddit the compose sheet is posting to. Prefer the RDKSubreddit
// object; fall back to the Swift subredditName string (set even when Apollo
// was handed just a name).
static NSString *ApolloPollComposeSubredditName(id composeVC) {
    id subreddit = ApolloPollComposeIvar(composeVC, "subreddit");
    if ([subreddit respondsToSelector:@selector(name)]) {
        NSString *name = ((NSString *(*)(id, SEL))objc_msgSend)(subreddit, @selector(name));
        if ([name isKindOfClass:NSString.class] && name.length > 0) return name;
    }
    return ApolloPollComposeSwiftStringIvar(composeVC, "subredditName");
}

// The account the sheet will post as: the compose account switcher's temporary
// pick when set, otherwise the app's active account.
static NSString *ApolloPollComposeUsername(id composeVC) {
    id account = ApolloPollComposeIvar(composeVC, "temporaryPostingAccount");
    for (NSString *key in @[ @"username", @"name" ]) {
        if (![account respondsToSelector:NSSelectorFromString(key)]) continue;
        NSString *name = [account valueForKey:key];
        if ([name isKindOfClass:NSString.class] && name.length > 0) return name;
    }
    return ApolloActiveAccountUsername();
}

#pragma mark - Quick post-type menu ("Submit Post" replacement)

// Post type picked from the subreddit "..." menu, applied to the compose
// sheet's segmented control when it appears. Time-limited so a compose sheet
// opened later through another path doesn't inherit a stale pick.
static NSString *sApolloPollPendingPostType = nil;
static CFAbsoluteTime sApolloPollPendingPostTypeSetAt = 0;

static void ApolloPollComposeSetPendingPostType(NSString *type) {
    sApolloPollPendingPostType = [type copy];
    sApolloPollPendingPostTypeSetAt = CFAbsoluteTimeGetCurrent();
}

static void ApolloPollComposeApplyPendingPostType(id composeVC) {
    NSString *pending = sApolloPollPendingPostType;
    sApolloPollPendingPostType = nil;
    if (pending.length == 0 || CFAbsoluteTimeGetCurrent() - sApolloPollPendingPostTypeSetAt > 30.0) return;
    UISegmentedControl *control = ApolloPollComposeIvar(composeVC, "postTypeSegmentedControl");
    if (![control isKindOfClass:UISegmentedControl.class]) return;

    // Match the picked type against the compose sheet's segment titles
    // case-insensitively, and treat "Photo"/"Image" as synonyms. Apollo titles
    // its image segment "Photo" (confirmed against the binary), but matching by
    // exact display string is fragile: a rebrand or future build could relabel
    // it "Image", and the quick-pick must still land on the right segment
    // instead of silently opening compose on the default type.
    NSString *wanted = pending.lowercaseString;
    NSArray<NSString *> *accepted =
        ([wanted isEqualToString:@"photo"] || [wanted isEqualToString:@"image"]) ? @[@"photo", @"image"]
                                                                                 : @[wanted];
    for (NSInteger index = 0; index < control.numberOfSegments; index++) {
        NSString *segTitle = [control titleForSegmentAtIndex:index].lowercaseString;
        if (segTitle.length == 0 || ![accepted containsObject:segTitle]) continue;
        if (control.selectedSegmentIndex != index) {
            control.selectedSegmentIndex = index;
            // Fires Apollo's own postTypeSegmentedControlValueChanged: (and,
            // for Poll, this file's hook) exactly as a user tap would.
            [control sendActionsForControlEvents:UIControlEventValueChanged];
        }
        return;
    }
    // No segment matched — leave the sheet on its default type rather than
    // guessing an index, but surface the miss so a title/label drift can't fail
    // silently the way it would with a bare exact-string match.
    ApolloLog(@"[PollCompose] quick-pick '%@' matched no compose segment title — left default type", pending);
}

static UIViewController *ApolloPollComposeVisibleViewController(void) {
    for (UIWindow *window in ApolloAllWindows()) if (window.isKeyWindow) return window.visibleViewController;
    return ApolloAllWindows().firstObject.visibleViewController;
}

// Loads one of the tweak's bundled custom post-type symbols. These are SF
// Symbols custom-symbol exports compiled into ApolloPollSymbols.bundle
// (Assets.car), staged inside ApolloReborn.bundle. Resolved once and cached;
// returns nil when the bundle is unavailable so callers fall back to a stock
// SF Symbol.
static UIImage *ApolloPollComposeSymbol(NSString *symbolName) {
    static NSBundle *symbols = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = ApolloBundledResourcePath(@"ApolloPollSymbols", @"bundle");
        symbols = path ? [NSBundle bundleWithPath:path] : nil;
        if (!symbols) ApolloLog(@"[PollCompose] ApolloPollSymbols.bundle not found — using SF Symbol fallbacks");
    });
    return symbols ? [UIImage imageNamed:symbolName inBundle:symbols compatibleWithTraitCollection:nil] : nil;
}

// The ControlGroup-style inline icon row that replaces the "Submit Post" menu
// item: one entry per post type the current subreddit accepts
// (RDKSubmissionType: Any=1, Link=2, Self=3 — RedditKit's transformer defaults
// missing to Any), each landing directly on that type in the compose sheet.
// RDK predates polls, so there is no allow_polls flag to check — Poll shows
// for any signed-in account and the server's error surfaces if a sub
// disallows them (same as the compose sheet's Poll segment).
//
// The whole picker is gated on the experimental Polls feature: with Polls off,
// this returns nil so Apollo's plain "Submit Post" row is left exactly as-is.
// The Photo/Link/Text speed-up isn't poll-specific, but shipping it to every
// install would be a stock-behavior change outside the feature flag, so it
// rides the Polls gate rather than silently replacing the default row.
UIMenu *ApolloSubmitPostTypesMenu(__unused id actionController, void (^selectRow)(void)) {
    if (!ApolloPollsFeatureEnabled()) return nil;
    id subreddit = ApolloPollComposeIvar(ApolloPollComposeVisibleViewController(), "currentSubreddit");
    NSInteger submissionType = 1;
    BOOL allowImages = YES;
    if ([subreddit respondsToSelector:@selector(acceptedSubmissionsType)]) {
        submissionType = ((NSInteger (*)(id, SEL))objc_msgSend)(subreddit, @selector(acceptedSubmissionsType));
        if (submissionType < 1 || submissionType > 3) submissionType = 1;
    }
    if ([subreddit respondsToSelector:@selector(allowImagePosts)]) {
        allowImages = ((BOOL (*)(id, SEL))objc_msgSend)(subreddit, @selector(allowImagePosts));
    }
    BOOL linkAllowed = submissionType != 3;
    BOOL textAllowed = submissionType != 2;
    // Custom SF Symbols (…badge.plus) ship in ApolloPollSymbols.bundle; each
    // falls back to a stock SF Symbol if the bundle can't be loaded.
    struct { NSString *title; NSString *customSymbol; NSString *fallback; BOOL available; } entries[] = {
        { @"Photo", @"custom.photo.badge.plus",                         @"photo",          linkAllowed && allowImages },
        { @"Link",  @"custom.link.badge.plus",                          @"link",           linkAllowed },
        { @"Text",  @"custom.text.page.badge.plus",                     @"text.alignleft", textAllowed },
        // Feature gate already passed above; Poll just needs a signed-in account.
        { @"Poll",  @"custom.chart.bar.horizontal.page.fill.badge.plus", @"chart.bar",     ApolloActiveAccountUsername().length > 0 },
    };
    UIImageSymbolConfiguration *iconConfig =
        [UIImageSymbolConfiguration configurationWithPointSize:22.0 weight:UIImageSymbolWeightRegular];
    UIAction *(^makeAction)(NSString *, NSString *, NSString *) = ^(NSString *title, NSString *custom, NSString *fallback) {
        UIImage *image = ApolloPollComposeSymbol(custom) ?: [UIImage systemImageNamed:fallback];
        image = [[image imageByApplyingSymbolConfiguration:iconConfig]
                    imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        return [UIAction actionWithTitle:title image:image
                              identifier:nil handler:^(__unused UIAction *action) {
            ApolloPollComposeSetPendingPostType(title);
            selectRow();
        }];
    };
    NSMutableArray<UIAction *> *nativeActions = [NSMutableArray array];
    for (size_t i = 0; i < 3; i++) {
        if (entries[i].available) [nativeActions addObject:makeAction(entries[i].title, entries[i].customSymbol, entries[i].fallback)];
    }
    UIAction *pollAction = entries[3].available ? makeAction(entries[3].title, entries[3].customSymbol, entries[3].fallback) : nil;
    if (nativeActions.count + (pollAction ? 1 : 0) < 2) return nil;

    // Small elements keep all four post types on one clean, compact icon row
    // (no labels, no vertical bulk). Medium was worse: it shows labels and only
    // fits three per row, dropping Poll onto a lopsided second row. The custom
    // badge-plus glyphs read clearly at this size, so the row stays legible
    // while staying a single native UIMenu (keyboard/VoiceOver come free).
    NSMutableArray<UIAction *> *actions = [nativeActions mutableCopy];
    if (pollAction) [actions addObject:pollAction];
    UIMenu *iconRow = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                                    options:UIMenuOptionsDisplayInline children:actions];
    if (@available(iOS 16.0, *)) {
        iconRow.preferredElementSize = UIMenuElementSizeSmall;
    }
    return [UIMenu menuWithTitle:@"" image:nil identifier:nil
                         options:UIMenuOptionsDisplayInline children:@[iconRow]];
}

#pragma mark - Poll composer

@interface ApolloPollComposeViewController : UITableViewController <UITextFieldDelegate>
@property (nonatomic, weak) UIViewController *composeHost;
@property (nonatomic, copy) NSString *originalComposeTitle;
@property (nonatomic, strong) UIColor *composeBackgroundColor;
@property (nonatomic, strong) UIColor *composeCellColor;
@property (nonatomic, strong) UIColor *composePrimaryTextColor;
@property (nonatomic, strong) UIColor *composeSecondaryTextColor;
@property (nonatomic, strong) UIBarButtonItem *originalPostButton;
@property (nonatomic, strong) UIBarButtonItem *pollPostButton;
@property (nonatomic, copy) NSString *subredditName;
@property (nonatomic, copy) NSString *username;
@property (nonatomic, strong) NSMutableArray<NSString *> *optionTexts;
@property (nonatomic, copy) NSString *titleText;
@property (nonatomic) NSInteger durationDays;
@property (nonatomic) BOOL submitting;
@end

@implementation ApolloPollComposeViewController

- (UINavigationItem *)activeNavigationItem {
    return self.composeHost.navigationItem ?: self.navigationItem;
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _optionTexts = [NSMutableArray arrayWithObjects:@"", @"", nil];
        _titleText = @"";
        _durationDays = kApolloPollDefaultDurationDays;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UINavigationItem *item = self.activeNavigationItem;
    self.originalPostButton = item.rightBarButtonItem;
    self.pollPostButton = [[UIBarButtonItem alloc]
        initWithTitle:@"Post" style:UIBarButtonItemStyleDone target:self action:@selector(postTapped)];
    item.rightBarButtonItem = self.pollPostButton;
    UIColor *accent = ApolloThemeAccentColor();
    if (accent) self.navigationController.navigationBar.tintColor = accent;
    self.tableView.backgroundColor = self.composeBackgroundColor ?: self.composeHost.view.backgroundColor;
    [self revalidate];
}

- (NSArray<NSString *> *)filledOptions {
    NSMutableArray *filled = [NSMutableArray array];
    for (NSString *text in self.optionTexts) {
        NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length > 0) [filled addObject:trimmed];
    }
    return filled;
}

- (void)revalidate {
    NSString *title = [self.titleText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    self.pollPostButton.enabled =
        !self.submitting && title.length > 0 && self.filledOptions.count >= kApolloPollMinOptions;
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    if (section == 1) return self.optionTexts.count + (self.optionTexts.count < kApolloPollMaxOptions ? 1 : 0);
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"Title";
    if (section == 1) return @"Options";
    return @"Duration";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1) return @"2 to 6 options. Empty ones are skipped.";
    if (section == 2) return @"Voting closes this many days after posting.";
    return nil;
}

- (UITextField *)textFieldForCell:(UITableViewCell *)cell {
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectZero];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.delegate = self;
    field.returnKeyType = UIReturnKeyNext;
    field.textColor = self.composePrimaryTextColor;
    [field addTarget:self action:@selector(textFieldChanged:) forControlEvents:UIControlEventEditingChanged];
    [cell.contentView addSubview:field];
    [NSLayoutConstraint activateConstraints:@[
        [field.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
        [field.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
        [field.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor],
        [field.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor],
        [field.heightAnchor constraintGreaterThanOrEqualToConstant:44.0],
    ]];
    return field;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    UIColor *card = self.composeCellColor;
    if (card) {
        cell.backgroundColor = card;
        cell.contentView.backgroundColor = card;
    }
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (indexPath.section == 0) {
        UITextField *field = [self textFieldForCell:cell];
        field.placeholder = @"Poll title";
        field.text = self.titleText;
        field.tag = -1;
    } else if (indexPath.section == 1) {
        if ((NSUInteger)indexPath.row < self.optionTexts.count) {
            UITextField *field = [self textFieldForCell:cell];
            field.placeholder = [NSString stringWithFormat:@"Option %ld", (long)indexPath.row + 1];
            field.text = self.optionTexts[indexPath.row];
            field.tag = indexPath.row;
        } else {
            cell.textLabel.text = @"Add Option";
            cell.textLabel.textColor = ApolloThemeAccentColor() ?: cell.textLabel.tintColor;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
    } else {
        cell.textLabel.text = @"Poll Duration";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld %@", (long)self.durationDays,
                                     self.durationDays == 1 ? @"Day" : @"Days"];
        UIStepper *stepper = [[UIStepper alloc] init];
        stepper.minimumValue = 1;
        stepper.maximumValue = 7;
        stepper.value = self.durationDays;
        [stepper addTarget:self action:@selector(durationChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = stepper;
    }
    cell.textLabel.textColor = self.composePrimaryTextColor;
    cell.detailTextLabel.textColor = self.composeSecondaryTextColor;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1 || (NSUInteger)indexPath.row != self.optionTexts.count) return;
    [self.optionTexts addObject:@""];
    // Reload the section rather than inserting: the "Add Option" row also moves
    // (or disappears at the 6-option cap), and these tiny tables reload cheaply.
    [tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)textFieldChanged:(UITextField *)field {
    if (field.tag == -1) {
        self.titleText = field.text ?: @"";
    } else if (field.tag >= 0 && (NSUInteger)field.tag < self.optionTexts.count) {
        self.optionTexts[field.tag] = field.text ?: @"";
    }
    [self revalidate];
}

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    [field resignFirstResponder];
    return YES;
}

- (void)durationChanged:(UIStepper *)stepper {
    self.durationDays = (NSInteger)stepper.value;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark Submission

- (void)showError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Couldn't Create Poll"
        message:message ?: @"Reddit rejected the poll." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)setSubmitting:(BOOL)submitting {
    _submitting = submitting;
    UISegmentedControl *segments = ApolloPollComposeIvar(self.composeHost, "postTypeSegmentedControl");
    segments.enabled = !submitting;
    if (submitting) {
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
            initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        self.activeNavigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:spinner];
    } else {
        self.activeNavigationItem.rightBarButtonItem = self.pollPostButton;
    }
    [self revalidate];
}

- (void)postTapped {
    if (self.submitting) return;
    [self.view endEditing:YES];
    NSString *title = [self.titleText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray<NSString *> *options = self.filledOptions;
    NSMutableSet *uniqueOptions = [NSMutableSet set];
    for (NSString *option in options) [uniqueOptions addObject:option.lowercaseString];
    if (title.length > 300) { [self showError:@"Poll titles can be at most 300 characters."]; return; }
    if (options.count < 2 || options.count > 6) { [self showError:@"Polls require 2 to 6 options."]; return; }
    if (uniqueOptions.count != options.count) { [self showError:@"Each poll option must be different."]; return; }
    for (NSString *option in options) {
        if (option.length > 120) { [self showError:@"Poll options can be at most 120 characters."]; return; }
    }
    NSString *currentUsername = ApolloPollComposeUsername(self.composeHost);
    if (currentUsername.length == 0) { [self showError:@"Choose an account before posting."]; return; }
    self.username = currentUsername;
    self.submitting = YES;
    ApolloWebSessionEntry *session = ApolloWebSessionPollFor(self.username);
    if (session.cookieHeader.length > 0) { [self submitWithSession:session]; return; }

    // OAuth account without a harvested reddit.com session yet: run the same
    // one-time cookie login the poll-voting flow uses, then submit.
    ApolloWebSessionLoginViewController *login = [ApolloWebSessionLoginViewController
        loginControllerForUsername:self.username completion:^(BOOL success) {
            if (!success) { self.submitting = NO; return; }
            ApolloWebSessionEntry *harvested = ApolloWebSessionPollFor(self.username);
            if (harvested.cookieHeader.length > 0) {
                [self submitWithSession:harvested];
            } else {
                self.submitting = NO;
                [self showError:@"A Reddit web session is required to create polls."];
            }
        }];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:login];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)submitWithSession:(ApolloWebSessionEntry *)session {
    if (session.modhash.length == 0) {
        self.submitting = NO;
        [self showError:@"The stored Reddit session has no modhash. Sign in again from the account switcher and retry."];
        return;
    }
    NSDictionary *body = @{ @"sr": self.subredditName ?: @"",
                            @"title": [self.titleText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet],
                            @"text": @"",
                            @"options": self.filledOptions,
                            @"duration": @(self.durationDays),
                            @"api_type": @"json",
                            @"kind": @"poll",
                            @"resubmit": @YES,
                            @"sendreplies": @YES };
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kApolloPollSubmitEndpoint]];
    request.HTTPMethod = @"POST";
    NSError *serializationError = nil;
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&serializationError];
    if (!request.HTTPBody) {
        self.submitting = NO;
        ApolloLog(@"[PollCompose] submit failed stage=serialization");
        [self showError:serializationError.localizedDescription ?: @"Apollo could not prepare the poll."];
        return;
    }
    request.HTTPShouldHandleCookies = NO;
    request.timeoutInterval = 30.0;
    [request setValue:session.cookieHeader forHTTPHeaderField:@"Cookie"];
    [request setValue:session.modhash forHTTPHeaderField:@"X-Modhash"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:defaultUserAgent forHTTPHeaderField:@"User-Agent"];

    NSURLSession *urlSession = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    [[urlSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.submitting = NO;
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
            id jsonObject = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSDictionary *json = [jsonObject isKindOfClass:NSDictionary.class] ? jsonObject : nil;
            id errorsObject = [json valueForKeyPath:@"json.errors"];
            NSArray *errors = [errorsObject isKindOfClass:NSArray.class] ? errorsObject : @[];
            id postURLObject = [json valueForKeyPath:@"json.data.url"];
            NSString *postURL = [postURLObject isKindOfClass:NSString.class] ? postURLObject : nil;
            if (error || status != 200 || errors.count > 0 || postURL.length == 0) {
                // api_type=json errors are [code, human message, field] triples.
                NSString *serverMessage = nil;
                id first = errors.firstObject;
                if ([first isKindOfClass:NSArray.class] && [first count] > 1 && [first[1] isKindOfClass:NSString.class]) serverMessage = first[1];
                NSString *message = serverMessage ?: error.localizedDescription;
                if (status == 429) message = @"Reddit is rate limiting posts. Wait a moment before trying again.";
                else if (status == 401) {
                    // Only a 401 is a definite authentication failure — remove the
                    // stored session so the user is prompted to sign in again.
                    ApolloWebSessionRemove(self.username);
                    message = @"The Reddit web session expired. Sign in again and retry.";
                }
                else if (status == 403) {
                    // A 403 from /api/submit_poll_post.json is very reachable
                    // without the session being bad: the subreddit disallows
                    // polls, the user is banned/muted, lacks the karma to post,
                    // or the subreddit is restricted. Do NOT remove the session —
                    // for a keyless account this is its primary API-key-free
                    // transport, and ApolloWebSessionRemove would sign it out of
                    // the whole cookie transport, not just polls. Mirror
                    // ApolloPollVoting.xm's 403 handling and surface Reddit's own
                    // reason instead.
                    message = serverMessage ?: @"Reddit did not authorize this poll. You may not be allowed to post polls in this subreddit.";
                }
                else if (status >= 500) message = @"Reddit is temporarily unavailable. Try again later.";
                ApolloLog(@"[PollCompose] submit failed status=%ld code=%ld", (long)status, (long)error.code);
                [self showError:message ?: (status > 0 ? [NSString stringWithFormat:@"Reddit returned HTTP %ld.", (long)status] : @"Reddit could not be reached.")];
                return;
            }
            UINotificationFeedbackGenerator *feedback = [UINotificationFeedbackGenerator new];
            [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
            [self openCreatedPoll:postURL];
        });
        [urlSession finishTasksAndInvalidate];
    }] resume];
}

- (void)openCreatedPoll:(NSString *)postURL {
    // Reddit commonly returns a www.reddit.com URL.  Hand-building an
    // apollo://www.reddit.com URL bypasses Apollo's native Reddit host route
    // and falls into its web viewer.  Use the shared router, which canonicalizes
    // Reddit hosts and invokes Apollo's deep-link handler in-process.
    NSURL *createdURL = [NSURL URLWithString:postURL];
    // Apollo predates Reddit's internal community names (r/a:t5_*).  Its URL
    // handler accepts the route but then opens those subreddit-qualified URLs
    // in the web viewer.  A post's canonical /comments/<id> route is equivalent
    // and does not require Apollo to resolve the community namespace.
    NSArray<NSString *> *components = createdURL.pathComponents;
    NSUInteger commentsIndex = [components indexOfObject:@"comments"];
    NSURL *nativeURL = createdURL;
    if (commentsIndex != NSNotFound && commentsIndex + 1 < components.count) {
        NSString *postID = components[commentsIndex + 1];
        if (postID.length > 0) {
            nativeURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://reddit.com/comments/%@", postID]];
        }
    }
    UIViewController *root = self.composeHost.presentingViewController ?: self.presentingViewController;
    [root dismissViewControllerAnimated:YES completion:^{
        BOOL routed = nativeURL && ApolloRouteResolvedURLViaApolloScheme(nativeURL);
        if (!routed) {
            ApolloLog(@"[PollCompose] native route failed after successful creation");
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Poll Created"
                message:@"The poll was created, but Apollo could not open it."
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [root presentViewController:alert animated:YES completion:nil];
        }
    }];
}

@end

#pragma mark - Compose sheet hook

static void ApolloPollComposePresentComposer(UIViewController *composeVC) {
    NSString *subredditName = ApolloPollComposeSubredditName(composeVC);
    NSString *username = ApolloPollComposeUsername(composeVC);
    if (subredditName.length == 0 || username.length == 0) return;
    ApolloPollComposeViewController *existing = objc_getAssociatedObject(composeVC, kApolloPollComposerKey);
    if (existing) {
        existing.view.hidden = NO;
        composeVC.navigationItem.rightBarButtonItem = existing.pollPostButton;
        composeVC.navigationItem.title = @"Poll";
        [existing revalidate];
        return;
    }
    ApolloPollComposeViewController *composer = [ApolloPollComposeViewController new];
    composer.subredditName = subredditName;
    composer.username = username;
    composer.composeHost = composeVC;
    composer.originalComposeTitle = composeVC.navigationItem.title ?: composeVC.title;
    composeVC.navigationItem.title = @"Poll";
    UITableView *nativeTable = ApolloPollComposeIvar(composeVC, "tableView");
    UITableViewCell *nativeCell = [nativeTable.visibleCells firstObject];
    // Use the same semantic surface roles that the settings controllers use,
    // rather than sampling the presenting controller.  The latter is the
    // dimmed sheet's white host view, hence the white poll editor on a dark or
    // custom Apollo theme.  Runtime colours are dynamic, so live light/dark
    // and custom-theme changes continue to resolve correctly.
    UIColor *page = ApolloThemeRuntimeColor(ApolloThemeTokenBackground);
    UIColor *card = ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryBackground);
    composer.composeBackgroundColor = page ?: nativeTable.backgroundColor
        ?: composeVC.view.backgroundColor ?: UIColor.systemGroupedBackgroundColor;
    composer.composeCellColor = card ?: nativeCell.backgroundColor
        ?: UIColor.secondarySystemGroupedBackgroundColor;
    composer.composePrimaryTextColor = nativeCell.textLabel.textColor ?: UIColor.labelColor;
    composer.composeSecondaryTextColor = nativeCell.detailTextLabel.textColor
        ?: [composer.composePrimaryTextColor colorWithAlphaComponent:0.62];

    objc_setAssociatedObject(composeVC, kApolloPollComposerKey, composer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Keep Apollo's post-type segmented control visible and replace only the
    // content beneath it. Poll is therefore a genuine peer mode: selecting
    // Text/Link/Photo again immediately uncovers Apollo's original content.
    [composeVC addChildViewController:composer];
    UIView *view = composer.view;
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [composeVC.view addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [view.leadingAnchor constraintEqualToAnchor:composeVC.view.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor:composeVC.view.trailingAnchor],
        [view.topAnchor constraintEqualToAnchor:((UIView *)ApolloPollComposeIvar(composeVC, "postTypeSegmentedControl")).bottomAnchor constant:8.0],
        [view.bottomAnchor constraintEqualToAnchor:composeVC.view.bottomAnchor],
    ]];
    [composer didMoveToParentViewController:composeVC];
}

static void ApolloPollComposeHideComposer(UIViewController *composeVC) {
    ApolloPollComposeViewController *composer = objc_getAssociatedObject(composeVC, kApolloPollComposerKey);
    if (!composer || composer.view.hidden) return;
    [composer.view endEditing:YES];
    composer.view.hidden = YES;
    if (composer.originalPostButton) {
        composeVC.navigationItem.rightBarButtonItem = composer.originalPostButton;
    }
    composeVC.navigationItem.title = composer.originalComposeTitle;
}

// The segmented control is built after viewDidLoad/viewWillAppear (it's still
// nil there), so install from viewDidAppear: — idempotent via the "Poll" title
// check so re-appearances are no-ops.
static void ApolloPollComposeInstallSegment(id composeVC) {
    if (!ApolloPollsFeatureEnabled()) return;
    UISegmentedControl *control = ApolloPollComposeIvar(composeVC, "postTypeSegmentedControl");
    if (![control isKindOfClass:UISegmentedControl.class] || control.numberOfSegments == 0) {
        return;
    }
    if ([[control titleForSegmentAtIndex:control.numberOfSegments - 1] isEqualToString:@"Poll"]) return;
    // Profile posts and other targets without a resolvable subreddit keep the
    // stock sheet. Signed-out browsing has no account to post as.
    NSString *subredditName = ApolloPollComposeSubredditName(composeVC);
    NSString *username = ApolloPollComposeUsername(composeVC);
    if (subredditName.length == 0 || username.length == 0) return;
    [control insertSegmentWithTitle:@"Poll" atIndex:control.numberOfSegments animated:NO];
    objc_setAssociatedObject(composeVC, kApolloPollSegmentIndexKey,
                             @(control.numberOfSegments - 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(composeVC, kApolloPollLastSegmentKey,
                             @(control.selectedSegmentIndex), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%hook _TtC6Apollo25ComposePostViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloPollComposeInstallSegment(self);
    // After the Poll segment exists, so a "Poll" quick-pick can land on it.
    ApolloPollComposeApplyPendingPostType(self);
}

- (void)postTypeSegmentedControlValueChanged:(UISegmentedControl *)sender {
    NSNumber *pollIndex = objc_getAssociatedObject(self, kApolloPollSegmentIndexKey);
    if (pollIndex && sender.selectedSegmentIndex == pollIndex.integerValue) {
        // Do not forward the synthetic enum case into Apollo's Swift switch;
        // leave Poll selected and show our content below the shared control.
        ApolloPollComposePresentComposer((UIViewController *)self);
        return;
    }
    ApolloPollComposeHideComposer((UIViewController *)self);
    objc_setAssociatedObject(self, kApolloPollLastSegmentKey,
                             @(sender.selectedSegmentIndex), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
}

%end

%ctor {}
