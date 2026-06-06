#import "ApolloLinkPreviewFetcher.h"
#import "ApolloBannedProfile.h"
#import "ApolloUserProfileCache.h"

#import "ApolloCommon.h"
#import "ApolloLinkPreviewCache.h"
#import "ApolloState.h"
#import "ApolloSubredditInfoCache.h"
#import "ApolloUserProfileCache.h"

static const NSUInteger ApolloLinkPreviewMaxHTMLBytes = 2 * 1024 * 1024;

typedef void (^ApolloLinkPreviewCompletion)(ApolloLinkPreview *preview);

static dispatch_queue_t ApolloLinkPreviewFetcherQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.apollo.linkpreviews.fetcher", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSMutableDictionary<NSString *, NSMutableArray<ApolloLinkPreviewCompletion> *> *ApolloLinkPreviewPendingFetches(void) {
    static NSMutableDictionary *pending;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pending = [NSMutableDictionary dictionary];
    });
    return pending;
}

// Decode every &#NNN; and &#xHH; numeric entity to its actual Unicode scalar.
// Walks the string in one pass so we don't run a regex over every shared input.
static NSString *ApolloLinkPreviewDecodeNumericEntities(NSString *string) {
    if (string.length == 0) return string;
    NSRange amp = [string rangeOfString:@"&#"];
    if (amp.location == NSNotFound) return string;

    NSMutableString *out = [NSMutableString stringWithCapacity:string.length];
    NSScanner *scanner = [NSScanner scannerWithString:string];
    scanner.charactersToBeSkipped = nil;
    NSCharacterSet *hexDigits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    NSCharacterSet *decDigits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"];

    while (!scanner.atEnd) {
        NSString *chunk = nil;
        if ([scanner scanUpToString:@"&#" intoString:&chunk]) {
            [out appendString:chunk];
        }
        if (scanner.atEnd) break;

        NSUInteger savedLocation = scanner.scanLocation;
        // Consume the "&#" prefix.
        scanner.scanLocation = savedLocation + 2;

        BOOL isHex = NO;
        if (scanner.scanLocation < string.length) {
            unichar maybeX = [string characterAtIndex:scanner.scanLocation];
            if (maybeX == 'x' || maybeX == 'X') {
                isHex = YES;
                scanner.scanLocation += 1;
            }
        }

        NSString *digits = nil;
        BOOL gotDigits = [scanner scanCharactersFromSet:(isHex ? hexDigits : decDigits) intoString:&digits];
        BOOL terminated = NO;
        if (gotDigits && scanner.scanLocation < string.length && [string characterAtIndex:scanner.scanLocation] == ';') {
            terminated = YES;
            scanner.scanLocation += 1;
        }

        if (!gotDigits || !terminated) {
            // Malformed entity; copy the literal "&" and resume scanning right after it.
            [out appendString:@"&"];
            scanner.scanLocation = savedLocation + 1;
            continue;
        }

        unsigned int scalar = 0;
        NSScanner *numScanner = [NSScanner scannerWithString:digits];
        BOOL parsed = isHex ? [numScanner scanHexInt:&scalar] : [numScanner scanInt:(int *)&scalar];
        if (!parsed || scalar == 0 || scalar > 0x10FFFF) {
            // Garbage value; drop the entity entirely.
            continue;
        }

        if (scalar <= 0xFFFF) {
            [out appendFormat:@"%C", (unichar)scalar];
        } else {
            uint32_t v = scalar - 0x10000;
            unichar high = (unichar)(0xD800 + (v >> 10));
            unichar low = (unichar)(0xDC00 + (v & 0x3FF));
            [out appendFormat:@"%C%C", high, low];
        }
    }

    return out;
}

