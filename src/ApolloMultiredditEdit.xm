#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloFollowingSection.h"
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
// 3. CUSTOM ICONS — the editor also offers "Choose Icon" (and "Remove
//    Icon"): a photo picked from the library is stored in the
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
// - Rows are resolved by MODEL, never by index and never by title. The list
//   re-sorts its model arrays for display, so a visible row index means
//   nothing against the stored array (the exact lesson of the
//   MODERATOR-section fix in ApolloHideModSubreddits.xm) — and display_name
//   is editable independently of the path, so two multireddits can share a
//   title and a title match alone would resolve both rows to the first of
//   them. Apollo's cellForRowAt never messages the model (verified in the
//   binary — it renders from cached Swift storage), so a row is identified by
//   title AND, when a title is shared, by matching each candidate's own
//   subreddits against the subtitle Apollo rendered. The resolved model is
//   bound to the cell and the edit-mode tap reads it back from there, so the
//   tap never re-derives a multireddit from a title. A row that still can't
//   be pinned to one model is left alone rather than guessed at.
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
// The multireddit's member subreddits; Mantle's subredditsJSONTransformer
// decides the element type, so callers must handle both objects and strings.
- (NSArray *)subreddits;
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

// The RDKMultireddit a MULTIREDDITS row was built from, bound to the cell in
// cellForRow. display_name is user-editable and not unique, so it can never be
// the row's identity; this is.
static char kApolloMultiEditRowModelKey;

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
// While ApolloFollowingSection's section remap is engaged, the index paths
// reaching this module's hooks are already in Apollo's NATIVE section space,
// where the on-screen header walk (visible space) would lie — ask that module
// for the canonical native title instead.
static NSString *ApolloMultiEditSectionTitle(id delegate, UITableView *tableView, NSInteger section) {
    NSString *canonical = ApolloFollowingCanonicalTitleForNativeSection(tableView, section);
    if (canonical) return canonical.length > 0 ? canonical : nil;

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

static NSString *ApolloMultiEditDisplayTitle(RDKMultireddit *candidate) {
    NSString *display = nil;
    if ([candidate respondsToSelector:@selector(displayName)]) display = [candidate displayName];
    if (display.length == 0 && [candidate respondsToSelector:@selector(name)]) display = [candidate name];
    return display;
}

// Every model whose rendered title matches, deduplicated by path.
//
// display_name is user-editable and independent of the path, so it is NOT an
// identity: two multireddits can legitimately share one title while living at
// different paths. Callers must treat a >1 result as unresolved rather than
// taking the first — editing, describing or icon-tagging the wrong
// multireddit is worse than not acting.
static NSArray<RDKMultireddit *> *ApolloMultiEditFindAllByTitle(NSString *title) {
    if (title.length == 0) return @[];
    NSMutableArray<RDKMultireddit *> *matches = [NSMutableArray array];
    NSMutableSet<NSString *> *seenPaths = [NSMutableSet set];
    for (NSArray *list in ApolloMultiEditCandidateLists()) {
        for (RDKMultireddit *candidate in list) {
            NSString *display = ApolloMultiEditDisplayTitle(candidate);
            if (display.length == 0 || [display caseInsensitiveCompare:title] != NSOrderedSame) continue;
            // The same multireddit reached through two accounts' captured
            // lists is one multireddit, not an ambiguity.
            NSString *path = [candidate respondsToSelector:@selector(path)] ? [candidate path] : nil;
            if (path.length > 0) {
                if ([seenPaths containsObject:path]) continue;
                [seenPaths addObject:path];
            }
            [matches addObject:candidate];
        }
    }
    return matches;
}

// MARK: - Row identity
//
// Apollo's cell carries only strings (redditTitle/subtitle — see
// Headers/Swift/RedditListTableViewCell.swift), and its
// tableView(_:cellForRowAt:) never messages the model: disassembling it
// (0x10063dbb4, reached from -[… tableView:cellForRowAtIndexPath:] at
// 0x1006401f4) shows no objc_msgSend to displayName/name/path/subreddits
// anywhere in the function — it renders from cached Swift storage. So there is
// no configure-time model read to piggyback on; the row's identity has to be
// recovered from what Apollo rendered.
//
// The title alone cannot do it (that is the bug). The stock subtitle can: it
// is the row's subreddit list, and two multireddits sharing a display_name
// still differ in what they contain. So a same-titled group is disambiguated
// by matching each candidate's own subreddits against the rendered subtitle,
// and a group that still can't be told apart is left alone rather than
// resolved to whichever came first.

// A multireddit's subreddit names, whatever the transformed array holds
// (RDKSubreddit objects or plain strings).
static NSArray<NSString *> *ApolloMultiEditSubredditNames(RDKMultireddit *multireddit) {
    if (![multireddit respondsToSelector:@selector(subreddits)]) return @[];
    NSArray *subreddits = [multireddit subreddits];
    if (![subreddits isKindOfClass:[NSArray class]]) return @[];

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id entry in subreddits) {
        NSString *name = nil;
        if ([entry isKindOfClass:[NSString class]]) name = entry;
        else if ([entry respondsToSelector:@selector(name)]) name = [entry name];
        if (name.length == 0 && [entry respondsToSelector:@selector(displayName)]) name = [entry displayName];
        if (name.length > 0) [names addObject:name];
    }
    return names;
}

