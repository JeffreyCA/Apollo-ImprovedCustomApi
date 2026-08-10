// ApolloPaneRouting.m

// Pure destination/source classification shared by ApolloPaneRouter's live
// push hook and ApolloPaneSplitViewController's pre-install stack normalizer.

#import "ApolloPaneRouting.h"
#import <objc/runtime.h>

typedef struct {
    const char *className;
    ApolloPaneColumn column;
} ApolloPaneRoute;

// Matched with isKindOfClass:, so subclasses inherit their parent's column.
// Comment-list controllers are feeds and intentionally stay unlisted.
static const ApolloPaneRoute kPaneRoutes[] = {
#if APOLLO_SIM_BUILD
    // Deterministic Task 11 transition probe. The class exists only in the
    // simulator debug bridge, so no device destination can match this entry.
    { "ApolloPaneTransitionProbeViewController", ApolloPaneColumnSecondary },
#endif
    { "_TtC6Apollo22CommentsViewController", ApolloPaneColumnSecondary },

    // Apollo's concrete private-message/modmail conversation. Do not classify
    // its generic MessagesViewController base: an unrelated future subclass
    // should not acquire column behavior without its own test pass.
    { "_TtC6Apollo28PrivateMessageViewController", ApolloPaneColumnSecondary },

    // These screens describe the item selected in a list/feed. A profile also
    // serves as the Profile tab's root, but that instance is already installed
    // before panes are built; subsequent profile pushes are author details.
    { "_TtC6Apollo21ProfileViewController",          ApolloPaneColumnSecondary },
    { "_TtC6Apollo30SubredditSidebarViewController", ApolloPaneColumnSecondary },
    { "_TtC6Apollo28SubredditRulesViewController",   ApolloPaneColumnSecondary },

    // Reborn's authenticated Chat/Modmail surface is opened from the Inbox
    // Boxes index (including notification deep links), so it owns detail even
    // though one controller renders both its list and conversation routes.
    { "ApolloDirectChatWebViewController", ApolloPaneColumnSecondary },

    // The Inbox Boxes controller remains the tab's stable index. Selecting a
    // category or native Modmail opens its list in detail; selecting a message
    // then appends the conversation on that same rightward stack.
    { "_TtC6Apollo19InboxViewController",        ApolloPaneColumnSecondary },
    { "_TtC6Apollo26ModmailInboxViewController", ApolloPaneColumnSecondary },

    // Feed indexes stay on the left. Explicit classification also tells the
    // router to clear stale detail when the user changes feeds.
    { "_TtC6Apollo19PostsViewController",     ApolloPaneColumnPrimary },
    { "_TtC6Apollo23LitePostsViewController", ApolloPaneColumnPrimary },
};

static BOOL ApolloPaneIsIndexRootController(UIViewController *viewController) {
    static const char *kIndexRoots[] = {
        "_TtC6Apollo22SettingsViewController",
        "_TtC6Apollo21ProfileViewController",
    };
    for (size_t index = 0; index < sizeof(kIndexRoots) / sizeof(kIndexRoots[0]); index++) {
        Class cls = objc_getClass(kIndexRoots[index]);
        if (cls && [viewController isMemberOfClass:cls]) return YES;
    }
    return NO;
}

static ApolloPaneColumn ApolloPaneExplicitColumnForViewController(UIViewController *viewController) {
    if (!viewController) return ApolloPaneColumnInPlace;
    for (size_t index = 0; index < sizeof(kPaneRoutes) / sizeof(kPaneRoutes[0]); index++) {
        Class cls = objc_getClass(kPaneRoutes[index].className);
        if (cls && [viewController isKindOfClass:cls]) return kPaneRoutes[index].column;
    }
    return ApolloPaneColumnInPlace;
}

BOOL ApolloPaneDestinationRequiresSupplementalBack(UIViewController *destinationViewController) {
    Class profileClass = objc_getClass("_TtC6Apollo21ProfileViewController");
    return profileClass && [destinationViewController isMemberOfClass:profileClass];
}

ApolloPaneColumn ApolloPaneResolveLogicalColumn(UIViewController *sourceViewController,
                                                UIViewController *destinationViewController,
                                                ApolloPaneColumn sourceColumn,
                                                BOOL *explicitlyClassified) {
    if (explicitlyClassified) *explicitlyClassified = NO;

    // Content only moves rightward. A link opened from detail stays in detail
    // even when its class would ordinarily be a primary feed.
    if (sourceColumn == ApolloPaneColumnSecondary) return ApolloPaneColumnSecondary;

    // Settings and Profile are index roots by product policy. Their first
    // destination occupies detail regardless of the destination class table.
    if (ApolloPaneIsIndexRootController(sourceViewController)) {
        if (explicitlyClassified) *explicitlyClassified = YES;
        return ApolloPaneColumnSecondary;
    }

    ApolloPaneColumn explicitColumn =
        ApolloPaneExplicitColumnForViewController(destinationViewController);
    if (explicitColumn != ApolloPaneColumnInPlace) {
        if (explicitlyClassified) *explicitlyClassified = YES;
        return explicitColumn;
    }

    // Unknown controllers behave exactly like a stock in-place push.
    return sourceColumn == ApolloPaneColumnSecondary
        ? ApolloPaneColumnSecondary : ApolloPaneColumnPrimary;
}

NSUInteger ApolloPaneExplicitRouteCount(void) {
    return sizeof(kPaneRoutes) / sizeof(kPaneRoutes[0]);
}
