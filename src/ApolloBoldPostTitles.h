//
//  ApolloBoldPostTitles.h
//  Apollo-Reborn
//
//  "Bold Post Titles" (Appearance > Posts): feed post titles in Semibold
//  instead of Apollo's Regular. See ApolloBoldPostTitles.xm.
//

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Flip the setting: updates the in-memory flag + NSUserDefaults and asks every
// live feed to re-render through Apollo's own post-cell-appearance reload, so
// the change is visible without a relaunch. Main thread.
void ApolloBoldPostTitlesSetEnabled(BOOL enabled);

#ifdef __cplusplus
}
#endif
