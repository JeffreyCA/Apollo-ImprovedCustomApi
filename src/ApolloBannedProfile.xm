#import "ApolloBannedProfile.h"
#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"
#import "ApolloUserProfileCache.h"
#import <objc/message.h>
#import <dlfcn.h>
#import <string.h>

static const void *kApolloBannedProfileOverlayKey = &kApolloBannedProfileOverlayKey;
static const void *kApolloBannedProfileOverlayBottomConstraintKey = &kApolloBannedProfileOverlayBottomConstraintKey;
static const void *kApolloBannedProfileRefreshScheduledKey = &kApolloBannedProfileRefreshScheduledKey;
static const void *kApolloBannedProfileCommentHintKey = &kApolloBannedProfileCommentHintKey;
static const void *kApolloBannedProfileLinkCardHintLoggedKey = &kApolloBannedProfileLinkCardHintLoggedKey;

static Class sProfileViewControllerClass = Nil;
static NSMutableSet<NSString *> *sListEndpoint403Usernames = nil;
static NSSet<NSString *> *sBlockedNavTitles = nil;

// Usernames whose banned overlay the user has manually dismissed. Persisted so
// the overlay never reappears for that account — the escape hatch for false
// positives (e.g. your own temporarily-suspended account flashing the overlay
// for a split second right after login, before RDKClient.currentUser resolves).
static NSString *const kApolloBannedProfileDismissedUsernamesDefaultsKey = @"ApolloBannedProfileDismissedUsernames";
static NSMutableSet<NSString *> *sDismissedUsernames = nil;

static void ApolloBannedProfileLoadDismissedUsernames(void) {
    if (sDismissedUsernames) return;
    sDismissedUsernames = [NSMutableSet set];
    NSArray *stored = [[NSUserDefaults standardUserDefaults] arrayForKey:kApolloBannedProfileDismissedUsernamesDefaultsKey];
    for (id entry in stored) {
        if ([entry isKindOfClass:[NSString class]]) [sDismissedUsernames addObject:entry];
    }
}

static NSString *ApolloBannedProfileNormalizedUsername(NSString *username) {
    if (![username isKindOfClass:[NSString class]]) return nil;
    NSString *clean = [username stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([clean hasPrefix:@"u/"] || [clean hasPrefix:@"U/"]) clean = [clean substringFromIndex:2];
    if (clean.length == 0) return nil;
    if ([clean isEqualToString:@"[deleted]"] || [clean isEqualToString:@"deleted"]) return nil;
    return clean;
}

static BOOL ApolloBannedProfileUsernamesMatch(NSString *left, NSString *right) {
    NSString *normalizedLeft = ApolloBannedProfileNormalizedUsername(left);
    NSString *normalizedRight = ApolloBannedProfileNormalizedUsername(right);
    if (normalizedLeft.length == 0 || normalizedRight.length == 0) return NO;
    return [normalizedLeft caseInsensitiveCompare:normalizedRight] == NSOrderedSame;
}

static BOOL ApolloBannedProfileOverlayDismissedForUsername(NSString *username) {
    NSString *key = ApolloBannedProfileNormalizedUsername(username);
    if (key.length == 0) return NO;
    ApolloBannedProfileLoadDismissedUsernames();
    return [sDismissedUsernames containsObject:key.lowercaseString];
}

static void ApolloBannedProfileMarkOverlayDismissedForUsername(NSString *username) {
    NSString *key = ApolloBannedProfileNormalizedUsername(username);
    if (key.length == 0) return;
    ApolloBannedProfileLoadDismissedUsernames();
    NSString *lower = key.lowercaseString;
    if ([sDismissedUsernames containsObject:lower]) return;
    [sDismissedUsernames addObject:lower];
    [[NSUserDefaults standardUserDefaults] setObject:sDismissedUsernames.allObjects
                                              forKey:kApolloBannedProfileDismissedUsernamesDefaultsKey];
    ApolloLog(@"[BannedProfile] user dismissed banned overlay for u/%@", key);
}

void ApolloBannedProfileClearDismissedOverlays(void) {
    ApolloBannedProfileLoadDismissedUsernames();
    [sDismissedUsernames removeAllObjects];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kApolloBannedProfileDismissedUsernamesDefaultsKey];
    [sListEndpoint403Usernames removeAllObjects];
    ApolloLog(@"[BannedProfile] cleared all dismissed banned overlays and 403 markers");
}

// A Swift class instance is a real heap pointer that is safe to read with
// object_getIvar and retain. Value types (String "SS", Bool, structs "V",
// enums "O", tuples) are stored inline; reading them as an object pointer and
// retaining the result crashes (the root cause of the viewDidLayoutSubviews
// crash on UserCommentsViewController's `username: String` ivar).
//
// ObjC ivars use the "@"/"#" encodings. Swift ivars use the mangled type name:
// classes end in "C" (or "CSg" when optional), e.g. "_$sSo10RDKCommentC" (an
// imported ObjC class) or "_$s6Apollo16ApolloButtonNodeC" (a pure Swift class).
static BOOL ApolloBannedProfileIvarEncodingIsRetainableObject(const char *encoding) {
    if (!encoding) return NO;
    if (encoding[0] == '@' || encoding[0] == '#') return YES;

    NSString *type = [NSString stringWithUTF8String:encoding];
    if (!type) return NO;
    if (![type containsString:@"$s"]) return NO;
    return [type hasSuffix:@"C"] || [type hasSuffix:@"CSg"];
}

static id ApolloBannedProfileObjectIvar(id object, NSString *name) {
    if (!object || name.length == 0) return nil;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;
        if (!ApolloBannedProfileIvarEncodingIsRetainableObject(ivar_getTypeEncoding(ivar))) return nil;
        @try {
            return object_getIvar(object, ivar);
        } @catch (__unused NSException *exception) {
            return nil;
        }
    }
    return nil;
}

