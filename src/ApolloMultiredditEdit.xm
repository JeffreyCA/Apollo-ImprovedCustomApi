#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import "ApolloAccountCredentials.h"
#import "ApolloSubredditCustomIconCache.h"

// MARK: - Multireddit Rename & Descriptions
//
// Reddit's website lets you rename a multireddit and give it a description
// (the "edit details" dialog), but Apollo only asks for a name at creation
// time — an existing multireddit can never be renamed or described in-app.
//
// This module adds both, plus display rules for the Subreddits list:
//
// 1. EDITING — in the list's Edit mode, tapping a MULTIREDDITS row opens an
//    editor prefilled with the multireddit's name and description. Saving
//    PUTs the website's own model shape ({"display_name", "description_md"})
//    to api/multi/<path>, so the multireddit's URL slug is untouched, exactly
//    like the website's edit-details dialog. Taps reach us because our
//    setEditing: hook turns on allowsSelectionDuringEditing; Apollo's own
//    didSelect was unreachable in Edit mode (and it navigates), so the
//    didSelect hook swallows every edit-mode tap instead of forwarding it.
// 2. DISPLAY — a multireddit row's subtitle normally lists the subreddits it
//    contains. When the multireddit has a description, the description
//    replaces that list (clear it in the editor and the list comes back).
//    The "Hide Multireddit Descriptions" toggle blanks the subtitle line
//    entirely, mirroring what Hide Feed Descriptions does for the built-in
//    feed rows.
// 3. CUSTOM ICONS — the editor also offers "Choose Custom Icon…" (and
//    "Remove Custom Icon"): a photo picked from the library is stored in the
//    existing subreddit custom-icon cache under a slash-free key derived from
//    the multireddit's path (rename-stable) and drawn over the row's icon.
//    Local-only: Reddit's API has no custom image upload for multireddits.
//
// Mechanics worth noting:
// - Writes go through ApolloActiveAccountClient(): RDKClient.sharedClient is
//   Apollo's application-only bootstrap client whose currentUser is nil while
//   a real account is signed in (see ApolloAccountCredentials.m), and every
//   api/multi path is built from currentUser.username.
// - putPath:parameters:completion:'s completion takes THREE arguments
//   (response, responseObject, error) — verified in the binary from the
//   wrapper block setDescription:forMultiredditWithName: hands it (0x10001f7e8),
//   which forwards to the public two-argument (object, error) completions.
// - After a successful save the local RDKMultireddit is updated via KVC for
//   instant UI, then com.christianselig.MultiredditsUpdatedForAccount is
//   posted (object nil, matching Apollo's own add/remove-subreddit flows),
//   which makes RedditListViewController refetch the authoritative list.
// - Rows are resolved by NAME, never by index. The list re-sorts its model
//   arrays for display, so a visible row index means nothing against the
//   stored array (the exact lesson of the MODERATOR-section fix in
//   ApolloHideModSubreddits.xm). The tapped cell's title label is matched
//   against RDKMultireddit.displayName case-insensitively.
// - The model array is captured from -[RDKUser setMultireddits:] (fired by
//   the list's own fetch) with the active client's user as fallback, so no
//   Swift ivar of the view controller is ever read (its `multireddits` field
//   is a Swift Array — a bridge object, not a safe NSArray pointer).

// Minimal surface of Apollo's bundled RedditKit model. Entries of the captured
// multireddits array; all methods are ObjC-visible (verified via Hopper).
@interface RDKMultireddit : NSObject
- (NSString *)name;
- (NSString *)displayName;
- (NSString *)path;
- (NSString *)descriptionMarkdown;
- (BOOL)isEditable;
@end

@interface RedditListTableViewCell : UITableViewCell
@end

