// ApolloImgChestUpload.m
//
// ImgChest as a media upload host (issue #414), plus the cross-provider
// upload registry that makes Apollo's native Manage Uploads screen work for
// non-Imgur uploads.
//
// How it fits in: Apollo only knows how to upload to Imgur. Like the Reddit
// upload host, the ImgChest host works by intercepting Apollo's Imgur upload
// request (see ApolloImageUploadHost.xm), uploading to ImgChest instead, and
// answering with a synthetic Imgur response carrying the ImgChest link. The
// synthetic id/deletehash is the CDN filename; this module remembers which
// provider each deletehash belongs to (persisted), so when Apollo's Manage
// Uploads screen issues an Imgur DELETE for it, we can route the deletion to
// the right place: ImgChest posts are deleted via the ImgChest API; Reddit
// uploads (no delete API) are acknowledged so the entry leaves the list.
//
// Albums: Apollo uploads each image individually, then creates an Imgur
// album from their deletehashes. Each intercepted image upload becomes its
// own hidden single-image ImgChest post (the composer needs a working link
// immediately), with the original bytes cached. At album-creation time the
// cached bytes are combined into ONE multi-image ImgChest post (the album),
// the interim single-image posts are deleted, and a synthetic Imgur album
// response is returned with link = imgchest.com/p/<post> — which this tweak
// already renders as a swipeable inline album.

#import "ApolloImgChestUpload.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import <objc/runtime.h>

static NSString *const kImgChestAPIBase = @"https://api.imgchest.com/v1";
static NSString *const kUploadRegistryDefaultsKey = @"ApolloRebornUploadRegistry";
static NSString *const kProviderImgChest = @"imgchest";
static NSString *const kProviderImgChestMerged = @"imgchest-merged";
static NSString *const kProviderReddit = @"reddit";

// Owned files cached per token for album combining; evicted once combined or
// when the cap is exceeded (oldest first). 150 MB covers any realistic album.
static const unsigned long long kAlbumFileCacheCapBytes = 150ULL * 1024ULL * 1024ULL;
static char kApolloImgChestUploadOperationKey;
static void ApolloImgChestRemoveManagedFile(NSURL *fileURL);
static NSError *ApolloImgChestError(NSString *message);
static NSError *ApolloImgChestCancelledError(void);

static dispatch_queue_t ApolloImgChestMultipartQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.apolloreborn.imgchest-multipart", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(queue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    });
    return queue;
}

@interface ApolloImgChestUploadOperation ()
@property (atomic, readwrite, getter=isCancelled) BOOL cancelled;
@property (nonatomic, strong) NSURLSessionTask *activeTask;
@property (nonatomic, strong) NSMutableSet<NSURL *> *cleanupFiles;
@property (nonatomic) BOOL finished;
- (BOOL)adoptTaskIfActive:(NSURLSessionTask *)task;
- (void)addCleanupFile:(NSURL *)fileURL;
- (void)relinquishCleanupFile:(NSURL *)fileURL;
- (BOOL)finishOnce;
@end

@implementation ApolloImgChestUploadOperation

- (instancetype)init {
    self = [super init];
    if (self) _cleanupFiles = [NSMutableSet set];
    return self;
}

- (void)cancel {
    NSURLSessionTask *task = nil;
    NSArray<NSURL *> *files = nil;
    @synchronized (self) {
        if (self.cancelled || self.finished) return;
        self.cancelled = YES;
        task = self.activeTask;
        self.activeTask = nil;
        files = self.cleanupFiles.allObjects;
        [self.cleanupFiles removeAllObjects];
    }
    [task cancel];
    for (NSURL *fileURL in files) ApolloImgChestRemoveManagedFile(fileURL);
}

- (BOOL)adoptTaskIfActive:(NSURLSessionTask *)task {
    @synchronized (self) {
        if (self.cancelled || self.finished) return NO;
        self.activeTask = task;
        return YES;
    }
}

- (void)addCleanupFile:(NSURL *)fileURL {
    if (!fileURL) return;
    BOOL removeNow = NO;
    @synchronized (self) {
        if (self.cancelled || self.finished) removeNow = YES;
        else [self.cleanupFiles addObject:fileURL];
    }
    if (removeNow) ApolloImgChestRemoveManagedFile(fileURL);
}

- (void)relinquishCleanupFile:(NSURL *)fileURL {
    if (!fileURL) return;
    @synchronized (self) { [self.cleanupFiles removeObject:fileURL]; }
}

- (BOOL)finishOnce {
    @synchronized (self) {
        if (self.finished) return NO;
        self.finished = YES;
        self.activeTask = nil;
        return YES;
    }
}

@end

