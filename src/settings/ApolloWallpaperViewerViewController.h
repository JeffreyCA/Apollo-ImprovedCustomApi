#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ApolloWallpaperItem : NSObject

+ (instancetype)itemWithURLString:(NSString *)URLString caption:(NSString *)caption;

@property (nonatomic, copy, readonly) NSURL *URL;
@property (nonatomic, copy, readonly) NSString *caption;

@end

// Apollo-style, full-screen wallpaper pager. Images remain remotely hosted;
// opening pages can be warmed before presentation and nearby pages are loaded
// into a bounded shared cache as the user browses.
@interface ApolloWallpaperViewerViewController : UIViewController

+ (void)preloadFirstItemFromItems:(NSArray<ApolloWallpaperItem *> *)items;

- (instancetype)initWithItems:(NSArray<ApolloWallpaperItem *> *)items;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
