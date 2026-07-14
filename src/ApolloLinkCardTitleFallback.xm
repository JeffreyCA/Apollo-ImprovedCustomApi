#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"

// =============================================================================
// MARK: - Overview
// =============================================================================
//
// Some link posts point at pages whose only machine-scraped <title> is a string
// of numbers — typically single-page apps (e.g. fifa.com match-center URLs)
// whose static HTML carries internal IDs ("285023 289273 400021448") instead of
// a human headline. Reddit stores that scraped title verbatim, and Apollo's
// LinkButtonNode renders it in the card's title slot, so the compact card shows
// a meaningless series of digits under the domain eyebrow.
//
// Fix: when the card's title contains no letters but does contain digits (the
// numeric-ID signature), replace it with a clean website name derived from the
// link's host (fifa.com -> "FIFA"). The domain eyebrow ("FIFA.COM") is left
// alone, mirroring the Safari/iMessage link-preview pattern (site name as the
// headline, full host underneath).
//
// Seam: LinkButtonNode has no ObjC method that sets the title (it is configured
// from pure Swift), so the title text is only reachable once the node lays out.
// -layoutSpecThatFits: runs on a background layout thread, where reading the
// titleTextNode's attributedText is safe but mutating it is not. So we read on
// the layout thread and, when the title is junk, apply the swap on the main
// thread (guarded by a per-node in-flight flag to avoid scheduling a pile-up of
// blocks across repeated layout passes). The replacement has letters, so the
// next layout pass no longer matches the junk test and nothing re-fires — the
// fix converges in one extra pass and re-applies cleanly on cell reuse.
//
// =============================================================================

static char kApolloLinkCardTitleFixInFlightKey;

// Junk-title detection and website-name derivation live in ApolloCommon so the
// native LinkButtonNode path (here) and ApolloInlineLinkPreviews' replacement
// cards share one implementation.
static NSString *ApolloLinkCardWebsiteNameForURLString(NSString *urlString) {
    if (urlString.length == 0) return nil;

    NSString *host = [NSURL URLWithString:urlString].host;
    if (host.length == 0) {
        // Tolerate a missing scheme (the urlTextNode fallback omits it).
        host = [NSURL URLWithString:[@"https://" stringByAppendingString:urlString]].host;
    }
    return ApolloWebsiteNameFromHost(host);
}

static id ApolloLinkCardTitleNode(id linkButtonNode) {
    if (!linkButtonNode) return nil;
    Ivar ivar = class_getInstanceVariable([linkButtonNode class], "titleTextNode");
    return ivar ? object_getIvar(linkButtonNode, ivar) : nil;
}

// Main-thread: re-resolve the node's current title + URL and, if still junk,
// swap in the website name. Re-resolving here (rather than trusting values
// captured on the layout thread) keeps the swap correct if the cell was reused
// for a different post between scheduling and running.
static void ApolloLinkCardApplyTitleFix(id linkButtonNode) {
    id titleNode = ApolloLinkCardTitleNode(linkButtonNode);
    if (!titleNode || ![titleNode respondsToSelector:@selector(attributedText)]) return;

    NSAttributedString *current = [titleNode attributedText];
    NSString *text = current.string;
    if (!ApolloIsJunkNumericTitle(text)) return;

    NSString *urlString = ApolloGetLinkButtonNodeURLString(linkButtonNode);
    NSString *name = ApolloLinkCardWebsiteNameForURLString(urlString);
    if (name.length == 0) return;

    // Preserve the title's existing typography (font, color, paragraph style).
    NSDictionary *attrs = current.length > 0 ? [current attributesAtIndex:0 effectiveRange:NULL] : nil;
    NSAttributedString *replacement = attrs
        ? [[NSAttributedString alloc] initWithString:name attributes:attrs]
        : [[NSAttributedString alloc] initWithString:name];

    if (![titleNode respondsToSelector:@selector(setAttributedText:)]) return;
    [titleNode setAttributedText:replacement];

    ApolloLog(@"[LinkCardTitle] junk title \"%@\" -> \"%@\" (%@)", text, name, urlString ?: @"(no url)");
}

// Layout thread: cheap junk pre-check (reads only), then defer the mutation to
// the main thread. The in-flight flag collapses repeated layout passes into a
// single scheduled fix.
static void ApolloLinkCardScheduleTitleFix(id linkButtonNode) {
    if (!linkButtonNode) return;

    NSNumber *inFlight = objc_getAssociatedObject(linkButtonNode, &kApolloLinkCardTitleFixInFlightKey);
    if ([inFlight boolValue]) return;

    id titleNode = ApolloLinkCardTitleNode(linkButtonNode);
    if (!titleNode || ![titleNode respondsToSelector:@selector(attributedText)]) return;
    if (!ApolloIsJunkNumericTitle([[titleNode attributedText] string])) return;

    objc_setAssociatedObject(linkButtonNode, &kApolloLinkCardTitleFixInFlightKey,
                             @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak id weakNode = linkButtonNode;
    dispatch_async(dispatch_get_main_queue(), ^{
        id node = weakNode;
        if (!node) return;
        objc_setAssociatedObject(node, &kApolloLinkCardTitleFixInFlightKey,
                                 @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @try {
            ApolloLinkCardApplyTitleFix(node);
        } @catch (__unused NSException *e) {}
    });
}

// ASSizeRange ABI for -layoutSpecThatFits: (matches Apollo's class dump).
struct CDStruct_90e057aa { CGSize min; CGSize max; };

%hook LinkButtonNode

- (id)layoutSpecThatFits:(struct CDStruct_90e057aa)constrainedSize {
    id spec = %orig;
    @try {
        ApolloLinkCardScheduleTitleFix(self);
    } @catch (__unused NSException *e) {}
    return spec;
}

%end

// =============================================================================
// MARK: - Constructor
// =============================================================================

%ctor {
    Class linkButtonNodeClass = objc_getClass("_TtC6Apollo14LinkButtonNode");

    ApolloLog(@"[LinkCardTitle] ctor: LinkButtonNode=%p", (void *)linkButtonNodeClass);

    if (!linkButtonNodeClass) {
        ApolloLog(@"[LinkCardTitle] ctor: LinkButtonNode class not found — skipping hook");
        return;
    }

    %init(LinkButtonNode = linkButtonNodeClass);

    ApolloLog(@"[LinkCardTitle] ctor: hook installed");
}