void ApolloImgChestAssociateOperationWithTask(ApolloImgChestUploadOperation *operation, NSURLSessionTask *task) {
    if (!operation || !task) return;
    objc_setAssociatedObject(task, &kApolloImgChestUploadOperationKey, operation, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void ApolloImgChestCancelOperationAssociatedWithTask(NSURLSessionTask *task) {
    ApolloImgChestUploadOperation *operation = task
        ? objc_getAssociatedObject(task, &kApolloImgChestUploadOperationKey) : nil;
    [operation cancel];
}

#pragma mark - Upload registry (persisted)

static NSObject *ApolloUploadRegistryLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static NSMutableDictionary<NSString *, NSDictionary *> *ApolloUploadRegistryCopy(void) {
    NSDictionary *stored = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kUploadRegistryDefaultsKey];
    return stored ? [stored mutableCopy] : [NSMutableDictionary dictionary];
}

static void ApolloUploadRegistrySet(NSString *token, NSDictionary *_Nullable entry) {
    if (token.length == 0) return;
    @synchronized (ApolloUploadRegistryLock()) {
        NSMutableDictionary *registry = ApolloUploadRegistryCopy();
        if (entry) registry[token] = entry;
        else [registry removeObjectForKey:token];
        [[NSUserDefaults standardUserDefaults] setObject:registry forKey:kUploadRegistryDefaultsKey];
    }
}

static NSDictionary *_Nullable ApolloUploadRegistryEntry(NSString *token) {
    if (token.length == 0) return nil;
    @synchronized (ApolloUploadRegistryLock()) {
        NSDictionary *entry = ApolloUploadRegistryCopy()[token];
        return [entry isKindOfClass:[NSDictionary class]] ? entry : nil;
    }
}

NSURL *ApolloImgChestPostURLForUploadedLink(NSURL *cdnLink) {
    if (![cdnLink isKindOfClass:[NSURL class]]) return nil;
    NSDictionary *entry = ApolloUploadRegistryEntry(cdnLink.lastPathComponent);
    NSString *postID = [entry[@"post"] isKindOfClass:[NSString class]] ? entry[@"post"] : nil;
    if (postID.length == 0) return nil;
    return [NSURL URLWithString:[@"https://imgchest.com/p/" stringByAppendingString:postID]];
}

NSURL *ApolloImgChestPostURLForAlbumID(NSString *albumID) {
    if (![albumID isKindOfClass:[NSString class]] || albumID.length == 0) return nil;
    NSDictionary *entry = ApolloUploadRegistryEntry(albumID);
    NSString *provider = [entry[@"provider"] isKindOfClass:[NSString class]] ? entry[@"provider"] : nil;
    if (![provider isEqualToString:kProviderImgChest]) return nil;
    NSString *link = [entry[@"link"] isKindOfClass:[NSString class]] ? entry[@"link"] : nil;
    if (link.length > 0) return [NSURL URLWithString:link];
    NSString *postID = [entry[@"post"] isKindOfClass:[NSString class]] ? entry[@"post"] : nil;
    return postID.length > 0 ? [NSURL URLWithString:[@"https://imgchest.com/p/" stringByAppendingString:postID]] : nil;
}

void ApolloUploadRegistryRecordRedditUpload(NSURL *mediaURL) {
    NSString *token = mediaURL.lastPathComponent;
    if (token.length == 0) return;
    ApolloUploadRegistrySet(token, @{ @"provider": kProviderReddit,
                                      @"link": mediaURL.absoluteString ?: @"" });
}

#pragma mark - CDN User-Agent (Manage Uploads thumbnails, etc.)

static NSString *const kImgChestUserAgent = @"Apollo/1.15.11 (iOS)";

BOOL ApolloImgChestIsImgChestHostURL(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    return [host isEqualToString:@"imgchest.com"] || [host hasSuffix:@".imgchest.com"];
}

NSURLRequest *ApolloImgChestRequestByAddingUserAgentIfNeeded(NSURLRequest *request) {
    if (![request isKindOfClass:[NSURLRequest class]]) return nil;
    if (!ApolloImgChestIsImgChestHostURL(request.URL)) return nil;
    if ([request valueForHTTPHeaderField:@"User-Agent"].length > 0) return nil;

    NSMutableURLRequest *modified = [request mutableCopy];
    [modified setValue:kImgChestUserAgent forHTTPHeaderField:@"User-Agent"];
    return modified;
}


#pragma mark - Album file cache

typedef NSDictionary ApolloImgChestCachedUpload; // {fileURL, size, filename, mimeType, post}

// This directory contains only transient files whose ownership is represented
// by the in-memory token cache below. That metadata cannot survive a relaunch,
// so the first access clears every orphan left by a previous process.
static NSURL *ApolloImgChestManagedDirectory(void) {
    static NSURL *directory;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *caches = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory
                                                                inDomains:NSUserDomainMask] firstObject];
        directory = [caches URLByAppendingPathComponent:@"ApolloRebornImgChestUploads" isDirectory:YES];
        [[NSFileManager defaultManager] removeItemAtURL:directory error:nil];
        NSError *error = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtURL:directory
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:&error]) {
            ApolloLog(@"[ImgChestUpload] could not prepare managed directory: %@", error.localizedDescription);
        }
    });
    return directory;
}

static void ApolloImgChestRemoveManagedFile(NSURL *fileURL) {
    if (![fileURL isKindOfClass:[NSURL class]]) return;
    NSURL *directory = ApolloImgChestManagedDirectory();
    if (![fileURL.path hasPrefix:[directory.path stringByAppendingString:@"/"]]) return;
    [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
}

static NSNumber *ApolloImgChestFileSize(NSURL *fileURL) {
    if (![fileURL isKindOfClass:NSURL.class] || !fileURL.isFileURL) return @0;

    NSNumber *size = nil;
    [fileURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    if (![size isKindOfClass:[NSNumber class]]) {
        size = [[[NSFileManager defaultManager] attributesOfItemAtPath:fileURL.path error:nil] objectForKey:NSFileSize];
    }
    return [size isKindOfClass:[NSNumber class]] ? size : @0;
}

static NSURL *ApolloImgChestUniqueManagedURL(NSString *filename) {
    NSString *extension = filename.lastPathComponent.pathExtension;
    NSString *name = [NSUUID UUID].UUIDString;
    if (extension.length > 0) name = [name stringByAppendingPathExtension:extension];
    return [ApolloImgChestManagedDirectory() URLByAppendingPathComponent:name];
}

static NSURL *ApolloImgChestCopyFileIntoManagedStorage(NSURL *sourceURL, NSString *filename,
                                                        ApolloImgChestUploadOperation *operation,
                                                        NSError **outError) {
    if (![sourceURL isKindOfClass:[NSURL class]] || !sourceURL.isFileURL) {
        if (outError) *outError = [NSError errorWithDomain:@"ApolloImgChestUpload" code:-2
                                                  userInfo:@{NSLocalizedDescriptionKey: @"Invalid image file URL"}];
        return nil;
    }
    NSURL *destination = ApolloImgChestUniqueManagedURL(filename ?: sourceURL.lastPathComponent ?: @"image.jpg");
    if (![[NSFileManager defaultManager] createFileAtPath:destination.path contents:nil attributes:nil]) {
        if (outError) *outError = [NSError errorWithDomain:@"ApolloImgChestUpload" code:-4
                                                   userInfo:@{NSLocalizedDescriptionKey: @"Could not create staged image file"}];
        return nil;
    }
    NSFileHandle *input = [NSFileHandle fileHandleForReadingAtPath:sourceURL.path];
    NSFileHandle *output = [NSFileHandle fileHandleForWritingAtPath:destination.path];
    BOOL success = input && output;
    BOOL reachedEnd = NO;
    NSError *stagingError = nil;
    while (success && !reachedEnd) {
        @autoreleasepool {
            if (operation.cancelled) {
                stagingError = ApolloImgChestCancelledError();
                success = NO;
                continue;
            }
            @try {
                NSData *chunk = [input readDataOfLength:64 * 1024];
                if (chunk.length == 0) reachedEnd = YES;
                else [output writeData:chunk];
            } @catch (NSException *exception) {
                stagingError = [NSError errorWithDomain:@"ApolloImgChestUpload" code:-5
                                                userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"Could not stage image file"}];
                success = NO;
            }
        }
    }
    [input closeFile];
    [output closeFile];
    if (!success) {
        ApolloImgChestRemoveManagedFile(destination);
        if (outError && stagingError) *outError = stagingError;
        return nil;
    }
    if (ApolloImgChestFileSize(destination).unsignedLongLongValue == 0) {
        ApolloImgChestRemoveManagedFile(destination);
        if (outError && !*outError) *outError = [NSError errorWithDomain:@"ApolloImgChestUpload" code:-3
                                                               userInfo:@{NSLocalizedDescriptionKey: @"Image file was empty"}];
        return nil;
    }
    return destination;
}

static NSURL *ApolloImgChestWriteDataIntoManagedStorage(NSData *data, NSString *filename,
                                                         ApolloImgChestUploadOperation *operation,
                                                         NSError **outError) {
    NSURL *destination = ApolloImgChestUniqueManagedURL(filename ?: @"image.jpg");
    if (![[NSFileManager defaultManager] createFileAtPath:destination.path contents:nil attributes:nil]) return nil;
    NSFileHandle *output = [NSFileHandle fileHandleForWritingAtPath:destination.path];
    BOOL success = output != nil;
    NSError *stagingError = nil;
    for (NSUInteger offset = 0; success && offset < data.length; offset += MIN((NSUInteger)(64 * 1024), data.length - offset)) {
        @autoreleasepool {
            if (operation.cancelled) {
                stagingError = ApolloImgChestCancelledError();
                success = NO;
                continue;
            }
            NSUInteger length = MIN((NSUInteger)(64 * 1024), data.length - offset);
            @try { [output writeData:[data subdataWithRange:NSMakeRange(offset, length)]]; }
            @catch (NSException *exception) {
                stagingError = [NSError errorWithDomain:@"ApolloImgChestUpload" code:-6
                                                userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"Could not stage image data"}];
                success = NO;
            }
        }
    }
    [output closeFile];
    if (!success) {
        ApolloImgChestRemoveManagedFile(destination);
        if (outError && stagingError) *outError = stagingError;
        return nil;
    }
    return destination;
}

