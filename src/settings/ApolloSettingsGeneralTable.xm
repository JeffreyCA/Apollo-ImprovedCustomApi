// ApolloSettingsGeneralTable — the single owner of Apollo's native Settings >
// General table geometry. Feature modules register row hides / injections via
// the API in ApolloSettingsGeneralTable.h; this module turns the registry into
// a per-screen display<->native row map and interposes an NSProxy as the
// table's delegate + dataSource to apply it.
//
// WHY A PROXY, NOT %hook: the screen is a Eureka FormViewController whose
// delegate methods index straight into its form model
// (`form[indexPath.section][indexPath.row]`) with no bounds guard, so every
// index path crossing the display/native boundary must be translated — and with
// %hook stacks the boundary is smeared across every hooked method on the class
// (any second module hooking the same methods re-enters the chain in the wrong
// index space; PR #570). With the proxy the boundary is exactly one object:
//   - the VC's own methods are never swizzled, so Eureka-internal
//     `self.tableView(...)` calls (its height/estimated merged twin, form
//     lookups from row callbacks) run purely in native space;
//   - one generic forwardInvocation: translates EVERY NSIndexPath argument and
//     return value, covering delegate methods we never enumerated — the old
//     frozen `otool -oV` selector-dump completeness assumption is gone;
//   - a second module hooking the VC class can no longer enter the geometry
//     chain at all, so the single-remapper invariant is structural.
//
// THE MAP (display space -> native space), built once per screen instance from
// a full scan in viewDidLoad:
//   displayRows[section] = [0, 1, INJECTED(i), 2, 4]
// Hidden native rows are simply omitted (no zero-height rows, separators, or
// selection swallowing) and injected slots carry a marker. Sections with no
// changes aren't in the map and pass through untouched. Both directions are
// O(rows) on tiny arrays.
//
// VERIFIED ASSUMPTIONS (Hopper: Apollo.hop + the embedded Eureka binary, plus
// the Eureka 5.5 source):
//   - The General form is built exactly once, in viewDidLoad; its three hidden
//     conditions use empty tag arrays (evaluated once, no observers), the
//     subclass overrides no viewWillAppear, and re-entry creates a fresh VC —
//     so a single scan per instance is sound and the map never goes stale.
//   - Eureka touches the table's delegate/dataSource in exactly one place:
//     viewDidLoad's nil-guards (`if tableView.delegate == nil`). Nothing ever
//     reads them back for dispatch or casts them (its cells find their VC by
//     walking the RESPONDER chain — Cell.swift's formViewController() — which
//     still contains the real VC), so interposing after %orig is safe and
//     nothing needs to fight over the pointer afterward. A defensive re-assert
//     lives in viewDidLayoutSubviews anyway and logs loudly if it ever fires.
//   - Eureka APIs that pass MODEL-derived (native) paths straight to table
//     APIs (BaseRow.reload()/select()/deselect(), hidden-condition
//     insert/delete) would misroute under ANY remapping design, including the
//     previous +1 hook stack; none are reachable on this screen (static form,
//     no tag conditions). Re-check on a base-IPA bump.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloSettingsGeneralTable.h"

@interface SettingsGeneralViewController : UIViewController
@end

// MARK: - registry (filled from feature %ctors, read at screen load)

typedef UITableViewCell *(^ApolloGTRowFactory)(UIViewController *vc, UITableViewCell *donor);

@interface ApolloGTInjection : NSObject
@property (nonatomic, copy) NSString *anchorTitle;
@property (nonatomic, copy) NSString *sectionMarkerTitle;
@property (nonatomic, copy) ApolloGTRowFactory factory;
@property (nonatomic, copy) void (^onSelect)(UIViewController *vc); // nil = inert row
@end
@implementation ApolloGTInjection
@end

static NSMutableArray<BOOL (^)(UITableViewCell *)> *sGTHideMatchers;
static NSMutableArray<ApolloGTInjection *> *sGTInjections;

@interface ApolloGTNativeRowConfiguration : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) void (^configure)(UIViewController *vc, UITableViewCell *cell);
@end
@implementation ApolloGTNativeRowConfiguration
@end

