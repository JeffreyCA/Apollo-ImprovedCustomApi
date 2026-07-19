#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloModernAwards.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
#import "ApolloWebSessionStore.h"

// Reddit retired both pieces that Apollo's original award screen used: the
// Apollo-hosted catalog and Reddit's coin-era /api/v2/gold/gild API. Reddit's
// replacement is implemented on its first-party web stack. Its item-scoped
// route owns the live catalog, free-award entitlements, current gold prices,
// eligibility checks, anonymous/message controls, purchase flow, leaderboard,
// and the official award animations.
//
// Embedding that route is deliberately preferable to copying a private GraphQL
// schema or periodically snapshotting its catalog. Apollo therefore submits
// through Reddit's current implementation and follows future catalog, price,
// and animation changes without another tweak release.

static const void *kApolloModernAwardControllerKey = &kApolloModernAwardControllerKey;
static const void *kApolloModernAwardNavigationBarKey = &kApolloModernAwardNavigationBarKey;
static NSString *const kApolloModernAwardCacheDefaultsKey = @"ApolloModernAwardCacheV1";

static NSString *ApolloModernAwardFullName(id thing);
static NSURL *ApolloModernAwardPermalink(id thing);

static NSObject *ApolloModernAwardStateLock(void) {
    static NSObject *lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static NSMutableDictionary<NSString *, NSArray<NSDictionary *> *> *ApolloModernAwardCache(void) {
    static NSMutableDictionary<NSString *, NSArray<NSDictionary *> *> *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary *stored = [[NSUserDefaults standardUserDefaults]
            dictionaryForKey:kApolloModernAwardCacheDefaultsKey];
        cache = [stored isKindOfClass:[NSDictionary class]] ? [stored mutableCopy] :
            [NSMutableDictionary dictionary];
    });
    return cache;
}

static NSHashTable *ApolloModernAwardKnownThings(void) {
    static NSHashTable *things = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ things = [NSHashTable weakObjectsHashTable]; });
    return things;
}

static id ApolloModernAwardObjectIvar(id object, const char *name) {
    if (!object || !name) return nil;
    Ivar ivar = class_getInstanceVariable([object class], name);
    if (!ivar) return nil;
    @try { return object_getIvar(object, ivar); }
    @catch (__unused NSException *exception) { return nil; }
}

// Apollo's post and comments screens are backed by ASTableView subclasses.
// Rebuilding only the visible tables after a successful award lets Apollo
// recreate its native PostInfoNode/AwardsNode immediately, while preserving
// the exact scroll position the user left beneath the transparent picker.
static void ApolloModernAwardReloadVisibleTables(UIView *rootView) {
    if (!rootView) return;
    if ([rootView isKindOfClass:[UITableView class]]) {
        UITableView *tableView = (UITableView *)rootView;
        if (tableView.hidden || tableView.alpha <= 0.01 || !tableView.window) return;
        CGPoint contentOffset = tableView.contentOffset;
        [UIView performWithoutAnimation:^{
            [tableView reloadData];
            [tableView layoutIfNeeded];
            [tableView setContentOffset:contentOffset animated:NO];
        }];

        // Texture may finish measuring the rebuilt award node on the next main
        // pass. Restore once more after that measurement so adding an award
        // never nudges a post or comment out from under the user.
        __weak UITableView *weakTableView = tableView;
        dispatch_async(dispatch_get_main_queue(), ^{
            UITableView *strongTableView = weakTableView;
            if (!strongTableView.window) return;
            [strongTableView setContentOffset:contentOffset animated:NO];
        });
        return;
    }
    for (UIView *subview in rootView.subviews) {
        ApolloModernAwardReloadVisibleTables(subview);
    }
}

static UIImage *ApolloModernAwardSnapshot(UIViewController *host) {
    UINavigationController *navigation = host.navigationController;
    id<UIViewControllerTransitionCoordinator> transition = host.transitionCoordinator;
    UIViewController *fromController =
        [transition viewControllerForKey:UITransitionContextFromViewControllerKey];
    // A long-press action menu can temporarily make UIKit's already-blurred
    // context-menu window key. Prefer the window that actually owns Apollo's
    // comments transition so the captured rows remain recognizable.
    UIView *view = fromController.view;
    if (!view) view = navigation.view.window ?: navigation.view;
    if (!view) {
        for (UIWindow *window in ApolloAllWindows()) {
            if (window.isKeyWindow && !window.hidden && window.alpha > 0.01) {
                view = window;
                break;
            }
        }
    }
    if (!view) {
        NSArray<UIViewController *> *stack = navigation.viewControllers;
        UIViewController *source = stack.count > 1 ? stack[stack.count - 2] : host.presentingViewController;
        view = source.view;
    }
    CGSize size = view.bounds.size;
    if (!view || CGSizeEqualToSize(size, CGSizeZero)) return nil;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [view drawViewHierarchyInRect:(CGRect){CGPointZero, size}
                   afterScreenUpdates:NO];
    }];
}

static NSURL *ApolloModernAwardValidatedIconURL(id raw) {
    if (![raw isKindOfClass:[NSString class]] || [(NSString *)raw length] > 2048) return nil;
    NSURL *URL = [NSURL URLWithString:raw];
    NSString *host = URL.host.lowercaseString;
    BOOL assetHost = [host isEqualToString:@"i.redd.it"] || [host hasSuffix:@".redd.it"] ||
        [host isEqualToString:@"redditstatic.com"] || [host hasSuffix:@".redditstatic.com"] ||
        [host isEqualToString:@"redditmedia.com"] || [host hasSuffix:@".redditmedia.com"];
    return ([URL.scheme.lowercaseString isEqualToString:@"https"] && assetHost) ? URL : nil;
}

static NSString *ApolloModernAwardSafeString(id raw, NSUInteger maximumLength) {
    if (![raw isKindOfClass:[NSString class]]) return nil;
    NSString *value = [(NSString *)raw stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return value.length > 0 && value.length <= maximumLength ? value : nil;
}

static NSDictionary *ApolloModernAwardRecord(NSDictionary *selection, NSInteger fallbackCount) {
    if (![selection isKindOfClass:[NSDictionary class]]) return nil;
    NSString *identifier = ApolloModernAwardSafeString(selection[@"id"], 128);
    NSString *name = ApolloModernAwardSafeString(selection[@"name"], 128) ?: @"Reddit Award";
    NSURL *iconURL = ApolloModernAwardValidatedIconURL(selection[@"icon"]);
    NSInteger count = [selection[@"count"] respondsToSelector:@selector(integerValue)] ?
        [selection[@"count"] integerValue] : fallbackCount;
    count = MAX(1, count);
    if (identifier.length == 0) {
        NSMutableString *slug = [NSMutableString string];
        NSCharacterSet *allowed = NSCharacterSet.alphanumericCharacterSet;
        for (NSUInteger index = 0; index < name.length && slug.length < 96; index++) {
            unichar character = [name characterAtIndex:index];
            if ([allowed characterIsMember:character]) [slug appendFormat:@"%C", character];
            else if (![slug hasSuffix:@"-"]) [slug appendString:@"-"];
        }
        identifier = [@"modern-" stringByAppendingString:slug.lowercaseString ?: @"award"];
    }
    NSMutableDictionary *record = [@{
        @"id": identifier,
        @"name": name,
        @"count": @(count),
    } mutableCopy];
    if (iconURL) record[@"icon"] = iconURL.absoluteString;
    return [record copy];
}

static BOOL ApolloModernAwardRecordMatchesAward(NSDictionary *record, id award) {
    NSString *recordID = record[@"id"];
    NSString *recordName = record[@"name"];
    NSString *awardID = nil;
    NSString *awardName = nil;
    @try {
        awardID = [award valueForKey:@"identifier"];
        awardName = [award valueForKey:@"name"];
    } @catch (__unused NSException *exception) {}
    return (recordID.length > 0 && [recordID isEqualToString:awardID]) ||
        (recordName.length > 0 &&
         [recordName caseInsensitiveCompare:awardName ?: @""] == NSOrderedSame);
}

static id ApolloModernAwardCreateAward(NSDictionary *record) {
    Class awardClass = NSClassFromString(@"RDKAward");
    id award = awardClass ? [awardClass new] : nil;
    if (!award) return nil;
    NSURL *iconURL = ApolloModernAwardValidatedIconURL(record[@"icon"]);
    @try {
        [award setValue:record[@"id"] forKey:@"identifier"];
        [award setValue:record[@"name"] ?: @"Reddit Award" forKey:@"name"];
        [award setValue:@(MAX(1, [record[@"count"] integerValue])) forKey:@"count"];
        [award setValue:@YES forKey:@"isEnabled"];
        if (iconURL) {
            [award setValue:iconURL forKey:@"largeIconURL"];
            [award setValue:@128 forKey:@"largeIconWidth"];
            Class iconClass = NSClassFromString(@"RDKAwardIcon");
            id icon = iconClass ? [iconClass new] : nil;
            if (icon) {
                [icon setValue:iconURL forKey:@"url"];
                [icon setValue:@128 forKey:@"width"];
                [icon setValue:@128 forKey:@"height"];
                [award setValue:@[icon] forKey:@"resizedIcons"];
            }
        }
    } @catch (NSException *exception) {
        ApolloLog(@"[ModernAwards] couldn't construct native award: %@", exception);
        return nil;
    }
    return award;
}

static NSArray *ApolloModernAwardMergedAwards(id thing, NSArray *incoming) {
    NSString *fullName = ApolloModernAwardFullName(thing);
    if (fullName.length == 0) return [incoming isKindOfClass:[NSArray class]] ? incoming : @[];
    NSArray<NSDictionary *> *records = nil;
    @synchronized (ApolloModernAwardStateLock()) {
        records = [ApolloModernAwardCache()[fullName] copy];
    }
    if (records.count == 0) return [incoming isKindOfClass:[NSArray class]] ? incoming : @[];
    ApolloLog(@"[ModernAwards] merging %lu cached award(s) into %@ (current=%lu)",
              (unsigned long)records.count, fullName,
              (unsigned long)([incoming isKindOfClass:[NSArray class]] ? incoming.count : 0));

    NSMutableArray *awards = [incoming isKindOfClass:[NSArray class]] ?
        [incoming mutableCopy] : [NSMutableArray array];
    for (NSDictionary *record in records) {
        id match = nil;
        for (id award in awards) {
            if (ApolloModernAwardRecordMatchesAward(record, award)) { match = award; break; }
        }
        if (!match) {
            id award = ApolloModernAwardCreateAward(record);
            if (award) [awards addObject:award];
            continue;
        }
        @try {
            NSInteger count = MAX([[match valueForKey:@"count"] integerValue],
                                  [record[@"count"] integerValue]);
            [match setValue:@(MAX(1, count)) forKey:@"count"];
            NSURL *iconURL = ApolloModernAwardValidatedIconURL(record[@"icon"]);
            if (iconURL && ![match valueForKey:@"largeIconURL"]) {
                [match setValue:iconURL forKey:@"largeIconURL"];
                [match setValue:@128 forKey:@"largeIconWidth"];
                Class iconClass = NSClassFromString(@"RDKAwardIcon");
                id icon = iconClass ? [iconClass new] : nil;
                if (icon) {
                    [icon setValue:iconURL forKey:@"url"];
                    [icon setValue:@128 forKey:@"width"];
                    [icon setValue:@128 forKey:@"height"];
                    [match setValue:@[icon] forKey:@"resizedIcons"];
                }
            }
        } @catch (__unused NSException *exception) {}
    }
    return [awards copy];
}

static void ApolloModernAwardRememberThing(id thing) {
    if (!thing || ApolloModernAwardFullName(thing).length == 0) return;
    @synchronized (ApolloModernAwardStateLock()) {
        [ApolloModernAwardKnownThings() addObject:thing];
    }
}

static void ApolloModernAwardApplyCachedToThing(id thing, BOOL notify) {
    if (!thing || !sModernAwardsEnabled) return;
    ApolloModernAwardRememberThing(thing);
    NSString *fullName = ApolloModernAwardFullName(thing);
    NSArray *records = nil;
    @synchronized (ApolloModernAwardStateLock()) {
        records = ApolloModernAwardCache()[fullName];
    }
    if (records.count == 0) return;
    NSArray *existing = nil;
    @try { existing = [thing valueForKey:@"awards"]; }
    @catch (__unused NSException *exception) {}
    NSArray *merged = ApolloModernAwardMergedAwards(thing, existing);
    @try { [thing setValue:merged forKey:@"awards"]; }
    @catch (NSException *exception) {
        ApolloLog(@"[ModernAwards] couldn't update Apollo award model: %@", exception);
        return;
    }
    ApolloLog(@"[ModernAwards] applied %lu native award(s) to %@",
              (unsigned long)merged.count, fullName);
    if (notify) {
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"com.christianselig.ModelObjectUpdated" object:thing];
    }
}