// Decodes a Swift.String value held in two 64-bit words. Small strings (<= 15
// bytes) are stored inline; longer strings use a buffer pointer and are decoded
// via Swift's _bridgeToObjectiveC. Mirrors ApolloDecodeSwiftString in
// ApolloTranslation.xm.
static NSString *ApolloBannedProfileDecodeSwiftString(uint64_t w0, uint64_t w1) {
    uint8_t disc = (uint8_t)(w1 >> 56);
    if (disc >= 0xE0 && disc <= 0xEF) {
        NSUInteger len = disc - 0xE0;
        if (len == 0) return @"";

        char buf[16] = {0};
        memcpy(buf, &w0, 8);
        uint64_t w1clean = w1 & 0x00FFFFFFFFFFFFFFULL;
        memcpy(buf + 8, &w1clean, 7);
        return [[NSString alloc] initWithBytes:buf length:len encoding:NSUTF8StringEncoding];
    }

    typedef NSString *(*BridgeFn)(uint64_t, uint64_t);
    static BridgeFn sBridge = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sBridge = (BridgeFn)dlsym(RTLD_DEFAULT, "$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF");
    });

    return sBridge ? sBridge(w0, w1) : nil;
}

// Reads a Swift.String stored as an inline ivar. object_getIvar must NOT be
// used here: a String is a 16-byte value, not an object pointer.
static NSString *ApolloBannedProfileSwiftStringIvar(id object, NSString *name) {
    if (!object || name.length == 0) return nil;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;

        const char *encoding = ivar_getTypeEncoding(ivar);
        // Match non-optional Swift.String ("_$sSS"); skip anything else.
        if (!encoding || !strstr(encoding, "$sSS")) return nil;

        uint64_t words[2] = {0, 0};
        const uint8_t *storage = (const uint8_t *)(__bridge const void *)object + ivar_getOffset(ivar);
        memcpy(words, storage, sizeof(words));

        NSString *value = ApolloBannedProfileDecodeSwiftString(words[0], words[1]);
        return ApolloBannedProfileNormalizedUsername(value);
    }
    return nil;
}

static NSString *ApolloBannedProfileUsernameFromModelObject(id object) {
    if (!object) return nil;
    if ([object isKindOfClass:[NSString class]]) {
        return ApolloBannedProfileNormalizedUsername((NSString *)object);
    }
    NSArray<NSString *> *selectors = @[@"username", @"userName", @"name", @"displayName"];
    for (NSString *selectorName in selectors) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![object respondsToSelector:selector]) continue;
        id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
        if ([value isKindOfClass:[NSString class]]) {
            NSString *username = ApolloBannedProfileNormalizedUsername(value);
            if (username.length > 0) return username;
        }
    }
    return nil;
}

// Currently logged-in account username, or nil. Used to avoid blocking the
// user's own profile when their account is temporarily banned.
static NSString *ApolloBannedProfileCurrentLoggedInUsername(void) {
    Class clientClass = objc_getClass("RDKClient");
    SEL sharedClientSEL = @selector(sharedClient);
    if (!clientClass || ![clientClass respondsToSelector:sharedClientSEL]) return nil;

    id client = ((id (*)(id, SEL))objc_msgSend)(clientClass, sharedClientSEL);
    if (!client) return nil;

    SEL currentUserSEL = @selector(currentUser);
    if (![client respondsToSelector:currentUserSEL]) return nil;

    id currentUser = ((id (*)(id, SEL))objc_msgSend)(client, currentUserSEL);
    return ApolloBannedProfileUsernameFromModelObject(currentUser);
}

static BOOL ApolloBannedProfileIsCurrentLoggedInUser(NSString *username) {
    NSString *current = ApolloBannedProfileCurrentLoggedInUsername();
    if (current.length == 0) return NO;
    return ApolloBannedProfileUsernamesMatch(current, username);
}

static NSString *ApolloBannedProfileUsernameFromViewControllerDirect(UIViewController *viewController) {
    if (!viewController) return nil;

    NSArray<NSString *> *preferredIvars = @[@"username", @"userName", @"_username", @"account", @"user", @"userInfo", @"profile", @"viewModel"];
    for (NSString *ivarName in preferredIvars) {
        NSString *swiftString = ApolloBannedProfileSwiftStringIvar(viewController, ivarName);
        if (swiftString.length > 0) return swiftString;

        id value = ApolloBannedProfileObjectIvar(viewController, ivarName);
        if ([value isKindOfClass:[NSString class]]) {
            NSString *username = ApolloBannedProfileNormalizedUsername(value);
            if (username.length > 0) return username;
        }
        NSString *username = ApolloBannedProfileUsernameFromModelObject(value);
        if (username.length > 0) return username;
    }

    id titleValue = viewController.navigationItem.title ?: viewController.title;
    if ([titleValue isKindOfClass:[NSString class]]) {
        NSString *title = ApolloBannedProfileNormalizedUsername((NSString *)titleValue);
        if (title.length > 0 && ![sBlockedNavTitles containsObject:title.lowercaseString]) {
            if (![title containsString:@" "] && title.length <= 32) return title;
        }
    }

    return nil;
}

