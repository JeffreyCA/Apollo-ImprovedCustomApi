#import <Foundation/Foundation.h>

@interface ShareUrlTask : NSObject

@property (atomic, strong) dispatch_group_t dispatchGroup;
@property (atomic, strong) NSString *resolvedURL;
@end

@interface RDKLink
@property(copy, nonatomic) NSURL *URL;
@end

@interface RDKComment
{
    NSDate *_createdUTC;
    NSString *_linkID;
}
- (id)linkIDWithoutTypePrefix;
@property(copy, nonatomic) NSString *body;
@property(readonly, nonatomic) NSDictionary *mediaMetadata;
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
