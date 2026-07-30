#import "ApolloBadgeBookScraper.h"
#import "ApolloCommon.h"
#import "ApolloState.h"                // sLatestRedditBearerToken, sUserAgent
#import "ApolloProfileSocialLinks.h"   // ApolloSharedScrapeDataStore()
#import "ApolloWebSessionStore.h"      // ApolloActiveWebSession() — logged-in scrape cookies
#import "ApolloWebJSON.h"              // ApolloWebJSONProbeURL() — opt-out of the Web JSON rewrite
#import <WebKit/WebKit.h>

NSString *const ApolloBadgeBookUserUpdatedNotification = @"ApolloBadgeBookUserUpdatedNotification";

// Same desktop Safari UA the WKWebView fallback presents — Reddit serves the
// server-rendered shreddit markup (trophy list + achievement-badge tags) to it.
static NSString *const kApolloBBDesktopUA =
    @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";

#pragma mark - ApolloUserBadges

@implementation ApolloUserBadges
- (instancetype)init {
    if ((self = [super init])) {
        _earnedAchievementIDs = [NSSet set];
        _trophies = @[];
        _earnedAchievementImageURLs = @{};
    }
    return self;
}
- (NSUInteger)earnedAchievementCount { return self.earnedAchievementIDs.count; }
@end

#pragma mark - Username helpers

static NSString *ApolloBBNormalizeUsername(NSString *username) {
    if (![username isKindOfClass:[NSString class]]) return nil;
    NSString *s = [username stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([s hasPrefix:@"u/"] || [s hasPrefix:@"U/"]) s = [s substringFromIndex:2];
    if (s.length == 0) return nil;
    if ([s isEqualToString:@"[deleted]"] || [s caseInsensitiveCompare:@"deleted"] == NSOrderedSame) return nil;
    return s;
}

static NSString *ApolloBBEscapedUsername(NSString *username) {
    NSMutableCharacterSet *allowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"_-"];
    return [username stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: username;
}

static NSString *ApolloBBStr(id v) { return [v isKindOfClass:[NSString class]] ? v : nil; }

#pragma mark - Result cache + in-flight dedup

static NSCache<NSString *, ApolloUserBadges *> *ApolloBBCache(void) {
    static NSCache *cache; static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [[NSCache alloc] init]; cache.countLimit = 60; });
    return cache;
}
// key(lower) -> array of completion blocks waiting on the in-flight scrape.
static NSMutableDictionary<NSString *, NSMutableArray *> *ApolloBBPending(void) {
    static NSMutableDictionary *d; static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}
// Retains in-flight WebView fetchers so they aren't deallocated mid-load. A SET,
// not a per-username dictionary: two fetches for the same user can overlap
// (pull-to-refresh supersedes a fetch whose fallback is still running), and a
// keyed store would let one overwrite/remove the other's only strong reference —
// deallocating a live scrape, orphaning its hidden WKWebView in the window, and
// leaking the single fallback slot. Each fetch owns exactly its own membership.
static NSMutableSet *ApolloBBFetchers(void) {
    static NSMutableSet *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NSMutableSet set]; });
    return s;
}
// Bumped by ApolloBadgeBookInvalidate (main thread, like all fetch state). Every
// fetch stamps itself with the value at start; a late leg (or the up-to-90s
// WebView fallback) of a superseded fetch checks the stamp before re-pinning its
// stale result into the cache/disk over a newer fetch's delivery. Global rather
// than per-user: an invalidate racing an unrelated user's in-flight fetch only
// costs that fetch its cache pin (its waiters are still answered), never
// correctness.
static NSUInteger sApolloBBGeneration = 0;

#pragma mark - Disk cache (TTL)

// Trophy cases and achievements change rarely, so a tiny per-user JSON file in
// Library/Caches (OS-purgeable) makes repeat visits across launches render
// instantly with ZERO reddit requests. The TTL bounds staleness;
// pull-to-refresh bypasses it via ApolloBadgeBookInvalidate.
static NSTimeInterval const kApolloBBDiskTTL = 6.0 * 60.0 * 60.0;

static NSString *ApolloBBDiskDir(void) {
    static NSString *dir; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        dir = [caches stringByAppendingPathComponent:@"ApolloBadgeBook"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    });
    return dir;
}

// Cache keys are normalized reddit usernames ([A-Za-z0-9_-], lowercased) —
// inherently safe as filenames.
static NSString *ApolloBBDiskPath(NSString *key) {
    return [[ApolloBBDiskDir() stringByAppendingPathComponent:key] stringByAppendingPathExtension:@"json"];
}

static void ApolloBBDictSetIfPresent(NSMutableDictionary *d, NSString *key, NSString *value) {
    if (value.length) d[key] = value;
}

// Browsing a busy thread writes one small file per unique username, and an
// expired entry was only ever skipped on read — never deleted. Sweep once per
// launch (piggybacked on the first save, already on a background queue): drop
// anything past the TTL, then cap the directory to the most recently written
// entries so even a heavy browsing session can't grow it without bound.
static NSUInteger const kApolloBBDiskMaxFiles = 150;

static void ApolloBBDiskSweepOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = ApolloBBDiskDir();
        NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:dir error:nil];
        if (names.count == 0) return;

        NSDate *now = [NSDate date];
        NSMutableArray<NSDictionary *> *live = [NSMutableArray array];
        NSUInteger expired = 0;
        for (NSString *name in names) {
            NSString *path = [dir stringByAppendingPathComponent:name];
            NSDate *modified = [fm attributesOfItemAtPath:path error:nil].fileModificationDate;
            if (modified && [now timeIntervalSinceDate:modified] > kApolloBBDiskTTL) {
                [fm removeItemAtPath:path error:nil];
                expired++;
                continue;
            }
            [live addObject:@{ @"path": path, @"date": modified ?: now }];
        }

        NSUInteger overflow = 0;
        if (live.count > kApolloBBDiskMaxFiles) {
            [live sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [b[@"date"] compare:a[@"date"]];   // newest first
            }];
            for (NSUInteger i = kApolloBBDiskMaxFiles; i < live.count; i++) {
                [fm removeItemAtPath:live[i][@"path"] error:nil];
                overflow++;
            }
        }
        if (expired || overflow) {
            ApolloLog(@"[BadgeBook] disk cache swept: %lu expired, %lu over cap, %lu kept",
                      (unsigned long)expired, (unsigned long)overflow,
                      (unsigned long)MIN(live.count, kApolloBBDiskMaxFiles));
        }
    });
}

// A result is complete when every leg that CAN resolve has. Without the bundled
// catalogue the achievements leg never runs (nothing to join against), so
// completeness is trophies alone there — otherwise no one would ever get a disk
// cache on a broken install.
static BOOL ApolloBBResultComplete(ApolloUserBadges *result) {
    if (!result) return NO;
    BOOL achievementsComplete = result.achievementsResolved || ![ApolloBadgeBookCatalog shared].isLoaded;
    return result.trophiesResolved && achievementsComplete;
}

static void ApolloBBDiskSave(ApolloUserBadges *result) {
    // Only COMPLETE results persist. A partial (one leg failed permanently) would
    // otherwise be served from disk for the whole 6h TTL with no retry of the
    // failed half — partials stay in the session cache only, so the next visit
    // re-attempts the network.
    if (!ApolloBBResultComplete(result)) return;
    NSString *key = result.username.lowercaseString;
    if (key.length == 0) return;

    NSMutableArray *trophies = [NSMutableArray array];
    for (ApolloBadgeItem *t in result.trophies) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        ApolloBBDictSetIfPresent(d, @"id", t.identifier);
        ApolloBBDictSetIfPresent(d, @"title", t.title);
        ApolloBBDictSetIfPresent(d, @"bio", t.bio);
        ApolloBBDictSetIfPresent(d, @"file", t.imageFile);
        ApolloBBDictSetIfPresent(d, @"url", t.imageURLString);
        ApolloBBDictSetIfPresent(d, @"dest", t.destinationURLString);
        if (t.isLiveUncatalogued) d[@"live"] = @YES;
        [trophies addObject:d];
    }
    NSDictionary *doc = @{
        @"v": @1,
        @"ts": @([NSDate date].timeIntervalSince1970),
        @"username": result.username ?: key,
        @"earned": result.earnedAchievementIDs.allObjects ?: @[],
        @"artURLs": result.earnedAchievementImageURLs ?: @{},
        @"trophies": trophies,
        @"achResolved": @(result.achievementsResolved),
        @"troResolved": @(result.trophiesResolved),
    };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSData *data = [NSJSONSerialization dataWithJSONObject:doc options:0 error:nil];
        if (data) [data writeToFile:ApolloBBDiskPath(key) atomically:YES];
        ApolloBBDiskSweepOnce();
    });
}

