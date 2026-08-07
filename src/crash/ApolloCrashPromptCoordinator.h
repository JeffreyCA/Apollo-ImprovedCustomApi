#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Presents the once-per-report "Apollo encountered a problem" prompt after a
// crash, once Apollo's normal interface is up. "Not Now" marks the report as
// prompted (it stays reachable under Settings → Apollo Reborn → Crash
// Reports) — a persistently crashing build must never nag on every launch;
// only a NEW report ID prompts again.
@interface ApolloCrashPromptCoordinator : NSObject

@property (class, nonatomic, readonly) ApolloCrashPromptCoordinator *sharedCoordinator;

// Call once from %ctor (after the crash recorder installs). No-op when the
// recorder isn't installed.
- (void)start;

@end

NS_ASSUME_NONNULL_END
