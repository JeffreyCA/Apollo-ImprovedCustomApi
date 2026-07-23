#import "ApolloThemeRuntime.h"
#import "ApolloThemeStore.h"
#import "ApolloThemeCompiler.h"
#import "ApolloThemeGalleryCatalog.h"
#import "ApolloCommon.h"
#import <CoreText/CoreText.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>

@class ASDisplayNode;

@interface ASDisplayNode : NSObject
- (ASDisplayNode *)supernode;
@property (nonatomic, strong) UIColor *backgroundColor;
@end

@interface ASTextNode : ASDisplayNode
@property (nonatomic, copy) NSAttributedString *attributedText;
@end

@interface ASTextNode2 : ASTextNode
@end

@interface ASButtonNode : ASDisplayNode
- (void)setAttributedTitle:(NSAttributedString *)title forState:(NSUInteger)state;
- (void)setTitle:(NSString *)title withFont:(UIFont *)font withColor:(UIColor *)color forState:(NSUInteger)state;
- (void)setTitle:(NSString *)title withFont:(UIFont *)font withColor:(UIColor *)color withShadowColor:(UIColor *)shadowColor withShadowOffset:(CGSize)shadowOffset forState:(NSUInteger)state;
@end

@interface ASImageNode : ASDisplayNode
- (void)setImageModificationBlock:(id)block;
@end

@interface _UINavigationBarTitleControl : UIControl
@end

// Apollo's feed/subreddit search-field pill. A plain UITextField whose
// background Apollo builds from the SAME literal RGB constant it uses for
// hairline row separators (0xC7C7CC light / 0x646466 dark — see
// docs/theme-builder-RE.md's "separator" role: "row separators + search/input
// field fills"). kSeparatorEntries below intentionally remaps that constant
// globally so the Advanced "Separators" override reaches real divider lines,
// but that means it also recolors this field's fill, since both draw from the
// identical constant and can't be told apart by RGB alone. Given its own sink
// (below) so it lands on "Raised" (inset controls/elevated panels) instead.
@interface _TtC6Apollo24ApolloSearchBarTextField : UITextField
@end

// Apollo inserts these Texture cells between comment sections. Their internal
// separatorNode is painted from Apollo's shared "gray" role (the same role as
// muted text), rather than from its separator role, so RGB remapping alone
// cannot distinguish the divider from a genuine muted label.
@interface _TtC6Apollo21ThinSeparatorCellNode : ASDisplayNode
@end

// The post header above a comment thread owns two more explicit Texture
// hairlines: one above the action quick bar and one above the comments list.
@interface _TtC6Apollo22CommentsHeaderCellNode : ASDisplayNode
@end

// ===========================================================================
// Runtime state
// ===========================================================================

static volatile bool sEnabled = false;
// Active theme's app-wide font. Read from any thread (Texture builds
// attributed strings off-main); a single enum-width store is atomic on arm64,
// matching the sEnabled convention.
static volatile ApolloThemeFont sFontChoices[ApolloThemeModeCount] = {
    ApolloThemeFontSystem, ApolloThemeFontSystem
};
// Mirrors kApolloThemeVoteArrowsAccentKey on the active theme — see the
// DualStateButtonNode sink below for what this actually recolors.
static volatile bool sVoteArrowsAccent[ApolloThemeModeCount] = { false, false };
static uint32_t sTokens[ApolloThemeModeCount][ApolloThemeTokenCount];
static uint64_t sEpoch = 0; // bumped whenever sTokens or sEnabled changes
static os_unfair_lock sLock = OS_UNFAIR_LOCK_INIT;
static bool sDebugLogging = false;
static uintptr_t sApolloStart = 0;
static uintptr_t sApolloEnd = 0;
static uintptr_t sTweakStart = 0;
static uintptr_t sTweakEnd = 0;

// Apply UIKit-owned colours at the view sink as well as at UIColor creation.
// UITableView creates its default hairline colour inside UIKit, so the
// caller-gated UIColor.separatorColor hook deliberately cannot see it. The
// Search tab likewise uses a stock UISearchBar (not ApolloSearchBarTextField),
// whose input fill is assembled inside UIKit from its own palette.
static void ApplyThemeTableSeparator(UITableView *tableView) {
    if (!sEnabled || !tableView) return;
    UIColor *separator = ApolloThemeRuntimeColor(ApolloThemeTokenSeparator);
    if (separator && ![tableView.separatorColor isEqual:separator]) {
        tableView.separatorColor = separator;
    }
}

static void ApplyThemeSearchFieldBackground(UISearchBar *searchBar) {
    if (!sEnabled || !searchBar) return;
    UIColor *raised = ApolloThemeRuntimeColor(ApolloThemeTokenTertiaryBackground);
    UITextField *field = searchBar.searchTextField;
    if (raised && field && ![field.backgroundColor isEqual:raised]) {
        field.backgroundColor = raised;
    }
}

static void ApplyThemeThinSeparatorNode(_TtC6Apollo21ThinSeparatorCellNode *cellNode) {
    if (!sEnabled || !cellNode) return;
    Ivar separatorIvar = class_getInstanceVariable(object_getClass(cellNode), "separatorNode");
    ASDisplayNode *separatorNode = separatorIvar ? object_getIvar(cellNode, separatorIvar) : nil;
    UIColor *separator = ApolloThemeRuntimeColor(ApolloThemeTokenSeparator);
    if (separatorNode && separator) separatorNode.backgroundColor = separator;
}

static ASDisplayNode *ApolloThemeObjectIvar(id owner, const char *name) {
    if (!owner || !name) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(owner), name);
    return ivar ? object_getIvar(owner, ivar) : nil;
}

static void ApplyThemeCommentsHeaderSeparators(_TtC6Apollo22CommentsHeaderCellNode *headerNode) {
    if (!sEnabled || !headerNode) return;
    UIColor *separator = ApolloThemeRuntimeColor(ApolloThemeTokenSeparator);
    if (!separator) return;

    ASDisplayNode *quickBarSeparator = ApolloThemeObjectIvar(headerNode, "quickBarSeparatorNode");
    ASDisplayNode *commentsSeparator = ApolloThemeObjectIvar(headerNode, "commentsSeparatorNode");
    if (quickBarSeparator) quickBarSeparator.backgroundColor = separator;
    if (commentsSeparator) commentsSeparator.backgroundColor = separator;
}

static void RecordImageBounds(const struct mach_header *mh, intptr_t slide, uintptr_t *outStart, uintptr_t *outEnd) {
    if (!mh || mh->magic != MH_MAGIC_64) return;

    uintptr_t start = (uintptr_t)mh;
    uintptr_t end = start;
    const uint8_t *p = (const uint8_t *)mh + sizeof(struct mach_header_64);
    const struct mach_header_64 *mh64 = (const struct mach_header_64 *)mh;
    for (uint32_t c = 0; c < mh64->ncmds; c++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, SEG_PAGEZERO) != 0) {
                uintptr_t segEnd = (uintptr_t)((intptr_t)seg->vmaddr + slide) + (uintptr_t)seg->vmsize;
                if (segEnd > end) end = segEnd;
            }
        }
        p += lc->cmdsize;
    }

    *outStart = start;
    *outEnd = (end > start) ? end : (start + 0x8000000);
}

static void FindRuntimeImages(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;

        const struct mach_header *mh = _dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        size_t len = strlen(name);
        if (len >= 7 && strcmp(name + len - 7, "/Apollo") == 0) {
            RecordImageBounds(mh, slide, &sApolloStart, &sApolloEnd);
        } else if (strstr(name, "ApolloReborn")) {
            RecordImageBounds(mh, slide, &sTweakStart, &sTweakEnd);
        }
    }
}

static inline BOOL CallerMayUseThemeRuntime(uintptr_t caller) {
    if (sApolloStart && caller >= sApolloStart && caller < sApolloEnd) return YES;
    if (sTweakStart && caller >= sTweakStart && caller < sTweakEnd) return YES;
    return NO;
}

static inline UIColor *SemColor(ApolloThemeToken t, uintptr_t caller) {
    if (!CallerMayUseThemeRuntime(caller)) return nil;
    return ApolloThemeRuntimeColor(t);
}
// Repaint strategy. The window-style flip is the PRIMARY, proven-safe mechanism:
// it toggles each window's overrideUserInterfaceStyle for one runloop turn,
// which drives a trait-change cascade that re-resolves our dynamic token colours
// app-wide. It is self-contained (touches only our own override) and cannot put
// Apollo's theme system into an inconsistent state.
//
// Posting Apollo's own ApolloSpecificThemeChanged / CommentsColorThemeChanged is
// DISABLED by default: although Apollo's picker posts them, it does so only as
// the tail of a full apply sequence that first updates the Combine Published
// theme value. Posting them standalone made Apollo's observers (ThemeableWindow,
// retained CommentsViewControllers) repaint against state we never set up, which
// crashed on the post-apply repaint. Kept behind a flag for future use.
// Repaint via Apollo's own theme-change notifications (flash-free, repaints live).
// The earlier crash was the UIColor value-constructor over-release, NOT the
// notifications, so these are safe now that the constructors are fixed. The
// window-style flip is ON by default because donor-constructor remaps produce
// static colours; without a trait cascade, already-created views can keep stale
// background/card colours until they are recreated naturally.
static bool sLegacyRepaint = true;
static bool sPostNativeNotifications = true;

// Re-entrancy guard: while a dynamic-colour provider is building a concrete
// colour for a token, the UIColor constructor hook must not re-map it.
static __thread int sBypassHook = 0;

// ---------------------------------------------------------------------------
// Theme font (per-theme app-wide font, spec: 4 system designs only)
// ---------------------------------------------------------------------------

// Guard against UIKit re-entering a hooked UIFont factory while we re-derive
// a font through fontWithDescriptor:size:.
static __thread int sFontBypass = 0;

