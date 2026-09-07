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

// Same test, additionally requiring the fallback's sh.reddit.com link to point
// at `postID` (the post's own base36 id, no t3_ prefix). This is what separates
// a real devvit post from a text post that merely APPENDS the fallback sentence
// linking to some other interactive post — Global Scoreboard's post-match
// threads do exactly that. Prefer this whenever the post id is available;
// passing nil postID degrades to the adjacency-only test above.
BOOL ApolloDevvitSelfTextIsInteractiveForPostID(NSString *selfText, NSString *postID);

// Same test against a t3 post's `data` dictionary (JSON API shape).
BOOL ApolloDevvitPostDataIsInteractive(NSDictionary *postData);

// YES while interactive posts render as their real live widget in FEED cards —
// i.e. the feed, not a highlights card, is the right owner for such a post.
BOOL ApolloDevvitFeedOwnsInteractivePosts(void);

// ApolloDevvitFeedOwnsInteractivePosts() && `link` (an RDKLink) is one of them.
// Safe to call from Texture's background layout queue.
BOOL ApolloDevvitFeedOwnsLink(id link);

// YES when the feature is on and `link` (an RDKLink) is an interactive post —
// i.e. wherever Apollo would render the post's body, the live widget stands in
// for it (the comments header always; feed cards when the sub-toggle is on).
// Consumers that derive anything from the post BODY — Apollo AI's post/link
// summaries — must treat such a post as having no body at all: the selftext
// is Reddit's old-Reddit fallback plus whatever data blob the app appended,
// none of which the user can see once the widget replaces it, so "summarizing"
// it only ever produced an error card (or a summary of invisible text).
// Surface-agnostic and independent of the feed sub-toggle and of a widget that
// gave up: an interactive post is never body-summarizable. Safe off-main.
BOOL ApolloDevvitLinkShowsWidget(id link);