static ApolloUserBadges *ApolloBBDiskLoad(NSString *key, double *outAgeHours) {
    NSData *data = [NSData dataWithContentsOfFile:ApolloBBDiskPath(key)];
    if (!data) return nil;
    NSDictionary *doc = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![doc isKindOfClass:[NSDictionary class]] || [doc[@"v"] integerValue] != 1) return nil;
    NSTimeInterval age = [NSDate date].timeIntervalSince1970 - [doc[@"ts"] doubleValue];
    if (age < 0 || age > kApolloBBDiskTTL) return nil;

    ApolloUserBadges *result = [[ApolloUserBadges alloc] init];
    result.username = ApolloBBStr(doc[@"username"]) ?: key;
    if ([doc[@"earned"] isKindOfClass:[NSArray class]]) {
        result.earnedAchievementIDs = [NSSet setWithArray:doc[@"earned"]];
    }
    if ([doc[@"artURLs"] isKindOfClass:[NSDictionary class]]) {
        result.earnedAchievementImageURLs = doc[@"artURLs"];
    }
    NSMutableArray<ApolloBadgeItem *> *trophies = [NSMutableArray array];
    for (NSDictionary *d in ([doc[@"trophies"] isKindOfClass:[NSArray class]] ? doc[@"trophies"] : @[])) {
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        ApolloBadgeItem *item = [[ApolloBadgeItem alloc] init];
        item.kind = ApolloBadgeKindTrophy;
        item.earned = YES;
        item.identifier = ApolloBBStr(d[@"id"]);
        item.title = ApolloBBStr(d[@"title"]);
        item.bio = ApolloBBStr(d[@"bio"]);
        item.imageFile = ApolloBBStr(d[@"file"]);
        item.imageURLString = ApolloBBStr(d[@"url"]);
        item.destinationURLString = ApolloBBStr(d[@"dest"]);
        item.isLiveUncatalogued = [d[@"live"] boolValue];
        if (item.title.length) [trophies addObject:item];
    }
    result.trophies = trophies;
    result.achievementsResolved = [doc[@"achResolved"] boolValue];
    result.trophiesResolved = [doc[@"troResolved"] boolValue];
    // Saves are gated on completeness, but files written by earlier builds (or
    // with a catalogue that has since appeared) may be partial — treat those as
    // misses so the failed leg gets retried instead of served stale for 6h.
    if (!ApolloBBResultComplete(result)) return nil;
    if (outAgeHours) *outAgeHours = age / 3600.0;
    return result;
}

#pragma mark - HTML parsing (fast path)

// Minimal entity decode for the handful Reddit emits in attribute/text content.
// &amp; must go LAST so "&amp;lt;" doesn't double-decode.
static NSString *ApolloBBDecodeEntities(NSString *s) {
    if (s.length == 0 || [s rangeOfString:@"&"].location == NSNotFound) return s;
    NSMutableString *m = [s mutableCopy];
    NSDictionary<NSString *, NSString *> *first = @{
        @"&lt;": @"<", @"&gt;": @">", @"&quot;": @"\"",
        @"&#39;": @"'", @"&#x27;": @"'", @"&#x2F;": @"/", @"&nbsp;": @" ",
    };
    for (NSString *k in first) {
        [m replaceOccurrencesOfString:k withString:first[k] options:0 range:NSMakeRange(0, m.length)];
    }
    [m replaceOccurrencesOfString:@"&amp;" withString:@"&" options:0 range:NSMakeRange(0, m.length)];
    return m;
}

static NSString *ApolloBBCollapseWhitespace(NSString *s) {
    if (s.length == 0) return s;
    NSArray *parts = [s componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray *keep = [NSMutableArray array];
    for (NSString *p in parts) if (p.length) [keep addObject:p];
    return [keep componentsJoinedByString:@" "];
}

// attr="value" from inside a single tag string (attribute order varies). The
// needle is space-prefixed so `title` never matches inside `subtitle="..."`
// and `id` never matches inside `data-testid="..."` — attributes are always
// space-separated after the tag name.
static NSString *ApolloBBTagAttr(NSString *tag, NSString *name) {
    NSString *needle = [NSString stringWithFormat:@" %@=\"", name];
    NSRange start = [tag rangeOfString:needle];
    if (start.location == NSNotFound) return nil;
    NSUInteger from = NSMaxRange(start);
    NSRange end = [tag rangeOfString:@"\"" options:0 range:NSMakeRange(from, tag.length - from)];
    if (end.location == NSNotFound) return nil;
    return ApolloBBDecodeEntities([tag substringWithRange:NSMakeRange(from, end.location - from)]);
}

// A real (non-blockpage) shreddit page always carries the app shell tag.
static BOOL ApolloBBLooksLikeRedditPage(NSString *html) {
    return [html rangeOfString:@"<shreddit-app"].location != NSNotFound;
}

// "<title>...</title>" of a failed page — tells block pages, challenges, and
// consent walls apart in user logs without dumping HTML.
static NSString *ApolloBBPageTitle(NSString *html) {
    if (html.length == 0) return @"(no body)";
    NSRange open = [html rangeOfString:@"<title"];
    if (open.location == NSNotFound) return @"(no title)";
    NSRange gt = [html rangeOfString:@">" options:0 range:NSMakeRange(open.location, MIN((NSUInteger)200, html.length - open.location))];
    if (gt.location == NSNotFound) return @"(no title)";
    NSUInteger from = NSMaxRange(gt);
    NSRange close = [html rangeOfString:@"</title>" options:0 range:NSMakeRange(from, MIN((NSUInteger)300, html.length - from))];
    if (close.location == NSNotFound) return @"(unterminated title)";
    return ApolloBBCollapseWhitespace(ApolloBBDecodeEntities([html substringWithRange:NSMakeRange(from, close.location - from)]));
}

// All <achievement-badge ...> tags -> {id, unlocked, title, url}. The raw
// server HTML lists them in light DOM (the live page upgrades them into shadow
// DOM, which is why the WebView fallback re-fetches its own URL — but a direct
// GET sees the raw markup for free).
static NSArray<NSDictionary *> *ApolloBBParseAchievementTags(NSString *html) {
    static NSRegularExpression *tagRE; static dispatch_once_t once;
    dispatch_once(&once, ^{
        tagRE = [NSRegularExpression regularExpressionWithPattern:@"<achievement-badge\\b[^>]*>" options:0 error:nil];
    });
    NSMutableArray *out = [NSMutableArray array];
    [tagRE enumerateMatchesInString:html options:0 range:NSMakeRange(0, html.length)
                         usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags, BOOL *stop) {
        NSString *tag = [html substringWithRange:m.range];
        NSString *badgeID = ApolloBBTagAttr(tag, @"id");
        if (badgeID.length == 0) return;
        [out addObject:@{
            @"id": badgeID,
            @"unlocked": @(ApolloBBTagAttr(tag, @"unlocked-at").length > 0),
            @"title": ApolloBBTagAttr(tag, @"title") ?: @"",
            @"url": ApolloBBTagAttr(tag, @"url") ?: @"",
        }];
    }];
    return out;
}

