#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

// =============================================================================
// MARK: - Overview
// =============================================================================
//
// "Unmute Videos in Comments" — controls header video mute behavior.
//   Default (0):                    Native behavior (always muted).
//   Remember from Full Screen (1):  After fullscreen dismiss, match the
//                                   mute state the user had in fullscreen.
//   Always (2):                     Auto-unmute on comments entry +
//                                   always re-unmute after fullscreen.
//
// Architecture:
//   1. Hook RichMediaHeaderCellNode.cellNodeVisibilityEvent: — fires when the
//      comments header video cell becomes visible in the scroll view. This is
//      event-driven (no polling/delays) and the player is guaranteed to exist.
//   2. Get the AVPlayer via [[videoNode playerLayer] player] — the native code
//      (sub_10058b800) uses this exact path. For shareable v.redd.it videos,
//      the player lives on the AVPlayerLayer, NOT on [videoNode player].
//   3. Hook AVAudioSession to block Apollo's reversion to Ambient category.
//   4. Hook AVPlayer.setMuted: to detect user manual mute.
//
// =============================================================================

// =============================================================================
// MARK: - State Variables
// =============================================================================

// Per-cell flag: prevents re-unmuting on subsequent visibility events or when
// returning from MediaViewerController. Set on the RichMediaHeaderCellNode
// instance via objc_setAssociatedObject.
static const void *kAutoUnmuteAppliedKey = &kAutoUnmuteAppliedKey;

// The AVPlayer we auto-unmuted. Used by AVAudioSession hooks to block
// reversion to Ambient. __weak so it auto-nils when player deallocates
// (e.g. when leaving the CommentsViewController).
static __weak AVPlayer *sAutoUnmutedPlayer = nil;

// Guard: YES only during our programmatic unmute. Lets the AVPlayer.setMuted:
// hook distinguish our unmute from user tapping the mute button.
static BOOL sIsAutoUnmuting = NO;

// Flag: YES when CommentsVC is being popped (back navigation via swipe or
// back button). Prevents the cellNodeVisibilityEvent event=2 handler from
// clearing sAutoUnmutedPlayer during the back transition animation.
// Without this, the mute dance (triggered by TouchHintVideoNode.didExitVisibleState
// → sub_10058cb30) would re-mute the player because our AVPlayer/AVAudioSession
// hooks only block muting when sAutoUnmutedPlayer is set.
static BOOL sIsNavigatingBack = NO;

// Saved references from the comments header video cell. Used for re-unmute
// after returning from fullscreen MediaViewer. Set in cellNodeVisibilityEvent:
// which fires before the user can open fullscreen, so always available.
static __weak id sCommentsRichMediaNode = nil;
static __weak id sCommentsVideoNode = nil;

// Tracks which CommentsVC instance owns the saved refs above. When navigating
// CommentsVC #1 → CommentsVC #2 (via tapping a link), CommentsVC #2's
// cellNodeVisibilityEvent saves refs BEFORE CommentsVC #1's viewDidDisappear
// fires. Without this guard, CommentsVC #1's viewDidDisappear would clear
// refs that belong to CommentsVC #2, breaking re-unmute after fullscreen.
static __weak id sCommentsVCOwner = nil;

// =============================================================================
// MARK: - Helpers
// =============================================================================

static AVPlayer *GetPlayerFromVideoNode(id videoNode);
static void SyncMuteButtonIcon(id richMediaNode, BOOL isMuted);

// Safely read an ObjC object ivar by name. class_getInstanceVariable walks
// the superclass chain, so this works for inherited ivars too.
static id GetIvarObject(id obj, const char *ivarName) {
    if (!obj) return nil;
    Ivar ivar = class_getInstanceVariable([obj class], ivarName);
    if (!ivar) {
        ApolloLog(@"[VideoUnmute] GetIvarObject: ivar '%s' not found on %@", ivarName, [obj class]);
        return nil;
    }
    return object_getIvar(obj, ivar);
}

static id GetIvarObjectQuiet(id obj, const char *ivarName) {
    if (!obj) return nil;
    Ivar ivar = class_getInstanceVariable([obj class], ivarName);
    return ivar ? object_getIvar(obj, ivar) : nil;
}

// Read a Swift Bool ivar (1 byte) from an object. Returns NO if ivar not found.
static BOOL GetIvarBool(id obj, const char *ivarName) {
    if (!obj) return NO;
    Ivar ivar = class_getInstanceVariable([obj class], ivarName);
    if (!ivar) return NO;
    ptrdiff_t offset = ivar_getOffset(ivar);
    return *(BOOL *)((uint8_t *)(__bridge void *)obj + offset);
}

static id GetVideoNodeFromRichMediaNode(id richMediaNode) {
    return richMediaNode ? GetIvarObjectQuiet(richMediaNode, "videoNode") : nil;
}

static id GetCrosspostRichMediaNodeFromOwner(id owner) {
    id crosspostNode = GetIvarObjectQuiet(owner, "crosspostNode");
    return crosspostNode ? GetIvarObjectQuiet(crosspostNode, "richMediaNode") : nil;
}

static BOOL ObjectsMatch(id lhs, id rhs) {
    return lhs && rhs && (lhs == rhs || [lhs isEqual:rhs]);
}

static UITableView *GetTableViewFromViewController(UIViewController *viewController) {
    UIView *rootView = [viewController view];
    if (!rootView) return nil;

    for (UIView *subview in [rootView subviews]) {
        if ([subview isKindOfClass:[UITableView class]]) {
            return (UITableView *)subview;
        }
    }

    return nil;
}

static BOOL IsCommentsOwnerShowingSameLinkAsMediaPage(id mediaPageVC) {
    if (!mediaPageVC || !sCommentsVCOwner) return NO;

    id mediaPageLink = GetIvarObjectQuiet(mediaPageVC, "link");
    id commentsLink = GetIvarObjectQuiet(sCommentsVCOwner, "link");
    return ObjectsMatch(mediaPageLink, commentsLink);
}

// Saved nav controller reference for the 200ms dispatch_after in
// viewDidDisappear. Must be captured in viewWillDisappear (still non-nil
// during pop) — by viewDidDisappear the CommentsVC is already removed
// from the nav stack and self.navigationController returns nil.
static __weak UINavigationController *sSavedNavControllerForPop = nil;

static BOOL RichMediaNodeContainsPlayer(id richMediaNode, AVPlayer *targetPlayer) {
    if (!richMediaNode || !targetPlayer) return NO;

    id videoNode = GetVideoNodeFromRichMediaNode(richMediaNode);
    if (!videoNode) return NO;

    AVPlayer *player = GetPlayerFromVideoNode(videoNode);
    return player && player == targetPlayer;
}