static ApolloThemeMode CurrentRuntimeMode(void) {
    return UITraitCollection.currentTraitCollection.userInterfaceStyle == UIUserInterfaceStyleDark
        ? ApolloThemeModeDark : ApolloThemeModeLight;
}

static ApolloThemeFont CurrentFontChoice(void) {
    return sFontChoices[CurrentRuntimeMode()];
}

static BOOL ClassNameLooksApolloOwned(const char *name);
static BOOL TextSinkMayUseTheme(id object, uintptr_t caller);

// Pinned views carry a font the tweak chose deliberately in a SPECIFIC design
// (the editor's font-picker tiles and preview rows must each render their own
// design, not the active theme's). Both the sink hooks and the refresh walk
// skip them.
static const void *kApolloThemeFontPinnedKey = &kApolloThemeFontPinnedKey;

void ApolloThemeRuntimeSetFontPinned(id view, BOOL pinned) {
    if (!view) return;
    objc_setAssociatedObject(view, kApolloThemeFontPinnedKey,
                             pinned ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL FontPinned(id view) {
    return view && [objc_getAssociatedObject(view, kApolloThemeFontPinnedKey) boolValue];
}

// Re-derive a system font in the active theme's design. Caller-gated like the
// colour hooks: only Apollo's own code (and the tweak) get themed fonts, so
// UIKit-built chrome (system alerts, share sheet, keyboard) keeps SF Pro —
// which also keeps the wide SF Mono design out of fixed-width system chrome.
static UIFont *ThemedFont(UIFont *font, uintptr_t caller) {
    ApolloThemeFont choice = CurrentFontChoice();
    if (!sEnabled || choice == ApolloThemeFontSystem || !font) return font;
    if (sFontBypass) return font;
    if (!CallerMayUseThemeRuntime(caller)) return font;
    sFontBypass++;
    UIFont *themed = ApolloThemeFontApply(choice, font);
    sFontBypass--;
    return themed;
}

static BOOL FontLooksLikeAppleSystemDesign(UIFont *font) {
    if (![font isKindOfClass:[UIFont class]]) return NO;
    NSString *fontName = font.fontName ?: @"";
    NSString *familyName = font.familyName ?: @"";

    // System-design fonts use private/postscript names rather than normal
    // bundled font names. Keep the predicate conservative so explicit app
    // fonts such as markdown code faces survive sink-level rewriting.
    if ([fontName hasPrefix:@".SF"] ||
        [fontName hasPrefix:@".NewYork"] ||
        [fontName hasPrefix:@".AppleSystem"]) {
        return YES;
    }
    if ([familyName hasPrefix:@"SF "] ||
        [familyName hasPrefix:@"SF-"] ||
        [familyName isEqualToString:@"New York"] ||
        [familyName hasPrefix:@"New York"] ||
        [familyName isEqualToString:@".AppleSystemUIFont"]) {
        return YES;
    }
    return NO;
}

// Apollo's markdown code faces do NOT come through fontWithName: as originally
// assumed here — they're built with monospacedSystemFontOfSize:weight:, which
// is itself a *system-design* font (name .AppleSystemUIFontMonospaced / family
// prefixed .SFMono) and therefore matches FontLooksLikeAppleSystemDesign above.
// Left unguarded, every sink/refresh path re-derives it into the active theme
// design and strips the monospacing — reproducible under ANY custom theme,
// including one whose font choice is plain SF Pro (the sink/refresh/attach
// paths don't short-circuit on System the way ThemedFont() does; they still
// call ApolloThemeFontApply(System, font), which rebuilds from a proportional
// Body descriptor). Exempt anything already monospaced, independent of design.
static BOOL FontIsMonospaced(UIFont *font) {
    if (![font isKindOfClass:[UIFont class]]) return NO;
    if (font.fontDescriptor.symbolicTraits & UIFontDescriptorTraitMonoSpace) return YES;
    NSString *fontName = font.fontName ?: @"";
    NSString *familyName = font.familyName ?: @"";
    return [fontName localizedCaseInsensitiveContainsString:@"Mono"] ||
           [familyName localizedCaseInsensitiveContainsString:@"Mono"];
}

// Single themeability gate used by every sink/refresh/attach path: a font must
// look like a re-derivable Apple system design AND not already be monospaced
// (code faces stay put no matter which design the theme is set to).
static BOOL FontIsThemeable(UIFont *font) {
    return FontLooksLikeAppleSystemDesign(font) && !FontIsMonospaced(font);
}

static UIFont *ThemedTextSinkFont(UIFont *font, id owner, uintptr_t caller) {
    if (!sEnabled || !font || sFontBypass) return font;
    if (FontPinned(owner)) return font;
    if (!TextSinkMayUseTheme(owner, caller)) return font;
    if (!FontIsThemeable(font)) return font;

    sFontBypass++;
    UIFont *themed = ApolloThemeFontApply(CurrentFontChoice(), font);
    sFontBypass--;
    // Preserve identity when the design didn't change, so attributed-string
    // rewrites can skip the copy.
    if (!themed || [themed.fontName isEqualToString:font.fontName]) return font;
    return themed;
}

// ---------------------------------------------------------------------------
// Donor + exact Apollo palette lookup tables (spec §8.1, §11.2)
// ---------------------------------------------------------------------------

// mode: 0 = light, 1 = dark, 0xFF = mode-independent (resolve via current trait).
#define kModeCurrent 0xFF
typedef struct { uint32_t rgb; ApolloThemeToken token; uint8_t mode; } RGBTokenEntry;

// outrun donor role constants -> semantic token + the mode that constant
// represents. The light and dark constants are distinct, so each match pins a
// specific mode and we return that mode's *static* token colour. Apollo re-emits
// these constants when the resolved theme flips light<->dark, so a static return
// stays correct — and a UIColor value-constructor must NOT return a dynamic
// colour (it over-releases inside UIKit cell prep; see the constructor hooks).
//
//   accent      -> Accent              (C400A6 / FF00D8)
//   primaryBG   -> SecondaryBackground (card surface: CFD7E8 / 061636)
//   secondaryBG -> Background          (page behind cells: BAC1D1 / 081D47)
//   tertiaryBG  -> TertiaryBackground  (raised: C1C8D9 / 041129)
//   separator   -> Separator           (B5B9C7 / 06214D)
//   bar         -> BarBackground        (C5CAD9 / 031229)
//   gray        -> SecondaryLabel       (ABABAB / 484E5B)
//   unread      -> Selection            (95C0EE / 034388)
static const RGBTokenEntry kDonorEntries[] = {
    { 0xC400A6, ApolloThemeTokenAccent,              ApolloThemeModeLight },
    { 0xFF00D8, ApolloThemeTokenAccent,              ApolloThemeModeDark  },
    { 0xCFD7E8, ApolloThemeTokenSecondaryBackground, ApolloThemeModeLight },
    { 0x061636, ApolloThemeTokenSecondaryBackground, ApolloThemeModeDark  },
    { 0xBAC1D1, ApolloThemeTokenBackground,          ApolloThemeModeLight },
    { 0x081D47, ApolloThemeTokenBackground,          ApolloThemeModeDark  },
    { 0xC1C8D9, ApolloThemeTokenTertiaryBackground,  ApolloThemeModeLight },
    { 0x041129, ApolloThemeTokenTertiaryBackground,  ApolloThemeModeDark  },
    { 0xB5B9C7, ApolloThemeTokenSeparator,           ApolloThemeModeLight },
    { 0x06214D, ApolloThemeTokenSeparator,           ApolloThemeModeDark  },
    { 0xC5CAD9, ApolloThemeTokenBarBackground,       ApolloThemeModeLight },
    { 0x031229, ApolloThemeTokenBarBackground,       ApolloThemeModeDark  },
    { 0xABABAB, ApolloThemeTokenSecondaryLabel,      ApolloThemeModeLight },
    { 0x484E5B, ApolloThemeTokenSecondaryLabel,      ApolloThemeModeDark  },
    // Inbox unread-message tint. Outrun's UNREAD row background comes from a
    // dedicated per-theme getter (sub_10068ee00), not the shared role palette —
    // these two constants are exclusive to InboxCellNode and unique in the
    // whole binary, so swapping them here can't hit anything else. There is no
    // "unread" token, so route it to Selection — the theme's highlight family.
    // Apollo derives the pressed state for unread rows by darkening whatever
    // this returns, so the pressed variant follows the theme automatically.
    { 0x95C0EE, ApolloThemeTokenSelection,           ApolloThemeModeLight },
    { 0x034388, ApolloThemeTokenSelection,           ApolloThemeModeDark  },
};

// Apollo's separator constants are emitted outside the donor slot and outside
// text sinks, so they stay on the value-constructor path. Text palette constants
// are handled later at ASTextNode/ASButtonNode/UILabel sinks instead of here:
// matching them by render class avoids the old v1 "near-neutral gray" sweep.
static const RGBTokenEntry kSeparatorEntries[] = {
    { 0xC7C7CC, ApolloThemeTokenSeparator,      kModeCurrent },
    { 0x646466, ApolloThemeTokenSeparator,      kModeCurrent },
};

typedef struct { uint32_t rgb; ApolloThemeToken token; } TextPaletteEntry;

// Decoded from Apollo's native text palette helper sub_100689abc(role, read,
// dark). The helper builds these as hex strings and then calls sub_100752f2c,
// which ends in UIColor initWithRed:green:blue:alpha:. We intentionally use the
// constants only at text render sinks, never as global constructor remaps.
static const TextPaletteEntry kTextPaletteEntries[] = {
    // role 0: primary. Read-state primary is intentionally routed to secondary.
    { 0x000000, ApolloThemeTokenLabel },
    { 0x303030, ApolloThemeTokenLabel },
    { 0xEEEFF5, ApolloThemeTokenLabel },
    { 0xD0D1D6, ApolloThemeTokenLabel },
    { 0x999999, ApolloThemeTokenSecondaryLabel },
    { 0x939499, ApolloThemeTokenSecondaryLabel },
    { 0x86868A, ApolloThemeTokenSecondaryLabel },

    // role 1: secondary.
    { 0x666666, ApolloThemeTokenSecondaryLabel },
    { 0xB3B3B3, ApolloThemeTokenSecondaryLabel },
    { 0x94969D, ApolloThemeTokenSecondaryLabel },
    { 0x75777A, ApolloThemeTokenSecondaryLabel },
    { 0x97AEB4, ApolloThemeTokenSecondaryLabel },
    { 0x628087, ApolloThemeTokenSecondaryLabel },
    { 0x919191, ApolloThemeTokenSecondaryLabel },
    { 0x84878C, ApolloThemeTokenSecondaryLabel },

    // role 2: tertiary.
    { 0x858585, ApolloThemeTokenTertiaryLabel },
    { 0xBFBFBF, ApolloThemeTokenTertiaryLabel },
    { 0x61626A, ApolloThemeTokenTertiaryLabel },
    { 0x5D5E61, ApolloThemeTokenTertiaryLabel },
    { 0x7E9296, ApolloThemeTokenTertiaryLabel },
    { 0x5B6A6D, ApolloThemeTokenTertiaryLabel },

    // role 3/default: quaternary.
    { 0xB5B5B5, ApolloThemeTokenQuaternaryLabel },
    { 0xD7D7D7, ApolloThemeTokenQuaternaryLabel },
    { 0x505257, ApolloThemeTokenQuaternaryLabel },
    { 0x424345, ApolloThemeTokenQuaternaryLabel },
    { 0x69797D, ApolloThemeTokenQuaternaryLabel },
    { 0x465154, ApolloThemeTokenQuaternaryLabel },
};

// Fast first-byte (red) filter so the hot path bails before scanning.
static uint8_t sRByteFilter[256];

static void BuildByteFilter(void) {
    memset(sRByteFilter, 0, sizeof(sRByteFilter));
    for (size_t i = 0; i < sizeof(kDonorEntries) / sizeof(kDonorEntries[0]); i++)
        sRByteFilter[(kDonorEntries[i].rgb >> 16) & 0xFF] = 1;
    for (size_t i = 0; i < sizeof(kSeparatorEntries) / sizeof(kSeparatorEntries[0]); i++)
        sRByteFilter[(kSeparatorEntries[i].rgb >> 16) & 0xFF] = 1;
}

static inline BOOL LookupToken(uint32_t rgb, uintptr_t caller, ApolloThemeToken *out, uint8_t *outMode) {
    if (!CallerMayUseThemeRuntime(caller)) return NO;
    if (!sRByteFilter[(rgb >> 16) & 0xFF]) return NO;
    for (size_t i = 0; i < sizeof(kDonorEntries) / sizeof(kDonorEntries[0]); i++) {
        if (kDonorEntries[i].rgb == rgb) { *out = kDonorEntries[i].token; *outMode = kDonorEntries[i].mode; return YES; }
    }
    for (size_t i = 0; i < sizeof(kSeparatorEntries) / sizeof(kSeparatorEntries[0]); i++) {
        if (kSeparatorEntries[i].rgb == rgb) { *out = kSeparatorEntries[i].token; *outMode = kSeparatorEntries[i].mode; return YES; }
    }
    return NO;
}

static BOOL TextPaletteTokenForRGB(uint32_t rgb, ApolloThemeToken *out) {
    for (size_t i = 0; i < sizeof(kTextPaletteEntries) / sizeof(kTextPaletteEntries[0]); i++) {
        if (kTextPaletteEntries[i].rgb == rgb) {
            if (out) *out = kTextPaletteEntries[i].token;
            return YES;
        }
    }
    return NO;
}

static BOOL ColorComponents(UIColor *color, CGFloat *outR, CGFloat *outG, CGFloat *outB, CGFloat *outA) {
    if (![color isKindOfClass:[UIColor class]]) return NO;
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if ([color getRed:&r green:&g blue:&b alpha:&a]) {
        if (outR) *outR = r; if (outG) *outG = g; if (outB) *outB = b; if (outA) *outA = a;
        return YES;
    }
    CGFloat w = 0;
    if ([color getWhite:&w alpha:&a]) {
        if (outR) *outR = w; if (outG) *outG = w; if (outB) *outB = w; if (outA) *outA = a;
        return YES;
    }
    return NO;
}

static BOOL TextPaletteTokenForColor(UIColor *color, ApolloThemeToken *outToken, CGFloat *outAlpha) {
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (!ColorComponents(color, &r, &g, &b, &a)) return NO;
    if (outAlpha) *outAlpha = a;
    return TextPaletteTokenForRGB(ApolloThemeRGBKeyFromComponents(r, g, b), outToken);
}

static BOOL ClassNameLooksApolloOwned(const char *name) {
    if (!name) return NO;
    return strncmp(name, "_TtC6Apollo", 11) == 0 ||
           strncmp(name, "Apollo", 6) == 0 ||
           strstr(name, ".Apollo") != NULL;
}

// Walk supernode (Texture), then the RESPONDER chain, then superview.
// nextResponder must outrank superview: the responder chain interleaves each
// view's managing view controller, so a label inside an Apollo controller is
// vetted in a few hops. The old superview-first walk had to climb the entire
// UIKit view stack and then window→scene→application→AppDelegate — 10-13 hops
// depending on presentation depth, which straddled the budget and made the
// gate (and therefore all font/text theming) fail on deeper screens.
static BOOL ObjectChainLooksApolloOwned(id object) {
    id current = object;
    for (NSUInteger i = 0; current && i < 16; i++) {
        if (ClassNameLooksApolloOwned(class_getName(object_getClass(current)))) return YES;

        id next = nil;
        if ([current respondsToSelector:@selector(supernode)]) {
            @try {
                next = ((id (*)(id, SEL))objc_msgSend)(current, @selector(supernode));
            } @catch (__unused NSException *e) {
                next = nil;
            }
        }
        if (!next && [current respondsToSelector:@selector(nextResponder)]) {
            @try {
                next = ((id (*)(id, SEL))objc_msgSend)(current, @selector(nextResponder));
            } @catch (__unused NSException *e) {
                next = nil;
            }
        }
        if (!next && [current respondsToSelector:@selector(superview)]) {
            @try {
                next = ((id (*)(id, SEL))objc_msgSend)(current, @selector(superview));
            } @catch (__unused NSException *e) {
                next = nil;
            }
        }
        if (next == current) break;
        current = next;
    }
    return NO;
}

static UINavigationBar *NavigationBarForDescendant(UIView *view) {
    for (UIView *v = view; v != nil; v = v.superview) {
        if ([v isKindOfClass:[UINavigationBar class]]) return (UINavigationBar *)v;
    }
    return nil;
}

// Nav/tab bars host their labels outside Apollo's view/responder chain, so
// ownership is vetted at the bar: either the chain reaches an Apollo class,
// or the bar's delegate is one (Apollo's own controllers).
static BOOL ChromeBarLooksApolloOwned(UIView *bar) {
    if (!([bar isKindOfClass:[UINavigationBar class]] || [bar isKindOfClass:[UITabBar class]])) return NO;
    if (ObjectChainLooksApolloOwned(bar)) return YES;
    id delegate = ((id (*)(id, SEL))objc_msgSend)(bar, @selector(delegate));
    if (delegate && ClassNameLooksApolloOwned(class_getName(object_getClass(delegate)))) return YES;
    return NO;
}

// Re-derive one live text control's font into `target`'s design. Only touches
// fonts that are Apple system designs (explicit app fonts like markdown code
// faces survive) and skips pinned views (the editor's picker tiles).
static void RefreshFontOnTextControl(UIView *view, ApolloThemeFont target) {
    if (FontPinned(view)) return;
    UIFont *font = ((UILabel *)view).font; // UILabel/UITextField/UITextView all expose `font`
    if (![font isKindOfClass:[UIFont class]] || !FontIsThemeable(font)) return;
    sFontBypass++;
    UIFont *themed = ApolloThemeFontApply(target, font);
    if (themed && ![themed.fontName isEqualToString:font.fontName]) {
        // Set inside the bypass: the font is already derived, the sink hook
        // must not re-derive it (and must not fight a target of System).
        ((void (*)(id, SEL, id))objc_msgSend)(view, @selector(setFont:), themed);
    }
    sFontBypass--;
}

static BOOL ViewIsFontRefreshable(UIView *view) {
    return [view isKindOfClass:[UILabel class]] ||
           [view isKindOfClass:[UITextField class]] ||
           [view isKindOfClass:[UITextView class]];
}

// `vetted` propagates a one-time ownership decision down a subtree (a vetted
// bar's labels never chain back to Apollo classes individually). Outside a
// vetted subtree, each text control is gated exactly like the sink hooks.
static void RefreshFontsInViewTree(UIView *view, ApolloThemeFont target, BOOL vetted) {
    if (!vetted && ([view isKindOfClass:[UINavigationBar class]] || [view isKindOfClass:[UITabBar class]])) {
        if (!ChromeBarLooksApolloOwned(view)) return; // foreign chrome: leave the whole subtree alone
        vetted = YES;
    }
    if (ViewIsFontRefreshable(view) && (vetted || ObjectChainLooksApolloOwned(view))) {
        RefreshFontOnTextControl(view, target);
    }
    for (UIView *subview in view.subviews) {
        RefreshFontsInViewTree(subview, target, vetted);
    }
}

void ApolloThemeRuntimeRefreshFonts(void) {
    // Runs even when the runtime is INACTIVE: disabling theming (or switching
    // to the System font) must walk existing labels back to SF Pro — nothing
    // else re-derives a font until the view happens to be recreated.
    ApolloThemeFont target = sEnabled ? CurrentFontChoice() : ApolloThemeFontSystem;
    for (UIWindow *window in ApolloAllWindows()) {
        RefreshFontsInViewTree(window, target, NO);
    }
}

// Attach-time repair: UIKit configures table/collection cell labels while the
// cell is DETACHED (cellForRow… runs before the cell joins the table), so the
// set-time sink gate has no superview/responder chain to vet and those fonts
// stay SF Pro — the manager's own rows rendered unthemed while its (attached)
// headers/footers themed fine. The moment a text control joins a window the
// chain exists, so re-derive from didMoveToWindow. Ordering matters for the
// hot path (every cell recycle): bail on font identity (Apply is cached)
// BEFORE paying for the ownership walk.
static void RethemeFontOnAttach(UIView *view) {
    if (!sEnabled || sFontBypass) return;
    if (!view.window) return;
    if (FontPinned(view)) return;
    UIFont *font = ((UILabel *)view).font; // UILabel/UITextField/UITextView all expose `font`
    if (![font isKindOfClass:[UIFont class]] || !FontIsThemeable(font)) return;
    sFontBypass++;
    UIFont *themed = ApolloThemeFontApply(CurrentFontChoice(), font);
    if (themed && ![themed.fontName isEqualToString:font.fontName] && ObjectChainLooksApolloOwned(view)) {
        ((void (*)(id, SEL, id))objc_msgSend)(view, @selector(setFont:), themed);
    }
    sFontBypass--;
}

static void ApplyThemeFontToNavigationTitleControl(UIView *titleControl) {
    if (!sEnabled || ![titleControl isKindOfClass:[UIView class]]) return;
    if (!ChromeBarLooksApolloOwned(NavigationBarForDescendant(titleControl))) return;
    RefreshFontsInViewTree(titleControl, CurrentFontChoice(), YES);
}

static BOOL TextSinkMayUseTheme(id object, uintptr_t caller) {
    if (!sEnabled) return NO;
    if (CallerMayUseThemeRuntime(caller)) return YES;
    return ObjectChainLooksApolloOwned(object);
}

// ---------------------------------------------------------------------------
// Public accessors
// ---------------------------------------------------------------------------

BOOL ApolloThemeRuntimeIsActive(void) { return sEnabled; }

// Build a FRESH dynamic colour for a token. We deliberately do NOT cache and
// vend a shared singleton: handing the same retained UIColor instance back
// through hooked UIColor constructors/accessors leads to ARC retain/release
// imbalances at the UIKit call sites (observed as an over-release of our
// UIDynamicProviderColor → EXC_BAD_ACCESS in objc_release during the table's
// cell-prep autorelease drain). A fresh, independently-owned object per call is
// freed normally by its caller and sidesteps the entire problem. The provider
// reads the live sTokens table, so light/dark + edits still resolve correctly.
static UIColor *ApolloThemeMakeDynamicColor(ApolloThemeToken token) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        ApolloThemeMode mode = (tc.userInterfaceStyle == UIUserInterfaceStyleDark)
            ? ApolloThemeModeDark : ApolloThemeModeLight;
        uint32_t rgb;
        os_unfair_lock_lock(&sLock);
        rgb = sTokens[mode][token];
        os_unfair_lock_unlock(&sLock);
        sBypassHook++;
        UIColor *c = ApolloThemeUIColorFromRGB(rgb);
        sBypassHook--;
        return c;
    }];
}