static void ApolloModernAwardRecordSelections(NSString *fullName, id awardedThing,
                                               NSArray<NSDictionary *> *selections,
                                               BOOL increment) {
    if (fullName.length == 0 || selections.count == 0) return;
    NSMutableArray<NSDictionary *> *records = nil;
    @synchronized (ApolloModernAwardStateLock()) {
        records = [ApolloModernAwardCache()[fullName] mutableCopy] ?: [NSMutableArray array];
        for (NSDictionary *selection in selections) {
            NSDictionary *candidate = ApolloModernAwardRecord(selection, 1);
            if (!candidate) continue;
            NSUInteger matchIndex = NSNotFound;
            for (NSUInteger index = 0; index < records.count; index++) {
                NSDictionary *record = records[index];
                BOOL sameID = [record[@"id"] isEqualToString:candidate[@"id"]];
                BOOL sameName = [record[@"name"] caseInsensitiveCompare:
                    candidate[@"name"] ?: @""] == NSOrderedSame;
                if (sameID || sameName) { matchIndex = index; break; }
            }
            NSInteger desiredCount = [candidate[@"count"] integerValue];
            if (matchIndex != NSNotFound) {
                NSDictionary *old = records[matchIndex];
                NSInteger oldCount = [old[@"count"] integerValue];
                desiredCount = MAX(desiredCount, increment ? oldCount + 1 : oldCount);
                if (!candidate[@"icon"] && old[@"icon"]) {
                    NSMutableDictionary *withIcon = [candidate mutableCopy];
                    withIcon[@"icon"] = old[@"icon"];
                    candidate = [withIcon copy];
                }
            }
            if (increment) {
                NSArray *currentAwards = nil;
                @try { currentAwards = [awardedThing valueForKey:@"awards"]; }
                @catch (__unused NSException *exception) {}
                for (id award in currentAwards) {
                    if (ApolloModernAwardRecordMatchesAward(candidate, award)) {
                        desiredCount = MAX(desiredCount,
                            [[award valueForKey:@"count"] integerValue] + 1);
                        break;
                    }
                }
            }
            NSMutableDictionary *stored = [candidate mutableCopy];
            stored[@"count"] = @(MAX(1, desiredCount));
            if (matchIndex == NSNotFound) [records addObject:[stored copy]];
            else records[matchIndex] = [stored copy];
        }
        ApolloModernAwardCache()[fullName] = [records copy];
        [[NSUserDefaults standardUserDefaults]
            setObject:[ApolloModernAwardCache() copy]
               forKey:kApolloModernAwardCacheDefaultsKey];
    }

    NSArray *knownThings = nil;
    @synchronized (ApolloModernAwardStateLock()) {
        knownThings = ApolloModernAwardKnownThings().allObjects;
    }
    NSMutableArray *matchingThings = [NSMutableArray array];
    if (awardedThing) [matchingThings addObject:awardedThing];
    for (id thing in knownThings) {
        if ([ApolloModernAwardFullName(thing) isEqualToString:fullName] &&
            ![matchingThings containsObject:thing]) {
            [matchingThings addObject:thing];
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        for (id thing in matchingThings) ApolloModernAwardApplyCachedToThing(thing, YES);
    });
}

static NSDictionary *ApolloModernAwardLegacyJSON(NSDictionary *record) {
    NSString *identifier = ApolloModernAwardSafeString(record[@"id"], 128);
    NSString *name = ApolloModernAwardSafeString(record[@"name"], 128) ?: @"Reddit Award";
    if (identifier.length == 0) return nil;
    NSMutableDictionary *JSON = [@{
        @"id": identifier,
        @"name": name,
        @"count": @(MAX(1, [record[@"count"] integerValue])),
        @"is_enabled": @YES,
    } mutableCopy];
    NSURL *iconURL = ApolloModernAwardValidatedIconURL(record[@"icon"]);
    if (iconURL) {
        JSON[@"icon_url"] = iconURL.absoluteString;
        JSON[@"icon_width"] = @128;
        JSON[@"resized_icons"] = @[@{
            @"url": iconURL.absoluteString,
            @"width": @128,
            @"height": @128,
        }];
    }
    return [JSON copy];
}

static BOOL ApolloModernAwardMergeIntoJSONNode(id node) {
    __block BOOL changed = NO;
    if ([node isKindOfClass:[NSMutableArray class]]) {
        for (id child in (NSArray *)node) {
            if (ApolloModernAwardMergeIntoJSONNode(child)) changed = YES;
        }
        return changed;
    }
    if (![node isKindOfClass:[NSMutableDictionary class]]) return NO;

    NSMutableDictionary *dictionary = node;
    NSString *kind = [dictionary[@"kind"] isKindOfClass:[NSString class]] ?
        dictionary[@"kind"] : nil;
    NSMutableDictionary *thingData =
        [dictionary[@"data"] isKindOfClass:[NSMutableDictionary class]] ?
            dictionary[@"data"] : nil;
    if (([kind isEqualToString:@"t1"] || [kind isEqualToString:@"t3"]) && thingData) {
        NSString *fullName = [thingData[@"name"] isKindOfClass:[NSString class]] ?
            thingData[@"name"] : nil;
        NSString *identifier = [thingData[@"id"] isKindOfClass:[NSString class]] ?
            thingData[@"id"] : nil;
        if (fullName.length == 0 && identifier.length > 0) {
            fullName = [NSString stringWithFormat:@"%@_%@", kind, identifier];
        }
        NSArray<NSDictionary *> *records = nil;
        @synchronized (ApolloModernAwardStateLock()) {
            records = [ApolloModernAwardCache()[fullName] copy];
        }
        if (records.count > 0) {
            NSMutableArray *awardings =
                [thingData[@"all_awardings"] isKindOfClass:[NSArray class]] ?
                    [thingData[@"all_awardings"] mutableCopy] : [NSMutableArray array];
            for (NSDictionary *record in records) {
                NSDictionary *legacy = ApolloModernAwardLegacyJSON(record);
                if (!legacy) continue;
                NSUInteger matchIndex = NSNotFound;
                for (NSUInteger index = 0; index < awardings.count; index++) {
                    NSDictionary *existing = [awardings[index] isKindOfClass:[NSDictionary class]] ?
                        awardings[index] : nil;
                    BOOL sameID = [existing[@"id"] isEqualToString:legacy[@"id"]];
                    BOOL sameName = [existing[@"name"] caseInsensitiveCompare:
                        legacy[@"name"] ?: @""] == NSOrderedSame;
                    if (sameID || sameName) { matchIndex = index; break; }
                }
                if (matchIndex == NSNotFound) {
                    [awardings addObject:legacy];
                } else {
                    NSMutableDictionary *merged = [awardings[matchIndex] mutableCopy];
                    [merged addEntriesFromDictionary:legacy];
                    NSInteger count = MAX([awardings[matchIndex][@"count"] integerValue],
                                          [legacy[@"count"] integerValue]);
                    merged[@"count"] = @(MAX(1, count));
                    awardings[matchIndex] = [merged copy];
                }
            }
            thingData[@"all_awardings"] = [awardings copy];
            ApolloLog(@"[ModernAwards] merged %lu cached award(s) into Reddit JSON for %@",
                      (unsigned long)records.count, fullName);
            changed = YES;
        }
    }

    for (id value in dictionary.allValues) {
        if (value == thingData) continue;
        if (ApolloModernAwardMergeIntoJSONNode(value)) changed = YES;
    }
    if (thingData) {
        for (id value in thingData.allValues) {
            if (ApolloModernAwardMergeIntoJSONNode(value)) changed = YES;
        }
    }
    return changed;
}