// Check if a specific AVPlayer is on any visible feed cell's playerLayer.
// Used after back navigation to determine if the player is visible on the
// feed (non-compact: feed has inline video cells) or orphaned (compact:
// no inline video on feed). Walks the feed VC's table view visible cells.
static BOOL IsPlayerOnVisibleFeedCell(UIViewController *feedVC, AVPlayer *targetPlayer) {
    if (!feedVC || !targetPlayer) return NO;

    UITableView *tableView = GetTableViewFromViewController(feedVC);
    if (!tableView) return NO;

    for (UITableViewCell *cell in [tableView visibleCells]) {
        SEL nodeSel = NSSelectorFromString(@"node");
        if (![cell respondsToSelector:nodeSel]) continue;

        id cellNode = ((id (*)(id, SEL))objc_msgSend)(cell, nodeSel);
        if (!cellNode) continue;

        if (RichMediaNodeContainsPlayer(GetIvarObjectQuiet(cellNode, "richMediaNode"), targetPlayer)) {
            return YES;
        }
        if (RichMediaNodeContainsPlayer(GetCrosspostRichMediaNodeFromOwner(cellNode), targetPlayer)) {
            return YES;
        }
    }

    return NO;
}

// Recursively search a view hierarchy for a subview of a given class.
// Used to find PlayerLayerContainerView in the transition container after
// animateTransition: (before the ivar on MediaViewerController is set).
static UIView *FindSubviewOfClass(UIView *root, Class cls) {
    if (!root || !cls) return nil;
    for (UIView *subview in [root subviews]) {
        if ([subview isKindOfClass:cls]) return subview;
        UIView *found = FindSubviewOfClass(subview, cls);
        if (found) return found;
    }
    return nil;
}

// Get the AVPlayer from an ASVideoNode. Handles both shareable (playerLayer)
// and non-shareable (direct player property) paths.
//
// For shareable v.redd.it videos: player is on [[videoNode playerLayer] player]
//   - The AVPlayerLayer is shared from the feed cell; the ASVideoNode's _player
//     ivar is nil. The native button tap handler (sub_10058b800) uses this path.
//
// For non-shareable GIFs/Streamable/etc: player is on [videoNode player]
//   - A new AVPlayer is created via prepareToPlayAsset:withKeys: → setPlayer:.
static AVPlayer *GetPlayerFromVideoNode(id videoNode) {
    if (!videoNode) return nil;

    // Primary path: shareable videos — player is on the AVPlayerLayer.
    // This mirrors the native code: [r21 playerLayer] → [playerLayer player]
    SEL playerLayerSel = NSSelectorFromString(@"playerLayer");
    if ([videoNode respondsToSelector:playerLayerSel]) {
        id layer = ((id (*)(id, SEL))objc_msgSend)(videoNode, playerLayerSel);
        if (layer) {
            SEL layerPlayerSel = NSSelectorFromString(@"player");
            if ([layer respondsToSelector:layerPlayerSel]) {
                AVPlayer *player = ((id (*)(id, SEL))objc_msgSend)(layer, layerPlayerSel);
                if (player) return player;
            }
        }
    }

    // Fallback: non-shareable videos — player is directly on videoNode
    SEL playerSel = NSSelectorFromString(@"player");
    if ([videoNode respondsToSelector:playerSel]) {
        AVPlayer *player = ((id (*)(id, SEL))objc_msgSend)(videoNode, playerSel);
        if (player) return player;
    }

    return nil;
}

// Get the AVPlayer from a MediaPageViewController's currently-displayed child
// MediaViewerController. Returns nil if the child is showing an image (no player)
// or if the child VC isn't a MediaViewerController. Used to restrict our
// MediaPageVC hooks to video-only content.
static AVPlayer *GetPlayerFromMediaPageVC(id mediaPageVC) {
    static Class sMediaViewerClass = nil;
    if (!sMediaViewerClass) {
        sMediaViewerClass = objc_getClass("_TtC6Apollo21MediaViewerController");
    }
    if (!sMediaViewerClass) {
        ApolloLog(@"[VideoUnmute] GetPlayerFromMediaPageVC: MediaViewerController class not found");
        return nil;
    }

    NSArray *vcs = ((NSArray *(*)(id, SEL))objc_msgSend)(mediaPageVC, @selector(viewControllers));
    id mediaVC = [vcs firstObject];
    if (!mediaVC || ![mediaVC isKindOfClass:sMediaViewerClass]) return nil;

    // Direct player ivar (non-shareable videos)
    AVPlayer *player = GetIvarObject(mediaVC, "player");
    if (player) return player;

    // Shareable videos: player on playerLayerContainerView.playerLayer
    id container = GetIvarObject(mediaVC, "playerLayerContainerView");
    if (container) {
        id playerLayer = GetIvarObject(container, "playerLayer");
        if ([playerLayer isKindOfClass:[AVPlayerLayer class]]) {
            player = [(AVPlayerLayer *)playerLayer player];
            if (player) return player;
        }
    }

    return nil;
}

// Update the MuteUnmuteVideoButtonNode's visual state to match actual mute state.
// Sets the `isMuted` ivar (Swift Bool) and updates the `icon` ASImageNode's image.
//
// Icon names decoded from the binary (sub_10058b800 assembly):
//   Muted:   "small-mute"   (0xea prefix, 10 chars)
//   Unmuted: "small-unmute" (0xec prefix, 12 chars)
static void SyncMuteButtonIcon(id richMediaNode, BOOL isMuted) {
    id muteButtonNode = GetIvarObject(richMediaNode, "muteUnmuteButtonNode");
    if (!muteButtonNode) return;

    // Skip if button state already matches — avoids redundant work during scroll
    BOOL currentIsMuted = GetIvarBool(muteButtonNode, "isMuted");
    if (currentIsMuted == isMuted) return;

    ApolloLog(@"[VideoUnmute] SyncMuteButtonIcon: %@ → %@",
              currentIsMuted ? @"muted" : @"unmuted",
              isMuted ? @"muted" : @"unmuted");

    // Write the isMuted ivar (Swift Bool = 1 byte at ivar offset)
    Ivar isMutedIvar = class_getInstanceVariable([muteButtonNode class], "isMuted");
    if (isMutedIvar) {
        ptrdiff_t offset = ivar_getOffset(isMutedIvar);
        *(BOOL *)((uint8_t *)(__bridge void *)muteButtonNode + offset) = isMuted;
    }

    // Update the icon ASImageNode's image to match
    id iconNode = GetIvarObject(muteButtonNode, "icon");
    if (iconNode && [iconNode respondsToSelector:@selector(setImage:)]) {
        NSString *imageName = isMuted ? @"small-mute" : @"small-unmute";
        UIImage *image = [UIImage imageNamed:imageName];
        if (image) {
            ((void (*)(id, SEL, id))objc_msgSend)(iconNode, @selector(setImage:), image);
        }
    }
}

static void SyncRichMediaNodeMuteButton(id richMediaNode) {
    id videoNode = GetVideoNodeFromRichMediaNode(richMediaNode);
    if (!videoNode) return;

    AVPlayer *player = GetPlayerFromVideoNode(videoNode);
    if (!player) return;

    SyncMuteButtonIcon(richMediaNode, [player isMuted]);
}