UIColor *ApolloThemeRuntimeColor(ApolloThemeToken token) {
    if (!sEnabled || token >= ApolloThemeTokenCount) return nil;
    return ApolloThemeMakeDynamicColor(token);
}

UIFont *ApolloThemeRuntimeFont(UIFont *base) {
    ApolloThemeFont choice = CurrentFontChoice();
    if (!sEnabled || choice == ApolloThemeFontSystem || !base) return base;
    sFontBypass++;
    UIFont *themed = ApolloThemeFontApply(choice, base);
    sFontBypass--;
    return themed ?: base;
}

uint64_t ApolloThemeRuntimeEpoch(void) {
    os_unfair_lock_lock(&sLock);
    uint64_t e = sEpoch;
    os_unfair_lock_unlock(&sLock);
    return e;
}

static UIColor *ThemedTextColorForSourceColor(UIColor *source, id owner, uintptr_t caller) {
    if (!TextSinkMayUseTheme(owner, caller)) return source;

    ApolloThemeToken token;
    CGFloat alpha = 1;
    if (!TextPaletteTokenForColor(source, &token, &alpha)) return source;

    UIColor *replacement = ApolloThemeRuntimeColor(token);
    if (!replacement) return source;
    if (alpha < 0.995) replacement = [replacement colorWithAlphaComponent:alpha];
    if (sDebugLogging) {
        uint32_t rgb = ApolloThemeRGBFromUIColor(source);
        ApolloLog(@"ThemeRuntime: text #%06X -> %@", rgb, ApolloThemeTokenKey(token));
    }
    return replacement;
}