static NSString *ApolloBannedProfileUsernameFromViewController(UIViewController *viewController) {
    if (!viewController) return nil;

    NSString *direct = ApolloBannedProfileUsernameFromViewControllerDirect(viewController);
    if (direct.length > 0) return direct;

    for (UIViewController *controller in viewController.navigationController.viewControllers.reverseObjectEnumerator) {
        if (controller == viewController) continue;
        if (sProfileViewControllerClass && [controller isKindOfClass:sProfileViewControllerClass]) {
            NSString *username = ApolloBannedProfileUsernameFromViewControllerDirect(controller);
            if (username.length > 0) return username;
        }
        NSString *className = NSStringFromClass(controller.class);
        if ([className containsString:@"ProfileViewController"]) {
            NSString *username = ApolloBannedProfileUsernameFromViewControllerDirect(controller);
            if (username.length > 0) return username;
        }
    }

    UIBarButtonItem *backItem = viewController.navigationItem.backBarButtonItem;
    NSString *backTitle = backItem.title;
    if (backTitle.length == 0 && viewController.navigationController.viewControllers.count > 1) {
        UIViewController *previous = viewController.navigationController.viewControllers[viewController.navigationController.viewControllers.count - 2];
        id previousTitle = previous.navigationItem.title ?: previous.title;
        backTitle = [previousTitle isKindOfClass:[NSString class]] ? (NSString *)previousTitle : nil;
    }
    backTitle = ApolloBannedProfileNormalizedUsername(backTitle);
    if (backTitle.length > 0 && ![sBlockedNavTitles containsObject:backTitle.lowercaseString]) {
        return backTitle;
    }

    return nil;
}

static BOOL ApolloBannedProfileViewControllerLooksLikeProfileList(UIViewController *viewController) {
    NSString *className = NSStringFromClass(viewController.class);
    if ([className containsString:@"ProfileViewController"]) return YES;
    if (![className containsString:@"User"]) return NO;
    return [className containsString:@"Comment"] ||
        [className containsString:@"Post"] ||
        [className containsString:@"Overview"] ||
        [className containsString:@"Submitted"] ||
        [className containsString:@"Upvoted"] ||
        [className containsString:@"Downvoted"];
}

static NSArray *ApolloBannedProfileSubnodesForNode(id node) {
    if (![node respondsToSelector:@selector(subnodes)]) return nil;
    NSArray *(*msgSend)(id, SEL) = (NSArray *(*)(id, SEL))objc_msgSend;
    id subnodes = msgSend(node, @selector(subnodes));
    return [subnodes isKindOfClass:[NSArray class]] ? subnodes : nil;
}

static NSAttributedString *ApolloBannedProfileAttributedTextForNode(id node) {
    if (![node respondsToSelector:@selector(attributedText)]) return nil;
    NSAttributedString *(*msgSend)(id, SEL) = (NSAttributedString *(*)(id, SEL))objc_msgSend;
    id attributedText = msgSend(node, @selector(attributedText));
    return [attributedText isKindOfClass:[NSAttributedString class]] ? attributedText : nil;
}

static void ApolloBannedProfileSetAttributedTextForNode(id node, NSAttributedString *attributedText) {
    if (!node || !attributedText || ![node respondsToSelector:@selector(setAttributedText:)]) return;
    void (*msgSend)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
    msgSend(node, @selector(setAttributedText:), attributedText);
}

static void ApolloBannedProfileCollectTextNodes(id node, NSMutableSet<NSValue *> *visited, NSMutableArray *outNodes, NSUInteger depth) {
    if (!node || depth > 8) return;
    NSValue *key = [NSValue valueWithNonretainedObject:node];
    if ([visited containsObject:key]) return;
    [visited addObject:key];

    if (ApolloBannedProfileAttributedTextForNode(node).length > 0) {
        [outNodes addObject:node];
    }

    for (id subnode in ApolloBannedProfileSubnodesForNode(node)) {
        ApolloBannedProfileCollectTextNodes(subnode, visited, outNodes, depth + 1);
    }
}

static id ApolloBannedProfileBestAuthorTextNodeInRoot(id root, NSString *username) {
    if (!root || username.length == 0) return nil;
    NSMutableArray *nodes = [NSMutableArray array];
    ApolloBannedProfileCollectTextNodes(root, [NSMutableSet set], nodes, 0);

    NSString *lowerUsername = username.lowercaseString;
    id bestNode = nil;
    for (id node in nodes) {
        NSString *text = ApolloBannedProfileAttributedTextForNode(node).string;
        if (text.length == 0) continue;
        NSString *lowerText = text.lowercaseString;
        if ([lowerText containsString:lowerUsername] && ![lowerText containsString:@"has been banned"]) {
            bestNode = node;
            break;
        }
    }
    return bestNode;
}

static NSString *ApolloBannedProfileUsernameFromCommentCell(id cell) {
    if (!cell) return nil;
    NSString *username = ApolloBannedProfileUsernameFromModelObject(ApolloBannedProfileObjectIvar(cell, @"comment"));
    if (username.length > 0) return username;
    return ApolloBannedProfileUsernameFromModelObject(ApolloBannedProfileObjectIvar(cell, @"link"));
}

