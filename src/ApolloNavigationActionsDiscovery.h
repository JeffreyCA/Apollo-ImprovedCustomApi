#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "ApolloNavigationActions.h"
#include <math.h>

// Discover ownership from live item views, not private class names: UIKit may
// register old platter classes without using them. Discovery is read-only.
static inline NSArray<UIView *> *ApolloNavigationActionsItemViewCandidates(UIBarButtonItem *item) {
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    if (item.customView) [views addObject:item.customView];
    SEL selector = NSSelectorFromString(@"view");
    @try {
        id native = [item respondsToSelector:selector]
            ? ((id (*)(id, SEL))objc_msgSend)(item, selector)
            : [item valueForKey:@"view"];
        if ([native isKindOfClass:UIView.class] && ![views containsObject:native]) [views addObject:native];
    } @catch (__unused NSException *exception) {
        // The public customView is still a valid anchor when attached.
    }
    return views;
}

static inline BOOL ApolloNavigationActionsContainsAnchor(UIView *view, NSArray<UIView *> *anchors) {
    for (UIView *anchor in anchors) if ([anchor isDescendantOfView:view]) return YES;
    return NO;
}

static inline BOOL ApolloNavigationActionsSubtreeIsExclusive(UIView *root, NSArray<UIView *> *rightViews,
                                                              NSArray<UIView *> *leftViews, UIView *titleView) {
    if (titleView && [titleView isDescendantOfView:root]) return NO;
    for (UIView *left in leftViews) if ([left isDescendantOfView:root]) return NO;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    for (NSUInteger index = 0; index < queue.count; index++) {
        UIView *view = queue[index];
        // Search/title controls are excluded even when exposed as item anchors.
        if ([view isKindOfClass:UISearchBar.class] || [view isKindOfClass:UITextField.class] ||
            [NSStringFromClass(view.class) containsString:@"NavigationBarTitleControl"]) return NO;
        // Custom right items own their entire subtree, including gestures.
        if (ApolloNavigationActionsViewIsInManagedRoots(view, rightViews)) continue;
        BOOL containsRight = ApolloNavigationActionsContainsAnchor(view, rightViews);
        if (([view isKindOfClass:UIControl.class] || [view isKindOfClass:UILabel.class]) && !containsRight) return NO;
        // Only ancestors of right-item anchors may own platter gestures.
        if (!containsRight && view.gestureRecognizers.count > 0) return NO;
        [queue addObjectsFromArray:view.subviews];
    }
    return YES;
}

static inline BOOL ApolloNavigationActionsValidGroupFrame(CGRect rect, CGRect anchorRect,
                                                           UINavigationBar *bar) {
    if (CGRectIsNull(rect) || CGRectIsInfinite(rect) || CGRectIsEmpty(rect) ||
        !isfinite(rect.origin.x) || !isfinite(rect.origin.y) ||
        !isfinite(rect.size.width) || !isfinite(rect.size.height)) return NO;
    if (CGRectGetWidth(rect) >= CGRectGetWidth(bar.bounds) - 1.0 ||
        CGRectGetHeight(rect) > MAX(64.0, CGRectGetHeight(anchorRect) + 16.0) ||
        CGRectGetMaxY(rect) <= CGRectGetMinY(anchorRect) || CGRectGetMinY(rect) >= CGRectGetMaxY(anchorRect)) return NO;
    return YES;
}

static inline NSArray<UIView *> *ApolloNavigationActionsDiscoverGroups(UINavigationBar *bar,
                                                                      UINavigationItem *item) {
    if (!bar || !item || CGRectGetWidth(bar.bounds) <= 0) return @[];
    NSMutableArray<UIView *> *rightViews = [NSMutableArray array];
    NSMutableArray<UIView *> *leftViews = [NSMutableArray array];
    for (UIBarButtonItem *button in item.leftBarButtonItems) {
        for (UIView *view in ApolloNavigationActionsItemViewCandidates(button)) {
            if ([view isDescendantOfView:bar]) [leftViews addObject:view];
        }
    }
    for (UIBarButtonItem *button in item.rightBarButtonItems) {
        // UIKit can detach a custom view while retaining its native wrapper.
        for (UIView *view in ApolloNavigationActionsItemViewCandidates(button)) {
            // Hidden anchors still belong to the item and stay out of title fitting.
            CGRect rect = [view isDescendantOfView:bar] ? [view convertRect:view.bounds toView:bar] : CGRectNull;
            if (ApolloNavigationActionsValidGroupFrame(rect, rect, bar) && ![rightViews containsObject:view]) {
                [rightViews addObject:view];
            }
        }
    }
    NSMutableArray<UIView *> *roots = [NSMutableArray array];
    for (UIView *anchor in rightViews) {
        CGRect anchorRect = [anchor convertRect:anchor.bounds toView:bar];
        UIView *root = nil;
        for (UIView *candidate = anchor; candidate && candidate != bar; candidate = candidate.superview) {
            CGRect rect = [candidate convertRect:candidate.bounds toView:bar];
            if (!ApolloNavigationActionsValidGroupFrame(rect, anchorRect, bar) ||
                !ApolloNavigationActionsSubtreeIsExclusive(candidate, rightViews, leftViews, item.titleView)) break;
            // Ownership follows item membership, not position or wrapper class:
            // split right-item groups may cross the midpoint in either direction.
            // The guards above exclude shared planes and unrelated controls.
            root = candidate;
        }
        if (!root) continue;
        BOOL covered = NO;
        for (UIView *existing in [roots copy]) {
            if ([root isDescendantOfView:existing]) { covered = YES; break; }
            if ([existing isDescendantOfView:root]) [roots removeObject:existing];
        }
        if (!covered) [roots addObject:root];
    }
    return roots;
}
