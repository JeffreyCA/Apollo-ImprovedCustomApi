#import "ApolloPostFilterStore.h"

#import "ApolloState.h"
#import "UserDefaultConstants.h"

NSString *const ApolloPostFiltersChangedNotification = @"ApolloPostFiltersChangedNotification";

@implementation ApolloPostFilterStore

#pragma mark - Normalization

+ (NSString *)normalizeTerm:(NSString *)raw {
    if (![raw isKindOfClass:[NSString class]]) return @"";
    return [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
}

+ (NSString *)normalizeSubreddit:(NSString *)raw {
    if (![raw isKindOfClass:[NSString class]]) return @"";
    NSString *s = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([s hasPrefix:@"r/"] || [s hasPrefix:@"R/"]) s = [s substringFromIndex:2];
    if ([s hasPrefix:@"/"]) s = [s substringFromIndex:1];
    return s.lowercaseString;
}

// Strip ":emoji:" snoomoji tokens (e.g. ":n_media:") and collapse interior runs of
// whitespace, then trim + lowercase. Used on BOTH the typed-filter side and the
// post's raw linkFlairText so an exact match lines up regardless of flair emoji.
+ (NSString *)normalizeFlair:(NSString *)raw {
    if (![raw isKindOfClass:[NSString class]] || raw.length == 0) return @"";
    static NSRegularExpression *re = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@":[^:\\s]+:" options:0 error:NULL];
    });
    NSString *out = re ? [re stringByReplacingMatchesInString:raw options:0 range:NSMakeRange(0, raw.length) withTemplate:@""] : raw;
    NSArray<NSString *> *parts = [out componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    for (NSString *p in parts) if (p.length) [kept addObject:p];
    return [[kept componentsJoinedByString:@" "] lowercaseString];
}

#pragma mark - Persistence helpers

// Update the in-memory snapshot (read by the feed matcher), persist, and
// broadcast. The snapshot is always swapped as an immutable [copy] so off-main
// readers see a consistent container.
+ (void)persistSubreddits:(NSDictionary<NSString *, NSDictionary *> *)dict {
    sPostFilterSubreddits = [dict copy] ?: @{};
    [[NSUserDefaults standardUserDefaults] setObject:sPostFilterSubreddits forKey:UDKeyPostFilterSubreddits];
    [self broadcast];
}

+ (void)persistNameSubstrings:(NSArray<NSString *> *)list {
    sPostFilterNameSubstrings = [list copy] ?: @[];
    [[NSUserDefaults standardUserDefaults] setObject:sPostFilterNameSubstrings forKey:UDKeyPostFilterNameSubstrings];
    [self broadcast];
}

+ (void)broadcast {
    if ([NSThread isMainThread]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:ApolloPostFiltersChangedNotification object:nil];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:ApolloPostFiltersChangedNotification object:nil];
        });
    }
}

// Sanitize an arbitrary array into a deduped list of normalized terms. Flairs use
// the flair normalizer (emoji-strip + whitespace-collapse); keywords use the plain
// term normalizer.
+ (NSArray<NSString *> *)cleanArray:(NSArray *)arr flairs:(BOOL)flairs {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    if ([arr isKindOfClass:[NSArray class]]) {
        for (id t in arr) {
            NSString *s = flairs ? [self normalizeFlair:t] : [self normalizeTerm:t];
            if (s.length > 0 && ![out containsObject:s]) [out addObject:s];
        }
    }
    return [out copy];
}

#pragma mark - Per-subreddit rules