// How many of the multireddit's subreddits appear in the rendered subtitle.
static NSUInteger ApolloMultiEditSubtitleOverlap(RDKMultireddit *multireddit, NSString *subtitle) {
    if (subtitle.length == 0) return 0;
    NSUInteger matched = 0;
    for (NSString *name in ApolloMultiEditSubredditNames(multireddit)) {
        NSRange found = [subtitle rangeOfString:name options:NSCaseInsensitiveSearch];
        if (found.location != NSNotFound) matched++;
    }
    return matched;
}

// The multireddit a row was rendered from, or nil when it can't be pinned down.
//
// `subtitle` must be the subtitle APOLLO rendered (read before this module
// swaps in a description), since that is what identifies a row among
// same-titled multireddits.
static RDKMultireddit *ApolloMultiEditResolveRowModel(NSString *title, NSString *subtitle) {
    NSArray<RDKMultireddit *> *matches = ApolloMultiEditFindAllByTitle(title);
    if (matches.count <= 1) return matches.firstObject;

    // Same title, different multireddits: let their contents decide.
    RDKMultireddit *best = nil;
    NSUInteger bestOverlap = 0;
    BOOL tied = NO;
    for (RDKMultireddit *candidate in matches) {
        NSUInteger overlap = ApolloMultiEditSubtitleOverlap(candidate, subtitle);
        if (overlap > bestOverlap) { best = candidate; bestOverlap = overlap; tied = NO; }
        else if (overlap == bestOverlap && overlap > 0) tied = YES;
    }
    if (!best || tied) {
        // Indistinguishable from the rendered row. Editing, describing or
        // icon-tagging the wrong multireddit is worse than doing nothing.
        ApolloLog(@"[MultiEdit] '%@' matches %lu multireddits and the row's subreddits don't "
                  @"single one out — leaving this row alone",
                  title, (unsigned long)matches.count);
        return nil;
    }
    ApolloLog(@"[MultiEdit] '%@' is shared by %lu multireddits; row resolved to %@ by its subreddits",
              title, (unsigned long)matches.count,
              [best respondsToSelector:@selector(path)] ? [best path] : @"?");
    return best;
}

// MARK: - Capture Apollo's multireddit fetches

typedef void (^ApolloMultiEditRawResponseCompletion)(NSHTTPURLResponse *response,
                                                      id responseObject,
                                                      NSError *error);

static NSString *const kApolloMultiEditMinePath = @"api/multi/mine.json";
static NSString *const kApolloMultiEditResponseErrorDomain = @"ApolloReborn.MultiredditResponse";

typedef NS_ENUM(NSUInteger, ApolloMultiEditResponseShape) {
    ApolloMultiEditResponseShapeNone,
    ApolloMultiEditResponseShapeArray,
    ApolloMultiEditResponseShapeObject,
};

static NSString *ApolloMultiEditNormalizedPath(id path) {
    if (![path isKindOfClass:[NSString class]]) return nil;
    return [(NSString *)path hasPrefix:@"/"]
        ? [(NSString *)path substringFromIndex:1]
        : (NSString *)path;
}