static NSMutableArray<NSString *> *ApolloImgChestCacheOrder(void) {
    static NSMutableArray *order;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ order = [NSMutableArray array]; });
    return order;
}

static NSMutableDictionary<NSString *, ApolloImgChestCachedUpload *> *ApolloImgChestCache(void) {
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

static void ApolloImgChestCacheStore(NSString *token, NSDictionary *upload) {
    if (token.length == 0 || !upload) return;
    @synchronized (ApolloImgChestCache()) {
        NSURL *replacedURL = [ApolloImgChestCache()[token][@"fileURL"] isKindOfClass:[NSURL class]]
            ? ApolloImgChestCache()[token][@"fileURL"] : nil;
        ApolloImgChestCache()[token] = upload;
        [ApolloImgChestCacheOrder() removeObject:token];
        [ApolloImgChestCacheOrder() addObject:token];
        NSURL *newURL = [upload[@"fileURL"] isKindOfClass:[NSURL class]] ? upload[@"fileURL"] : nil;
        if (replacedURL && ![replacedURL isEqual:newURL]) ApolloImgChestRemoveManagedFile(replacedURL);

        unsigned long long totalBytes = 0;
        for (NSDictionary *entry in ApolloImgChestCache().allValues) {
            totalBytes += [entry[@"size"] respondsToSelector:@selector(unsignedLongLongValue)]
                ? [entry[@"size"] unsignedLongLongValue] : 0;
        }
        while (totalBytes > kAlbumFileCacheCapBytes && ApolloImgChestCacheOrder().count > 0) {
            NSString *oldest = ApolloImgChestCacheOrder().firstObject;
            NSDictionary *evicted = ApolloImgChestCache()[oldest];
            unsigned long long evictedSize = [evicted[@"size"] respondsToSelector:@selector(unsignedLongLongValue)]
                ? [evicted[@"size"] unsignedLongLongValue] : 0;
            totalBytes = totalBytes > evictedSize ? totalBytes - evictedSize : 0;
            ApolloImgChestRemoveManagedFile([evicted[@"fileURL"] isKindOfClass:[NSURL class]] ? evicted[@"fileURL"] : nil);
            [ApolloImgChestCache() removeObjectForKey:oldest];
            [ApolloImgChestCacheOrder() removeObjectAtIndex:0];
        }
    }
}

// Read-only lookup — it returns the cached entry without evicting it; the
// actual eviction happens separately in ApolloImgChestCacheRemove once the
// combined album post has been created.
static NSDictionary *_Nullable ApolloImgChestCachePeek(NSString *token) {
    @synchronized (ApolloImgChestCache()) {
        NSDictionary *entry = ApolloImgChestCache()[token];
        return entry;
    }
}

// Freeze album members while holding the same lock used by cache eviction.
// Hard links are effectively free snapshots on this volume: eviction may
// unlink the cache-owned name afterward, while the album build keeps a stable
// inode until its operation completes or is cancelled.
static NSArray<NSDictionary *> *_Nullable ApolloImgChestSnapshotCachedParts(
    NSArray<NSString *> *tokens, NSArray<NSURL *> **snapshotFilesOut, NSError **outError) {
    NSMutableArray<NSDictionary *> *parts = [NSMutableArray arrayWithCapacity:tokens.count];
    NSMutableArray<NSURL *> *snapshotFiles = [NSMutableArray arrayWithCapacity:tokens.count];
    @synchronized (ApolloImgChestCache()) {
        for (NSString *token in tokens) {
            NSDictionary *cached = ApolloImgChestCache()[token];
            NSURL *sourceURL = [cached[@"fileURL"] isKindOfClass:[NSURL class]] ? cached[@"fileURL"] : nil;
            if (ApolloImgChestFileSize(sourceURL).unsignedLongLongValue == 0) {
                if (outError) *outError = ApolloImgChestError(@"An album image expired before it could be combined");
                for (NSURL *snapshotURL in snapshotFiles) ApolloImgChestRemoveManagedFile(snapshotURL);
                return nil;
            }

            NSURL *snapshotURL = ApolloImgChestUniqueManagedURL(sourceURL.lastPathComponent ?: @"album-image");
            NSError *linkError = nil;
            if (![[NSFileManager defaultManager] linkItemAtURL:sourceURL toURL:snapshotURL error:&linkError]) {
                if (outError) *outError = linkError ?: ApolloImgChestError(@"Could not snapshot an album image");
                for (NSURL *createdURL in snapshotFiles) ApolloImgChestRemoveManagedFile(createdURL);
                return nil;
            }
            NSMutableDictionary *snapshotPart = [cached mutableCopy];
            snapshotPart[@"fileURL"] = snapshotURL;
            [parts addObject:snapshotPart];
            [snapshotFiles addObject:snapshotURL];
        }
    }
    if (snapshotFilesOut) *snapshotFilesOut = [snapshotFiles copy];
    return [parts copy];
}

static void ApolloImgChestCacheRemove(NSArray<NSString *> *tokens) {
    @synchronized (ApolloImgChestCache()) {
        for (NSString *token in tokens) {
            NSDictionary *entry = ApolloImgChestCache()[token];
            ApolloImgChestRemoveManagedFile([entry[@"fileURL"] isKindOfClass:[NSURL class]] ? entry[@"fileURL"] : nil);
            [ApolloImgChestCache() removeObjectForKey:token];
            [ApolloImgChestCacheOrder() removeObject:token];
        }
    }
}

#pragma mark - ImgChest API

BOOL ApolloImgChestUploadAvailable(void) {
    return sImageChestAPIToken.length > 0;
}

static NSError *ApolloImgChestError(NSString *message) {
    return [NSError errorWithDomain:@"ApolloImgChestUpload"
                               code:-1
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Image Chest upload failed"}];
}

static NSError *ApolloImgChestCancelledError(void) {
    return [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled
                           userInfo:@{NSLocalizedDescriptionKey: @"Image Chest upload cancelled"}];
}

static NSString *ApolloImgChestSanitizedMultipartFilename(NSString *filename) {
    NSString *last = [filename isKindOfClass:[NSString class]] ? filename.lastPathComponent : nil;
    if (last.length == 0) last = @"image.jpg";
    NSMutableString *safe = [NSMutableString stringWithCapacity:MIN(last.length, (NSUInteger)180)];
    NSUInteger limit = MIN(last.length, (NSUInteger)180);
    NSCharacterSet *controls = [NSCharacterSet controlCharacterSet];
    for (NSUInteger i = 0; i < limit; i++) {
        unichar character = [last characterAtIndex:i];
        BOOL control = [controls characterIsMember:character];
        unichar safeCharacter = (control || character == '"' || character == '\\') ? (unichar)'_' : character;
        [safe appendFormat:@"%C", safeCharacter];
    }
    return safe.length > 0 ? safe : @"image.jpg";
}

static NSString *ApolloImgChestSafeMIMEType(NSString *mimeType) {
    if (![mimeType isKindOfClass:[NSString class]] || mimeType.length == 0 || mimeType.length > 100) return @"image/jpeg";
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$&^_.+-/"];
    return [mimeType rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound ? mimeType : @"image/jpeg";
}

static BOOL ApolloImgChestAppendData(NSFileHandle *handle, NSData *data, NSError **outError) {
    @try {
        [handle writeData:data];
        return YES;
    } @catch (NSException *exception) {
        if (outError) *outError = ApolloImgChestError(exception.reason ?: @"Could not write multipart body");
        return NO;
    }
}

static BOOL ApolloImgChestAppendString(NSFileHandle *handle, NSString *string, NSError **outError) {
    return ApolloImgChestAppendData(handle, [string dataUsingEncoding:NSUTF8StringEncoding], outError);
}

// Assemble multipart syntax and image bytes into one temporary file. Each
// source is copied in 64 KB chunks, so album size no longer multiplies resident
// memory. The caller removes the returned body after NSURLSession completes.
static NSURL *ApolloImgChestMultipartFile(NSString *boundary,
                                          NSDictionary<NSString *, NSString *> *fields,
                                          NSArray<NSDictionary *> *imageParts,
                                          ApolloImgChestUploadOperation *operation,
                                          NSError **outError) {
    NSURL *bodyURL = [ApolloImgChestManagedDirectory() URLByAppendingPathComponent:
        [[NSUUID UUID].UUIDString stringByAppendingPathExtension:@"multipart"]];
    if (![[NSFileManager defaultManager] createFileAtPath:bodyURL.path contents:nil attributes:nil]) {
        if (outError) *outError = ApolloImgChestError(@"Could not create multipart body file");
        return nil;
    }
    [operation addCleanupFile:bodyURL];

    NSFileHandle *output = [NSFileHandle fileHandleForWritingAtPath:bodyURL.path];
    BOOL success = output != nil && !operation.cancelled;
    for (NSString *name in fields) {
        if (!success) break;
        if (operation.cancelled) {
            success = NO;
            if (outError) *outError = ApolloImgChestCancelledError();
            break;
        }
        success = ApolloImgChestAppendString(output, [NSString stringWithFormat:@"--%@\r\n", boundary], outError)
            && ApolloImgChestAppendString(output, [NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"\r\n\r\n", name], outError)
            && ApolloImgChestAppendString(output, [NSString stringWithFormat:@"%@\r\n", fields[name]], outError);
    }
    for (NSDictionary *part in imageParts) {
        if (!success) break;
        if (operation.cancelled) {
            success = NO;
            if (outError) *outError = ApolloImgChestCancelledError();
            break;
        }
        NSURL *fileURL = [part[@"fileURL"] isKindOfClass:[NSURL class]] ? part[@"fileURL"] : nil;
        if (ApolloImgChestFileSize(fileURL).unsignedLongLongValue == 0) {
            success = NO;
            if (outError) *outError = ApolloImgChestError(@"Album image file was missing or empty");
            break;
        }
        NSString *filename = ApolloImgChestSanitizedMultipartFilename(part[@"filename"]);
        NSString *mimeType = ApolloImgChestSafeMIMEType(part[@"mimeType"]);
        success = ApolloImgChestAppendString(output, [NSString stringWithFormat:@"--%@\r\n", boundary], outError)
            && ApolloImgChestAppendString(output, [NSString stringWithFormat:@"Content-Disposition: form-data; name=\"images[]\"; filename=\"%@\"\r\n", filename], outError)
            && ApolloImgChestAppendString(output, [NSString stringWithFormat:@"Content-Type: %@\r\n\r\n", mimeType], outError);
        NSFileHandle *input = success ? [NSFileHandle fileHandleForReadingAtPath:fileURL.path] : nil;
        if (success && !input) {
            success = NO;
            if (outError) *outError = ApolloImgChestError(@"Could not open album image file");
        }
        BOOL reachedEnd = NO;
        NSError *streamError = nil;
        while (success && !reachedEnd) {
            @autoreleasepool {
                if (operation.cancelled) {
                    streamError = ApolloImgChestCancelledError();
                    success = NO;
                    continue;
                }
                NSData *chunk = nil;
                @try { chunk = [input readDataOfLength:64 * 1024]; }
                @catch (NSException *exception) {
                    streamError = ApolloImgChestError(exception.reason ?: @"Could not read album image file");
                    success = NO;
                }
                if (success && chunk.length == 0) {
                    reachedEnd = YES;
                } else if (success) {
                    success = ApolloImgChestAppendData(output, chunk, &streamError);
                }
            }
        }
        if (!success && outError && streamError) *outError = streamError;
        [input closeFile];
        if (success) success = ApolloImgChestAppendString(output, @"\r\n", outError);
    }
    if (success) success = ApolloImgChestAppendString(output, [NSString stringWithFormat:@"--%@--\r\n", boundary], outError);
    [output closeFile];

    if (!success) {
        ApolloImgChestRemoveManagedFile(bodyURL);
        [operation relinquishCleanupFile:bodyURL];
        return nil;
    }
    return bodyURL;
}

// POST /v1/post with the given image parts. completion(postDictionary, error)
// where postDictionary is the API's `data` object: {id, link, images: [...]}.
static void ApolloImgChestCreatePost(NSArray<NSDictionary *> *imageParts,
                                     ApolloImgChestUploadOperation *operation,
    void (^completion)(NSDictionary *_Nullable post, NSError *_Nullable error)) {
    if (!ApolloImgChestUploadAvailable()) {
        if ([operation finishOnce]) completion(nil, ApolloImgChestError(@"No Image Chest API key configured"));
        return;
    }
    NSString *boundary = [NSString stringWithFormat:@"apollo-imgchest-%@", [NSUUID UUID].UUIDString];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kImgChestAPIBase stringByAppendingString:@"/post"]]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 120.0;
    [request setValue:[@"Bearer " stringByAppendingString:sImageChestAPIToken] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary] forHTTPHeaderField:@"Content-Type"];
    // "hidden" = unlisted: reachable by link, not listed publicly.
    NSError *bodyError = nil;
    NSURL *multipartURL = ApolloImgChestMultipartFile(boundary, @{ @"privacy": @"hidden" }, imageParts, operation, &bodyError);
    if (!multipartURL) {
        NSError *error = bodyError ?: (operation.cancelled
            ? ApolloImgChestCancelledError()
            : ApolloImgChestError(@"Could not build Image Chest upload"));
        if ([operation finishOnce]) completion(nil, error);
        return;
    }
    if (operation.cancelled) {
        ApolloImgChestRemoveManagedFile(multipartURL);
        [operation relinquishCleanupFile:multipartURL];
        if ([operation finishOnce]) completion(nil, ApolloImgChestCancelledError());
        return;
    }

    NSURLSessionUploadTask *task = [[NSURLSession sharedSession] uploadTaskWithRequest:request
                                                                              fromFile:multipartURL
                                                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        ApolloImgChestRemoveManagedFile(multipartURL);
        [operation relinquishCleanupFile:multipartURL];
        if (operation.cancelled) {
            if ([operation finishOnce]) completion(nil, ApolloImgChestCancelledError());
            return;
        }
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        id root = data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *json = [root isKindOfClass:[NSDictionary class]] ? root : nil;
        NSDictionary *post = [json[@"data"] isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;
        if (error || http.statusCode < 200 || http.statusCode >= 300 || !post) {
            NSString *message = [json[@"message"] isKindOfClass:[NSString class]] ? json[@"message"] : nil;
            ApolloLog(@"[ImgChestUpload] create post failed status=%ld err=%@ msg=%@ bytes=%lu",
                      (long)http.statusCode, error.localizedDescription ?: @"nil", message ?: @"nil", (unsigned long)data.length);
            if ([operation finishOnce]) completion(nil, error ?: ApolloImgChestError(message ?: @"Image Chest upload failed"));
            return;
        }
        if ([operation finishOnce]) completion(post, nil);
    }];
    if (![operation adoptTaskIfActive:task]) {
        [task cancel];
        ApolloImgChestRemoveManagedFile(multipartURL);
        [operation relinquishCleanupFile:multipartURL];
        if ([operation finishOnce]) completion(nil, ApolloImgChestCancelledError());
        return;
    }
    [task resume];
}