static NSString *ApolloLinkPreviewDecodeCommonNamedEntities(NSString *string) {
    NSString *clean = string;
    clean = [clean stringByReplacingOccurrencesOfString:@"&nbsp;" withString:@" "];
    clean = [clean stringByReplacingOccurrencesOfString:@"&quot;" withString:@"\""];
    clean = [clean stringByReplacingOccurrencesOfString:@"&apos;" withString:@"'"];
    clean = [clean stringByReplacingOccurrencesOfString:@"&lsquo;" withString:@"'"];
    clean = [clean stringByReplacingOccurrencesOfString:@"&rsquo;" withString:@"'"];
    clean = [clean stringByReplacingOccurrencesOfString:@"&sbquo;" withString:@"'"];
    clean = [clean stringByReplacingOccurrencesOfString:@"&ldquo;" withString:@"\""];
    clean = [clean stringByReplacingOccurrencesOfString:@"&rdquo;" withString:@"\""];
    clean = [clean stringByReplacingOccurrencesOfString:@"&bdquo;" withString:@"\""];
    clean = [clean stringByReplacingOccurrencesOfString:@"&ndash;" withString:@"-"];
    clean = [clean stringByReplacingOccurrencesOfString:@"&mdash;" withString:@"-"];
    clean = [clean stringByReplacingOccurrencesOfString:@"&hellip;" withString:@"..."];
    clean = [clean stringByReplacingOccurrencesOfString:@"&lt;" withString:@"<"];
    clean = [clean stringByReplacingOccurrencesOfString:@"&gt;" withString:@">"];
    // &amp; last so we don't double-decode embedded entities.
    clean = [clean stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    return clean;
}

static NSString *ApolloLinkPreviewCleanString(NSString *string) {
    if (![string isKindOfClass:[NSString class]]) return nil;
    NSString *clean = ApolloLinkPreviewDecodeCommonNamedEntities(ApolloLinkPreviewDecodeNumericEntities(string));
    clean = [clean stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    NSRegularExpression *whitespace = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
    clean = [whitespace stringByReplacingMatchesInString:clean options:0 range:NSMakeRange(0, clean.length) withTemplate:@" "];
    return clean.length > 0 ? clean : nil;
}

static NSString *ApolloLinkPreviewCleanMultilineString(NSString *string) {
    if (![string isKindOfClass:[NSString class]]) return nil;
    NSString *clean = ApolloLinkPreviewDecodeCommonNamedEntities(ApolloLinkPreviewDecodeNumericEntities(string));
    clean = [clean stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    clean = [clean stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];

    NSRegularExpression *inlineWhitespace = [NSRegularExpression regularExpressionWithPattern:@"[\\t\\f\\v ]+" options:0 error:nil];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    BOOL lastLineWasBlank = YES;
    for (NSString *line in [clean componentsSeparatedByString:@"\n"]) {
        NSString *trimmedLine = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        trimmedLine = [inlineWhitespace stringByReplacingMatchesInString:trimmedLine
                                                                 options:0
                                                                   range:NSMakeRange(0, trimmedLine.length)
                                                            withTemplate:@" "];
        if (trimmedLine.length == 0) {
            if (!lastLineWasBlank) {
                [lines addObject:@""];
                lastLineWasBlank = YES;
            }
            continue;
        }
        [lines addObject:trimmedLine];
        lastLineWasBlank = NO;
    }
    while (lines.count > 0 && lines.lastObject.length == 0) {
        [lines removeLastObject];
    }
    NSString *joined = [lines componentsJoinedByString:@"\n"];
    return joined.length > 0 ? joined : nil;
}

// Returns YES when the supplied URL points at a subreddit listing or a user
// profile / overview rather than an individual post. Reddit's anti-bot wall
// will hand any unauthenticated scrape a "Please wait for verification" page
// for these, so we'd rather punt back to Apollo's native subreddit card.
static BOOL ApolloLinkPreviewIsRedditListingURL(NSURL *url) {
    NSString *host = url.host.lowercaseString ?: @"";
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    if (![host isEqualToString:@"reddit.com"] && ![host hasSuffix:@".reddit.com"]) return NO;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in [url.path componentsSeparatedByString:@"/"]) {
        if (part.length > 0) [parts addObject:part.lowercaseString];
    }
    if (parts.count == 0) return YES;

    NSString *first = parts[0];
    if (![first isEqualToString:@"r"] && ![first isEqualToString:@"user"] && ![first isEqualToString:@"u"]) {
        return NO;
    }
    if (parts.count < 2) return YES;
    if ([parts containsObject:@"comments"]) return NO;

    // /r/foo, /r/foo/, /r/foo/new, /r/foo/about, /user/bar, /user/bar/submitted, ...
    return YES;
}

static NSString *ApolloRedditUsernameFromProfileURL(NSURL *url) {
    NSString *host = url.host.lowercaseString ?: @"";
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    if (![host isEqualToString:@"reddit.com"] && ![host hasSuffix:@".reddit.com"]) return nil;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in [url.path componentsSeparatedByString:@"/"]) {
        if (part.length > 0) [parts addObject:part];
    }
    if (parts.count < 2) return nil;

    NSString *kind = parts[0].lowercaseString;
    if (![kind isEqualToString:@"u"] && ![kind isEqualToString:@"user"]) return nil;
    for (NSString *part in parts) {
        if ([part.lowercaseString isEqualToString:@"comments"]) return nil;
    }

    NSString *username = [parts[1] stringByRemovingPercentEncoding] ?: parts[1];
    if (username.length == 0) return nil;
    NSMutableCharacterSet *allowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"_-"];
    if ([username rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return nil;
    return username;
}

static NSString *ApolloRedditSubredditFromURL(NSURL *url) {
    NSString *host = url.host.lowercaseString ?: @"";
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    if (![host isEqualToString:@"reddit.com"] && ![host hasSuffix:@".reddit.com"]) return nil;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in [url.path componentsSeparatedByString:@"/"]) {
        if (part.length > 0) [parts addObject:part];
    }
    if (parts.count < 2) return nil;

    NSString *kind = parts[0].lowercaseString;
    if (![kind isEqualToString:@"r"]) return nil;
    for (NSString *part in parts) {
        if ([part.lowercaseString isEqualToString:@"comments"]) return nil;
    }

    NSString *subreddit = [parts[1] stringByRemovingPercentEncoding] ?: parts[1];
    if (subreddit.length == 0) return nil;
    NSMutableCharacterSet *allowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"_-"];
    if ([subreddit rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return nil;
    return subreddit;
}

static NSString *ApolloLinkPreviewRedditUsernameFromListingURL(NSURL *url) {
    if (!ApolloLinkPreviewIsRedditListingURL(url)) return nil;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in [url.path componentsSeparatedByString:@"/"]) {
        if (part.length > 0) [parts addObject:part];
    }
    if (parts.count < 2) return nil;
    NSString *first = [parts[0] lowercaseString];
    if (![first isEqualToString:@"user"] && ![first isEqualToString:@"u"]) return nil;
    NSString *username = parts[1];
    if ([username isEqualToString:@"[deleted]"]) return nil;
    return username;
}

// Sniffs the supplied HTML for the giveaway signatures of an anti-bot
// challenge page (Reddit's "Please wait for verification", Cloudflare's
// "Just a moment", Akamai, etc.). When we see one we mark the preview as
// noMetadata so Apollo's classic card shows through.
static BOOL ApolloLinkPreviewIsBlockedPage(NSString *title, NSString *html) {
    NSArray<NSString *> *titleNeedles = @[
        @"please wait for verification",
        @"just a moment",
        @"attention required",
        @"one more step",
        @"access denied",
        @"are you a robot",
        @"verifying you are human",
        // Nature.com fronts most article pages with a Cloudflare interstitial
        // whose <title> is literally "Client Challenge". Treat it as a wall so
        // we never cache that as the preview title.
        @"client challenge",
    ];
    NSString *lowerTitle = title.lowercaseString;
    for (NSString *needle in titleNeedles) {
        if (lowerTitle.length > 0 && [lowerTitle containsString:needle]) return YES;
    }

    if (html.length > 0 && html.length < 16 * 1024) {
        NSString *lowerHTML = html.lowercaseString;
        if ([lowerHTML containsString:@"verifying you are human"]) return YES;
        if ([lowerHTML containsString:@"cf-challenge"]) return YES;
        if ([lowerHTML containsString:@"cf_chl_opt"]) return YES;
    }
    return NO;
}

static NSString *ApolloLinkPreviewTruncatedString(NSString *string, NSUInteger maxLength) {
    NSString *clean = ApolloLinkPreviewCleanString(string);
    if (clean.length <= maxLength) return clean;
    return [[clean substringToIndex:maxLength] stringByAppendingString:@"..."];
}

static BOOL ApolloLinkPreviewURLIsHTTP(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString;
    return [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
}

static NSURL *ApolloLinkPreviewBaseURLForRelativeResource(NSURL *baseURL, NSString *resourceString) {
    if (!baseURL || resourceString.length == 0) return baseURL;
    if ([resourceString hasPrefix:@"/"] || [resourceString hasPrefix:@"//"]) return baseURL;
    if ([resourceString rangeOfString:@"://"].location != NSNotFound) return baseURL;
    if ([baseURL.path hasSuffix:@"/"] || baseURL.pathExtension.length > 0) return baseURL;

    NSURLComponents *components = [NSURLComponents componentsWithURL:baseURL resolvingAgainstBaseURL:NO];
    if (!components) return baseURL;
    NSString *path = components.path ?: @"";
    if (path.length == 0) path = @"/";
    if (![path hasSuffix:@"/"]) path = [path stringByAppendingString:@"/"];
    components.path = path;
    components.query = nil;
    components.fragment = nil;
    return components.URL ?: baseURL;
}

static NSString *ApolloLinkPreviewHost(NSURL *url) {
    NSString *host = url.host.lowercaseString ?: @"";
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    return host;
}

static NSDictionary *ApolloLinkPreviewDictionaryValue(id value) {
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

static NSArray *ApolloLinkPreviewArrayValue(id value) {
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

static NSString *ApolloLinkPreviewStringValue(id value) {
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static BOOL ApolloLinkPreviewHostIs(NSURL *url, NSString *host) {
    NSString *lowerHost = ApolloLinkPreviewHost(url);
    return [lowerHost isEqualToString:host] || [lowerHost hasSuffix:[@"." stringByAppendingString:host]];
}

static NSString *ApolloRedditPostIDFromURL(NSURL *url) {
    NSString *host = ApolloLinkPreviewHost(url);
    NSArray<NSString *> *parts = [url.path componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) [clean addObject:part];
    }

    if ([host isEqualToString:@"redd.it"] && clean.count > 0) return clean.firstObject;
    NSUInteger commentsIndex = [clean indexOfObject:@"comments"];
    if (commentsIndex != NSNotFound && commentsIndex + 1 < clean.count) return clean[commentsIndex + 1];
    return nil;
}

static NSDictionary *ApolloRedditPostFromCommentsJSON(id jsonObject) {
    NSArray *listingPair = ApolloLinkPreviewArrayValue(jsonObject);
    NSDictionary *postListing = listingPair.count > 0 ? ApolloLinkPreviewDictionaryValue(listingPair[0]) : nil;
    NSDictionary *listingData = ApolloLinkPreviewDictionaryValue(postListing[@"data"]);
    NSArray *children = ApolloLinkPreviewArrayValue(listingData[@"children"]);
    NSDictionary *firstChild = children.count > 0 ? ApolloLinkPreviewDictionaryValue(children[0]) : nil;
    return ApolloLinkPreviewDictionaryValue(firstChild[@"data"]);
}

static NSString *ApolloRedditPreviewImageStringFromPost(NSDictionary *post) {
    NSDictionary *preview = ApolloLinkPreviewDictionaryValue(post[@"preview"]);
    NSArray *images = ApolloLinkPreviewArrayValue(preview[@"images"]);
    NSDictionary *firstImage = images.count > 0 ? ApolloLinkPreviewDictionaryValue(images[0]) : nil;
    NSDictionary *source = ApolloLinkPreviewDictionaryValue(firstImage[@"source"]);
    NSString *image = ApolloLinkPreviewStringValue(source[@"url"]);
    if (image.length > 0) return image;

    NSString *thumbnail = ApolloLinkPreviewStringValue(post[@"thumbnail"]);
    return ([thumbnail hasPrefix:@"http://"] || [thumbnail hasPrefix:@"https://"]) ? thumbnail : nil;
}

static NSURL *ApolloLinkPreviewURLFromString(NSString *string, NSURL *baseURL) {
    NSString *clean = ApolloLinkPreviewCleanString(string);
    if (clean.length == 0) return nil;
    NSURL *url = [NSURL URLWithString:clean relativeToURL:ApolloLinkPreviewBaseURLForRelativeResource(baseURL, clean)];
    url = url.absoluteURL;
    return ApolloLinkPreviewURLIsHTTP(url) ? url : nil;
}

static NSString *ApolloLinkPreviewStringByStrippingHTMLTags(NSString *string) {
    NSString *clean = ApolloLinkPreviewCleanString(string);
    if (clean.length == 0) return nil;

    NSRegularExpression *tagRegex = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>" options:0 error:nil];
    clean = [tagRegex stringByReplacingMatchesInString:clean options:0 range:NSMakeRange(0, clean.length) withTemplate:@" "];
    return ApolloLinkPreviewCleanString(clean);
}

static NSString *ApolloLinkPreviewDOIFromURL(NSURL *url) {
    if (!ApolloLinkPreviewURLIsHTTP(url)) return nil;

    NSString *host = ApolloLinkPreviewHost(url);
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in [url.path componentsSeparatedByString:@"/"]) {
        NSString *decoded = part.stringByRemovingPercentEncoding ?: part;
        if (decoded.length > 0) [parts addObject:decoded];
    }

    NSString *doi = nil;
    if ([host isEqualToString:@"doi.org"] && parts.count > 0) {
        doi = [parts componentsJoinedByString:@"/"];
    } else if (([host isEqualToString:@"nature.com"] || [host hasSuffix:@".nature.com"])
               && parts.count >= 2
               && [parts[0].lowercaseString isEqualToString:@"articles"]) {
        // Nature articles always map to DOI prefix 10.1038/<article-id>, e.g.
        // /articles/s41586-024-12345-6 -> 10.1038/s41586-024-12345-6 and
        // /articles/nature12345 -> 10.1038/nature12345. The article-id token
        // is the path component directly after "/articles/".
        NSString *articleID = parts[1];
        NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."];
        if ([articleID rangeOfCharacterFromSet:[allowed invertedSet]].location == NSNotFound) {
            doi = [@"10.1038/" stringByAppendingString:articleID];
        }
    } else {
        NSUInteger doiIndex = NSNotFound;
        for (NSUInteger index = 0; index < parts.count; index++) {
            if ([parts[index].lowercaseString isEqualToString:@"doi"]) {
                doiIndex = index;
                break;
            }
        }
        if (doiIndex != NSNotFound && doiIndex + 1 < parts.count) {
            doi = [[parts subarrayWithRange:NSMakeRange(doiIndex + 1, parts.count - doiIndex - 1)] componentsJoinedByString:@"/"];
        }
    }

    if (doi.length == 0) {
        NSString *absolute = url.absoluteString.stringByRemovingPercentEncoding ?: url.absoluteString;
        NSRegularExpression *doiRegex = [NSRegularExpression regularExpressionWithPattern:@"10\\.\\d{4,9}/[^\\s?#\"'<>]+"
                                                                                  options:NSRegularExpressionCaseInsensitive
                                                                                    error:nil];
        NSTextCheckingResult *match = [doiRegex firstMatchInString:absolute options:0 range:NSMakeRange(0, absolute.length)];
        if (match) doi = [absolute substringWithRange:match.range];
    }

    doi = ApolloLinkPreviewCleanString(doi);
    NSCharacterSet *trimSet = [NSCharacterSet characterSetWithCharactersInString:@".,);]}>"];
    doi = [doi stringByTrimmingCharactersInSet:trimSet];
    return [doi hasPrefix:@"10."] ? doi : nil;
}

static NSString *ApolloLinkPreviewFirstString(id value) {
    if ([value isKindOfClass:[NSString class]]) return ApolloLinkPreviewCleanString(value);
    if ([value isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)value) {
            NSString *string = ApolloLinkPreviewFirstString(item);
            if (string.length > 0) return string;
        }
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)value;
        return ApolloLinkPreviewFirstString(dict[@"url"] ?: dict[@"contentUrl"] ?: dict[@"name"] ?: dict[@"headline"]);
    }
    return nil;
}

static NSString *ApolloLinkPreviewJSONLDValueForKeys(id object, NSArray<NSString *> *keys) {
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)object;
        for (NSString *key in keys) {
            NSString *value = ApolloLinkPreviewFirstString(dict[key]);
            if (value.length > 0) return value;
        }
        for (id child in dict.allValues) {
            NSString *value = ApolloLinkPreviewJSONLDValueForKeys(child, keys);
            if (value.length > 0) return value;
        }
    } else if ([object isKindOfClass:[NSArray class]]) {
        for (id child in (NSArray *)object) {
            NSString *value = ApolloLinkPreviewJSONLDValueForKeys(child, keys);
            if (value.length > 0) return value;
        }
    }
    return nil;
}

