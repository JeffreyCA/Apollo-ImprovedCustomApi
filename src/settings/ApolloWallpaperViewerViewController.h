#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ApolloWallpaperItem : NSObject

+ (instancetype)itemWithURLString:(NSString *)URLString caption:(NSString *)caption;

@property (nonatomic, copy, readonly) NSURL *URL;
@property (nonatomic, copy, readonly) NSString *caption;

@end

// Apollo-style, full-screen wallpaper pager. Images remain remotely hosted;
// only the current page (and UIKit's ordinary URL cache) is loaded on demand.
@interface ApolloWallpaperViewerViewController : UIViewController

- (instancetype)initWithItems:(NSArray<ApolloWallpaperItem *> *)items;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