// Every direct RDKObjectBuilder use in RedditKit's multireddit methods was
// traced in Apollo 1.15.11. Collection reads return an array of LabeledMulti
// envelopes. Individual reads and create/update/description writes return a
// single envelope. DELETE and api/multi/copy use non-model completion shapes,
// so deliberately leave those untouched.
static ApolloMultiEditResponseShape ApolloMultiEditResponseShapeForRequest(id method, id path) {
    NSString *normalizedMethod = [method isKindOfClass:[NSString class]]
        ? [(NSString *)method uppercaseString] : nil;
    NSString *normalizedPath = ApolloMultiEditNormalizedPath(path);
    if (normalizedMethod.length == 0 || normalizedPath.length == 0) {
        return ApolloMultiEditResponseShapeNone;
    }
    if ([normalizedMethod isEqualToString:@"DELETE"] ||
        [normalizedPath isEqualToString:@"api/multi/copy"]) {
        return ApolloMultiEditResponseShapeNone;
    }
    if ([normalizedMethod isEqualToString:@"GET"] &&
        [normalizedPath isEqualToString:kApolloMultiEditMinePath]) {
        return ApolloMultiEditResponseShapeArray;
    }
    if ([normalizedMethod isEqualToString:@"GET"] &&
        [normalizedPath hasPrefix:@"api/multi/user/"]) {
        NSArray<NSString *> *components = [normalizedPath componentsSeparatedByString:@"/"];
        if (components.count == 4) return ApolloMultiEditResponseShapeArray;
    }
    return [normalizedPath hasPrefix:@"api/multi/"]
        ? ApolloMultiEditResponseShapeObject
        : ApolloMultiEditResponseShapeNone;
}

static NSString *ApolloMultiEditExpectedKindForPath(NSString *path) {
    return [path hasSuffix:@"/description"]
        ? @"LabeledMultiDescription"
        : @"LabeledMulti";
}

static NSError *ApolloMultiEditMalformedResponseError(NSString *path, id responseObject,
                                                       NSUInteger invalidCount) {
    NSString *responseClass = responseObject ? NSStringFromClass([responseObject class]) : @"nil";
    return [NSError errorWithDomain:kApolloMultiEditResponseErrorDomain
                               code:858
                           userInfo:@{
        NSLocalizedDescriptionKey: @"Reddit returned malformed multireddit data.",
        @"path": path ?: @"unknown",
        @"responseClass": responseClass,
        @"invalidEntryCount": @(invalidCount),
    }];
}

static BOOL ApolloMultiEditCanBuildEnvelope(id entry, NSString *expectedKind,
                                             NSString **reasonOut) {
    if (reasonOut) *reasonOut = nil;
    if (![entry isKindOfClass:[NSDictionary class]]) {
        if (reasonOut) {
            *reasonOut = [NSString stringWithFormat:@"class:%@",
                entry ? NSStringFromClass([entry class]) : @"nil"];
        }
        return NO;
    }

    NSDictionary *envelope = (NSDictionary *)entry;
    id kind = envelope[@"kind"];
    if (![kind isKindOfClass:[NSString class]]) {
        if (reasonOut) *reasonOut = @"kind:not-string";
        return NO;
    }
    if (![kind isEqualToString:expectedKind]) {
        if (reasonOut) *reasonOut = @"kind:unexpected";
        return NO;
    }
    if (![envelope[@"data"] isKindOfClass:[NSDictionary class]]) {
        if (reasonOut) *reasonOut = @"data:not-dictionary";
        return NO;
    }

    // Apollo's array parsers do not nil-check objectFromJSON: before calling
    // addObject:. Validate the complete Mantle conversion now, under an
    // exception boundary, so both a thrown transformer and a nil model are
    // filtered before the private parser sees the envelope.
    @try {
        Class builderClass = objc_getClass("RDKObjectBuilder");
        SEL builderSelector = @selector(objectFromJSON:);
        if (!builderClass || ![builderClass respondsToSelector:builderSelector]) {
            if (reasonOut) *reasonOut = @"builder:unavailable";
            return NO;
        }
        id model = ((id (*)(id, SEL, id))objc_msgSend)(builderClass, builderSelector, envelope);
        Class expectedClass = [expectedKind isEqualToString:@"LabeledMultiDescription"]
            ? NSClassFromString(@"RDKMultiredditDescription")
            : NSClassFromString(@"RDKMultireddit");
        if (model && (!expectedClass || [model isKindOfClass:expectedClass])) return YES;
        if (reasonOut) *reasonOut = @"builder:nil-or-wrong-class";
    } @catch (__unused NSException *exception) {
        if (reasonOut) *reasonOut = @"builder:exception";
    }
    return NO;
}

