#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

// MARK: - Scroll Edge Effect Style (Liquid Glass, iOS 26+)
//
// iOS 26 introduced UIScrollView.topEdgeEffect/bottomEdgeEffect, a glass blur
// rendered where content scrolls under the nav/tab bars. iOS 26 defaults to a
// soft gradient blur; iOS 27 betas default to a hard cutoff with a dividing
// line, which some users find jarring. This lets users override the style
// (or hide the effect entirely) for Apollo's scrolling surfaces.
//
// UIScrollEdgeEffect/UIScrollEdgeEffectStyle are public iOS 26 SDK classes,
// but referencing them directly would create a hard class reference that
// could fail to bind on the pre-26 devices this tweak still targets. Access
// everything defensively via objc_getClass/objc_msgSend, mirroring the
// pattern used for other iOS 26-only APIs (see ApolloNativeActionMenus.xm).

static NSString *const ApolloScrollEdgeEffectStyleChangedNotification = @"ApolloScrollEdgeEffectStyleChangedNotification";
static char kApolloScrollEdgeEffectForcedHiddenKey;

static id ApolloScrollEdgeEffectStyleObjectForMode(NSInteger mode) {
    Class styleClass = objc_getClass("UIScrollEdgeEffectStyle");
    if (!styleClass) return nil;

    SEL selector;
    switch (mode) {
        case ApolloScrollEdgeEffectStyleSoft: selector = NSSelectorFromString(@"softStyle"); break;
        case ApolloScrollEdgeEffectStyleHard: selector = NSSelectorFromString(@"hardStyle"); break;
        default: selector = NSSelectorFromString(@"automaticStyle"); break;
    }
    if (![styleClass respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(styleClass, selector);
}

static BOOL sLoggedScrollEdgeEffectDiagnostics = NO;
static BOOL sLoggedScrollEdgeEffectSetterOverride = NO;

// Logos otherwise emits a compile-time UIScrollEdgeEffect type reference,
// which is availability-annotated for iOS 26 even though this module resolves
// the class dynamically. Hook an unannotated alias and bind it only when the
// runtime class exists so iOS 14-25 retain no hard dependency or warnings.
@interface ApolloRuntimeScrollEdgeEffect : NSObject
@end

static void ApolloApplyScrollEdgeEffectToEdge(UIScrollView *scrollView, SEL edgeSelector, NSInteger mode) {
    if (![scrollView respondsToSelector:edgeSelector]) return;
    id effect = ((id (*)(id, SEL))objc_msgSend)(scrollView, edgeSelector);
    if (!effect) return;

    SEL setHiddenSelector = NSSelectorFromString(@"setHidden:");
    BOOL hasSetHidden = [effect respondsToSelector:setHiddenSelector];
    if (hasSetHidden) {
        if (mode == ApolloScrollEdgeEffectStyleHidden) {
            // Remember only the visibility changes made by this feature. When the
            // user switches away from Hidden, restore those effects without
            // un-hiding edges that UIKit intentionally keeps disabled.
            objc_setAssociatedObject(effect, &kApolloScrollEdgeEffectForcedHiddenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ((void (*)(id, SEL, BOOL))objc_msgSend)(effect, setHiddenSelector, YES);
        } else if (objc_getAssociatedObject(effect, &kApolloScrollEdgeEffectForcedHiddenKey)) {
            objc_setAssociatedObject(effect, &kApolloScrollEdgeEffectForcedHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ((void (*)(id, SEL, BOOL))objc_msgSend)(effect, setHiddenSelector, NO);
        }
    }

    SEL setStyleSelector = NSSelectorFromString(@"setStyle:");
    id style = ApolloScrollEdgeEffectStyleObjectForMode(mode);
    BOOL hasSetStyle = (style != nil) && [effect respondsToSelector:setStyleSelector];
    if (hasSetStyle) {
        ((void (*)(id, SEL, id))objc_msgSend)(effect, setStyleSelector, style);
    }

    if (!sLoggedScrollEdgeEffectDiagnostics) {
        sLoggedScrollEdgeEffectDiagnostics = YES;
        ApolloLog(@"[ScrollEdgeEffect] applied mode=%ld effect=%@ setHidden=%d style=%@ setStyle=%d on %@",
                  (long)mode, effect, hasSetHidden, style, hasSetStyle, scrollView);
    }
}

// Declared in ApolloState.h; called from UIScrollView's didMoveToWindow hook in
// ApolloAutoHideTabBar.xm (a second %hook UIScrollView didMoveToWindow here would be a
// duplicate symbol that the Logos internal generator silently drops).
void ApolloApplyScrollEdgeEffectStyle(UIScrollView *scrollView) {
    if (!IsLiquidGlass()) return;

    NSInteger mode = sScrollEdgeEffectStyle;
    NSArray<NSString *> *edgeSelectors = @[
        @"topEdgeEffect",
        @"leftEdgeEffect",
        @"bottomEdgeEffect",
        @"rightEdgeEffect",
    ];
    for (NSString *selectorName in edgeSelectors) {
        ApolloApplyScrollEdgeEffectToEdge(scrollView, NSSelectorFromString(selectorName), mode);
    }
}

static void ApolloApplyScrollEdgeEffectStyleToViewTree(UIView *view) {
    if ([view isKindOfClass:[UIScrollView class]]) {
        ApolloApplyScrollEdgeEffectStyle((UIScrollView *)view);
    }
    for (UIView *subview in view.subviews) {
        ApolloApplyScrollEdgeEffectStyleToViewTree(subview);
    }
}

void ApolloApplyScrollEdgeEffectStyleToViewController(UIViewController *viewController) {
    if (!IsLiquidGlass() || !viewController.isViewLoaded) return;
    ApolloApplyScrollEdgeEffectStyleToViewTree(viewController.view);
}

static void ApolloApplyScrollEdgeEffectStyleToAllScrollViews(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        ApolloApplyScrollEdgeEffectStyleToViewTree(window);
    }
}

// A one-shot UIScrollView lifecycle update is not sufficient on iOS 27. UIKit
// configures some edge effects after didMoveToWindow and may later restore its
// new hard default while navigation chrome changes. SwiftUI solves this through
// an inherited environment value on NavigationStack; Apollo is UIKit, so the
// equivalent app-wide enforcement point is UIScrollEdgeEffect's style setter.
// This also covers scroll views created after the setting changes.
%group ApolloScrollEdgeEffectRuntimeHooks

%hook ApolloRuntimeScrollEdgeEffect

- (void)setStyle:(id)style {
    NSInteger mode = sScrollEdgeEffectStyle;
    id selectedStyle = style;
    if (IsLiquidGlass() && (mode == ApolloScrollEdgeEffectStyleSoft || mode == ApolloScrollEdgeEffectStyleHard)) {
        selectedStyle = ApolloScrollEdgeEffectStyleObjectForMode(mode) ?: style;
        if (!sLoggedScrollEdgeEffectSetterOverride) {
            sLoggedScrollEdgeEffectSetterOverride = YES;
            ApolloLog(@"[ScrollEdgeEffect] enforcing mode=%ld for UIKit edge-effect updates proposed=%@ selected=%@",
                      (long)mode, style, selectedStyle);
        }
    }
    %orig(selectedStyle);
}

- (void)setHidden:(BOOL)hidden {
    if (IsLiquidGlass() && sScrollEdgeEffectStyle == ApolloScrollEdgeEffectStyleHidden) {
        objc_setAssociatedObject(self, &kApolloScrollEdgeEffectForcedHiddenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(YES);
        return;
    }
    %orig(hidden);
}

%end

%end

%ctor {
    Class edgeEffectClass = objc_getClass("UIScrollEdgeEffect");
    if (edgeEffectClass) {
        %init(ApolloScrollEdgeEffectRuntimeHooks,
              ApolloRuntimeScrollEdgeEffect = edgeEffectClass);
    }
    ApolloLog(@"[ScrollEdgeEffect] module loaded, mode=%ld liquidGlass=%d", (long)sScrollEdgeEffectStyle, IsLiquidGlass());
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloScrollEdgeEffectStyleChangedNotification
                                                       object:nil
                                                        queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(__unused NSNotification *notification) {
        ApolloApplyScrollEdgeEffectStyleToAllScrollViews();
    }];
}
