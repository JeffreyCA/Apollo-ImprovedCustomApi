#import <Foundation/Foundation.h>

// Privacy-safe local crash context: a small in-memory ring buffer of coarse,
// ENUMERATED app actions ("opened_post", "started_video") that is published
// into KSCrash's userInfo so a crash report can say what broad activity
// preceded it. This is not an analytics stream: it exists only in memory and
// in the local crash report, carries no arguments (no subreddit names, no
// URLs, no titles — the API physically cannot accept a string), and leaves
// the device only inside a report the user has reviewed and submitted.
typedef NS_ENUM(NSInteger, ApolloCrashEvent) {
    ApolloCrashEventAppBecameActive,
    ApolloCrashEventAppResignedActive,
    ApolloCrashEventAppEnteredBackground,
    ApolloCrashEventMemoryWarning,
    ApolloCrashEventOpenedFeed,
    ApolloCrashEventOpenedPost,
    ApolloCrashEventOpenedComments,
    ApolloCrashEventOpenedGallery,
    ApolloCrashEventOpenedMediaViewer,
    ApolloCrashEventStartedVideo,
    ApolloCrashEventOpenedProfile,
    ApolloCrashEventOpenedSettings,
    ApolloCrashEventOpenedComposer,
    ApolloCrashEventPresentedShareSheet,
    ApolloCrashEventChangedCommentSort,
};

NS_ASSUME_NONNULL_BEGIN

@interface ApolloCrashContext : NSObject

// Begin observing app-lifecycle notifications and publish the initial
// context. Call once from %ctor, after the crash recorder installs. No-op
// when the recorder is not installed.
+ (void)start;

// Record one enumerated event. Safe from any thread; cheap (ring buffer
// write + debounced userInfo publish). No-op before +start.
+ (void)recordEvent:(ApolloCrashEvent)event;

@end

// C entry point for .xm hook sites that don't want the header's ObjC surface.
__BEGIN_DECLS
void ApolloCrashContextRecordEvent(ApolloCrashEvent event);
__END_DECLS

NS_ASSUME_NONNULL_END