@interface RedditListViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
// The %new methods this module adds, declared so in-module calls type-check.
- (void)apolloMultiEditPresentEditorFor:(RDKMultireddit *)multireddit;
- (void)apolloMultiEditPresentEditorFor:(RDKMultireddit *)multireddit prefillName:(NSString *)prefillName prefillDescription:(NSString *)prefillDescription;
- (void)apolloMultiEditSave:(RDKMultireddit *)multireddit name:(NSString *)newName descriptionText:(NSString *)newDescription;
- (void)apolloMultiEditShowError:(NSString *)message;
- (void)apolloMultiEditPickIconFor:(RDKMultireddit *)multireddit pendingName:(NSString *)pendingName pendingDescription:(NSString *)pendingDescription;
@end

// Posted by Apollo after multireddit mutations; RedditListViewController
// listens and refetches. Recovered from the binary (posted with object:nil).
static NSString *const kApolloMultiredditsUpdatedNotification = @"com.christianselig.MultiredditsUpdatedForAccount";

// Multireddit arrays captured from -[RDKClient multiredditsWithCompletion:],
// keyed by the client instance that fetched them (weak keys — a released
// account client drops its entry). Apollo runs that fetch for every signed-in
// account around launch, so a single "latest array" global would be clobbered
// by whichever account answered last; keying by client keeps the signed-in
// account's list resolvable via ApolloActiveAccountClient().
static NSMapTable<id, NSArray *> *sMultiredditsByClient = nil;

// The Subreddits list table most recently configured through our cellForRow
// hook — reloaded when the hide-descriptions toggle changes.
static __weak UITableView *sMultiEditListTable = nil;

// Associated flag: we (not Apollo) enabled allowsSelectionDuringEditing on
// this table, so we also turn it back off when Edit mode ends.
static char kApolloMultiEditSelectionEnabledKey;

// Associates the picker context (multireddit + the editor's unsaved field
// values) with its PHPicker instance, so the editor can reopen exactly as the
// user left it after picking or cancelling.
static char kApolloMultiEditPickerTargetKey;

// Associates a custom-icon cache key with a row's icon image view. Apollo's
// icon pipeline applies the multireddit's icon (the first subreddit's avatar)
// asynchronously, so a one-shot write from cellForRow gets overwritten a
// moment later; the UIImageView setImage: hook below re-asserts the custom
// icon on every attempt to replace it while the tag is present.
static char kApolloMultiEditIconEnforceKey;

// Fast path for that hook: stays NO (one static read per setImage:) until any
// custom multireddit icon exists this session.
static BOOL sMultiEditIconEnforcementNeeded = NO;

// MARK: - Helpers

static NSString *ApolloMultiEditTrim(NSString *text) {
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// Leftmost non-empty UILabel in a view tree — section headers contain just
// their title label. (Same approach as ApolloHideModSubreddits.)
static NSString *ApolloMultiEditLeftmostLabelText(UIView *root) {
    if (!root) return nil;

    UILabel *best = nil;
    CGFloat bestX = CGFLOAT_MAX;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count > 0) {
        UIView *candidate = stack.lastObject;
        [stack removeLastObject];
        if ([candidate isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)candidate;
            NSString *text = ApolloMultiEditTrim(label.text);
            if (text.length > 0) {
                CGFloat minX = CGRectGetMinX([label convertRect:label.bounds toView:root]);
                if (minX < bestX) {
                    best = label;
                    bestX = minX;
                }
            }
        }
        [stack addObjectsFromArray:candidate.subviews];
    }
    return ApolloMultiEditTrim(best.text);
}

// Resolves a section's header title (uppercased) by checking the visible
// header first, then asking the delegate to build one.
static NSString *ApolloMultiEditSectionTitle(id delegate, UITableView *tableView, NSInteger section) {
    if (!tableView || section < 0 || section >= tableView.numberOfSections) return nil;

    UIView *header = [tableView headerViewForSection:section];
    if (!header && [delegate respondsToSelector:@selector(tableView:viewForHeaderInSection:)]) {
        header = [delegate tableView:tableView viewForHeaderInSection:section];
    }
    NSString *text = ApolloMultiEditLeftmostLabelText(header);
    return text.length > 0 ? text.uppercaseString : nil;
}

