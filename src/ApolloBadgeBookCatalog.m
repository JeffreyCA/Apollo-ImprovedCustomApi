#import "ApolloBadgeBookCatalog.h"
#import "ApolloCommon.h"

#pragma mark - Bundled asset directory resolution

// The generator writes assets into resources/BadgeBook/, which ships as a
// subdirectory of ApolloReborn.bundle. Depending on how the tweak is installed
// that bundle lands in different places, so try each known layout. Mirrors
// ApolloBundledResourcePath()'s roots, plus a flat fallback (assets copied to the
// resource root) so the code keeps working even if the subdirectory is flattened.
NSString *ApolloBadgeBookResourceDirectory(void) {
    static NSString *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSBundle *mainBundle = [NSBundle mainBundle];
        NSString *innerBundlePath = [mainBundle.bundlePath stringByAppendingPathComponent:@"ApolloReborn.bundle"];

        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        // inject-deb-local.sh: rsync'd into <App>.app/ApolloRebornResources/
        [candidates addObject:[mainBundle.bundlePath stringByAppendingPathComponent:@"ApolloRebornResources/BadgeBook"]];
        // cyan / azule / sideload deb + run-in-sim: <App>.app/ApolloReborn.bundle/
        [candidates addObject:[innerBundlePath stringByAppendingPathComponent:@"BadgeBook"]];
        // Loose at the app root
        [candidates addObject:[mainBundle.bundlePath stringByAppendingPathComponent:@"BadgeBook"]];
        // Jailbreak rootful + rootless
        [candidates addObject:@"/Library/Application Support/ApolloReborn/ApolloReborn.bundle/BadgeBook"];
        [candidates addObject:@"/var/jb/Library/Application Support/ApolloReborn/ApolloReborn.bundle/BadgeBook"];
        // Flat fallbacks (assets living directly in the resource root)
        [candidates addObject:[mainBundle.bundlePath stringByAppendingPathComponent:@"ApolloRebornResources"]];
        [candidates addObject:innerBundlePath];
        [candidates addObject:@"/Library/Application Support/ApolloReborn/ApolloReborn.bundle"];
        [candidates addObject:@"/var/jb/Library/Application Support/ApolloReborn/ApolloReborn.bundle"];

        for (NSString *dir in candidates) {
            BOOL isDir = NO;
            NSString *marker = [dir stringByAppendingPathComponent:@"badgebook-catalog.json"];
            if ([fm fileExistsAtPath:marker isDirectory:&isDir] && !isDir) {
                cached = [dir copy];
                break;
            }
        }
        ApolloLog(@"[BadgeBook] resource dir = %@", cached ?: @"(not found)");
    });
    return cached;
}

#pragma mark - Image cache

static NSCache<NSString *, UIImage *> *ApolloBadgeBookImageCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 400;   // whole catalogue fits; icons are ~7KB each
    });
    return cache;
}

#pragma mark - ApolloBadgeItem

@implementation ApolloBadgeItem

// Fully-decoded bundled icon. Decoding is forced at load time (ImageIO
// kCGImageSourceShouldCacheImmediately) so the cached UIImage never lazily
// decompresses during a scroll. Thread-safe (NSCache + ImageIO), but BLOCKING on
// a cache miss (file read + decode) — main-thread callers must go through
// cachedBundledImage/loadBundledImage: instead.
- (UIImage *)bundledImage {
    if (self.imageFile.length == 0) return nil;
    UIImage *cached = [ApolloBadgeBookImageCache() objectForKey:self.imageFile];
    if (cached) return cached;

    NSString *dir = ApolloBadgeBookResourceDirectory();
    if (dir.length == 0) return nil;
    NSString *path = [dir stringByAppendingPathComponent:self.imageFile];
    NSURL *fileURL = [NSURL fileURLWithPath:path];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)fileURL, NULL);
    if (!src) return nil;
    NSDictionary *opts = @{ (id)kCGImageSourceShouldCacheImmediately: @YES };
    CGImageRef cg = CGImageSourceCreateImageAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
    CFRelease(src);
    if (!cg) return nil;
    UIImage *image = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    [ApolloBadgeBookImageCache() setObject:image forKey:self.imageFile];
    return image;
}