static void ApolloBannedProfileApplyCommentAuthorHint(id cell, NSString *username) {
    username = ApolloBannedProfileNormalizedUsername(username);
    if (!cell || username.length == 0) return;
    if ([objc_getAssociatedObject(cell, kApolloBannedProfileCommentHintKey) boolValue]) return;

    if (!ApolloBannedProfileCachedIsSuspended(username)) return;

    id authorRoot = ApolloBannedProfileObjectIvar(cell, @"authorNode");
    id textNode = ApolloBannedProfileBestAuthorTextNodeInRoot(authorRoot ?: cell, username);
    if (!textNode) return;

    NSAttributedString *existing = ApolloBannedProfileAttributedTextForNode(textNode);
    if (existing.length == 0) return;
    NSString *plain = existing.string;
    if ([plain containsString:@"has been banned"] || [plain containsString:@"(banned)"]) {
        objc_setAssociatedObject(cell, kApolloBannedProfileCommentHintKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    NSMutableAttributedString *updated = [existing mutableCopy];
    NSDictionary *suffixAttributes = @{
        NSForegroundColorAttributeName: [UIColor secondaryLabelColor],
        NSFontAttributeName: [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote],
    };
    [updated appendAttributedString:[[NSAttributedString alloc] initWithString:@"\nThis account has been banned" attributes:suffixAttributes]];
    ApolloBannedProfileSetAttributedTextForNode(textNode, updated);
    objc_setAssociatedObject(cell, kApolloBannedProfileCommentHintKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[BannedProfile] applied comment author hint for u/%@", username);
}

static void ApolloBannedProfileScheduleCommentAuthorHint(id cell, NSString *username, NSUInteger attempt) {
    __weak id weakCell = cell;
    NSTimeInterval delay = attempt == 0 ? 0.0 : (attempt == 1 ? 0.35 : 0.9);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id strongCell = weakCell;
        if (!strongCell) return;
        ApolloBannedProfileApplyCommentAuthorHint(strongCell, username);
        if (![objc_getAssociatedObject(strongCell, kApolloBannedProfileCommentHintKey) boolValue] && attempt + 1 < 3) {
            ApolloBannedProfileScheduleCommentAuthorHint(strongCell, username, attempt + 1);
        }
    });
}

void ApolloBannedProfileDecorateCommentCellIfNeeded(id cell) {
    NSString *username = ApolloBannedProfileUsernameFromCommentCell(cell);
    if (username.length == 0) return;

    if (ApolloBannedProfileCachedIsSuspended(username)) {
        ApolloBannedProfileScheduleCommentAuthorHint(cell, username, 0);
        return;
    }

    __weak id weakCell = cell;
    [[ApolloUserProfileCache sharedCache] requestInfoForUsername:username completion:^(ApolloUserProfileInfo *info) {
        if (!info.isSuspended) return;
        id strongCell = weakCell;
        if (strongCell) ApolloBannedProfileScheduleCommentAuthorHint(strongCell, username, 0);
    }];
}

static NSString *ApolloBannedProfileRedditUsernameFromProfileURL(NSURL *url) {
    if (!url) return nil;
    NSString *host = url.host.lowercaseString ?: @"";
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    if (![host isEqualToString:@"reddit.com"] && ![host hasSuffix:@".reddit.com"]) return nil;

    NSArray<NSString *> *parts = [url.path componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) [clean addObject:part];
    }
    if (clean.count < 2) return nil;

    NSString *prefix = clean[0].lowercaseString;
    if (![prefix isEqualToString:@"user"] && ![prefix isEqualToString:@"u"]) return nil;
    return ApolloBannedProfileNormalizedUsername(clean[1]);
}

static void ApolloBannedProfileTriggerLinkButtonRelayout(id linkButtonNode) {
    if (!linkButtonNode) return;

    id current = linkButtonNode;
    for (NSUInteger depth = 0; current && depth < 32; depth++) {
        SEL invalidate = @selector(invalidateCalculatedLayout);
        if ([current respondsToSelector:invalidate]) {
            ((void (*)(id, SEL))objc_msgSend)(current, invalidate);
        }

        SEL relayout = NSSelectorFromString(@"_u_setNeedsLayoutFromAbove");
        if ([current respondsToSelector:relayout]) {
            ((void (*)(id, SEL))objc_msgSend)(current, relayout);
        }

        SEL setNeedsLayout = @selector(setNeedsLayout);
        if ([current respondsToSelector:setNeedsLayout]) {
            ((void (*)(id, SEL))objc_msgSend)(current, setNeedsLayout);
        }

        if (![current respondsToSelector:@selector(supernode)]) break;
        id supernode = ((id (*)(id, SEL))objc_msgSend)(current, @selector(supernode));
        if (!supernode || supernode == current) break;
        current = supernode;
    }
}

