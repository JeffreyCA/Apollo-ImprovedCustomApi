#import <UIKit/UIKit.h>
#import "ApolloSaveAllMediaItems.h"

NS_ASSUME_NONNULL_BEGIN

__BEGIN_DECLS

// Save a fully resolved, ordered snapshot of the post's original media to
// Photos. Call after the invoking menu has dismissed, with its owning visible
// controller. The array is copied; navigation cannot change the running job.
//
// The job requests add-only access before starting any downloads and saves one
// item at a time. Images retain their original bytes (including GIF/APNG
// animation); videos use the existing Gallery export/audio-mux path. Progress
// offers cancellation: active image downloads stop immediately, while a Photos
// write or video export already in progress finishes before the job stops.
// Only one batch can run at a time. Results report the actual Photos successes.
void ApolloSaveAllMedia(NSArray<ApolloSaveAllMediaItem *> *items,
                        UIViewController *presenter);

__END_DECLS

NS_ASSUME_NONNULL_END