- (UIImage *)cachedBundledImage {
    if (self.imageFile.length == 0) return nil;
    return [ApolloBadgeBookImageCache() objectForKey:self.imageFile];
}

// The prewarm gives most callers a warm cache, but it can't be relied on: it is
// itself asynchronous, and a cold launch straight into a profile races it. So
// every UI path goes through here and simply never decodes on main.
- (void)loadBundledImage:(void (^)(UIImage *))completion {
    if (!completion) return;
    if (self.imageFile.length == 0) { completion(nil); return; }
    UIImage *cached = [ApolloBadgeBookImageCache() objectForKey:self.imageFile];
    if (cached) { completion(cached); return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *image = [self bundledImage];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(image); });
    });
}

@end

#pragma mark - Prewarm

void ApolloBadgeBookPrewarmImages(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
            ApolloBadgeBookCatalog *cat = [ApolloBadgeBookCatalog shared];
            NSUInteger n = 0;
            for (ApolloBadgeItem *item in cat.achievements) if ([item bundledImage]) n++;
            for (ApolloBadgeItem *item in cat.trophies) if ([item bundledImage]) n++;
            ApolloLog(@"[BadgeBook][perf] prewarmed %lu bundled icons in %.0fms",
                      (unsigned long)n, (CFAbsoluteTimeGetCurrent() - t0) * 1000.0);
        });
    });
}

#pragma mark - Catalogue

// Normalize a trophy identifier/filename down to its bare slug so the two CDN
// naming schemes join up:
//   "e00bf6b9933ec117_trophy_image_for_6_year_club"  -> "6_year_club"   (catalogue)
//   "6_year_club-70.png"                             -> "6_year_club"   (API awards2)
//   "mod_hof_attendee_26-40"                         -> "mod_hof_attendee_26"
static NSString *ApolloBadgeBookTrophySlug(NSString *name) {
    if (name.length == 0) return nil;
    NSString *s = name.lowercaseString;
    // Drop extension
    NSRange dot = [s rangeOfString:@"." options:NSBackwardsSearch];
    if (dot.location != NSNotFound) s = [s substringToIndex:dot.location];
    // Drop a leading 16-hex-char content hash ("<hash>_...")
    if (s.length > 17) {
        NSString *maybeHash = [s substringToIndex:16];
        NSCharacterSet *nonHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
        if ([s characterAtIndex:16] == '_' && [maybeHash rangeOfCharacterFromSet:nonHex].location == NSNotFound) {
            s = [s substringFromIndex:17];
        }
    }
    // Drop the shreddit prefix
    NSRange marker = [s rangeOfString:@"trophy_image_for_"];
    if (marker.location != NSNotFound) s = [s substringFromIndex:NSMaxRange(marker)];
    // Drop a trailing "-<digits>" size suffix ("...-70", "...-40")
    NSRange dash = [s rangeOfString:@"-" options:NSBackwardsSearch];
    if (dash.location != NSNotFound && dash.location + 1 < s.length) {
        NSString *tail = [s substringFromIndex:dash.location + 1];
        NSCharacterSet *nonDigit = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
        if ([tail rangeOfCharacterFromSet:nonDigit].location == NSNotFound) s = [s substringToIndex:dash.location];
    }
    return s.length ? s : nil;
}

// Last path component of a URL, ignoring any query/fragment — the stable Reddit
// CDN filename we key catalogue lookups on (e.g. "mgol2ep2mnwd1.png").
static NSString *ApolloBadgeBookURLBasename(NSString *urlString) {
    if (urlString.length == 0) return nil;
    NSString *s = urlString;
    NSRange q = [s rangeOfString:@"?"];
    if (q.location != NSNotFound) s = [s substringToIndex:q.location];
    NSRange h = [s rangeOfString:@"#"];
    if (h.location != NSNotFound) s = [s substringToIndex:h.location];
    return s.lastPathComponent.lowercaseString;
}