// old.reddit.com sidebar Trophy Case: <div class="trophy-area"> holding one
// <td class="trophy-info"> per trophy with an awards2 <img class="trophy-icon">,
// a <span class="trophy-name">, an optional <span class="trophy-description">
// and an optional destination <a href>. old.reddit is the trophy source for the
// direct path because shreddit sniffs the transport fingerprint and serves
// CFNetwork the MOBILE variant, which has no trophy markup at all (the desktop
// UA string is not enough — curl and WebKit get desktop, NSURLSession doesn't).
// Bonus: ~36KB vs ~500KB. Returns nil when the page has no trophy area.
static NSArray<NSDictionary *> *ApolloBBParseOldRedditTrophies(NSString *html) {
    NSRange areaStart = [html rangeOfString:@"class=\"sidecontentbox trophy-area"];
    if (areaStart.location == NSNotFound) return nil;
    NSRange tail = NSMakeRange(areaStart.location, html.length - areaStart.location);
    NSRange areaEnd = [html rangeOfString:@"</table>" options:0 range:tail];
    NSString *area = (areaEnd.location != NSNotFound)
        ? [html substringWithRange:NSMakeRange(areaStart.location, areaEnd.location - areaStart.location)]
        : [html substringWithRange:tail];

    static NSRegularExpression *iconRE, *nameRE, *descRE, *hrefRE;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        iconRE = [NSRegularExpression regularExpressionWithPattern:@"<img[^>]*class=\"trophy-icon\"[^>]*src=\"([^\"]*)\"|<img[^>]*src=\"([^\"]*)\"[^>]*class=\"trophy-icon\"" options:0 error:nil];
        nameRE = [NSRegularExpression regularExpressionWithPattern:@"class=\"trophy-name\"[^>]*>([^<]*)" options:0 error:nil];
        descRE = [NSRegularExpression regularExpressionWithPattern:@"class=\"trophy-description\"[^>]*>([^<]*)" options:0 error:nil];
        hrefRE = [NSRegularExpression regularExpressionWithPattern:@"<a[^>]*\\shref=\"([^\"]*)\"" options:0 error:nil];
    });

    NSMutableArray *out = [NSMutableArray array];
    NSArray<NSString *> *chunks = [area componentsSeparatedByString:@"<td class=\"trophy-info\""];
    for (NSUInteger i = 1; i < chunks.count; i++) {
        NSString *chunk = chunks[i];
        NSRange full = NSMakeRange(0, chunk.length);

        NSTextCheckingResult *iconMatch = [iconRE firstMatchInString:chunk options:0 range:full];
        NSString *icon = nil;
        if (iconMatch) {
            NSRange r1 = [iconMatch rangeAtIndex:1], r2 = [iconMatch rangeAtIndex:2];
            if (r1.location != NSNotFound) icon = [chunk substringWithRange:r1];
            else if (r2.location != NSNotFound) icon = [chunk substringWithRange:r2];
        }
        NSTextCheckingResult *nameMatch = [nameRE firstMatchInString:chunk options:0 range:full];
        NSString *name = nameMatch ? ApolloBBCollapseWhitespace(ApolloBBDecodeEntities([chunk substringWithRange:[nameMatch rangeAtIndex:1]])) : nil;
        if (name.length == 0 || icon.length == 0) continue;

        NSTextCheckingResult *descMatch = [descRE firstMatchInString:chunk options:0 range:full];
        NSString *desc = descMatch ? ApolloBBCollapseWhitespace(ApolloBBDecodeEntities([chunk substringWithRange:[descMatch rangeAtIndex:1]])) : nil;
        NSTextCheckingResult *hrefMatch = [hrefRE firstMatchInString:chunk options:0 range:full];
        NSString *dest = hrefMatch ? ApolloBBDecodeEntities([chunk substringWithRange:[hrefMatch rangeAtIndex:1]]) : nil;

        NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithDictionary:@{
            @"title": name, @"icon": ApolloBBDecodeEntities(icon) }];
        if (desc.length) entry[@"bio"] = desc;
        if (dest.length) entry[@"dest"] = [dest hasPrefix:@"/"] ? [@"https://www.reddit.com" stringByAppendingString:dest] : dest;
        [out addObject:entry];
    }
    return out;
}

// Old-reddit chrome marker: distinguishes a real page (with or without a trophy
// case) from a block/challenge interstitial.
static BOOL ApolloBBLooksLikeOldRedditPage(NSString *html) {
    return [html rangeOfString:@"id=\"header-bottom-left\""].location != NSNotFound;
}

#pragma mark - Shared joins (used by both the direct and WebView paths)

// Raw scraped trophy dicts {title, image, bio?, dest?} -> catalogue-joined items.
static NSArray<ApolloBadgeItem *> *ApolloBBTrophyItemsFromRaw(NSArray *raw) {
    ApolloBadgeBookCatalog *cat = [ApolloBadgeBookCatalog shared];
    NSMutableArray<ApolloBadgeItem *> *out = [NSMutableArray array];
    for (NSDictionary *d in raw) {
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        NSString *title = ApolloBBStr(d[@"title"]);
        NSString *image = ApolloBBStr(d[@"image"]);
        if (title.length == 0 || image.length == 0) continue;

        NSString *bio = ApolloBBStr(d[@"bio"]);
        NSString *dest = ApolloBBStr(d[@"dest"]);

        // Prefer the bundled catalogue entry (downscaled icon + canonical bio) when
        // the CDN basename matches; otherwise present the live trophy as-is.
        ApolloBadgeItem *catItem = [cat itemMatchingImageURL:image];
        ApolloBadgeItem *item = [[ApolloBadgeItem alloc] init];
        item.kind = ApolloBadgeKindTrophy;
        item.earned = YES;
        if (catItem && catItem.kind == ApolloBadgeKindTrophy) {
            item.identifier = catItem.identifier;
            item.title = catItem.title.length ? catItem.title : title;
            item.bio = catItem.bio.length ? catItem.bio : bio;
            item.imageFile = catItem.imageFile;
            item.imageURLString = catItem.imageURLString ?: image;
            item.destinationURLString = dest.length ? dest : catItem.destinationURLString;
            item.isLiveUncatalogued = NO;
        } else {
            item.identifier = image.lastPathComponent;
            item.title = title;
            item.bio = bio;
            item.imageFile = nil;               // not bundled — async-load imageURLString
            item.imageURLString = image;
            item.destinationURLString = dest;
            item.isLiveUncatalogued = YES;
        }
        [out addObject:item];
    }
    return out;
}

// Old-reddit trophy dicts {title, icon, bio?, dest?} -> catalogue-joined items.
// awards2 icon URLs join by normalized slug (the trophyMatchingIconURL join the
// trophies API uses); the title is the fallback key.
static NSArray<ApolloBadgeItem *> *ApolloBBTrophyItemsFromOldReddit(NSArray *raw) {
    ApolloBadgeBookCatalog *cat = [ApolloBadgeBookCatalog shared];
    NSMutableArray<ApolloBadgeItem *> *out = [NSMutableArray array];
    for (NSDictionary *d in raw) {
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        NSString *title = ApolloBBStr(d[@"title"]);
        NSString *icon = ApolloBBStr(d[@"icon"]);
        if (title.length == 0 || icon.length == 0) continue;
        NSString *bio = ApolloBBStr(d[@"bio"]);
        NSString *dest = ApolloBBStr(d[@"dest"]);

        ApolloBadgeItem *catItem = [cat trophyMatchingIconURL:icon title:title];
        ApolloBadgeItem *item = [[ApolloBadgeItem alloc] init];
        item.kind = ApolloBadgeKindTrophy;
        item.earned = YES;
        if (catItem) {
            item.identifier = catItem.identifier;
            item.title = title;                              // page title carries specifics ("11-Year Club")
            item.bio = bio.length ? bio : catItem.bio;
            item.imageFile = catItem.imageFile;              // bundled downscaled icon — instant
            item.imageURLString = catItem.imageURLString ?: icon;
            item.destinationURLString = dest.length ? dest : catItem.destinationURLString;
            item.isLiveUncatalogued = NO;
        } else {
            // The sidebar serves 40px icons; the 70px variant exists for every
            // awards2 asset and renders much sharper in the grid.
            NSString *bigger = [icon stringByReplacingOccurrencesOfString:@"-40.png" withString:@"-70.png"];
            item.identifier = icon.lastPathComponent;
            item.title = title;
            item.bio = bio;
            item.imageFile = nil;
            item.imageURLString = bigger;
            item.destinationURLString = dest;
            item.isLiveUncatalogued = YES;
        }
        [out addObject:item];
    }
    return out;
}

