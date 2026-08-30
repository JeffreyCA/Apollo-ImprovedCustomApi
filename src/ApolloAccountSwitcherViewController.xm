#import "ApolloAccountSwitcherViewController.h"
#import "ApolloAccountCredentials.h"
#import "ApolloWebSessionStore.h"
#import "ApolloWebSessionLoginViewController.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
#import "ApolloCommon.h"
#import "UserDefaultConstants.h"
#import "ApolloUserProfileCache.h"
#import <objc/message.h>
#import <objc/runtime.h>

// Feature flag: if a future Apollo build changes the native
// AccountManagerViewController's ObjC selector surface and driving it starts
// misbehaving, flipping this default to NO in a hotfix restores Apollo's
// stock switcher without removing any of this file.
static NSString *const UDKeyUseCustomAccountSwitcher = @"UseCustomAccountSwitcher";

static NSString *const kApolloGroupSuite = @"group.com.christianselig.apollo";

#pragma mark - Reading Apollo's account list (read-only; see ApolloWebJSONIdentity.xm
// for the canonical documentation of this two-blob format, which this file
// only reads from, never writes to directly)

// Non-secure top-level unarchive — RDKClient/AFNetworking's object graph is
// arbitrary, so secure coding with a fixed class list isn't practical here.
static id ApolloSwitcherUnarchive(NSData *data) {
    if (![data isKindOfClass:[NSData class]]) return nil;
    NSError *e = nil;
    NSKeyedUnarchiver *u = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&e];
    if (!u) return nil;
    u.requiresSecureCoding = NO;
    id obj = nil;
    @try { obj = [u decodeTopLevelObjectForKey:NSKeyedArchiveRootObjectKey error:&e]; }
    @catch (__unused NSException *ex) { obj = nil; }
    [u finishDecoding];
    return obj;
}

#pragma mark - Avatars (mirrors the standalone pattern in ApolloModeratorAvatars.xm —
// ApolloUserProfileCache + a plain UIImage render, no ASDK dependency)

static const CGFloat kApolloSwitcherAvatarDiameter = 32.0;
static const void *kApolloSwitcherAvatarUsernameKey = &kApolloSwitcherAvatarUsernameKey;
static const void *kApolloSwitcherEditButtonUsernameKey = &kApolloSwitcherEditButtonUsernameKey;

// Oval-clipped, aspect-fill render at `diameter`. Nil source -> neutral placeholder.
static UIImage *ApolloSwitcherCircularImage(UIImage *sourceImage, CGFloat diameter) {
    CGSize size = CGSizeMake(diameter, diameter);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = [UIScreen mainScreen].scale;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect rect = CGRectMake(0.0, 0.0, diameter, diameter);
        [[UIBezierPath bezierPathWithOvalInRect:rect] addClip];
        if (sourceImage) {
            CGFloat aspect = sourceImage.size.width > 0 ? sourceImage.size.height / sourceImage.size.width : 1.0;
            CGFloat w = diameter, h = diameter;
            if (aspect > 1.0) { w = diameter; h = diameter * aspect; }
            else if (aspect > 0.0) { w = diameter / aspect; h = diameter; }
            [sourceImage drawInRect:CGRectMake((diameter - w) / 2.0, (diameter - h) / 2.0, w, h)];
        } else {
            [[UIColor secondarySystemFillColor] setFill];
            UIRectFill(rect);
        }
    }];
}

static void ApolloSwitcherApplyAvatarToCell(UITableViewCell *cell, NSString *username) {
    if (username.length == 0) return;
    objc_setAssociatedObject(cell, kApolloSwitcherAvatarUsernameKey, username, OBJC_ASSOCIATION_COPY_NONATOMIC);
    cell.imageView.image = ApolloSwitcherCircularImage(nil, kApolloSwitcherAvatarDiameter);

    ApolloUserProfileCache *cache = [ApolloUserProfileCache sharedCache];
    __weak UITableViewCell *weakCell = cell;
    [cache requestInfoForUsername:username completion:^(ApolloUserProfileInfo *info) {
        UITableViewCell *c1 = weakCell;
        if (!c1 || ![objc_getAssociatedObject(c1, kApolloSwitcherAvatarUsernameKey) isEqualToString:username]) return;

        NSURL *imageURL = info.iconURL ?: info.snoovatarURL;
        if (!imageURL) return; // no avatar available — keep neutral placeholder

        [cache requestImageForURL:imageURL completion:^(UIImage *image) {
            if (!image) return;
            UIImage *circular = ApolloSwitcherCircularImage(image, kApolloSwitcherAvatarDiameter);
            dispatch_async(dispatch_get_main_queue(), ^{
                UITableViewCell *c2 = weakCell;
                if (!c2 || ![objc_getAssociatedObject(c2, kApolloSwitcherAvatarUsernameKey) isEqualToString:username]) return;
                c2.imageView.image = circular;
                [c2 setNeedsLayout];
            });
        }];
    }];
}

// One row's worth of display data.
@interface ApolloSwitcherAccountRow : NSObject
@property (nonatomic, copy) NSString *username;
@property (nonatomic) BOOL isActive;
@property (nonatomic, copy) NSString *keyStatusText;
// YES if this account signs in via a harvested web session (cookie) rather
// than an OAuth API key. Auth modes are mutually exclusive per account — see
// ApolloWebSessionStore.h — so this and an OAuth key-status badge never both
// apply to the same row.
@property (nonatomic) BOOL isWebSession;
@end
@implementation ApolloSwitcherAccountRow @end

// Broaden UIKit's narrow reorder target and reload only after its drag finishes.
@interface ApolloSwitcherAccountCell : UITableViewCell
@property (nonatomic, copy) void (^reorderDragDidEnd)(void);
@property (nonatomic) BOOL observedReorderDrag;
@end

@implementation ApolloSwitcherAccountCell

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (!self.isEditing || !self.showsReorderControl ||
        [hitView isKindOfClass:[UIControl class]]) return hitView;

    // Forward the trailing 52-point band to whatever UIKit exposes at the
    // center of its reorder handle, without naming or moving private views.
    BOOL rightToLeft = self.effectiveUserInterfaceLayoutDirection ==
        UIUserInterfaceLayoutDirectionRightToLeft;
    CGRect band = self.bounds;
    band.size.width = MIN(52.0, CGRectGetWidth(band));
    if (!rightToLeft) {
        band.origin.x = CGRectGetMaxX(self.bounds) - CGRectGetWidth(band);
    }
    if (!CGRectContainsPoint(band, point)) return hitView;

    CGPoint handlePoint = CGPointMake(rightToLeft ? 20.0 : CGRectGetWidth(self.bounds) - 20.0,
                                      CGRectGetMidY(self.bounds));
    UIView *reorderControl = [super hitTest:handlePoint withEvent:event];
    while (reorderControl && reorderControl != self &&
           ![reorderControl isKindOfClass:[UIControl class]]) {
        reorderControl = reorderControl.superview;
    }
    return [reorderControl isKindOfClass:[UIControl class]] ? reorderControl : hitView;
}