static NSAttributedString *ThemedAttributedText(NSAttributedString *text, id owner, uintptr_t caller) {
    if (![text isKindOfClass:[NSAttributedString class]] || text.length == 0) return text;
    if (!TextSinkMayUseTheme(owner, caller)) return text;

    __block NSMutableAttributedString *rewritten = nil;
    NSRange full = NSMakeRange(0, text.length);
    [text enumerateAttribute:NSFontAttributeName
                     inRange:full
                     options:0
                  usingBlock:^(id value, NSRange range, BOOL *stop) {
        if (![value isKindOfClass:[UIFont class]]) return;
        UIFont *replacement = ThemedTextSinkFont(value, owner, caller);
        if (replacement == value) return;
        if (!rewritten) rewritten = [text mutableCopy];
        [rewritten addAttribute:NSFontAttributeName value:replacement range:range];
    }];
    [text enumerateAttribute:NSForegroundColorAttributeName
                     inRange:full
                     options:0
                  usingBlock:^(id value, NSRange range, BOOL *stop) {
        if (![value isKindOfClass:[UIColor class]]) return;
        UIColor *replacement = ThemedTextColorForSourceColor(value, owner, caller);
        if (replacement == value) return;
        if (!rewritten) rewritten = [text mutableCopy];
        [rewritten addAttribute:NSForegroundColorAttributeName value:replacement range:range];
    }];
    return rewritten ?: text;
}

static NSAttributedString *ThemedPlaceholderText(UITextField *field, NSAttributedString *placeholder, uintptr_t caller) {
    if (![field isKindOfClass:[UITextField class]]) return placeholder;
    if (!TextSinkMayUseTheme(field, caller)) return placeholder;

    NSMutableAttributedString *working = nil;
    if ([placeholder isKindOfClass:[NSAttributedString class]] && placeholder.length > 0) {
        working = [placeholder mutableCopy];
    } else if (field.placeholder.length > 0) {
        working = [[NSMutableAttributedString alloc] initWithString:field.placeholder];
    }
    if (!working.length) return placeholder;

    NSRange full = NSMakeRange(0, working.length);
    __block BOOL hasFont = NO;
    [working enumerateAttribute:NSFontAttributeName inRange:full options:0 usingBlock:^(id value, NSRange range, BOOL *stop) {
        if ([value isKindOfClass:[UIFont class]]) { hasFont = YES; *stop = YES; }
    }];
    if (!hasFont && [field.font isKindOfClass:[UIFont class]]) {
        [working addAttribute:NSFontAttributeName value:field.font range:full];
    }
    return ThemedAttributedText(working, field, caller);
}

// Resolve a token's static RGB components (0..1) for a mode. The value-
// constructor hooks feed these straight into %orig(...) — i.e. UIKit's own
// colorWithRed:/initWithRed: with new components — exactly as the v1 builder
// did. Returning %orig's result (rather than a colour built in a helper and
// returned across call boundaries) preserves ARC's autoreleased-return-value
// chain; building a substitute colour any other way over-releases it inside
// UIKit's cell-prep autorelease drain. `mode` may be kModeCurrent (greys).
static void ApolloThemeTokenComponents(ApolloThemeToken token, uint8_t mode,
                                       CGFloat *outR, CGFloat *outG, CGFloat *outB) {
    if (mode == kModeCurrent) {
        mode = (UITraitCollection.currentTraitCollection.userInterfaceStyle == UIUserInterfaceStyleDark)
            ? ApolloThemeModeDark : ApolloThemeModeLight;
    }
    uint32_t rgb;
    os_unfair_lock_lock(&sLock);
    rgb = sTokens[mode][token];
    os_unfair_lock_unlock(&sLock);
    *outR = ((rgb >> 16) & 0xFF) / 255.0;
    *outG = ((rgb >> 8) & 0xFF) / 255.0;
    *outB = (rgb & 0xFF) / 255.0;
}

void ApolloThemeRuntimeSetDebugLogging(BOOL on) { sDebugLogging = on; }
BOOL ApolloThemeRuntimeDebugLogging(void) { return sDebugLogging; }
BOOL ApolloThemeRuntimeUseLegacyRepaintFallback(void) { return sLegacyRepaint; }
void ApolloThemeRuntimeSetLegacyRepaintFallback(BOOL on) { sLegacyRepaint = on; }

// ===========================================================================
// Compile / reload
// ===========================================================================