static NSDictionary<NSString *, NSString *> *ApolloLinkPreviewJSONLDValuesFromHTML(NSString *html) {
    if (html.length == 0) return @{};

    NSRegularExpression *scriptRegex = [NSRegularExpression regularExpressionWithPattern:@"<script\\s+[^>]*type\\s*=\\s*(['\"])[^'\"]*ld\\+json[^'\"]*\\1[^>]*>(.*?)</script>"
                                                                                options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators
                                                                                  error:nil];
    NSArray<NSTextCheckingResult *> *matches = [scriptRegex matchesInString:html options:0 range:NSMakeRange(0, html.length)];
    NSMutableDictionary<NSString *, NSString *> *values = [NSMutableDictionary dictionary];
    for (NSTextCheckingResult *match in matches) {
        if (match.numberOfRanges < 3) continue;
        NSString *jsonString = [html substringWithRange:[match rangeAtIndex:2]];
        jsonString = [jsonString stringByReplacingOccurrencesOfString:@"&quot;" withString:@"\""];
        NSData *jsonData = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
        if (!jsonData) continue;

        id object = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
        NSString *siteName = ApolloLinkPreviewJSONLDValueForKeys(object, @[@"publisher", @"sourceOrganization"]);
        NSString *title = ApolloLinkPreviewJSONLDValueForKeys(object, @[@"headline", @"name"]);
        NSString *desc = ApolloLinkPreviewJSONLDValueForKeys(object, @[@"description", @"abstract"]);
        NSString *image = ApolloLinkPreviewJSONLDValueForKeys(object, @[@"image", @"thumbnailUrl", @"contentUrl"]);
        if (siteName.length > 0 && !values[@"jsonld:site_name"]) values[@"jsonld:site_name"] = siteName;
        if (title.length > 0 && !values[@"jsonld:title"]) values[@"jsonld:title"] = title;
        if (desc.length > 0 && !values[@"jsonld:description"]) values[@"jsonld:description"] = desc;
        if (image.length > 0 && !values[@"jsonld:image"]) values[@"jsonld:image"] = image;
        if (values.count >= 4) break;
    }
    return values;
}

static NSString *ApolloLinkPreviewTitleFromURL(NSURL *url) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in [url.path componentsSeparatedByString:@"/"]) {
        NSString *decoded = part.stringByRemovingPercentEncoding ?: part;
        decoded = [decoded stringByReplacingOccurrencesOfString:@"-" withString:@" "];
        decoded = [decoded stringByReplacingOccurrencesOfString:@"_" withString:@" "];
        decoded = ApolloLinkPreviewCleanString(decoded);
        if (decoded.length == 0) continue;
        if ([decoded.lowercaseString isEqualToString:@"en"] || [decoded.lowercaseString isEqualToString:@"wiki"]) continue;
        if ([decoded.lowercaseString isEqualToString:@"usage"] || [decoded.lowercaseString isEqualToString:@"matches"]) continue;
        [parts addObject:decoded.capitalizedString];
    }

    if (parts.count == 0) return ApolloLinkPreviewHost(url);
    NSUInteger start = parts.count > 3 ? parts.count - 3 : 0;
    return [[parts subarrayWithRange:NSMakeRange(start, parts.count - start)] componentsJoinedByString:@" "];
}

static NSURL *ApolloLinkPreviewFallbackIconURL(NSURL *url) {
    NSString *host = ApolloLinkPreviewHost(url);
    if (host.length == 0) return nil;
    if (ApolloLinkPreviewHostIs(url, @"wikipedia.org")) {
        return [NSURL URLWithString:@"https://www.wikipedia.org/portal/wikipedia.org/assets/img/Wikipedia-logo-v2.png"];
    }

    NSString *escapedHost = [host stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    if (escapedHost.length == 0) return nil;
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://www.google.com/s2/favicons?domain=%@&sz=128", escapedHost]];
}

static void ApolloLinkPreviewApplyFallbackIcon(ApolloLinkPreview *preview, NSURL *url) {
    preview.imageURL = ApolloLinkPreviewFallbackIconURL(url);
    preview.imageSize = CGSizeMake(128.0, 128.0);
    preview.imageIsFallbackIcon = YES;
}

static ApolloLinkPreview *ApolloLinkPreviewFallbackPreviewForURL(NSURL *url, NSString *reason) {
    NSString *title = ApolloLinkPreviewTitleFromURL(url);
    if (title.length == 0) return nil;

    ApolloLinkPreview *preview = [ApolloLinkPreview new];
    preview.siteName = ApolloLinkPreviewHost(url);
    preview.title = title;
    NSString *cleanReason = ApolloLinkPreviewCleanString(reason);
    NSString *lowerReason = cleanReason.lowercaseString ?: @"";
    if ([lowerReason containsString:@"text/html"] || [lowerReason containsString:@"charset="]) cleanReason = nil;
    preview.desc = cleanReason;
    ApolloLinkPreviewApplyFallbackIcon(preview, url);
    preview.fetchedAt = [NSDate date];
    return preview;
}

static BOOL ApolloLinkPreviewIsWeakAcademicPreview(ApolloLinkPreview *preview, NSURL *url) {
    if (ApolloLinkPreviewDOIFromURL(url).length == 0 || !preview) return NO;
    NSString *lowerTitle = preview.title.lowercaseString ?: @"";
    NSString *lowerDesc = preview.desc.lowercaseString ?: @"";
    return [lowerTitle hasPrefix:@"doi "]
        || [lowerTitle hasPrefix:@"10."]
        || [lowerDesc containsString:@"text/html"]
        || [lowerDesc containsString:@"charset="];
}

// Returns YES when an existing cache entry was captured behind a known
// anti-bot wall (Cloudflare's "Client Challenge" etc.) and should be
// discarded on the next requestPreview so we can refetch through Crossref or
// the bot-wall fallback branch.
static BOOL ApolloLinkPreviewIsCachedBotWall(ApolloLinkPreview *preview) {
    if (!preview) return NO;
    return ApolloLinkPreviewIsBlockedPage(preview.title, nil);
}

static NSURL *ApolloTheNumbersPosterURLFromHTML(NSString *html, NSURL *baseURL) {
    if (html.length == 0 || !ApolloLinkPreviewHostIs(baseURL, @"the-numbers.com")) return nil;

    NSRegularExpression *imgRegex = [NSRegularExpression regularExpressionWithPattern:@"<img\\s+[^>]*>"
                                                                               options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators
                                                                                 error:nil];
    NSRegularExpression *srcRegex = [NSRegularExpression regularExpressionWithPattern:@"\\bsrc\\s*=\\s*(['\"])(.*?)\\1"
                                                                              options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators
                                                                                error:nil];
    NSArray<NSTextCheckingResult *> *matches = [imgRegex matchesInString:html options:0 range:NSMakeRange(0, html.length)];
    for (NSTextCheckingResult *match in matches) {
        NSString *tag = [html substringWithRange:match.range];
        NSTextCheckingResult *srcMatch = [srcRegex firstMatchInString:tag options:0 range:NSMakeRange(0, tag.length)];
        if (!srcMatch || srcMatch.numberOfRanges < 3) continue;

        NSString *src = [tag substringWithRange:[srcMatch rangeAtIndex:2]];
        NSString *lower = src.lowercaseString ?: @"";
        if (![lower containsString:@"/images/movie-posters/"]) continue;
        if ([lower containsString:@"/site-images/"] || [lower hasSuffix:@".svg"]) continue;

        NSURL *posterURL = ApolloLinkPreviewURLFromString(src, baseURL);
        if (posterURL.absoluteString.length > 0) return posterURL;
    }
    return nil;
}

static NSString *ApolloTheNumbersSynopsisFromHTML(NSString *html) {
    if (html.length == 0) return nil;
    NSRegularExpression *synopsisRegex = [NSRegularExpression regularExpressionWithPattern:@"<h2[^>]*>\\s*Synopsis\\s*</h2>\\s*<p[^>]*>(.*?)</p>"
                                                                                   options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators
                                                                                     error:nil];
    NSTextCheckingResult *match = [synopsisRegex firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
    if (!match || match.numberOfRanges < 2) return nil;

    NSString *raw = [html substringWithRange:[match rangeAtIndex:1]];
    NSRegularExpression *tags = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>" options:0 error:nil];
    raw = [tags stringByReplacingMatchesInString:raw options:0 range:NSMakeRange(0, raw.length) withTemplate:@" "];
    return ApolloLinkPreviewTruncatedString(raw, 220);
}

static NSString *ApolloYouTubeVideoIDFromURL(NSURL *url) {
    NSString *host = ApolloLinkPreviewHost(url);
    NSArray<NSString *> *parts = [url.path componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) [clean addObject:part];
    }

    if ([host isEqualToString:@"youtu.be"] && clean.count > 0) return clean.firstObject;
    if (ApolloLinkPreviewHostIs(url, @"youtube.com")) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        for (NSURLQueryItem *item in components.queryItems) {
            if ([item.name isEqualToString:@"v"] && item.value.length > 0) return item.value;
        }
        NSUInteger shortsIndex = [clean indexOfObject:@"shorts"];
        if (shortsIndex != NSNotFound && shortsIndex + 1 < clean.count) return clean[shortsIndex + 1];
        NSUInteger embedIndex = [clean indexOfObject:@"embed"];
        if (embedIndex != NSNotFound && embedIndex + 1 < clean.count) return clean[embedIndex + 1];
    }
    return nil;
}

