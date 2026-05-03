#import <Foundation/Foundation.h>

@interface ShareUrlTask : NSObject

@property (atomic, strong) dispatch_group_t dispatchGroup;
@property (atomic, strong) NSString *resolvedURL;
@end

@interface RDKClient : NSObject
+ (instancetype)sharedClient;
- (id)currentUser;
- (void)thingsByFullNames:(NSArray *)fullNames completion:(void(^)(NSArray *, NSError *))completion;
@end

@class RDKLinkPreviewMedia;

@interface RDKLink
@property(copy, nonatomic) NSString *fullName;
@property(copy, nonatomic) NSString *title;
@property(copy, nonatomic) NSString *author;
@property(copy, nonatomic) NSString *subreddit;
@property(copy, nonatomic) NSString *permalink;
@property(copy, nonatomic) NSString *selfText;
@property(copy, nonatomic) NSString *selfTextHTML;
@property(copy, nonatomic) NSURL *URL;
@property(nonatomic) NSInteger score;
@property(nonatomic) NSInteger totalComments;
@property(nonatomic, strong) NSDate *createdUTC;
@property(nonatomic, getter=isNSFW) BOOL NSFW;
@property(nonatomic, getter=isSpoiler) BOOL spoiler;
@property(nonatomic, getter=isSelfPost) BOOL selfPost;
@property(retain, nonatomic) NSDictionary *mediaMetadata;
@property(retain, nonatomic) RDKLinkPreviewMedia *previewMedia;
@end

@interface RDKComment
{
    NSDate *_createdUTC;
    NSString *_linkID;
}
- (id)linkIDWithoutTypePrefix;
@property(copy, nonatomic) NSString *body;
@property(copy, nonatomic) NSString *bodyHTML;
@property(readonly, nonatomic) NSDictionary *mediaMetadata;
@property(copy, nonatomic) NSString *author;
@property(nonatomic) BOOL stickied;
@property(nonatomic) BOOL collapsed;
@end

@interface RDKLinkPreviewItem : NSObject
@property(copy, nonatomic) NSURL *URL;
@property(nonatomic) double width;
@property(nonatomic) double height;
@end

@interface RDKLinkPreviewMedia : NSObject
@property(retain, nonatomic) NSArray *images;
@property(retain, nonatomic) RDKLinkPreviewItem *sourceImage;
@end

@interface RDKModmailMessage : NSObject
@property(copy, nonatomic) NSString *bodyHTML;
@end

@interface ASImageNode : NSObject
+ (UIImage *)createContentsForkey:(id)key drawParameters:(id)parameters isCancelled:(id)cancelled;
@end

// FLAnimatedImage - GIF data model
@interface FLAnimatedImage : NSObject
@property (nonatomic, readonly) NSDictionary *delayTimesForIndexes;
@property (nonatomic, readonly) NSUInteger frameCount;
@property (nonatomic, readonly) NSUInteger loopCount;
- (UIImage *)imageLazilyCachedAtIndex:(NSUInteger)index;
@end

// FLAnimatedImageView - Fix for 120Hz ProMotion displays
@interface FLAnimatedImageView : UIImageView
- (void)displayDidRefresh:(CADisplayLink *)displayLink;
- (void)stopAnimating;
@end

@class _TtC6Apollo14LinkButtonNode;