// Apollo's native -multiredditsWithCompletion: assumes every element returned
// by /api/multi/mine is a dictionary. Its own RDKObjectBuilder notices a bad
// type and leaves a breadcrumb, but then continues into json[@"kind"] anyway.
// Issue #858 captured that exact path: one non-dictionary element reaches
// -objectForKeyedSubscript: and raises NSInvalidArgumentException at launch.
//
// Sanitize the raw endpoint payload before Apollo's private completion block
// enumerates it. A partly valid response keeps its valid models. A wholly
// malformed response becomes a failure instead of a successful empty result,
// so transient server/auth errors cannot make Apollo replace the user's in-
// memory multireddit list with an empty array.
static NSArray *ApolloMultiEditSanitizeArrayResponse(NSString *path, id responseObject,
                                                      NSError **sanitizationError) {
    if (sanitizationError) *sanitizationError = nil;
    if (![responseObject isKindOfClass:[NSArray class]]) {
        ApolloLog(@"[MultiEdit] %@ returned top-level %@ instead of NSArray; rejecting response",
                  path,
                  responseObject ? NSStringFromClass([responseObject class]) : @"nil");
        if (sanitizationError) {
            *sanitizationError = ApolloMultiEditMalformedResponseError(path, responseObject,
                                                                       responseObject ? 1 : 0);
        }
        return nil;
    }

    NSArray *responseArray = (NSArray *)responseObject;
    NSMutableArray *validEntries = [NSMutableArray arrayWithCapacity:responseArray.count];
    NSMutableDictionary<NSString *, NSNumber *> *invalidReasons = [NSMutableDictionary dictionary];
    for (id entry in responseArray) {
        NSString *reason = nil;
        if (ApolloMultiEditCanBuildEnvelope(entry, @"LabeledMulti", &reason)) {
            [validEntries addObject:entry];
        } else {
            reason = reason ?: @"unknown";
            invalidReasons[reason] = @([invalidReasons[reason] unsignedIntegerValue] + 1);
        }
    }

    if (validEntries.count == responseArray.count) return responseArray;

    NSUInteger invalidCount = responseArray.count - validEntries.count;
    ApolloLog(@"[MultiEdit] Filtered %lu malformed %@ entr%@ (%@); preserving %lu valid entr%@",
              (unsigned long)invalidCount,
              path,
              invalidCount == 1 ? @"y" : @"ies",
              invalidReasons,
              (unsigned long)validEntries.count,
              validEntries.count == 1 ? @"y" : @"ies");

    if (validEntries.count == 0 && responseArray.count > 0) {
        if (sanitizationError) {
            *sanitizationError = ApolloMultiEditMalformedResponseError(path, responseObject,
                                                                       invalidCount);
        }
        return nil;
    }
    return validEntries;
}

static NSDictionary *ApolloMultiEditSanitizeObjectResponse(NSString *path, id responseObject,
                                                            NSError **sanitizationError) {
    if (sanitizationError) *sanitizationError = nil;
    NSString *reason = nil;
    NSString *expectedKind = ApolloMultiEditExpectedKindForPath(path);
    if (ApolloMultiEditCanBuildEnvelope(responseObject, expectedKind, &reason)) {
        return responseObject;
    }

    ApolloLog(@"[MultiEdit] Rejected malformed %@ response (%@, top-level=%@)",
              path, reason ?: @"unknown",
              responseObject ? NSStringFromClass([responseObject class]) : @"nil");
    if (sanitizationError) {
        *sanitizationError = ApolloMultiEditMalformedResponseError(path, responseObject,
                                                                   responseObject ? 1 : 0);
    }
    return nil;
}

#if APOLLO_SIM_BUILD
// Deterministic issue #858 reproduction, simulator-only. simctl forwards
// SIMCTL_CHILD_* variables into the launched app after removing the prefix:
//
//   SIMCTL_CHILD_APOLLO_SIMULATE_ISSUE_858=filter scripts/run-in-sim.sh --logs
//       Injects several malformed envelope shapes and proves the sanitizer
//       keeps only model-buildable entries without crashing.
//
//   SIMCTL_CHILD_APOLLO_SIMULATE_ISSUE_858=crash scripts/run-in-sim.sh --logs
//       Injects the same elements but deliberately bypasses the sanitizer,
//       recreating Apollo's original NSInvalidArgumentException and stack.
//
// This code is compiled out of device/release builds.
static NSString *ApolloMultiEditIssue858SimulationMode(void) {
    NSString *mode = [NSProcessInfo processInfo].environment[@"APOLLO_SIMULATE_ISSUE_858"];
    return [mode isKindOfClass:[NSString class]] ? mode.lowercaseString : nil;
}

