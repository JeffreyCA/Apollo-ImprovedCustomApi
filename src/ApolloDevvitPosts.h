// ApolloDevvitPosts.h — detection surface shared with Community Highlights.
//
// A Devvit ("Developer Platform") custom post — a live match thread, a game,
// a bracket — is only identifiable by the old-Reddit fallback text Reddit puts
// in its selftext; there is no dedicated field anywhere in the classic JSON
// API. Two consumers need that test, from two different data sources:
//
//   • ApolloDevvitPosts.xm itself, from an RDKLink (feed + comments hooks)
//   • ApolloSubredditHighlights.xm, from a raw t3 `data` dict (the highlights
//     REST/`api/info` fetches), so a PINNED interactive post can be left in
//     the feed — where its live widget renders — instead of being swallowed
//     by the Community Highlights carousel as a static card.
//
// Both go through the one predicate here so the two modules can never drift.

#import <Foundation/Foundation.h>

// Posted when either Devvit toggle changes, so Community Highlights can
// re-decide which pinned posts the feed owns (see ApolloDevvitFeedOwns*).
extern NSString *const ApolloDevvitFeedOwnershipChangedNotification;

// The raw marker test: YES when `selfText` is Reddit's old-Reddit fallback body
// for a custom post. Feature-flag agnostic — callers apply their own gate.
BOOL ApolloDevvitSelfTextIsInteractive(NSString *selfText);

// Same test against a t3 post's `data` dictionary (JSON API shape).
BOOL ApolloDevvitPostDataIsInteractive(NSDictionary *postData);

// YES while interactive posts render as their real live widget in FEED cards —
// i.e. the feed, not a highlights card, is the right owner for such a post.
BOOL ApolloDevvitFeedOwnsInteractivePosts(void);

// ApolloDevvitFeedOwnsInteractivePosts() && `link` (an RDKLink) is one of them.
// Safe to call from Texture's background layout queue.
BOOL ApolloDevvitFeedOwnsLink(id link);