id ApolloBannedProfileWrapLinkButtonSpecWithBannedHint(id linkButtonNode, id nativeSpec, NSString *username) {
    username = ApolloBannedProfileNormalizedUsername(username);
    if (!nativeSpec || username.length == 0) return nativeSpec;

    Class stackClass = NSClassFromString(@"ASStackLayoutSpec");
    Class textNodeClass = NSClassFromString(@"ASTextNode");
    if (!stackClass || !textNodeClass) return nativeSpec;

    id textNode = [[textNodeClass alloc] init];
    if ([textNode respondsToSelector:@selector(setMaximumNumberOfLines:)]) {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(textNode, @selector(setMaximumNumberOfLines:), 2);
    }

    UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    NSAttributedString *hintText = [[NSAttributedString alloc] initWithString:ApolloBannedProfileBannedDescriptionText()
                                                                    attributes:@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: [UIColor secondaryLabelColor],
    }];
    if ([textNode respondsToSelector:@selector(setAttributedText:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(textNode, @selector(setAttributedText:), hintText);
    }

    NSArray *children = @[nativeSpec, textNode];
    id stack = ((id (*)(id, SEL, unsigned char, CGFloat, unsigned char, unsigned char, id))objc_msgSend)(
        stackClass,
        @selector(stackLayoutSpecWithDirection:spacing:justifyContent:alignItems:children:),
        0,
        4.0,
        0,
        3,
        children);

    if (stack && linkButtonNode && ![objc_getAssociatedObject(linkButtonNode, kApolloBannedProfileLinkCardHintLoggedKey) boolValue]) {
        ApolloLog(@"[BannedProfile] applied link-card banned hint for u/%@", username);
        objc_setAssociatedObject(linkButtonNode, kApolloBannedProfileLinkCardHintLoggedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    return stack ?: nativeSpec;
}

static void ApolloBannedProfileRefreshLinkButtonsInTree(id object, NSHashTable *visited, NSString *username, NSUInteger depth) {
    if (!object || depth > 24 || [visited containsObject:object]) return;
    [visited addObject:object];

    NSString *className = NSStringFromClass([object class]);
    if ([className containsString:@"LinkButtonNode"]) {
        NSString *urlString = ApolloGetLinkButtonNodeURLString(object);
        NSURL *url = urlString.length > 0 ? [NSURL URLWithString:urlString] : nil;
        NSString *cardUsername = ApolloBannedProfileRedditUsernameFromProfileURL(url);
        if (cardUsername.length > 0 &&
            (username.length == 0 || ApolloBannedProfileUsernamesMatch(cardUsername, username))) {
            objc_setAssociatedObject(object, kApolloBannedProfileLinkCardHintLoggedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ApolloBannedProfileTriggerLinkButtonRelayout(object);
        }
    }

    for (id subnode in ApolloBannedProfileSubnodesForNode(object)) {
        ApolloBannedProfileRefreshLinkButtonsInTree(subnode, visited, username, depth + 1);
    }

    if ([object isKindOfClass:[UIView class]]) {
        for (UIView *subview in ((UIView *)object).subviews) {
            ApolloBannedProfileRefreshLinkButtonsInTree(subview, visited, username, depth + 1);
        }
    }
}

void ApolloBannedProfileRefreshLinkButtonsForUsername(NSString *username) {
    username = ApolloBannedProfileNormalizedUsername(username);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSHashTable *visited = [NSHashTable weakObjectsHashTable];
        for (UIWindow *window in ApolloAllWindows()) {
            ApolloBannedProfileRefreshLinkButtonsInTree(window.rootViewController.view, visited, username, 0);
            ApolloBannedProfileRefreshLinkButtonsInTree(window.rootViewController, visited, username, 0);
        }
    });
}

static void ApolloBannedProfileRefreshCommentCellsInTree(id object, NSHashTable *visited, NSString *username, NSUInteger depth) {
    if (!object || depth > 18 || [visited containsObject:object]) return;
    [visited addObject:object];

    NSString *className = NSStringFromClass([object class]);
    if ([className containsString:@"CommentCellNode"]) {
        NSString *cellUsername = ApolloBannedProfileUsernameFromCommentCell(object);
        if (cellUsername.length > 0 &&
            (username.length == 0 || ApolloBannedProfileUsernamesMatch(cellUsername, username))) {
            objc_setAssociatedObject(object, kApolloBannedProfileCommentHintKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ApolloBannedProfileDecorateCommentCellIfNeeded(object);
        }
    }

    for (id subnode in ApolloBannedProfileSubnodesForNode(object)) {
        ApolloBannedProfileRefreshCommentCellsInTree(subnode, visited, username, depth + 1);
    }

    if ([object isKindOfClass:[UIView class]]) {
        for (UIView *subview in ((UIView *)object).subviews) {
            ApolloBannedProfileRefreshCommentCellsInTree(subview, visited, username, depth + 1);
        }
    }
}

static void ApolloBannedProfileStopVisibleSpinnersInView(UIView *view) {
    if (!view || view.hidden || view.alpha < 0.01) return;
    if ([view isKindOfClass:[UIActivityIndicatorView class]]) {
        UIActivityIndicatorView *spinner = (UIActivityIndicatorView *)view;
        [spinner stopAnimating];
        spinner.hidden = YES;
        return;
    }
    for (UIView *subview in view.subviews) {
        ApolloBannedProfileStopVisibleSpinnersInView(subview);
    }
}

static Class ApolloBannedProfileHeaderViewClass(void) {
    static Class cls;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cls = NSClassFromString(@"ApolloProfileHeaderView");
    });
    return cls;
}

static void ApolloBannedProfileApplyHeaderSuspendedAppearance(UIViewController *viewController, BOOL suspended) {
    Class headerClass = ApolloBannedProfileHeaderViewClass();
    if (!headerClass || !viewController.view) return;

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:viewController.view];
    while (stack.count > 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if ([view isKindOfClass:headerClass]) {
            view.hidden = suspended;
            continue;
        }
        for (UIView *subview in view.subviews) [stack addObject:subview];
    }
}

static UIImage *sBannedProfileIconImage = nil;

UIImage *ApolloBannedProfileIconImage(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = ApolloBundledResourcePath(@"reddit-alien_banned", @"png");
        if (path.length > 0) {
            sBannedProfileIconImage = [UIImage imageWithContentsOfFile:path];
        }
        if (!sBannedProfileIconImage) {
            ApolloLog(@"[BannedProfile] failed to load banned icon asset");
        }
    });
    return sBannedProfileIconImage;
}

NSString *ApolloBannedProfileBannedDescriptionText(void) {
    return @"This account has been banned";
}

@interface ApolloBannedProfileOverlayView : UIView
@property(nonatomic, strong) UIImageView *iconView;
@property(nonatomic, strong) UILabel *messageLabel;
@property(nonatomic, strong) UIButton *dismissButton;
@property(nonatomic, copy) void (^dismissHandler)(void);
- (void)applyThemeAccentColor:(UIColor *)accent;
@end

@implementation ApolloBannedProfileOverlayView