static void SyncVisibleCellMuteButtons(id cellNode) {
    if (!cellNode) return;

    SyncRichMediaNodeMuteButton(GetIvarObjectQuiet(cellNode, "richMediaNode"));
    SyncRichMediaNodeMuteButton(GetCrosspostRichMediaNodeFromOwner(cellNode));
}

static void SyncVisibleFeedMuteButtons(UIViewController *feedVC) {
    UITableView *tableView = GetTableViewFromViewController(feedVC);
    if (!tableView) {
        ApolloLog(@"[VideoUnmute] SyncVisibleFeedMuteButtons: no tableView found on %@", [feedVC class]);
        return;
    }

    for (UITableViewCell *cell in [tableView visibleCells]) {
        SEL nodeSel = NSSelectorFromString(@"node");
        if (![cell respondsToSelector:nodeSel]) continue;

        id cellNode = ((id (*)(id, SEL))objc_msgSend)(cell, nodeSel);
        if (!cellNode) continue;

        SyncVisibleCellMuteButtons(cellNode);
    }
}

// Core unmute logic. Replicates the native unmute flow from sub_100341894
// (PostCellActionTaker.muteUnmuteTapped(player:)) without depending on the
// weak actionDelegate which may be nil in the comments header context.
//
// Steps in strict order (matching the native flow):
//   1. Set AVAudioSession to Playback (MUST be before unmuting — Apollo
//      defaults to Ambient which silences AVPlayer audio)
//   2. Unmute the AVPlayer directly (for shareable videos, ASVideoNode's
//      _player ivar is nil, so [videoNode setMuted:NO] alone won't work)
//   3. Also update ASVideoNode's internal _muted flag for consistency
//   4. Track the player for AVAudioSession hook scoping
//   5. Sync the mute button icon
static void UnmuteRichMediaNode(id richMediaNode, id videoNode) {
    AVPlayer *player = GetPlayerFromVideoNode(videoNode);
    if (!player) {
        ApolloLog(@"[VideoUnmute] UnmuteRichMediaNode: no player found, aborting");
        return;
    }

    BOOL alreadyUnmuted = ![player isMuted];

    // Even when the player is already unmuted (e.g. re-entry from feed where
    // audio was playing), we must establish protection (sAutoUnmutedPlayer +
    // Playback session). Without this, the mute dance from the feed cell
    // exiting visibility would kill audio ~350-500ms into the push animation.
    // Steps 2-3 (setMuted:NO) are skipped when redundant to avoid triggering
    // ASVideoNode internals (KVO, layout) unnecessarily.

    ApolloLog(@"[VideoUnmute] UnmuteRichMediaNode: %@",
              alreadyUnmuted ? @"player already unmuted, establishing protection"
                             : @"starting unmute sequence...");

    // Step 1: AVAudioSession → Playback (always — session may be Ambient)
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    [session setCategory:AVAudioSessionCategoryPlayback
                    mode:AVAudioSessionModeDefault
                 options:0
                   error:&error];
    if (error) ApolloLog(@"[VideoUnmute] setCategory:Playback error: %@", error);
    error = nil;
    [session setActive:YES withOptions:0 error:&error];
    if (error) ApolloLog(@"[VideoUnmute] setActive:YES error: %@", error);

    if (!alreadyUnmuted) {
        // Step 2: Unmute the AVPlayer directly. For shareable videos, the
        // ASVideoNode's _player ivar is nil — only the playerLayer has the player.
        // We must unmute the player object directly.
        sIsAutoUnmuting = YES;
        [player setMuted:NO];

        // Step 3: Also update ASVideoNode's internal _muted ivar for consistency.
        // [videoNode setMuted:NO] sets _muted=NO and also [_player setMuted:NO]
        // if _player is non-nil. For shareable videos, _player is nil so only
        // _muted gets updated — but that's fine, we already unmuted the real
        // player above.
        SEL setMutedSel = NSSelectorFromString(@"setMuted:");
        if ([videoNode respondsToSelector:setMutedSel]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(videoNode, setMutedSel, NO);
        }
        sIsAutoUnmuting = NO;
    }

    // Step 4: Track this player so AVAudioSession hooks block Ambient reversion
    // (always — the core of the re-entry fix)
    sAutoUnmutedPlayer = player;

    // Step 5: Sync the mute button icon to "unmuted" state (always)
    SyncMuteButtonIcon(richMediaNode, NO);

    ApolloLog(@"[VideoUnmute] Auto-unmute complete for player %p", player);
}

static void ReUnmuteAfterFullscreenWhenReady(id richMediaNode, id videoNode, NSUInteger attemptsRemaining) {
    id rmNode = richMediaNode;
    id vNode = videoNode;
    if (!rmNode || !vNode) {
        ApolloLog(@"[VideoUnmute] Re-unmute after fullscreen: nodes deallocated, aborting");
        return;
    }

    AVPlayer *player = GetPlayerFromVideoNode(vNode);
    if (!player) {
        if (attemptsRemaining > 0) {
            ApolloLog(@"[VideoUnmute] Re-unmute after fullscreen: player not ready, retrying (%lu left)",
                      (unsigned long)attemptsRemaining);
            __weak id weakRichMediaNode = rmNode;
            __weak id weakVideoNode = vNode;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                ReUnmuteAfterFullscreenWhenReady(weakRichMediaNode, weakVideoNode, attemptsRemaining - 1);
            });
        } else {
            ApolloLog(@"[VideoUnmute] Re-unmute after fullscreen: no player found, aborting");
        }
        return;
    }

    ApolloLog(@"[VideoUnmute] Re-unmuting after fullscreen dismiss");
    UnmuteRichMediaNode(rmNode, vNode);
}

