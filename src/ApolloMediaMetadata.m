#import "ApolloMediaMetadata.h"

static BOOL ApolloStringIsNonEmpty(NSString *string) {
    return [string isKindOfClass:[NSString class]] && string.length > 0;
}

static NSString *ApolloLowercaseString(NSString *string) {
    return ApolloStringIsNonEmpty(string) ? string.lowercaseString : @"";
}

static BOOL ApolloURLHostIsRedditPreview(NSString *urlString) {
    NSString *lower = ApolloLowercaseString(urlString);
    return [lower containsString:@"preview.redd.it"] || [lower containsString:@"external-preview.redd.it"];
}

static BOOL ApolloURLIsRedditStaticPreview(NSString *urlString) {
    if (!ApolloURLHostIsRedditPreview(urlString)) return NO;
    NSString *lower = ApolloLowercaseString(urlString);
    return [lower containsString:@"format=png8"] || [lower containsString:@"format=pjpg"] || [lower containsString:@"format=webp"];
}

static BOOL ApolloURLIsRedditPseudoMP4GIF(NSString *urlString) {
    return ApolloURLHostIsRedditPreview(urlString) && [ApolloLowercaseString(urlString) containsString:@"format=mp4"];
}

static BOOL ApolloURLIsRedditHostedGIFSource(NSString *urlString) {
    if (!ApolloStringIsNonEmpty(urlString)) return NO;
    NSString *lower = ApolloLowercaseString(urlString);
    if ([lower containsString:@"i.redd.it"] && [lower hasSuffix:@".gif"]) return YES;
    if (ApolloURLIsRedditPseudoMP4GIF(urlString)) return YES;
    return NO;
}

BOOL ApolloMetadataEntryIsRedditHostedGIF(NSString *assetID, NSDictionary *entry) {
    if (!ApolloStringIsNonEmpty(assetID) || [assetID hasPrefix:@"giphy|"]) return NO;
    if (![entry isKindOfClass:[NSDictionary class]]) return NO;

    if ([entry[@"m"] isEqualToString:@"image/gif"]) return YES;

    if ([entry[@"e"] isEqualToString:@"AnimatedImage"]) return YES;

    NSDictionary *source = [entry[@"s"] isKindOfClass:[NSDictionary class]] ? entry[@"s"] : nil;
    if (source) {
        for (NSString *key in @[@"gif", @"mp4", @"u"]) {
            if (ApolloURLIsRedditHostedGIFSource(source[key])) return YES;
        }
    }

    return NO;
}

NSString *ApolloRedditHostedGIFDisplayURL(NSString *assetID) {
    if (!ApolloStringIsNonEmpty(assetID) || [assetID hasPrefix:@"giphy|"]) return nil;
    return [NSString stringWithFormat:@"https://i.redd.it/%@.gif", assetID];
}

// A Reddit-hosted GIF entry only needs our normalization when Reddit's own
// metadata is incomplete (e.g. a freshly uploaded GIF that came back not-yet
// "valid", missing the AnimatedImage type, or lacking a usable source URL).
// Healthy entries — which already carry an efficient signed
// `preview.redd.it/<id>.gif?format=mp4` in `s.mp4` that the gallery/album
// viewer streams — must be left untouched so we don't downgrade playback to
// the full `i.redd.it/<id>.gif`.
static BOOL ApolloRedditHostedGifEntryNeedsNormalization(NSDictionary *entry) {
    if (![[entry objectForKey:@"status"] isEqualToString:@"valid"]) return YES;
    if (![[entry objectForKey:@"e"] isEqualToString:@"AnimatedImage"]) return YES;
    if (![[entry objectForKey:@"m"] isEqualToString:@"image/gif"]) return YES;
    NSDictionary *source = [entry[@"s"] isKindOfClass:[NSDictionary class]] ? entry[@"s"] : nil;
    if (!ApolloStringIsNonEmpty(source[@"gif"])) return YES;
    if (!ApolloStringIsNonEmpty(source[@"mp4"])) return YES;
    return NO;
}