static void ApolloImgChestDeletePost(NSString *postID, void (^_Nullable completion)(BOOL success)) {
    if (postID.length == 0 || !ApolloImgChestUploadAvailable()) {
        if (completion) completion(NO);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@/post/%@", kImgChestAPIBase, postID]]];
    request.HTTPMethod = @"DELETE";
    [request setValue:[@"Bearer " stringByAppendingString:sImageChestAPIToken] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        BOOL success = !error && http.statusCode >= 200 && http.statusCode < 300;
        if (!success) {
            ApolloLog(@"[ImgChestUpload] delete post %@ failed status=%ld err=%@", postID, (long)http.statusCode, error.localizedDescription ?: @"nil");
        }
        if (completion) completion(success);
    }] resume];
}

// First image's direct CDN link from a post's `images` array.
static NSURL *_Nullable ApolloImgChestFirstImageLink(NSDictionary *post) {
    NSArray *images = [post[@"images"] isKindOfClass:[NSArray class]] ? post[@"images"] : nil;
    NSDictionary *first = images.count > 0 && [images.firstObject isKindOfClass:[NSDictionary class]] ? images.firstObject : nil;
    NSString *link = [first[@"link"] isKindOfClass:[NSString class]] ? first[@"link"] : nil;
    return link.length > 0 ? [NSURL URLWithString:link] : nil;
}

