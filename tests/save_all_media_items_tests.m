#import <Foundation/Foundation.h>

// Compile the unchanged resolver in this translation unit so the provider
// fixtures exercise its private production parser without adding a test API.
#import "../src/ApolloSaveAllMediaItems.m"

NSString *sImgurClientId = nil;
NSString *sImageChestAPIToken = nil;

// The existing ImgChest URL validator is the only non-Foundation dependency.
// Provider parsing tests below exercise raw responses without network access.
NSString *ApolloImageChestPostIDFromURL(NSURL *URL) {
    if (![URL.host isEqualToString:@"imgchest.com"] || ![URL.path hasPrefix:@"/p/"]) return nil;
    return URL.lastPathComponent;
}
BOOL ApolloImageChestIsPostURL(NSURL *URL) { return ApolloImageChestPostIDFromURL(URL).length > 0; }

@interface TestSaveAllLink : NSObject
@property (nonatomic, strong) NSDictionary *mediaMetadata;
@property (nonatomic, strong) NSArray *galleryData;
@property (nonatomic, strong) id gallery;
@property (nonatomic, strong) TestSaveAllLink *crosspostParent;
@property (nonatomic, strong) NSURL *URL;
@end
@implementation TestSaveAllLink
@end

@interface TestSaveAllGallery : NSObject
@property (nonatomic, strong) NSArray *items;
@end
@implementation TestSaveAllGallery
@end

@interface TestSaveAllMember : NSObject
@property (nonatomic, strong) id image;
@end
@implementation TestSaveAllMember
@end

@interface TestSaveAllImage : NSObject
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) NSURL *mp4URL;
@end
@implementation TestSaveAllImage
@end

static NSUInteger sChecks;
static void Check(BOOL condition, NSString *description) {
    sChecks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", description.UTF8String);
        exit(1);
    }
}

static TestSaveAllMember *NativeItem(NSString *URL, NSString *mp4) {
    TestSaveAllImage *image = [TestSaveAllImage new];
    image.url = URL ? [NSURL URLWithString:URL] : nil;
    image.mp4URL = mp4 ? [NSURL URLWithString:mp4] : nil;
    TestSaveAllMember *member = [TestSaveAllMember new];
    member.image = image;
    return member;
}