- (instancetype)initWithMessage:(NSString *)message {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        self.backgroundColor = [UIColor systemBackgroundColor];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        _iconView = [[UIImageView alloc] initWithImage:ApolloBannedProfileIconImage()];
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
        _iconView.contentMode = UIViewContentModeScaleAspectFit;

        _messageLabel = [[UILabel alloc] init];
        _messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _messageLabel.text = message;
        _messageLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _messageLabel.textColor = [UIColor labelColor];
        _messageLabel.textAlignment = NSTextAlignmentCenter;
        _messageLabel.numberOfLines = 0;
        _messageLabel.adjustsFontForContentSizeCategory = YES;

        _dismissButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _dismissButton.translatesAutoresizingMaskIntoConstraints = NO;
        [_dismissButton setTitle:@"Dismiss Overlay" forState:UIControlStateNormal];
        _dismissButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        _dismissButton.titleLabel.adjustsFontForContentSizeCategory = YES;
        [_dismissButton addTarget:self action:@selector(handleDismissTapped) forControlEvents:UIControlEventTouchUpInside];

        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_iconView, _messageLabel, _dismissButton]];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 16.0;
        stack.alignment = UIStackViewAlignmentCenter;
        [stack setCustomSpacing:24.0 afterView:_messageLabel];
        [self addSubview:stack];

        [NSLayoutConstraint activateConstraints:@[
            [stack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor constant:-24.0],
            [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:24.0],
            [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-24.0],
            [_iconView.widthAnchor constraintEqualToConstant:96.0],
            [_iconView.heightAnchor constraintEqualToConstant:96.0],
        ]];
    }
    return self;
}

// Apollo applies its accent color directly to views rather than via an
// inheritable window tint, so adopt the accent resolved from the host profile's
// chrome instead of the UIKit-default tint. Background stays the solid default.
- (void)applyThemeAccentColor:(UIColor *)accent {
    if (accent) {
        self.tintColor = accent;
        self.dismissButton.tintColor = accent;
        [self.dismissButton setTitleColor:accent forState:UIControlStateNormal];
    }
}

- (void)handleDismissTapped {
    if (self.dismissHandler) self.dismissHandler();
}

@end

// Resolves the active Apollo theme's accent color from the host profile's chrome.
// Theme accent (custom or stock Apollo theme); view tint as a last resort.
static UIColor *ApolloBannedProfileResolveAccentColor(UIViewController *viewController) {
    return ApolloThemeAccentColor() ?: viewController.view.tintColor ?: [UIColor systemBlueColor];
}

NSString *ApolloBannedProfileMessageForUsername(NSString *username) {
    NSString *clean = ApolloBannedProfileNormalizedUsername(username) ?: @"username";
    return [NSString stringWithFormat:@"u/%@ has been banned", clean];
}

BOOL ApolloBannedProfileCachedIsSuspended(NSString *username) {
    NSString *key = ApolloBannedProfileNormalizedUsername(username);
    if (key.length == 0) return NO;
    // Never treat the logged-in user's own account as banned; a temporary
    // suspension must not lock them out of their own profile.
    if (ApolloBannedProfileIsCurrentLoggedInUser(key)) return NO;
    if ([sListEndpoint403Usernames containsObject:key.lowercaseString]) return YES;
    return [[ApolloUserProfileCache sharedCache] cachedIsSuspendedForUsername:key];
}

void ApolloBannedProfileNoteListEndpoint403ForURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return;
    NSString *path = url.path.lowercaseString ?: @"";
    if ([path rangeOfString:@"/user/"].location == NSNotFound) return;
    if ([path rangeOfString:@".json"].location == NSNotFound) return;
    if ([path rangeOfString:@"overview"].location == NSNotFound &&
        [path rangeOfString:@"comments"].location == NSNotFound &&
        [path rangeOfString:@"submitted"].location == NSNotFound &&
        [path rangeOfString:@"upvoted"].location == NSNotFound &&
        [path rangeOfString:@"downvoted"].location == NSNotFound) {
        return;
    }

    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    for (NSUInteger i = 0; i + 1 < parts.count; i++) {
        if (![parts[i] isEqualToString:@"user"]) continue;
        NSString *username = ApolloBannedProfileNormalizedUsername(parts[i + 1]);
        if (username.length == 0) return;
        // A 403 on the own account's listing is transient (auth/temp ban),
        // not a permanent suspension; don't poison the cache.
        if (ApolloBannedProfileIsCurrentLoggedInUser(username)) {
            ApolloLog(@"[BannedProfile] ignoring list endpoint 403 for own account u/%@", username);
            return;
        }
        if (!sListEndpoint403Usernames) sListEndpoint403Usernames = [NSMutableSet set];
        [sListEndpoint403Usernames addObject:username.lowercaseString];
        ApolloLog(@"[BannedProfile] list endpoint 403 for u/%@", username);
        return;
    }
}

void ApolloBannedProfileClearListEndpoint403ForUsername(NSString *username) {
    NSString *key = ApolloBannedProfileNormalizedUsername(username);
    if (key.length == 0 || !sListEndpoint403Usernames) return;
    NSString *lower = key.lowercaseString;
    if (![sListEndpoint403Usernames containsObject:lower]) return;
    [sListEndpoint403Usernames removeObject:lower];
    ApolloLog(@"[BannedProfile] cleared list endpoint 403 for u/%@ (no longer suspended)", key);
}