#pragma mark - Single-image upload

static void ApolloImgChestUploadOwnedFile(NSURL *ownedFileURL,
                                          NSString *filename,
                                          NSString *mimeType,
                                          ApolloImgChestUploadOperation *operation,
                                          void (^completion)(NSURL *_Nullable directLink, NSError *_Nullable error)) {
    NSNumber *size = ApolloImgChestFileSize(ownedFileURL);
    if (size.unsignedLongLongValue == 0) {
        ApolloImgChestRemoveManagedFile(ownedFileURL);
        [operation relinquishCleanupFile:ownedFileURL];
        if ([operation finishOnce]) completion(nil, ApolloImgChestError(@"Empty image file"));
        return;
    }
    NSDictionary *part = @{ @"fileURL": ownedFileURL,
                             @"size": size,
                             @"filename": ApolloImgChestSanitizedMultipartFilename(filename),
                             @"mimeType": ApolloImgChestSafeMIMEType(mimeType) };
    ApolloImgChestCreatePost(@[part], operation, ^(NSDictionary *post, NSError *error) {
        NSString *postID = [post[@"id"] isKindOfClass:[NSString class]] ? post[@"id"] : nil;
        NSURL *link = ApolloImgChestFirstImageLink(post);
        if (!postID || !link) {
            ApolloImgChestRemoveManagedFile(ownedFileURL);
            [operation relinquishCleanupFile:ownedFileURL];
            completion(nil, error ?: ApolloImgChestError(@"Image Chest response missing link"));
            return;
        }
        // The synthetic Imgur response derives id/deletehash from the link's
        // last path component — key everything off that same token.
        NSString *token = link.lastPathComponent;
        ApolloUploadRegistrySet(token, @{ @"provider": kProviderImgChest,
                                          @"post": postID,
                                          @"link": link.absoluteString ?: @"" });
        ApolloImgChestCacheStore(token, @{ @"fileURL": ownedFileURL,
                                           @"size": size,
                                           @"filename": ApolloImgChestSanitizedMultipartFilename(filename),
                                           @"mimeType": ApolloImgChestSafeMIMEType(mimeType),
                                           @"post": postID });
        [operation relinquishCleanupFile:ownedFileURL];
        ApolloLog(@"[ImgChestUpload] uploaded %@ bytes -> post=%@ link=%@", size, postID, link.absoluteString);
        completion(link, nil);
    });
}