static NSDictionary<NSString *, NSString *> *ApolloBlueskyPostPartsFromURL(NSURL *url) {
    if (!ApolloLinkPreviewHostIs(url, @"bsky.app")) return nil;

    NSArray<NSString *> *parts = [url.path componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (NSString *part in parts) {
        NSString *decoded = part.stringByRemovingPercentEncoding ?: part;
        if (decoded.length > 0) [clean addObject:decoded];
    }

    NSUInteger profileIndex = [clean indexOfObject:@"profile"];
    NSUInteger postIndex = [clean indexOfObject:@"post"];
    if (profileIndex == NSNotFound || postIndex == NSNotFound || profileIndex + 1 >= clean.count || postIndex + 1 >= clean.count) {
        return nil;
    }

    NSString *actor = clean[profileIndex + 1];
    NSString *rkey = clean[postIndex + 1];
    if (actor.length == 0 || rkey.length == 0) return nil;
    return @{@"actor": actor, @"rkey": rkey};
}

static NSString *ApolloBlueskyFirstTextLine(NSString *text) {
    NSString *clean = ApolloLinkPreviewCleanString(text);
    if (clean.length == 0) return nil;

    NSArray<NSString *> *parts = [clean componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *part in parts) {
        NSString *line = ApolloLinkPreviewCleanString(part);
        if (line.length > 0) return ApolloLinkPreviewTruncatedString(line, 90);
    }
    return ApolloLinkPreviewTruncatedString(clean, 90);
}

static NSString *ApolloWikipediaPageTitleFromURL(NSURL *url) {
    if (!ApolloLinkPreviewHostIs(url, @"wikipedia.org")) return nil;
    NSArray<NSString *> *parts = [url.path componentsSeparatedByString:@"/"];
    NSUInteger wikiIndex = [parts indexOfObject:@"wiki"];
    if (wikiIndex == NSNotFound || wikiIndex + 1 >= parts.count) return nil;
    NSArray<NSString *> *titleParts = [parts subarrayWithRange:NSMakeRange(wikiIndex + 1, parts.count - wikiIndex - 1)];
    NSString *title = [titleParts componentsJoinedByString:@"/"];
    return title.length > 0 ? title : nil;
}

static NSMutableURLRequest *ApolloLinkPreviewRequest(NSURL *url, NSTimeInterval timeout) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:timeout];
    NSString *userAgent = sUserAgent.length > 0 ? sUserAgent : @"ApolloLinkPreviews/1.0";
    [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"text/html,application/json;q=0.9,*/*;q=0.8" forHTTPHeaderField:@"Accept"];
    return request;
}

static NSString *ApolloLinkPreviewBrowserUserAgent(void) {
    return @"Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
}

@interface ApolloLinkPreviewFetcher ()
+ (void)fetchPreviewForURL:(NSURL *)url completion:(ApolloLinkPreviewCompletion)completion;
+ (void)finishURL:(NSURL *)url preview:(ApolloLinkPreview *)preview;
+ (void)fetchYouTubePreviewForURL:(NSURL *)url completion:(ApolloLinkPreviewCompletion)completion;
+ (void)imageURLIsUsable:(NSURL *)imageURL completion:(void (^)(BOOL usable))completion;
+ (void)fetchWikipediaPreviewForURL:(NSURL *)url completion:(ApolloLinkPreviewCompletion)completion;
+ (void)fetchRedditPreviewForURL:(NSURL *)url completion:(ApolloLinkPreviewCompletion)completion;
+ (void)fetchGitHubPreviewForURL:(NSURL *)url completion:(ApolloLinkPreviewCompletion)completion;
+ (void)fetchBlueskyPreviewForURL:(NSURL *)url completion:(ApolloLinkPreviewCompletion)completion;
+ (NSString *)crossrefSummaryFromMessage:(NSDictionary *)message;
+ (void)fetchCrossrefPreviewForURL:(NSURL *)url completion:(ApolloLinkPreviewCompletion)completion;
+ (void)fetchHTMLPreviewForURL:(NSURL *)url completion:(ApolloLinkPreviewCompletion)completion;
+ (void)fetchHTMLPreviewForURL:(NSURL *)url allowRange:(BOOL)allowRange browserFallback:(BOOL)browserFallback completion:(ApolloLinkPreviewCompletion)completion;
@end

@implementation ApolloLinkPreviewFetcher

+ (void)requestPreviewForURL:(NSURL *)url completion:(void (^)(ApolloLinkPreview *preview))completion {
    if (!ApolloLinkPreviewURLIsHTTP(url)) {
        if (completion) completion(nil);
        return;
    }

    ApolloLinkPreview *cached = [[ApolloLinkPreviewCache sharedCache] cachedPreviewForURL:url];
    NSString *logHost = url.host.lowercaseString ?: @"";
    if ([logHost hasPrefix:@"www."]) logHost = [logHost substringFromIndex:4];
    ApolloLog(@"[LinkPreviews] requestPreview host=%@ cached=%@", logHost, cached ? @"YES" : @"NO");
    if (cached) {
        BOOL botWall = ApolloLinkPreviewIsCachedBotWall(cached);
        BOOL weakAcademic = ApolloLinkPreviewIsWeakAcademicPreview(cached, url);
        BOOL weakGeneric = cached.imageIsFallbackIcon
            && cached.desc.length == 0
            && [cached.title isEqualToString:ApolloLinkPreviewTitleFromURL(url)];
        BOOL staleBluesky = ApolloBlueskyPostPartsFromURL(url)
            && (![cached.previewKind isEqualToString:@"bluesky-post-v2"] || cached.postText.length == 0);
        BOOL staleRedditUser = ApolloRedditUsernameFromProfileURL(url).length > 0
            && ![cached.previewKind isEqualToString:@"reddit-user-profile"];
        BOOL staleRedditSubreddit = ApolloRedditSubredditFromURL(url).length > 0
            && ![cached.previewKind isEqualToString:@"reddit-subreddit"];
        NSString *redditUsername = ApolloRedditUsernameFromProfileURL(url);
        ApolloUserProfileInfo *redditProfileInfo = redditUsername.length > 0
            ? [[ApolloUserProfileCache sharedCache] cachedInfoForUsername:redditUsername]
            : nil;
        BOOL previewSaysBanned = [cached.desc isEqualToString:ApolloBannedProfileBannedDescriptionText()];
        BOOL staleRedditUserSuspension = redditUsername.length > 0
            && [cached.previewKind isEqualToString:@"reddit-user-profile"]
            && ((redditProfileInfo && !redditProfileInfo.suspensionChecked)
                || (ApolloBannedProfileCachedIsSuspended(redditUsername) != previewSaysBanned));
        if (!botWall && !weakAcademic && !weakGeneric && !staleBluesky && !staleRedditUser && !staleRedditSubreddit && !staleRedditUserSuspension) {
            if (completion) completion(cached);
            return;
        }
        ApolloLog(@"[LinkPreviews] refetching cached preview host=%@ reason=%@",
                  logHost, botWall ? @"bot-wall" : (weakAcademic ? @"weak-academic" : (weakGeneric ? @"weak-generic" : (staleBluesky ? @"stale-bluesky" : (staleRedditUserSuspension ? @"stale-reddit-user-suspension" : (staleRedditUser ? @"stale-reddit-user" : @"stale-reddit-subreddit"))))));
        if (staleRedditUserSuspension && redditUsername.length > 0) {
            [[ApolloLinkPreviewCache sharedCache] removePreviewsForRedditUsername:redditUsername];
        }
    }

    NSString *key = url.absoluteString ?: @"";
    dispatch_async(ApolloLinkPreviewFetcherQueue(), ^{
        NSMutableDictionary *pending = ApolloLinkPreviewPendingFetches();
        NSMutableArray *completions = pending[key];
        if (completions) {
            if (completion) [completions addObject:[completion copy]];
            return;
        }

        pending[key] = completion ? [NSMutableArray arrayWithObject:[completion copy]] : [NSMutableArray array];
        [self fetchPreviewForURL:url completion:^(ApolloLinkPreview *preview) {
            [self finishURL:url preview:preview];
        }];
    });
}

+ (BOOL)isTwitterURL:(NSURL *)url {
    NSString *host = ApolloLinkPreviewHost(url);
    return [host isEqualToString:@"x.com"] || [host hasSuffix:@".x.com"]
        || [host isEqualToString:@"twitter.com"] || [host hasSuffix:@".twitter.com"];
}