// Badge dicts {id, unlocked, title, url} -> earned id set + earned art URLs on
// `result`. The achievement-badge `id` attribute IS the catalogue id — join
// directly; unknown-but-earned ids are kept so a badge Reddit ships after our
// catalogue snapshot still counts (set membership is by id either way). The url
// attribute of an EARNED tile is the real artwork — the only source of art for
// catalogue entries whose public image is just the "ghost" placeholder.
static void ApolloBBApplyBadges(ApolloUserBadges *result, NSArray *badges) {
    ApolloBadgeBookCatalog *cat = [ApolloBadgeBookCatalog shared];
    NSMutableSet<NSString *> *earned = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSString *> *artURLs = [NSMutableDictionary dictionary];
    for (NSDictionary *b in badges) {
        if (![b isKindOfClass:[NSDictionary class]]) continue;
        if (![b[@"unlocked"] boolValue]) continue;
        NSString *badgeID = ApolloBBStr(b[@"id"]);
        if (badgeID.length == 0) continue;
        [earned addObject:badgeID];
        NSString *url = ApolloBBStr(b[@"url"]);
        if (url.length) artURLs[badgeID] = url;
        if (![cat achievementWithIdentifier:badgeID]) {
            ApolloLog(@"[BadgeBook] u/%@ earned achievement '%@' not in bundled catalogue", result.username, badgeID);
        }
    }
    result.earnedAchievementIDs = earned;
    result.earnedAchievementImageURLs = artURLs;
}

#pragma mark - Trophy API (parallel accelerator)

// One `t6` dict from /api/v1/user/<name>/trophies -> catalogue-joined ApolloBadgeItem.
// Shape (raw_json=1): {"kind":"t6","data":{"name":"Three-Year Club","description":null,
//   "icon_70":"https://www.redditstatic.com/awards2/3_year_club-70.png","icon_40":...,
//   "url":null|"/r/...", "award_id":..., "id":...}}
static ApolloBadgeItem *ApolloBBItemFromAPITrophyDict(NSDictionary *data) {
    NSString *name = ApolloBBStr(data[@"name"]);
    if (name.length == 0) return nil;
    NSString *desc = ApolloBBStr(data[@"description"]);
    NSString *icon = ApolloBBStr(data[@"icon_70"]) ?: ApolloBBStr(data[@"icon_40"]);
    NSString *urlField = ApolloBBStr(data[@"url"]);

    ApolloBadgeItem *catItem = [[ApolloBadgeBookCatalog shared] trophyMatchingIconURL:icon title:name];
    ApolloBadgeItem *item = [[ApolloBadgeItem alloc] init];
    item.kind = ApolloBadgeKindTrophy;
    item.earned = YES;
    if (catItem) {
        item.identifier = catItem.identifier;
        item.title = name;                                   // API title carries specifics ("12-Year Club")
        item.bio = desc.length ? desc : catItem.bio;
        item.imageFile = catItem.imageFile;                  // bundled downscaled icon — instant
        item.imageURLString = catItem.imageURLString ?: icon;
        item.isLiveUncatalogued = NO;
    } else {
        item.identifier = icon.lastPathComponent.length ? icon.lastPathComponent : name;
        item.title = name;
        item.bio = desc;
        item.imageFile = nil;                                // async-load the API icon
        item.imageURLString = icon;
        item.isLiveUncatalogued = YES;
    }
    if ([urlField hasPrefix:@"/"]) {
        item.destinationURLString = [@"https://www.reddit.com" stringByAppendingString:urlField];
    } else if ([urlField hasPrefix:@"http"]) {
        item.destinationURLString = urlField;
    } else if (catItem.destinationURLString.length) {
        item.destinationURLString = catItem.destinationURLString;
    }
    return item;
}

// Fetch trophies straight from oauth.reddit.com with the bearer token the tweak
// already captures from Apollo's own traffic (sLatestRedditBearerToken — the same
// proven pattern ApolloUserProfileCache / SubredditInfoCache / LinkPreviewFetcher
// use). NOTE: this endpoint currently answers third-party bearers with an HTML
// "forbidden" page (the reason Apollo's native Trophy Case broke) — kept as a
// zero-cost parallel try in case Reddit revives it. NOT RDKClient: `+sharedClient`
// turned out to be an unauthenticated instance in Apollo's multi-account setup.
// Consecutive failures this session. The endpoint has been dead server-side for
// months — after two strikes stop re-asking, so every profile visit isn't
// pinging a dead endpoint (request hygiene; resets on relaunch, so a revived
// endpoint gets picked up again). Main thread only.
static int sApolloBBAPIFailStreak = 0;

static void ApolloBBFetchTrophiesViaAPI(NSString *username, void (^completion)(NSArray<ApolloBadgeItem *> *items, BOOL ok)) {
    NSString *token = [sLatestRedditBearerToken copy];
    if (token.length == 0 || sApolloBBAPIFailStreak >= 2) {
        completion(nil, NO);
        return;
    }

    NSString *urlString = [NSString stringWithFormat:@"https://oauth.reddit.com/api/v1/user/%@/trophies?raw_json=1",
                           ApolloBBEscapedUsername(username)];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 15.0;
    [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [request setValue:(sUserAgent.length > 0 ? sUserAgent : @"ApolloBadgeBook/1.0") forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                 completionHandler:^(NSData *body, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSArray *rawTrophies = nil;
        if (status == 200 && body.length) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
            NSDictionary *data = [json isKindOfClass:[NSDictionary class]] && [json[@"data"] isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;
            if ([data[@"trophies"] isKindOfClass:[NSArray class]]) rawTrophies = data[@"trophies"];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!rawTrophies) {
                sApolloBBAPIFailStreak++;
                completion(nil, NO);
                return;
            }
            sApolloBBAPIFailStreak = 0;
            NSMutableArray<ApolloBadgeItem *> *items = [NSMutableArray array];
            for (NSDictionary *entry in rawTrophies) {
                if (![entry isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *d = [entry[@"data"] isKindOfClass:[NSDictionary class]] ? entry[@"data"] : nil;
                ApolloBadgeItem *item = d ? ApolloBBItemFromAPITrophyDict(d) : nil;
                if (item) [items addObject:item];
            }
            ApolloLog(@"[BadgeBook][api] u/%@ trophies: %lu (API alive!)", username, (unsigned long)items.count);
            completion(items, YES);
        });
    }];
    [task resume];
}

#pragma mark - Direct HTTP fetch (fast path)

// Ephemeral, cookie-jar-free session: the account's web-session cookies ride
// along per-request only, and nothing a response Set-Cookie's is ever stored —
// so this can't poison any shared state (the reason the WebView path needs its
// isolated store dance).
static NSURLSession *ApolloBBDirectSession(void) {
    static NSURLSession *session; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.HTTPCookieStorage = nil;
        config.HTTPShouldSetCookies = NO;
        // timeoutIntervalForRequest is an IDLE timer (resets on every received
        // byte) — a slow-dripping response could hold a leg open indefinitely,
        // wedging this username's pending entry (and every later waiter) for
        // the whole app session. The resource cap is the hard wall-clock bound;
        // 30s covers the ~3MB achievements page on a slow cellular link.
        config.timeoutIntervalForRequest = 12.0;
        config.timeoutIntervalForResource = 30.0;
        config.HTTPAdditionalHeaders = @{ @"Accept-Language": @"en-US,en;q=0.9" };
        session = [NSURLSession sessionWithConfiguration:config];
    });
    return session;
}

// Hard local-connectivity failures — the kind where a WKWebView attempt can't
// do any better than the direct GET just did. Escalating past one of these
// only burns a ~60s hidden-WebView poll (and a queue slot) per profile visit
// while offline. Mirrors ApolloSLIsOfflineErrorCode in ApolloProfileSocialLinks.m.
static BOOL ApolloBBIsOfflineErrorCode(NSInteger code) {
    switch (code) {
        case NSURLErrorNotConnectedToInternet:
        case NSURLErrorNetworkConnectionLost:
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorCannotFindHost:
        case NSURLErrorDNSLookupFailed:
        case NSURLErrorInternationalRoamingOff:
        case NSURLErrorDataNotAllowed:
            return YES;
        default:
            return NO;
    }
}