ApolloImgChestUploadOperation *ApolloImgChestUploadData(NSData *data,
                                                         NSString *filename,
                                                         NSString *mimeType,
                                                         void (^completion)(NSURL *_Nullable directLink, NSError *_Nullable error)) {
    ApolloImgChestUploadOperation *operation = [ApolloImgChestUploadOperation new];
    if (data.length == 0) {
        [operation finishOnce];
        completion(nil, ApolloImgChestError(@"Empty image data"));
        return operation;
    }
    NSData *dataCopy = [data copy];
    NSString *filenameCopy = [filename copy];
    NSString *mimeTypeCopy = [mimeType copy];
    dispatch_async(ApolloImgChestMultipartQueue(), ^{
        if (operation.cancelled) {
            if ([operation finishOnce]) completion(nil, ApolloImgChestCancelledError());
            return;
        }
        NSError *error = nil;
        NSURL *ownedFileURL = ApolloImgChestWriteDataIntoManagedStorage(dataCopy, filenameCopy, operation, &error);
        if (!ownedFileURL) {
            if ([operation finishOnce]) completion(nil, error ?: ApolloImgChestError(@"Could not stage image data"));
            return;
        }
        [operation addCleanupFile:ownedFileURL];
        if (operation.cancelled) {
            if ([operation finishOnce]) completion(nil, ApolloImgChestCancelledError());
            return;
        }
        ApolloImgChestUploadOwnedFile(ownedFileURL, filenameCopy, mimeTypeCopy, operation, completion);
    });
    return operation;
}

ApolloImgChestUploadOperation *ApolloImgChestUploadFile(NSURL *fileURL,
                                                         NSString *filename,
                                                         NSString *mimeType,
                                                         void (^completion)(NSURL *_Nullable directLink, NSError *_Nullable error)) {
    ApolloImgChestUploadOperation *operation = [ApolloImgChestUploadOperation new];
    NSURL *sourceURL = [fileURL copy];
    NSString *filenameCopy = [filename copy];
    NSString *mimeTypeCopy = [mimeType copy];
    dispatch_async(ApolloImgChestMultipartQueue(), ^{
        if (operation.cancelled) {
            if ([operation finishOnce]) completion(nil, ApolloImgChestCancelledError());
            return;
        }
        NSError *error = nil;
        NSURL *ownedFileURL = ApolloImgChestCopyFileIntoManagedStorage(sourceURL, filenameCopy, operation, &error);
        if (!ownedFileURL) {
            if ([operation finishOnce]) completion(nil, error ?: ApolloImgChestError(@"Could not stage image file"));
            return;
        }
        [operation addCleanupFile:ownedFileURL];
        if (operation.cancelled) {
            if ([operation finishOnce]) completion(nil, ApolloImgChestCancelledError());
            return;
        }
        ApolloImgChestUploadOwnedFile(ownedFileURL, filenameCopy, mimeTypeCopy, operation, completion);
    });
    return operation;
}

#pragma mark - Album combining

static BOOL ApolloImgChestIsImgurAlbumCreationRequest(NSURLRequest *request) {
    if (![request isKindOfClass:[NSURLRequest class]]) return NO;
    NSString *host = request.URL.host.lowercaseString;
    BOOL imgurHost = [host isEqualToString:@"imgur-apiv3.p.rapidapi.com"] || [host isEqualToString:@"api.imgur.com"];
    return imgurHost
        && [request.URL.path hasPrefix:@"/3/album"]
        && [(request.HTTPMethod ?: @"GET") caseInsensitiveCompare:@"POST"] == NSOrderedSame;
}

// Member tokens from Apollo's album-creation body (deletehashes=a,b,c or
// deletehashes[]=a&deletehashes[]=b, possibly percent-encoded).
static NSArray<NSString *> *ApolloImgChestAlbumTokensFromRequest(NSURLRequest *request) {
    NSData *body = request.HTTPBody;
    NSString *form = body.length > 0 ? [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] : nil;
    if (form.length == 0) return @[];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *pair in [form componentsSeparatedByString:@"&"]) {
        NSRange equals = [pair rangeOfString:@"="];
        if (equals.location == NSNotFound) continue;
        NSString *key = [pair substringToIndex:equals.location];
        if (![key hasPrefix:@"deletehashes"] && ![key hasPrefix:@"ids"]) continue;
        NSString *value = [[pair substringFromIndex:equals.location + 1] stringByRemovingPercentEncoding]
            ?: [pair substringFromIndex:equals.location + 1];
        for (NSString *token in [value componentsSeparatedByString:@","]) {
            NSString *trimmed = [token stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trimmed.length > 0 && ![tokens containsObject:trimmed]) [tokens addObject:trimmed];
        }
    }
    return tokens;
}