NSData *ApolloModernAwardsMergeCachedResponseData(NSURLResponse *response, NSData *data) {
    if (!sModernAwardsEnabled || ![data isKindOfClass:[NSData class]] || data.length == 0) {
        return data;
    }
    if (![response isKindOfClass:[NSHTTPURLResponse class]]) return data;
    NSURL *URL = ((NSHTTPURLResponse *)response).URL;
    NSString *host = URL.host.lowercaseString;
    if (![host isEqualToString:@"www.reddit.com"] &&
        ![host isEqualToString:@"oauth.reddit.com"]) return data;
    @synchronized (ApolloModernAwardStateLock()) {
        if (ApolloModernAwardCache().count == 0) return data;
    }
    id root = [NSJSONSerialization JSONObjectWithData:data
                                              options:NSJSONReadingMutableContainers
                                                error:NULL];
    if (!root || !ApolloModernAwardMergeIntoJSONNode(root)) return data;
    NSData *merged = [NSJSONSerialization dataWithJSONObject:root options:0 error:NULL];
    return merged ?: data;
}

static NSString *ApolloModernAwardFullName(id thing) {
    if (!thing) return nil;
    id value = [thing respondsToSelector:@selector(fullName)] ?
        ((id (*)(id, SEL))objc_msgSend)(thing, @selector(fullName)) : nil;
    NSString *fullName = [value isKindOfClass:[NSString class]] ?
        [(NSString *)value stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet] : nil;
    if (fullName.length == 0 && [thing respondsToSelector:@selector(identifier)]) {
        id rawIdentifier = ((id (*)(id, SEL))objc_msgSend)(thing, @selector(identifier));
        NSString *identifier = [rawIdentifier isKindOfClass:[NSString class]] ?
            [(NSString *)rawIdentifier stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet] : nil;
        id rawKind = [thing respondsToSelector:@selector(kindName)] ?
            ((id (*)(id, SEL))objc_msgSend)(thing, @selector(kindName)) : nil;
        NSString *kind = [rawKind isKindOfClass:[NSString class]] ?
            [(NSString *)rawKind lowercaseString] : nil;
        Class linkClass = NSClassFromString(@"RDKLink");
        Class commentClass = NSClassFromString(@"RDKComment");
        NSString *className = NSStringFromClass([thing class]).lowercaseString;
        BOOL looksLikeComment = (commentClass && [thing isKindOfClass:commentClass]) ||
            [className containsString:@"comment"] ||
            [thing respondsToSelector:@selector(linkID)] ||
            [thing respondsToSelector:@selector(parentID)];
        BOOL looksLikePost = (linkClass && [thing isKindOfClass:linkClass]) ||
            [className containsString:@"link"] || [className containsString:@"post"];

        if (identifier.length > 0 && ([kind isEqualToString:@"t1"] ||
                                      [kind isEqualToString:@"comment"] ||
                                      looksLikeComment)) {
            fullName = [@"t1_" stringByAppendingString:identifier];
        } else if (identifier.length > 0 && ([kind isEqualToString:@"t3"] ||
                                             [kind isEqualToString:@"link"] ||
                                             [kind isEqualToString:@"post"] ||
                                             looksLikePost)) {
            fullName = [@"t3_" stringByAppendingString:identifier];
        } else if (identifier.length > 0) {
            // API-key-free post models can arrive as a plain RDKThing: the id
            // is populated while both name and kind are nil. Comments retain
            // linkID/parentID, so an otherwise untyped award target is the
            // post represented by its Reddit identifier.
            fullName = [@"t3_" stringByAppendingString:identifier];
            ApolloLog(@"[ModernAwards] recovered untyped post identifier from %@",
                      NSStringFromClass([thing class]));
        }
    }

    // Some restored models lose the identifier mapping as well but retain
    // Reddit's permalink. Recover the post id from /comments/<id>/, or the
    // trailing comment id for a comment-shaped target.
    if (fullName.length == 0) {
        NSURL *permalink = ApolloModernAwardPermalink(thing);
        NSArray<NSString *> *components = permalink.pathComponents;
        NSUInteger commentsIndex = [components indexOfObject:@"comments"];
        if (commentsIndex != NSNotFound && commentsIndex + 1 < components.count) {
            NSString *postID = components[commentsIndex + 1].lowercaseString;
            NSString *className = NSStringFromClass([thing class]).lowercaseString;
            BOOL looksLikeComment = [className containsString:@"comment"] ||
                [thing respondsToSelector:@selector(linkID)] ||
                [thing respondsToSelector:@selector(parentID)];
            NSString *lastComponent = permalink.path.lastPathComponent.lowercaseString;
            if (looksLikeComment && lastComponent.length > 0 &&
                ![lastComponent isEqualToString:postID]) {
                fullName = [@"t1_" stringByAppendingString:lastComponent];
            } else if (postID.length > 0) {
                fullName = [@"t3_" stringByAppendingString:postID];
            }
        }
    }
    BOOL supportedPrefix = [fullName hasPrefix:@"t1_"] || [fullName hasPrefix:@"t3_"];
    if (!supportedPrefix || fullName.length <= 3) return nil;
    NSCharacterSet *invalid = [NSCharacterSet.alphanumericCharacterSet invertedSet];
    return [[fullName substringFromIndex:3] rangeOfCharacterFromSet:invalid].location == NSNotFound ?
        fullName : nil;
}