- (void)dragStateDidChange:(UITableViewCellDragState)dragState {
    [super dragStateDidChange:dragState];
    BOOL ended = self.observedReorderDrag && dragState == UITableViewCellDragStateNone;
    self.observedReorderDrag = dragState != UITableViewCellDragStateNone;
    if (ended && self.reorderDragDidEnd) self.reorderDragDidEnd();
}

@end

static NSArray<ApolloSwitcherAccountRow *> *ApolloSwitcherLoadAccountRows(void) {
    NSUserDefaults *group = [[NSUserDefaults alloc] initWithSuiteName:kApolloGroupSuite];
    id accounts = ApolloSwitcherUnarchive([group objectForKey:@"RedditAccounts2"]);
    if (![accounts isKindOfClass:[NSArray class]]) return @[];

    NSInteger activeIndex = [group objectForKey:@"CurrentRedditAccountIndex"] ? [group integerForKey:@"CurrentRedditAccountIndex"] : -1;
    NSMutableArray<ApolloSwitcherAccountRow *> *rows = [NSMutableArray array];

    [(NSArray *)accounts enumerateObjectsUsingBlock:^(id client, NSUInteger idx, BOOL *stop) {
        NSString *username = nil;
        @try {
            id user = [client valueForKey:@"currentUser"];
            id name = user ? [user valueForKey:@"username"] : nil;
            if ([name isKindOfClass:[NSString class]]) username = name;
        } @catch (__unused NSException *e) { /* not our object shape — skip */ }
        if (username.length == 0) username = [NSString stringWithFormat:@"(account %lu)", (unsigned long)idx + 1];

        ApolloSwitcherAccountRow *row = [ApolloSwitcherAccountRow new];
        row.username = username;
        row.isActive = ((NSInteger)idx == activeIndex);

        // Auth modes are mutually exclusive per account: an account is EITHER a
        // web-session (cookie) account OR an OAuth account, chosen at "Add
        // Account" time. Check the web-session store first since it's a simple
        // presence test, with no OAuth divergence logic to run for these rows.
        if (ApolloWebSessionFor(username) != nil) {
            row.isWebSession = YES;
            // Deliberately short — the subtitle shares the row with the
            // checkmark + ellipsis accessories and truncates past ~20 chars.
            row.keyStatusText = @"API-key-free";
            [rows addObject:row];
            return;
        }

        // Every account gets auto-pinned to whatever the default was at sign-in
        // time (see ApolloPinAccountToCurrentDefaultCredentialsIfNeeded in
        // ApolloUserAvatars.xm), so a stored entry alone doesn't mean "custom" —
        // most accounts' pinned values are identical to the current default
        // until that default changes. Only flag "Custom key" once the stored
        // entry actually diverges from the live default for some field.
        ApolloAccountCredentialEntry *entry = ApolloAccountCredentialsFor(username);
        BOOL divergesFromDefault = entry != nil && (
            ![ (entry.clientId ?: @"") isEqualToString:(sRedditClientId ?: @"") ]
            || ![ (entry.clientSecret ?: @"") isEqualToString:(sRedditClientSecret ?: @"") ]
            || ![ (entry.redirectURI ?: @"") isEqualToString:(sRedirectURI ?: @"") ]
        );
        if (divergesFromDefault) {
            row.keyStatusText = @"API key · custom";
        } else if (sRedditClientId.length > 0) {
            row.keyStatusText = @"API key · default";
        } else {
            row.keyStatusText = @"No API key set";
        }
        [rows addObject:row];
    }];
    return rows;
}

#pragma mark - Per-account credential editor form

// Small standalone form: Reddit API Key / Secret / Redirect URI for one
// account. Kept self-contained here (rather than reusing
// CustomAPIViewController's private cell builders) since it's a much smaller
// surface — three text fields and an optional "Clear" row.
@interface ApolloAccountCredentialEditorViewController : UITableViewController <UITextFieldDelegate>
@property (nonatomic, strong) ApolloAccountCredentialEntry *entry;
@property (nonatomic, copy) void (^onSave)(NSString *clientId, NSString *secret, NSString *redirectURI);
@property (nonatomic, copy, nullable) void (^onClear)(void);
@end

@implementation ApolloAccountCredentialEditorViewController {
    UITextField *_clientIdField;
    UITextField *_secretField;
    UITextField *_redirectField;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self action:@selector(saveTapped:)];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return self.onClear ? 2 : 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 3 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 0 ? @"Leave a field blank to fall back to the default API key set in Settings." : nil;
}

- (UITextField *)makeFieldWithPlaceholder:(NSString *)placeholder text:(NSString *)text secure:(BOOL)secure {
    UITextField *field = [[UITextField alloc] init];
    field.placeholder = placeholder;
    field.text = text;
    field.secureTextEntry = secure;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.delegate = self;
    field.borderStyle = UITextBorderStyleNone;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    return field;
}

// Stacked layout (caption label above, full-width field below) rather than
// the standard textLabel+accessoryView row — "Reddit API Secret" plus a
// reasonably long value doesn't fit on one line at this sheet's width.
- (UITableViewCell *)stackedCellWithCaption:(NSString *)caption field:(UITextField *)field {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UILabel *label = [[UILabel alloc] init];
    label.text = caption;
    label.font = [UIFont systemFontOfSize:12];
    label.textColor = [UIColor secondaryLabelColor];
    label.translatesAutoresizingMaskIntoConstraints = NO;

    [cell.contentView addSubview:label];
    [cell.contentView addSubview:field];
    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.topAnchor],
        [label.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
        [label.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],

        [field.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:4],
        [field.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
        [field.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
        [field.bottomAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.bottomAnchor],
    ]];
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 1) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = @"Clear Custom Key for This Account";
        cell.textLabel.textColor = [UIColor systemRedColor];
        return cell;
    }

    switch (indexPath.row) {
        case 0:
            if (!_clientIdField) _clientIdField = [self makeFieldWithPlaceholder:@"Default" text:self.entry.clientId secure:YES];
            return [self stackedCellWithCaption:@"Reddit API Key" field:_clientIdField];
        case 1:
            if (!_secretField) _secretField = [self makeFieldWithPlaceholder:@"Required for \"Web app\" clients" text:self.entry.clientSecret secure:YES];
            return [self stackedCellWithCaption:@"Reddit API Secret" field:_secretField];
        default:
            if (!_redirectField) _redirectField = [self makeFieldWithPlaceholder:@"Default" text:self.entry.redirectURI secure:NO];
            return [self stackedCellWithCaption:@"Redirect URI" field:_redirectField];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1 && self.onClear) {
        self.onClear();
        [self.navigationController popViewControllerAnimated:YES];
    }
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    if (textField == _clientIdField || textField == _secretField) {
        textField.secureTextEntry = NO;
    }
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (textField == _clientIdField || textField == _secretField) {
        textField.secureTextEntry = YES;
    }
}

