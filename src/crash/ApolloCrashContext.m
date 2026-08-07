#import "crash/ApolloCrashContext.h"

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#import "ApolloCommon.h"
#import "crash/ApolloCrashManager.h"

// 20 events is enough to show the shape of the session leading into a crash
// without becoming a browsing history. (enum, not static const: it sizes a
// file-scope array, which needs a true constant expression in C.)
enum { kApolloCrashContextCapacity = 20 };
// Publishing rewrites KSCrash's userInfo (a JSON re-encode); debounce so a
// burst of navigation doesn't re-serialize per event.
static const NSTimeInterval kApolloCrashContextPublishDebounce = 2.0;

typedef struct {
    ApolloCrashEvent event;
    CFTimeInterval timestamp; // CACurrentMediaTime() at record
} ApolloCrashContextEntry;

static NSString *ApolloCrashEventName(ApolloCrashEvent event) {
    switch (event) {
        case ApolloCrashEventAppBecameActive:      return @"app_became_active";
        case ApolloCrashEventAppResignedActive:    return @"app_resigned_active";
        case ApolloCrashEventAppEnteredBackground: return @"app_entered_background";
        case ApolloCrashEventMemoryWarning:        return @"memory_warning";
        case ApolloCrashEventOpenedFeed:           return @"opened_feed";
        case ApolloCrashEventOpenedPost:           return @"opened_post";
        case ApolloCrashEventOpenedComments:       return @"opened_comments";
        case ApolloCrashEventOpenedGallery:        return @"opened_gallery";
        case ApolloCrashEventOpenedMediaViewer:    return @"opened_media_viewer";
        case ApolloCrashEventStartedVideo:         return @"started_video";
        case ApolloCrashEventOpenedProfile:        return @"opened_profile";
        case ApolloCrashEventOpenedSettings:       return @"opened_settings";
        case ApolloCrashEventOpenedComposer:       return @"opened_composer";
        case ApolloCrashEventPresentedShareSheet:  return @"presented_share_sheet";
        case ApolloCrashEventChangedCommentSort:   return @"changed_comment_sort";
    }
    return @"unknown";
}

// All state is confined to this serial queue.
static dispatch_queue_t sContextQueue;
static ApolloCrashContextEntry sEntries[kApolloCrashContextCapacity];
static NSUInteger sEntryCount;
static NSUInteger sEntryHead; // next write slot
static BOOL sStarted;
static BOOL sPublishScheduled;

@implementation ApolloCrashContext

+ (void)start {
    if (!ApolloCrashManager.sharedManager.installed) return;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sContextQueue = dispatch_queue_create("com.apolloreborn.crashcontext", DISPATCH_QUEUE_SERIAL);
        sStarted = YES;

        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        struct { NSNotificationName name; ApolloCrashEvent event; } observed[] = {
            { UIApplicationDidBecomeActiveNotification, ApolloCrashEventAppBecameActive },
            { UIApplicationWillResignActiveNotification, ApolloCrashEventAppResignedActive },
            { UIApplicationDidEnterBackgroundNotification, ApolloCrashEventAppEnteredBackground },
            { UIApplicationDidReceiveMemoryWarningNotification, ApolloCrashEventMemoryWarning },
        };
        for (size_t i = 0; i < sizeof(observed) / sizeof(observed[0]); i++) {
            ApolloCrashEvent event = observed[i].event;
            [center addObserverForName:observed[i].name
                                object:nil
                                 queue:nil
                            usingBlock:^(__unused NSNotification *note) {
                [ApolloCrashContext recordEvent:event];
            }];
        }
        [ApolloCrashManager.sharedManager publishUserInfoWithRecentActions:@[]];
    });
}

+ (void)recordEvent:(ApolloCrashEvent)event {
    if (!sStarted) return;
    CFTimeInterval now = CACurrentMediaTime();
    dispatch_async(sContextQueue, ^{
        sEntries[sEntryHead] = (ApolloCrashContextEntry){ .event = event, .timestamp = now };
        sEntryHead = (sEntryHead + 1) % kApolloCrashContextCapacity;
        if (sEntryCount < kApolloCrashContextCapacity) sEntryCount++;

        if (sPublishScheduled) return;
        sPublishScheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloCrashContextPublishDebounce * NSEC_PER_SEC)),
                       sContextQueue, ^{
            sPublishScheduled = NO;
            [self publishLocked];
        });
    });
}

// Serialize oldest-first with ages relative to the snapshot moment. The crash
// necessarily happens after the last publish, so "age_seconds" reads as
// "at least this long before the crash" — deliberately coarse (whole seconds).
+ (void)publishLocked {
    CFTimeInterval now = CACurrentMediaTime();
    NSMutableArray<NSDictionary *> *actions = [NSMutableArray arrayWithCapacity:sEntryCount];
    for (NSUInteger i = 0; i < sEntryCount; i++) {
        NSUInteger idx = (sEntryHead + kApolloCrashContextCapacity - sEntryCount + i) % kApolloCrashContextCapacity;
        [actions addObject:@{
            @"event": ApolloCrashEventName(sEntries[idx].event),
            @"age_seconds": @((NSInteger)(now - sEntries[idx].timestamp)),
        }];
    }
    [ApolloCrashManager.sharedManager publishUserInfoWithRecentActions:actions];
}

@end

void ApolloCrashContextRecordEvent(ApolloCrashEvent event) {
    [ApolloCrashContext recordEvent:event];
}