static id ApolloMultiEditObjectIvar(id object, const char *name) {
    if (!object || !name) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

static UITableView *ApolloMultiEditTableView(UIViewController *viewController) {
    UITableView *tableView = (UITableView *)ApolloMultiEditObjectIvar(viewController, "tableView");
    return [tableView isKindOfClass:[UITableView class]] ? tableView : nil;
}

// A UILabel stored property on Apollo's Swift RedditListTableViewCell.
// ObjC-class-typed Swift stored properties are real runtime ivars under their
// Swift names, so plain ivar access is safe (unlike Swift struct fields).
static UILabel *ApolloMultiEditCellLabel(UITableViewCell *cell, const char *name) {
    UILabel *label = (UILabel *)ApolloMultiEditObjectIvar(cell, name);
    return [label isKindOfClass:[UILabel class]] ? label : nil;
}

static Class ApolloMultiEditListCellClass(void) {
    static Class cls = Nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cls = objc_getClass("_TtC6Apollo23RedditListTableViewCell");
    });
    return cls;
}

// MARK: - Custom icons

// Custom multireddit icons ride the existing subreddit custom-icon cache. Its
// keys map straight to <key>.png filenames, so the multireddit's path (stable
// across display-name renames — the URL slug never changes) is made slash-free
// and namespaced away from every possible subreddit name.
static NSString *ApolloMultiEditIconKey(RDKMultireddit *multireddit) {
    NSString *path = [multireddit path];
    if (path.length == 0) return nil;
    return [@"multi" stringByAppendingString:[path stringByReplacingOccurrencesOfString:@"/" withString:@"~"]];
}

static UIImage *ApolloMultiEditCustomIcon(RDKMultireddit *multireddit) {
    NSString *key = ApolloMultiEditIconKey(multireddit);
    return key ? [[ApolloSubredditCustomIconCache sharedCache] cachedIconForSubreddit:key] : nil;
}

// The cell's icon image view has no fixed size constraint — it takes the
// image's intrinsic size, and Apollo hands it display-sized images. So the
// stored 256px icon must be redrawn at the stock icon's point size before
// going into the view (a raw 256pt image blows the row up). Resized copies are
// cached per size; the cache is dumped whenever an icon is saved or removed.
static NSCache<NSString *, UIImage *> *sMultiEditDisplayIconCache = nil;

static UIImage *ApolloMultiEditDisplayIconForKey(NSString *key, CGSize targetSize) {
    if (key.length == 0 || targetSize.width < 1.0 || targetSize.height < 1.0) return nil;

    NSString *cacheKey = [NSString stringWithFormat:@"%@|%.0fx%.0f", key, targetSize.width, targetSize.height];
    UIImage *cached = [sMultiEditDisplayIconCache objectForKey:cacheKey];
    if (cached) return cached;

    UIImage *stored = [[ApolloSubredditCustomIconCache sharedCache] cachedIconForSubreddit:key];
    if (!stored) return nil;

    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:targetSize];
    UIImage *resized = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [stored drawInRect:CGRectMake(0, 0, targetSize.width, targetSize.height)];
    }];
    if (!sMultiEditDisplayIconCache) sMultiEditDisplayIconCache = [[NSCache alloc] init];
    [sMultiEditDisplayIconCache setObject:resized forKey:cacheKey];
    return resized;
}

// Renders the picked photo as a 256px circular icon: center-cropped square,
// aspect-filled, clipped to a circle — the shape of Apollo's own list icons —
// so it looks native regardless of the source photo's aspect ratio or the
// image view's configuration. List icons render ~40pt, so 256px is generous
// while keeping the PNG (and the load-time NSCache entry) small.
static UIImage *ApolloMultiEditScaledIcon(UIImage *image) {
    CGFloat side = 256.0;
    CGSize size = image.size;
    if (size.width < 1.0 || size.height < 1.0) return image;

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1.0;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, side, side)] addClip];
        CGFloat fillScale = MAX(side / size.width, side / size.height);
        CGSize scaled = CGSizeMake(size.width * fillScale, size.height * fillScale);
        [image drawInRect:CGRectMake((side - scaled.width) / 2.0, (side - scaled.height) / 2.0,
                                     scaled.width, scaled.height)];
    }];
}