- (void)saveTapped:(id)sender {
    [self.view endEditing:YES];
    self.onSave(_clientIdField.text ?: @"", _secretField.text ?: @"", _redirectField.text ?: @"");
    [self.navigationController popViewControllerAnimated:YES];
}

@end

#pragma mark - The overlay switcher

// IMPORTANT: this VC is never alloc'd as the presented account-manager screen
// itself. Apollo's _TtC6Apollo28AccountManagerViewController has its own
// custom Swift designated initializer (visible in Hopper only as a bare
// function, no ObjC selector) that does ivar setup before calling
// super.init(nibName:bundle:) — and its OWN override of
// -initWithNibName:bundle: is a deliberate `fatalError()` stub forcing callers
// through that custom initializer ("Use of unimplemented initializer
// 'init(nibName:bundle:)'" — confirmed by crashing on exactly this when an
// earlier version of this file tried to alloc/init one directly). There is no
// safe way to construct an instance ourselves.
//
// Instead: let Apollo construct and present the real instance entirely on its
// own (the %hook below only runs AFTER -viewDidLoad's %orig has already done
// that correctly), then install this view controller as a CHILD of that real,
// already-valid instance, covering its table view. All switch/add/delete
// actions are driven on that same live `liveManager` instance via its
// existing ObjC-visible selectors, never on anything we constructed.
@interface ApolloAccountSwitcherViewController ()
@property (nonatomic, weak, nullable) UIViewController *liveManager;
@property (nonatomic, strong) NSArray<ApolloSwitcherAccountRow *> *rows;
- (BOOL)driveLiveMoveRowFromIndexPath:(NSIndexPath *)fromPath toIndexPath:(NSIndexPath *)toPath;
@end