+ (void)fetchPreviewForURL:(NSURL *)url completion:(ApolloLinkPreviewCompletion)completion {
    if ([self isTwitterURL:url]) {
        ApolloLinkPreview *preview = [ApolloLinkPreview new];
        preview.noMetadata = YES;
        preview.fetchedAt = [NSDate date];
        completion(preview);
    } else if (ApolloLinkPreviewHostIs(url, @"youtube.com") || ApolloLinkPreviewHostIs(url, @"youtu.be")) {
        [self fetchYouTubePreviewForURL:url completion:completion];
    } else if (ApolloWikipediaPageTitleFromURL(url).length > 0) {
        [self fetchWikipediaPreviewForURL:url completion:completion];
    } else if (ApolloLinkPreviewHostIs(url, @"reddit.com") || ApolloLinkPreviewHostIs(url, @"redd.it")) {
        [self fetchRedditPreviewForURL:url completion:completion];
    } else if (ApolloLinkPreviewHostIs(url, @"github.com")) {
        [self fetchGitHubPreviewForURL:url completion:completion];
    } else if (ApolloBlueskyPostPartsFromURL(url)) {
        [self fetchBlueskyPreviewForURL:url completion:^(ApolloLinkPreview *preview) {
            if (preview) completion(preview);
            else [self fetchHTMLPreviewForURL:url completion:completion];
        }];
    } else if (ApolloLinkPreviewHostIs(url, @"doi.org")
               || (ApolloLinkPreviewHostIs(url, @"nature.com") && ApolloLinkPreviewDOIFromURL(url).length > 0)) {
        // For doi.org and Nature article URLs, jump straight to Crossref:
        // both either redirect to a Cloudflare wall (Nature's "Client
        // Challenge") or only expose the DOI in their meta tags, so the
        // HTML fetch round-trip adds nothing useful here.
        [self fetchCrossrefPreviewForURL:url completion:^(ApolloLinkPreview *preview) {
            if (preview) completion(preview);
            else [self fetchHTMLPreviewForURL:url completion:completion];
        }];
    } else {
        [self fetchHTMLPreviewForURL:url completion:completion];
    }
}

+ (void)finishURL:(NSURL *)url preview:(ApolloLinkPreview *)preview {
    if (!preview) {
        // Negatively cache the failure so the next layout resolves from cache
        // instead of refetching. Without this, a URL that always 404s (e.g. a
        // removed v.redd.it video surfaced as a redd.it/<id> short link) loops
        // forever: fetch fails -> node relayouts -> refetches, freezing scroll.
        ApolloLog(@"[LinkPreviews] caching negative result for empty preview host=%@", ApolloLinkPreviewHost(url));
        [[ApolloLinkPreviewCache sharedCache] markNoMetadataForURL:url];
        NSString *key = url.absoluteString ?: @"";
        dispatch_async(ApolloLinkPreviewFetcherQueue(), ^{
            NSMutableArray *completions = ApolloLinkPreviewPendingFetches()[key];
            [ApolloLinkPreviewPendingFetches() removeObjectForKey:key];
            for (ApolloLinkPreviewCompletion completion in completions) {
                completion(nil);
            }
        });
        return;
    }

    if (![preview hasUsefulMetadata]) {
        [[ApolloLinkPreviewCache sharedCache] markNoMetadataForURL:url];
    } else {
        preview.fetchedAt = preview.fetchedAt ?: [NSDate date];
        [[ApolloLinkPreviewCache sharedCache] storePreview:preview forURL:url];
    }

    NSString *key = url.absoluteString ?: @"";
    dispatch_async(ApolloLinkPreviewFetcherQueue(), ^{
        NSMutableArray *completions = ApolloLinkPreviewPendingFetches()[key];
        [ApolloLinkPreviewPendingFetches() removeObjectForKey:key];
        for (ApolloLinkPreviewCompletion completion in completions) {
            completion(preview);
        }
    });
}

+ (void)fetchYouTubePreviewForURL:(NSURL *)url completion:(ApolloLinkPreviewCompletion)completion {
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://www.youtube.com/oembed"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"url" value:url.absoluteString],
        [NSURLQueryItem queryItemWithName:@"format" value:@"json"],
    ];
    NSMutableURLRequest *request = ApolloLinkPreviewRequest(components.URL, 10.0);

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            ApolloLog(@"[LinkPreviews] YouTube oEmbed failed %@ err=%@", url.absoluteString, error.localizedDescription);
            completion(nil);
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        ApolloLinkPreview *preview = [ApolloLinkPreview new];
        preview.siteName = @"YouTube";
        preview.title = ApolloLinkPreviewCleanString(json[@"title"]);
        preview.desc = ApolloLinkPreviewCleanString(json[@"author_name"]);
        NSString *videoID = ApolloYouTubeVideoIDFromURL(url);
        if (videoID.length > 0) {
            NSURL *hq720URL = [NSURL URLWithString:[NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hq720.jpg", videoID]];
            [self imageURLIsUsable:hq720URL completion:^(BOOL usable) {
                if (usable) {
                    preview.imageURL = hq720URL;
                    preview.imageSize = CGSizeMake(1280.0, 720.0);
                } else {
                    preview.imageURL = ApolloLinkPreviewURLFromString(json[@"thumbnail_url"], url);
                    preview.imageSize = CGSizeMake([json[@"thumbnail_width"] respondsToSelector:@selector(doubleValue)] ? [json[@"thumbnail_width"] doubleValue] : 0.0,
                                                   [json[@"thumbnail_height"] respondsToSelector:@selector(doubleValue)] ? [json[@"thumbnail_height"] doubleValue] : 0.0);
                    ApolloLog(@"[LinkPreviews] YouTube hq720 unavailable %@ fallback=%@", url.absoluteString, preview.imageURL.absoluteString ?: @"(none)");
                }
                preview.fetchedAt = [NSDate date];
                completion(preview);
            }];
            return;
        } else {
            preview.imageURL = ApolloLinkPreviewURLFromString(json[@"thumbnail_url"], url);
            preview.imageSize = CGSizeMake([json[@"thumbnail_width"] respondsToSelector:@selector(doubleValue)] ? [json[@"thumbnail_width"] doubleValue] : 0.0,
                                           [json[@"thumbnail_height"] respondsToSelector:@selector(doubleValue)] ? [json[@"thumbnail_height"] doubleValue] : 0.0);
        }
        preview.fetchedAt = [NSDate date];
        completion(preview);
    }] resume];
}

+ (void)imageURLIsUsable:(NSURL *)imageURL completion:(void (^)(BOOL usable))completion {
    if (imageURL.absoluteString.length == 0) {
        completion(NO);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:imageURL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:5.0];
    request.HTTPMethod = @"HEAD";
    [request setValue:@"image/*,*/*;q=0.8" forHTTPHeaderField:@"Accept"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(__unused NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSString *contentType = [[httpResponse allHeaderFields][@"Content-Type"] lowercaseString] ?: @"";
        BOOL usable = !error && httpResponse.statusCode >= 200 && httpResponse.statusCode < 300
            && (contentType.length == 0 || [contentType containsString:@"image"]);
        completion(usable);
    }] resume];
}

+ (void)fetchWikipediaPreviewForURL:(NSURL *)url completion:(ApolloLinkPreviewCompletion)completion {
    NSString *pageTitle = ApolloWikipediaPageTitleFromURL(url);
    NSString *encodedTitle = [pageTitle stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    if (encodedTitle.length == 0) {
        completion(ApolloLinkPreviewFallbackPreviewForURL(url, nil));
        return;
    }

    NSString *scheme = url.scheme.length > 0 ? url.scheme : @"https";
    NSString *summaryURLString = [NSString stringWithFormat:@"%@://%@/api/rest_v1/page/summary/%@", scheme, url.host, encodedTitle];
    NSMutableURLRequest *request = ApolloLinkPreviewRequest([NSURL URLWithString:summaryURLString], 10.0);
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (error || !data || httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
            ApolloLog(@"[LinkPreviews] Wikipedia summary failed %@ status=%ld err=%@",
                      url.absoluteString, (long)httpResponse.statusCode, error.localizedDescription);
            completion(ApolloLinkPreviewFallbackPreviewForURL(url, nil));
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        ApolloLinkPreview *preview = [ApolloLinkPreview new];
        preview.siteName = @"Wikipedia";
        preview.title = ApolloLinkPreviewCleanString(json[@"displaytitle"]) ?: ApolloLinkPreviewCleanString(json[@"title"]) ?: ApolloLinkPreviewTitleFromURL(url);
        preview.desc = ApolloLinkPreviewTruncatedString(json[@"extract"], 220);
        NSString *image = json[@"thumbnail"][@"source"] ?: json[@"originalimage"][@"source"];
        preview.imageURL = ApolloLinkPreviewURLFromString(image, url);
        if (preview.imageURL.absoluteString.length > 0) {
            preview.imageSize = CGSizeMake([json[@"thumbnail"][@"width"] respondsToSelector:@selector(doubleValue)] ? [json[@"thumbnail"][@"width"] doubleValue] : 0.0,
                                           [json[@"thumbnail"][@"height"] respondsToSelector:@selector(doubleValue)] ? [json[@"thumbnail"][@"height"] doubleValue] : 0.0);
        } else {
            ApolloLinkPreviewApplyFallbackIcon(preview, url);
        }
        preview.fetchedAt = [NSDate date];
        completion(preview);
    }] resume];
}