// MARK: - Model lookup

// The lists to search for a tapped/rendered row's model: the active account
// client's fetch result first (authoritative for the Subreddits list), then
// every other captured fetch as a fallback.
static NSArray<NSArray *> *ApolloMultiEditCandidateLists(void) {
    if (!sMultiredditsByClient) return @[];

    NSMutableArray<NSArray *> *lists = [NSMutableArray array];
    id activeClient = ApolloActiveAccountClient();
    NSArray *activeList = activeClient ? [sMultiredditsByClient objectForKey:activeClient] : nil;
    if (activeList.count > 0) [lists addObject:activeList];

    for (id client in sMultiredditsByClient) {
        NSArray *list = [sMultiredditsByClient objectForKey:client];
        if (list.count > 0 && list != activeList) [lists addObject:list];
    }
    return lists;
}

static RDKMultireddit *ApolloMultiEditFindByTitle(NSString *title) {
    if (title.length == 0) return nil;
    for (NSArray *list in ApolloMultiEditCandidateLists()) {
        for (RDKMultireddit *candidate in list) {
            NSString *display = nil;
            if ([candidate respondsToSelector:@selector(displayName)]) display = [candidate displayName];
            if (display.length == 0 && [candidate respondsToSelector:@selector(name)]) display = [candidate name];
            if (display.length > 0 && [display caseInsensitiveCompare:title] == NSOrderedSame) return candidate;
        }
    }
    return nil;
}

// MARK: - Capture Apollo's multireddit fetches

// The Subreddits list populates its MULTIREDDITS section from this fetch, so
// wrapping the completion hands us the exact model objects behind the rows.
// Apollo issues the same fetch for every signed-in account's client around
// launch — hence the per-client keying above. Completion arity is
// (NSArray *collection, NSError *error) (RedditKit's RDKArrayCompletionBlock).
%hook RDKClient

- (id)multiredditsWithCompletion:(void (^)(NSArray *collection, NSError *error))completion {
    if (!completion) return %orig;
    __weak typeof(self) weakClient = self;
    void (^wrapped)(NSArray *, NSError *) = ^(NSArray *collection, NSError *error) {
        id client = weakClient;
        if (client && [collection isKindOfClass:[NSArray class]] && collection.count > 0) {
            // The map is read from the main thread (didSelect / cellForRow),
            // so mutate it there too; completions aren't guaranteed on main.
            void (^store)(void) = ^{
                if (!sMultiredditsByClient) {
                    sMultiredditsByClient = [NSMapTable weakToStrongObjectsMapTable];
                }
                [sMultiredditsByClient setObject:collection forKey:client];
                ApolloLog(@"[MultiEdit] captured %lu multireddits for client %p%@",
                          (unsigned long)collection.count, client,
                          client == ApolloActiveAccountClient() ? @" (active)" : @"");
            };
            if ([NSThread isMainThread]) store();
            else dispatch_async(dispatch_get_main_queue(), store);
        }
        completion(collection, error);
    };
    return %orig(wrapped);
}

%end

// MARK: - Custom icon enforcement

// Apollo applies a multireddit row's icon (its first subreddit's avatar)
// through an asynchronous pipeline, so writing the custom icon once from
// cellForRow loses the race whenever the real avatar lands afterwards: the
// row flashes back to Apollo's icon (reported with the ApolloReborn robot).
// cellForRow instead TAGS the icon view with the custom-icon key, and this
// hook swaps every competing image assignment for the custom icon while the
// tag is present. Untagged image views (the entire rest of the app, and any
// multireddit row without a custom icon) pay one static BOOL read.
%hook UIImageView

- (void)setImage:(UIImage *)image {
    if (sMultiEditIconEnforcementNeeded) {
        NSString *iconKey = objc_getAssociatedObject(self, &kApolloMultiEditIconEnforceKey);
        if (iconKey.length > 0) {
            CGSize targetSize = (image && image.size.width >= 1.0) ? image.size : self.bounds.size;
            UIImage *display = ApolloMultiEditDisplayIconForKey(iconKey, targetSize);
            if (display && image != display) {
                %orig(display);
                return;
            }
        }
    }
    %orig;
}