void ApolloThemeRuntimeReload(void) {
    ApolloThemeStore *store = [ApolloThemeStore shared];
    BOOL crashed = store.runtimeDisabledDueToCrash;
    BOOL enable = store.customThemeEnabled && !crashed;
    NSDictionary *lightTheme = enable ? [store themeForMode:ApolloThemeModeLight] : nil;
    NSDictionary *darkTheme = enable ? [store themeForMode:ApolloThemeModeDark] : nil;

    if (!lightTheme || !darkTheme) {
        os_unfair_lock_lock(&sLock);
        sEnabled = false;
        sFontChoices[ApolloThemeModeLight] = ApolloThemeFontSystem;
        sFontChoices[ApolloThemeModeDark] = ApolloThemeFontSystem;
        sVoteArrowsAccent[ApolloThemeModeLight] = false;
        sVoteArrowsAccent[ApolloThemeModeDark] = false;
        sEpoch++;
        os_unfair_lock_unlock(&sLock);
        ApolloLog(@"ThemeRuntime: reload -> INACTIVE (enabledFlag=%d crashKill=%d activeTheme=%@)",
                  store.customThemeEnabled, crashed, store.activeThemeID ?: @"(none)");
        return;
    }

    ApolloCompiledTheme *compiled[ApolloThemeModeCount] = { nil, nil };
    @try {
        NSDictionary *themes[ApolloThemeModeCount] = { lightTheme, darkTheme };
        for (NSUInteger mode = 0; mode < ApolloThemeModeCount; mode++) {
            NSDictionary *theme = themes[mode];
            compiled[mode] = [ApolloCompiledTheme compiledThemeWithInput:theme[@"input"]
                                                                  variant:ApolloThemeVariantFromKey(theme[@"variant"])
                                                          advancedEnabled:[theme[kApolloThemeAdvancedOptionsEnabledKey] boolValue]];
        }
    } @catch (NSException *e) {
        ApolloLog(@"ThemeRuntime: COMPILE EXCEPTION %@ — %@ (light=%@ dark=%@)",
                  e.name, e.reason, lightTheme[@"name"], darkTheme[@"name"]);
        os_unfair_lock_lock(&sLock); sEnabled = false; sEpoch++; os_unfair_lock_unlock(&sLock);
        return;
    }

    os_unfair_lock_lock(&sLock);
    for (NSUInteger m = 0; m < ApolloThemeModeCount; m++) {
        for (NSUInteger t = 0; t < ApolloThemeTokenCount; t++) {
            sTokens[m][t] = [compiled[m] rgbForToken:(ApolloThemeToken)t mode:(ApolloThemeMode)m];
        }
        NSDictionary *theme = m == ApolloThemeModeDark ? darkTheme : lightTheme;
        sFontChoices[m] = ApolloThemeFontFromKey(theme[kApolloThemeFontKey]);
        sVoteArrowsAccent[m] = [theme[kApolloThemeVoteArrowsAccentKey] boolValue];
    }
    sEnabled = true;
    sEpoch++;
    os_unfair_lock_unlock(&sLock);

    ApolloLog(@"ThemeRuntime: reload -> ACTIVE light='%@' dark='%@' | light bg=#%06X card=#%06X accent=#%06X label=#%06X | dark bg=#%06X card=#%06X accent=#%06X",
              lightTheme[@"name"], darkTheme[@"name"],
              sTokens[0][ApolloThemeTokenBackground], sTokens[0][ApolloThemeTokenSecondaryBackground],
              sTokens[0][ApolloThemeTokenAccent], sTokens[0][ApolloThemeTokenLabel],
              sTokens[1][ApolloThemeTokenBackground], sTokens[1][ApolloThemeTokenSecondaryBackground],
              sTokens[1][ApolloThemeTokenAccent]);

    sFontBypass++;
    UIFont *base = [UIFont systemFontOfSize:17.0 weight:UIFontWeightRegular];
    sFontBypass--;
    ApolloThemeFont currentFont = CurrentFontChoice();
    UIFont *resolved = ApolloThemeFontApply(currentFont, base);
    ApolloLog(@"ThemeRuntime: font sample light=%@ dark=%@ base='%@' -> resolved='%@'",
              ApolloThemeFontKey(sFontChoices[0]), ApolloThemeFontKey(sFontChoices[1]), base.fontName, resolved.fontName);
    UIFont *defaultSample = ApolloThemeFontApply(ApolloThemeFontSystem, base);
    UIFont *roundedSample = ApolloThemeFontApply(ApolloThemeFontRounded, base);
    UIFont *serifSample = ApolloThemeFontApply(ApolloThemeFontSerif, base);
    UIFont *monoSample = ApolloThemeFontApply(ApolloThemeFontMono, base);
    ApolloLog(@"ThemeRuntime: font designs default='%@' rounded='%@' serif='%@' mono='%@'",
              defaultSample.fontName, roundedSample.fontName, serifSample.fontName, monoSample.fontName);
}

// ===========================================================================
// Apollo theme system bridge (donor hijack + previous-theme restore)
// ===========================================================================

static NSString * const kAppGroupSuite  = @"group.com.christianselig.apollo";
static NSString * const kAppColorThemeKey = @"AppColorTheme";
static const uint8_t kDonorThemeRawValue = 5; // outrun

// Apollo's own Pure Black Dark Mode toggles (group defaults, same suite as
// AppColorTheme). UsePurePUREBlackMode is a stronger tier on top of
// UsePureBlackDarkMode; both apply only to non-tinted stock themes (Apollo's
// theme screen: "Pure black affects Apollo themes only").
static NSString * const kUsePureBlackDarkModeKey = @"UsePureBlackDarkMode";
static NSString * const kUsePurerBlackDarkModeKey = @"UsePurePUREBlackMode";
static NSString * const kPureBlackReduceSmearingKey = @"PureBlackModeReduceSmearing";

// Stock AppColorTheme metadata, indexed by raw value: enum case name, accent
// {light, dark}, and card background {light, dark} (docs/theme-builder-RE.md;
// accents recovered from the 1.15.11 binary's accent switch — jump table
// 0x100ae3c14, arms off 0x10068b6bc). One table so all three stay in sync.
//
// tinted themes (solarized/outrun/sunset/sepia/dracula) retint their own
// background and ignore Pure Black entirely. Non-tinted themes share one
// baseline (0x20252F) that ApolloStockNonTintedDarkCardRGB overrides per
// Apollo's Pure Black tier.
static const struct { const char *name; uint32_t light, dark; uint32_t bgLight, bgDark; BOOL tinted; } kStockThemes[] = {
    {"default",         0x007AFF, 0x2399FF, 0xFFFFFF, 0x20252F, NO},
    {"nefertiti",       0x01A200, 0x01A200, 0xFFFFFF, 0x20252F, NO},
    {"fieryStare",      0xFF0000, 0xFD0000, 0xFFFFFF, 0x20252F, NO},
    {"spookyPumpkin",   0xFF6200, 0xF25D00, 0xFFFFFF, 0x20252F, NO},
    {"solarized",       0x268BD2, 0x268BD2, 0xFDF6E3, 0x002B36, YES},
    {"outrun",          0xC400A6, 0xFF00D8, 0xCFD7E8, 0x061636, YES},
    {"sunset",          0xFF6600, 0xFF7D00, 0xFFE3D0, 0x000F29, YES},
    {"sepia",           0xB88023, 0xD3AC72, 0xF1EAD9, 0x211E1A, YES},
    {"monochromatic",   0x000000, 0xFFFFFF, 0xFFFFFF, 0x20252F, NO},
    {"navy",            0x0058B8, 0x0060C9, 0xFFFFFF, 0x20252F, NO},
    {"skiesOnSkies",    0x00B5F2, 0x01ADE8, 0xFFFFFF, 0x20252F, NO},
    {"majesticPurple",  0x8800FF, 0x9C2CFF, 0xFFFFFF, 0x20252F, NO},
    {"magentasplosion", 0xFF00B2, 0xE800A2, 0xFFFFFF, 0x20252F, NO},
    {"sniffingWalnut",  0xA74E00, 0xA74E00, 0xFFFFFF, 0x20252F, NO},
    {"fisherKing",      0x808286, 0x76787D, 0xFFFFFF, 0x20252F, NO},
    {"chumbus",         0xF8F8F8, 0x20242B, 0xFFFFFF, 0x20252F, NO},
    {"dracula",         0x9760FF, 0xAD81FF, 0xF8F8F3, 0x1A1D29, YES},
    {"mint",            0x37BB98, 0x62DFA7, 0xFFFFFF, 0x20252F, NO},
};
enum { kStockThemeCount = sizeof(kStockThemes) / sizeof(kStockThemes[0]) };

static NSUserDefaults *GroupDefaults(void) {
    static NSUserDefaults *g;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ g = [[NSUserDefaults alloc] initWithSuiteName:kAppGroupSuite]; });
    return g;
}

static BOOL RawForThemeName(NSString *name, uint8_t *outRaw) {
    if (!name.length) return NO;
    for (uint8_t i = 0; i < kStockThemeCount; i++) {
        if ([name isEqualToString:@(kStockThemes[i].name)]) { if (outRaw) *outRaw = i; return YES; }
    }
    return NO;
}

static __weak NSObject *sThemeManager = nil;

// Write Apollo's in-memory ThemeManager.appColorTheme enum byte so a switch
// takes effect without a relaunch. Falls back to the persisted default if the
// manager hasn't been captured yet.
static BOOL SetLiveAppColorThemeRaw(uint8_t raw) {
    NSObject *tm = sThemeManager;
    if (!tm) {
        ApolloLog(@"ThemeRuntime: SetLiveAppColorThemeRaw(%d) — ThemeManager not captured; applies next launch", raw);
        return NO;
    }
    Ivar ivar = class_getInstanceVariable(object_getClass(tm), "appColorTheme");
    if (!ivar) {
        ApolloLog(@"ThemeRuntime: SetLiveAppColorThemeRaw(%d) — appColorTheme ivar missing", raw);
        return NO;
    }
    *((uint8_t *)(__bridge void *)tm + ivar_getOffset(ivar)) = raw;
    ApolloLog(@"ThemeRuntime: live appColorTheme ivar set to raw %d", raw);
    return YES;
}