int main(void) {
    @autoreleasepool {
        NSError *error = [NSError errorWithDomain:@"previous" code:1 userInfo:nil];
        Check(ApolloSaveAllMediaItemsFromLink(nil, &error) == nil && error == nil, @"nil link is not a broken collection");
        error = [NSError errorWithDomain:@"previous" code:1 userInfo:nil];
        Check(ApolloSaveAllMediaItemsFromGallery(nil, &error) == nil && error == nil, @"nil gallery is not a broken collection");

        TestSaveAllLink *single = [TestSaveAllLink new];
        single.URL = [NSURL URLWithString:@"https://i.redd.it/single.jpg"];
        Check(ApolloSaveAllMediaItemsFromLink(single, &error) == nil && error == nil, @"single post leaves native save alone");
        Check(!ApolloSaveAllMediaLinkHasCollection(single), @"single post does not receive Save All");

        TestSaveAllLink *link = [TestSaveAllLink new];
        link.galleryData = @[@{@"media_id": @"photo"}, @{@"media_id": @"animation"}, @{@"media_id": @"clip"}, @{@"media_id": @"photo"}];
        link.mediaMetadata = @{
            @"clip": @{@"status": @"valid", @"e": @"RedditVideo", @"m": @"video/mp4", @"dashUrl": @"https://v.redd.it/clip/DASHPlaylist.mpd"},
            @"animation": @{@"status": @"valid", @"e": @"AnimatedImage", @"m": @"image/gif", @"s": @{@"gif": @"https://i.redd.it/animation.gif", @"u": @"https://preview.redd.it/poster.jpg", @"mp4": @"https://preview.redd.it/animation.gif?format=mp4"}},
            @"photo": @{@"status": @"valid", @"e": @"Image", @"m": @"image/jpeg", @"s": @{@"u": @"https://i.redd.it/original.jpg?x=1&amp;y=2"}, @"p": @[@{@"u": @"https://preview.redd.it/thumbnail.jpg"}]}
        };
        NSArray<ApolloSaveAllMediaItem *> *items = ApolloSaveAllMediaItemsFromLink(link, &error);
        Check(items.count == 4 && error == nil, @"mixed gallery has every ordered member");
        Check([items[0].URL.absoluteString isEqualToString:@"https://i.redd.it/original.jpg?x=1&y=2"] && !items[0].isVideo, @"photo uses original and decodes URL entities");
        Check([items[1].URL.absoluteString isEqualToString:@"https://i.redd.it/animation.gif"] && !items[1].isVideo, @"animation uses original GIF rather than poster or transcode");
        Check(items[2].isVideo && [items[2].URL.pathExtension isEqualToString:@"mpd"], @"Reddit video preserves DASH handle for audio-aware exporter");
        Check([items[3].URL isEqual:items[0].URL], @"repeated gallery entries retain ordering and count");
        Check(ApolloSaveAllMediaLinkHasCollection(link), @"mixed gallery menu eligibility");

        TestSaveAllLink *crosspost = [TestSaveAllLink new];
        crosspost.crosspostParent = link;
        NSArray *crosspostItems = ApolloSaveAllMediaItemsFromLink(crosspost, &error);
        Check(crosspostItems.count == 4 && [((ApolloSaveAllMediaItem *)crosspostItems[2]).URL isEqual:items[2].URL], @"crosspost resolves parent gallery");

        NSMutableDictionary *brokenMetadata = [link.mediaMetadata mutableCopy];
        [brokenMetadata removeObjectForKey:@"animation"];
        link.mediaMetadata = brokenMetadata;
        Check(ApolloSaveAllMediaItemsFromLink(link, &error) == nil && error != nil, @"missing member rejects entire gallery");

        TestSaveAllGallery *native = [TestSaveAllGallery new];
        native.items = @[NativeItem(@"https://i.redd.it/a.jpg", nil), NativeItem(@"https://i.redd.it/poster.jpg", @"https://i.redd.it/clip.mp4")];
        items = ApolloSaveAllMediaItemsFromGallery(native, &error);
        Check(items.count == 2 && !items[0].isVideo && items[1].isVideo, @"native gallery preserves MP4 animation");
        link.mediaMetadata = nil;
        link.gallery = native;
        Check(ApolloSaveAllMediaItemsFromLink(link, &error) == nil && error != nil, @"truncated native fallback cannot masquerade as full gallery");
        native.items = @[NativeItem(@"https://i.redd.it/a.jpg", nil), NativeItem(nil, nil)];
        Check(ApolloSaveAllMediaItemsFromGallery(native, &error) == nil && error != nil, @"missing native source rejects entire gallery");

        items = ApolloSaveAllMediaItemsFromURLs(@[[NSURL URLWithString:@"https://i.imgur.com/animated.gifv"], [NSURL URLWithString:@"https://preview.redd.it/clip.gif?format=mp4"]], &error);
        Check(items.count == 2 && items[0].isVideo && items[1].isVideo && [items[0].URL.pathExtension isEqualToString:@"mp4"], @"Swift URL bridge sources normalize gifv and detect format=mp4");
        Check(ApolloSaveAllMediaItemsFromURLs(@[[NSURL URLWithString:@"file:///tmp/private.jpg"]], &error) == nil && error != nil, @"source list rejects non-network URLs");

        NSDictionary *imgur = @{@"images_count": @3, @"cover": @"last", @"images": @[
            @{@"link": @"https://i.imgur.com/first.jpg", @"type": @"image/jpeg"},
            @{@"link": @"https://i.imgur.com/second.gif", @"mp4": @"https://i.imgur.com/second.mp4", @"type": @"image/gif", @"animated": @YES},
            @{@"link": @"https://i.imgur.com/last.mp4", @"type": @"video/mp4"}
        ]};
        items = ApolloAllProviderItems(imgur, YES, &error);
        Check(items.count == 3 && error == nil && [items[0].URL.lastPathComponent isEqualToString:@"first.jpg"], @"Imgur reads album order rather than cover order");
        Check(!items[1].isVideo && [items[1].URL.pathExtension isEqualToString:@"gif"] && items[2].isVideo, @"Imgur preserves original GIF and video media kinds");

        NSDictionary *imgchest = @{@"image_count": @3, @"files": @[
            @{@"link": @"https://cdn.imgchest.com/files/third.mp4", @"position": @3, @"mime_type": @"video/mp4"},
            @{@"link": @"https://cdn.imgchest.com/files/first.jpg", @"position": @1},
            @{@"link": @"https://cdn.imgchest.com/files/second.gif", @"position": @2}
        ]};
        items = ApolloAllProviderItems(imgchest, NO, &error);
        Check(items.count == 3 && [items[0].URL.lastPathComponent isEqualToString:@"first.jpg"] && [items[1].URL.lastPathComponent isEqualToString:@"second.gif"] && items[2].isVideo, @"ImgChest sorts full mixed file list by position");
        NSMutableDictionary *bothLists = [imgchest mutableCopy];
        bothLists[@"images"] = @[imgchest[@"files"][1], imgchest[@"files"][2]];
        Check(ApolloAllProviderItems(bothLists, NO, &error).count == 3, @"ImgChest complete files list takes precedence over image-only list");

        NSMutableDictionary *truncated = [imgur mutableCopy];
        truncated[@"images_count"] = @4;
        Check(ApolloAllProviderItems(truncated, YES, &error) == nil && error != nil, @"reported provider count catches truncated response");
        Check(ApolloAllProviderItems(@{@"images": @[@{@"link": @"https://example.com/a.jpg"}, @{@"type": @"image/jpeg"}]}, YES, &error) == nil && error != nil, @"missing provider original rejects entire album");
        Check(ApolloAllProviderItems(@{@"images": @[@{@"link": @"https://example.com/a.pdf", @"type": @"application/pdf"}]}, YES, &error) == nil && error != nil, @"unsupported provider media rejects entire album");
        Check(ApolloAllProviderItems(@{@"images": @[@{@"link": @"https://example.com/a.m3u8", @"type": @"video/mp4"}]}, YES, &error) == nil && error != nil, @"unsupported playlist never becomes a Photos file");

        Check(ApolloSaveAllMediaURLIsCollection([NSURL URLWithString:@"https://imgur.com/a/abc123"]) && ApolloSaveAllMediaURLIsCollection([NSURL URLWithString:@"https://imgur.com/gallery/abc123"]), @"supported Imgur album URL forms");
        Check(!ApolloSaveAllMediaURLIsCollection([NSURL URLWithString:@"https://imgur.com.evil.test/a/abc123"]) && !ApolloSaveAllMediaURLIsCollection([NSURL URLWithString:@"https://imgur.com/a/a%3Fb"]), @"provider URLs require exact host and safe ID");
        printf("save_all_media_items_tests: all %lu checks passed\n", (unsigned long)sChecks);
    }
    return 0;
}