static void HandleCommentsRichMediaVisibilityEvent(id visibilityOwner,
                                                   id richMediaNode,
                                                   unsigned long long event,
                                                   NSString *contextLabel) {
    if (!visibilityOwner || !richMediaNode) return;

    // ASCellNodeVisibilityEventInvisible (2): cell scrolled out of view.
    // Clear auto-unmute protection AND saved refs — the video is no longer
    // visible, so MediaPageVC dismiss should not re-unmute it.
    if (event == 2) {
        if (sIsNavigatingBack) {
            ApolloLog(@"[VideoUnmute] %@ cell invisible during back navigation — keeping protection", contextLabel);
            return;
        }
        ApolloLog(@"[VideoUnmute] %@ cell invisible — clearing protection and refs", contextLabel);

        sAutoUnmutedPlayer = nil;  // Clear first so our setMuted: hook doesn't block

        id videoNode = GetVideoNodeFromRichMediaNode(richMediaNode);
        if (videoNode) {
            SEL setMutedSel = NSSelectorFromString(@"setMuted:");
            if ([videoNode respondsToSelector:setMutedSel]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(videoNode, setMutedSel, YES);
            }

            AVPlayer *player = GetPlayerFromVideoNode(videoNode);
            if (player) [player setMuted:YES];
        }

        sCommentsRichMediaNode = nil;
        sCommentsVideoNode = nil;
        return;
    }

    BOOL unmuteApplied = objc_getAssociatedObject(visibilityOwner, kAutoUnmuteAppliedKey) != nil;
    id videoNode = GetVideoNodeFromRichMediaNode(richMediaNode);
    if (!videoNode) return;

    if (sUnmuteCommentsVideos >= 1) {
        sCommentsRichMediaNode = richMediaNode;
        sCommentsVideoNode = videoNode;
    }

    AVPlayer *player = GetPlayerFromVideoNode(videoNode);
    if (!player) {
        ApolloLog(@"[VideoUnmute] %@ player not ready (event=%llu), scheduling retry",
                  contextLabel, event);

        __weak id weakOwner = visibilityOwner;
        __weak id weakRichMediaNode = richMediaNode;
        __weak id weakVideoNode = videoNode;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            id strongOwner = weakOwner;
            id rmNode = weakRichMediaNode;
            id vNode = weakVideoNode;
            if (!strongOwner || !rmNode || !vNode) return;

            AVPlayer *retryPlayer = GetPlayerFromVideoNode(vNode);
            if (!retryPlayer) {
                ApolloLog(@"[VideoUnmute] %@ retry: player still not ready after 500ms", contextLabel);
                return;
            }

            SyncMuteButtonIcon(rmNode, [retryPlayer isMuted]);

            if (sUnmuteCommentsVideos == 2
                && !objc_getAssociatedObject(strongOwner, kAutoUnmuteAppliedKey)) {
                objc_setAssociatedObject(strongOwner, kAutoUnmuteAppliedKey, @YES,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                ApolloLog(@"[VideoUnmute] %@ retry: unmuting after delay (muted=%d)",
                          contextLabel, [retryPlayer isMuted]);
                UnmuteRichMediaNode(rmNode, vNode);
            }
        });
        return;
    }

    SyncMuteButtonIcon(richMediaNode, [player isMuted]);

    if (sUnmuteCommentsVideos != 2) return;
    if (unmuteApplied) return;

    objc_setAssociatedObject(visibilityOwner, kAutoUnmuteAppliedKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    ApolloLog(@"[VideoUnmute] %@ auto-unmuting (event=%llu, muted=%d)",
              contextLabel, event, [player isMuted]);
    UnmuteRichMediaNode(richMediaNode, videoNode);
}

// =============================================================================
// MARK: - Hooks
// =============================================================================

// ---------------------------------------------------------------------------
// RichMediaHeaderCellNode: the comments header video cell
// ---------------------------------------------------------------------------
// cellNodeVisibilityEvent: fires when the cell's visibility changes in the
// scroll view (visible, invisible, rect changed, etc). Two responsibilities:
//
// 1. Icon sync (ALWAYS, native bug fix, runs on every visibility event):
//    For shareable videos, the button setup code (sub_100582a0c) checks
//    [videoNode player] to set the initial isMuted state. But for shareable
//    videos, [videoNode player] is nil (the player is on the playerLayer).
//    The code defaults to isMuted=false (unmuted icon) even though the player
//    is actually muted. We correct this on every visibility event so the icon
//    stays in sync — including after returning from MediaViewer, which
//    force-mutes the player via viewDidDisappear.
//
// 2. Auto-unmute (only if toggle enabled, one-shot per cell instance):
//    Unmutes the player and syncs the icon to "unmuted" state.
// ---------------------------------------------------------------------------
%hook RichMediaHeaderCellNode

- (void)cellNodeVisibilityEvent:(unsigned long long)event
                   inScrollView:(id)scrollView
                  withCellFrame:(CGRect)frame {
    %orig;
    id richMediaNode = GetIvarObject(self, "richMediaNode");
    HandleCommentsRichMediaVisibilityEvent(self, richMediaNode, event,
                                           @"comments header video");
}

%end

%hook CommentsHeaderCellNode

- (void)cellNodeVisibilityEvent:(unsigned long long)event
                   inScrollView:(id)scrollView
                  withCellFrame:(CGRect)frame {
    %orig;

    id richMediaNode = GetCrosspostRichMediaNodeFromOwner(self);
    if (!richMediaNode) return;

    ApolloLog(@"[VideoUnmute] CommentsHeaderCellNode visibility event=%llu for crosspost rich media",
              event);
    HandleCommentsRichMediaVisibilityEvent(self, richMediaNode, event,
                                           @"comments crosspost video");
}

%end

// =============================================================================
// MARK: - RichMediaNode Hooks
// =============================================================================

%hook RichMediaNode

// ---------------------------------------------------------------------------
// unpauseAllAVPlayersNotificationReceivedWithNotification: — native bug fix:
// shareable comments header videos are skipped by the native unpause handler
// (sub_10058249c). Resume them ourselves. Unconditional (not behind the
// unmute toggle) since it's a native bug fix.
// ---------------------------------------------------------------------------
- (void)unpauseAllAVPlayersNotificationReceivedWithNotification:(id)notification {
    %orig;

    // Only fix for comments header videos
    if (!GetIvarBool(self, "isShownInCommentsHeader") && self != sCommentsRichMediaNode) return;

    id videoNode = GetIvarObject(self, "videoNode");
    if (!videoNode) return;

    // Only fix for shareable videos (non-shareable already handled by native code)
    SEL shareableSel = NSSelectorFromString(@"allowPlayerLayerToBeShareable");
    if (![videoNode respondsToSelector:shareableSel]) return;
    BOOL isShareable = ((BOOL (*)(id, SEL))objc_msgSend)(videoNode, shareableSel);
    if (!isShareable) return;

    AVPlayer *player = GetPlayerFromVideoNode(videoNode);
    if (!player) return;

    ApolloLog(@"[VideoUnmute] unpauseAllAVPlayers: resuming shareable comments header video");
    [player play];
}

// ---------------------------------------------------------------------------
// muteUnmuteButtonTappedWithSender: — detect user manually tapping the mute
// button. Clears sAutoUnmutedPlayer BEFORE %orig so the mute dance that
// follows (triggered by the native handler) can proceed normally.
//
// This is the counterpart to the AVPlayer.setMuted: hook which BLOCKS mute
// on the auto-unmuted player. Without this, the user couldn't manually mute.
// ---------------------------------------------------------------------------
- (void)muteUnmuteButtonTappedWithSender:(id)sender {
    // Clear auto-unmute protection if this cell's player matches the
    // protected player. No context check (isShownInCommentsHeader) — for
    // shareable videos the same AVPlayer is shared between feed and comments
    // cells, so the user must be able to mute from either context.
    if (sAutoUnmutedPlayer) {
        id videoNode = GetIvarObject(self, "videoNode");
        AVPlayer *player = GetPlayerFromVideoNode(videoNode);
        if (player && player == sAutoUnmutedPlayer) {
            ApolloLog(@"[VideoUnmute] User tapped mute button — clearing auto-unmute protection");
            sAutoUnmutedPlayer = nil;
        }
    }

    // Capture player state before the tap handler runs.
    // sub_10058cb30 (called from TouchHintVideoNode.didExitVisibleState) force-
    // mutes AND pauses unmuted videos when the feed VC leaves the view hierarchy
    // (e.g. navigating back to RedditListVC). When the user returns and taps the
    // mute button to unmute, the native handler (sub_100341894) unmutes the player
    // but does NOT call [player play], leaving the video frozen. Detect this state
    // so we can resume playback after %orig.
    id videoNodeForResume = GetIvarObject(self, "videoNode");
    AVPlayer *playerForResume = GetPlayerFromVideoNode(videoNodeForResume);
    BOOL wasMutedAndPaused = playerForResume
        && [playerForResume isMuted]
        && [playerForResume rate] == 0.0f;

    %orig;

    // If the tap just unmuted a force-paused video, resume playback.
    if (wasMutedAndPaused && playerForResume && ![playerForResume isMuted]) {
        ApolloLog(@"[VideoUnmute] Mute button unmuted a force-paused video — resuming playback");
        [playerForResume play];
    }
}