static NSURL *ApolloModernAwardPermalink(id thing) {
    id value = nil;
    if ([thing respondsToSelector:@selector(permalink)]) {
        value = ((id (*)(id, SEL))objc_msgSend)(thing, @selector(permalink));
    } else if ([thing respondsToSelector:@selector(urlWithContext:)]) {
        value = ((id (*)(id, SEL, long long))objc_msgSend)(
            thing, @selector(urlWithContext:), 0);
    }

    NSURL *URL = [value isKindOfClass:[NSURL class]] ? value : nil;
    if (URL && URL.host.length == 0 && [URL.relativeString hasPrefix:@"/"]) {
        URL = [[NSURL URLWithString:URL.relativeString
                     relativeToURL:[NSURL URLWithString:@"https://www.reddit.com"]]
            absoluteURL];
    }
    if (!URL && [value isKindOfClass:[NSString class]]) {
        NSString *string = (NSString *)value;
        URL = [string hasPrefix:@"/"] ?
            [NSURL URLWithString:string relativeToURL:[NSURL URLWithString:@"https://www.reddit.com"]] :
            [NSURL URLWithString:string];
        URL = URL.absoluteURL;
    }
    NSString *host = URL.host.lowercaseString;
    BOOL Reddit = [host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"];
    return ([URL.scheme.lowercaseString isEqualToString:@"https"] && Reddit) ? URL : nil;
}

static NSArray<NSHTTPCookie *> *ApolloModernAwardCookiesFromHeader(NSString *header) {
    NSMutableArray<NSHTTPCookie *> *cookies = [NSMutableArray array];
    for (NSString *rawPair in [header componentsSeparatedByString:@";"]) {
        NSString *pair = [rawPair stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSRange separator = [pair rangeOfString:@"="];
        if (separator.location == NSNotFound || separator.location == 0) continue;
        NSString *name = [pair substringToIndex:separator.location];
        NSString *value = [pair substringFromIndex:separator.location + 1];
        if (name.length == 0) continue;
        NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:@{
            NSHTTPCookieName: name,
            NSHTTPCookieValue: value,
            NSHTTPCookieDomain: @".reddit.com",
            NSHTTPCookiePath: @"/",
            NSHTTPCookieSecure: @"TRUE",
        }];
        if (cookie) [cookies addObject:cookie];
    }
    return cookies;
}

static NSString *ApolloModernAwardBridgeScript(void) {
    // Only lifecycle signals and the selected award's public catalog metadata
    // cross this bridge. Cookies, request bodies, anonymity, and messages remain
    // entirely inside Reddit's first-party implementation.
    return @"(function(){"
        "if(window.__apolloModernAwardsInstalled)return;"
        "window.__apolloModernAwardsInstalled=true;"
        "var send=function(type,extra){try{window.webkit.messageHandlers.apolloModernAwards.postMessage(Object.assign({type:type},extra||{}));}catch(_){}};"
        "var selected={},selectedNode=null;"
        "var allNodes=function(root){"
            "var output=[],queue=root?[root]:[],seen=new Set();"
            "while(queue.length&&output.length<800){var node=queue.shift();if(!node||seen.has(node))continue;seen.add(node);output.push(node);"
                "if(node.shadowRoot)queue.push(node.shadowRoot);"
                "if(node.children)for(var child of node.children)queue.push(child);"
            "}return output;"
        "};"
        "var redditAsset=function(raw){try{var value=String(raw||'').trim();if(!value)return '';"
            "var url=new URL(value,location.origin),host=url.hostname.toLowerCase();"
            "return url.protocol==='https:'&&(/(^|\\.)redd\\.it$/.test(host)||/(^|\\.)redditstatic\\.com$/.test(host)||/(^|\\.)redditmedia\\.com$/.test(host))?url.href:'';"
        "}catch(_){return '';}};"
        "var imageURL=function(root,path){var nodes=(path||[]).concat(allNodes(root));"
            "for(var node of nodes){if(!node)continue;var values=[node.currentSrc,node.src];"
                "if(node.getAttribute){values.push(node.getAttribute('src'),node.getAttribute('data-src'),node.getAttribute('icon-url'),node.getAttribute('image-url'),node.getAttribute('asset-url'));"
                    "var srcset=node.getAttribute('srcset');if(srcset)values.push(srcset.split(',')[0].trim().split(/\\s+/)[0]);}"
                "for(var value of values){var asset=redditAsset(value);if(asset)return asset;}"
                "try{var background=getComputedStyle(node).backgroundImage||'';var match=background.match(/url\\([\"']?([^\"')]+)[\"']?\\)/);var asset=redditAsset(match&&match[1]);if(asset)return asset;}catch(_){}"
            "}return '';"
        "};"
        "var labelFor=function(root,path){var nodes=[root].concat(path||[]).concat(allNodes(root));"
            "for(var node of nodes){if(!node)continue;var values=[];if(node.getAttribute)values.push(node.getAttribute('aria-label'),node.getAttribute('title'),node.getAttribute('data-award-name'),node.getAttribute('data-name'),node.getAttribute('alt'));"
                "values.push(node.alt);for(var value of values){value=String(value||'').trim();if(value&&value.length<=128&&!/^(award|select|image)$/i.test(value))return value;}"
            "}return '';"
        "};"
        "var idFor=function(root,path){var nodes=[root].concat(path||[]);for(var node of nodes){if(!node)continue;var values=[];"
            "if(node.getAttribute)values.push(node.getAttribute('data-award-id'),node.getAttribute('award-id'),node.getAttribute('data-id'),node.getAttribute('thing-id'));"
            "values.push(node.awardId,node.awardID);for(var value of values){value=String(value||'').trim();if(value&&value.length<=128)return value;}}return '';};"
        "var metadataFor=function(root,path){if(!root)return {};var id=idFor(root,path),name=labelFor(root,path),icon=imageURL(root,path),metadata={};"
            "if(id)metadata.id=id;if(name)metadata.name=name.replace(/^give\\s+/i,'').trim();if(icon)metadata.icon=icon;"
            "var text=String(root.innerText||root.textContent||'');var countMatch=text.match(/(?:^|\\s)(\\d{1,6})(?:\\s|$)/);if(countMatch)metadata.count=parseInt(countMatch[1],10)||1;return metadata;"
        "};"
        "window.__apolloModernAwardAllNodes=allNodes;window.__apolloModernAwardMetadataFor=metadataFor;"
        "var remember=function(root,path){if(!root)return;var metadata=metadataFor(root,path);"
            "if(metadata.id)selected.id=metadata.id;if(metadata.name)selected.name=metadata.name;if(metadata.icon)selected.icon=metadata.icon;selectedNode=root;"
        "};"
        "var refreshSelected=function(){if(selectedNode)remember(selectedNode,[]);var sheet=document.querySelector('award-selection-sheet');if(!sheet)return selected;"
            "var nodes=allNodes(sheet),active=nodes.find(function(node){return node&&node.getAttribute&&(node.getAttribute('aria-pressed')==='true'||node.getAttribute('aria-selected')==='true'||node.getAttribute('data-selected')==='true'||node.hasAttribute('selected'));});"
            "if(active)remember(active,[]);var buttons=nodes.filter(function(node){return node&&node.matches&&node.matches('button,[role=button]');});"
            "var submit=buttons.find(function(node){return /^give\\s+/i.test(String(node.innerText||node.textContent||'').trim());});"
            "if(submit){var submitName=String(submit.innerText||submit.textContent||'').trim().replace(/^give\\s+/i,'').trim();if(submitName&&submitName.length<=128)selected.name=submitName;}"
            "if(!selected.icon&&selected.name){var named=nodes.find(function(node){var label=labelFor(node,[]);return label&&label.toLowerCase().indexOf(selected.name.toLowerCase())!==-1&&imageURL(node,[]);});if(named)remember(named,[]);}"
            "return selected;"
        "};"
        "var operation=function(input,init){"
            "var url=String((input&&input.url)||input||'');"
            "var body=String((init&&init.body)||'');"
            "return /CreateAwardOrder|createAwardOrder/.test(url+' '+body);"
        "};"
        "var requestAwardID=function(init){var body=String((init&&init.body)||'');var match=body.match(/[\"'](?:awardId|award_id|awardID)[\"']\\s*:\\s*[\"']([^\"']{1,128})/i);return match?match[1]:'';};"
        "var originalFetch=window.fetch;"
        "if(originalFetch){window.fetch=function(input,init){"
            "var isAward=operation(input,init),requestID=isAward?requestAwardID(init):'',promise=originalFetch.apply(this,arguments);"
            "if(isAward){promise.then(function(response){"
                "if(response&&response.ok){refreshSelected();if(requestID&&!selected.id)selected.id=requestID;send('awarded',{selection:selected});}"
                "else send('awardError',{status:(response&&response.status)||0});"
            "}).catch(function(error){send('awardError',{message:String(error||'Request failed')});});}"
            "return promise;"
        "};}"
        "document.addEventListener('click',function(event){"
            "var target=event.target;"
            "var path=event.composedPath?event.composedPath():[target];"
            "var sheet=path.find(function(node){return node&&node.tagName==='AWARD-SELECTION-SHEET';})||document.querySelector('award-selection-sheet');"
            "var interactive=path.find(function(node){return node&&node.matches&&node.matches('button,[role=button],label,[data-award-id],[award-id]');});"
            "if(sheet&&interactive){var text=String(interactive.innerText||interactive.textContent||'').trim();var icon=imageURL(interactive,path);"
                "if(icon&&!/^give\\s+/i.test(text))remember(interactive,path);"
                "if(/^give\\s+/i.test(text)){var submitName=text.replace(/^give\\s+/i,'').trim();if(submitName&&submitName.length<=128)selected.name=submitName;refreshSelected();}"
            "}"
            "var showAll=path.find(function(node){return node.matches&&node.matches('award-selection-sheet button:not([data-award-id])');});"
            "if(showAll&&location.pathname.indexOf('/svc/shreddit/award-dialog/')===0){"
                "event.preventDefault();event.stopImmediatePropagation();"
                "send('showAll');return;"
            "}"
            "if(target&&target.closest&&target.closest('button[aria-label=\"Close\"]'))send('close');"
        "},true);"
        "document.addEventListener('award_content',function(){send('awarded',{selection:refreshSelected()});},true);"
        "document.addEventListener('award-content',function(){send('awarded',{selection:refreshSelected()});},true);"
        "var announced=false,signedOut=false;"
        "var inspect=function(){"
            "var dialog=document.querySelector('award-dialog[page=\"selection-sheet\"],award-dialog,#award-dialog,[dialog-id=\"award-dialog\"]');"
            "if(dialog&&!announced){announced=true;send('ready');}"
            "var text=(document.body&&document.body.innerText)||'';"
            "if(!signedOut&&/Already a redditor\\?|Log In to continue/i.test(text)){signedOut=true;send('signedOut');}"
        "};"
        "new MutationObserver(inspect).observe(document.documentElement,{childList:true,subtree:true});"
        "document.addEventListener('DOMContentLoaded',inspect);"
        "setTimeout(inspect,0);"
        "var missing=0;setInterval(function(){var dialog=document.querySelector('award-dialog[page=\"selection-sheet\"],award-dialog,#award-dialog,[dialog-id=\"award-dialog\"]');"
            "if(announced&&!dialog){missing++;if(missing===4)send('close');}else missing=0;},250);"
    "})();";
}

static NSString *ApolloModernAwardOpenFullPickerScript(NSString *fullName) {
    // Reddit's overflow component owns the supported transition into the full
    // selection sheet. Invoking that component keeps the catalog, eligibility,
    // balance, messaging, purchase flow, and animations entirely first-party.
    return [NSString stringWithFormat:@"(function(){"
        "if(window.__apolloModernAwardsOpeningFull)return;"
        "window.__apolloModernAwardsOpeningFull=true;"
        "var fullName='%@',started=false,ticks=0,targetFound=false,scrolled=false,controlFound=false,"
            "loaderFound=false,loaderRequested=false,loaderFailed=false,targetTag='',targetTags='',loaderNames='',"
            "routeFound=false,routeStarted=false,routeFailed=false,existingReported=false;"
        "var exactTarget=function(){"
            "var roots='shreddit-post,shreddit-comment,article,[data-testid=\\\"post-container\\\"]';"
            "var direct=[document.getElementById(fullName),document.getElementById(fullName.substring(3))];"
            "var escaped=CSS.escape(fullName);"
            "var selectors=['[thingid=\\\"'+escaped+'\\\"]','[thing-id=\\\"'+escaped+'\\\"]','[data-fullname=\\\"'+escaped+'\\\"]','[data-thing-id=\\\"'+escaped+'\\\"]'];"
            "for(var index=0;index<selectors.length;index++){try{direct.push(document.querySelector(selectors[index]));}catch(_){}}"
            "for(var candidate of direct){if(candidate){var root=candidate.matches(roots)?candidate:candidate.closest(roots);if(root)return root;}}"
            "return null;"
        "};"
        "var timer=setInterval(function(){"
            "ticks++;"
            "var full=document.querySelector('award-dialog[page=\\\"selection-sheet\\\"] award-selection-sheet');"
            "if(full){clearInterval(timer);"
                "var sheet=full.closest('rpl-dialog-sheet')||full.closest('[role=\"dialog\"]')||full;"
                "var rect=sheet.getBoundingClientRect();"
                "window.webkit.messageHandlers.apolloModernAwards.postMessage({"
                    "type:'fullReady',sheetTag:(sheet.tagName||'').toLowerCase(),"
                    "sheetLeft:rect.left,sheetTop:rect.top,sheetWidth:rect.width,sheetHeight:rect.height,"
                    "viewportWidth:window.innerWidth,viewportHeight:window.innerHeight"
                "});return;}"
            "if(!started){"
                "var target=exactTarget();"
                "targetFound=targetFound||!!target;"
                "if(target&&!targetTag){"
                    "targetTag=target.tagName||'';"
                    "targetTags=Array.from(new Set(Array.from(target.querySelectorAll('*')).map(function(node){"
                        "return (node.tagName||'').toLowerCase();"
                    "}).filter(function(tag){return /award|comment|faceplate|overflow/.test(tag);}))).slice(0,24).join(',');"
                "}"
                "if(target&&!existingReported&&window.__apolloModernAwardAllNodes&&window.__apolloModernAwardMetadataFor){"
                    "var existing=[],seenAssets=new Set();"
                    "for(var node of window.__apolloModernAwardAllNodes(target)){"
                        "if(!node||!node.getAttribute)continue;var descriptor=((node.tagName||'')+' '+(node.id||'')+' '+(node.className||'')+' '+(node.getAttribute('aria-label')||'')+' '+(node.getAttribute('data-testid')||'')).toLowerCase();"
                        "if(descriptor.indexOf('award')===-1)continue;var metadata=window.__apolloModernAwardMetadataFor(node,[]);"
                        "if(!metadata.icon||seenAssets.has(metadata.icon))continue;seenAssets.add(metadata.icon);existing.push(metadata);if(existing.length===12)break;"
                    "}"
                    "if(existing.length||ticks>10){existingReported=true;if(existing.length)window.webkit.messageHandlers.apolloModernAwards.postMessage({type:'existingAwards',awards:existing});}"
                "}"
                "if(target&&(!scrolled||ticks%%10===0)){"
                    "scrolled=true;"
                    "try{target.scrollIntoView({block:'center',inline:'nearest'});}catch(_){target.scrollIntoView();}"
                "}"
                // Both post and comment controls eventually call Reddit's
                // programmatic AwardDialog faceplate route. Activate that same
                // first-party route directly when present. This avoids relying
                // on a private controller property that Reddit removed from the
                // current full comment action row.
                "var routeParts=Array.from(document.querySelectorAll('faceplate-partial,faceplate-iframe'));"
                "var awardRoute=routeParts.find(function(node){"
                    "return /awarddialog|award-dialog/i.test((node.getAttribute('name')||'')+' '+(node.getAttribute('src')||''));"
                "});"
                "routeFound=routeFound||!!awardRoute;"
                "if(awardRoute&&typeof awardRoute.load==='function'){"
                    "var routeName=awardRoute.getAttribute('name')||'';"
                    "var routeLoader=Array.from(document.querySelectorAll('faceplate-loader')).find(function(loader){"
                        "return loader.getAttribute('name')===routeName;"
                    "});"
                    "if(!routeLoader||typeof routeLoader.load==='function'){"
                        "started=true;routeStarted=true;"
                        "try{"
                            "var routeURL=new URL(String(awardRoute.src||awardRoute.getAttribute('src')||''),location.origin);"
                            "routeURL.pathname=routeURL.pathname.replace(/(?:%%3A|:)thingId/i,fullName);"
                            "routeURL.searchParams.set('skipQuickGivePopover','true');"
                            "if(routeLoader)routeLoader.loading='programmatic';"
                            "awardRoute.loading='programmatic';"
                            "if('renderMode' in awardRoute)awardRoute.renderMode='contents';"
                            "awardRoute.src=routeURL.pathname+routeURL.search;"
                            "var routeLoads=[];"
                            "if(routeLoader)routeLoads.push(routeLoader.load());"
                            "routeLoads.push(awardRoute.load());"
                            "Promise.allSettled(routeLoads).then(function(results){"
                                "if(results.some(function(result){return result.status==='rejected';}))routeFailed=true;"
                            "});"
                        "}catch(_){started=false;routeFailed=true;}"
                    "}"
                "}"
                // Comment actions are wrapped in a lazy faceplate-loader. The
                // target permalink can sit several screens below a long post,
                // and a hidden WKWebView does not reliably trip its observer.
                // Reddit no longer gives this loader a stable name, so hydrate
                // only loaders physically contained by the exact t1 target.
                "if(!started&&target&&!loaderRequested){"
                    "var loaders=Array.from(target.querySelectorAll('faceplate-loader')).filter(function(loader){"
                        "return loader.closest('shreddit-comment')===target;"
                    "});"
                    "loaderFound=loaderFound||loaders.length>0;"
                    "loaderNames=loaders.map(function(loader){return loader.getAttribute('name')||'(unnamed)';}).join(',');"
                    "for(var loader of loaders){"
                        "if(typeof loader.load!=='function')continue;"
                        "loaderRequested=true;"
                        "try{"
                            "loader.loading='programmatic';"
                            "var loading=loader.load();"
                            "if(loading&&typeof loading.catch==='function')loading.catch(function(){loaderFailed=true;});"
                        "}catch(_){loaderFailed=true;}"
                    "}"
                "}"
                "var nodes=[];"
                "var collect=function(root){"
                    "if(!root||nodes.indexOf(root)!==-1)return;"
                    "nodes.push(root);"
                    "var children=root.querySelectorAll?Array.from(root.querySelectorAll('*')):[];"
                    "for(var child of children){"
                        "if(nodes.indexOf(child)===-1)nodes.push(child);"
                        "if(child.shadowRoot)collect(child.shadowRoot);"
                    "}"
                "};"
                "collect(target);"
                "var overflow=nodes.find(function(node){return typeof node.clickAwardButton==='function';});"
                "var hasController=function(node){"
                    "return !!node.awardController&&typeof node.awardController.activateDialog==='function';"
                "};"
                "var controllerMatches=function(node){"
                    "if(!hasController(node))return false;"
                    "var id='';"
                    "try{id=String(node.commentId||node.thingId||(node.getAttribute&&"
                        "(node.getAttribute('comment-id')||node.getAttribute('thing-id')||node.getAttribute('thingid')))||'');}catch(_){}"
                    "return id===fullName||id===fullName.substring(3);"
                "};"
                // A controller inside the exact target already has an
                // unambiguous owner even if Reddit does not expose its ID.
                "var commentControl=nodes.find(hasController);"
                // Reddit may portal the hydrated comment action component away
                // from its shreddit-comment. Search all light/shadow DOM only
                // for a controller whose own ID exactly matches our comment.
                "if(!commentControl&&fullName.indexOf('t1_')===0&&ticks%%5===0){"
                    "collect(document);"
                    "commentControl=nodes.find(controllerMatches);"
                "}"
                "controlFound=controlFound||!!overflow||!!commentControl;"
                "if(!started&&(overflow||commentControl)){"
                    "started=true;"
                    "try{"
                        "if(overflow)overflow.clickAwardButton({skipQuickGivePopover:true});"
                        "else commentControl.awardController.activateDialog({skipQuickGivePopover:true});"
                    "}"
                    "catch(_){clearInterval(timer);window.webkit.messageHandlers.apolloModernAwards.postMessage({type:'fullError'});return;}"
                "}"
            "}"
            "if(ticks>=150){"
                "clearInterval(timer);"
                "window.webkit.messageHandlers.apolloModernAwards.postMessage({"
                    "type:'fullError',targetFound:targetFound,scrolled:scrolled,controlFound:controlFound,"
                    "loaderFound:loaderFound,loaderRequested:loaderRequested,loaderFailed:loaderFailed,loaderNames:loaderNames,"
                    "targetTag:targetTag,targetTags:targetTags,routeFound:routeFound,routeStarted:routeStarted,routeFailed:routeFailed"
                "});"
            "}"
        "},200);"
    "})();", fullName];
}
static NSString *ApolloModernAwardAppearanceScript(void) {
    // The endpoint is a complete page whose only meaningful content is its
    // sheet. Remove desktop page padding so it fills Apollo's presentation.
    return @"(function(){"
        "var style=document.getElementById('apollo-modern-awards-style');"
        "if(!style){"
            "style=document.createElement('style');"
            "style.id='apollo-modern-awards-style';"
            "style.textContent='#shreddit-skip-link{display:none!important}'"
                "+'html,body,shreddit-app{margin:0!important;padding:0!important;min-height:100%!important;background:transparent!important}'"
                "+'rpl-dialog-sheet{--viewport-height:100dvh!important}';"
            "(document.head||document.documentElement).appendChild(style);"
        "}"
        "document.documentElement.style.colorScheme='light dark';"
    "})();";
}

@interface ApolloModernAwardErrorView : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UIButton *retryButton;
@property (nonatomic, strong) UIButton *closeButton;
@end

@implementation ApolloModernAwardErrorView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.backgroundColor = UIColor.systemBackgroundColor;

        _titleLabel = [UILabel new];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        _titleLabel.numberOfLines = 0;

        _detailLabel = [UILabel new];
        _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _detailLabel.textColor = UIColor.secondaryLabelColor;
        _detailLabel.textAlignment = NSTextAlignmentCenter;
        _detailLabel.numberOfLines = 0;

        _retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _retryButton.translatesAutoresizingMaskIntoConstraints = NO;
        _retryButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        [_retryButton setTitle:@"Try Again" forState:UIControlStateNormal];
        _retryButton.tintColor = ApolloThemeAccentColor() ?: self.tintColor ?: UIColor.systemBlueColor;
        _retryButton.contentEdgeInsets = UIEdgeInsetsMake(12.0, 22.0, 12.0, 22.0);
        _retryButton.layer.cornerRadius = 12.0;
        _retryButton.backgroundColor = [_retryButton.tintColor colorWithAlphaComponent:0.12];

        _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _closeButton.translatesAutoresizingMaskIntoConstraints = NO;
        _closeButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        [_closeButton setTitle:@"Close" forState:UIControlStateNormal];

        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
            @[_titleLabel, _detailLabel, _retryButton, _closeButton]];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        stack.axis = UILayoutConstraintAxisVertical;
        stack.alignment = UIStackViewAlignmentCenter;
        stack.spacing = 14.0;
        [self addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:28.0],
            [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-28.0],
            [_detailLabel.widthAnchor constraintLessThanOrEqualToConstant:430.0],
        ]];
    }
    return self;
}

