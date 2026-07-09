// ApolloHideSubscribePrompt
//
// Removes the "Subscribe to r/ApolloApp?" pop-up that Apollo throws up the
// first time you sign in with a Reddit account ("The official subreddit for
// this app! Subscribe to the community for news on the app, feature requests,
// and more!"). It's an unwanted extra tap on every fresh login, so we just
// never let it appear.
//
// How it works: Apollo builds this as a stock UIAlertController and shows it
// with -[UIViewController presentViewController:animated:completion:] from deep
// inside its post-login "sync subscribed subreddits" routine (Hopper:
// sub_100839a70, the branch gated on the subreddit name matching "apolloapp").
// That same routine presents plenty of *legitimate* alerts (errors, other
// confirmations), so we can't blanket-suppress presentation — we match on the
// two exact, unique prompt titles and pass everything else straight through.
//
// Suppressing the presentation is side-effect free: Apollo fires the alert with
// a nil completion and only mutates state from the No/Yes action handlers, which
// only run on a user tap. Never presenting it == the user silently declined,
// which is exactly the desired behavior.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "ApolloCommon.h"

// The two prompt variants, verbatim from the Apollo binary's __cstring
// (0x100a86eb0 / 0x100a86f50). Matching the exact titles — rather than a
// "Subscribe to r/ApolloApp" prefix — avoids ever catching a genuine subscribe
// confirmation for an unrelated subreddit (e.g. a hypothetical r/ApolloApple).
static BOOL ApolloIsAppSubredditSubscribePrompt(UIViewController *presented) {
    if (![presented isKindOfClass:[UIAlertController class]]) return NO;

    NSString *title = [(UIAlertController *)presented title];
    if (title.length == 0) return NO;

    return [title isEqualToString:@"Subscribe to r/ApolloApp?"] ||
           [title isEqualToString:@"Subscribe to r/ApolloAppBeta Beta Subreddit?"];
}

%hook UIViewController

- (void)presentViewController:(UIViewController *)viewControllerToPresent
                     animated:(BOOL)animated
                   completion:(void (^)(void))completion {
    if (ApolloIsAppSubredditSubscribePrompt(viewControllerToPresent)) {
        ApolloLog(@"Suppressed the r/ApolloApp subscribe prompt (\"%@\")",
                  [(UIAlertController *)viewControllerToPresent title]);
        // Honor the presentation contract: the completion block normally runs
        // once the alert finishes animating in. Apollo passes nil here, but a
        // future/other caller might not, so fire it rather than swallow it.
        if (completion) completion();
        return;
    }
    %orig;
}

%end