%end

// ---------------------------------------------------------------------------
// MediaPageViewController: manage auto-unmute around fullscreen transitions
// ---------------------------------------------------------------------------
// MediaPageViewController is used for ALL media types (images, videos, GIFs).
// Our hooks are guarded by GetPlayerFromMediaPageVC() to only fire for video
// content — opening/closing an image viewer must not disrupt the comments
// header video's audio protection.
//
// viewWillAppear: Suspends auto-unmute protection ONLY when the fullscreen
//   viewer shows the same video we're protecting (player identity check).
//   This lets the user freely mute/unmute in fullscreen. Image viewers and
//   different videos leave sAutoUnmutedPlayer intact.
//
// viewDidDisappear: The native dismiss code (sub_10025ce28) unconditionally:
//   1. [player setMuted:YES] — force-mutes the shared player
//   2. Sets muteUnmuteButtonNode.isMuted = true + updates icon to "small-mute"
//   3. Triggers the "mute dance" (sub_10025d84c):
//      T+0ms:   isDancing=true, posts pauseAllAVPlayers
//      T+50ms:  AVAudioSession → Ambient, setActive:NO
//      T+100ms: [player setMuted:YES] again, posts unpauseAllAVPlayers
//
//   If the player was unmuted at dismiss time (user had sound on), we schedule
//   a re-unmute after the mute dance completes (200ms) to restore audio.
// ---------------------------------------------------------------------------
%hook MediaPageViewController

// - (void)viewWillAppear:(BOOL)animated {
//     %orig;
//     if (sAutoUnmutedPlayer) {
//         // Only suspend protection if the fullscreen viewer is showing the SAME
//         // video we're protecting. Opening an image viewer (no player) or a
//         // different video should not disrupt the comments header's audio.
//         AVPlayer *fullscreenPlayer = GetPlayerFromMediaPageVC(self);
//         if (fullscreenPlayer && fullscreenPlayer == sAutoUnmutedPlayer) {
//             ApolloLog(@"[VideoUnmute] MediaPageVC appearing with protected player — suspending protection for fullscreen");
//             sAutoUnmutedPlayer = nil;
//         } else {
//             ApolloLog(@"[VideoUnmute] MediaPageVC appearing (image or different video) — keeping protection");
//         }
//     }
// }

- (void)viewDidDisappear:(BOOL)animated {
    // Only process re-unmute for video content. Image viewers have no player
    // and should not trigger any mute/unmute logic.
    AVPlayer *fullscreenPlayer = GetPlayerFromMediaPageVC(self);
    if (!fullscreenPlayer) {
        ApolloLog(@"[VideoUnmute] MediaPageVC disappearing — no video player (image viewer), skipping");
        %orig;
        return;
    }

    // Normally we only process re-unmute when fullscreen is showing the SAME
    // player as the comments header. Compact-mode entry via the fullscreen
    // comments button is different: MediaPageVC.commentsButtonTapped pushes a
    // new CommentsVC using the SAME RDKLink object (sub_100270ab0 →
    // sub_100725044), but the comments header creates a fresh AVPlayer, so the
    // player identity check fails. Detect that same-link handoff explicitly.
    AVPlayer *headerPlayer = sCommentsVideoNode ? GetPlayerFromVideoNode(sCommentsVideoNode) : nil;
    BOOL sameLinkCommentsTransition = IsCommentsOwnerShowingSameLinkAsMediaPage(self);
    if (headerPlayer && fullscreenPlayer != headerPlayer && !sameLinkCommentsTransition) {
        ApolloLog(@"[VideoUnmute] MediaPageVC disappearing — different video than header, skipping re-unmute");
        %orig;
        return;
    }

    if (sameLinkCommentsTransition && (!headerPlayer || fullscreenPlayer != headerPlayer)) {
        ApolloLog(@"[VideoUnmute] MediaPageVC disappearing — compact-mode same-link transition, allowing re-unmute with new player");
    }

    // BEFORE %orig: check if the player in the fullscreen viewer is unmuted.
    // Used by "Remember from Full Screen" mode (1) to decide whether to
    // re-unmute. "Always" mode (2) re-unmutes regardless.
    BOOL shouldReUnmute = NO;

    ApolloLog(@"[VideoUnmute] MediaPageVC disappearing — checking if re-unmute needed (mode=%ld)", (long)sUnmuteCommentsVideos);

    if (sUnmuteCommentsVideos >= 1 && sCommentsRichMediaNode && sCommentsVideoNode) {
        if (sUnmuteCommentsVideos == 2) {
            // Always mode: re-unmute regardless of fullscreen mute state
            shouldReUnmute = YES;
            ApolloLog(@"[VideoUnmute] MediaPageVC dismissing — Always mode, will re-unmute");
        } else {
            // Remember mode: check what the user did in fullscreen
            if (![fullscreenPlayer isMuted]) {
                shouldReUnmute = YES;
                ApolloLog(@"[VideoUnmute] MediaPageVC dismissing — player was unmuted, will re-unmute (Remember mode)");
            } else {
                ApolloLog(@"[VideoUnmute] MediaPageVC dismissing — player was muted (user choice), skipping re-unmute");
            }
        }
    } else {
        if (!sCommentsRichMediaNode) ApolloLog(@"[VideoUnmute] MediaPageVC disappearing — no saved richMediaNode, skipping re-unmute");
        if (!sCommentsVideoNode) ApolloLog(@"[VideoUnmute] MediaPageVC disappearing — no saved videoNode, skipping re-unmute");
    }

    %orig;  // Native: [player setMuted:YES] + mute dance (T+50ms, T+100ms)

    if (shouldReUnmute) {
        __weak id weakRichMediaNode = sCommentsRichMediaNode;
        __weak id weakVideoNode = sCommentsVideoNode;
        // Wait 200ms for the mute dance to finish (last step at T+100ms).
        // Then re-unmute the player and re-establish audio session protection.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ReUnmuteAfterFullscreenWhenReady(weakRichMediaNode, weakVideoNode, 3);
        });
    }
}