@end

@interface ApolloModernAwardWebController : UIViewController
    <WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler>
@property (nonatomic, weak) UIViewController *hostController;
@property (nonatomic, copy) NSString *thingFullName;
@property (nonatomic, strong) NSURL *thingPermalink;
@property (nonatomic, strong) id thingToAward;
@property (nonatomic, strong) UIImage *backgroundSnapshot;
@property (nonatomic, strong) UIImageView *backgroundView;
@property (nonatomic, strong) UIView *dimmingView;
@property (nonatomic, strong) ApolloWebSessionEntry *session;
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIView *loadingView;
@property (nonatomic, strong) ApolloModernAwardErrorView *errorView;
@property (nonatomic, strong) UIButton *nativeCloseButton;
@property (nonatomic, copy) NSDictionary *pickerGeometry;
@property (nonatomic) BOOL receivedReady;
@property (nonatomic) BOOL receivedAward;
@property (nonatomic) BOOL showingFullPicker;
@property (nonatomic) BOOL overlayPresentation;
@property (nonatomic) NSUInteger loadGeneration;
- (instancetype)initWithThingFullName:(NSString *)fullName
                            permalink:(NSURL *)permalink
                                thing:(id)thing
                             snapshot:(UIImage *)snapshot
                                  host:(UIViewController *)host;
@end

@implementation ApolloModernAwardWebController