// Read the live appColorTheme raw byte (counterpart of SetLiveAppColorThemeRaw);
// falls back to the persisted group-defaults selection pre-capture.
static BOOL GetLiveAppColorThemeRaw(uint8_t *outRaw) {
    NSObject *tm = sThemeManager;
    if (tm) {
        static Ivar sIvar;   // resolved once — this sits on per-cell accent paths
        if (!sIvar) sIvar = class_getInstanceVariable(object_getClass(tm), "appColorTheme");
        if (sIvar) { *outRaw = *((uint8_t *)(__bridge void *)tm + ivar_getOffset(sIvar)); return YES; }
    }
    return RawForThemeName([GroupDefaults() stringForKey:kAppColorThemeKey], outRaw);
}

// Accent of the currently-selected stock Apollo theme; nil while the custom
// runtime is active (stock slot hijacked to the donor) or theme unknown.
// Internal — external callers go through ApolloThemeAccentColor().
static UIColor *ApolloThemeStockAccentColor(void) {
    if (sEnabled) return nil;   // stock slot is hijacked to the donor theme
    uint8_t raw = 0;
    if (!GetLiveAppColorThemeRaw(&raw)) return nil;
    if (raw >= kStockThemeCount) return nil;
    uint32_t light = kStockThemes[raw].light, dark = kStockThemes[raw].dark;
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        uint32_t rgb = (tc.userInterfaceStyle == UIUserInterfaceStyleDark) ? dark : light;
        sBypassHook++;
        UIColor *c = ApolloThemeUIColorFromRGB(rgb);
        sBypassHook--;
        return c;
    }];
}

UIColor *ApolloThemeAccentColor(void) {
    UIColor *custom = ApolloThemeRuntimeColor(ApolloThemeTokenAccent);
    return custom ?: ApolloThemeStockAccentColor();
}

// Dark-mode card override for a non-tinted stock theme, per Apollo's Pure
// Black tier. PURER is only consulted when Pure Black is also on — Apollo
// hides its toggle (and ignores the stored value) once Pure Black is off,
// but doesn't clear it, so an unconditional check would resurrect a stale
// YES. Read live, not cached: colorWithDynamicProvider: only runs on trait
// resolution, and -boolForKey: is cheap after the first read.
static BOOL ApolloStockNonTintedDarkCardRGB(uint32_t *outRGB) {
    NSUserDefaults *d = GroupDefaults();
    if (![d boolForKey:kUsePureBlackDarkModeKey]) return NO;
    if ([d boolForKey:kUsePurerBlackDarkModeKey]) {
        if (outRGB) *outRGB = [d boolForKey:kPureBlackReduceSmearingKey] ? 0x050505 : 0x000000;
        return YES;
    }
    if (outRGB) *outRGB = 0x131516;
    return YES;
}

// Card/cell background ("primaryBG") of the currently-selected stock Apollo
// theme; nil while the custom runtime is active (donor hijack) or theme
// unknown. Internal — external callers go through ApolloThemeCardBackgroundColor().
static UIColor *ApolloThemeStockCardBackgroundColor(void) {
    if (sEnabled) return nil;
    uint8_t raw = 0;
    if (!GetLiveAppColorThemeRaw(&raw)) return nil;
    if (raw >= kStockThemeCount) return nil;
    uint32_t light = kStockThemes[raw].bgLight, dark = kStockThemes[raw].bgDark;
    BOOL tinted = kStockThemes[raw].tinted;
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        uint32_t rgb = light;
        if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
            uint32_t pureBlackRGB = 0;
            rgb = (!tinted && ApolloStockNonTintedDarkCardRGB(&pureBlackRGB)) ? pureBlackRGB : dark;
        }
        sBypassHook++;
        UIColor *c = ApolloThemeUIColorFromRGB(rgb);
        sBypassHook--;
        return c;
    }];
}

// The EFFECTIVE card/cell background for tweak-drawn UI: the custom theme's
// card color when one is active, else the stock theme's (Pure Black Dark
// Mode aware). nil only if neither can be determined — callers supply their
// own last-resort (typically secondarySystemGroupedBackgroundColor).
UIColor *ApolloThemeCardBackgroundColor(void) {
    UIColor *custom = ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryBackground);
    return custom ?: ApolloThemeStockCardBackgroundColor();
}

void ApolloThemeRuntimeEnable(void) {
    ApolloThemeStore *store = [ApolloThemeStore shared];
    NSString *current = [GroupDefaults() stringForKey:kAppColorThemeKey];
    NSString *donor = [store runtimeDonorTheme];
    ApolloLog(@"ThemeRuntime: ENABLE requested (currentAppColorTheme=%@ donor=%@ activeTheme=%@)",
              current ?: @"(none)", donor, store.activeThemeID ?: @"(none)");
    // Remember the real selected theme before hijacking the donor slot.
    if (current.length && ![current isEqualToString:donor]) {
        store.previousApolloTheme = current;
    }
    [GroupDefaults() setObject:donor forKey:kAppColorThemeKey];
    [store restoreLastCustomSelection];
    ApolloThemeRuntimeReload();
    SetLiveAppColorThemeRaw(kDonorThemeRawValue);
    ApolloThemeRuntimeInvalidate();
    ApolloLog(@"ThemeRuntime: enabled (donor=%@, prev=%@)", donor, store.previousApolloTheme);
}

void ApolloThemeRuntimeDisable(void) {
    ApolloThemeStore *store = [ApolloThemeStore shared];
    [store selectApolloTheme];
    os_unfair_lock_lock(&sLock);
    sEnabled = false;
    sEpoch++;
    os_unfair_lock_unlock(&sLock);

    NSString *prev = store.previousApolloTheme;
    uint8_t raw = 0; // AppColorTheme.default fallback
    if (prev.length) {
        [GroupDefaults() setObject:prev forKey:kAppColorThemeKey];
        RawForThemeName(prev, &raw);
    } else {
        [GroupDefaults() removeObjectForKey:kAppColorThemeKey];
    }
    SetLiveAppColorThemeRaw(raw);
    ApolloThemeRuntimeInvalidate();
    ApolloLog(@"ThemeRuntime: disabled (restored=%@ raw=%d)", prev ?: @"default", raw);
}

// ===========================================================================
// Invalidation (spec §12)
// ===========================================================================

static void PostThemeNotifications(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc postNotificationName:@"com.christianselig.ApolloSpecificThemeChanged" object:nil];
    [nc postNotificationName:@"com.christianselig.CommentsColorThemeChanged" object:nil];
}

// Legacy fallback: flip each window's override style for one runloop turn to
// drive a full trait-change cascade (re-resolves cached dynamic colours).
static void LegacyFlipRepaint(void) {
    NSArray<UIWindow *> *windows = ApolloAllWindows();
    NSMutableArray<NSNumber *> *saved = [NSMutableArray array];
    for (UIWindow *w in windows) {
        [saved addObject:@(w.overrideUserInterfaceStyle)];
        UIUserInterfaceStyle eff = w.traitCollection.userInterfaceStyle;
        w.overrideUserInterfaceStyle = (eff == UIUserInterfaceStyleDark)
            ? UIUserInterfaceStyleLight : UIUserInterfaceStyleDark;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [windows enumerateObjectsUsingBlock:^(UIWindow *w, NSUInteger idx, BOOL *stop) {
            if (idx < saved.count) w.overrideUserInterfaceStyle = (UIUserInterfaceStyle)saved[idx].integerValue;
        }];
    });
}

void ApolloThemeRuntimeInvalidate(void) {
    ApolloLog(@"ThemeRuntime: invalidate (active=%d flip=%d postNotifs=%d)", sEnabled, sLegacyRepaint, sPostNativeNotifications);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sPostNativeNotifications) PostThemeNotifications();
        if (sLegacyRepaint) LegacyFlipRepaint();
        // Colours re-resolve via the trait cascade, but fonts on existing
        // views only change if something re-derives them — walk the windows.
        ApolloThemeRuntimeRefreshFonts();
        ApolloLog(@"ThemeRuntime: invalidate applied");
    });
}

// ===========================================================================
// Hooks
// ===========================================================================

%group ApolloThemeRuntimeManagerHook
%hook _TtC6Apollo12ThemeManager
- (id)init {
    id result = %orig;
    sThemeManager = result;
    ApolloLog(@"ThemeRuntime: captured ThemeManager %p", result);
    return result;
}
%end
%end

%group ApolloThemeRuntimeHooks

%hook UIColor

// --- donor-constant + separator remap (hot path) ---
// These VALUE CONSTRUCTORS return STATIC plain colours (never dynamic provider
// colours — those over-release inside UIKit cell prep). The donor constant pins
// the mode; separator constants resolve against the current trait. Apollo
// re-emits these on a light<->dark change, and our invalidate flips the window
// style, so static is OK. Native text palette colours are handled by the text
// sink hooks below, not by this constructor path.

+ (UIColor *)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    if (sEnabled && !sBypassHook) {
        uint32_t rgb = ApolloThemeRGBKeyFromComponents(r, g, b);
        uintptr_t caller = (uintptr_t)__builtin_return_address(0);
        ApolloThemeToken token; uint8_t mode;
        if (LookupToken(rgb, caller, &token, &mode)) {
            if (sDebugLogging) ApolloLog(@"ThemeRuntime: donor #%06X -> %@", rgb, ApolloThemeTokenKey(token));
            CGFloat R, G, B; ApolloThemeTokenComponents(token, mode, &R, &G, &B);
            return %orig(R, G, B, a);
        }
    }
    return %orig;
}

// Apollo is Swift: UIColor(red:green:blue:alpha:) compiles to this instance
// initialiser, so this is the primary donor entry point.
- (UIColor *)initWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    if (sEnabled && !sBypassHook) {
        uint32_t rgb = ApolloThemeRGBKeyFromComponents(r, g, b);
        uintptr_t caller = (uintptr_t)__builtin_return_address(0);
        ApolloThemeToken token; uint8_t mode;
        if (LookupToken(rgb, caller, &token, &mode)) {
            if (sDebugLogging) ApolloLog(@"ThemeRuntime: donor(init) #%06X a=%.2f -> %@", rgb, a, ApolloThemeTokenKey(token));
            CGFloat R, G, B; ApolloThemeTokenComponents(token, mode, &R, &G, &B);
            return %orig(R, G, B, a);
        }
    }
    return %orig;
}