%end

// ---------------------------------------------------------------------------
// MediaViewerAnimationController: suspend protection during fullscreen
// ---------------------------------------------------------------------------
// For shareable videos, the playerLayerContainerView on MediaViewerController
// is created in animateTransition: (by the transition animation controller),
// NOT during viewDidLoad/viewWillAppear/viewDidAppear. So we can't use VC
// lifecycle hooks to find the fullscreen player reliably.
//
// Instead, hook animateTransition: directly. After %orig, the player layer
// has been transferred from the comments header to the fullscreen container.
// We check if the comments header's player matches our protected player —
// if so, the fullscreen viewer is showing the same video, and we suspend
// protection so the user can freely mute/unmute in fullscreen.
//
// This only fires for PRESENT transitions (the "to" VC is a MediaPageVC).
// Dismiss transitions have a different "to" VC and are handled by
// MediaPageViewController.viewDidDisappear.
// ---------------------------------------------------------------------------
%hook MediaViewerAnimationController

- (void)animateTransition:(id)transitionContext {
    %orig;

    if (!sAutoUnmutedPlayer) return;

    // Get the "to" VC to confirm this is a present (not dismiss) transition.
    SEL vcForKeySel = NSSelectorFromString(@"viewControllerForKey:");
    if (![transitionContext respondsToSelector:vcForKeySel]) return;

    id toVC = ((id (*)(id, SEL, id))objc_msgSend)(
        transitionContext, vcForKeySel, UITransitionContextToViewControllerKey);

    static Class sMediaPageVCClass = nil;
    if (!sMediaPageVCClass) {
        sMediaPageVCClass = objc_getClass("_TtC6Apollo23MediaPageViewController");
    }
    if (!toVC || !sMediaPageVCClass || ![toVC isKindOfClass:sMediaPageVCClass]) return;

    // After %orig, the transition has created a PlayerLayerContainerView for
    // shareable videos and added it to the view hierarchy with its playerLayer
    // ivar set. However, the MediaViewerController's playerLayerContainerView
    // ivar is only set in the animation COMPLETION block, so
    // GetPlayerFromMediaPageVC can't find it via the ivar yet.
    //
    // Walk the transition container's view hierarchy to find the
    // PlayerLayerContainerView by class, then check its playerLayer's player
    // against our protected player.
    static Class sPlayerLayerContainerClass = nil;
    if (!sPlayerLayerContainerClass) {
        sPlayerLayerContainerClass = objc_getClass("_TtC6Apollo24PlayerLayerContainerView");
    }

    // First try GetPlayerFromMediaPageVC (works for non-shareable videos
    // where the player ivar is set directly). Fall back to hierarchy walk
    // for shareable videos.
    AVPlayer *fullscreenPlayer = GetPlayerFromMediaPageVC(toVC);

    if (!fullscreenPlayer && sPlayerLayerContainerClass) {
        // Walk the transition container view to find the PlayerLayerContainerView
        // that animateTransition: just created and added to the hierarchy.
        UIView *containerView = ((id (*)(id, SEL))objc_msgSend)(transitionContext, @selector(containerView));
        UIView *found = FindSubviewOfClass(containerView, sPlayerLayerContainerClass);
        if (found) {
            id playerLayer = GetIvarObject(found, "playerLayer");
            if ([playerLayer isKindOfClass:[AVPlayerLayer class]]) {
                fullscreenPlayer = [(AVPlayerLayer *)playerLayer player];
            }
        }
    }

    ApolloLog(@"[VideoUnmute] animateTransition: fullscreenPlayer=%p, sAutoUnmutedPlayer=%p",
              fullscreenPlayer, sAutoUnmutedPlayer);

    if (fullscreenPlayer && fullscreenPlayer == sAutoUnmutedPlayer) {
        ApolloLog(@"[VideoUnmute] animateTransition: same player — suspending protection for fullscreen");
        sAutoUnmutedPlayer = nil;
    } else if (!fullscreenPlayer) {
        ApolloLog(@"[VideoUnmute] animateTransition: no player found (image viewer) — keeping protection");
    } else {
        ApolloLog(@"[VideoUnmute] animateTransition: different player — keeping protection");
    }
}

%end

// ---------------------------------------------------------------------------
// AVPlayer: block mute-dance re-muting after auto-unmute
// ---------------------------------------------------------------------------
// After our auto-unmute, the mute dance from MediaPageViewController's
// viewDidDisappear (or TouchHintVideoNode.didExitVisibleState) fires and calls
// [player setMuted:YES]. Without blocking this, the player gets re-muted
// ~50-100ms after we unmuted it.
//
// We BLOCK setMuted:YES on the auto-unmuted player entirely. User manual mute
// is handled by the muteUnmuteButtonTappedWithSender: hook on RichMediaNode,
// which clears sAutoUnmutedPlayer BEFORE the mute dance runs, allowing it
// through.
//
// Safety: sAutoUnmutedPlayer is __weak — auto-nils on player dealloc.
// ---------------------------------------------------------------------------
%hook AVPlayer

- (void)setMuted:(BOOL)muted {
    // Block mute-dance re-muting on our auto-unmuted player.
    // User manual mute clears sAutoUnmutedPlayer via the button tap hook first.
    if (muted && !sIsAutoUnmuting && sAutoUnmutedPlayer && self == sAutoUnmutedPlayer) {
        ApolloLog(@"[VideoUnmute] AVPlayer.setMuted:YES — BLOCKED (protecting auto-unmuted player)");
        return;
    }
    %orig;
}

%end

// ---------------------------------------------------------------------------
// AVAudioSession: block Apollo's reversion to Ambient
// ---------------------------------------------------------------------------
// Apollo's video setup code resets the audio session to Ambient after player
// creation, which silences audio even when player.muted == NO. We block this
// while our auto-unmuted player is active.
//
// Safety: sAutoUnmutedPlayer is __weak — auto-nils when the player deallocates,
// making these hooks transparent pass-throughs automatically.
// ---------------------------------------------------------------------------
%hook AVAudioSession

- (BOOL)setCategory:(AVAudioSessionCategory)category
                mode:(AVAudioSessionMode)mode
             options:(AVAudioSessionCategoryOptions)options
               error:(NSError **)error {
    if (sAutoUnmutedPlayer && [category isEqualToString:AVAudioSessionCategoryAmbient]) {
        ApolloLog(@"[VideoUnmute] Blocking setCategory:Ambient (mode:options: variant)");
        return YES;
    }
    return %orig;
}

- (BOOL)setCategory:(AVAudioSessionCategory)category error:(NSError **)error {
    if (sAutoUnmutedPlayer && [category isEqualToString:AVAudioSessionCategoryAmbient]) {
        ApolloLog(@"[VideoUnmute] Blocking setCategory:Ambient (short variant)");
        return YES;
    }
    return %orig;
}