// GET a Reddit page; completion(html or nil, status, errorCode, elapsed, bytes)
// on the session's BACKGROUND delegate queue — callers parse the (multi-MB)
// HTML right there and hop to main only with the extracted results, so the UI
// thread never touches raw page bytes. errorCode is the NSURLError code on
// transport failure, else 0.
static void ApolloBBGetHTML(NSString *urlString, NSString *cookieHeader,
                            void (^completion)(NSString *html, NSInteger status, NSInteger errorCode, double elapsed, long bytes)) {
    NSURL *url = [NSURL URLWithString:urlString];
    // Tag with the Web JSON probe fragment (never sent over the wire): every
    // task in the process passes through the tweak's _onqueue_resume rewrite,
    // and for web-session accounts a bare /user/<name>/ GET is a whitelisted
    // "listing read" — it would come back as the overview JSON instead of the
    // profile HTML. The fragment is the established "self-authenticating
    // request, leave it alone" marker (probes + upload leases use it too).
    url = ApolloWebJSONProbeURL(url) ?: url;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:kApolloBBDesktopUA forHTTPHeaderField:@"User-Agent"];
    if (cookieHeader.length) [request setValue:cookieHeader forHTTPHeaderField:@"Cookie"];

    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    NSURLSessionDataTask *task = [ApolloBBDirectSession() dataTaskWithRequest:request
                                                           completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        double elapsed = CFAbsoluteTimeGetCurrent() - t0;
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSString *html = (status == 200 && data.length)
            ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        completion(html, status, error.code, elapsed, (long)data.length);
    }];
    [task resume];
}

#pragma mark - WKWebView fallback

typedef NS_ENUM(NSInteger, ApolloBBPhase) {
    ApolloBBPhaseTrophies = 0,
    ApolloBBPhaseAchievements = 1,
};

@interface ApolloBBWebFetch : NSObject <WKNavigationDelegate>
@property(nonatomic, strong) WKWebView *web;
@property(nonatomic, copy) NSString *username;
@property(nonatomic, copy) void (^done)(ApolloUserBadges *);
@property(nonatomic, strong) ApolloUserBadges *result;
@property(nonatomic) ApolloBBPhase phase;
// Phase to begin at. When trophies already resolved (presetTrophies set), the
// scrape starts directly at the achievements page — half the web work.
@property(nonatomic) ApolloBBPhase startPhase;
@property(nonatomic, strong) NSArray<ApolloBadgeItem *> *presetTrophies;
@property(nonatomic) int polls;
@property(nonatomic) int emptyAfterLoaded;
@property(nonatomic) BOOL sawPage;
@property(nonatomic) BOOL holdsSlot;    // owns one of the concurrent-fallback slots
@property(nonatomic) BOOL finished;
@end

@implementation ApolloBBWebFetch

// Give a hydrating/challenged page plenty of room: 3s initial + 2s per poll.
// Reddit's JS bot-challenge typically clears in ~5-10s and then auto-redirects to
// the real page, so a short window could give up mid-challenge.
static int const kApolloBBMaxPolls = 14;

// A fallback scrape puts a full-window, live-rendering WKWebView into the REAL
// key window and loads reddit.com in it for up to ~60s (two phases). Visiting a
// handful of profiles on a network that trips the fallback would otherwise stand
// up that many at once, all rendering behind whatever the user is scrolling. Only
// one runs at a time; the rest queue.
static int const kApolloBBMaxConcurrentWebFetches = 1;
static int sApolloBBActiveWebFetches = 0;   // main thread only
// Waiting scrapes, oldest first. Drained NEWEST first: by the time a slot frees
// up, the newest request is the profile the user is actually looking at, and the
// older ones are screens they scrolled past. Bounded so a long browsing session
// on a fallback-tripping network can't build an endless backlog — the oldest
// entries are dropped (and answered with what they have, i.e. nothing).
static NSUInteger const kApolloBBMaxQueuedWebFetches = 6;

static NSMutableArray<ApolloBBWebFetch *> *ApolloBBWebFetchQueue(void) {
    static NSMutableArray *q; static dispatch_once_t once;
    dispatch_once(&once, ^{ q = [NSMutableArray array]; });
    return q;
}

// Belt-and-braces: the poll loop is bounded, but a WKWebView that never answers
// evaluateJavaScript would hold the single slot forever and stall every queued
// scrape behind it. 3s + 14 polls x 2s per phase, x2 phases, plus slack.
static NSTimeInterval const kApolloBBWebFetchWatchdog = 90.0;

- (void)startForUsername:(NSString *)username completion:(void (^)(ApolloUserBadges *))done {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self startForUsername:username completion:done]; });
        return;
    }
    self.username = username;
    self.done = done;
    self.result = [[ApolloUserBadges alloc] init];
    self.result.username = username;
    if (self.presetTrophies) {
        self.result.trophies = self.presetTrophies;
        self.result.trophiesResolved = YES;
    }
    // Starting directly at achievements only makes sense with a catalogue to join
    // against; without one there is nothing left for the scrape to add.
    if (self.startPhase == ApolloBBPhaseAchievements && ![ApolloBadgeBookCatalog shared].isLoaded) {
        [self finish];
        return;
    }

    // Wait for a free slot before touching the window at all — a queued scrape
    // costs nothing until it actually starts.
    if (!self.holdsSlot) {
        if (sApolloBBActiveWebFetches >= kApolloBBMaxConcurrentWebFetches) {
            NSMutableArray<ApolloBBWebFetch *> *queue = ApolloBBWebFetchQueue();
            if (![queue containsObject:self]) [queue addObject:self];
            ApolloLog(@"[BadgeBook][web] u/%@ queued behind %d active fallback scrape(s) (%lu waiting)",
                      username, sApolloBBActiveWebFetches, (unsigned long)queue.count);
            while (queue.count > kApolloBBMaxQueuedWebFetches) {
                ApolloBBWebFetch *oldest = queue.firstObject;
                [queue removeObjectAtIndex:0];
                ApolloLog(@"[BadgeBook][web] u/%@ dropped from the fallback queue (backlog full)", oldest.username);
                [oldest finish];   // answers its waiters rather than stranding them
            }
            return;
        }
        sApolloBBActiveWebFetches++;
        self.holdsSlot = YES;
        __weak typeof(self) ws = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloBBWebFetchWatchdog * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            typeof(self) ss = ws;
            if (!ss || ss.finished) return;
            ApolloLog(@"[BadgeBook][web] u/%@ watchdog fired — abandoning fallback scrape", ss.username);
            [ss finish];
        });
    }

    UIWindow *win = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) { if (w.isKeyWindow) win = w; }
    }
    if (!win) win = ApolloAllWindows().firstObject;
    if (!win) { [self finish]; return; }

    // Reddit HARD-BLOCKS logged-out page loads from flagged networks — the
    // interstitial literally says "log in to your Reddit account to continue"
    // and has no self-solving script. When the active account has a harvested
    // web session, scrape LOGGED IN with those cookies — seeded into an
    // ISOLATED per-scrape store, never the shared logged-out one (logged-in
    // cookies there would reintroduce the old-reddit preference poison that
    // store exists to avoid). No session -> shared logged-out store, which
    // still works from non-flagged networks.
    ApolloWebSessionEntry *session = ApolloActiveWebSession();
    void (^proceed)(WKWebsiteDataStore *) = ^(WKWebsiteDataStore *store) {
        // The cookie-seed completions below come from WebKit's network
        // process — if one straggles in after the watchdog already ran
        // finish (finished=YES, web still nil so teardown was a no-op),
        // building the WebView now would orphan it in the window forever:
        // finish early-returns on finished and can never tear it down.
        if (self.finished) return;
        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
        config.websiteDataStore = store;
        self.web = [[WKWebView alloc] initWithFrame:win.bounds configuration:config];
        self.web.navigationDelegate = self;
        self.web.alpha = 0.011;
        self.web.userInteractionEnabled = NO;
        self.web.customUserAgent = kApolloBBDesktopUA;
        [win insertSubview:self.web atIndex:0];
        [self loadPhase:self.startPhase];
    };

    if (session.cookieHeader.length == 0) {
        proceed(ApolloSharedScrapeDataStore());
        return;
    }

    // Parse "name=value; name2=value2" into cookies and seed them (async) before
    // the first load. __Host- prefixed cookies must be host-scoped, not domain.
    NSMutableArray<NSHTTPCookie *> *cookies = [NSMutableArray array];
    for (NSString *pair in [session.cookieHeader componentsSeparatedByString:@";"]) {
        NSRange eq = [pair rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *cname = [[pair substringToIndex:eq.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *value = [[pair substringFromIndex:NSMaxRange(eq)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (cname.length == 0) continue;
        NSDictionary *props = @{
            NSHTTPCookieName: cname,
            NSHTTPCookieValue: value,
            NSHTTPCookiePath: @"/",
            NSHTTPCookieDomain: [cname hasPrefix:@"__Host-"] ? @"www.reddit.com" : @".reddit.com",
            NSHTTPCookieSecure: @"TRUE",
        };
        NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:props];
        if (cookie) [cookies addObject:cookie];
    }
    if (cookies.count == 0) {
        proceed(ApolloSharedScrapeDataStore());
        return;
    }
    ApolloLog(@"[BadgeBook][web] u/%@ seeding %lu session cookies (logged-in scrape)",
              username, (unsigned long)cookies.count);
    WKWebsiteDataStore *store = [WKWebsiteDataStore nonPersistentDataStore];
    WKHTTPCookieStore *cookieStore = store.httpCookieStore;
    __block NSUInteger remaining = cookies.count;
    for (NSHTTPCookie *cookie in cookies) {
        [cookieStore setCookie:cookie completionHandler:^{
            if (--remaining == 0) proceed(store);
        }];
    }
}

- (void)loadPhase:(ApolloBBPhase)phase {
    self.phase = phase;
    self.polls = 0;
    self.emptyAfterLoaded = 0;
    self.sawPage = NO;
    NSString *urlString = (phase == ApolloBBPhaseTrophies)
        ? [NSString stringWithFormat:@"https://www.reddit.com/user/%@/", self.username]
        : [NSString stringWithFormat:@"https://www.reddit.com/user/%@/achievements/", self.username];
    ApolloLog(@"[BadgeBook][web] u/%@ loading %@", self.username, (phase == ApolloBBPhaseTrophies) ? @"profile" : @"achievements");
    [self.web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:urlString]]];
    [self pollAfter:3.0];
}

- (void)pollAfter:(double)d {
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [ws poll]; });
}