%end

// MARK: - Subreddits list hooks

%group ApolloMultiEditList

%hook RedditListViewController

// Apollo leaves allowsSelectionDuringEditing off, so multireddit rows can't be
// tapped in Edit mode. Turn it on while editing (and back off afterwards, but
// only if we were the ones who enabled it).
- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    %orig;

    UITableView *tableView = ApolloMultiEditTableView((UIViewController *)self);
    if (!tableView) return;

    if (editing) {
        if (!tableView.allowsSelectionDuringEditing) {
            tableView.allowsSelectionDuringEditing = YES;
            objc_setAssociatedObject(tableView, &kApolloMultiEditSelectionEnabledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } else if ([objc_getAssociatedObject(tableView, &kApolloMultiEditSelectionEnabledKey) boolValue]) {
        tableView.allowsSelectionDuringEditing = NO;
        objc_setAssociatedObject(tableView, &kApolloMultiEditSelectionEnabledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// Edit-mode taps exist only because our setEditing: hook enabled selection.
// Never forward them to Apollo (its didSelect navigates and was written for
// browsing); a tap on a MULTIREDDITS row opens the rename/description editor,
// anything else just deselects.
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (![(UIViewController *)self isEditing]) {
        %orig;
        return;
    }

    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (![ApolloMultiEditSectionTitle(self, tableView, indexPath.section) isEqualToString:@"MULTIREDDITS"]) return;

    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    NSString *title = ApolloMultiEditTrim(ApolloMultiEditCellLabel(cell, "redditTitleLabel").text);
    RDKMultireddit *multireddit = ApolloMultiEditFindByTitle(title);
    if (!multireddit) {
        ApolloLog(@"[MultiEdit] no multireddit model matches tapped row '%@' (%lu candidate lists)",
                  title, (unsigned long)ApolloMultiEditCandidateLists().count);
        return;
    }
    if ([multireddit respondsToSelector:@selector(isEditable)] && ![multireddit isEditable]) {
        ApolloLog(@"[MultiEdit] '%@' is not editable (copied/unowned); ignoring tap", title);
        return;
    }
    [(RedditListViewController *)self apolloMultiEditPresentEditorFor:multireddit];
}

// A multireddit row's subtitle is the joined list of its subreddits. Swap in
// the user's description when one is set, or blank the line when the hide
// toggle is on; also apply any custom icon. Only rows Apollo gave a subtitle
// are touched (cheap first gate, hot path during scrolls): that skips the
// expanded-multireddit child rows (plain subreddit rows in the same section,
// no subtitle) and every other RedditListTableViewCell use.
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = %orig;
    sMultiEditListTable = tableView;

    Class cellClass = ApolloMultiEditListCellClass();
    if (!cellClass || ![cell isKindOfClass:cellClass]) return cell;

    UILabel *subtitleLabel = ApolloMultiEditCellLabel(cell, "subtitleLabel");
    if (subtitleLabel.text.length == 0) return cell;

    if (![ApolloMultiEditSectionTitle(self, tableView, indexPath.section) isEqualToString:@"MULTIREDDITS"]) return cell;

    NSString *title = ApolloMultiEditTrim(ApolloMultiEditCellLabel(cell, "redditTitleLabel").text);
    RDKMultireddit *multireddit = ApolloMultiEditFindByTitle(title);

    UIImageView *iconView = (UIImageView *)ApolloMultiEditObjectIvar(cell, "subredditIconImageView");
    if ([iconView isKindOfClass:[UIImageView class]]) {
        NSString *iconKey = multireddit ? ApolloMultiEditIconKey(multireddit) : nil;
        UIImage *stored = iconKey ? [[ApolloSubredditCustomIconCache sharedCache] cachedIconForSubreddit:iconKey] : nil;
        // Tag (or untag — cells are reused) the icon view for the enforcement
        // hook, then apply the icon at the stock icon's point size so the
        // intrinsic-size-driven layout doesn't change. Apollo's own async
        // avatar assignment for this row is swapped by the hook from here on.
        objc_setAssociatedObject(iconView, &kApolloMultiEditIconEnforceKey,
                                 stored ? iconKey : nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        if (stored) {
            sMultiEditIconEnforcementNeeded = YES;
            CGSize targetSize = iconView.image.size;
            if (targetSize.width < 1.0) targetSize = iconView.bounds.size;
            UIImage *customIcon = ApolloMultiEditDisplayIconForKey(iconKey, targetSize);
            if (customIcon) iconView.image = customIcon;
        }
    }

    if (sHideMultiredditDescriptions) {
        subtitleLabel.text = nil;
        return cell;
    }

    NSString *description = [multireddit respondsToSelector:@selector(descriptionMarkdown)]
        ? ApolloMultiEditTrim([multireddit descriptionMarkdown]) : nil;
    if (description.length > 0) {
        subtitleLabel.text = description;
    }
    return cell;
}

// MARK: Editor

%new
- (void)apolloMultiEditPresentEditorFor:(RDKMultireddit *)multireddit {
    [self apolloMultiEditPresentEditorFor:multireddit prefillName:nil prefillDescription:nil];
}

// prefillName/prefillDescription carry the editor's UNSAVED field contents
// across a round trip through the icon picker (or an icon removal), so
// typed-but-not-saved text is never lost; nil means "show the model's values".
%new
- (void)apolloMultiEditPresentEditorFor:(RDKMultireddit *)multireddit prefillName:(NSString *)prefillName prefillDescription:(NSString *)prefillDescription {
    NSString *currentName = [multireddit displayName].length > 0 ? [multireddit displayName] : [multireddit name];
    NSString *currentDescription = [multireddit respondsToSelector:@selector(descriptionMarkdown)]
        ? ([multireddit descriptionMarkdown] ?: @"") : @"";

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Edit Multireddit"
                                                                   message:@"Renaming keeps the multireddit's URL. With no description, the list of subreddits is shown instead."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = prefillName ?: currentName;
        textField.placeholder = @"Name";
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = prefillDescription ?: currentDescription;
        textField.placeholder = @"Description (optional)";
    }];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *newName = ApolloMultiEditTrim(alert.textFields.firstObject.text);
        if (newName.length == 0) newName = currentName; // a multireddit can't be nameless
        NSString *newDescription = ApolloMultiEditTrim(alert.textFields.lastObject.text) ?: @"";
        if ([newName isEqualToString:currentName] && [newDescription isEqualToString:currentDescription]) return;
        [weakSelf apolloMultiEditSave:multireddit name:newName descriptionText:newDescription];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Choose Custom Icon…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        // Alert actions dismiss the alert, so hand the unsaved field contents
        // to the picker flow — the editor reopens with them afterwards.
        [weakSelf apolloMultiEditPickIconFor:multireddit
                                 pendingName:alert.textFields.firstObject.text
                          pendingDescription:alert.textFields.lastObject.text];
    }]];
    if (ApolloMultiEditCustomIcon(multireddit)) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Remove Custom Icon" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            NSString *pendingName = alert.textFields.firstObject.text;
            NSString *pendingDescription = alert.textFields.lastObject.text;
            NSString *key = ApolloMultiEditIconKey(multireddit);
            if (key) [[ApolloSubredditCustomIconCache sharedCache] removeIconForSubreddit:key];
            [sMultiEditDisplayIconCache removeAllObjects];
            ApolloLog(@"[MultiEdit] removed custom icon for %@", [multireddit path]);
            // The reload unTAGs the icon views (no stored icon anymore), so
            // Apollo's own icon returns on the next configure pass.
            [(ApolloMultiEditTableView((UIViewController *)weakSelf) ?: sMultiEditListTable) reloadData];
            [weakSelf apolloMultiEditPresentEditorFor:multireddit prefillName:pendingName prefillDescription:pendingDescription];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [(UIViewController *)self presentViewController:alert animated:YES completion:nil];
}