- (void)applyPickerGeometry {
    NSDictionary *geometry = self.pickerGeometry;
    if (!self.webView || geometry.count == 0) return;
    CGFloat viewportWidth = [geometry[@"viewportWidth"] doubleValue];
    CGFloat sheetLeft = [geometry[@"sheetLeft"] doubleValue];
    CGFloat sheetTop = [geometry[@"sheetTop"] doubleValue];
    CGFloat sheetWidth = [geometry[@"sheetWidth"] doubleValue];
    CGRect bounds = self.webView.bounds;
    if (viewportWidth <= 0.0 || sheetWidth <= 0.0 || CGRectIsEmpty(bounds)) return;

    // Reddit's page and its award sheet share one WKWebView. Clip that view to
    // only the live sheet, allowing Apollo's captured comments/post screen to
    // remain the visible backdrop without copying Reddit's catalog or UI.
    CGFloat scale = CGRectGetWidth(bounds) / viewportWidth;
    CGFloat top = MAX(0.0, sheetTop * scale - 2.0);
    CGFloat left = MAX(0.0, sheetLeft * scale - 16.0);
    CGFloat width = MIN(CGRectGetWidth(bounds) - left, sheetWidth * scale + 32.0);
    BOOL edgeToEdgeSheet = width >= CGRectGetWidth(bounds) * 0.85;
    if (edgeToEdgeSheet) {
        left = 0.0;
        width = CGRectGetWidth(bounds);
    }
    CGRect sheetRect = CGRectMake(left, top, width, MAX(0.0, CGRectGetHeight(bounds) - top));
    UIBezierPath *visiblePath = [UIBezierPath bezierPathWithRoundedRect:sheetRect
                                                           cornerRadius:20.0];
    if (edgeToEdgeSheet) {
        // Reddit draws its grabber just above the sheet's content box.
        CGRect handleRect = CGRectMake(CGRectGetMidX(bounds) - 24.0,
                                       MAX(0.0, top - 14.0), 48.0, 6.0);
        [visiblePath appendPath:[UIBezierPath bezierPathWithRoundedRect:handleRect
                                                           cornerRadius:3.0]];
    }
    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.frame = bounds;
    mask.path = visiblePath.CGPath;
    self.webView.layer.mask = mask;

    if (!self.nativeCloseButton) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.accessibilityLabel = @"Close";
        button.tintColor = UIColor.whiteColor;
        button.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.48];
        button.layer.cornerRadius = 18.0;
        UIImage *image = nil;
        if (@available(iOS 13.0, *)) {
            image = [UIImage systemImageNamed:@"xmark"
                             withConfiguration:[UIImageSymbolConfiguration
                                 configurationWithPointSize:16.0
                                                    weight:UIImageSymbolWeightSemibold]];
        }
        if (image) [button setImage:image forState:UIControlStateNormal];
        else [button setTitle:@"×" forState:UIControlStateNormal];
        [button addTarget:self action:@selector(dismissHost)
         forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:button];
        self.nativeCloseButton = button;
    }
    CGFloat closeX = edgeToEdgeSheet ? CGRectGetWidth(bounds) - 52.0 :
        CGRectGetMaxX(sheetRect) - 44.0;
    self.nativeCloseButton.frame = CGRectMake(closeX, top + 14.0, 36.0, 36.0);
    self.nativeCloseButton.hidden = NO;
    [self.view bringSubviewToFront:self.nativeCloseButton];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self applyPickerGeometry];
}

- (instancetype)initWithThingFullName:(NSString *)fullName
                            permalink:(NSURL *)permalink
                                thing:(id)thing
                             snapshot:(UIImage *)snapshot
                                  host:(UIViewController *)host {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _thingFullName = [fullName copy];
        _thingPermalink = permalink;
        _thingToAward = thing;
        _backgroundSnapshot = snapshot;
        _hostController = host;
        _session = ApolloActiveWebSession();
    }
    return self;
}

- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:CGRectZero];
    self.view.backgroundColor = UIColor.clearColor;
    self.backgroundView = [[UIImageView alloc] initWithImage:self.backgroundSnapshot];
    self.backgroundView.frame = self.view.bounds;
    self.backgroundView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backgroundView.contentMode = UIViewContentModeScaleAspectFill;
    [self.view addSubview:self.backgroundView];
    self.dimmingView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.dimmingView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.dimmingView.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.42];
    [self.view addSubview:self.dimmingView];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self buildLoadingView];
    if (!sModernAwardsEnabled) {
        [self showErrorTitle:@"Modern awards are turned off"
                      detail:@"Enable Modern Reddit Awards in Apollo Reborn settings to use this feature."];
        return;
    }
    if (self.session.cookieHeader.length == 0) {
        [self showErrorTitle:@"API-Key-Free sign-in required"
                      detail:@"Reddit only allows its new awards through a first-party web session. Sign in with Apollo Reborn's API-Key-Free option for this account, then try again."];
        ApolloLog(@"[ModernAwards] blocked %@: active account has no web session", self.thingFullName);
        return;
    }
    [self buildWebViewAndLoad];
}

- (void)buildLoadingView {
    UIActivityIndicatorViewStyle style = UIActivityIndicatorViewStyleWhiteLarge;
    if (@available(iOS 13.0, *)) style = UIActivityIndicatorViewStyleLarge;
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:style];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.color = UIColor.secondaryLabelColor;
    [self.spinner startAnimating];

    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"Loading Reddit awards...";
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    label.textColor = UIColor.secondaryLabelColor;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.spinner, label]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12.0;
    self.loadingView = stack;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];
}

- (void)discardWebView {
    self.webView.navigationDelegate = nil;
    self.webView.UIDelegate = nil;
    [self.webView stopLoading];
    [self.webView.configuration.userContentController
        removeScriptMessageHandlerForName:@"apolloModernAwards"];
    [self.webView removeFromSuperview];
    self.webView.layer.mask = nil;
    self.webView = nil;
    self.pickerGeometry = nil;
    self.nativeCloseButton.hidden = YES;
}

- (void)buildWebViewAndLoad {
    [self discardWebView];
    NSUInteger generation = ++self.loadGeneration;

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    // Isolate this account from other API-free users and any unrelated login
    // left in WebKit's shared website data store.
    configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    WKUserContentController *content = [WKUserContentController new];
    [content addScriptMessageHandler:self name:@"apolloModernAwards"];
    [content addUserScript:[[WKUserScript alloc]
        initWithSource:ApolloModernAwardBridgeScript()
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
        forMainFrameOnly:NO]];
    configuration.userContentController = content;

    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:configuration];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    self.webView.opaque = NO;
    self.webView.backgroundColor = UIColor.clearColor;
    self.webView.scrollView.backgroundColor = UIColor.clearColor;
    self.webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.webView.customUserAgent =
        @"Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
         "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
    self.webView.alpha = 0.0;
    // Snapshot + dimming layer are the backdrop; Reddit's isolated dialog must be above
    // them, while Apollo's loading/error chrome remains above the web surface.
    [self.view insertSubview:self.webView belowSubview:self.loadingView];

    NSArray<NSHTTPCookie *> *cookies =
        ApolloModernAwardCookiesFromHeader(self.session.cookieHeader);
    if (cookies.count == 0) {
        [self showErrorTitle:@"Reddit session unavailable"
                      detail:@"Apollo could not prepare this account's Reddit web session. Re-sign in with API-Key-Free and try again."];
        return;
    }

    NSURL *URL = self.thingPermalink;
    if (URL) {
        // A full-screen Apollo controller should open Reddit's complete picker,
        // not its tiny feed popover. The post/comment page owns the supported
        // transition into that picker and retains the success animation.
        self.showingFullPicker = YES;
        self.webView.customUserAgent =
            @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
             "(KHTML, like Gecko) Version/18.0 Safari/605.1.15";
    } else {
        NSString *escaped = [self.thingFullName
            stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
        URL = [NSURL URLWithString:[NSString stringWithFormat:
            @"https://www.reddit.com/svc/shreddit/award-dialog/%@", escaped]];
    }
    NSMutableURLRequest *request = [NSMutableURLRequest
        requestWithURL:URL
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
        timeoutInterval:35.0];
    [request setValue:self.session.cookieHeader forHTTPHeaderField:@"Cookie"];
    [request setValue:@"https://www.reddit.com/" forHTTPHeaderField:@"Referer"];

    dispatch_group_t group = dispatch_group_create();
    WKHTTPCookieStore *store = configuration.websiteDataStore.httpCookieStore;
    for (NSHTTPCookie *cookie in cookies) {
        dispatch_group_enter(group);
        [store setCookie:cookie completionHandler:^{ dispatch_group_leave(group); }];
    }

    __weak typeof(self) weakSelf = self;
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self || !self.webView) return;
        ApolloLog(@"[ModernAwards] loading %@ award flow for %@ with %lu cookies",
                  self.showingFullPicker ? @"full" : @"compact fallback",
                  self.thingFullName, (unsigned long)cookies.count);
        [self.webView loadRequest:request];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self || generation != self.loadGeneration || self.receivedReady ||
            !self.webView) return;
        ApolloLog(@"[ModernAwards] dialog readiness timed out for %@", self.thingFullName);
        [self showErrorTitle:@"Reddit awards did not finish loading"
                      detail:@"Check your connection and retry."];
    });
}

- (void)showErrorTitle:(NSString *)title detail:(NSString *)detail {
    [self.spinner stopAnimating];
    self.loadingView.hidden = YES;
    if (!self.errorView) {
        self.errorView = [[ApolloModernAwardErrorView alloc] initWithFrame:self.view.bounds];
        [self.errorView.retryButton addTarget:self
                                       action:@selector(retryTapped)
                             forControlEvents:UIControlEventTouchUpInside];
        [self.errorView.closeButton addTarget:self
                                       action:@selector(dismissHost)
                             forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:self.errorView];
    }
    self.errorView.titleLabel.text = title;
    self.errorView.detailLabel.text = detail;
    self.errorView.hidden = NO;
    [self.view bringSubviewToFront:self.errorView];
}

- (void)retryTapped {
    self.session = ApolloActiveWebSession();
    self.errorView.hidden = YES;
    self.loadingView.hidden = NO;
    [self.spinner startAnimating];
    self.receivedReady = NO;
    self.receivedAward = NO;
    self.showingFullPicker = NO;
    if (self.session.cookieHeader.length == 0) {
        [self showErrorTitle:@"API-Key-Free sign-in required"
                      detail:@"Sign in with Apollo Reborn's API-Key-Free option for this account, then return here and try again."];
        return;
    }
    [self buildWebViewAndLoad];
}