static NSMutableArray<ApolloGTNativeRowConfiguration *> *sGTNativeRowConfigurations;

void ApolloGeneralTableHideRows(BOOL (^cellMatcher)(UITableViewCell *cell)) {
    if (!cellMatcher) return;
    if (!sGTHideMatchers) sGTHideMatchers = [NSMutableArray array];
    [sGTHideMatchers addObject:[cellMatcher copy]];
}

void ApolloGeneralTableInjectRow(NSString *anchorTitle,
                                 NSString *sectionMarkerTitle,
                                 ApolloGTRowFactory factory) {
    ApolloGeneralTableInjectSelectableRow(anchorTitle, sectionMarkerTitle, factory, nil);
}

void ApolloGeneralTableInjectSelectableRow(NSString *anchorTitle,
                                           NSString *sectionMarkerTitle,
                                           ApolloGTRowFactory factory,
                                           void (^onSelect)(UIViewController *vc)) {
    if (!anchorTitle || !factory) return;
    ApolloGTInjection *inj = [ApolloGTInjection new];
    inj.anchorTitle = anchorTitle;
    inj.sectionMarkerTitle = sectionMarkerTitle;
    inj.factory = factory;
    inj.onSelect = onSelect;
    if (!sGTInjections) sGTInjections = [NSMutableArray array];
    [sGTInjections addObject:inj];
}

void ApolloGeneralTableConfigureNativeRow(NSString *title,
                                          void (^configure)(UIViewController *vc,
                                                            UITableViewCell *cell)) {
    if (!title || !configure) return;
    ApolloGTNativeRowConfiguration *configuration = [ApolloGTNativeRowConfiguration new];
    configuration.title = title;
    configuration.configure = configure;
    if (!sGTNativeRowConfigurations) sGTNativeRowConfigurations = [NSMutableArray array];
    [sGTNativeRowConfigurations addObject:configuration];
}

// MARK: - shared title matching

static BOOL ApolloGTStringMatchesTitle(NSString *text, NSString *title) {
    if (![text isKindOfClass:[NSString class]]) return NO;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return [trimmed isEqualToString:title];
}

static BOOL ApolloGTLabelTreeHasTitle(UIView *view, NSString *title, int depth) {
    if ([view isKindOfClass:[UILabel class]] && ApolloGTStringMatchesTitle(((UILabel *)view).text, title)) {
        return YES;
    }
    if (depth < 6) {
        for (UIView *sub in view.subviews) {
            if (ApolloGTLabelTreeHasTitle(sub, title, depth + 1)) return YES;
        }
    }
    return NO;
}

BOOL ApolloGeneralTableCellHasTitle(UITableViewCell *cell, NSString *title) {
    if (!cell || !title) return NO;
    if (ApolloGTStringMatchesTitle(cell.textLabel.text, title)) return YES;
    return ApolloGTLabelTreeHasTitle(cell.contentView, title, 0);
}

static void ApolloGTApplyNativeRowConfigurations(UIViewController *vc, UITableViewCell *cell) {
    if (!vc || !cell) return;
    for (ApolloGTNativeRowConfiguration *configuration in sGTNativeRowConfigurations) {
        if (ApolloGeneralTableCellHasTitle(cell, configuration.title)) {
            configuration.configure(vc, cell);
        }
    }
}

// MARK: - map state

// Injected slots are encoded as -(injectionIndex + 1); values >= 0 are native rows.
@interface ApolloGTMapState : NSObject
@property (nonatomic, strong) NSDictionary<NSNumber *, NSArray<NSNumber *> *> *displayRowsBySection;
@property (nonatomic, strong) NSDictionary<NSNumber *, NSIndexPath *> *anchorsByInjection;
@end
@implementation ApolloGTMapState
@end

typedef NS_ENUM(int, ApolloGTKind) {
    ApolloGTKindPass = 0,      // unmodified section, or a stale path outside the map: use unchanged
    ApolloGTKindNative = 1,    // *outNative is the translated native path
    ApolloGTKindInjected = 2,  // *outInjection is the injection registry index
};

