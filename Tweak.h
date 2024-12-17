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

@class _TtC6Apollo14LinkButtonNode;
