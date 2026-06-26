// ApolloSearchHeaderOverlapFix.xm
//
// Fixes Apollo-Reborn issue #133: on the Search tab, the "SUBREDDIT SUGGESTIONS" section
// header overlaps the first suggestion row.
//
// Repro: Search a subreddit -> tap a suggestion (push the subreddit) -> Home (background
// the app) -> open another app -> reopen Apollo -> pop back to Search. The
// "SUBREDDIT SUGGESTIONS" header is drawn on top of the first row ("apollosideloaded")
// instead of resting in its own band above it.
//
// Class: _TtC6Apollo20SearchViewController : _TtC6Apollo25ApolloTableViewController. Its
// section headers are labelled Apollo.ApolloHeaderFooterView views from
// -tableView:viewForHeaderInSection:, and -tableView:heightForHeaderInSection: normally
// returns UITableViewAutomaticDimension (-1) so each labelled header self-sizes (the
// "TRENDING SUBREDDITS" header renders at ~51pt this way).
//
// Root cause (observed live in the simulator): after the controller is restored from the
// background and popped back to, Apollo's -heightForHeaderInSection: returns a collapsed
// hairline height (~1pt) for the "SUBREDDIT SUGGESTIONS" section, while
// -viewForHeaderInSection: still returns the real header view with its
// "SUBREDDIT SUGGESTIONS" label. The 1pt band can't contain the label, so the label spills
// downward over row 0. A reloadData does NOT help — the delegate itself returns 1pt, so the
// header height and the header view genuinely disagree.
//
// Fix: intercept -tableView:heightForHeaderInSection:. When Apollo crushes a header to a
// hairline (0..8pt) on a section that (a) still has rows and (b) whose header view carries a
// non-empty label, return UITableViewAutomaticDimension so the header self-sizes exactly
// like it does normally. UITableViewAutomaticDimension (-1) and any real height pass through
// untouched, so genuinely hidden/spacer headers are unaffected and the hook is a no-op in
// normal operation.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"

@interface _TtC6Apollo20SearchViewController : UIViewController
- (UIView *)tableView:(UITableView *)view viewForHeaderInSection:(long long)section;
@end

// Apollo's height callback for a hidden header is a hairline (~1pt); a spacer header is
// ~17.67pt. Anything in [0, 8) is "collapsed", which is the only value #133 produces.
static const CGFloat kApolloCollapsedHeaderHeight = 8.0;

// Re-entrancy guard: Apollo's -viewForHeaderInSection: could conceivably consult the height
// callback while configuring the view; don't recurse into the view lookup if so.
static BOOL sInHeaderHeightHook = NO;

// First UILabel with non-empty text under `v` (depth-first), else nil.
static UILabel *apollo_firstNonEmptyLabel(UIView *v) {
    if (!v) return nil;
    if ([v isKindOfClass:[UILabel class]] && [(UILabel *)v text].length > 0) return (UILabel *)v;
    for (UIView *sub in v.subviews) {
        UILabel *l = apollo_firstNonEmptyLabel(sub);
        if (l) return l;
    }
    return nil;
}

%hook _TtC6Apollo20SearchViewController

- (double)tableView:(UITableView *)tableView heightForHeaderInSection:(long long)section {
    double height = %orig;

    // Only a header Apollo collapsed to a hairline, on a section that still has rows, is
    // suspect. UITableViewAutomaticDimension (-1) and real heights fall straight through.
    if (height >= 0.0 && height < kApolloCollapsedHeaderHeight && !sInHeaderHeightHook &&
        [tableView numberOfRowsInSection:section] > 0 &&
        [self respondsToSelector:@selector(tableView:viewForHeaderInSection:)]) {

        sInHeaderHeightHook = YES;
        UIView *headerView = [self tableView:tableView viewForHeaderInSection:section];
        sInHeaderHeightHook = NO;

        // A header carrying a real label must never be crushed to ~1pt (issue #133). Let it
        // self-size like the (working) TRENDING SUBREDDITS header does.
        UILabel *lbl = apollo_firstNonEmptyLabel(headerView);
        if (lbl) {
            // Only fires in the #133 bug path, never in normal operation.
            ApolloLog(@"Un-collapsing search header sec %ld (orig=%.2fpt, label='%@')", (long)section, height, lbl.text);
            return UITableViewAutomaticDimension;
        }
    }

    return height;
}

%end

%ctor {
    %init;
}