static ApolloGTKind ApolloGTDisplayToNative(ApolloGTMapState *map, NSIndexPath *display,
                                            NSIndexPath *__strong *outNative, NSUInteger *outInjection) {
    NSArray<NSNumber *> *rows = map.displayRowsBySection[@(display.section)];
    if (!rows) return ApolloGTKindPass;
    if (display.row < 0 || (NSUInteger)display.row >= rows.count) return ApolloGTKindPass;
    NSInteger v = rows[(NSUInteger)display.row].integerValue;
    if (v < 0) {
        if (outInjection) *outInjection = (NSUInteger)(-v - 1);
        return ApolloGTKindInjected;
    }
    if (outNative) *outNative = [NSIndexPath indexPathForRow:v inSection:display.section];
    return ApolloGTKindNative;
}

// For delegate methods that RETURN an index path (Eureka echoes back the native
// path we passed in). Hidden rows have no display slot, but they also can't come
// back here: only paths this module fed in can be echoed.
static NSIndexPath *ApolloGTNativeToDisplay(ApolloGTMapState *map, NSIndexPath *native) {
    NSArray<NSNumber *> *rows = map.displayRowsBySection[@(native.section)];
    if (!rows) return native;
    for (NSUInteger i = 0; i < rows.count; i++) {
        if (rows[i].integerValue == native.row) {
            return [NSIndexPath indexPathForRow:(NSInteger)i inSection:native.section];
        }
    }
    return native;
}

// MARK: - the delegate/dataSource proxy

static void ApolloGTZeroReturn(NSInvocation *inv) {
    NSUInteger len = inv.methodSignature.methodReturnLength;
    if (len == 0) return;
    uint8_t zeros[256] = {0};
    if (len <= sizeof(zeros)) [inv setReturnValue:zeros];
}

@interface ApolloGTProxy : NSProxy {
    __weak UIViewController *_vc;
    __weak UITableView *_tableView;
    ApolloGTMapState *_map;
}
+ (instancetype)proxyForVC:(UIViewController *)vc tableView:(UITableView *)tv map:(ApolloGTMapState *)map;
- (void)reassertOnTable;
- (ApolloGTMapState *)gtMap;
@end

@implementation ApolloGTProxy

+ (instancetype)proxyForVC:(UIViewController *)vc tableView:(UITableView *)tv map:(ApolloGTMapState *)map {
    ApolloGTProxy *proxy = [self alloc];   // NSProxy has no -init
    proxy->_vc = vc;
    proxy->_tableView = tv;
    proxy->_map = map;
    return proxy;
}

- (ApolloGTMapState *)gtMap {
    return _map;
}

- (void)reassertOnTable {
    UITableView *tv = _tableView;
    if (!tv) return;
    if (tv.delegate != (id)self || tv.dataSource != (id)self) {
        // Should never fire (Eureka only nil-guards in viewDidLoad — see header);
        // loud log so a future binary change is diagnosable instead of silent.
        ApolloLog(@"[GeneralTable] table delegate was externally reassigned — re-installing proxy");
        tv.delegate = (id<UITableViewDelegate>)self;
        tv.dataSource = (id<UITableViewDataSource>)self;
        [tv reloadData];
    }
}

// Transparency: the proxy answers capability questions exactly as the VC would,
// so UIKit's delegate-flag caching sees the native response surface.
- (BOOL)respondsToSelector:(SEL)sel {
    UIViewController *vc = _vc;
    return vc ? [vc respondsToSelector:sel] : NO;
}

- (BOOL)conformsToProtocol:(Protocol *)protocol {
    UIViewController *vc = _vc;
    return vc ? [vc conformsToProtocol:protocol] : NO;
}

- (BOOL)isKindOfClass:(Class)cls {
    UIViewController *vc = _vc;
    return vc ? [vc isKindOfClass:cls] : NO;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    UIViewController *vc = _vc;
    NSMethodSignature *sig = vc ? [vc methodSignatureForSelector:sel] : nil;
    return sig ?: [NSMethodSignature signatureWithObjCTypes:"v@:"];
}