// Imgur-shaped image dictionary for a synthetic album response entry.
static NSDictionary *ApolloImgChestSyntheticImageDictionary(NSDictionary *imageEntry) {
    NSString *link = [imageEntry[@"link"] isKindOfClass:[NSString class]] ? imageEntry[@"link"] : @"";
    NSString *token = link.length > 0 ? [NSURL URLWithString:link].lastPathComponent : @"";
    return @{
        @"id": token ?: @"",
        @"deletehash": token ?: @"",
        @"title": [NSNull null],
        @"description": [NSNull null],
        @"datetime": @((NSInteger)[[NSDate date] timeIntervalSince1970]),
        @"type": @"image/jpeg",
        @"animated": @NO,
        @"width": @0,
        @"height": @0,
        @"size": @0,
        @"views": @0,
        @"bandwidth": @0,
        @"link": link,
        @"mp4": @"",
        @"hls": @"",
        @"has_sound": @NO,
    };
}

ApolloImgChestAlbumResponder ApolloImgChestAlbumCreationResponderForRequest(NSURLRequest *request) {
    if (!ApolloImgChestIsImgurAlbumCreationRequest(request)) return nil;
    if (!ApolloImgChestUploadAvailable()) return nil;

    NSArray<NSString *> *tokens = ApolloImgChestAlbumTokensFromRequest(request);
    if (tokens.count < 2) return nil;

    NSMutableArray<NSString *> *interimPosts = [NSMutableArray array];
    for (NSString *token in tokens) {
        NSDictionary *cached = ApolloImgChestCachePeek(token);
        NSURL *fileURL = [cached[@"fileURL"] isKindOfClass:[NSURL class]] ? cached[@"fileURL"] : nil;
        if (ApolloImgChestFileSize(fileURL).unsignedLongLongValue == 0) {
            // A member upload isn't ours / its file was already evicted — let the
            // request go to real Imgur rather than build a partial album.
            ApolloLog(@"[ImgChestUpload] album token %@ has no cached file; not combining", token);
            return nil;
        }
        NSString *postID = [cached[@"post"] isKindOfClass:[NSString class]] ? cached[@"post"] : nil;
        if (postID.length > 0) [interimPosts addObject:postID];
    }

    NSArray<NSString *> *tokensCopy = [tokens copy];
    return ^ApolloImgChestUploadOperation *(ApolloImgChestReply reply) {
        ApolloImgChestUploadOperation *operation = [ApolloImgChestUploadOperation new];
        __block NSArray<NSURL *> *snapshotFiles = @[];
        void (^postCompletion)(NSDictionary *, NSError *) = ^(NSDictionary *post, NSError *error) {
            for (NSURL *snapshotURL in snapshotFiles) {
                ApolloImgChestRemoveManagedFile(snapshotURL);
                [operation relinquishCleanupFile:snapshotURL];
            }
            snapshotFiles = @[];
            NSString *postID = [post[@"id"] isKindOfClass:[NSString class]] ? post[@"id"] : nil;
            NSString *postLink = [post[@"link"] isKindOfClass:[NSString class]] && [post[@"link"] length] > 0
                ? post[@"link"]
                : (postID ? [@"https://imgchest.com/p/" stringByAppendingString:postID] : nil);
            if (!postID || !postLink) {
                reply(nil, nil, error ?: ApolloImgChestError(@"Image Chest album creation failed"));
                return;
            }

            // The combined post supersedes the interim single-image posts:
            // delete them server-side and downgrade their registry entries to
            // acknowledged no-ops (their entries may linger in Apollo's list).
            for (NSString *interim in interimPosts) {
                ApolloImgChestDeletePost(interim, nil);
            }
            // The member tokens' old CDN links die with their interim posts;
            // point them at the combined post's images (same order) so their
            // Manage Uploads thumbnails keep working.
            NSArray *combinedImages = [post[@"images"] isKindOfClass:[NSArray class]] ? post[@"images"] : @[];
            for (NSUInteger i = 0; i < tokensCopy.count; i++) {
                NSString *newLink = i < combinedImages.count && [combinedImages[i] isKindOfClass:[NSDictionary class]]
                    ? ([combinedImages[i][@"link"] isKindOfClass:[NSString class]] ? combinedImages[i][@"link"] : @"")
                    : @"";
                ApolloUploadRegistrySet(tokensCopy[i], @{ @"provider": kProviderImgChestMerged, @"link": newLink });
            }
            ApolloImgChestCacheRemove(tokensCopy);
            ApolloUploadRegistrySet(postID, @{ @"provider": kProviderImgChest,
                                               @"post": postID,
                                               @"link": postLink ?: @"" });

            NSArray *responseImages = [post[@"images"] isKindOfClass:[NSArray class]] ? post[@"images"] : @[];
            NSMutableArray *imageDicts = [NSMutableArray arrayWithCapacity:responseImages.count];
            for (NSDictionary *entry in responseImages) {
                if ([entry isKindOfClass:[NSDictionary class]]) [imageDicts addObject:ApolloImgChestSyntheticImageDictionary(entry)];
            }

            NSDictionary *root = @{
                @"status": @200,
                @"success": @YES,
                @"data": @{
                    @"id": postID,
                    @"deletehash": postID,
                    @"title": [NSNull null],
                    @"description": [NSNull null],
                    @"datetime": @((NSInteger)[[NSDate date] timeIntervalSince1970]),
                    @"cover": [imageDicts.firstObject[@"id"] isKindOfClass:[NSString class]] ? imageDicts.firstObject[@"id"] : @"",
                    @"cover_width": @0,
                    @"cover_height": @0,
                    @"account_url": [NSNull null],
                    @"privacy": @"hidden",
                    @"layout": @"blog",
                    @"views": @0,
                    @"link": postLink,
                    @"favorite": @NO,
                    @"nsfw": [NSNull null],
                    @"section": [NSNull null],
                    @"images_count": @(imageDicts.count),
                    @"images": imageDicts,
                },
            };
            NSData *json = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
            NSHTTPURLResponse *fake = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                                  statusCode:200
                                                                 HTTPVersion:@"HTTP/1.1"
                                                                headerFields:@{@"Content-Type": @"application/json"}];
            ApolloLog(@"[ImgChestUpload] combined %lu uploads into album post=%@ link=%@",
                      (unsigned long)tokensCopy.count, postID, postLink);
            reply(json, fake, nil);
        };
        dispatch_async(ApolloImgChestMultipartQueue(), ^{
            if (operation.cancelled) {
                if ([operation finishOnce]) reply(nil, nil, ApolloImgChestCancelledError());
                return;
            }
            NSError *snapshotError = nil;
            NSArray<NSDictionary *> *parts = ApolloImgChestSnapshotCachedParts(tokensCopy, &snapshotFiles, &snapshotError);
            if (!parts) {
                if ([operation finishOnce]) reply(nil, nil, snapshotError ?: ApolloImgChestError(@"Could not snapshot album images"));
                return;
            }
            for (NSURL *snapshotURL in snapshotFiles) [operation addCleanupFile:snapshotURL];
            if (operation.cancelled) {
                if ([operation finishOnce]) reply(nil, nil, ApolloImgChestCancelledError());
                return;
            }
            ApolloImgChestCreatePost(parts, operation, postCompletion);
        });
        return operation;
    };
}