+ (void)fetchRedditUserPreviewForURL:(NSURL *)url username:(NSString *)username completion:(ApolloLinkPreviewCompletion)completion {
    ApolloUserProfileCache *profileCache = [ApolloUserProfileCache sharedCache];
    ApolloUserProfileInfo *cachedInfo = [profileCache cachedInfoForUsername:username];
    void (^deliver)(ApolloUserProfileInfo *) = ^(ApolloUserProfileInfo *info) {
        NSString *canonicalUsername = info.username.length > 0 ? info.username : username;
        NSString *fallbackHandle = [@"u/" stringByAppendingString:(username ?: @"")];
        BOOL isSuspended = (info.isSuspended) || ApolloBannedProfileCachedIsSuspended(canonicalUsername ?: username);

        ApolloLinkPreview *preview = [ApolloLinkPreview new];
        preview.siteName = @"Reddit";
        preview.previewKind = @"reddit-user-profile";
        preview.authorHandle = canonicalUsername.length > 0 ? [@"u/" stringByAppendingString:canonicalUsername] : fallbackHandle;

        if (isSuspended) {
            preview.title = preview.authorHandle;
            preview.authorDisplayName = nil;
            preview.desc = ApolloBannedProfileBannedDescriptionText();
            preview.avatarURL = nil;
            preview.imageURL = nil;
            preview.fetchedAt = [NSDate date];
            ApolloLog(@"[LinkPreviews] Reddit user preview banned handle=%@", preview.authorHandle ?: fallbackHandle);
            completion(preview);
            return;
        }

        preview.authorDisplayName = ApolloLinkPreviewCleanString(info.displayName);
        preview.title = preview.authorDisplayName.length > 0 ? preview.authorDisplayName : preview.authorHandle;
        preview.desc = ApolloLinkPreviewTruncatedString(info.aboutText, 160);
        preview.avatarURL = info.iconURL ?: info.snoovatarURL;
        preview.imageURL = preview.avatarURL;
        if (preview.imageURL.absoluteString.length > 0) {
            preview.imageSize = CGSizeMake(128.0, 128.0);
        } else {
            ApolloLinkPreviewApplyFallbackIcon(preview, url);
        }
        preview.fetchedAt = [NSDate date];
        ApolloLog(@"[LinkPreviews] Reddit user preview fetched handle=%@ avatar=%@",
                  preview.authorHandle ?: fallbackHandle,
                  preview.avatarURL.absoluteString.length > 0 ? @"YES" : @"NO");
        completion(preview);
    };

    if (cachedInfo && cachedInfo.suspensionChecked) {
        deliver(cachedInfo);
        return;
    }
    if (ApolloBannedProfileCachedIsSuspended(username)) {
        deliver(cachedInfo);
        return;
    }

    __block BOOL didDeliver = NO;
    [profileCache requestInfoForUsername:username completion:^(ApolloUserProfileInfo *info) {
        if (didDeliver) return;
        didDeliver = YES;
        deliver(info);
    }];
}

+ (void)fetchRedditSubredditPreviewForURL:(NSURL *)url subreddit:(NSString *)subreddit completion:(ApolloLinkPreviewCompletion)completion {
    ApolloSubredditInfoCache *subredditCache = [ApolloSubredditInfoCache sharedCache];
    ApolloSubredditInfo *cachedInfo = [subredditCache cachedInfoForSubreddit:subreddit];
    void (^deliver)(ApolloSubredditInfo *) = ^(ApolloSubredditInfo *info) {
        ApolloLinkPreview *preview = [ApolloLinkPreview new];
        preview.siteName = @"Reddit";
        preview.previewKind = @"reddit-subreddit";
        NSString *canonicalSubreddit = info.subredditName.length > 0 ? info.subredditName : subreddit;
        NSString *fallbackHandle = [@"r/" stringByAppendingString:(subreddit ?: @"")];
        preview.authorHandle = canonicalSubreddit.length > 0 ? [@"r/" stringByAppendingString:canonicalSubreddit] : fallbackHandle;
        preview.authorDisplayName = ApolloLinkPreviewCleanString(info.displayName);
        preview.title = preview.authorDisplayName.length > 0 ? preview.authorDisplayName : preview.authorHandle;
        preview.desc = ApolloLinkPreviewTruncatedString(info.aboutText, 160);
        preview.postText = ApolloSubredditFormattedMemberCount(info.subscriberCount);
        preview.avatarURL = info.iconURL;
        preview.imageURL = preview.avatarURL;
        if (preview.imageURL.absoluteString.length > 0) {
            preview.imageSize = CGSizeMake(128.0, 128.0);
        } else {
            ApolloLinkPreviewApplyFallbackIcon(preview, url);
        }
        preview.fetchedAt = [NSDate date];
        ApolloLog(@"[LinkPreviews] Reddit subreddit preview fetched handle=%@ avatar=%@ members=%@",
                  preview.authorHandle ?: fallbackHandle,
                  preview.avatarURL.absoluteString.length > 0 ? @"YES" : @"NO",
                  preview.postText.length > 0 ? preview.postText : @"NO");
        completion(preview);
    };

    if (cachedInfo) {
        deliver(cachedInfo);
        return;
    }

    __block BOOL didDeliver = NO;
    [subredditCache requestInfoForSubreddit:subreddit completion:^(ApolloSubredditInfo *info) {
        if (didDeliver) return;
        didDeliver = YES;
        deliver(info);
    }];
}

+ (void)fetchRedditPreviewForURL:(NSURL *)url completion:(ApolloLinkPreviewCompletion)completion {
    NSString *username = ApolloRedditUsernameFromProfileURL(url);
    if (username.length > 0) {
        [self fetchRedditUserPreviewForURL:url username:username completion:completion];
        return;
    }

    NSString *subreddit = ApolloRedditSubredditFromURL(url);
    if (subreddit.length > 0) {
        [self fetchRedditSubredditPreviewForURL:url subreddit:subreddit completion:completion];
        return;
    }

    NSString *postID = ApolloRedditPostIDFromURL(url);
    if (postID.length == 0) {
        if (ApolloLinkPreviewIsRedditListingURL(url)) {
            // Subreddit / user-profile / overview links: Reddit's HTML is gated
            // by a verification challenge that returns garbage metadata. Punt
            // back to Apollo's native card (which already paints a subreddit
            // icon + name) instead of trying to scrape.
            NSString *redditUsername = ApolloLinkPreviewRedditUsernameFromListingURL(url);
            if (redditUsername.length > 0) {
                [[ApolloUserProfileCache sharedCache] requestInfoForUsername:redditUsername completion:nil];
                if (ApolloBannedProfileCachedIsSuspended(redditUsername)) {
                    ApolloLog(@"[LinkPreviews] Reddit user u/%@ is suspended; native profile UI will show banned state", redditUsername);
                }
            }
            ApolloLog(@"[LinkPreviews] Reddit listing URL skipped %@", url.absoluteString);
            ApolloLinkPreview *preview = [ApolloLinkPreview new];
            preview.noMetadata = YES;
            preview.fetchedAt = [NSDate date];
            completion(preview);
            return;
        }
        [self fetchHTMLPreviewForURL:url completion:completion];
        return;
    }

    NSString *urlString = sLatestRedditBearerToken.length > 0
        ? [NSString stringWithFormat:@"https://oauth.reddit.com/comments/%@/.json?raw_json=1", postID]
        : [NSString stringWithFormat:@"https://www.reddit.com/comments/%@.json?raw_json=1", postID];
    NSMutableURLRequest *request = ApolloLinkPreviewRequest([NSURL URLWithString:urlString], 10.0);
    if (sLatestRedditBearerToken.length > 0) {
        [request setValue:[@"Bearer " stringByAppendingString:sLatestRedditBearerToken] forHTTPHeaderField:@"Authorization"];
    }

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            ApolloLog(@"[LinkPreviews] Reddit JSON failed %@ err=%@", url.absoluteString, error.localizedDescription);
            completion(nil);
            return;
        }

        NSInteger statusCode = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (statusCode < 200 || statusCode >= 300) {
            ApolloLog(@"[LinkPreviews] Reddit JSON failed %@ status=%ld", url.absoluteString, (long)statusCode);
            completion(nil);
            return;
        }

        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *post = ApolloRedditPostFromCommentsJSON(json);
        if (!post) {
            ApolloLog(@"[LinkPreviews] Reddit JSON missing post %@", url.absoluteString);
            completion(nil);
            return;
        }

        ApolloLinkPreview *preview = [ApolloLinkPreview new];
        preview.siteName = @"Reddit";
        preview.title = ApolloLinkPreviewCleanString(post[@"title"]);
        preview.desc = ApolloLinkPreviewTruncatedString(post[@"selftext"], 200);
        preview.imageURL = ApolloLinkPreviewURLFromString(ApolloRedditPreviewImageStringFromPost(post), url);
        preview.fetchedAt = [NSDate date];
        completion(preview);
    }] resume];
}

+ (void)fetchGitHubPreviewForURL:(NSURL *)url completion:(ApolloLinkPreviewCompletion)completion {
    NSArray<NSString *> *parts = [url.path componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) [clean addObject:part];
    }
    if (clean.count < 2) {
        [self fetchHTMLPreviewForURL:url completion:completion];
        return;
    }

    NSString *owner = clean[0];
    NSString *repo = clean[1];
    NSString *apiURLString = nil;
    if (clean.count >= 4 && ([clean[2] isEqualToString:@"issues"] || [clean[2] isEqualToString:@"pull"])) {
        apiURLString = [NSString stringWithFormat:@"https://api.github.com/repos/%@/%@/issues/%@", owner, repo, clean[3]];
    } else {
        apiURLString = [NSString stringWithFormat:@"https://api.github.com/repos/%@/%@", owner, repo];
    }

    NSMutableURLRequest *request = ApolloLinkPreviewRequest([NSURL URLWithString:apiURLString], 10.0);
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            completion(nil);
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        ApolloLinkPreview *preview = [ApolloLinkPreview new];
        preview.siteName = @"GitHub";
        if (json[@"full_name"]) {
            preview.title = ApolloLinkPreviewCleanString(json[@"full_name"]);
            preview.desc = ApolloLinkPreviewTruncatedString(json[@"description"], 200);
            preview.imageURL = ApolloLinkPreviewURLFromString(json[@"owner"][@"avatar_url"], url);
        } else {
            preview.title = ApolloLinkPreviewCleanString(json[@"title"]);
            preview.desc = ApolloLinkPreviewTruncatedString(json[@"body"], 200);
            preview.imageURL = ApolloLinkPreviewURLFromString(json[@"user"][@"avatar_url"], url);
        }
        preview.fetchedAt = [NSDate date];
        completion(preview);
    }] resume];
}

