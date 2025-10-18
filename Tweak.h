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
@end

@interface ASImageNode : NSObject
+ (UIImage *)createContentsForkey:(id)key drawParameters:(id)parameters isCancelled:(id)cancelled;
@end

@class _TtC6Apollo14LinkButtonNode;