NSDictionary *ApolloFixRedditHostedGifMetadata(NSDictionary *orig, NSUInteger *outFixedCount) {
    if (outFixedCount) *outFixedCount = 0;
    if (![orig isKindOfClass:[NSDictionary class]] || orig.count == 0) return orig;

    NSMutableDictionary *fixed = nil;
    NSUInteger fixedCount = 0;

    for (NSString *key in orig) {
        if (!ApolloStringIsNonEmpty(key) || [key hasPrefix:@"giphy|"]) continue;

        NSDictionary *entry = orig[key];
        if (!ApolloMetadataEntryIsRedditHostedGIF(key, entry)) continue;
        // Only repair entries Reddit returned incomplete. Skipping healthy
        // entries preserves their efficient signed `preview.redd.it ...
        // format=mp4` source, fixing the regression where the gallery viewer
        // started streaming full `i.redd.it/<id>.gif` files (stuck spinner).
        if (!ApolloRedditHostedGifEntryNeedsNormalization(entry)) continue;

        NSString *gifURL = ApolloRedditHostedGIFDisplayURL(key);
        if (!gifURL) continue;

        if (!fixed) fixed = [orig mutableCopy];

        NSDictionary *existingSource = [entry[@"s"] isKindOfClass:[NSDictionary class]] ? entry[@"s"] : nil;
        NSMutableDictionary *source = existingSource ? [existingSource mutableCopy] : [NSMutableDictionary dictionary];
        // Synthesize only the source URLs Reddit left missing. Never overwrite
        // an existing value: a present `mp4` is Reddit's efficient signed
        // preview that the gallery streams, and a present `gif` already points
        // at the animatable i.redd.it asset. A missing `mp4` must still resolve
        // to an animatable GIF (otherwise Apollo opens it in a webview).
        if (!ApolloStringIsNonEmpty(source[@"gif"])) source[@"gif"] = gifURL;
        if (!ApolloStringIsNonEmpty(source[@"mp4"])) source[@"mp4"] = gifURL;

        NSMutableDictionary *normalized = [entry mutableCopy];
        normalized[@"status"] = @"valid";
        normalized[@"e"] = @"AnimatedImage";
        normalized[@"m"] = @"image/gif";
        normalized[@"s"] = [source copy];
        normalized[@"id"] = key;
        fixed[key] = [normalized copy];
        fixedCount++;
    }

    if (outFixedCount) *outFixedCount = fixedCount;
    return fixed ?: orig;
}

static NSString *ApolloFirstNonPreviewSourceURL(NSDictionary *source, BOOL preferMP4ForExternalGIFs) {
    if (![source isKindOfClass:[NSDictionary class]]) return nil;

    NSArray<NSString *> *keys = preferMP4ForExternalGIFs
        ? @[@"mp4", @"gif", @"u"]
        : @[@"gif", @"mp4", @"u"];

    for (NSString *key in keys) {
        NSString *candidate = source[key];
        if (!ApolloStringIsNonEmpty(candidate)) continue;
        if (ApolloURLIsRedditStaticPreview(candidate) || ApolloURLIsRedditPseudoMP4GIF(candidate)) continue;
        return candidate;
    }
    return nil;
}

NSString *ApolloMediaDisplayURLFromMetadataEntry(NSString *assetID,
                                                 NSDictionary *entry,
                                                 BOOL preferMP4ForExternalGIFs) {
    if (!ApolloStringIsNonEmpty(assetID) || ![entry isKindOfClass:[NSDictionary class]]) return nil;
    if (![[entry objectForKey:@"status"] isEqualToString:@"valid"]) return nil;

    if (ApolloMetadataEntryIsRedditHostedGIF(assetID, entry)) {
        return ApolloRedditHostedGIFDisplayURL(assetID);
    }

    NSDictionary *source = [entry[@"s"] isKindOfClass:[NSDictionary class]] ? entry[@"s"] : nil;
    NSString *url = ApolloFirstNonPreviewSourceURL(source, preferMP4ForExternalGIFs);
    if (!url) {
        NSArray *previews = entry[@"p"];
        if ([previews isKindOfClass:[NSArray class]] && previews.count > 0) {
            url = [previews.lastObject objectForKey:@"u"];
            if (ApolloURLIsRedditStaticPreview(url) || ApolloURLIsRedditPseudoMP4GIF(url)) {
                url = nil;
            }
        }
    }

    return ApolloStringIsNonEmpty(url) ? url : nil;
}