+ (void)fetchBlueskyPreviewForURL:(NSURL *)url completion:(ApolloLinkPreviewCompletion)completion {
    NSDictionary<NSString *, NSString *> *parts = ApolloBlueskyPostPartsFromURL(url);
    NSString *actor = parts[@"actor"];
    NSString *rkey = parts[@"rkey"];
    if (actor.length == 0 || rkey.length == 0) {
        completion(nil);
        return;
    }

    void (^fetchPostWithDID)(NSString *) = ^(NSString *did) {
        if (did.length == 0) {
            completion(nil);
            return;
        }

        NSString *atURI = [NSString stringWithFormat:@"at://%@/app.bsky.feed.post/%@", did, rkey];
        NSURLComponents *components = [NSURLComponents componentsWithString:@"https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread"];
        components.queryItems = @[
            [NSURLQueryItem queryItemWithName:@"uri" value:atURI],
            [NSURLQueryItem queryItemWithName:@"depth" value:@"0"],
            [NSURLQueryItem queryItemWithName:@"parentHeight" value:@"0"],
        ];

        NSMutableURLRequest *request = ApolloLinkPreviewRequest(components.URL, 10.0);
        [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
        [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            if (error || !data || httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
                ApolloLog(@"[LinkPreviews] Bluesky post fetch failed host=%@ status=%ld err=%@",
                          ApolloLinkPreviewHost(url), (long)httpResponse.statusCode, error.localizedDescription);
                completion(nil);
                return;
            }

            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSDictionary *thread = [json[@"thread"] isKindOfClass:[NSDictionary class]] ? json[@"thread"] : nil;
            NSDictionary *post = [thread[@"post"] isKindOfClass:[NSDictionary class]] ? thread[@"post"] : nil;
            if (![post isKindOfClass:[NSDictionary class]]) {
                completion(nil);
                return;
            }

            NSDictionary *author = [post[@"author"] isKindOfClass:[NSDictionary class]] ? post[@"author"] : nil;
            NSDictionary *record = [post[@"record"] isKindOfClass:[NSDictionary class]] ? post[@"record"] : nil;
            NSDictionary *embed = [post[@"embed"] isKindOfClass:[NSDictionary class]] ? post[@"embed"] : nil;

            NSString *displayName = ApolloLinkPreviewCleanString(author[@"displayName"]);
            NSString *handle = ApolloLinkPreviewCleanString(author[@"handle"]);
            NSString *text = ApolloLinkPreviewCleanMultilineString(record[@"text"]);
            NSString *title = nil;
            if (displayName.length > 0 && handle.length > 0) {
                title = [NSString stringWithFormat:@"%@ (@%@)", displayName, handle];
            } else {
                title = displayName ?: handle ?: ApolloBlueskyFirstTextLine(text) ?: @"Bluesky";
            }

            ApolloLinkPreview *preview = [ApolloLinkPreview new];
            preview.siteName = @"Bluesky";
            preview.title = title;
            preview.desc = ApolloLinkPreviewTruncatedString(text, 300);
            preview.previewKind = @"bluesky-post-v2";
            preview.authorDisplayName = displayName;
            preview.authorHandle = handle;
            preview.postText = text;
            preview.avatarURL = ApolloLinkPreviewURLFromString(author[@"avatar"], url);
            preview.fetchedAt = [NSDate date];

            BOOL avatarOnlyImage = NO;
            NSArray *images = [embed[@"images"] isKindOfClass:[NSArray class]] ? embed[@"images"] : nil;
            NSDictionary *firstImage = images.count > 0 && [images.firstObject isKindOfClass:[NSDictionary class]] ? images.firstObject : nil;
            NSString *imageString = nil;
            if (firstImage) {
                imageString = firstImage[@"thumb"] ?: firstImage[@"fullsize"];
                NSDictionary *aspectRatio = [firstImage[@"aspectRatio"] isKindOfClass:[NSDictionary class]] ? firstImage[@"aspectRatio"] : nil;
                if ([aspectRatio[@"width"] respondsToSelector:@selector(doubleValue)] && [aspectRatio[@"height"] respondsToSelector:@selector(doubleValue)]) {
                    preview.imageSize = CGSizeMake([aspectRatio[@"width"] doubleValue], [aspectRatio[@"height"] doubleValue]);
                }
            }

            NSDictionary *external = [embed[@"external"] isKindOfClass:[NSDictionary class]] ? embed[@"external"] : nil;
            if (imageString.length == 0) {
                imageString = external[@"thumb"];
            }
            if (preview.desc.length == 0) {
                preview.desc = ApolloLinkPreviewTruncatedString(external[@"description"] ?: external[@"title"], 220);
            }
            if (imageString.length == 0) {
                imageString = author[@"avatar"];
                avatarOnlyImage = imageString.length > 0;
                if (avatarOnlyImage) preview.imageSize = CGSizeMake(128.0, 128.0);
            }

            preview.imageURL = ApolloLinkPreviewURLFromString(imageString, url);
            ApolloLog(@"[LinkPreviews] Bluesky preview fetched handle=%@ image=%@", handle ?: actor, preview.imageURL.absoluteString.length > 0 ? @"YES" : @"NO");

            if (avatarOnlyImage && preview.imageURL.absoluteString.length > 0) {
                [self imageURLIsUsable:preview.imageURL completion:^(BOOL usable) {
                    if (!usable) {
                        preview.imageURL = nil;
                        preview.imageSize = CGSizeZero;
                    }
                    completion(preview);
                }];
                return;
            }

            completion(preview);
        }] resume];
    };

    if ([actor hasPrefix:@"did:"]) {
        fetchPostWithDID(actor);
        return;
    }

    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle"];
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"handle" value:actor]];
    NSMutableURLRequest *request = ApolloLinkPreviewRequest(components.URL, 10.0);
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (error || !data || httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
            ApolloLog(@"[LinkPreviews] Bluesky handle resolve failed actor=%@ status=%ld err=%@",
                      actor, (long)httpResponse.statusCode, error.localizedDescription);
            completion(nil);
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *did = [json[@"did"] isKindOfClass:[NSString class]] ? json[@"did"] : nil;
        fetchPostWithDID(did);
    }] resume];
}

+ (NSString *)crossrefSummaryFromMessage:(NSDictionary *)message {
    NSString *publisher = ApolloLinkPreviewFirstString(message[@"publisher"]);
    NSString *container = ApolloLinkPreviewFirstString(message[@"container-title"]);
    NSString *dateString = nil;
    NSArray *dateParts = message[@"published-print"][@"date-parts"] ?: message[@"published-online"][@"date-parts"] ?: message[@"issued"][@"date-parts"];
    NSArray *firstDate = [dateParts isKindOfClass:[NSArray class]] ? dateParts.firstObject : nil;
    if ([firstDate isKindOfClass:[NSArray class]] && firstDate.count > 0) {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (id part in firstDate) {
            if ([part respondsToSelector:@selector(integerValue)]) [parts addObject:[NSString stringWithFormat:@"%ld", (long)[part integerValue]]];
        }
        dateString = [parts componentsJoinedByString:@"-"];
    }

    NSMutableArray<NSString *> *summaryParts = [NSMutableArray array];
    if (container.length > 0) [summaryParts addObject:container];
    if (publisher.length > 0 && ![publisher isEqualToString:container]) [summaryParts addObject:publisher];
    if (dateString.length > 0) [summaryParts addObject:dateString];
    return summaryParts.count > 0 ? [summaryParts componentsJoinedByString:@" - "] : nil;
}

+ (void)fetchCrossrefPreviewForURL:(NSURL *)url completion:(ApolloLinkPreviewCompletion)completion {
    NSString *doi = ApolloLinkPreviewDOIFromURL(url);
    if (doi.length == 0) {
        completion(nil);
        return;
    }

    NSString *encodedDOI = [doi stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSURL *apiURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.crossref.org/works/%@", encodedDOI]];
    NSMutableURLRequest *request = ApolloLinkPreviewRequest(apiURL, 10.0);
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (error || !data || httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
            ApolloLog(@"[LinkPreviews] Crossref failed doi=%@ status=%ld err=%@", doi, (long)httpResponse.statusCode, error.localizedDescription);
            completion(nil);
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *message = [json[@"message"] isKindOfClass:[NSDictionary class]] ? json[@"message"] : nil;
        NSString *title = ApolloLinkPreviewFirstString(message[@"title"]);
        if (title.length == 0) {
            completion(nil);
            return;
        }

        ApolloLinkPreview *preview = [ApolloLinkPreview new];
        NSString *container = ApolloLinkPreviewFirstString(message[@"container-title"]);
        NSString *publisher = ApolloLinkPreviewFirstString(message[@"publisher"]);
        preview.siteName = container.length > 0 ? container : (publisher.length > 0 ? publisher : ApolloLinkPreviewHost(url));
        preview.title = title;
        preview.desc = ApolloLinkPreviewTruncatedString(ApolloLinkPreviewStringByStrippingHTMLTags(message[@"abstract"]) ?: [self crossrefSummaryFromMessage:message], 220);

        NSArray *links = [message[@"link"] isKindOfClass:[NSArray class]] ? message[@"link"] : nil;
        for (NSDictionary *link in links) {
            if (![link isKindOfClass:[NSDictionary class]]) continue;
            NSString *contentType = [link[@"content-type"] lowercaseString] ?: @"";
            NSString *linkURL = link[@"URL"];
            if ([contentType containsString:@"image"] || [linkURL.lowercaseString hasSuffix:@".jpg"] || [linkURL.lowercaseString hasSuffix:@".png"]) {
                preview.imageURL = ApolloLinkPreviewURLFromString(linkURL, url);
                if (preview.imageURL.absoluteString.length > 0) break;
            }
        }
        if (preview.imageURL.absoluteString.length == 0) ApolloLinkPreviewApplyFallbackIcon(preview, url);
        preview.fetchedAt = [NSDate date];
        ApolloLog(@"[LinkPreviews] Crossref metadata doi=%@ titleLen=%lu desc=%d", doi, (unsigned long)preview.title.length, preview.desc.length > 0);
        completion(preview);
    }] resume];
}

