// ApolloPostFilterStore
//
// Single read/write surface for the Reborn "Post Filters" feature — the
// device-wide content filters layered onto Apollo's native Filters & Blocks
// screen. Bridges the persisted NSUserDefaults representation and the in-memory
// ApolloState snapshots (sPostFilterSubreddits / sPostFilterNameSubstrings) that
// the feed matcher reads off-main, and broadcasts ApolloPostFiltersChangedNotification
// on every mutation so visible feeds refresh.
//
// Both the native-screen injection hook (ApolloPostFilters.xm) and the
// per-subreddit detail VC mutate through here so the trim+lowercase normalization
// stays identical on every write (and matches Tweak.xm's hydration on read).

#import <Foundation/Foundation.h>

extern NSString *const ApolloPostFiltersChangedNotification;

@interface ApolloPostFilterStore : NSObject

// Normalization — write side must match read side (Tweak.xm hydration AND the
// feed matcher). Subreddit: trim, strip a leading r/ or /, lowercase. Term
// (keyword): trim, lowercase. Flair: additionally strip ":emoji:" snoomoji tokens
// and collapse interior whitespace, so a typed label matches the post's raw
// linkFlairText (e.g. ":n_media: Media" → "media").
+ (NSString *)normalizeSubreddit:(NSString *)raw;
+ (NSString *)normalizeTerm:(NSString *)raw;
+ (NSString *)normalizeFlair:(NSString *)raw;

// Per-subreddit rules ------------------------------------------------------
+ (NSArray<NSString *> *)allSubreddits;                     // lowercased, sorted
+ (NSArray<NSString *> *)keywordsForSubreddit:(NSString *)sub;
+ (NSArray<NSString *> *)flairsForSubreddit:(NSString *)sub;
+ (NSInteger)ruleCountForSubreddit:(NSString *)sub;         // keywords + flairs
+ (void)setKeywords:(NSArray<NSString *> *)keywords
             flairs:(NSArray<NSString *> *)flairs
       forSubreddit:(NSString *)sub;
+ (void)addKeyword:(NSString *)keyword forSubreddit:(NSString *)sub;
+ (void)removeKeyword:(NSString *)keyword forSubreddit:(NSString *)sub;
+ (void)addFlair:(NSString *)flair forSubreddit:(NSString *)sub;
+ (void)removeFlair:(NSString *)flair forSubreddit:(NSString *)sub;
+ (void)ensureSubreddit:(NSString *)sub;                    // create empty entry if absent
+ (void)removeSubreddit:(NSString *)sub;

// Subreddit-name substrings ------------------------------------------------
+ (NSArray<NSString *> *)nameSubstrings;                    // lowercased, sorted
+ (void)addNameSubstring:(NSString *)term;
+ (void)removeNameSubstring:(NSString *)term;

@end