// Fetches a private ivar of object type by name (e.g. the real `tableView`
// ivar on the live AccountManagerViewController instance), defensively.
static id _Nullable ApolloGetObjectIvar(id object, const char *name) {
    if (!object) return nil;
    Ivar ivar = class_getInstanceVariable([object class], name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

#pragma mark - Identity-preserving native account reorder

// The overlay calls Apollo's native move handler. This result lets it commit
// its cached row order only after the guarded live move succeeds.
static const void *kApolloAccountReorderSucceededKey = &kApolloAccountReorderSucceededKey;

typedef struct {
    __unsafe_unretained id manager;
    __unsafe_unretained id activeAccount;
    Ivar accountsIvar;
    Ivar currentIndexIvar;
    Ivar backgroundTaskIvar;
    NSUInteger accountCount;
    NSInteger currentIndex;
    NSInteger movedIndex;
    uintptr_t originalOrder[64];
} ApolloAccountReorderContext;

static BOOL ApolloAccountReorderIvarFits(Class cls, Ivar ivar, size_t length) {
    if (!cls || !ivar) return NO;
    ptrdiff_t offset = ivar_getOffset(ivar);
    size_t instanceSize = class_getInstanceSize(cls);
    return offset >= 0 && (size_t)offset <= instanceSize &&
        length <= instanceSize - (size_t)offset;
}

static NSInteger ApolloAccountIndexAfterMove(NSInteger activeIndex,
                                             NSInteger sourceIndex,
                                             NSInteger destinationIndex) {
    if (activeIndex == sourceIndex) return destinationIndex;
    if (sourceIndex < activeIndex && activeIndex <= destinationIndex) return activeIndex - 1;
    if (destinationIndex <= activeIndex && activeIndex < sourceIndex) return activeIndex + 1;
    return activeIndex;
}

static void ApolloAccountReorderWriteIndex(const ApolloAccountReorderContext *context,
                                           NSInteger index) {
    uint8_t *bytes = (uint8_t *)(__bridge void *)context->manager;
    ptrdiff_t offset = ivar_getOffset(context->currentIndexIvar);
    uint8_t some = 0;
    memcpy(bytes + offset, &index, sizeof(index));
    memcpy(bytes + offset + sizeof(index), &some, sizeof(some));
}

static UIBackgroundTaskIdentifier ApolloAccountReorderReadTask(
    const ApolloAccountReorderContext *context) {
    UIBackgroundTaskIdentifier value = UIBackgroundTaskInvalid;
    uint8_t *bytes = (uint8_t *)(__bridge void *)context->manager;
    memcpy(&value, bytes + ivar_getOffset(context->backgroundTaskIvar), sizeof(value));
    return value;
}

static void ApolloAccountReorderWriteTask(const ApolloAccountReorderContext *context,
                                          UIBackgroundTaskIdentifier value) {
    uint8_t *bytes = (uint8_t *)(__bridge void *)context->manager;
    memcpy(bytes + ivar_getOffset(context->backgroundTaskIvar), &value, sizeof(value));
}

// Read the native Swift array without retaining or mutating its elements.
static BOOL ApolloAccountReorderReadOrder(const ApolloAccountReorderContext *context,
                                          uintptr_t order[64]) {
    uint8_t *managerBytes = (uint8_t *)(__bridge void *)context->manager;
    uintptr_t storageWord = 0;
    memcpy(&storageWord, managerBytes + ivar_getOffset(context->accountsIvar),
           sizeof(storageWord));
    if ((storageWord & 0xF000000000000000ULL) != 0) return NO;
    uint8_t *storage = (uint8_t *)(storageWord & ~(uintptr_t)0x7);
    if (!storage) return NO;

    uintptr_t count = 0;
    memcpy(&count, storage + 2 * sizeof(uintptr_t), sizeof(count));
    if (count != context->accountCount) return NO;
    for (NSUInteger index = 0; index < context->accountCount; index++) {
        memcpy(&order[index], storage + (4 + index) * sizeof(uintptr_t),
               sizeof(order[index]));
        if (!order[index]) return NO;
    }
    return YES;
}

static NSInteger ApolloAccountReorderIndexOf(const uintptr_t order[64],
                                              NSUInteger count,
                                              uintptr_t account) {
    for (NSUInteger index = 0; index < count; index++) {
        if (order[index] == account) return (NSInteger)index;
    }
    return -1;
}

static void ApolloAccountReorderApplyMove(uintptr_t order[64],
                                          NSInteger source,
                                          NSInteger destination) {
    uintptr_t moved = order[source];
    if (source < destination) {
        memmove(&order[source], &order[source + 1],
                (NSUInteger)(destination - source) * sizeof(uintptr_t));
    } else {
        memmove(&order[destination + 1], &order[destination],
                (NSUInteger)(source - destination) * sizeof(uintptr_t));
    }
    order[destination] = moved;
}

static BOOL ApolloAccountReorderOrdersMatch(const ApolloAccountReorderContext *context,
                                            const uintptr_t first[64],
                                            const uintptr_t second[64]) {
    return memcmp(first, second,
                  context->accountCount * sizeof(uintptr_t)) == 0;
}

// Check every private Swift-layout assumption before %orig. Signed-out moves
// are intentionally rejected because there is no live identity to prove.
static BOOL ApolloAccountReorderPrepare(NSInteger source,
                                        NSInteger destination,
                                        ApolloAccountReorderContext *outContext) {
    if (![NSThread isMainThread] || !outContext) return NO;

    Class managerClass = objc_getClass("_TtC6Apollo14AccountManager");
    SEL sharedSelector = NSSelectorFromString(@"shared");
    id manager = managerClass && [managerClass respondsToSelector:sharedSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(managerClass, sharedSelector) : nil;
    if (!manager || object_getClass(manager) != managerClass) return NO;

    Ivar accountsIvar = class_getInstanceVariable(managerClass, "accounts");
    Ivar currentIndexIvar = class_getInstanceVariable(managerClass, "currentAccountIndex");
    Ivar backgroundTaskIvar = class_getInstanceVariable(managerClass, "backgroundTaskID");
    if (!ApolloAccountReorderIvarFits(managerClass, accountsIvar, sizeof(uintptr_t)) ||
        !ApolloAccountReorderIvarFits(managerClass, currentIndexIvar, sizeof(NSInteger) + 1) ||
        !ApolloAccountReorderIvarFits(managerClass, backgroundTaskIvar,
                                      sizeof(UIBackgroundTaskIdentifier)) ||
        ivar_getOffset(currentIndexIvar) !=
            ivar_getOffset(accountsIvar) + (ptrdiff_t)sizeof(uintptr_t)) {
        return NO;
    }

    SEL countSelector = NSSelectorFromString(@"totalAccountsObjC");
    SEL persistSelector = NSSelectorFromString(@"persistInformationToDisk");
    NSMethodSignature *countSignature = [manager methodSignatureForSelector:countSelector];
    NSMethodSignature *persistSignature = [manager methodSignatureForSelector:persistSelector];
    if (!countSignature || countSignature.numberOfArguments != 2 ||
        countSignature.methodReturnLength != sizeof(NSInteger) ||
        !persistSignature || persistSignature.numberOfArguments != 2 ||
        persistSignature.methodReturnLength != 0) {
        return NO;
    }

    NSInteger reportedCount = 0;
    @try {
        reportedCount = ((NSInteger (*)(id, SEL))objc_msgSend)(manager, countSelector);
    } @catch (__unused NSException *exception) {
        return NO;
    }
    if (reportedCount <= 0 || reportedCount > 64 || source < 0 || destination < 0 ||
        source >= reportedCount || destination >= reportedCount) return NO;

    uint8_t *bytes = (uint8_t *)(__bridge void *)manager;
    ptrdiff_t indexOffset = ivar_getOffset(currentIndexIvar);
    NSInteger currentIndex = 0;
    uint8_t discriminator = 0xFF;
    memcpy(&currentIndex, bytes + indexOffset, sizeof(currentIndex));
    memcpy(&discriminator, bytes + indexOffset + sizeof(currentIndex), sizeof(discriminator));
    id activeAccount = ApolloActiveAccountClient();
    if (discriminator != 0 || currentIndex < 0 ||
        currentIndex >= reportedCount || !activeAccount) return NO;

    ApolloAccountReorderContext context = {0};
    context.manager = manager;
    context.activeAccount = activeAccount;
    context.accountsIvar = accountsIvar;
    context.currentIndexIvar = currentIndexIvar;
    context.backgroundTaskIvar = backgroundTaskIvar;
    context.accountCount = (NSUInteger)reportedCount;
    context.currentIndex = currentIndex;
    context.movedIndex = ApolloAccountIndexAfterMove(currentIndex, source, destination);
    if (ApolloAccountReorderReadTask(&context) != UIBackgroundTaskInvalid ||
        !ApolloAccountReorderReadOrder(&context, context.originalOrder) ||
        context.originalOrder[currentIndex] !=
            (uintptr_t)(__bridge void *)activeAccount) return NO;
    for (NSUInteger index = 0; index < context.accountCount; index++) {
        if (ApolloAccountReorderIndexOf(context.originalOrder, index,
                                        context.originalOrder[index]) >= 0) return NO;
    }
    *outContext = context;
    return YES;
}

typedef BOOL (^ApolloAccountReorderMoveBlock)(NSInteger source, NSInteger destination);

// Reconstruct the exact original permutation through Apollo's native mover.
// Each step is verified before another begins; the Swift array is never
// written directly.
static BOOL ApolloAccountReorderRestore(
    const ApolloAccountReorderContext *context,
    UIBackgroundTaskIdentifier guard,
    ApolloAccountReorderMoveBlock move) {
    uintptr_t liveOrder[64] = {0};
    if (ApolloAccountReorderReadTask(context) != guard ||
        !ApolloAccountReorderReadOrder(context, liveOrder)) return NO;
    for (NSUInteger index = 0; index < context->accountCount; index++) {
        if (ApolloAccountReorderIndexOf(liveOrder, context->accountCount,
                                        context->originalOrder[index]) < 0) return NO;
    }

    for (NSUInteger target = 0; target < context->accountCount; target++) {
        if (liveOrder[target] == context->originalOrder[target]) continue;
        NSInteger source = ApolloAccountReorderIndexOf(
            liveOrder, context->accountCount, context->originalOrder[target]);
        NSInteger activeIndex = ApolloAccountReorderIndexOf(
            liveOrder, context->accountCount,
            (uintptr_t)(__bridge void *)context->activeAccount);
        if (source < 0 || activeIndex < 0) return NO;
        ApolloAccountReorderWriteIndex(context, activeIndex);

        uintptr_t expectedOrder[64] = {0};
        memcpy(expectedOrder, liveOrder,
               context->accountCount * sizeof(uintptr_t));
        ApolloAccountReorderApplyMove(expectedOrder, source, (NSInteger)target);
        (void)move(source, (NSInteger)target);
        if (ApolloAccountReorderReadTask(context) != guard ||
            !ApolloAccountReorderReadOrder(context, liveOrder) ||
            !ApolloAccountReorderOrdersMatch(context, liveOrder, expectedOrder)) return NO;
    }

    ApolloAccountReorderWriteIndex(context, context->currentIndex);
    return ApolloAccountReorderReadTask(context) == guard &&
        ApolloAccountReorderOrdersMatch(context, liveOrder, context->originalOrder) &&
        ApolloActiveAccountClient() == context->activeAccount;
}

static BOOL ApolloAccountReorderReleaseGuard(
    const ApolloAccountReorderContext *context,
    UIBackgroundTaskIdentifier guard) {
    if (ApolloAccountReorderReadTask(context) != guard) return NO;
    ApolloAccountReorderWriteTask(context, UIBackgroundTaskInvalid);
    return ApolloAccountReorderReadTask(context) == UIBackgroundTaskInvalid;
}

// Apollo's native method starts a background task and schedules its writer.
// A normal return means that native eventual persistence was accepted.
static BOOL ApolloAccountReorderSchedulePersist(
    const ApolloAccountReorderContext *context) {
    @try {
        ((void (*)(id, SEL))objc_msgSend)(
            context->manager, NSSelectorFromString(@"persistInformationToDisk"));
        return YES;
    } @catch (NSException *exception) {
        ApolloLog(@"[AccountSwitcher] Account reorder persistence failed: %@", exception);
        return NO;
    }
}

@implementation ApolloAccountSwitcherViewController

+ (BOOL)isAvailable {
    return [[NSUserDefaults standardUserDefaults] objectForKey:UDKeyUseCustomAccountSwitcher] == nil
        || [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyUseCustomAccountSwitcher];
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Accounts";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(doneTapped:)];
    // editButtonItem toggles UITableViewController's own -setEditing:animated:,
    // which (default implementation) puts self.tableView into edit mode —
    // showing the red remove control on every row canEditRowAtIndexPath:
    // allows, as a tap-based alternative to swipe-to-delete.
    self.navigationItem.leftBarButtonItem = self.editButtonItem;
    // AccountRow is NOT registered via registerClass: it needs the .subtitle
    // style (for the key-status detail line), which registerClass's recycling
    // pool can't express — see the manual dequeue-or-alloc in cellForRowAtIndexPath:.
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"AddRow"];
    // Keep account rows self-sizing for Dynamic Type, but force UIKit to resolve
    // geometry exactly. iOS 26's estimate cache can otherwise overlap rows
    // after reorder-driven autoscrolling.
    self.tableView.estimatedRowHeight = 0.0;
    self.tableView.estimatedSectionHeaderHeight = 0.0;
    self.tableView.estimatedSectionFooterHeight = 0.0;
    [self reloadRows];
}

- (void)doneTapped:(id)sender {
    // self isn't the presented VC — liveManager is. Dismissing it tells
    // UIKit to walk up to whoever actually presented it.
    [self.liveManager dismissViewControllerAnimated:YES completion:nil];
}

- (void)reloadRows {
    self.rows = ApolloSwitcherLoadAccountRows();
    [self.tableView reloadData];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? (NSInteger)self.rows.count : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"Accounts" : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 0
        ? @"Each account can use its own Reddit API key, or sign in without one via a web session. Tap an account to switch to it, or tap the ellipsis to manage its sign-in."
        : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 1) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"AddRow" forIndexPath:indexPath];
        cell.textLabel.text = @"Add Account…";
        cell.textLabel.textColor = ApolloThemeAccentColor() ?: self.view.tintColor;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }

    ApolloSwitcherAccountCell *cell = [tableView dequeueReusableCellWithIdentifier:@"AccountRow"];
    if (!cell) {
        cell = [[ApolloSwitcherAccountCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                reuseIdentifier:@"AccountRow"];
    }
    cell.textLabel.textColor = [UIColor labelColor];
    cell.accessoryType = UITableViewCellAccessoryNone;

    ApolloSwitcherAccountRow *row = self.rows[indexPath.row];
    cell.textLabel.text = [NSString stringWithFormat:@"u/%@", row.username];
    cell.detailTextLabel.text = row.keyStatusText;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    ApolloSwitcherApplyAvatarToCell(cell, row.username);
    cell.accessoryView = [self accessoryViewForRow:row];
    __weak UITableView *weakTableView = tableView;
    cell.reorderDragDidEnd = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakTableView reloadData];
        });
    };
    return cell;
}