+ (NSDictionary<NSString *, NSString *> *)metaValuesFromHTML:(NSString *)html {
    if (html.length == 0) return @{};

    NSMutableDictionary<NSString *, NSString *> *values = [NSMutableDictionary dictionary];
    NSRegularExpression *metaRegex = [NSRegularExpression regularExpressionWithPattern:@"<meta\\s+[^>]*>" options:NSRegularExpressionCaseInsensitive error:nil];
    NSRegularExpression *attrRegex = [NSRegularExpression regularExpressionWithPattern:@"([a-zA-Z:-]+)\\s*=\\s*(['\"])(.*?)\\2"
                                                                               options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators
                                                                                 error:nil];
    NSArray<NSTextCheckingResult *> *metaMatches = [metaRegex matchesInString:html options:0 range:NSMakeRange(0, html.length)];
    for (NSTextCheckingResult *metaMatch in metaMatches) {
        NSString *tag = [html substringWithRange:metaMatch.range];
        NSMutableDictionary<NSString *, NSString *> *attrs = [NSMutableDictionary dictionary];
        NSArray<NSTextCheckingResult *> *attrMatches = [attrRegex matchesInString:tag options:0 range:NSMakeRange(0, tag.length)];
        for (NSTextCheckingResult *attrMatch in attrMatches) {
            if (attrMatch.numberOfRanges < 4) continue;
            NSString *name = [[tag substringWithRange:[attrMatch rangeAtIndex:1]] lowercaseString];
            NSString *value = [tag substringWithRange:[attrMatch rangeAtIndex:3]];
            attrs[name] = value;
        }

        NSString *key = attrs[@"property"] ?: attrs[@"name"];
        NSString *content = attrs[@"content"];
        if (key.length > 0 && content.length > 0) {
            values[key.lowercaseString] = content;
        }
    }

    NSRegularExpression *titleRegex = [NSRegularExpression regularExpressionWithPattern:@"<title[^>]*>(.*?)</title>"
                                                                                options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators
                                                                                  error:nil];
    NSTextCheckingResult *titleMatch = [titleRegex firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
    if (titleMatch && titleMatch.numberOfRanges > 1) {
        values[@"title"] = [html substringWithRange:[titleMatch rangeAtIndex:1]];
    }
    NSDictionary *jsonLD = ApolloLinkPreviewJSONLDValuesFromHTML(html);
    [jsonLD enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, __unused BOOL *stop) {
        if (key.length > 0 && value.length > 0 && !values[key]) values[key] = value;
    }];
    return values;
}

+ (void)fetchHTMLPreviewForURL:(NSURL *)url completion:(ApolloLinkPreviewCompletion)completion {
    [self fetchHTMLPreviewForURL:url allowRange:YES browserFallback:NO completion:completion];
}

+ (void)fetchHTMLPreviewForURL:(NSURL *)url allowRange:(BOOL)allowRange browserFallback:(BOOL)browserFallback completion:(ApolloLinkPreviewCompletion)completion {
    NSMutableURLRequest *request = ApolloLinkPreviewRequest(url, browserFallback ? 18.0 : 12.0);
    if (allowRange) {
        [request setValue:@"bytes=0-65535" forHTTPHeaderField:@"Range"];
    }
    if (browserFallback) {
        [request setValue:ApolloLinkPreviewBrowserUserAgent() forHTTPHeaderField:@"User-Agent"];
        [request setValue:@"text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" forHTTPHeaderField:@"Accept"];
    }

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSString *contentType = [[httpResponse allHeaderFields][@"Content-Type"] lowercaseString];
        if (error || !data || httpResponse.statusCode < 200 || httpResponse.statusCode >= 300 || data.length > ApolloLinkPreviewMaxHTMLBytes || (contentType.length > 0 && ![contentType containsString:@"text/html"])) {
            ApolloLog(@"[LinkPreviews] HTML fetch failed %@ status=%ld type=%@ bytes=%lu err=%@",
                      url.absoluteString, (long)httpResponse.statusCode, contentType ?: @"",
                      (unsigned long)data.length, error.localizedDescription);
            if (!browserFallback && (error || httpResponse.statusCode == 0 || data.length == 0)) {
                ApolloLog(@"[LinkPreviews] HTML retrying full browser fetch host=%@", ApolloLinkPreviewHost(url));
                [self fetchHTMLPreviewForURL:url allowRange:NO browserFallback:YES completion:completion];
                return;
            }
            if (ApolloLinkPreviewDOIFromURL(url).length > 0) {
                [self fetchCrossrefPreviewForURL:url completion:^(ApolloLinkPreview *preview) {
                    completion(preview ?: ApolloLinkPreviewFallbackPreviewForURL(url, nil));
                }];
            } else {
                completion(ApolloLinkPreviewFallbackPreviewForURL(url, contentType.length > 0 ? contentType : nil));
            }
            return;
        }

        NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (html.length == 0) {
            html = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
        }

        NSDictionary<NSString *, NSString *> *meta = [self metaValuesFromHTML:html];
        ApolloLinkPreview *preview = [ApolloLinkPreview new];
        preview.siteName = ApolloLinkPreviewCleanString(meta[@"og:site_name"])
            ?: ApolloLinkPreviewCleanString(meta[@"citation_journal_title"])
            ?: ApolloLinkPreviewCleanString(meta[@"prism.publicationname"])
            ?: ApolloLinkPreviewCleanString(meta[@"dc.publisher"])
            ?: ApolloLinkPreviewCleanString(meta[@"jsonld:site_name"])
            ?: ApolloLinkPreviewHost(url);
        preview.title = ApolloLinkPreviewStringByStrippingHTMLTags(meta[@"og:title"])
            ?: ApolloLinkPreviewStringByStrippingHTMLTags(meta[@"twitter:title"])
            ?: ApolloLinkPreviewStringByStrippingHTMLTags(meta[@"citation_title"])
            ?: ApolloLinkPreviewStringByStrippingHTMLTags(meta[@"dc.title"])
            ?: ApolloLinkPreviewStringByStrippingHTMLTags(meta[@"prism.title"])
            ?: ApolloLinkPreviewStringByStrippingHTMLTags(meta[@"jsonld:title"])
            ?: ApolloLinkPreviewStringByStrippingHTMLTags(meta[@"title"]);
        NSString *rawDescription = meta[@"og:description"]
            ?: meta[@"twitter:description"]
            ?: meta[@"citation_abstract"]
            ?: meta[@"dc.description"]
            ?: meta[@"jsonld:description"]
            ?: meta[@"description"];
        preview.desc = ApolloLinkPreviewTruncatedString(ApolloLinkPreviewStringByStrippingHTMLTags(rawDescription), 220);
        preview.imageURL = ApolloLinkPreviewURLFromString(meta[@"og:image"] ?: meta[@"twitter:image"] ?: meta[@"twitter:image:src"] ?: meta[@"citation_image"] ?: meta[@"jsonld:image"], url);
        preview.fetchedAt = [NSDate date];

        if (ApolloLinkPreviewHostIs(url, @"the-numbers.com")) {
            NSURL *posterURL = ApolloTheNumbersPosterURLFromHTML(html, url);
            NSString *synopsis = ApolloTheNumbersSynopsisFromHTML(html);
            if (posterURL.absoluteString.length > 0) {
                preview.imageURL = posterURL;
                preview.imageSize = CGSizeMake(300.0, 450.0);
                preview.imageIsFallbackIcon = NO;
                ApolloLog(@"[LinkPreviews] The Numbers poster extracted %@", posterURL.absoluteString);
            }
            if (synopsis.length > 0) preview.desc = synopsis;
        }

        // If we landed on a Cloudflare / Reddit verification gate, treat the
        // result as empty so Apollo's native card paints instead of "Please
        // wait for verification" everywhere.
        if (ApolloLinkPreviewIsBlockedPage(preview.title, html)) {
            ApolloLog(@"[LinkPreviews] blocked-page sniff matched %@ title=%@", url.absoluteString, preview.title);
            if (ApolloLinkPreviewDOIFromURL(url).length > 0) {
                [self fetchCrossrefPreviewForURL:url completion:^(ApolloLinkPreview *crossrefPreview) {
                    completion(crossrefPreview ?: ApolloLinkPreviewFallbackPreviewForURL(url, nil));
                }];
            } else {
                completion(ApolloLinkPreviewFallbackPreviewForURL(url, nil));
            }
            return;
        }

        if (preview.title.length == 0 && preview.desc.length == 0 && preview.imageURL.absoluteString.length == 0) {
            if (ApolloLinkPreviewDOIFromURL(url).length > 0) {
                [self fetchCrossrefPreviewForURL:url completion:^(ApolloLinkPreview *crossrefPreview) {
                    completion(crossrefPreview ?: ApolloLinkPreviewFallbackPreviewForURL(url, nil));
                }];
            } else {
                completion(ApolloLinkPreviewFallbackPreviewForURL(url, nil));
            }
            return;
        }

        BOOL weakAcademicMetadata = ApolloLinkPreviewDOIFromURL(url).length > 0
            && (preview.desc.length == 0 || [preview.title.lowercaseString hasPrefix:@"doi "] || [preview.title.lowercaseString hasPrefix:@"10."]);
        if (weakAcademicMetadata) {
            [self fetchCrossrefPreviewForURL:url completion:^(ApolloLinkPreview *crossrefPreview) {
                completion(crossrefPreview ?: preview);
            }];
            return;
        }

        if (preview.imageURL.absoluteString.length == 0 && (preview.title.length > 0 || preview.desc.length > 0)) {
            ApolloLinkPreviewApplyFallbackIcon(preview, url);
        }

        completion(preview);
    }] resume];
}

@end