// The injected display slot never reaches Eureka. Policy:
//   - cellForRow: build via the registered factory (donor = the live anchor cell,
//     fetched through the VC's REAL — never swizzled — dataSource method);
//   - height / estimatedHeight: borrow the anchor's answer (same visual row class);
//   - willSelect: nil (the switch is the control; the row itself is inert);
//   - didSelect: deselect and swallow (unreachable given willSelect, defensive);
//   - anything else: a zeroed return (NO / 0 / nil) and no forward.
- (void)handleInjectedSlot:(NSInvocation *)inv vc:(UIViewController *)vc
                 injection:(NSUInteger)injectionIdx displayPath:(NSIndexPath *)displayPath {
    SEL sel = inv.selector;
    NSIndexPath *anchor = _map.anchorsByInjection[@(injectionIdx)];

    if (sel == @selector(tableView:cellForRowAtIndexPath:)) {
        UITableView *tv = _tableView;
        UITableViewCell *donor = nil;
        if (anchor && tv) {
            donor = ((UITableViewCell *(*)(id, SEL, UITableView *, NSIndexPath *))objc_msgSend)(
                vc, @selector(tableView:cellForRowAtIndexPath:), tv, anchor);
        }
        ApolloGTInjection *inj = (injectionIdx < sGTInjections.count) ? sGTInjections[injectionIdx] : nil;
        UITableViewCell *cell = inj ? inj.factory(vc, donor) : nil;
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        // setReturnValue: does not retain — pin the cell to the autorelease pool
        // (retain + autorelease, net neutral) so it outlives this scope even when
        // a factory returns an otherwise-unowned cell (review finding: the
        // fail-soft branch above would hand UIKit a dangling pointer without this).
        CFAutorelease(CFBridgingRetain(cell));
        [inv setReturnValue:&cell];
        return;
    }
    if (anchor && (sel == @selector(tableView:heightForRowAtIndexPath:) ||
                   sel == @selector(tableView:estimatedHeightForRowAtIndexPath:))) {
        [inv setArgument:&anchor atIndex:3];
        [inv invokeWithTarget:vc];
        return;
    }
    if (sel == @selector(tableView:willSelectRowAtIndexPath:)) {
        // Selectable injections keep the tap; inert (switch) rows return nil.
        ApolloGTInjection *inj = (injectionIdx < sGTInjections.count) ? sGTInjections[injectionIdx] : nil;
        id ret = inj.onSelect ? displayPath : nil;
        if (ret) CFAutorelease(CFBridgingRetain(ret));
        [inv setReturnValue:&ret];
        return;
    }
    if (sel == @selector(tableView:didSelectRowAtIndexPath:)) {
        [_tableView deselectRowAtIndexPath:displayPath animated:YES];
        ApolloGTInjection *inj = (injectionIdx < sGTInjections.count) ? sGTInjections[injectionIdx] : nil;
        if (inj.onSelect) inj.onSelect(vc);
        return;
    }
    ApolloGTZeroReturn(inv);
}

