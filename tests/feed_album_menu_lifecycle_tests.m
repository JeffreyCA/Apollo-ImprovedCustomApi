#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

// Host-side doubles only for UIKit's action storage and the window-presence
// check. Selection ownership, deferral and dismissal completion below are
// extracted verbatim from the shipping module by the runner.
@interface UIView : NSObject
@property (nonatomic, strong) id window;
@end
@implementation UIView
@end
@interface UIViewController : NSObject
@property (nonatomic, strong) UIView *viewIfLoaded;
@end
@implementation UIViewController
@end
@interface UIImage : NSObject
+ (instancetype)systemImageNamed:(NSString *)name;
@end
@implementation UIImage
+ (instancetype)systemImageNamed:(__unused NSString *)name { return nil; }
@end
@interface UIAction : NSObject
@property (nonatomic, copy) void (^handler)(UIAction *);
+ (instancetype)actionWithTitle:(NSString *)title image:(UIImage *)image identifier:(id)identifier handler:(void (^)(UIAction *))handler;
@end
@implementation UIAction
+ (instancetype)actionWithTitle:(__unused NSString *)title image:(__unused UIImage *)image identifier:(__unused id)identifier handler:(void (^)(UIAction *))handler {
    UIAction *action = [self new];
    action.handler = handler;
    return action;
}
@end

@class ApolloSaveAllMediaItem, ApolloFeedGalleryCarouselView;
@protocol UIContextMenuInteractionAnimating
- (void)addCompletion:(dispatch_block_t)completion;
@end
@interface QAAnimator : NSObject <UIContextMenuInteractionAnimating>
@property (nonatomic, copy) dispatch_block_t completion;
- (void)complete;
@end
@implementation QAAnimator
- (void)addCompletion:(dispatch_block_t)completion { self.completion = completion; }
- (void)complete {
    dispatch_block_t completion = self.completion;
    self.completion = nil;
    if (completion) completion();
}
@end

#import "FeedAlbumMenuLifecycle.inc"

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static void DrainMainQueue(void) {
    __block BOOL drained = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ drained = YES; });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
    while (!drained && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
    }
    Check(drained, @"main-queue work completed");
}

// +1 prevents a host-side autorelease from accidentally keeping the selection
// alive after the simulated configuration releases it (masking the regression).
static ApolloFeedAlbumMenuContext *Context(UIViewController *owner) NS_RETURNS_RETAINED;
static ApolloFeedAlbumMenuContext *Context(UIViewController *owner) {
    ApolloFeedAlbumMenuContext *context = [ApolloFeedAlbumMenuContext new];
    context.presenter = owner;
    context.index = 4;
    return context;
}

int main(void) {
    @autoreleasepool {
        UIViewController *owner = [UIViewController new];
        owner.viewIfLoaded = [UIView new];
        owner.viewIfLoaded.window = [NSObject new];

        // UIKit can release configuration first and invoke a surviving action
        // later. This failed with the original weak-only UIAction handler.
        __weak ApolloFeedAlbumMenuContext *releasedContext;
        __block NSUInteger calls = 0;
        @autoreleasepool {
            ApolloFeedAlbumMenuContext *context = Context(owner);
            releasedContext = context;
            context.ended = YES;
            __weak ApolloFeedAlbumMenuContext *selection = context;
            UIAction *action = ApolloFeedAlbumAction(@"Save Image", @"save", context, ^{
                Check(selection.index == 4, @"late action retains its captured fifth image");
                calls++;
            });
            context = nil; // configuration's final reference disappears
            Check(releasedContext != nil, @"UIAction owns selection after configuration teardown");
            action.handler(action);
            action = nil;
            Check(calls == 0, @"late action waits for the next main-queue turn");
            Check(releasedContext != nil, @"queued action owns selection after UIAction teardown");
            DrainMainQueue();
            Check(calls == 1, @"late selection executes once");
        }
        Check(releasedContext == nil, @"late action releases selection after execution");

        calls = 0;
        @autoreleasepool {
            ApolloFeedAlbumMenuContext *context = Context(owner);
            releasedContext = context;
            __weak ApolloFeedAlbumMenuContext *selection = context;
            UIAction *action = ApolloFeedAlbumAction(@"Copy Image", @"copy", context, ^{
                Check(selection.index == 4 && selection.pendingAction == nil,
                      @"dismissal clears the pending action before invoking captured selection");
                calls++;
            });
            action.handler(action);
            Check(calls == 0 && context.pendingAction != nil, @"early action waits for menu dismissal");
            action = nil;
            QAAnimator *animator = [QAAnimator new];
            QAEndMenu(context, animator);
            context = nil;
            Check(releasedContext != nil, @"dismissal animator owns the pending selection");
            [animator complete];
            Check(calls == 1, @"early selection executes once after animation");
        }
        Check(releasedContext == nil, @"completed animator and pending action do not retain selection");

        calls = 0;
        @autoreleasepool {
            ApolloFeedAlbumMenuContext *context = Context(owner);
            releasedContext = context;
            UIAction *action = ApolloFeedAlbumAction(@"Save All Media", @"save", context, ^{ calls++; });
            QAEndMenu(context, nil);
            context = nil;
            DrainMainQueue();
            action.handler(action);
            action = nil;
            DrainMainQueue();
            Check(calls == 1, @"no-animator end followed by late selection executes once");
        }
        Check(releasedContext == nil, @"no-animator path releases selection");

        @autoreleasepool {
            ApolloFeedAlbumMenuContext *context = Context(owner);
            releasedContext = context;
            QAAnimator *animator = [QAAnimator new];
            QAEndMenu(context, animator);
            context = nil;
            [animator complete];
        }
        Check(releasedContext == nil, @"dismissal without selection has no retained context");
    }
    printf("feed_album_menu_lifecycle_tests: all %lu checks passed\n", (unsigned long)checks);
    return 0;
}