#pragma mark JS extractors

- (NSString *)trophyExtractionJS {
    return
    @"(function(){"
    "function clean(s){return (s||'').replace(/\\s+/g,' ').trim();}"
    "var loaded=!!document.querySelector('shreddit-app');"
    "var list=document.querySelector('shreddit-profile-trophy-list');"
    "if(!list){return JSON.stringify({ready:document.readyState,loaded:loaded,list:false,title:document.title,len:(document.body?document.body.innerHTML.length:0),trophies:[]});}"
    "var out=[].slice.call(list.querySelectorAll('li')).map(function(li){"
    "var img=li.querySelector('img');var a=li.querySelector('a[href]');"
    "return {title:clean((li.querySelector('.text-body-2')||{}).textContent),"
    "bio:clean((li.querySelector('.text-caption-1.text-secondary-weak')||{}).textContent),"
    "image:img?(img.currentSrc||img.src||img.getAttribute('src')):null,"
    "dest:a?a.href:null};"
    "}).filter(function(t){return t.title&&t.image;});"
    "return JSON.stringify({ready:document.readyState,loaded:loaded,list:true,title:document.title,trophies:out});"
    "})()";
}

// Earned/locked detection from the RAW achievements-page HTML. The live page
// upgrades its badge tiles into shadow DOM (document.querySelectorAll sees
// nothing), but the server-rendered markup is beautifully structured light DOM —
// so we re-fetch the page's own URL (same-origin, session cookies included) and
// parse with DOMParser, which never upgrades custom elements.
- (NSString *)achievementExtractionJS {
    return
    @"(function(){"
    "var loaded=!!document.querySelector('shreddit-app');"
    "if(!window.__bbFetchStarted){window.__bbFetchStarted=1;"
    "fetch(location.href,{credentials:'include'}).then(function(r){return r.text();})"
    ".then(function(h){window.__bbHTML=h;}).catch(function(e){window.__bbErr=String(e);});}"
    "if(window.__bbErr){return JSON.stringify({ready:document.readyState,loaded:loaded,count:0,badges:[],fetchErr:window.__bbErr,title:document.title});}"
    "if(!window.__bbHTML){return JSON.stringify({ready:document.readyState,loaded:false,count:0,badges:[],pending:1,title:document.title,len:(document.body?document.body.innerHTML.length:0)});}"
    "var doc=new DOMParser().parseFromString(window.__bbHTML,'text/html');"
    "var tiles=[].slice.call(doc.querySelectorAll('achievement-badge'));"
    "var badges=tiles.map(function(b){return {id:b.getAttribute('id')||'',"
    "unlocked:((b.getAttribute('unlocked-at')||'').length>0),"
    "title:b.getAttribute('title')||'',"
    "url:b.getAttribute('url')||''};}).filter(function(b){return b.id.length>0;});"
    "return JSON.stringify({ready:document.readyState,loaded:loaded,count:badges.length,badges:badges,title:document.title,len:window.__bbHTML.length});"
    "})()";
}

#pragma mark Poll loop