%new
- (void)apolloMultiEditPickIconFor:(RDKMultireddit *)multireddit pendingName:(NSString *)pendingName pendingDescription:(NSString *)pendingDescription {
    PHPickerConfiguration *configuration = [[PHPickerConfiguration alloc] init];
    configuration.filter = [PHPickerFilter imagesFilter];
    configuration.selectionLimit = 1;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:configuration];
    picker.delegate = (id<PHPickerViewControllerDelegate>)self;
    NSMutableDictionary *context = [NSMutableDictionary dictionaryWithObject:multireddit forKey:@"multireddit"];
    if (pendingName) context[@"name"] = [pendingName copy];
    if (pendingDescription) context[@"description"] = [pendingDescription copy];
    objc_setAssociatedObject(picker, &kApolloMultiEditPickerTargetKey, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [(UIViewController *)self presentViewController:picker animated:YES completion:nil];
}

// PHPickerViewControllerDelegate — added to the list controller via %new; the
// picker dispatches by respondsToSelector:, so no compile-time conformance is
// needed beyond the cast at the assignment. Whatever happens (picked,
// cancelled, or a failed load), the editor reopens with the unsaved field
// contents it was carrying.
%new
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    NSDictionary *context = objc_getAssociatedObject(picker, &kApolloMultiEditPickerTargetKey);
    RDKMultireddit *multireddit = context[@"multireddit"];
    NSString *pendingName = context[@"name"];
    NSString *pendingDescription = context[@"description"];
    NSItemProvider *provider = results.firstObject.itemProvider;

    __weak typeof(self) weakSelf = self;
    void (^reopenEditor)(void) = ^{
        if (multireddit) {
            [weakSelf apolloMultiEditPresentEditorFor:multireddit prefillName:pendingName prefillDescription:pendingDescription];
        }
    };

    [picker dismissViewControllerAnimated:YES completion:^{
        if (!multireddit || ![provider canLoadObjectOfClass:[UIImage class]]) {
            reopenEditor(); // cancelled (or unloadable) — just restore the editor
            return;
        }
        [provider loadObjectOfClass:[UIImage class] completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([object isKindOfClass:[UIImage class]]) {
                    NSString *key = ApolloMultiEditIconKey(multireddit);
                    NSError *saveError = nil;
                    UIImage *scaled = ApolloMultiEditScaledIcon((UIImage *)object);
                    if (key && [[ApolloSubredditCustomIconCache sharedCache] saveIcon:scaled forSubreddit:key error:&saveError]) {
                        [sMultiEditDisplayIconCache removeAllObjects];
                        sMultiEditIconEnforcementNeeded = YES;
                        ApolloLog(@"[MultiEdit] saved custom icon for %@ (%.0fx%.0f)", [multireddit path], scaled.size.width, scaled.size.height);
                        [(ApolloMultiEditTableView((UIViewController *)weakSelf) ?: sMultiEditListTable) reloadData];
                    } else {
                        ApolloLog(@"[MultiEdit] icon save failed for %@: %@", [multireddit path], saveError);
                    }
                } else {
                    ApolloLog(@"[MultiEdit] icon load failed: %@", error);
                }
                reopenEditor();
            });
        }];
    }];
}