static void ApolloBannedProfileRemoveOverlay(UIViewController *viewController) {
    UIView *overlay = objc_getAssociatedObject(viewController, kApolloBannedProfileOverlayKey);
    if (overlay) {
        [overlay removeFromSuperview];
        objc_setAssociatedObject(viewController, kApolloBannedProfileOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(viewController, kApolloBannedProfileOverlayBottomConstraintKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ApolloBannedProfileApplyHeaderSuspendedAppearance(viewController, NO);
}

static void ApolloBannedProfileInstallOverlay(UIViewController *viewController, NSString *username) {
    UIView *hostView = viewController.view;
    if (!hostView) return;

    // If the user previously dismissed the overlay for this account, never show
    // it again — reveal the underlying profile instead. This is the escape hatch
    // for false positives (own temp-banned account flashing on login, etc.).
    if (ApolloBannedProfileOverlayDismissedForUsername(username)) {
        ApolloBannedProfileRemoveOverlay(viewController);
        return;
    }

    NSString *message = ApolloBannedProfileMessageForUsername(username);
    ApolloBannedProfileOverlayView *overlay = objc_getAssociatedObject(viewController, kApolloBannedProfileOverlayKey);
    if (!overlay) {
        overlay = [[ApolloBannedProfileOverlayView alloc] initWithMessage:message];
        overlay.translatesAutoresizingMaskIntoConstraints = NO;
        [hostView addSubview:overlay];
        objc_setAssociatedObject(viewController, kApolloBannedProfileOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        NSLayoutConstraint *top = [overlay.topAnchor constraintEqualToAnchor:hostView.topAnchor];
        NSLayoutConstraint *leading = [overlay.leadingAnchor constraintEqualToAnchor:hostView.leadingAnchor];
        NSLayoutConstraint *trailing = [overlay.trailingAnchor constraintEqualToAnchor:hostView.trailingAnchor];
        NSLayoutConstraint *bottom = [overlay.bottomAnchor constraintEqualToAnchor:hostView.bottomAnchor];
        [NSLayoutConstraint activateConstraints:@[top, leading, trailing, bottom]];
        objc_setAssociatedObject(viewController, kApolloBannedProfileOverlayBottomConstraintKey, bottom, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        overlay.messageLabel.text = message;
        if (overlay.superview != hostView) {
            [overlay removeFromSuperview];
            [hostView addSubview:overlay];
        }
    }

    NSString *dismissUsername = [ApolloBannedProfileNormalizedUsername(username) copy];
    __weak UIViewController *weakViewController = viewController;
    overlay.dismissHandler = ^{
        ApolloBannedProfileMarkOverlayDismissedForUsername(dismissUsername);
        ApolloBannedProfileRemoveOverlay(weakViewController);
    };

    [hostView bringSubviewToFront:overlay];
    // Re-resolve each install so the accent tracks the theme once Apollo has
    // finished tinting the profile's chrome (may not be ready on first pass).
    UIColor *accent = ApolloBannedProfileResolveAccentColor(viewController);
    [overlay applyThemeAccentColor:accent];
    ApolloBannedProfileApplyHeaderSuspendedAppearance(viewController, YES);
    ApolloBannedProfileStopVisibleSpinnersInView(viewController.view);
}

static void ApolloBannedProfileApplySuspendedState(UIViewController *viewController, BOOL suspended, NSString *username) {
    if (suspended) {
        ApolloLog(@"[BannedProfile] showing banned overlay for u/%@ class=%@", username, NSStringFromClass(viewController.class));
        ApolloBannedProfileInstallOverlay(viewController, username);
    } else {
        ApolloBannedProfileRemoveOverlay(viewController);
    }
}

static void ApolloBannedProfileEvaluateViewController(UIViewController *viewController) {
    if (!viewController || !ApolloBannedProfileViewControllerLooksLikeProfileList(viewController)) return;

    NSString *username = ApolloBannedProfileUsernameFromViewController(viewController);
    if (username.length == 0) {
        ApolloLog(@"[BannedProfile] skipped overlay class=%@ reason=no-username", NSStringFromClass(viewController.class));
        return;
    }

    // Never block the logged-in user's own profile, even if suspended; clear
    // any stale overlay installed before the account resolved.
    if (ApolloBannedProfileIsCurrentLoggedInUser(username)) {
        ApolloLog(@"[BannedProfile] skipping overlay for own account u/%@", username);
        ApolloBannedProfileApplySuspendedState(viewController, NO, username);
        return;
    }

    // Show the cached overlay immediately if suspended, but still revalidate so
    // a lifted ban clears the overlay instead of persisting for the cache TTL.
    BOOL cachedSuspended = ApolloBannedProfileCachedIsSuspended(username);
    ApolloBannedProfileApplySuspendedState(viewController, cachedSuspended, username);

    __weak UIViewController *weakViewController = viewController;
    [[ApolloUserProfileCache sharedCache] requestInfoForUsername:username completion:^(ApolloUserProfileInfo *info) {
        UIViewController *strongViewController = weakViewController;
        if (!strongViewController) return;
        NSString *currentUsername = ApolloBannedProfileUsernameFromViewController(strongViewController);
        if (!ApolloBannedProfileUsernamesMatch(currentUsername, username)) return;
        if (ApolloBannedProfileIsCurrentLoggedInUser(username)) return;
        BOOL suspended = info.isSuspended || ApolloBannedProfileCachedIsSuspended(username);
        ApolloBannedProfileApplySuspendedState(strongViewController, suspended, username);
    }];
}

void ApolloBannedProfileRefreshViewController(UIViewController *viewController) {
    if (!viewController) return;
    ApolloBannedProfileEvaluateViewController(viewController);
}

static void ApolloBannedProfileRefreshViewControllersInTree(UIViewController *viewController, NSString *username, NSHashTable *visited);

void ApolloBannedProfileRefreshProfilesForUsername(NSString *username) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSHashTable *visited = [NSHashTable weakObjectsHashTable];
        for (UIWindow *window in ApolloAllWindows()) {
            ApolloBannedProfileRefreshViewControllersInTree(window.rootViewController, username, visited);
        }
        NSHashTable *commentVisited = [NSHashTable weakObjectsHashTable];
        for (UIWindow *window in ApolloAllWindows()) {
            ApolloBannedProfileRefreshCommentCellsInTree(window.rootViewController, commentVisited, username, 0);
        }
        NSHashTable *linkVisited = [NSHashTable weakObjectsHashTable];
        for (UIWindow *window in ApolloAllWindows()) {
            ApolloBannedProfileRefreshLinkButtonsInTree(window.rootViewController.view, linkVisited, username, 0);
            ApolloBannedProfileRefreshLinkButtonsInTree(window.rootViewController, linkVisited, username, 0);
        }
    });
}

static void ApolloBannedProfileScheduleRefresh(UIViewController *viewController) {
    if (!viewController) return;
    if ([objc_getAssociatedObject(viewController, kApolloBannedProfileRefreshScheduledKey) boolValue]) return;
    objc_setAssociatedObject(viewController, kApolloBannedProfileRefreshScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIViewController *weakViewController = viewController;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *strongViewController = weakViewController;
        if (strongViewController) {
            objc_setAssociatedObject(strongViewController, kApolloBannedProfileRefreshScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ApolloBannedProfileRefreshViewController(strongViewController);
        }
    });
}

static BOOL ApolloBannedProfileURLMatchesUserListEndpoint(NSURL *url) {
    if (!url) return NO;
    NSString *path = url.path.lowercaseString ?: @"";
    if ([path rangeOfString:@"/user/"].location == NSNotFound) return NO;
    return [path hasSuffix:@".json"] &&
        ([path containsString:@"overview"] ||
         [path containsString:@"comments"] ||
         [path containsString:@"submitted"] ||
         [path containsString:@"upvoted"] ||
         [path containsString:@"downvoted"]);
}

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if (!completionHandler || !ApolloBannedProfileURLMatchesUserListEndpoint(request.URL)) {
        return %orig;
    }

    void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        if ([response isKindOfClass:[NSHTTPURLResponse class]] && ((NSHTTPURLResponse *)response).statusCode == 403) {
            ApolloBannedProfileNoteListEndpoint403ForURL(response.URL ?: request.URL);
        }
        completionHandler(data, response, error);
    };
    return %orig(request, wrappedHandler);
}