- (void)forwardInvocation:(NSInvocation *)inv {
    UIViewController *vc = _vc;
    if (!vc) {
        ApolloGTZeroReturn(inv);
        return;
    }
    SEL sel = inv.selector;

    // Row counts come straight from the map for modified sections.
    if (sel == @selector(tableView:numberOfRowsInSection:)) {
        NSInteger section = 0;
        [inv getArgument:&section atIndex:3];
        NSArray *rows = _map.displayRowsBySection[@(section)];
        if (rows) {
            NSInteger n = (NSInteger)rows.count;
            [inv setReturnValue:&n];
            return;
        }
        [inv invokeWithTarget:vc];
        return;
    }

    // Generic translation: every NSIndexPath argument goes display -> native.
    // Signatures can't distinguish NSIndexPath from other object args, so each
    // object arg is class-checked at runtime; the translated paths stay alive as
    // strong locals across the synchronous invoke.
    NSMethodSignature *sig = inv.methodSignature;
    NSUInteger nargs = sig.numberOfArguments;
    // Keeps translated paths alive across the invoke (setArgument: does not
    // retain); precise lifetime pins the array to end of scope so ARC can't
    // release it early.
    __attribute__((objc_precise_lifetime)) NSMutableArray *pinned = nil;
    NSUInteger injectionIdx = NSNotFound;
    NSIndexPath *injectedDisplayPath = nil;
    for (NSUInteger i = 2; i < nargs; i++) {
        const char *type = [sig getArgumentTypeAtIndex:i];
        if (type[0] != '@') continue;
        __unsafe_unretained id arg = nil;
        [inv getArgument:&arg atIndex:i];
        if (![arg isKindOfClass:[NSIndexPath class]]) continue;
        NSIndexPath *native = nil;
        NSUInteger inj = NSNotFound;
        ApolloGTKind kind = ApolloGTDisplayToNative(_map, (NSIndexPath *)arg, &native, &inj);
        if (kind == ApolloGTKindNative) {
            if (!pinned) pinned = [NSMutableArray arrayWithCapacity:2];
            [pinned addObject:native];
            [inv setArgument:&native atIndex:i];
        } else if (kind == ApolloGTKindInjected) {
            injectionIdx = inj;
            injectedDisplayPath = (NSIndexPath *)arg;
        }
    }

    if (injectionIdx != NSNotFound) {
        [self handleInjectedSlot:inv vc:vc injection:injectionIdx displayPath:injectedDisplayPath];
        return;
    }

    [inv invokeWithTarget:vc];

    // Native rows pass through Eureka unchanged, then receive any registered
    // state-only configuration. Applying after every dequeue makes off-screen
    // rows agree as soon as they scroll into view without rebuilding the form.
    if (sel == @selector(tableView:cellForRowAtIndexPath:)) {
        __unsafe_unretained UITableViewCell *cell = nil;
        [inv getReturnValue:&cell];
        ApolloGTApplyNativeRowConfigurations(vc, cell);
    }

    // Echoed index paths (willSelect, targetIndexPathForMove, ...) go back
    // native -> display. Pin the replacement to the pool: setReturnValue: does
    // not retain, and "small NSIndexPaths are tagged (immortal) pointers" is a
    // Foundation implementation detail, not a contract (review finding).
    if (sig.methodReturnType[0] == '@') {
        __unsafe_unretained id ret = nil;
        [inv getReturnValue:&ret];
        if ([ret isKindOfClass:[NSIndexPath class]]) {
            NSIndexPath *display = ApolloGTNativeToDisplay(_map, (NSIndexPath *)ret);
            if (display != (id)ret) {
                CFAutorelease(CFBridgingRetain(display));
                [inv setReturnValue:&display];
            }
        }
    }
}

@end

// MARK: - scan + install

static const void *kApolloGTProxyKey = &kApolloGTProxyKey;
static __weak UIViewController *sApolloGTActiveVC = nil;

UIViewController *ApolloGeneralTableActiveVC(void) {
    return sApolloGTActiveVC;
}

static UITableView *ApolloGTFindTable(UIViewController *vc) {
    // Eureka stores the table in a `tableView` ivar; subview walk as fallback
    // (same pattern as ApolloSettings.xm's About injection).
    Class cls = object_getClass(vc);
    while (cls) {
        Ivar iv = class_getInstanceVariable(cls, "tableView");
        if (iv) {
            id tv = object_getIvar(vc, iv);
            if ([tv isKindOfClass:[UITableView class]]) return (UITableView *)tv;
            break;
        }
        cls = class_getSuperclass(cls);
    }
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:vc.view];
    while (stack.count) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        if ([v isKindOfClass:[UITableView class]]) return (UITableView *)v;
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
    return nil;
}