- (void)poll {
    if (!self.web) return;
    self.polls++;
    NSString *js = (self.phase == ApolloBBPhaseTrophies) ? [self trophyExtractionJS] : [self achievementExtractionJS];
    __weak typeof(self) ws = self;
    [self.web evaluateJavaScript:js completionHandler:^(id res, NSError *e) {
        typeof(self) ss = ws; if (!ss) return;
        NSString *s = [res isKindOfClass:[NSString class]] ? res : @"{}";
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[s dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (![j isKindOfClass:[NSDictionary class]]) j = @{};
        BOOL loaded = [j[@"loaded"] boolValue];
        if (loaded) ss.sawPage = YES;

        if (ss.phase == ApolloBBPhaseTrophies) {
            [ss handleTrophyPoll:j loaded:loaded];
        } else {
            [ss handleAchievementPoll:j loaded:loaded];
        }
    }];
}

- (void)handleTrophyPoll:(NSDictionary *)j loaded:(BOOL)loaded {
    BOOL hasList = [j[@"list"] boolValue];
    NSArray *raw = [j[@"trophies"] isKindOfClass:[NSArray class]] ? j[@"trophies"] : @[];

    if (hasList) {
        self.result.trophies = ApolloBBTrophyItemsFromRaw(raw);
        self.result.trophiesResolved = YES;
        ApolloLog(@"[BadgeBook][web] u/%@ trophies: %lu", self.username, (unsigned long)self.result.trophies.count);
        [self advanceToAchievements];
        return;
    }
    // No trophy list yet. Give hydration a few passes after the page loaded, then
    // accept "no trophy case" and move on.
    if (loaded) {
        self.emptyAfterLoaded++;
        if (self.emptyAfterLoaded >= 3) {
            self.result.trophies = @[];
            self.result.trophiesResolved = YES;
            ApolloLog(@"[BadgeBook][web] u/%@ no trophy case", self.username);
            [self advanceToAchievements];
            return;
        }
    } else if (self.polls == 4 || self.polls == 9) {
        // Still on the interstitial — log what we're actually looking at so a
        // stuck challenge is diagnosable from user logs.
        ApolloLog(@"[BadgeBook][web] u/%@ waiting on profile (poll#%d ready=%@ title=%@ len=%@)",
                  self.username, self.polls, j[@"ready"], j[@"title"], j[@"len"]);
    }
    if (self.polls >= kApolloBBMaxPolls) {
        self.result.trophiesResolved = self.sawPage;
        ApolloLog(@"[BadgeBook][web] u/%@ trophy phase timed out (sawPage=%d title=%@)",
                  self.username, self.sawPage, j[@"title"]);
        [self advanceToAchievements];
        return;
    }
    [self pollAfter:2.0];
}

- (void)advanceToAchievements {
    // The whole feature also works with just the trophy case, so achievements are
    // a best-effort second pass. If the catalogue failed to load there's nothing to
    // join against, so skip it.
    if (![ApolloBadgeBookCatalog shared].isLoaded) { [self finish]; return; }
    [self loadPhase:ApolloBBPhaseAchievements];
}

- (void)handleAchievementPoll:(NSDictionary *)j loaded:(BOOL)loaded {
    NSArray *badges = [j[@"badges"] isKindOfClass:[NSArray class]] ? j[@"badges"] : @[];

    if (badges.count > 0) {
        ApolloBBApplyBadges(self.result, badges);
        self.result.achievementsResolved = YES;
        ApolloLog(@"[BadgeBook][web] u/%@ achievements: %lu tiles -> %lu earned",
                  self.username, (unsigned long)badges.count,
                  (unsigned long)self.result.earnedAchievementIDs.count);
        [self finish];
        return;
    }
    if (loaded) {
        self.emptyAfterLoaded++;
        if (self.emptyAfterLoaded >= 3) {
            // Loaded, but nothing to read — likely login-gated or empty. Leave
            // achievementsResolved=NO so the UI doesn't assert an all-locked state.
            ApolloLog(@"[BadgeBook][web] u/%@ achievements unavailable (empty after load)", self.username);
            [self finish];
            return;
        }
    } else if (self.polls == 4 || self.polls == 9) {
        ApolloLog(@"[BadgeBook][web] u/%@ waiting on achievements (poll#%d ready=%@ title=%@ len=%@)",
                  self.username, self.polls, j[@"ready"], j[@"title"], j[@"len"]);
    }
    if (self.polls >= kApolloBBMaxPolls) {
        ApolloLog(@"[BadgeBook][web] u/%@ achievements phase timed out (sawPage=%d title=%@)",
                  self.username, self.sawPage, j[@"title"]);
        [self finish];
        return;
    }
    [self pollAfter:2.0];
}

#pragma mark Finish

- (void)finish {
    if (self.finished) return;
    self.finished = YES;
    if (self.web) { self.web.navigationDelegate = nil; [self.web stopLoading]; [self.web removeFromSuperview]; self.web = nil; }
    // Release the slot BEFORE the completion so a waiting scrape starts straight
    // away rather than a callback-chain later.
    NSMutableArray<ApolloBBWebFetch *> *queue = ApolloBBWebFetchQueue();
    [queue removeObject:self];
    if (self.holdsSlot) {
        self.holdsSlot = NO;
        sApolloBBActiveWebFetches = MAX(0, sApolloBBActiveWebFetches - 1);
        // One slot freed -> start one waiter, newest first. Hopped through the
        // runloop because a queued start that fails immediately calls finish
        // again, which would re-enter this block.
        ApolloBBWebFetch *next = queue.lastObject;
        if (next) {
            [queue removeLastObject];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (next.finished) return;
                [next startForUsername:next.username completion:next.done];
            });
        }
    }
    ApolloUserBadges *result = self.result;
    void (^d)(ApolloUserBadges *) = self.done; self.done = nil;
    if (d) d(result);
}

- (void)webView:(WKWebView *)wv didFinishNavigation:(WKNavigation *)nav {}

@end

#pragma mark - Public entry