static id ApolloMultiEditIssue858InjectedResponse(id responseObject, NSString *mode) {
    if (![mode isEqualToString:@"filter"] && ![mode isEqualToString:@"crash"]) {
        return responseObject;
    }
    NSMutableArray *injected = [NSMutableArray array];
    [injected addObject:@"ApolloReborn issue #858 simulated malformed entry"];
    [injected addObject:[NSNull null]];
    [injected addObject:@{ @"kind": [NSNull null], @"data": @{} }];
    [injected addObject:@{ @"kind": @"Unknown", @"data": @{} }];
    [injected addObject:@{ @"kind": @"LabeledMulti", @"data": @"not-a-dictionary" }];
    if ([responseObject isKindOfClass:[NSArray class]]) {
        [injected addObjectsFromArray:(NSArray *)responseObject];
    }
    ApolloLog(@"[MultiEdit][Issue858] Injected five malformed envelopes into %@ response (mode=%@, original=%@)",
              kApolloMultiEditMinePath, mode,
              responseObject ? NSStringFromClass([responseObject class]) : @"nil");
    return injected;
}
#endif

// The Subreddits list populates its MULTIREDDITS section from this fetch, so
// wrapping the completion hands us the exact model objects behind the rows.
// Apollo issues the same fetch for every signed-in account's client around
// launch — hence the per-client keying above. Completion arity is
// (NSArray *collection, NSError *error) (RedditKit's RDKArrayCompletionBlock).
%hook RDKClient

- (id)taskWithMethod:(NSString *)method
    path:(NSString *)path
    parameters:(id)parameters
    completion:(ApolloMultiEditRawResponseCompletion)completion {
    ApolloMultiEditResponseShape shape = ApolloMultiEditResponseShapeForRequest(method, path);
    if (shape == ApolloMultiEditResponseShapeNone || !completion) return %orig;
    NSString *normalizedPath = ApolloMultiEditNormalizedPath(path);

    ApolloMultiEditRawResponseCompletion wrapped = ^(NSHTTPURLResponse *response,
                                                       id responseObject,
                                                       NSError *error) {
#if APOLLO_SIM_BUILD
        if ([normalizedPath isEqualToString:kApolloMultiEditMinePath]) {
            NSString *simulationMode = ApolloMultiEditIssue858SimulationMode();
            responseObject = ApolloMultiEditIssue858InjectedResponse(responseObject, simulationMode);
            if ([simulationMode isEqualToString:@"crash"]) {
                ApolloLog(@"[MultiEdit][Issue858] Deliberately bypassing sanitizer to reproduce the original crash");
                completion(response, responseObject, error);
                return;
            }
        }
#endif

        // Preserve RedditKit's normal network/error handling. Shape validation
        // applies only to a purported successful payload.
        if (error || !responseObject) {
            completion(response, responseObject, error);
            return;
        }

        NSError *sanitizationError = nil;
        id sanitized = shape == ApolloMultiEditResponseShapeArray
            ? ApolloMultiEditSanitizeArrayResponse(normalizedPath, responseObject, &sanitizationError)
            : ApolloMultiEditSanitizeObjectResponse(normalizedPath, responseObject, &sanitizationError);
        if (!sanitized) {
            completion(response, nil, error ?: sanitizationError);
            return;
        }
        completion(response, sanitized, error);
    };
    return %orig(method, path, parameters, wrapped);
}

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
    // The model this exact row was built from — never a fresh title match,
    // which would resolve two same-titled rows to the same multireddit and
    // edit the wrong one.
    RDKMultireddit *multireddit = objc_getAssociatedObject(cell, &kApolloMultiEditRowModelKey);
    if (!multireddit) {
        ApolloLog(@"[MultiEdit] tapped row '%@' has no bound multireddit model (%lu candidate lists)",
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
    // Apollo's own subtitle (its subreddit list), read before the description
    // swap below replaces it — it is what tells same-titled multireddits apart.
    RDKMultireddit *multireddit = ApolloMultiEditResolveRowModel(title, subtitleLabel.text);
    // Bind the model to the cell so the edit-mode tap acts on this row's
    // multireddit rather than re-deriving one from the (non-unique) title.
    // Cells are reused, so an unresolved row must clear the old binding.
    objc_setAssociatedObject(cell, &kApolloMultiEditRowModelKey, multireddit, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

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
    [alert addAction:[UIAlertAction actionWithTitle:@"Choose Icon" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        // Alert actions dismiss the alert, so hand the unsaved field contents
        // to the picker flow — the editor reopens with them afterwards.
        [weakSelf apolloMultiEditPickIconFor:multireddit
                                 pendingName:alert.textFields.firstObject.text
                          pendingDescription:alert.textFields.lastObject.text];
    }]];
    if (ApolloMultiEditCustomIcon(multireddit)) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Remove Icon" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
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
    // A recycled cell must not carry the previous row's multireddit — an
    // edit-mode tap landing before cellForRow rebinds would act on it.
    objc_setAssociatedObject(self, &kApolloMultiEditRowModelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