// Checkmark (only for the active account) + an info button (edits that
// account's key) — replaces the single accessoryType slot, which can't show
// both a selection indicator and a detail-disclosure button at once.
- (UIView *)accessoryViewForRow:(ApolloSwitcherAccountRow *)row {
    // NOTE: use `alpha`, not `hidden` — UIStackView automatically collapses a
    // hidden arranged subview's width to zero, which shifted the info button
    // left on every non-active row instead of leaving its slot reserved.
    UIImageView *checkmark = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"]];
    checkmark.tintColor = ApolloThemeAccentColor() ?: self.view.tintColor;
    checkmark.alpha = row.isActive ? 1.0 : 0.0;
    checkmark.contentMode = UIViewContentModeCenter;
    checkmark.frame = CGRectMake(0, 0, 20, 24);

    UIButton *infoButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [infoButton setImage:[UIImage systemImageNamed:@"ellipsis.circle"] forState:UIControlStateNormal];
    infoButton.tintColor = [UIColor secondaryLabelColor];
    infoButton.frame = CGRectMake(0, 0, 28, 28);
    objc_setAssociatedObject(infoButton, kApolloSwitcherEditButtonUsernameKey, row.username, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [infoButton addTarget:self action:@selector(editButtonTapped:) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectMake(0, 0, 56, 28)];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 4;
    [stack addArrangedSubview:checkmark];
    [stack addArrangedSubview:infoButton];
    return stack;
}

- (void)editButtonTapped:(UIButton *)sender {
    NSString *username = objc_getAssociatedObject(sender, kApolloSwitcherEditButtonUsernameKey);
    if (username.length == 0) return;
    if (ApolloWebSessionFor(username) != nil) {
        [self presentWebSessionActionsForUsername:username];
    } else {
        [self presentCredentialEditorForUsername:username];
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 0 && self.liveManager != nil;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 0 && self.liveManager != nil;
}

// Keeps a drag from landing on (or past) the "Add Account…" row in section 1 —
// reordering is only meaningful within the account list itself.
- (NSIndexPath *)tableView:(UITableView *)tableView
   targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)sourceIndexPath
                        toProposedIndexPath:(NSIndexPath *)proposedIndexPath {
    if (proposedIndexPath.section != 0) {
        NSInteger lastRow = MAX((NSInteger)self.rows.count - 1, 0);
        return [NSIndexPath indexPathForRow:lastRow inSection:0];
    }
    return proposedIndexPath;
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath {
    return @"Remove";
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete || indexPath.section != 0) return;
    ApolloSwitcherAccountRow *row = self.rows[indexPath.row];
    [self driveLiveCommitEditingStyle:UITableViewCellEditingStyleDelete atRow:indexPath.row];
    // Harmless no-op for whichever store doesn't have this username (auth modes
    // are mutually exclusive per account), so both are always safe to call.
    ApolloAccountCredentialsRemove(row.username);
    ApolloWebSessionRemove(row.username);
    [self reloadRows];
}

// UIKit has already performed the visual move by the time this is called. Drive
// the guarded native move first; only commit our cached row order after the
// native AccountManager confirms success. A failed runtime-layout preflight
// reloads below on the next main turn, visually cancelling UIKit's move.
- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    if (sourceIndexPath.section != 0 || destinationIndexPath.section != 0) return;
    if (sourceIndexPath.row < 0 || destinationIndexPath.row < 0 ||
        sourceIndexPath.row >= (NSInteger)self.rows.count ||
        destinationIndexPath.row >= (NSInteger)self.rows.count ||
        ![self driveLiveMoveRowFromIndexPath:sourceIndexPath toIndexPath:destinationIndexPath]) {
        // Keep the cached order unchanged. ApolloSwitcherAccountCell repairs
        // UIKit's visual move only after dragStateDidChange: returns to None.
        return;
    }
    NSMutableArray<ApolloSwitcherAccountRow *> *rows = [self.rows mutableCopy];
    ApolloSwitcherAccountRow *moved = rows[sourceIndexPath.row];
    [rows removeObjectAtIndex:sourceIndexPath.row];
    [rows insertObject:moved atIndex:destinationIndexPath.row];
    self.rows = rows;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 1) {
        [self presentAddAccountChooser];
        return;
    }

    ApolloSwitcherAccountRow *row = self.rows[indexPath.row];
    if (row.isActive) return;
    [self driveLiveSwitchToRow:indexPath.row];
    // Apollo's account-changed notification (fired by the call above) updates
    // the profile tab/feed asynchronously; refresh our own list shortly after
    // so the active marker catches up.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self reloadRows];
    });
}