+ (NSArray<NSString *> *)allSubreddits {
    NSDictionary *all = sPostFilterSubreddits ?: @{};
    return [[all allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

+ (NSDictionary *)rulesForSubreddit:(NSString *)sub {
    NSString *key = [self normalizeSubreddit:sub];
    NSDictionary *o = (key.length > 0) ? (sPostFilterSubreddits ?: @{})[key] : nil;
    return [o isKindOfClass:[NSDictionary class]] ? o : @{};
}

+ (NSArray<NSString *> *)keywordsForSubreddit:(NSString *)sub {
    id kw = [self rulesForSubreddit:sub][@"keywords"];
    return [kw isKindOfClass:[NSArray class]] ? (NSArray *)kw : @[];
}

+ (NSArray<NSString *> *)flairsForSubreddit:(NSString *)sub {
    id fl = [self rulesForSubreddit:sub][@"flairs"];
    return [fl isKindOfClass:[NSArray class]] ? (NSArray *)fl : @[];
}

+ (NSInteger)ruleCountForSubreddit:(NSString *)sub {
    return (NSInteger)[self keywordsForSubreddit:sub].count + (NSInteger)[self flairsForSubreddit:sub].count;
}

+ (void)setKeywords:(NSArray<NSString *> *)keywords
             flairs:(NSArray<NSString *> *)flairs
       forSubreddit:(NSString *)sub {
    NSString *key = [self normalizeSubreddit:sub];
    if (key.length == 0) return;
    NSMutableDictionary *all = [(sPostFilterSubreddits ?: @{}) mutableCopy];
    NSMutableDictionary *rules = [NSMutableDictionary dictionary];
    NSArray<NSString *> *kw = [self cleanArray:keywords flairs:NO];
    NSArray<NSString *> *fl = [self cleanArray:flairs flairs:YES];
    if (kw.count > 0) rules[@"keywords"] = kw;
    if (fl.count > 0) rules[@"flairs"] = fl;
    all[key] = [rules copy]; // keep the entry even when empty (until explicitly removed)
    [self persistSubreddits:all];
}

+ (void)addKeyword:(NSString *)keyword forSubreddit:(NSString *)sub {
    NSString *t = [self normalizeTerm:keyword];
    if (t.length == 0) return;
    NSArray<NSString *> *kw = [self keywordsForSubreddit:sub];
    if ([kw containsObject:t]) return;
    [self setKeywords:[kw arrayByAddingObject:t] flairs:[self flairsForSubreddit:sub] forSubreddit:sub];
}

+ (void)removeKeyword:(NSString *)keyword forSubreddit:(NSString *)sub {
    NSString *t = [self normalizeTerm:keyword];
    if (t.length == 0) return;
    NSMutableArray<NSString *> *kw = [[self keywordsForSubreddit:sub] mutableCopy];
    if (![kw containsObject:t]) return;
    [kw removeObject:t];
    [self setKeywords:kw flairs:[self flairsForSubreddit:sub] forSubreddit:sub];
}

+ (void)addFlair:(NSString *)flair forSubreddit:(NSString *)sub {
    NSString *t = [self normalizeFlair:flair];
    if (t.length == 0) return;
    NSArray<NSString *> *fl = [self flairsForSubreddit:sub];
    if ([fl containsObject:t]) return;
    [self setKeywords:[self keywordsForSubreddit:sub] flairs:[fl arrayByAddingObject:t] forSubreddit:sub];
}

+ (void)removeFlair:(NSString *)flair forSubreddit:(NSString *)sub {
    NSString *t = [self normalizeFlair:flair];
    if (t.length == 0) return;
    NSMutableArray<NSString *> *fl = [[self flairsForSubreddit:sub] mutableCopy];
    if (![fl containsObject:t]) return;
    [fl removeObject:t];
    [self setKeywords:[self keywordsForSubreddit:sub] flairs:fl forSubreddit:sub];
}

+ (void)ensureSubreddit:(NSString *)sub {
    NSString *key = [self normalizeSubreddit:sub];
    if (key.length == 0) return;
    if ((sPostFilterSubreddits ?: @{})[key]) return;
    NSMutableDictionary *all = [(sPostFilterSubreddits ?: @{}) mutableCopy];
    all[key] = @{};
    [self persistSubreddits:all];
}

+ (void)removeSubreddit:(NSString *)sub {
    NSString *key = [self normalizeSubreddit:sub];
    if (key.length == 0) return;
    if (!(sPostFilterSubreddits ?: @{})[key]) return;
    NSMutableDictionary *all = [(sPostFilterSubreddits ?: @{}) mutableCopy];
    [all removeObjectForKey:key];
    [self persistSubreddits:all];
}

#pragma mark - Name substrings

+ (NSArray<NSString *> *)nameSubstrings {
    NSArray *all = sPostFilterNameSubstrings ?: @[];
    return [all sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

+ (void)addNameSubstring:(NSString *)term {
    NSString *t = [self normalizeTerm:term];
    if (t.length == 0) return;
    NSArray *current = sPostFilterNameSubstrings ?: @[];
    if ([current containsObject:t]) return;
    [self persistNameSubstrings:[current arrayByAddingObject:t]];
}

+ (void)removeNameSubstring:(NSString *)term {
    NSString *t = [self normalizeTerm:term];
    if (t.length == 0) return;
    NSArray *current = sPostFilterNameSubstrings ?: @[];
    if (![current containsObject:t]) return;
    NSMutableArray *m = [current mutableCopy];
    [m removeObject:t];
    [self persistNameSubstrings:m];
}

@end