%end

%hook _TtC6Apollo21ProfileViewController

- (void)viewDidLoad {
    %orig;
    ApolloBannedProfileScheduleRefresh((UIViewController *)self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    ApolloBannedProfileScheduleRefresh((UIViewController *)self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloBannedProfileScheduleRefresh((UIViewController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloBannedProfileScheduleRefresh((UIViewController *)self);
}

%end

%hook _TtC6Apollo26UserCommentsViewController

- (void)viewDidLoad {
    %orig;
    ApolloBannedProfileScheduleRefresh((UIViewController *)self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    ApolloBannedProfileScheduleRefresh((UIViewController *)self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloBannedProfileScheduleRefresh((UIViewController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloBannedProfileScheduleRefresh((UIViewController *)self);
}

%end

%hook _TtC6Apollo15CommentCellNode

- (void)didLoad {
    %orig;
    ApolloBannedProfileDecorateCommentCellIfNeeded(self);
}

%end

%hook UIViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (ApolloBannedProfileViewControllerLooksLikeProfileList(self)) {
        ApolloBannedProfileScheduleRefresh(self);
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (!ApolloBannedProfileViewControllerLooksLikeProfileList(self)) return;

    NSString *username = ApolloBannedProfileUsernameFromViewController(self);
    if (username.length == 0) return;
    // Respect a manual dismissal: don't re-pin (or churn header layout) for an
    // account the user chose to reveal.
    if (ApolloBannedProfileOverlayDismissedForUsername(username)) return;
    if (ApolloBannedProfileCachedIsSuspended(username)) {
        // Keep the overlay pinned during layout, but also schedule a revalidation
        // so a lifted ban clears it instead of re-pinning the stale cached state.
        ApolloBannedProfileInstallOverlay(self, username);
        ApolloBannedProfileScheduleRefresh(self);
    }
}

%end

%ctor {
    sProfileViewControllerClass = objc_getClass("_TtC6Apollo21ProfileViewController");
    if (!sProfileViewControllerClass) {
        sProfileViewControllerClass = NSClassFromString(@"Apollo.ProfileViewController");
    }
    ApolloLog(@"[BannedProfile] module loaded");
    sBlockedNavTitles = [NSSet setWithObjects:
        @"accounts", @"account", @"profile", @"settings", @"overview",
        @"comments", @"comment", @"posts", @"post", @"inbox", @"search",
        @"saved", @"hidden", @"friends", @"upvoted", @"downvoted", @"trophies",
        @"messages", @"notifications", @"moderator", @"modmail", nil];

    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloUserProfileInfoUpdatedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        NSString *username = note.userInfo[ApolloUserProfileUsernameKey];
        if (username.length == 0) return;
        ApolloBannedProfileRefreshProfilesForUsername(username);
    }];
}

static void ApolloBannedProfileRefreshViewControllersInTree(UIViewController *viewController, NSString *username, NSHashTable *visited) {
    if (!viewController || [visited containsObject:viewController]) return;
    [visited addObject:viewController];

    if (ApolloBannedProfileViewControllerLooksLikeProfileList(viewController)) {
        NSString *controllerUsername = ApolloBannedProfileUsernameFromViewController(viewController);
        if (controllerUsername.length == 0 || ApolloBannedProfileUsernamesMatch(controllerUsername, username)) {
            ApolloBannedProfileRefreshViewController(viewController);
        }
    }

    for (UIViewController *child in viewController.childViewControllers) {
        ApolloBannedProfileRefreshViewControllersInTree(child, username, visited);
    }
    if (viewController.presentedViewController) {
        ApolloBannedProfileRefreshViewControllersInTree(viewController.presentedViewController, username, visited);
    }
}