- (BOOL)setActive:(BOOL)active
      withOptions:(AVAudioSessionSetActiveOptions)options
            error:(NSError **)error {
    if (!active && sAutoUnmutedPlayer) {
        ApolloLog(@"[VideoUnmute] Blocking setActive:NO while auto-unmuted player active");
        return YES;
    }
    return %orig;
}

%end

// ---------------------------------------------------------------------------
// _TtC6Apollo22CommentsViewController: manage auto-unmute through transitions
// ---------------------------------------------------------------------------
// Key insight: when swiping back from comments to feed, the mute dance
// (sub_1003414cc, triggered by TouchHintVideoNode.didExitVisibleState →
// sub_10058cb30) fires DURING the transition and asynchronously:
//   T+0ms:   isDancing=true, pauseAllAVPlayers
//   T+50ms:  setCategory:Ambient, setActive:NO
//   T+100ms: [player setMuted:YES], unpauseAllAVPlayers
//
// If sAutoUnmutedPlayer is cleared before the mute dance completes, our
// AVPlayer.setMuted: and AVAudioSession hooks can't block it, and the
// player gets re-muted. This matches the user-observed bug: audio mutes
// on swipe-back but persists when using native unmute (which registers
// with VideoSharingManager.activeAudioPlayer instead).
//
// Fix: during back navigation, keep sAutoUnmutedPlayer alive so the hooks
// block the mute dance. The player protection persists into the feed,
// matching native unmute behavior.
// ---------------------------------------------------------------------------
%hook _TtC6Apollo22CommentsViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;

    BOOL isSameVC = (sCommentsVCOwner == self);

    if (sIsNavigatingBack && isSameVC) {
        // Same CommentsVC reappearing while sIsNavigatingBack is set means
        // an interactive back gesture was cancelled — we're still in comments.
        // Reset so a subsequent scroll-out-of-view (event=2) can clear
        // sAutoUnmutedPlayer normally instead of keeping stale protection.
        ApolloLog(@"[VideoUnmute] CommentsVC viewWillAppear — back gesture cancelled, resetting navigation flag");
        sIsNavigatingBack = NO;
    }
    // Note: when a DIFFERENT CommentsVC appears (isSameVC=NO), do NOT reset
    // sIsNavigatingBack. The popping CommentsVC's mute dance may still be
    // in-flight, and sIsNavigatingBack must survive until its viewDidDisappear
    // to protect sAutoUnmutedPlayer from the event=2 handler.

    if (!isSameVC) {
        // Different CommentsVC is appearing (forward push or back to a
        // previous CommentsVC). Clear stale refs from the old CommentsVC —
        // they belong to an invisible video and would cause ghost audio if
        // MediaPageVC dismiss tried to re-unmute them.
        ApolloLog(@"[VideoUnmute] CommentsVC viewWillAppear — new CommentsVC, clearing stale refs from previous");
        sCommentsRichMediaNode = nil;
        sCommentsVideoNode = nil;
    }
    // When isSameVC=YES (returning from MediaPageVC or gesture cancel),
    // refs are preserved so MediaPageVC.viewDidDisappear's dispatch_after
    // can still use them for re-unmute.

    sCommentsVCOwner = self;
}

- (void)viewWillDisappear:(BOOL)animated {
    BOOL isPopping = [(UIViewController *)self isMovingFromParentViewController];
    ApolloLog(@"[VideoUnmute] CommentsVC viewWillDisappear (isPopping=%d)", isPopping);
    %orig;

    if (isPopping) {
        // Back navigation (swipe or back button tap). Keep sAutoUnmutedPlayer
        // set so our hooks block the mute dance through the transition.
        sIsNavigatingBack = YES;
        // Save nav controller now — by viewDidDisappear, self.navigationController is nil.
        sSavedNavControllerForPop = [(UIViewController *)self navigationController];
        ApolloLog(@"[VideoUnmute] CommentsVC popping — keeping auto-unmute protection for back transition");
    }
    // Note: sAutoUnmutedPlayer is NOT cleared here anymore.
    // - Back navigation: protection persists so audio survives the mute dance.
    // - MediaPageVC push: MediaPageVC.viewWillAppear clears it separately.
    // - Scroll out of view: cellNodeVisibilityEvent event=2 clears it.
}

- (void)viewDidDisappear:(BOOL)animated {
    BOOL wasNavigatingBack = sIsNavigatingBack;
    UINavigationController *navForPop = sSavedNavControllerForPop;
    ApolloLog(@"[VideoUnmute] CommentsVC viewDidDisappear (isOwner=%d, wasBack=%d)", self == sCommentsVCOwner, wasNavigatingBack);
    %orig;
    sIsNavigatingBack = NO;
    sSavedNavControllerForPop = nil;
    // Only clear saved refs if THIS CommentsVC owns them. When navigating
    // CommentsVC #1 → CommentsVC #2 (via link), CommentsVC #2's
    // cellNodeVisibilityEvent saves refs and viewWillAppear claims ownership
    // BEFORE CommentsVC #1's viewDidDisappear fires. Without this guard,
    // CommentsVC #1 would wipe CommentsVC #2's refs, breaking re-unmute
    // after fullscreen.
    if (self == sCommentsVCOwner) {
        sCommentsRichMediaNode = nil;
        sCommentsVideoNode = nil;
        sCommentsVCOwner = nil;

        if (wasNavigatingBack && sAutoUnmutedPlayer) {
            // Back navigation: keep sAutoUnmutedPlayer alive briefly so
            // our hooks block the post-pop setCategory:Ambient (from
            // player setup after the playerLayer reclaim) and any mute
            // dance steps that might still be in-flight.
            //
            // Expire after 200ms — the mute dance window is T+0..T+100ms,
            // so 200ms covers the worst case with margin.
            //
            // After expiry, check if a visible feed cell has our player on
            // its playerLayer. If yes (non-compact: feed has inline video),
            // audio continues. If no (compact: no inline video on feed),
            // mute + pause to prevent invisible background audio.
            ApolloLog(@"[VideoUnmute] CommentsVC popped — keeping auto-unmute protection, will expire after mute dance window");

            __weak AVPlayer *weakPlayer = sAutoUnmutedPlayer;
            __weak UINavigationController *weakNav = navForPop;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                // Only clear if the protected player hasn't changed
                // (e.g. a new CommentsVC might have set a new player)
                if (sAutoUnmutedPlayer && sAutoUnmutedPlayer == weakPlayer) {
                    sAutoUnmutedPlayer = nil;

                    // Walk visible feed cells to check if the player is
                    // displayed on an inline video cell.
                    UINavigationController *nav = weakNav;
                    UIViewController *feedVC = [nav topViewController];
                    AVPlayer *p = weakPlayer;
                    BOOL visibleOnFeed = p ? IsPlayerOnVisibleFeedCell(feedVC, p) : NO;

                    ApolloLog(@"[VideoUnmute] Mute dance window expired — clearing protection (visibleOnFeed=%d)", visibleOnFeed);

                    if (!visibleOnFeed && p) {
                        // Player is not on any visible feed cell (compact mode
                        // or no matching cell). Mute + pause + reset audio
                        // session to prevent invisible background audio.
                        ApolloLog(@"[VideoUnmute] Player not on feed — muting to prevent background audio");
                        [p setMuted:YES];
                        [p pause];
                        AVAudioSession *session = [AVAudioSession sharedInstance];
                        [session setCategory:AVAudioSessionCategoryAmbient error:nil];
                        [session setActive:NO
                               withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                     error:nil];
                    }

                    if (feedVC) {
                        ApolloLog(@"[VideoUnmute] Syncing visible feed mute buttons after comments pop");
                        SyncVisibleFeedMuteButtons(feedVC);
                    }
                }
            });
        } else if (wasNavigatingBack) {
            __weak UINavigationController *weakNav = navForPop;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIViewController *feedVC = [weakNav topViewController];
                if (!feedVC) return;

                ApolloLog(@"[VideoUnmute] CommentsVC popped without protected player — syncing visible feed mute buttons");
                SyncVisibleFeedMuteButtons(feedVC);
            });
        } else if (sAutoUnmutedPlayer) {
            // Non-back transition (e.g. pushing MediaPageVC or another VC).
            // Drop protection so the native mute dance can proceed.
            ApolloLog(@"[VideoUnmute] CommentsVC disappeared (not back nav) — clearing auto-unmute protection");
            sAutoUnmutedPlayer = nil;
        }
    }
}