void ApolloBadgeBookFetch(NSString *rawUsername, void (^completion)(ApolloUserBadges *)) {
    NSString *username = ApolloBBNormalizeUsername(rawUsername);
    if (username.length == 0) { if (completion) completion(nil); return; }
    NSString *key = username.lowercaseString;

    ApolloUserBadges *cached = [ApolloBBCache() objectForKey:key];
    if (cached) { if (completion) completion(cached); return; }

    void (^work)(void) = ^{
        NSMutableArray *waiters = ApolloBBPending()[key];
        if (waiters) { if (completion) [waiters addObject:[completion copy]]; return; }

        // Fresh disk-cached result (tiny JSON, sub-ms read) → zero network.
        double ageHours = 0.0;
        ApolloUserBadges *disk = ApolloBBDiskLoad(key, &ageHours);
        if (disk) {
            [ApolloBBCache() setObject:disk forKey:key];
            ApolloLog(@"[BadgeBook][perf] u/%@ served from disk cache (age %.1fh)", username, ageHours);
            if (completion) completion(disk);
            return;
        }

        waiters = [NSMutableArray array];
        if (completion) [waiters addObject:[completion copy]];
        ApolloBBPending()[key] = waiters;

        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        NSUInteger const generation = sApolloBBGeneration;

        void (^deliver)(ApolloUserBadges *) = ^(ApolloUserBadges *result) {
            // Waiters are ALWAYS answered (their data is network-fresh even if an
            // invalidate raced this fetch) — only the cache pin is generation-gated,
            // so a superseded fetch can't reinstate what Invalidate just dropped.
            if (result && generation == sApolloBBGeneration) [ApolloBBCache() setObject:result forKey:key];
            NSArray *toNotify = ApolloBBPending()[key];
            [ApolloBBPending() removeObjectForKey:key];
            for (void (^waiter)(ApolloUserBadges *) in toNotify) waiter(result);
        };

        // Everything below runs on the main queue (all completions hop there).
        ApolloUserBadges *result = [[ApolloUserBadges alloc] init];
        result.username = username;
        __block BOOL delivered = NO;
        __block BOOL userGone = NO;      // a leg saw HTTP 404 — the account doesn't exist
        __block BOOL sawOfflineError = NO; // a leg failed with a hard connectivity error
        __block int directPending = 2;   // profile page + achievements page

        // First component in delivers the (partially-filled) result so the UI
        // paints immediately; the later one merges into the same instance and
        // posts the update notification — existing strip/book observers refresh.
        void (^componentSettled)(void) = ^{
            if (!delivered) {
                if (result.trophiesResolved || result.achievementsResolved) {
                    delivered = YES;
                    ApolloLog(@"[BadgeBook][perf] u/%@ first data in %.2fs (trophies=%d achievements=%d)",
                              username, CFAbsoluteTimeGetCurrent() - t0,
                              result.trophiesResolved, result.achievementsResolved);
                    deliver(result);
                    if (generation == sApolloBBGeneration) ApolloBBDiskSave(result);
                }
                return;
            }
            // Late-leg merge. If an invalidate (pull-to-refresh) superseded this
            // fetch, a newer fetch owns the cache now — repinning this result
            // object would clobber the refreshed data with the stale object. Skip
            // every write, but STILL post the notification: observers re-pull and
            // either find the newer fetch's cache or start a fresh fetch — without
            // this, a refresh that joined this (then-undelivered) fetch's waiters
            // would be left showing its first leg only, with no retry signal.
            if (generation != sApolloBBGeneration) {
                ApolloLog(@"[BadgeBook] u/%@ late leg from a superseded fetch — dropped (observers nudged)", username);
                [[NSNotificationCenter defaultCenter] postNotificationName:ApolloBadgeBookUserUpdatedNotification
                                                                    object:username];
                return;
            }
            [ApolloBBCache() setObject:result forKey:key];   // re-pin in case of eviction
            ApolloBBDiskSave(result);
            [[NSNotificationCenter defaultCenter] postNotificationName:ApolloBadgeBookUserUpdatedNotification
                                                                object:username];
        };

        void (^maybeFallback)(void) = ^{
            BOOL needTrophies = !result.trophiesResolved;
            BOOL needAchievements = !result.achievementsResolved && [ApolloBadgeBookCatalog shared].isLoaded;
            if (!needTrophies && !needAchievements) {
                ApolloLog(@"[BadgeBook][perf] u/%@ complete in %.2fs (direct: %lu trophies, %lu earned achievements)",
                          username, CFAbsoluteTimeGetCurrent() - t0,
                          (unsigned long)result.trophies.count,
                          (unsigned long)result.earnedAchievementIDs.count);
                return;
            }
            // A 404 is definitive (deleted/suspended account) — a hidden WebView
            // pass would just watch the same 404 for 30s.
            if (userGone) {
                ApolloLog(@"[BadgeBook][perf] u/%@ not found (404) — skipping WebView fallback", username);
                if (!delivered) { delivered = YES; deliver(result.trophiesResolved || result.achievementsResolved ? result : nil); }
                return;
            }
            // Hard local-connectivity failure — a hidden WebView can't do better
            // than the direct GETs just did; escalating would only burn a ~60s
            // poll (and the single fallback slot) per profile visit while
            // offline. Fail the fetch instead (never cached), so a later visit
            // retries once the network is back.
            if (sawOfflineError) {
                ApolloLog(@"[BadgeBook][perf] u/%@ offline (no connectivity) — skipping WebView fallback", username);
                if (!delivered) { delivered = YES; deliver(result.trophiesResolved || result.achievementsResolved ? result : nil); }
                return;
            }
            ApolloLog(@"[BadgeBook][perf] u/%@ direct path incomplete after %.2fs (needTrophies=%d needAchievements=%d) — WebView fallback",
                      username, CFAbsoluteTimeGetCurrent() - t0, needTrophies, needAchievements);
            ApolloBBWebFetch *fetch = [[ApolloBBWebFetch alloc] init];
            [ApolloBBFetchers() addObject:fetch];
            if (!needTrophies) {
                fetch.presetTrophies = result.trophies;
                fetch.startPhase = ApolloBBPhaseAchievements;
            } else {
                fetch.startPhase = ApolloBBPhaseTrophies;
            }
            [fetch startForUsername:username completion:^(ApolloUserBadges *late) {
                [ApolloBBFetchers() removeObject:fetch];
                if (late.trophiesResolved && !result.trophiesResolved) {
                    result.trophies = late.trophies;
                    result.trophiesResolved = YES;
                }
                if (late.achievementsResolved && !result.achievementsResolved) {
                    result.earnedAchievementIDs = late.earnedAchievementIDs;
                    result.earnedAchievementImageURLs = late.earnedAchievementImageURLs;
                    result.achievementsResolved = YES;
                }
                ApolloLog(@"[BadgeBook][perf] u/%@ complete in %.2fs (with WebView fallback: trophies=%d achievements=%d)",
                          username, CFAbsoluteTimeGetCurrent() - t0,
                          result.trophiesResolved, result.achievementsResolved);
                if (!delivered) {
                    // Nothing resolved at all -> hard failure: report nil and do
                    // NOT cache, so a later visit retries.
                    if (!result.trophiesResolved && !result.achievementsResolved) {
                        delivered = YES;
                        deliver(nil);
                        return;
                    }
                }
                componentSettled();
            }];
        };

        NSString *cookieHeader = ApolloActiveWebSession().cookieHeader;
        NSString *escaped = ApolloBBEscapedUsername(username);

        // ---- Leg 1: old.reddit profile (Trophy Case) ----
        // Parse on the session's background queue; only the joined results cross
        // to the main thread (result/state are main-thread-only).
        NSString *profileURL = [NSString stringWithFormat:@"https://old.reddit.com/user/%@", escaped];
        ApolloBBGetHTML(profileURL, cookieHeader, ^(NSString *html, NSInteger status, NSInteger errorCode, double elapsed, long bytes) {
            BOOL pageOK = (html != nil && ApolloBBLooksLikeOldRedditPage(html));
            NSArray *raw = pageOK ? ApolloBBParseOldRedditTrophies(html) : nil;  // nil = no trophy case
            NSArray<ApolloBadgeItem *> *items = raw ? ApolloBBTrophyItemsFromOldReddit(raw) : @[];
            NSString *failTitle = pageOK ? nil : ApolloBBPageTitle(html);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (pageOK) {
                    if (!result.trophiesResolved) {
                        result.trophies = items;
                        result.trophiesResolved = YES;
                    }
                    ApolloLog(@"[BadgeBook][perf] u/%@ trophy page %.2fs (%ldKB) -> %lu trophies",
                              username, elapsed, bytes / 1024, (unsigned long)result.trophies.count);
                    componentSettled();
                } else if (status == 404) {
                    // Account gone — "no trophies" is the definitive answer.
                    userGone = YES;
                    result.trophies = @[];
                    result.trophiesResolved = YES;
                    ApolloLog(@"[BadgeBook][perf] u/%@ trophy page 404 — user not found", username);
                    componentSettled();
                } else {
                    if (ApolloBBIsOfflineErrorCode(errorCode)) sawOfflineError = YES;
                    ApolloLog(@"[BadgeBook][perf] u/%@ trophy page direct GET failed (%.2fs http=%ld err=%ld %ldKB title=%@)",
                              username, elapsed, (long)status, (long)errorCode, bytes / 1024, failTitle);
                }
                if (--directPending == 0) maybeFallback();
            });
        });

        // ---- Leg 2: achievements page ----
        if ([ApolloBadgeBookCatalog shared].isLoaded) {
            NSString *achURL = [NSString stringWithFormat:@"https://www.reddit.com/user/%@/achievements/", escaped];
            ApolloBBGetHTML(achURL, cookieHeader, ^(NSString *html, NSInteger status, NSInteger errorCode, double elapsed, long bytes) {
                BOOL pageOK = (html != nil && ApolloBBLooksLikeRedditPage(html));
                NSArray *badges = pageOK ? ApolloBBParseAchievementTags(html) : nil;
                NSString *failTitle = pageOK ? nil : ApolloBBPageTitle(html);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (pageOK) {
                        // Zero tiles on a real page = the user simply has no earned
                        // achievements (other users' pages list only earned ones).
                        ApolloBBApplyBadges(result, badges);
                        result.achievementsResolved = YES;
                        ApolloLog(@"[BadgeBook][perf] u/%@ achievements page %.2fs (%ldKB) -> %lu tiles, %lu earned",
                                  username, elapsed, bytes / 1024,
                                  (unsigned long)badges.count, (unsigned long)result.earnedAchievementIDs.count);
                        componentSettled();
                    } else {
                        if (status == 404) userGone = YES;
                        if (ApolloBBIsOfflineErrorCode(errorCode)) sawOfflineError = YES;
                        ApolloLog(@"[BadgeBook][perf] u/%@ achievements page direct GET failed (%.2fs http=%ld err=%ld %ldKB title=%@)",
                                  username, elapsed, (long)status, (long)errorCode, bytes / 1024, failTitle);
                    }
                    if (--directPending == 0) maybeFallback();
                });
            });
        } else {
            directPending--;
        }

        // ---- Leg 3 (parallel accelerator): official trophies API ----
        ApolloBBFetchTrophiesViaAPI(username, ^(NSArray<ApolloBadgeItem *> *apiTrophies, BOOL apiOK) {
            if (!apiOK || result.trophiesResolved) return;    // page leg won, or API still dead
            result.trophies = apiTrophies ?: @[];
            result.trophiesResolved = YES;
            ApolloLog(@"[BadgeBook][perf] u/%@ trophies via API in %.2fs", username, CFAbsoluteTimeGetCurrent() - t0);
            componentSettled();
        });
    };
    if ([NSThread isMainThread]) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

void ApolloBadgeBookInvalidate(NSString *username) {
    sApolloBBGeneration++;   // strand any in-flight fetch's late cache writes
    NSString *norm = ApolloBBNormalizeUsername(username);
    NSFileManager *fm = [NSFileManager defaultManager];
    if (norm.length == 0) {
        [ApolloBBCache() removeAllObjects];
        for (NSString *file in [fm contentsOfDirectoryAtPath:ApolloBBDiskDir() error:nil]) {
            [fm removeItemAtPath:[ApolloBBDiskDir() stringByAppendingPathComponent:file] error:nil];
        }
        return;
    }
    NSString *key = norm.lowercaseString;
    [ApolloBBCache() removeObjectForKey:key];
    [fm removeItemAtPath:ApolloBBDiskPath(key) error:nil];
}

#if APOLLO_SIM_BUILD
void ApolloBadgeBookDebugSeedResult(ApolloUserBadges *result) {
    NSString *key = ApolloBBNormalizeUsername(result.username).lowercaseString;
    if (key.length == 0) return;
    [ApolloBBCache() setObject:result forKey:key];
}
#endif
