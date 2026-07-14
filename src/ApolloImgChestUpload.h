#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
__BEGIN_DECLS

typedef void (^ApolloImgChestReply)(NSData *_Nullable data, NSURLResponse *_Nullable response, NSError *_Nullable error);

/// YES when an ImgChest API token is configured — uploads require it.
BOOL ApolloImgChestUploadAvailable(void);

/// Upload one image to ImgChest as a new hidden single-image post.
/// On success, completion gets the file's direct CDN link. The upload is
/// recorded in the registry (token = link's last path component, the same
/// value the synthetic Imgur response uses as id/deletehash) and the bytes
/// are cached briefly so a following Imgur album-creation request can
/// combine the images into one multi-image ImgChest post.
void ApolloImgChestUploadData(NSData *data,
                              NSString *filename,
                              NSString *mimeType,
                              void (^completion)(NSURL *_Nullable directLink, NSError *_Nullable error));

/// Map a CDN image link this tweak just uploaded (cdn.imgchest.com/files/<id>.<ext>) to its short
/// ImgChest post URL (imgchest.com/p/<post>), via the upload registry. nil if not one of our uploads.
/// Used by the chat send path to send the short post link instead of the long CDN file URL.
NSURL *_Nullable ApolloImgChestPostURLForUploadedLink(NSURL *cdnLink);

/// When `albumID` is the id of a multi-image ImgChest album post this tweak created (issue #552),
/// returns its real post URL (imgchest.com/p/<id>); nil otherwise. The synthetic Imgur album
/// response we hand Apollo carries this id, and Apollo's createAlbum then rebuilds the submit link
/// as imgur.com/a/<id> — keeping our ImgChest post id but swapping the host to imgur.com, which
/// posts a dead Imgur album. The submit path uses this to rewrite that url back to ImgChest.
NSURL *_Nullable ApolloImgChestPostURLForAlbumID(NSString *albumID);

/// When `request` is an Imgur album-creation request whose member tokens are
/// all cached ImgChest uploads, returns a block that asynchronously creates
/// the combined ImgChest post and replies with a synthetic Imgur album
/// response (link = imgchest.com/p/<post>). Returns nil when not applicable.
typedef void (^ApolloImgChestAlbumResponder)(ApolloImgChestReply reply);
ApolloImgChestAlbumResponder _Nullable ApolloImgChestAlbumCreationResponderForRequest(NSURLRequest *request);

/// Manage Uploads (issue #414): YES when `request` is an Imgur delete whose
/// deletehash belongs to an upload recorded by this tweak (any provider).
BOOL ApolloUploadRegistryShouldInterceptDelete(NSURLRequest *request);

/// Handle an intercepted delete: ImgChest uploads are deleted server-side
/// via the ImgChest API; Reddit uploads (no delete API) are acknowledged so
/// Apollo removes the entry from its list. Always replies.
void ApolloUploadRegistryHandleImgurDelete(NSURLRequest *request, ApolloImgChestReply reply);

/// Record a Reddit-hosted upload so its Manage Uploads delete can be
/// acknowledged and its thumbnail resolved. Called from the Reddit upload
/// synthesis path with the final media URL (i.redd.it/...).
void ApolloUploadRegistryRecordRedditUpload(NSURL *_Nullable mediaURL);

/// ImgChest's CDN returns 403 to requests without a User-Agent (e.g. the
/// Manage Uploads thumbnail loader sends none). When `request` targets an
/// imgchest host and carries no User-Agent, returns a copy with one added;
/// otherwise nil (caller should proceed unchanged).
NSURLRequest *_Nullable ApolloImgChestRequestByAddingUserAgentIfNeeded(NSURLRequest *_Nullable request);

/// YES for an imgchest host (the post site or its CDN).
BOOL ApolloImgChestIsImgChestHostURL(NSURL *_Nullable url);

__END_DECLS
NS_ASSUME_NONNULL_END