%end

// =============================================================================
// MARK: - Exported: Fix Disconnected PlayerLayer
// =============================================================================
//
// Called from ApolloVideoSwipeFix after the committed pop's reclaim.
// After fullscreen MediaPageVC transitions, the reclaim (sub_100561a40) puts
// the shared AVPlayerLayer into playerLayerSuperlayer — a container CALayer
// saved by PostCellActionTaker that can become DISCONNECTED from the window's
// layer tree. The reclaim's async block (sub_100562a80) also doesn't run
// because the sharing state was already cleared. This leaves the playerLayer
// invisible and the shareable flag stale.
//
// This function walks visible cells, finds the disconnected playerLayer, and
// replicates what the async block would have done:
//   1. Re-parent playerLayer into the videoNode's live layer tree
//   2. Set allowPlayerLayerToBeShareable:NO (enables native unpause handler)
//   3. Sync the mute button icon to the player's actual state
//
// See docs/frozen-video-root-cause.md for the full analysis.
// =============================================================================

void ApolloVideoUnmute_FixDisconnectedPlayerLayer(id postsViewController) {
    UITableView *tableView = GetTableViewFromViewController((UIViewController *)postsViewController);
    if (!tableView) {
        ApolloLog(@"[VideoUnmute] FixDisconnectedPlayerLayer: no tableView found");
        return;
    }

    BOOL foundDisconnected = NO;

    for (UITableViewCell *cell in [tableView visibleCells]) {
        SEL nodeSel = NSSelectorFromString(@"node");
        if (![cell respondsToSelector:nodeSel]) continue;

        id cellNode = ((id (*)(id, SEL))objc_msgSend)(cell, nodeSel);
        if (!cellNode) continue;

        for (id richMediaNode in @[
            GetIvarObjectQuiet(cellNode, "richMediaNode") ?: [NSNull null],
            GetCrosspostRichMediaNodeFromOwner(cellNode) ?: [NSNull null]
        ]) {
            if (richMediaNode == (id)[NSNull null]) continue;

            id videoNode = GetVideoNodeFromRichMediaNode(richMediaNode);
            if (!videoNode) continue;

            SEL playerLayerSel = NSSelectorFromString(@"playerLayer");
            if (![videoNode respondsToSelector:playerLayerSel]) continue;

            CALayer *pLayer = ((id (*)(id, SEL))objc_msgSend)(videoNode, playerLayerSel);
            CALayer *vnLayer = ((CALayer *(*)(id, SEL))objc_msgSend)(videoNode, @selector(layer));
            if (!pLayer || !vnLayer) continue;

            AVPlayer *player = [pLayer respondsToSelector:@selector(player)]
                ? [(AVPlayerLayer *)pLayer player] : nil;
            if (!player || [player rate] == 0.0f) continue;

            BOOL inTree = NO;
            CALayer *walk = [pLayer superlayer];
            while (walk) {
                if (walk == vnLayer) { inTree = YES; break; }
                walk = [walk superlayer];
            }

            if (!inTree) {
                ApolloLog(@"[VideoUnmute] FixDisconnectedPlayerLayer: re-parenting playerLayer %p to videoNode %p",
                          pLayer, videoNode);
                [pLayer removeFromSuperlayer];
                [vnLayer addSublayer:pLayer];

                SEL setShareableSel = NSSelectorFromString(@"setAllowPlayerLayerToBeShareable:");
                if ([videoNode respondsToSelector:setShareableSel]) {
                    ((void (*)(id, SEL, BOOL))objc_msgSend)(videoNode, setShareableSel, NO);
                }

                foundDisconnected = YES;
            }

            SyncMuteButtonIcon(richMediaNode, [player isMuted]);
        }
    }

    if (!foundDisconnected) {
        ApolloLog(@"[VideoUnmute] FixDisconnectedPlayerLayer: no disconnected playerLayer found");
    }
}

// =============================================================================
// MARK: - Constructor
// =============================================================================

%ctor {
    Class richMediaHeaderCellClass = objc_getClass("_TtC6Apollo23RichMediaHeaderCellNode");
    Class commentsHeaderCellClass = objc_getClass("_TtC6Apollo22CommentsHeaderCellNode");
    Class richMediaNodeClass = objc_getClass("_TtC6Apollo13RichMediaNode");
    Class mediaPageVCClass = objc_getClass("_TtC6Apollo23MediaPageViewController");
    Class mediaViewerAnimClass = objc_getClass("_TtC6Apollo30MediaViewerAnimationController");

    ApolloLog(@"[VideoUnmute] ctor: RichMediaHeaderCellNode=%p, CommentsHeaderCellNode=%p, RichMediaNode=%p, MediaPageVC=%p, MediaViewerAnimCtrl=%p",
              (void *)richMediaHeaderCellClass, (void *)commentsHeaderCellClass, (void *)richMediaNodeClass,
              (void *)mediaPageVCClass, (void *)mediaViewerAnimClass);

    if (!richMediaHeaderCellClass || !commentsHeaderCellClass || !richMediaNodeClass
        || !mediaPageVCClass || !mediaViewerAnimClass) {
        ApolloLog(@"[VideoUnmute] ctor: FATAL - required classes not found!");
        return;
    }

    %init(
        RichMediaHeaderCellNode = richMediaHeaderCellClass,
        CommentsHeaderCellNode = commentsHeaderCellClass,
        RichMediaNode = richMediaNodeClass,
        MediaPageViewController = mediaPageVCClass,
        MediaViewerAnimationController = mediaViewerAnimClass
    );

    ApolloLog(@"[VideoUnmute] ctor: hooks initialized");
}