%new
- (void)apolloMultiEditSave:(RDKMultireddit *)multireddit name:(NSString *)newName descriptionText:(NSString *)newDescription {
    NSString *path = [multireddit path];
    id client = ApolloActiveAccountClient();
    if (path.length == 0 || ![client respondsToSelector:@selector(putPath:parameters:completion:)]) {
        ApolloLog(@"[MultiEdit] cannot save '%@': path=%@ client=%@", newName, path, client ? @"unsupported" : @"nil");
        [(RedditListViewController *)self apolloMultiEditShowError:@"Couldn't reach your account session. Please try again."];
        return;
    }

    // The website's edit-details request: PUT api/multi/<path> with a model
    // containing only the fields being edited — everything omitted (subreddits,
    // visibility, ...) is left untouched by Reddit.
    NSDictionary *model = @{ @"display_name": newName, @"description_md": newDescription ?: @"" };
    NSData *modelData = [NSJSONSerialization dataWithJSONObject:model options:0 error:nil];
    NSString *modelJSON = [[NSString alloc] initWithData:modelData encoding:NSUTF8StringEncoding];
    if (modelJSON.length == 0) return;

    NSString *requestPath = [@"api/multi" stringByAppendingString:path];
    NSDictionary *parameters = @{ @"model": modelJSON, @"multipath": path };
    ApolloLog(@"[MultiEdit] PUT %@ (rename to '%@', description %lu chars)",
              requestPath, newName, (unsigned long)newDescription.length);

    __weak typeof(self) weakSelf = self;
    // Arity verified in the binary: putPath's completion takes (response,
    // responseObject, error) — see the module header.
    void (^completion)(NSHTTPURLResponse *, id, NSError *) = ^(NSHTTPURLResponse *response, id responseObject, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                ApolloLog(@"[MultiEdit] save failed for %@: %@", path, error);
                [(RedditListViewController *)weakSelf apolloMultiEditShowError:@"Reddit rejected the change. Please try again."];
                return;
            }
            ApolloLog(@"[MultiEdit] save succeeded for %@ (HTTP %ld)", path, (long)response.statusCode);

            // Instant UI: update the local model and redraw, then let Apollo
            // refetch the authoritative list (same notification its own
            // add/remove-subreddit flows post).
            @try {
                [multireddit setValue:newName forKey:@"displayName"];
                [multireddit setValue:(newDescription ?: @"") forKey:@"descriptionMarkdown"];
            } @catch (NSException *exception) {
                ApolloLog(@"[MultiEdit] local model update skipped: %@", exception);
            }
            UITableView *tableView = ApolloMultiEditTableView((UIViewController *)weakSelf) ?: sMultiEditListTable;
            [tableView reloadData];
            [[NSNotificationCenter defaultCenter] postNotificationName:kApolloMultiredditsUpdatedNotification object:nil];
        });
    };
    ((id (*)(id, SEL, id, id, id))objc_msgSend)(client, @selector(putPath:parameters:completion:),
                                                requestPath, parameters, (id)completion);
}

