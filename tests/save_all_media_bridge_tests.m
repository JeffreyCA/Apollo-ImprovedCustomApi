#import <Foundation/Foundation.h>

extern CFArrayRef ApolloSaveAllMediaCopyURLs(const void *storage);
extern CFArrayRef ApolloTestNilMediaURLs(void);
extern CFArrayRef ApolloTestEmptyMediaURLs(void);
extern CFArrayRef ApolloTestOrderedMediaURLs(void);
extern NSInteger ApolloTestOptionalURLArraySize(void);
extern CFURLRef ApolloLinkedAlbumCopyURL(const void *storage, size_t size);
extern CFURLRef ApolloTestLinkedAlbumURL(void);
extern CFURLRef ApolloTestLinkedAlbumInvalidSize(NSInteger adjustment);

static void Check(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        Check(ApolloTestOptionalURLArraySize() == sizeof(void *), @"native optional URL array fits the checked one-pointer ivar slot");
        Check(ApolloSaveAllMediaCopyURLs(NULL) == NULL, @"NULL storage produces nil");
        Check(ApolloTestNilMediaURLs() == NULL, @"Swift Optional.none produces nil");
        NSArray *empty = CFBridgingRelease(ApolloTestEmptyMediaURLs());
        Check(empty != nil && empty.count == 0, @"Swift some([]) remains a non-nil empty array");
        __weak NSArray *weakCopy = nil;
        @autoreleasepool {
            NSArray<NSURL *> *copy = CFBridgingRelease(ApolloTestOrderedMediaURLs());
            weakCopy = copy;
            Check(copy.count == 3, @"returned array survives the source Swift array's lifetime");
            Check([copy[0].absoluteString isEqualToString:@"https://i.redd.it/first.jpg"] && [copy[1].absoluteString isEqualToString:@"https://i.imgur.com/second.mp4"] && [copy[2] isEqual:copy[0]], @"C bridge preserves URL ordering and duplicates");
        }
        Check(weakCopy == nil, @"CFBridgingRelease balances the Swift passRetained ownership");
        Check(ApolloLinkedAlbumCopyURL(NULL, sizeof(void *)) == NULL, @"nil linked-album URL storage is rejected");
        Check(ApolloTestLinkedAlbumInvalidSize(-1) == NULL, @"short URL ivar storage is rejected before reading");
        Check(ApolloTestLinkedAlbumInvalidSize(1) == NULL, @"oversized URL ivar storage is rejected before reading");
        __weak NSURL *weakURL = nil;
        @autoreleasepool {
            NSURL *url = CFBridgingRelease(ApolloTestLinkedAlbumURL());
            weakURL = url;
            Check([url isKindOfClass:NSURL.class], @"retained NSURL survives the source Swift URL's lifetime");
            Check([url.absoluteString isEqualToString:@"https://imgur.com/a/L9afIk4?source=post#2"], @"URL bridge preserves album identity, query and fragment without mutation");
        }
        Check(weakURL == nil, @"linked-album NSURL retained ownership balances on release");
    }
    puts("save_all_media_bridge_tests: all 13 checks passed");
    return 0;
}
