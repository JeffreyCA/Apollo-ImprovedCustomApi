#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import "ApolloSaveAllMediaItems.h"
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
@interface UIMenuElement : NSObject
@property (nonatomic, copy) NSString *title;
@end
@implementation UIMenuElement
@end
@interface UIMenu : UIMenuElement
@property (nonatomic, copy) NSArray *children;
- (instancetype)menuByReplacingChildren:(NSArray *)children;
@end
@implementation UIMenu
- (instancetype)menuByReplacingChildren:(NSArray *)children { UIMenu *menu=[UIMenu new];menu.children=children;return menu; }
@end
@interface UIAction : UIMenuElement
@property (nonatomic, strong) id image;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic) NSUInteger attributes;
@property (nonatomic, copy) void (^handler)(UIAction *);
+ (instancetype)actionWithTitle:(NSString *)title image:(id)image identifier:(NSString *)identifier handler:(void (^)(UIAction *))handler;
@end
@implementation UIAction
+ (instancetype)actionWithTitle:(NSString *)title image:(id)image identifier:(NSString *)identifier handler:(void (^)(UIAction *))handler {
 UIAction *action=[UIAction new];action.title=title;action.image=image;action.identifier=identifier;action.handler=handler;return action;
}
@end
@protocol UIContextMenuInteractionAnimating
- (void)addCompletion:(dispatch_block_t)completion;
@end
@interface QAAnimator : NSObject <UIContextMenuInteractionAnimating>
@property (nonatomic, copy) dispatch_block_t completion;
@end
@implementation QAAnimator
- (void)addCompletion:(dispatch_block_t)completion { self.completion=completion; }
@end
static NSUInteger saves;
static NSArray *savedItems;
static void ApolloSaveAllMedia(NSArray *items, __unused UIViewController *presenter) { saves++;savedItems=items; }
#define ApolloLog(...) ((void)0)
static id ApolloMediaActionGet(id object, NSString *name) { return [object isKindOfClass:NSDictionary.class] ? object[name] : nil; }
#import "InlineVideo.inc"
static NSUInteger checks;
static void Check(BOOL good, NSString *why) { checks++;if(!good){NSLog(@"FAIL: %@",why);exit(1);} }
static void Drain(void) {
 __block BOOL done=NO;dispatch_async(dispatch_get_main_queue(),^{done=YES;});
 NSDate *end=[NSDate dateWithTimeIntervalSinceNow:2];
 while(!done && end.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
 Check(done,@"queued action completes");
}
int main(void) { @autoreleasepool {
 NSURL *url=[NSURL URLWithString:@"https://v.redd.it/fixture/CMAF_480.mp4"];
 Check([ApolloInlineVideoPreviewURL(@{@"previewVideo":@{@"fallbackURL":url}}) isEqual:url],@"uses API preview MP4");
 for(NSString *bad in @[@"http://v.redd.it/id/file.mp4",@"https://v.redd.it.evil.test/id/file.mp4",@"https://v.redd.it/id/HLSPlaylist.m3u8",@"https://redgifs.com/watch/example"]) {
  Check(!ApolloInlineVideoPreviewURL(@{@"previewVideo":@{@"fallbackURL":[NSURL URLWithString:bad]}}),@"rejects unsuitable preview");
 }
 Check(!ApolloInlineVideoPreviewURL(@{}),@"missing preview keeps native route");
 UIViewController *owner=[UIViewController new];owner.viewIfLoaded=[UIView new];owner.viewIfLoaded.window=[NSObject new];
 UIAction *download=[UIAction actionWithTitle:@"Download Video…" image:nil identifier:@"download" handler:^(__unused UIAction *a){abort();}];
 UIAction *share=[UIAction actionWithTitle:@"Share" image:nil identifier:@"share" handler:nil];
 UIMenu *nested=[UIMenu new];nested.children=@[download];UIMenu *menu=[UIMenu new];menu.children=@[share,nested];
 for(NSUInteger ordering=0;ordering<3;ordering++) {
  __weak ApolloInlineVideoActionContext *weak;
  @autoreleasepool {
   ApolloInlineVideoActionContext *context=[ApolloInlineVideoActionContext new];context.presenter=owner;
   context.item=[[ApolloSaveAllMediaItem alloc] initWithURL:url isVideo:YES];
   weak=context;
   UIMenu *fixed=ApolloInlineVideoReplaceDownload(menu,context);
   Check(fixed.children.firstObject==share,@"preserves other action objects");
   UIAction *action=[(UIMenu *)fixed.children.lastObject children].firstObject;
   Check([action.title isEqual:download.title],@"preserves Download Video wording");
   QAAnimator *animator=[QAAnimator new];NSUInteger before=saves;
   if(ordering==0){action.handler(action);QAEndMenu(context,animator);}
   if(ordering==1){QAEndMenu(context,animator);action.handler(action);}
   if(ordering==2){QAEndMenu(context,animator);animator.completion();animator.completion=nil;action.handler(action);}
   action.handler(action); // duplicate dispatch must not duplicate the save
   context=nil;
   if(ordering<2){Check(saves==before,@"waits until dismissal ends");animator.completion();animator.completion=nil;}
   fixed=nil;action=nil;Drain();
   Check(saves==before+1,@"selection saved exactly once for either callback order");
   Check([((ApolloSaveAllMediaItem *)savedItems.firstObject).URL isEqual:url],@"saved original captured source");
  }
  Check(weak==nil,@"releases menu context after save handoff");
 }
 ApolloInlineVideoActionContext *cancel=[ApolloInlineVideoActionContext new];cancel.presenter=owner;
 NSUInteger before=saves;QAEndMenu(cancel,nil);Drain();Check(saves==before,@"cancel never saves");
 NSLog(@"PASS: %lu inline video source/menu checks",(unsigned long)checks);
} }
