#import <Foundation/Foundation.h>

#define UIColorFromRGB(rgbValue) [UIColor colorWithRed:((float)((rgbValue & 0xFF0000) >> 16))/255.0 green:((float)((rgbValue & 0xFF00) >> 8))/255.0 blue:((float)(rgbValue & 0xFF))/255.0 alpha:1.0]

@interface ShareUrlTask : NSObject

@property (nonatomic) dispatch_group_t dispatchGroup;
@property (nonatomic, strong) NSString *resolvedURL;

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