void ApolloGeneralTableRefreshNativeRowConfigurations(void) {
    UIViewController *vc = sApolloGTActiveVC;
    if (!vc || !vc.viewIfLoaded.window) return;
    UITableView *tv = ApolloGTFindTable(vc);
    if (!tv) return;
    for (NSIndexPath *indexPath in tv.indexPathsForVisibleRows) {
        ApolloGTApplyNativeRowConfigurations(vc, [tv cellForRowAtIndexPath:indexPath]);
    }
}

UITableViewCell *ApolloGeneralTableVisibleCellForTitle(UIViewController *vc, NSString *title) {
    if (!vc || !title || !vc.viewIfLoaded.window) return nil;
    UITableView *tv = ApolloGTFindTable(vc);
    if (!tv) return nil;
    // When the title is a registered injection's anchor, resolve through the
    // scan-time anchor — it was disambiguated by section there (e.g. "Remember
    // Subreddit Sort" exists in BOTH the Posts and Comments sections, and a
    // blind first-match visible scan can hit the wrong one — review finding).
    // For an anchor title, never fall through to the blind scan: a nil return
    // (row off-screen) is safer than confidently returning the wrong section's
    // row to a caller that will flip its switch.
    BOOL titleIsAnchor = NO;
    ApolloGTMapState *map = [(ApolloGTProxy *)objc_getAssociatedObject(vc, kApolloGTProxyKey) gtMap];
    for (NSUInteger i = 0; i < sGTInjections.count; i++) {
        if (![sGTInjections[i].anchorTitle isEqualToString:title]) continue;
        titleIsAnchor = YES;
        NSIndexPath *native = map.anchorsByInjection[@(i)];
        if (!native) continue;
        UITableViewCell *cell = [tv cellForRowAtIndexPath:ApolloGTNativeToDisplay(map, native)];
        if (cell) return cell;
    }
    if (titleIsAnchor) return nil;
    for (NSIndexPath *ip in tv.indexPathsForVisibleRows) {
        UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
        if (ApolloGeneralTableCellHasTitle(cell, title)) return cell;
    }
    return nil;
}