- (void)loadFullPicker {
    if (self.showingFullPicker) return;
    if (!self.thingPermalink) {
        ApolloLog(@"[ModernAwards] no Reddit permalink for %@", self.thingFullName);
        [self showErrorTitle:@"Couldn't open all awards"
                      detail:@"Reddit did not provide a usable link for this item. The free awards remain available from the first screen."];
        return;
    }

    self.showingFullPicker = YES;
    NSUInteger generation = ++self.loadGeneration;
    self.receivedReady = NO;
    self.webView.alpha = 0.0;
    self.webView.customUserAgent =
        @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
         "(KHTML, like Gecko) Version/18.0 Safari/605.1.15";
    self.loadingView.hidden = NO;
    [self.spinner startAnimating];
    NSMutableURLRequest *request = [NSMutableURLRequest
        requestWithURL:self.thingPermalink
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
        timeoutInterval:35.0];
    [request setValue:self.session.cookieHeader forHTTPHeaderField:@"Cookie"];
    [request setValue:@"https://www.reddit.com/" forHTTPHeaderField:@"Referer"];
    ApolloLog(@"[ModernAwards] opening full Reddit picker for %@ path=%@",
              self.thingFullName, self.thingPermalink.path ?: @"unknown");
    [self.webView loadRequest:request];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self || generation != self.loadGeneration || !self.showingFullPicker ||
            self.receivedReady || !self.webView) return;
        [self showErrorTitle:@"Reddit's full award picker did not open"
                      detail:@"Tap Try Again to reload the award flow."];
    });
}

- (void)revealWebView {
    if (self.receivedReady) return;
    self.receivedReady = YES;
    [self.spinner stopAnimating];
    self.loadingView.hidden = YES;
    self.errorView.hidden = YES;
    [UIView animateWithDuration:0.18 animations:^{ self.webView.alpha = 1.0; }];
    ApolloLog(@"[ModernAwards] dialog ready for %@", self.thingFullName);
}

- (void)dismissHost {
    UIViewController *host = self.hostController;
    if (self.overlayPresentation || self.presentingViewController) {
        NSString *fullName = [self.thingFullName copy];
        id thingToAward = self.thingToAward;
        [self dismissViewControllerAnimated:YES completion:^{
            ApolloModernAwardApplyCachedToThing(thingToAward, YES);
            NSArray *knownThings = nil;
            @synchronized (ApolloModernAwardStateLock()) {
                knownThings = ApolloModernAwardKnownThings().allObjects;
            }
            for (id thing in knownThings) {
                if ([ApolloModernAwardFullName(thing) isEqualToString:fullName]) {
                    ApolloModernAwardApplyCachedToThing(thing, YES);
                }
            }
            ApolloModernAwardReloadVisibleTables(host.view);
        }];
        return;
    }
    if (!host) return;
    if ([host respondsToSelector:@selector(cancelBarButtonItemTappedWithSender:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(
            host, @selector(cancelBarButtonItemTappedWithSender:), nil);
    } else if (host.navigationController.presentingViewController) {
        [host.navigationController dismissViewControllerAnimated:YES completion:nil];
    } else {
        [host dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:@"apolloModernAwards"] ||
        ![message.body isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *payload = (NSDictionary *)message.body;
    NSString *type = [payload[@"type"] isKindOfClass:[NSString class]] ?
        payload[@"type"] : @"";

    if ([type isEqualToString:@"ready"]) {
        if (!self.showingFullPicker) [self revealWebView];
    } else if ([type isEqualToString:@"showAll"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self loadFullPicker]; });
    } else if ([type isEqualToString:@"existingAwards"]) {
        NSArray *awards = [payload[@"awards"] isKindOfClass:[NSArray class]] ?
            payload[@"awards"] : @[];
        NSMutableArray<NSDictionary *> *safeAwards = [NSMutableArray array];
        NSUInteger iconCount = 0;
        for (id award in awards) {
            if (![award isKindOfClass:[NSDictionary class]]) continue;
            [safeAwards addObject:award];
            if (ApolloModernAwardValidatedIconURL(award[@"icon"])) iconCount++;
        }
        ApolloLog(@"[ModernAwards] recovered %lu existing award(s), %lu with icons for %@",
                  (unsigned long)safeAwards.count, (unsigned long)iconCount,
                  self.thingFullName);
        ApolloModernAwardRecordSelections(self.thingFullName, self.thingToAward,
                                           safeAwards, NO);
    } else if ([type isEqualToString:@"fullReady"]) {
        ApolloLog(@"[ModernAwards] full picker ready for %@ sheet=%@ rect=(%@,%@ %@x%@) viewport=%@x%@",
                  self.thingFullName,
                  payload[@"sheetTag"] ?: @"unknown",
                  payload[@"sheetLeft"] ?: @0,
                  payload[@"sheetTop"] ?: @0,
                  payload[@"sheetWidth"] ?: @0,
                  payload[@"sheetHeight"] ?: @0,
                  payload[@"viewportWidth"] ?: @0,
                  payload[@"viewportHeight"] ?: @0);
        self.pickerGeometry = payload;
        [self applyPickerGeometry];
        [self revealWebView];
    } else if ([type isEqualToString:@"fullError"]) {
        ApolloLog(@"[ModernAwards] full picker unavailable for %@ target=%@ tag=%@ children=%@ scrolled=%@ route=%@ started=%@ routeFailed=%@ control=%@ loader=%@ names=%@ requested=%@ failed=%@",
                  self.thingFullName,
                  payload[@"targetFound"] ?: @NO,
                  payload[@"targetTag"] ?: @"unknown",
                  payload[@"targetTags"] ?: @"unknown",
                  payload[@"scrolled"] ?: @NO,
                  payload[@"routeFound"] ?: @NO,
                  payload[@"routeStarted"] ?: @NO,
                  payload[@"routeFailed"] ?: @NO,
                  payload[@"controlFound"] ?: @NO,
                  payload[@"loaderFound"] ?: @NO,
                  payload[@"loaderNames"] ?: @"unknown",
                  payload[@"loaderRequested"] ?: @NO,
                  payload[@"loaderFailed"] ?: @NO);
        [self showErrorTitle:@"Couldn't open all Reddit awards"
                      detail:@"Reddit's page loaded, but its award control was unavailable. Tap Try Again to reload the flow."];
    } else if ([type isEqualToString:@"close"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self dismissHost]; });
    } else if ([type isEqualToString:@"signedOut"]) {
        ApolloLog(@"[ModernAwards] Reddit rejected stored session for %@", self.thingFullName);
        [self showErrorTitle:@"Reddit session expired"
                      detail:@"Re-sign in to this account with Apollo Reborn's API-Key-Free option, then try again."];
    } else if ([type isEqualToString:@"awarded"]) {
        if (self.receivedAward) return;
        self.receivedAward = YES;
        ApolloLog(@"[ModernAwards] Reddit accepted award for %@", self.thingFullName);
        NSDictionary *selection = [payload[@"selection"] isKindOfClass:[NSDictionary class]] ?
            payload[@"selection"] : @{};
        ApolloLog(@"[ModernAwards] selected metadata id=%@ name=%@ icon=%@",
                  [selection[@"id"] isKindOfClass:[NSString class]] && [selection[@"id"] length] > 0 ? @"yes" : @"no",
                  [selection[@"name"] isKindOfClass:[NSString class]] && [selection[@"name"] length] > 0 ? @"yes" : @"no",
                  ApolloModernAwardValidatedIconURL(selection[@"icon"]) ? @"yes" : @"no");
        ApolloModernAwardRecordSelections(self.thingFullName, self.thingToAward,
                                           selection.count > 0 ? @[selection] : @[], YES);
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"ApolloModernAwardGrantedNotification"
            object:self.thingToAward
            userInfo:@{@"thingFullName": self.thingFullName ?: @""}];
        // Leave Reddit's success animation visible briefly, then always return
        // to the exact Apollo controller and scroll position underneath.
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1600 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{ [weakSelf dismissHost]; });
    } else if ([type isEqualToString:@"awardError"]) {
        ApolloLog(@"[ModernAwards] Reddit award request failed for %@ status=%@",
                  self.thingFullName, payload[@"status"] ?: @"unknown");
    }
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    ApolloLog(@"[ModernAwards] main page finished host=%@", webView.URL.host ?: @"unknown");
    [webView evaluateJavaScript:ApolloModernAwardAppearanceScript() completionHandler:nil];
    if (self.showingFullPicker) {
        [webView evaluateJavaScript:ApolloModernAwardOpenFullPickerScript(self.thingFullName)
                  completionHandler:^(id result, NSError *error) {
            if (error) ApolloLog(@"[ModernAwards] full picker bootstrap failed: %@",
                                 error.localizedDescription);
        }];
    } else {
        [self revealWebView];
    }
}

- (void)webView:(WKWebView *)webView
    didFailProvisionalNavigation:(WKNavigation *)navigation
                       withError:(NSError *)error {
    if (error.code == NSURLErrorCancelled) return;
    ApolloLog(@"[ModernAwards] provisional navigation failed for %@: %@",
              self.thingFullName, error.localizedDescription);
    [self showErrorTitle:@"Couldn't load Reddit awards"
                  detail:error.localizedDescription ?: @"Check your connection and try again."];
}

- (void)webView:(WKWebView *)webView
    didFailNavigation:(WKNavigation *)navigation
             withError:(NSError *)error {
    if (error.code == NSURLErrorCancelled) return;
    ApolloLog(@"[ModernAwards] navigation failed for %@: %@",
              self.thingFullName, error.localizedDescription);
    [self showErrorTitle:@"Couldn't load Reddit awards"
                  detail:error.localizedDescription ?: @"Check your connection and try again."];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    ApolloLog(@"[ModernAwards] web process terminated for %@", self.thingFullName);
    [self showErrorTitle:@"Reddit awards stopped responding"
                  detail:@"Tap Try Again to reload the award picker."];
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *URL = navigationAction.request.URL;
    if (!URL || [URL.scheme isEqualToString:@"about"] ||
        [URL.scheme isEqualToString:@"data"]) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }

    NSString *host = URL.host.lowercaseString;
    BOOL redditHost =
        [host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"] ||
        [host isEqualToString:@"redditstatic.com"] || [host hasSuffix:@".redditstatic.com"];
    BOOL HTTPS = [URL.scheme.lowercaseString isEqualToString:@"https"];
    BOOL mainFrame = !navigationAction.targetFrame || navigationAction.targetFrame.isMainFrame;
    // Reddit's live picker embeds reCAPTCHA and payment resources. Keep HTTPS
    // subframes inside Reddit's page while still restricting the top frame.
    if (HTTPS && (redditHost || !mainFrame)) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }

    decisionHandler(WKNavigationActionPolicyCancel);
    if (HTTPS && navigationAction.navigationType == WKNavigationTypeLinkActivated) {
        ApolloPresentWebURLFromViewController(self, URL);
    }
}

- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)navigationAction
                    windowFeatures:(WKWindowFeatures *)windowFeatures {
    NSURL *URL = navigationAction.request.URL;
    NSString *host = URL.host.lowercaseString;
    BOOL redditHost =
        [host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"] ||
        [host isEqualToString:@"redditstatic.com"] || [host hasSuffix:@".redditstatic.com"];
    BOOL HTTPS = [URL.scheme.lowercaseString isEqualToString:@"https"];
    if (HTTPS && redditHost) {
        [webView loadRequest:navigationAction.request];
    } else if (HTTPS && navigationAction.navigationType == WKNavigationTypeLinkActivated) {
        ApolloPresentWebURLFromViewController(self, URL);
    }
    return nil;
}

- (void)dealloc {
    [self discardWebView];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    UIViewController *host = self.hostController;
    BOOL leaving = host.isBeingDismissed || host.isMovingFromParentViewController ||
        host.navigationController.isBeingDismissed;
    if (leaving) [self discardWebView];
}

@end

static ApolloModernAwardWebController *ApolloModernAwardControllerForHost(
    UIViewController *host) {
    return objc_getAssociatedObject(host, kApolloModernAwardControllerKey);
}

// Apollo's retired flow pushes AwardGiftingViewController onto the navigation
// stack. Replacing that controller's contents worked functionally, but UIKit
// still animated an entire screenshot-like page into view before Reddit's
// sheet loaded. Intercept only that one push and present transparently over the
// live source controller instead; the comments/post view never moves.
%hook UINavigationController

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    Class giftingClass = NSClassFromString(@"_TtC6Apollo26AwardGiftingViewController");
    if (sModernAwardsEnabled && giftingClass &&
        [viewController isKindOfClass:giftingClass]) {
        id thing = ApolloModernAwardObjectIvar(viewController, "thingToAward");
        NSString *fullName = ApolloModernAwardFullName(thing);
        UIViewController *source = self.topViewController;
        if (fullName.length > 0 && source && source.view.window) {
            ApolloModernAwardRememberThing(thing);
            ApolloModernAwardWebController *controller =
                [[ApolloModernAwardWebController alloc]
                    initWithThingFullName:fullName
                    permalink:ApolloModernAwardPermalink(thing)
                    thing:thing
                    snapshot:nil
                    host:source];
            controller.overlayPresentation = YES;
            controller.modalPresentationStyle = UIModalPresentationOverFullScreen;
            controller.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
            dispatch_async(dispatch_get_main_queue(), ^{
                [source presentViewController:controller animated:YES completion:nil];
            });
            ApolloLog(@"[ModernAwards] presented live overlay for %@", fullName);
            return;
        }
        ApolloLog(@"[ModernAwards] blocked legacy spinner: target %@ has no usable identifier",
                  NSStringFromClass([thing class]));
        UIViewController *presenter = source;
        if (!presenter.view.window && self.view.window) {
            presenter = self;
        }
        if (presenter.view.window) {
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:@"Couldn't identify this Reddit item"
                                 message:@"Reload the post or comments, then try Give Award again."
                          preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Close"
                                                      style:UIAlertActionStyleCancel
                                                    handler:nil]];
            dispatch_async(dispatch_get_main_queue(), ^{
                [presenter presentViewController:alert animated:YES completion:nil];
            });
        }
        // Reddit retired this controller, so never push it even if there is no
        // active presenter available for the explanatory alert.
        return;
    }
    %orig;
}

%end

%hook _TtC6Apollo26AwardGiftingViewController

- (void)viewDidLoad {
    // Capture the currently visible Apollo post/comments before the retired
    // gifting controller loads and replaces it in the navigation stack.
    UIImage *backgroundSnapshot = ApolloModernAwardSnapshot((UIViewController *)self);
    %orig;

    id thing = nil;
    @try {
        thing = MSHookIvar<id>(self, "thingToAward");
    } @catch (__unused id exception) {}
    NSString *fullName = ApolloModernAwardFullName(thing);
    if (fullName.length == 0) {
        ApolloLog(@"[ModernAwards] no usable identifier in fallback controller for %@",
                  NSStringFromClass([thing class]));
        @try {
            UIActivityIndicatorView *legacySpinner =
                MSHookIvar<UIActivityIndicatorView *>(self, "spinner");
            [legacySpinner stopAnimating];
            legacySpinner.hidden = YES;
            NSTimer *timer = MSHookIvar<NSTimer *>(self, "balanceRefreshingTimer");
            [timer invalidate];
        } @catch (__unused id exception) {}

        UIViewController *host = (UIViewController *)self;
        ApolloModernAwardErrorView *errorView =
            [[ApolloModernAwardErrorView alloc] initWithFrame:host.view.bounds];
        errorView.titleLabel.text = @"Couldn't identify this Reddit item";
        errorView.detailLabel.text =
            @"Reload the post or comments, then try Give Award again.";
        errorView.retryButton.hidden = YES;
        [errorView.closeButton addTarget:host
                                  action:@selector(cancelBarButtonItemTappedWithSender:)
                        forControlEvents:UIControlEventTouchUpInside];
        [host.view addSubview:errorView];
        return;
    }

    // Stop the retired screen from spinning or refreshing behind its
    // replacement. Its view/controller lifecycle remains Apollo-owned.
    @try {
        UIActivityIndicatorView *legacySpinner =
            MSHookIvar<UIActivityIndicatorView *>(self, "spinner");
        [legacySpinner stopAnimating];
        legacySpinner.hidden = YES;
        NSTimer *timer = MSHookIvar<NSTimer *>(self, "balanceRefreshingTimer");
        [timer invalidate];
    } @catch (__unused id exception) {}

    UIViewController *host = (UIViewController *)self;
    NSURL *permalink = ApolloModernAwardPermalink(thing);
    ApolloModernAwardWebController *controller =
        [[ApolloModernAwardWebController alloc] initWithThingFullName:fullName
                                                           permalink:permalink
                                                               thing:thing
                                                            snapshot:backgroundSnapshot
                                                                 host:host];
    objc_setAssociatedObject(host, kApolloModernAwardControllerKey,
                             controller, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [host addChildViewController:controller];
    controller.view.frame = host.view.bounds;
    controller.view.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [host.view addSubview:controller.view];
    [controller didMoveToParentViewController:host];
    ApolloLog(@"[ModernAwards] replaced legacy gifting screen for %@", fullName);
}

- (void)viewWillAppear:(BOOL)animated {
    ApolloModernAwardWebController *controller =
        ApolloModernAwardControllerForHost((UIViewController *)self);
    if (controller) {
        // viewWillAppear runs before the push transition, while the transition's
        // exact Apollo comments/post source controller is still available.
        UIImage *snapshot = ApolloModernAwardSnapshot((UIViewController *)self);
        if (snapshot) {
            controller.backgroundSnapshot = snapshot;
            controller.backgroundView.image = snapshot;
        }
    }
    %orig;
    if (!controller) return;
    UINavigationController *navigationController =
        ((UIViewController *)self).navigationController;
    if (!navigationController) return;
    objc_setAssociatedObject(self, kApolloModernAwardNavigationBarKey,
                             @(navigationController.navigationBarHidden),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [navigationController setNavigationBarHidden:YES animated:NO];
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloModernAwardWebController *controller =
        ApolloModernAwardControllerForHost((UIViewController *)self);
    if (!controller) return;
    controller.view.frame = ((UIViewController *)self).view.bounds;
    [((UIViewController *)self).view bringSubviewToFront:controller.view];
}

- (void)viewWillDisappear:(BOOL)animated {
    NSNumber *wasHidden =
        objc_getAssociatedObject(self, kApolloModernAwardNavigationBarKey);
    if (wasHidden && ((UIViewController *)self).navigationController) {
        [((UIViewController *)self).navigationController
            setNavigationBarHidden:wasHidden.boolValue animated:NO];
    }
    %orig;
}

%end

// Keep live model duplicates synchronized after a successful award. Initial
// model construction is handled above at the response-data boundary.
%hook RDKThing

- (void)setFullName:(NSString *)fullName {
    %orig;
    ApolloModernAwardRememberThing(self);
    // Mantle can assign `awards` before `fullName`. Merge synchronously as soon
    // as the identifier arrives so Apollo sees the award while it is building
    // PostInfoNode/AwardsNode, rather than after the header layout is complete.
    ApolloModernAwardApplyCachedToThing(self, NO);
}

- (void)setIdentifier:(NSString *)identifier {
    %orig;
    ApolloModernAwardRememberThing(self);
    // API-key-free JSON currently leaves RDKThing.fullName nil but still
    // supplies identifier. RDKLink/RDKComment class identity is sufficient to
    // reconstruct Reddit's stable t3_/t1_ fullname at this point.
    ApolloModernAwardApplyCachedToThing(self, NO);
}

%end

%hook RDKLink

- (void)setAwards:(NSArray *)awards {
    ApolloModernAwardRememberThing(self);
    %orig(ApolloModernAwardMergedAwards(self, awards));
}

%end

%hook RDKComment

- (void)setAwards:(NSArray *)awards {
    ApolloModernAwardRememberThing(self);
    %orig(ApolloModernAwardMergedAwards(self, awards));
}

%end

%hook _TtC6Apollo15CommentCellNode

- (void)awardsNodeTappedWithSender:(id)sender {
    if (!sModernAwardsEnabled || !sModernAwardsTapDetails) return;
    %orig;
}

%end

%hook _TtC6Apollo19CompactPostCellNode

- (void)awardsNodeTappedWithSender:(id)sender {
    if (!sModernAwardsEnabled || !sModernAwardsTapDetails) return;
    %orig;
}

%end

%hook _TtC6Apollo22CommentsHeaderCellNode

- (void)awardsNodeTappedWithSender:(id)sender {
    if (!sModernAwardsEnabled || !sModernAwardsTapDetails) return;
    %orig;
}

%end

%hook _TtC6Apollo17LargePostCellNode

- (void)awardsNodeTappedWithSender:(id)sender {
    if (!sModernAwardsEnabled || !sModernAwardsTapDetails) return;
    %orig;
}

%end

// Apollo already lays this node out in a dedicated award strip; returning an
// empty Texture spec removes that strip completely when the master is off.
struct ApolloModernAwardSizeRange { CGSize min; CGSize max; };

%hook _TtC6Apollo10AwardsNode

- (id)layoutSpecThatFits:(struct ApolloModernAwardSizeRange)constrainedSize {
    if (sModernAwardsEnabled) return %orig;
    Class layoutSpec = NSClassFromString(@"ASLayoutSpec");
    return layoutSpec ? [layoutSpec new] : %orig;
}

%end