%new
- (void)apolloMultiEditShowError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Couldn't Save Multireddit"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [(UIViewController *)self presentViewController:alert animated:YES completion:nil];
}

%end

%end // ApolloMultiEditList

// The enforcement tag rides the cell's icon image view, and cells are reused
// across sections — a stale tag would swap a custom icon onto whatever row
// inherits the cell (seen: a moderator row wearing a multireddit's icon).
// Clearing on reuse is the one reliable reset point; cellForRow then re-tags
// only the rows that actually have a custom icon.
%group ApolloMultiEditCell

%hook RedditListTableViewCell

- (void)prepareForReuse {
    %orig;
    UIImageView *iconView = (UIImageView *)ApolloMultiEditObjectIvar(self, "subredditIconImageView");
    if ([iconView isKindOfClass:[UIImageView class]]) {
        objc_setAssociatedObject(iconView, &kApolloMultiEditIconEnforceKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
}

%end

%end // ApolloMultiEditCell

%ctor {
    %init;

    Class listClass = objc_getClass("Apollo.RedditListViewController");
    if (!listClass) listClass = NSClassFromString(@"Apollo.RedditListViewController");
    if (listClass) {
        %init(ApolloMultiEditList, RedditListViewController = listClass);
        ApolloLog(@"[MultiEdit] list hooks installed on %@", NSStringFromClass(listClass));
    } else {
        ApolloLog(@"[MultiEdit] RedditListViewController class missing; multireddit editing unavailable");
    }

    Class cellClass = ApolloMultiEditListCellClass();
    if (cellClass) {
        %init(ApolloMultiEditCell, RedditListTableViewCell = cellClass);
    } else {
        ApolloLog(@"[MultiEdit] RedditListTableViewCell class missing; icon reuse guard unavailable");
    }

    // Re-render the list when Hide Multireddit Descriptions changes.
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloHideMultiredditDescriptionsChangedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        [sMultiEditListTable reloadData];
    }];
}