#pragma mark - Driving the live native instance

// Mirrors the native switch-mode branch of -tableView:didSelectRowAtIndexPath:
// (verified in Hopper: with accountSwitchType set — which Apollo's own real
// construction already does for this entry point — that branch reads only
// the IndexPath argument to derive the row, plus the live AccountManager
// singleton; it doesn't depend on which UITableView instance is passed).
- (void)driveLiveSwitchToRow:(NSInteger)row {
    if (!self.liveManager) return;
    SEL sel = NSSelectorFromString(@"tableView:didSelectRowAtIndexPath:");
    if (![self.liveManager respondsToSelector:sel]) return;
    NSMethodSignature *sig = [self.liveManager methodSignatureForSelector:sel];
    if (!sig) return;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.selector = sel;
    id tv = ApolloGetObjectIvar(self.liveManager, "tableView");
    NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:0];
    [inv setArgument:&tv atIndex:2];
    [inv setArgument:&path atIndex:3];
    @try {
        [inv invokeWithTarget:self.liveManager];
    } @catch (NSException *ex) {
        ApolloLog(@"[AccountSwitcher] Live switch call failed: %@", ex);
    }
}

- (void)driveLiveCommitEditingStyle:(UITableViewCellEditingStyle)style atRow:(NSInteger)row {
    if (!self.liveManager) return;
    SEL sel = NSSelectorFromString(@"tableView:commitEditingStyle:forRowAtIndexPath:");
    if (![self.liveManager respondsToSelector:sel]) return;
    NSMethodSignature *sig = [self.liveManager methodSignatureForSelector:sel];
    if (!sig) return;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.selector = sel;
    id tv = ApolloGetObjectIvar(self.liveManager, "tableView");
    NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:0];
    [inv setArgument:&tv atIndex:2];
    [inv setArgument:&style atIndex:3];
    [inv setArgument:&path atIndex:4];
    @try {
        [inv invokeWithTarget:self.liveManager];
    } @catch (NSException *ex) {
        ApolloLog(@"[AccountSwitcher] Live delete call failed: %@", ex);
    }
}

// Verified selector: -tableView:moveRowAtIndexPath:toIndexPath: (the native
// switcher's drag-to-reorder handler). The hooked live method records YES only
// after its Swift-layout preflight and identity-preserving move both complete.
- (BOOL)driveLiveMoveRowFromIndexPath:(NSIndexPath *)fromPath toIndexPath:(NSIndexPath *)toPath {
    if (!self.liveManager) return NO;
    SEL sel = NSSelectorFromString(@"tableView:moveRowAtIndexPath:toIndexPath:");
    if (![self.liveManager respondsToSelector:sel]) return NO;
    NSMethodSignature *sig = [self.liveManager methodSignatureForSelector:sel];
    if (!sig || sig.numberOfArguments != 5 || sig.methodReturnLength != 0) return NO;
    objc_setAssociatedObject(self.liveManager, kApolloAccountReorderSucceededKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.selector = sel;
    id tv = ApolloGetObjectIvar(self.liveManager, "tableView");
    [inv setArgument:&tv atIndex:2];
    [inv setArgument:&fromPath atIndex:3];
    [inv setArgument:&toPath atIndex:4];
    @try {
        [inv invokeWithTarget:self.liveManager];
    } @catch (NSException *ex) {
        ApolloLog(@"[AccountSwitcher] Live move call failed: %@", ex);
        return NO;
    }
    return [objc_getAssociatedObject(self.liveManager, kApolloAccountReorderSucceededKey) boolValue];
}

// Starts Apollo's own OAuth add-account flow via the live instance's real "+"
// bar button action (verified selector: -addBarButtonItemTapped:). The new
// account is created with the default API key; set a custom key for it
// afterward via the per-account editor (tap its row's › once it appears).
- (void)driveLiveAddAccount {
    if (!self.liveManager) {
        ApolloLog(@"[AccountSwitcher] No live manager — cannot start add-account flow");
        return;
    }
    SEL sel = NSSelectorFromString(@"addBarButtonItemTapped:");
    if (![self.liveManager respondsToSelector:sel]) return;
    NSMethodSignature *sig = [self.liveManager methodSignatureForSelector:sel];
    if (!sig) return;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.selector = sel;
    id sender = nil;
    [inv setArgument:&sender atIndex:2];
    @try {
        [inv invokeWithTarget:self.liveManager];
    } @catch (NSException *ex) {
        ApolloLog(@"[AccountSwitcher] Live add-account call failed: %@", ex);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self reloadRows];
    });
}