#pragma mark - Manage Uploads delete interception (issue #414)

// Deletehash from an Imgur delete request: DELETE /3/image/<hash> or
// /3/album/<hash> on an imgur API host.
static NSString *_Nullable ApolloImgurDeleteHashFromRequest(NSURLRequest *request) {
    if (![request isKindOfClass:[NSURLRequest class]]) return nil;
    if ([(request.HTTPMethod ?: @"GET") caseInsensitiveCompare:@"DELETE"] != NSOrderedSame) return nil;
    NSString *host = request.URL.host.lowercaseString;
    BOOL imgurHost = [host isEqualToString:@"imgur-apiv3.p.rapidapi.com"] || [host isEqualToString:@"api.imgur.com"];
    if (!imgurHost) return nil;
    NSArray<NSString *> *parts = request.URL.path.pathComponents;
    // ["/", "3", "image"|"album", "<hash>"]
    if (parts.count >= 4 && [parts[1] isEqualToString:@"3"] &&
        ([parts[2] isEqualToString:@"image"] || [parts[2] isEqualToString:@"album"])) {
        return parts[3].length > 0 ? parts[3] : nil;
    }
    return nil;
}

// Registry-loss fallback: even without a registry entry, Apollo's own
// uploads list (Documents/imgur-uploads.plist) tells us whether the hash
// belongs to an ImgChest-hosted upload. Without this, a lost registry
// (settings reset, restored device) sends the delete to Imgur's API, which
// fails and shows the user an Imgur-specific recovery alert that can't work.
static BOOL ApolloUploadsListHasImgChestEntryForHash(NSString *hash) {
    if (hash.length == 0) return NO;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/imgur-uploads.plist"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length == 0) return NO;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
    if (![plist isKindOfClass:[NSArray class]]) return NO;
    for (NSDictionary *entry in (NSArray *)plist) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        if (![hash isEqualToString:entry[@"deleteHash"]]) continue;
        id urlValue = entry[@"url"];
        NSString *urlString = [urlValue isKindOfClass:[NSDictionary class]] ? urlValue[@"relative"]
                            : ([urlValue isKindOfClass:[NSString class]] ? urlValue : nil);
        NSURL *url = [urlString isKindOfClass:[NSString class]] ? [NSURL URLWithString:urlString] : nil;
        return ApolloImgChestIsImgChestHostURL(url);
    }
    return NO;
}

BOOL ApolloUploadRegistryShouldInterceptDelete(NSURLRequest *request) {
    NSString *hash = ApolloImgurDeleteHashFromRequest(request);
    if (hash.length == 0) return NO;
    return ApolloUploadRegistryEntry(hash) != nil || ApolloUploadsListHasImgChestEntryForHash(hash);
}

static NSData *ApolloSyntheticImgurDeleteSuccessData(void) {
    return [NSJSONSerialization dataWithJSONObject:@{ @"status": @200, @"success": @YES, @"data": @YES }
                                           options:0
                                             error:nil];
}

void ApolloUploadRegistryHandleImgurDelete(NSURLRequest *request, ApolloImgChestReply reply) {
    NSString *hash = ApolloImgurDeleteHashFromRequest(request);
    NSDictionary *entry = hash.length > 0 ? ApolloUploadRegistryEntry(hash) : nil;
    NSString *provider = [entry[@"provider"] isKindOfClass:[NSString class]] ? entry[@"provider"] : @"";
    NSString *postID = [entry[@"post"] isKindOfClass:[NSString class]] ? entry[@"post"] : nil;

    NSHTTPURLResponse *ok = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                        statusCode:200
                                                       HTTPVersion:@"HTTP/1.1"
                                                      headerFields:@{@"Content-Type": @"application/json"}];
    void (^acknowledge)(void) = ^{
        ApolloImgChestCacheRemove(hash.length > 0 ? @[hash] : @[]);
        ApolloUploadRegistrySet(hash, nil);
        reply(ApolloSyntheticImgurDeleteSuccessData(), ok, nil);
    };

    if ([provider isEqualToString:kProviderImgChest] && postID.length > 0) {
        ApolloImgChestDeletePost(postID, ^(BOOL success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                ApolloLog(@"[ImgChestUpload] Manage Uploads delete hash=%@ post=%@ serverDelete=%@", hash, postID, success ? @"ok" : @"failed");
                // Even if the server delete failed (already gone, revoked
                // token), acknowledge so the entry leaves Apollo's list.
                acknowledge();
            });
        });
        return;
    }

    // Reddit uploads can't be deleted server-side; merged interim ImgChest
    // entries no longer exist; ImgChest entries with no registry mapping
    // (lost settings) can't be resolved to a post. Acknowledge so the list
    // entry goes away.
    ApolloLog(@"[ImgChestUpload] Manage Uploads delete hash=%@ provider=%@ acknowledged (list removal only)",
              hash, provider.length > 0 ? provider : @"imgchest-without-registry");
    acknowledge();
}