@interface ApolloBadgeBookCatalog ()
@property(nonatomic, strong) NSArray<ApolloBadgeItem *> *achievements;
@property(nonatomic, strong) NSArray<ApolloBadgeItem *> *trophies;
@property(nonatomic, strong) NSArray<NSString *> *achievementCategories;
@property(nonatomic, strong) NSDictionary<NSString *, ApolloBadgeItem *> *achievementsByID;
@property(nonatomic, strong) NSDictionary<NSString *, ApolloBadgeItem *> *itemsByImageBasename;
@property(nonatomic, strong) NSDictionary<NSString *, ApolloBadgeItem *> *trophiesBySlug;
@property(nonatomic, strong) NSDictionary<NSString *, ApolloBadgeItem *> *trophiesByTitle;
@property(nonatomic, strong) NSDictionary<NSString *, NSArray<ApolloBadgeItem *> *> *achievementsByCategory;
@property(nonatomic) BOOL isLoaded;
@end

@implementation ApolloBadgeBookCatalog

+ (instancetype)shared {
    static ApolloBadgeBookCatalog *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[ApolloBadgeBookCatalog alloc] init];
        [shared load];
    });
    return shared;
}

- (void)load {
    self.achievements = @[];
    self.trophies = @[];
    self.achievementCategories = @[];
    self.achievementsByID = @{};
    self.itemsByImageBasename = @{};
    self.achievementsByCategory = @{};

    NSString *dir = ApolloBadgeBookResourceDirectory();
    if (dir.length == 0) { ApolloLog(@"[BadgeBook] catalogue dir missing; book disabled"); return; }
    NSString *path = [dir stringByAppendingPathComponent:@"badgebook-catalog.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) { ApolloLog(@"[BadgeBook] catalogue json unreadable at %@", path); return; }

    NSError *err = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (![json isKindOfClass:[NSDictionary class]]) {
        ApolloLog(@"[BadgeBook] catalogue json parse failed: %@", err.localizedDescription);
        return;
    }

    NSMutableDictionary<NSString *, ApolloBadgeItem *> *byID = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, ApolloBadgeItem *> *byBasename = [NSMutableDictionary dictionary];

    // Achievements
    NSMutableArray<ApolloBadgeItem *> *ach = [NSMutableArray array];
    for (NSDictionary *d in ([json[@"achievements"] isKindOfClass:[NSArray class]] ? json[@"achievements"] : @[])) {
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        ApolloBadgeItem *item = [self itemFromDict:d kind:ApolloBadgeKindAchievement];
        if (!item) continue;
        [ach addObject:item];
        if (item.identifier.length) byID[item.identifier] = item;
        NSString *base = ApolloBadgeBookURLBasename(item.imageURLString);
        if (base.length) byBasename[base] = item;
    }
    self.achievements = ach;
    self.achievementsByID = byID;

    // Trophies
    NSMutableArray<ApolloBadgeItem *> *tro = [NSMutableArray array];
    NSMutableDictionary<NSString *, ApolloBadgeItem *> *bySlug = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, ApolloBadgeItem *> *byTitle = [NSMutableDictionary dictionary];
    for (NSDictionary *d in ([json[@"trophies"] isKindOfClass:[NSArray class]] ? json[@"trophies"] : @[])) {
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        ApolloBadgeItem *item = [self itemFromDict:d kind:ApolloBadgeKindTrophy];
        if (!item) continue;
        [tro addObject:item];
        NSString *base = ApolloBadgeBookURLBasename(item.imageURLString);
        if (base.length && !byBasename[base]) byBasename[base] = item;
        NSString *slug = ApolloBadgeBookTrophySlug(item.identifier);
        if (slug.length && !bySlug[slug]) bySlug[slug] = item;
        NSString *titleKey = item.title.lowercaseString;
        if (titleKey.length && !byTitle[titleKey]) byTitle[titleKey] = item;
    }
    self.trophies = tro;
    self.itemsByImageBasename = byBasename;
    self.trophiesBySlug = bySlug;
    self.trophiesByTitle = byTitle;

    // Category order (explicit list from the generator, else derived from data).
    NSArray *cats = json[@"achievement_categories"];
    if (![cats isKindOfClass:[NSArray class]] || cats.count == 0) {
        NSMutableArray *derived = [NSMutableArray array];
        for (ApolloBadgeItem *a in ach) {
            if (a.category.length && ![derived containsObject:a.category]) [derived addObject:a.category];
        }
        cats = derived;
    }
    self.achievementCategories = cats;

    NSMutableDictionary<NSString *, NSMutableArray<ApolloBadgeItem *> *> *byCat = [NSMutableDictionary dictionary];
    for (ApolloBadgeItem *a in ach) {
        NSString *c = a.category.length ? a.category : @"";
        NSMutableArray *list = byCat[c];
        if (!list) { list = [NSMutableArray array]; byCat[c] = list; }
        [list addObject:a];
    }
    self.achievementsByCategory = byCat;

    self.isLoaded = YES;
    ApolloLog(@"[BadgeBook] catalogue loaded: %lu achievements, %lu trophies, %lu categories",
              (unsigned long)ach.count, (unsigned long)tro.count, (unsigned long)cats.count);
}

- (ApolloBadgeItem *)itemFromDict:(NSDictionary *)d kind:(ApolloBadgeKind)kind {
    NSString *identifier = [d[@"id"] isKindOfClass:[NSString class]] ? d[@"id"] : nil;
    NSString *title = [d[@"title"] isKindOfClass:[NSString class]] ? d[@"title"] : nil;
    if (identifier.length == 0 || title.length == 0) return nil;

    ApolloBadgeItem *item = [[ApolloBadgeItem alloc] init];
    item.kind = kind;
    item.identifier = identifier;
    item.title = title;
    item.bio = [d[@"bio"] isKindOfClass:[NSString class]] ? d[@"bio"] : nil;
    item.category = [d[@"category"] isKindOfClass:[NSString class]] ? d[@"category"] : nil;
    item.imageFile = [d[@"image"] isKindOfClass:[NSString class]] ? d[@"image"] : nil;
    item.imageURLString = [d[@"image_url"] isKindOfClass:[NSString class]] ? d[@"image_url"] : nil;
    item.destinationURLString = [d[@"destination_url"] isKindOfClass:[NSString class]] ? d[@"destination_url"] : nil;
    return item;
}

- (NSArray<ApolloBadgeItem *> *)achievementsInCategory:(NSString *)category {
    return self.achievementsByCategory[category ?: @""] ?: @[];
}

- (ApolloBadgeItem *)achievementWithIdentifier:(NSString *)identifier {
    if (identifier.length == 0) return nil;
    return self.achievementsByID[identifier];
}

- (ApolloBadgeItem *)itemMatchingImageURL:(NSString *)urlString {
    NSString *base = ApolloBadgeBookURLBasename(urlString);
    if (base.length == 0) return nil;
    return self.itemsByImageBasename[base];
}

- (ApolloBadgeItem *)trophyMatchingIconURL:(NSString *)iconURLString title:(NSString *)title {
    NSString *slug = ApolloBadgeBookTrophySlug(ApolloBadgeBookURLBasename(iconURLString));
    if (slug.length) {
        ApolloBadgeItem *bySlug = self.trophiesBySlug[slug];
        if (bySlug) return bySlug;
    }
    NSString *titleKey = title.lowercaseString;
    if (titleKey.length) return self.trophiesByTitle[titleKey];
    return nil;
}

@end