#pragma mark - Add Account: choose sign-in method

// Auth modes are mutually exclusive per account (see ApolloWebSessionStore.h),
// so adding an account means picking ONE of the two up front, rather than the
// old single-path "+" flow that only ever started Apollo's own OAuth add-account.
- (void)presentAddAccountChooser {
    ApolloWebSessionPresentSignInChooser(self, ^{
        [self driveLiveAddAccount];
    });
}

// Web-session ("API-Key-Free") sign-in: presents the WKWebView login flow. If a
// web-session account already exists, the shared persistent cookie jar needs
// clearing first so the login form actually shows instead of silently reusing
// the existing web user (see ApolloWebSessionLoginViewController.h). No master-
// flag gate: the mode is chosen per account at sign-in, and a successful
// harvest enables the transport flag itself.
- (void)presentWebSessionAddAccount {
    BOOL hasExistingWebSession = ApolloWebSessionUsernames().count > 0;
    ApolloWebSessionLoginViewController *vc = hasExistingWebSession
        ? [ApolloWebSessionLoginViewController loginControllerForAdditionalAccount]
        : [ApolloWebSessionLoginViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

// Tapping a web-session row's edit button: there's no API key to edit, so
// offer re-sign-in (the same flow as adding an additional account — clears the
// cookie jar first, since whatever's there belongs to THIS account and the
// user is explicitly choosing to replace it) or switching the account over to
// API-key sign-in (removes the web session; see ApolloPresentSwitchToAPIKeyFlow).
- (void)presentWebSessionActionsForUsername:(NSString *)username {
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"u/%@", username]
                          message:@"Signed in without an API key (web session)."
                   preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Re-Sign In"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        ApolloWebSessionLoginViewController *vc = [ApolloWebSessionLoginViewController loginControllerForAdditionalAccount];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        [self presentViewController:nav animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Use API Key Instead…"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        ApolloPresentSwitchToAPIKeyFlow(self, username, ^(BOOL switched) {
            if (switched) [self reloadRows];
        });
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Per-account credential editor

- (void)presentCredentialEditorForUsername:(NSString *)username {
    ApolloAccountCredentialEntry *existing = ApolloAccountCredentialsFor(username) ?: [ApolloAccountCredentialEntry new];
    ApolloAccountCredentialEditorViewController *editor = [ApolloAccountCredentialEditorViewController new];
    editor.title = [NSString stringWithFormat:@"u/%@", username];
    editor.entry = existing;
    editor.onSave = ^(NSString *clientId, NSString *secret, NSString *redirectURI) {
        ApolloAccountCredentialsSet(username, clientId, secret, redirectURI);
        [self reloadRows];
    };
    editor.onClear = ^{
        ApolloAccountCredentialsRemove(username);
        [self reloadRows];
    };
    [self.navigationController pushViewController:editor animated:YES];
}

@end

#pragma mark - Installing the overlay on the real, live instance

// Run once per real AccountManagerViewController instance, right after its
// own (correct, Apollo-internal) -viewDidLoad has finished — see the %hook
// below. Wraps our switcher in its own UINavigationController (so it can push
// the credential editor) and adds that as a full-bounds child covering
// `host`'s own view; hides the real table view underneath so taps land only
// on our overlay. Never touches how `host` itself was constructed.
static const void *kApolloSwitcherInstalledKey = &kApolloSwitcherInstalledKey;

static void ApolloInstallAccountSwitcherOverlay(UIViewController *host) {
    if (![ApolloAccountSwitcherViewController isAvailable]) return;
    if (objc_getAssociatedObject(host, kApolloSwitcherInstalledKey)) return;
    objc_setAssociatedObject(host, kApolloSwitcherInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    @try {
        ApolloAccountSwitcherViewController *switcher = [ApolloAccountSwitcherViewController new];
        switcher.liveManager = host;
        UINavigationController *overlayNav = [[UINavigationController alloc] initWithRootViewController:switcher];
        overlayNav.modalPresentationStyle = UIModalPresentationCurrentContext;

        [host addChildViewController:overlayNav];
        overlayNav.view.frame = host.view.bounds;
        overlayNav.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        overlayNav.view.backgroundColor = [UIColor systemBackgroundColor];
        [host.view addSubview:overlayNav.view];
        [overlayNav didMoveToParentViewController:host];

        id realTableView = ApolloGetObjectIvar(host, "tableView");
        if ([realTableView isKindOfClass:[UIView class]]) {
            ((UIView *)realTableView).hidden = YES;
        }
        ApolloLog(@"[AccountSwitcher] Overlay installed on live AccountManagerViewController");
    } @catch (NSException *ex) {
        ApolloLog(@"[AccountSwitcher] Overlay install failed, leaving native UI visible: %@", ex);
    }
}

// The overlay's custom cell repairs failed drops at drag-end. If the custom
// switcher is disabled and Apollo's native table is visible, reload it on the
// next turn to cancel UIKit's already-animated visual move.
static void ApolloCancelVisibleNativeAccountReorder(UITableView *tableView) {
    if (![tableView isKindOfClass:[UITableView class]] || tableView.hidden) return;
    __weak UITableView *weakTableView = tableView;
    dispatch_async(dispatch_get_main_queue(), ^{
        UITableView *table = weakTableView;
        if (!table.hidden) [table reloadData];
    });
}

static BOOL sApolloAccountReorderQuarantined = NO;

static void ApolloQuarantineAccountSwitcher(UIViewController *controller) {
    sApolloAccountReorderQuarantined = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        [controller dismissViewControllerAnimated:NO completion:nil];
    });
}

%hook _TtC6Apollo28AccountManagerViewController

- (void)viewDidLoad {
    %orig;
    if (sApolloAccountReorderQuarantined) {
        ApolloQuarantineAccountSwitcher((UIViewController *)self);
        return;
    }
    ApolloInstallAccountSwitcherOverlay((UIViewController *)self);
}

- (void)tableView:(UITableView *)tableView
 moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath
       toIndexPath:(NSIndexPath *)destinationIndexPath {
    objc_setAssociatedObject(self, kApolloAccountReorderSucceededKey, @NO,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (![sourceIndexPath isKindOfClass:[NSIndexPath class]] ||
        ![destinationIndexPath isKindOfClass:[NSIndexPath class]] ||
        sourceIndexPath.section != 0 || destinationIndexPath.section != 0) {
        ApolloLog(@"[AccountSwitcher] Cancelling account reorder: invalid index path");
        ApolloCancelVisibleNativeAccountReorder(tableView);
        return;
    }

    NSInteger source = sourceIndexPath.row;
    NSInteger destination = destinationIndexPath.row;
    if (source == destination) {
        objc_setAssociatedObject(self, kApolloAccountReorderSucceededKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    ApolloAccountReorderContext context = {0};
    if (!ApolloAccountReorderPrepare(source, destination, &context)) {
        ApolloLog(@"[AccountSwitcher] Cancelling account reorder: runtime layout check failed");
        ApolloCancelVisibleNativeAccountReorder(tableView);
        return;
    }

    // Suppress the native handler's immediate stale write, move its index with
    // the retained account, then persist the corrected order/index pair once.
    id activeAccount = context.activeAccount; // retain across the Swift array mutation
    uintptr_t activePointer = (uintptr_t)(__bridge void *)activeAccount;
    uintptr_t expectedOrder[64] = {0};
    memcpy(expectedOrder, context.originalOrder,
           context.accountCount * sizeof(uintptr_t));
    ApolloAccountReorderApplyMove(expectedOrder, source, destination);

    ApolloAccountReorderMoveBlock nativeMove = ^BOOL(NSInteger from, NSInteger to) {
        NSIndexPath *fromPath = [NSIndexPath indexPathForRow:from inSection:0];
        NSIndexPath *toPath = [NSIndexPath indexPathForRow:to inSection:0];
        @try {
            %orig(tableView, fromPath, toPath);
            return YES;
        } @catch (NSException *exception) {
            ApolloLog(@"[AccountSwitcher] Native reorder %ld -> %ld failed: %@",
                      (long)from, (long)to, exception);
            return NO;
        }
    };

    UIBackgroundTaskIdentifier guard = UIBackgroundTaskInvalid == 0
        ? (UIBackgroundTaskIdentifier)NSUIntegerMax : 0;
    ApolloAccountReorderWriteTask(&context, guard);
    if (ApolloAccountReorderReadTask(&context) != guard) {
        ApolloLog(@"[AccountSwitcher] Cancelling account reorder: persistence guard failed");
        ApolloCancelVisibleNativeAccountReorder(tableView);
        return;
    }

    BOOL nativeReturned = nativeMove(source, destination);
    uintptr_t observedOrder[64] = {0};
    BOOL readOrder = ApolloAccountReorderReadOrder(&context, observedOrder);
    NSInteger activeIndex = readOrder
        ? ApolloAccountReorderIndexOf(observedOrder, context.accountCount, activePointer)
        : -1;
    if (activeIndex >= 0) ApolloAccountReorderWriteIndex(&context, activeIndex);
    BOOL movedSafely = nativeReturned &&
        ApolloAccountReorderReadTask(&context) == guard &&
        readOrder &&
        ApolloAccountReorderOrdersMatch(&context, observedOrder, expectedOrder) &&
        activeIndex == context.movedIndex &&
        expectedOrder[context.movedIndex] == activePointer &&
        ApolloActiveAccountClient() == activeAccount;
    if (!movedSafely) {
        BOOL restored = ApolloAccountReorderRestore(&context, guard, nativeMove);
        BOOL released = restored &&
            ApolloAccountReorderReleaseGuard(&context, guard);
        ApolloLog(@"[AccountSwitcher] Cancelled reorder postcondition (restored=%d, released=%d)",
                  restored, released);
        ApolloCancelVisibleNativeAccountReorder(tableView);
        if (!restored || !released) {
            ApolloQuarantineAccountSwitcher((UIViewController *)self);
        }
        return;
    }

    if (!ApolloAccountReorderReleaseGuard(&context, guard)) {
        BOOL restored = ApolloAccountReorderRestore(&context, guard, nativeMove);
        BOOL released = restored &&
            ApolloAccountReorderReleaseGuard(&context, guard);
        ApolloLog(@"[AccountSwitcher] Cancelled reorder: guard release failed (restored=%d)",
                  restored);
        ApolloCancelVisibleNativeAccountReorder(tableView);
        if (!restored || !released) {
            ApolloQuarantineAccountSwitcher((UIViewController *)self);
        }
        return;
    }

    if (!ApolloAccountReorderSchedulePersist(&context)) {
        // If persistence failed before starting work, restore and persist the
        // original pair. Never race a real background task if one was started.
        BOOL restored = NO;
        BOOL released = NO;
        BOOL originalPersisted = NO;
        if (ApolloAccountReorderReadTask(&context) == UIBackgroundTaskInvalid) {
            ApolloAccountReorderWriteTask(&context, guard);
            if (ApolloAccountReorderReadTask(&context) == guard) {
                restored = ApolloAccountReorderRestore(&context, guard, nativeMove);
                released = restored &&
                    ApolloAccountReorderReleaseGuard(&context, guard);
                originalPersisted = restored && released &&
                    ApolloAccountReorderSchedulePersist(&context);
            }
        }
        ApolloLog(@"[AccountSwitcher] Cancelled unpersisted reorder (restored=%d)",
                  restored);
        ApolloCancelVisibleNativeAccountReorder(tableView);
        if (!originalPersisted) {
            ApolloQuarantineAccountSwitcher((UIViewController *)self);
        }
        return;
    }
    objc_setAssociatedObject(self, kApolloAccountReorderSucceededKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLogDebug(@"[AccountSwitcher] Reordered row %ld -> %ld; active index %ld -> %ld",
                   (long)source, (long)destination,
                   (long)context.currentIndex, (long)context.movedIndex);
}

%end