// colorWithWhite:/initWithWhite: — our token colours are RGB and can't be passed
// through %orig (which is white-only). Apollo's greys are also reachable via the
// donor RGB constructors and the semantic accessors, so leave the white path on
// %orig rather than build-and-return a substitute (which over-releases).
+ (UIColor *)colorWithWhite:(CGFloat)w alpha:(CGFloat)a {
    return %orig;
}

- (UIColor *)initWithWhite:(CGFloat)w alpha:(CGFloat)a {
    return %orig;
}

// --- semantic UIKit accessor overrides (spec §10) ---
// Keyed on meaning, so they cover the colours Apollo draws from UIKit's palette
// (which the RGB hook never sees because they resolve inside UIKit). Written out
// explicitly because Logos preprocessing runs before the C preprocessor, so
// %orig can't live inside a C macro.

+ (UIColor *)systemBackgroundColor { UIColor *c = SemColor(ApolloThemeTokenBackground, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }
+ (UIColor *)secondarySystemBackgroundColor { UIColor *c = SemColor(ApolloThemeTokenSecondaryBackground, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }
+ (UIColor *)tertiarySystemBackgroundColor { UIColor *c = SemColor(ApolloThemeTokenTertiaryBackground, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }
+ (UIColor *)systemGroupedBackgroundColor { UIColor *c = SemColor(ApolloThemeTokenBackground, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }
+ (UIColor *)secondarySystemGroupedBackgroundColor { UIColor *c = SemColor(ApolloThemeTokenSecondaryBackground, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }
+ (UIColor *)tertiarySystemGroupedBackgroundColor { UIColor *c = SemColor(ApolloThemeTokenTertiaryBackground, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }

+ (UIColor *)labelColor { UIColor *c = SemColor(ApolloThemeTokenLabel, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }
+ (UIColor *)secondaryLabelColor { UIColor *c = SemColor(ApolloThemeTokenSecondaryLabel, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }
+ (UIColor *)tertiaryLabelColor { UIColor *c = SemColor(ApolloThemeTokenTertiaryLabel, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }
+ (UIColor *)quaternaryLabelColor { UIColor *c = SemColor(ApolloThemeTokenQuaternaryLabel, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }
+ (UIColor *)placeholderTextColor { UIColor *c = SemColor(ApolloThemeTokenPlaceholderText, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }

+ (UIColor *)separatorColor { UIColor *c = SemColor(ApolloThemeTokenSeparator, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }
+ (UIColor *)opaqueSeparatorColor { UIColor *c = SemColor(ApolloThemeTokenOpaqueSeparator, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }

+ (UIColor *)systemFillColor { UIColor *c = SemColor(ApolloThemeTokenFill, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }
+ (UIColor *)secondarySystemFillColor { UIColor *c = SemColor(ApolloThemeTokenSecondaryFill, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }
+ (UIColor *)tertiarySystemFillColor { UIColor *c = SemColor(ApolloThemeTokenTertiaryFill, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }
+ (UIColor *)quaternarySystemFillColor { UIColor *c = SemColor(ApolloThemeTokenQuaternaryFill, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }

+ (UIColor *)linkColor { UIColor *c = SemColor(ApolloThemeTokenLink, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }

%end

// --- theme font (per-theme app-wide font) ---
// Every hooked entry is a UIFont FACTORY: we let %orig build the exact font
// Apollo asked for, then re-derive it through the descriptor design axis
// (ApolloThemeFontApply), preserving size/weight/traits/Dynamic Type. Apollo
// is Swift, but UIFont.systemFont(ofSize:)/preferredFont(forTextStyle:)
// compile down to these class methods, so Texture attributed strings are
// covered. fontWithDescriptor:size: (our own re-derive path) is deliberately
// NOT hooked at the factory level, and neither is monospacedDigitSystemFontOfSize:
// weight: (column-aligned counters, which every design already honours) nor
// monospacedSystemFontOfSize:weight: (Apollo's markdown code blocks — NOT
// fontWithName: as previously assumed here). The latter two are still system-
// design fonts by name/family, so they DO reach the sink hooks below (setFont:,
// attributed-string rewrites); FontIsThemeable()'s FontIsMonospaced() check is
// what actually keeps code blocks monospaced, not an unhooked factory.

%hook UIFont

+ (UIFont *)systemFontOfSize:(CGFloat)size {
    return ThemedFont(%orig, (uintptr_t)__builtin_return_address(0));
}

+ (UIFont *)systemFontOfSize:(CGFloat)size weight:(UIFontWeight)weight {
    return ThemedFont(%orig, (uintptr_t)__builtin_return_address(0));
}

+ (UIFont *)boldSystemFontOfSize:(CGFloat)size {
    return ThemedFont(%orig, (uintptr_t)__builtin_return_address(0));
}

+ (UIFont *)italicSystemFontOfSize:(CGFloat)size {
    return ThemedFont(%orig, (uintptr_t)__builtin_return_address(0));
}

+ (UIFont *)preferredFontForTextStyle:(UIFontTextStyle)style {
    return ThemedFont(%orig, (uintptr_t)__builtin_return_address(0));
}

+ (UIFont *)preferredFontForTextStyle:(UIFontTextStyle)style compatibleWithTraitCollection:(UITraitCollection *)traitCollection {
    return ThemedFont(%orig, (uintptr_t)__builtin_return_address(0));
}

%end

// SF Pro Rounded has no true italic face. CoreText doesn't fail an italic
// request against it — it silently hands back an upright descriptor while
// still reporting the trait as satisfied, so the caller has no way to detect
// the failure after the fact. That caller isn't just this tweak's own code:
// Apollo's OWN markdown-to-attributedstring conversion asks OUR factory hooks
// above for a body font (getting back an already-Rounded one), then tries to
// add italic to THAT font itself via fontDescriptorWithSymbolicTraits: — and
// silently gets the same upright result, before ApolloThemeFontApply's own
// per-run theming ever sees the text. By the time a per-run fixup could look
// at it, the italic intent is already gone with no signal left to recover it.
// Catch it at the one place both call sites actually go through: redirect the
// WHOLE request to the DEFAULT (SF Pro) design at the same weight, which
// always has a real italic face, whenever a Rounded-family descriptor is
// asked for italic and doesn't already have it.
%hook UIFontDescriptor

- (UIFontDescriptor *)fontDescriptorWithSymbolicTraits:(UIFontDescriptorSymbolicTraits)symbolicTraits {
    if (sEnabled && CurrentFontChoice() == ApolloThemeFontRounded &&
        (symbolicTraits & UIFontDescriptorTraitItalic) &&
        !(self.symbolicTraits & UIFontDescriptorTraitItalic) &&
        [self.postscriptName localizedCaseInsensitiveContainsString:@"Rounded"] &&
        CallerMayUseThemeRuntime((uintptr_t)__builtin_return_address(0))) {
        // self.fontAttributes[UIFontDescriptorTraitsAttribute] isn't reliably
        // populated once a descriptor is already concrete (which this one is
        // — it came from an already-resolved .SFUIRounded-Bold-style font):
        // the weight is baked into the postscript name at that point, not
        // restated in the abstract traits dict. Resolving self into a font
        // and reading CTFontCopyTraits (same technique ApolloThemeFontApply
        // uses) is what actually reports the real weight — the traits-dict
        // read silently defaulted every case to Regular, dropping bold.
        CGFloat weight = UIFontWeightRegular;
        UIFont *selfFont = [UIFont fontWithDescriptor:self size:(self.pointSize > 0 ? self.pointSize : 17.0)];
        if (selfFont) {
            NSDictionary *ctTraits = CFBridgingRelease(CTFontCopyTraits((__bridge CTFontRef)selfFont));
            NSNumber *weightValue = ctTraits[(__bridge NSString *)kCTFontWeightTrait];
            if ([weightValue isKindOfClass:[NSNumber class]]) weight = weightValue.doubleValue;
        }
        // Set weight and the caller's full requested symbolic traits (bold,
        // italic, whatever else) TOGETHER in one combined traits dictionary.
        // fontDescriptorWithSymbolicTraits: is documented as a FAMILY-MEMBER
        // LOOKUP ("returns a new font descriptor reference in the same
        // family with the given symbolic traits"), not an attribute merge —
        // calling it after separately setting weight via
        // fontDescriptorByAddingAttributes: silently discarded the weight
        // (a bold Rounded header lost its boldness once italicized),
        // because it replaces the descriptor with whichever family member
        // matches the coarse symbolic bits, disregarding the fine-grained
        // numeric weight set moments earlier.
        UIFontDescriptor *fallback = [UIFontDescriptor preferredFontDescriptorWithTextStyle:UIFontTextStyleBody];
        return [fallback fontDescriptorByAddingAttributes:@{
            UIFontDescriptorTraitsAttribute: @{
                UIFontWeightTrait: @(weight),
                UIFontSymbolicTrait: @(symbolicTraits),
            },
        }];
    }
    return %orig;
}

%end

%hook ASTextNode

- (void)setAttributedText:(NSAttributedString *)attributedText {
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    %orig(ThemedAttributedText(attributedText, (id)self, caller));
}

%end

%hook ASTextNode2

- (void)setAttributedText:(NSAttributedString *)attributedText {
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    %orig(ThemedAttributedText(attributedText, (id)self, caller));
}

%end

%hook ASButtonNode

- (void)setAttributedTitle:(NSAttributedString *)title forState:(NSUInteger)state {
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    %orig(ThemedAttributedText(title, (id)self, caller), state);
}

- (void)setTitle:(NSString *)title withFont:(UIFont *)font withColor:(UIColor *)color forState:(NSUInteger)state {
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    %orig(title, ThemedTextSinkFont(font, (id)self, caller), ThemedTextColorForSourceColor(color, (id)self, caller), state);
}

- (void)setTitle:(NSString *)title withFont:(UIFont *)font withColor:(UIColor *)color withShadowColor:(UIColor *)shadowColor withShadowOffset:(CGSize)shadowOffset forState:(NSUInteger)state {
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    %orig(title, ThemedTextSinkFont(font, (id)self, caller), ThemedTextColorForSourceColor(color, (id)self, caller), shadowColor, shadowOffset, state);
}

%end

%hook UILabel

- (void)setFont:(UIFont *)font {
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    %orig(ThemedTextSinkFont(font, (id)self, caller));
}

- (void)setTextColor:(UIColor *)textColor {
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    %orig(ThemedTextColorForSourceColor(textColor, (id)self, caller));
}

- (void)setAttributedText:(NSAttributedString *)attributedText {
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    %orig(ThemedAttributedText(attributedText, (id)self, caller));
}

- (void)didMoveToWindow {
    %orig;
    RethemeFontOnAttach((UIView *)self);
}

%end

%hook UIButton

- (void)setAttributedTitle:(NSAttributedString *)title forState:(UIControlState)state {
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    %orig(ThemedAttributedText(title, (id)self, caller), state);
}

%end

// --- vote arrows: accent-color option (spec: kApolloThemeVoteArrowsAccentKey) ---
//
// DualStateButtonNode (the up/down vote arrow widget — Apollo.swift /
// DualStateButtonNode.swift) recolors its iconNode (an ASImageNode) on every
// appearance update via `[iconNode setImageModificationBlock:
// ASImageNodeTintColorModificationBlock(color)]` — RE'd in sub_10044bc94
// (Apollo 1.15.11): `color` is plain white while the vote is active
// (isActive==1, drawn over a separate green/blue-violet backgroundNode pill
// keyed on the `type` ivar) and a neutral gray (Apollo's shared
// tertiary-label palette helper) while inactive. We only retint the inactive
// case — swapping the idle gray for the theme's accent — and leave the
// active white-on-green/blue-violet pill alone, since that pairing is the
// actual "you voted this way" signal and forcing both directions to the same
// accent would erase it. Since ASImageNodeTintColorModificationBlock is
// AsyncDisplayKit's own public C entry point (not an Apollo-private
// address), we intercept the ObjC sink that consumes its result —
// setImageModificationBlock: — rather than the private colour-selection
// helper itself. Scoped to DualStateButtonNode's iconNode via supernode,
// since ASImageNode.setImageModificationBlock: is otherwise used for
// arbitrary icon tinting app-wide.
static Class DualStateButtonNodeClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cls = objc_getClass("_TtC6Apollo19DualStateButtonNode"); });
    return cls;
}

// AsyncDisplayKit is loaded into the host process by Apollo itself, but the
// tweak dylib doesn't link against it — resolve this public C entry point at
// runtime (like the rest of this file resolves Apollo/Texture classes via
// objc_getClass) rather than linking the framework in just for one symbol.
typedef id (*ASImageNodeTintColorModificationBlockFn)(UIColor *color);
static ASImageNodeTintColorModificationBlockFn ASImageNodeTintColorModificationBlockPtr(void) {
    static ASImageNodeTintColorModificationBlockFn fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (ASImageNodeTintColorModificationBlockFn)dlsym(RTLD_DEFAULT, "ASImageNodeTintColorModificationBlock");
    });
    return fn;
}

%hook ASImageNode

- (void)setImageModificationBlock:(id)block {
    if (sEnabled && sVoteArrowsAccent[CurrentRuntimeMode()]) {
        Class dualStateCls = DualStateButtonNodeClass();
        id supernode = dualStateCls ? [(ASDisplayNode *)self supernode] : nil;
        // isActive==YES is Apollo's own "this is the cast vote" state (white
        // icon over its green/blue-violet backgroundNode pill) — leave that
        // alone so the pill's own colour still reads as feedback. Only the
        // idle/neutral-gray icon (isActive==NO) gets the accent tint.
        if (supernode && [supernode isKindOfClass:dualStateCls] && !MSHookIvar<BOOL>(supernode, "isActive")) {
            ASImageNodeTintColorModificationBlockFn tintFn = ASImageNodeTintColorModificationBlockPtr();
            UIColor *accent = tintFn ? ApolloThemeRuntimeColor(ApolloThemeTokenAccent) : nil;
            if (accent) {
                id accentBlock = tintFn(accent);
                if (accentBlock) { %orig(accentBlock); return; }
            }
        }
    }
    %orig;
}

%end

%hook _UINavigationBarTitleControl

- (void)layoutSubviews {
    %orig;
    ApplyThemeFontToNavigationTitleControl((UIView *)self);
}

%end

%hook UITextField

- (void)setFont:(UIFont *)font {
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    %orig(ThemedTextSinkFont(font, (id)self, caller));
}

- (void)setPlaceholder:(NSString *)placeholder {
    %orig;
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    NSAttributedString *themed = ThemedPlaceholderText((UITextField *)self, self.attributedPlaceholder, caller);
    if (themed && themed != self.attributedPlaceholder) {
        self.attributedPlaceholder = themed;
    }
}

- (void)setAttributedPlaceholder:(NSAttributedString *)attributedPlaceholder {
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    %orig(ThemedPlaceholderText((UITextField *)self, attributedPlaceholder, caller));
}

- (void)setAttributedText:(NSAttributedString *)attributedText {
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    %orig(ThemedAttributedText(attributedText, (id)self, caller));
}

- (void)didMoveToWindow {
    %orig;
    RethemeFontOnAttach((UIView *)self);
}

%end

// UIKit chooses default table separators from inside UIKit itself. That call
// is intentionally outside the app/tweak caller gate on UIColor's semantic
// accessors, so enforce the semantic token on the table sink. This covers
// Apollo's native Appearance tables; Texture's comment dividers are handled
// separately below because they are independent ASDisplayNodes.
%hook UITableView

- (void)setSeparatorColor:(UIColor *)color {
    UIColor *separator = sEnabled ? ApolloThemeRuntimeColor(ApolloThemeTokenSeparator) : nil;
    %orig(separator ?: color);
}

- (void)didMoveToWindow {
    %orig;
    ApplyThemeTableSeparator(self);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig;
    ApplyThemeTableSeparator(self);
}

%end

// Comment threads use explicit ThinSeparatorCellNode objects between sections.
// Hopper (Apollo 1.15.11, sub_1003acddc) shows separatorNode receiving
// sub_10068cda0: Apollo's shared gray/muted-text palette helper. Override the
// semantic sink after the cell finishes loading so the line follows the
// Separators editor token without globally reclassifying muted text colors.
%hook _TtC6Apollo21ThinSeparatorCellNode

- (void)didLoad {
    %orig;
    ApplyThemeThinSeparatorNode(self);
}

%end

// The post header uses its own pair of ASDisplayNode hairlines, so these do not
// pass through UITableView or ThinSeparatorCellNode. Apply the same semantic
// separator token once Apollo has finished constructing/loading the header.
%hook _TtC6Apollo22CommentsHeaderCellNode

- (void)didLoad {
    %orig;
    ApplyThemeCommentsHeaderSeparators(self);
}

%end

// The main Search tab is a stock UISearchBar created by SearchViewController,
// while feed search uses ApolloSearchBarTextField below. Give both kinds of
// input the Raised token instead of allowing UIKit/Apollo's shared separator
// constant to leak into their fill.
%hook UISearchBar

- (void)didMoveToWindow {
    %orig;
    ApplyThemeSearchFieldBackground(self);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig;
    ApplyThemeSearchFieldBackground(self);
}

%end

// See the forward-declaration comment above for why this needs its own sink:
// Apollo fills this field's background from the same constant as real
// separator hairlines, so the blanket kSeparatorEntries remap would otherwise
// paint the search pill in the Advanced "Separators" color. Route it to
// "Raised" instead, matching how that token is already described in the
// editor ("inset controls and elevated panels").
%hook _TtC6Apollo24ApolloSearchBarTextField

- (void)setBackgroundColor:(UIColor *)color {
    UIColor *raised = ApolloThemeRuntimeColor(ApolloThemeTokenTertiaryBackground);
    %orig(raised ?: color);
}

%end

%hook UITextView

- (void)setFont:(UIFont *)font {
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    %orig(ThemedTextSinkFont(font, (id)self, caller));
}

- (void)setAttributedText:(NSAttributedString *)attributedText {
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    %orig(ThemedAttributedText(attributedText, (id)self, caller));
}

- (void)didMoveToWindow {
    %orig;
    RethemeFontOnAttach((UIView *)self);
}

%end

%end // ApolloThemeRuntimeHooks

// ===========================================================================
// Constructor
// ===========================================================================

%ctor {
    @autoreleasepool {
        FindRuntimeImages();
        BuildByteFilter();
        %init(ApolloThemeRuntimeHooks);
        BOOL haveTM = objc_getClass("_TtC6Apollo12ThemeManager") != nil;
        if (haveTM) %init(ApolloThemeRuntimeManagerHook);
        ApolloLog(@"ThemeRuntime: ctor — UIColor hooks installed, ThemeManager hook=%d", haveTM);
        // Crash kill-switch bookkeeping + initial compile.
        ApolloThemeStore *store = [ApolloThemeStore shared];
        ApolloThemeGalleryRegisterWithStore();
        [store migrateIfNeeded];
        [store beginLaunchAttempt];
        if (store.runtimeDisabledDueToCrash)
            ApolloLog(@"ThemeRuntime: ctor — runtime DISABLED by crash kill-switch");
        ApolloThemeRuntimeReload();
        // Mark launch stable once the UI has had time to come up (the feed
        // renders within ~1-3s; 5s clears the kill-switch marker for a healthy
        // launch while still catching a theme that crashes during startup).
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [store markLaunchStable]; });
    }
}