// One pass over the freshly built form: build every cell once (Eureka caches
// them per row anyway), run the hide matchers, resolve injection anchors, and
// emit display arrays for the sections that changed. The VC's real methods are
// called directly — nothing is interposed yet — so there is no re-entrancy to
// guard (the old sPPCSScanning flag is gone by construction).
static void ApolloGTScanAndInstall(UIViewController *vc) {
    if (objc_getAssociatedObject(vc, kApolloGTProxyKey)) return;
    if (sGTHideMatchers.count == 0 && sGTInjections.count == 0 &&
        sGTNativeRowConfigurations.count == 0) return;
    UITableView *tv = ApolloGTFindTable(vc);
    if (!tv) {
        ApolloLog(@"[GeneralTable] no table view found; leaving the screen native");
        return;
    }

    NSMutableDictionary<NSNumber *, NSArray<NSNumber *> *> *displayBySection = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSIndexPath *> *anchors = [NSMutableDictionary dictionary];
    id<UITableViewDataSource> ds = (id<UITableViewDataSource>)vc;
    @try {
        @autoreleasepool {
            NSInteger sections = [ds numberOfSectionsInTableView:tv];
            for (NSInteger s = 0; s < sections; s++) {
                NSInteger rowCount = [ds tableView:tv numberOfRowsInSection:s];
                NSMutableArray<UITableViewCell *> *cells = [NSMutableArray arrayWithCapacity:(NSUInteger)rowCount];
                for (NSInteger r = 0; r < rowCount; r++) {
                    UITableViewCell *cell = [ds tableView:tv
                                    cellForRowAtIndexPath:[NSIndexPath indexPathForRow:r inSection:s]];
                    ApolloGTApplyNativeRowConfigurations(vc, cell);
                    [cells addObject:cell ?: [UITableViewCell new]];
                }

                // Resolve injection anchors in this section (first match wins per
                // injection; multiple injections may share one anchor row).
                NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *injectionsByRow = [NSMutableDictionary dictionary];
                for (NSUInteger i = 0; i < sGTInjections.count; i++) {
                    if (anchors[@(i)]) continue;   // already anchored in an earlier section
                    ApolloGTInjection *inj = sGTInjections[i];
                    NSInteger anchorRow = NSNotFound;
                    BOOL hasMarker = (inj.sectionMarkerTitle == nil);
                    for (NSInteger r = 0; r < rowCount; r++) {
                        if (anchorRow == NSNotFound &&
                            ApolloGeneralTableCellHasTitle(cells[(NSUInteger)r], inj.anchorTitle)) {
                            anchorRow = r;
                        }
                        if (!hasMarker &&
                            ApolloGeneralTableCellHasTitle(cells[(NSUInteger)r], inj.sectionMarkerTitle)) {
                            hasMarker = YES;
                        }
                    }
                    if (anchorRow != NSNotFound && hasMarker) {
                        anchors[@(i)] = [NSIndexPath indexPathForRow:anchorRow inSection:s];
                        NSMutableArray *list = injectionsByRow[@(anchorRow)];
                        if (!list) { list = [NSMutableArray array]; injectionsByRow[@(anchorRow)] = list; }
                        [list addObject:@(i)];
                    }
                }

                // Emit the display array: natives minus hidden, injected markers
                // spliced right after their anchors.
                NSMutableArray<NSNumber *> *display = [NSMutableArray arrayWithCapacity:(NSUInteger)rowCount + 1];
                NSUInteger hidden = 0;
                NSUInteger injected = 0;
                for (NSInteger r = 0; r < rowCount; r++) {
                    BOOL hide = NO;
                    for (BOOL (^matcher)(UITableViewCell *) in sGTHideMatchers) {
                        if (matcher(cells[(NSUInteger)r])) { hide = YES; break; }
                    }
                    if (!hide) [display addObject:@(r)];
                    else hidden++;
                    for (NSNumber *inj in injectionsByRow[@(r)]) {
                        [display addObject:@(-(inj.integerValue + 1))];
                        injected++;
                    }
                }
                if (hidden > 0 || injected > 0) {
                    displayBySection[@(s)] = display;
                    ApolloLog(@"[GeneralTable] section %ld: %ld native rows -> %lu displayed (%lu hidden, %lu injected)",
                              (long)s, (long)rowCount, (unsigned long)display.count,
                              (unsigned long)hidden, (unsigned long)injected);
                }
            }
        }
    } @catch (NSException *e) {
        ApolloLog(@"[GeneralTable] scan threw (%@); leaving the screen native", e);
        return;
    }

    if (displayBySection.count == 0 && sGTNativeRowConfigurations.count == 0) {
        ApolloLog(@"[GeneralTable] nothing matched (no hides, no anchors); screen left native");
        return;
    }

    ApolloGTMapState *map = [ApolloGTMapState new];
    map.displayRowsBySection = displayBySection;
    map.anchorsByInjection = anchors;
    ApolloGTProxy *proxy = [ApolloGTProxy proxyForVC:vc tableView:tv map:map];
    objc_setAssociatedObject(vc, kApolloGTProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    tv.delegate = (id<UITableViewDelegate>)proxy;
    tv.dataSource = (id<UITableViewDataSource>)proxy;
    [tv reloadData];
}

// MARK: - hooks

%hook SettingsGeneralViewController

- (void)viewDidLoad {
    %orig;   // Eureka builds the form and claims the table's delegate/dataSource here
    sApolloGTActiveVC = self;
    ApolloGTScanAndInstall(self);
}

// The subclass implements viewDidLayoutSubviews (no viewWillAppear override
// exists to hook), so the defensive delegate re-assert lives here. A pointer
// compare per layout pass; the reinstall branch never runs in practice (see the
// file header) and this writes no layout inputs, so no layout-loop risk.
- (void)viewDidLayoutSubviews {
    %orig;
    ApolloGTProxy *proxy = objc_getAssociatedObject(self, kApolloGTProxyKey);
    [proxy reassertOnTable];
}

%end

%ctor {
    %init(SettingsGeneralViewController = objc_getClass("_TtC6Apollo29SettingsGeneralViewController"));
}
