#import "ApolloThemeTokens.h"

// ApolloThemeStore — persistence + lifecycle for v2 themes (spec §5, §14, §15, §18).
//
// Owns the v2 theme schema in the Apollo app-group defaults (so themes ride
// along with Backup/Restore Settings), v1->v2 migration, active/previous-theme
// tracking, strict import/export, and the crash kill-switch markers. It is data
// only: it does NOT touch Apollo's live theme or any UIColor hooks — the Runtime
// layer orchestrates activation and consumes the Store.

__BEGIN_DECLS

NS_ASSUME_NONNULL_BEGIN

// What kind of theme the active-selection pointer names. "Apollo" means the
// custom runtime is inactive and Apollo's own theme system is in charge —
// there is no separate enable flag; enablement is DERIVED from this.
typedef NS_ENUM(NSUInteger, ApolloThemeSelectionKind) {
    ApolloThemeSelectionApollo = 0,
    ApolloThemeSelectionCustom,   // a stored theme (My Themes / Imported), by id
    ApolloThemeSelectionGallery,  // a catalog preset, by slug (applied by reference)
};

typedef NS_ENUM(NSUInteger, ApolloThemeApplyTarget) {
    ApolloThemeApplyTargetBoth = 0,
    ApolloThemeApplyTargetLight,
    ApolloThemeApplyTargetDark,
};

// Resolves a gallery slug to a theme-shaped dict (name/input/variant/advanced/
// font) or nil. Registered by the gallery catalog module at load; absent
// resolver = every slug unresolvable (older build), which falls back to Apollo.
typedef NSDictionary *_Nullable (^ApolloThemeGalleryResolver)(NSString *slug);

@interface ApolloThemeStore : NSObject

+ (instancetype)shared;

#pragma mark - Active selection (spec: hub IA)

// Raw pointer kind, no fallback — what the user last chose, even if a gallery
// slug no longer resolves. Recovery/summary UI wants this.
- (ApolloThemeSelectionKind)storedSelectionKind;
// Resolved kind: gallery pointer whose slug doesn't resolve reads as Apollo
// (non-destructively — the pointer is left intact so a later build that knows
// the slug brings the theme back, e.g. Backup/Restore across versions).
- (ApolloThemeSelectionKind)activeSelectionKind;

- (void)selectApolloTheme;                       // custom runtime off; keeps last id/slug as memory
- (void)selectCustomTheme:(NSString *)themeID;   // stored theme active
- (void)selectGalleryTheme:(NSString *)slug;     // catalog preset active, by reference
- (void)selectCustomTheme:(NSString *)themeID forTarget:(ApolloThemeApplyTarget)target;
- (void)selectGalleryTheme:(NSString *)slug forTarget:(ApolloThemeApplyTarget)target;
// Flip an "apollo" pointer back to the remembered custom/gallery selection
// (falling back to the first stored theme). NO when there is nothing to
// restore; already-custom pointers are kept as-is.
- (BOOL)restoreLastCustomSelection;

// Stored slug when the pointer is (or remembers) a gallery selection.
- (nullable NSString *)activeGallerySlug;

// Derived: resolved kind != Apollo, and the crash kill-switch hasn't tripped.
// Read-only — change it by selecting something.
@property (nonatomic, readonly) BOOL customThemeEnabled;

#pragma mark - Gallery catalog bridge

+ (void)registerGalleryResolver:(nullable ApolloThemeGalleryResolver)resolver;
// Synthesized read-only theme dict for a catalog slug (id "gallery:<slug>",
// origin "gallery") or nil when unknown. Never persisted into allThemes.
- (nullable NSDictionary *)galleryThemeForSlug:(nullable NSString *)slug;

#pragma mark - Themes

// All stored v2 theme dicts, in creation order.
- (NSArray<NSDictionary *> *)allThemes;
- (nullable NSDictionary *)themeWithID:(NSString *)themeID;

// The stored theme id when the pointer kind is Custom, else nil. The setter is
// a selection shim: non-nil selects that custom theme, nil selects Apollo.
@property (nonatomic, copy, nullable) NSString *activeThemeID;
// Resolved theme dict for the pointer: stored theme for Custom, synthesized
// catalog dict for Gallery, nil for Apollo.
- (nullable NSDictionary *)activeTheme;
- (nullable NSDictionary *)themeForMode:(ApolloThemeMode)mode;
- (BOOL)isCustomThemeID:(NSString *)themeID selectedForMode:(ApolloThemeMode)mode;
- (BOOL)isGallerySlug:(NSString *)slug selectedForMode:(ApolloThemeMode)mode;

// Enabling snapshots the current selection into both slots. Disabling keeps
// the currently-effective slot as the ordinary single selection.
@property (nonatomic) BOOL separateThemesEnabled;

#pragma mark - CRUD

// Create a theme; returns its fresh id. `input` follows the v2 "input" schema
// (light/dark dicts). Pass nil for a neutral starter palette.
- (NSString *)createThemeNamed:(nullable NSString *)name
                         input:(nullable NSDictionary *)input
                       variant:(ApolloThemeVariant)variant
           advancedOptionsEnabled:(BOOL)advancedOptionsEnabled
                    generation:(nullable NSDictionary *)generation;

// Mutate a stored theme in place (bumps updatedAt, persists). No-op if missing.
- (void)updateTheme:(NSString *)themeID mutations:(void (^)(NSMutableDictionary *theme))block;

- (nullable NSString *)duplicateTheme:(NSString *)themeID; // returns new id
- (void)renameTheme:(NSString *)themeID to:(NSString *)name;
- (BOOL)deleteTheme:(NSString *)themeID;

// Editor conveniences.
- (void)setInputHex:(nullable NSString *)hex
             forKey:(NSString *)inputKey
               mode:(ApolloThemeMode)mode
            themeID:(NSString *)themeID;
- (void)setVariant:(ApolloThemeVariant)variant themeID:(NSString *)themeID;
- (void)setFont:(ApolloThemeFont)font themeID:(NSString *)themeID;
// Fill the opposite mode from the given source mode (spec §4.3).
- (void)generateMode:(ApolloThemeMode)destMode
            fromMode:(ApolloThemeMode)srcMode
             themeID:(NSString *)themeID;

#pragma mark - Lifecycle bookkeeping (spec §8)

// Apollo's real selected theme, saved before the donor hijack so it can be
// restored on disable.
@property (nonatomic, copy, nullable) NSString *previousApolloTheme;
// Internal runtime donor name ("outrun"), versioned so it can change later.
- (NSString *)runtimeDonorTheme;

#pragma mark - Migration (spec §15)

// Idempotent: migrates v1 (standard-defaults, role.mode colours) into v2 on
// first v2 launch, archiving v1 data under the backup key for one release.
- (void)migrateIfNeeded;

#pragma mark - Import / export (spec §14)

// Portable export: schemaVersion, name, variant, input, optional locks +
// generation. No id/timestamps/account data/donor/previous-theme.
- (NSData *)exportDataForTheme:(NSDictionary *)theme;
// Strict parse. Returns a normalised portable dict (name/variant/input/...) or
// nil with *error set. Does NOT persist.
- (nullable NSDictionary *)parseImportData:(NSData *)data error:(NSString *_Nullable *_Nullable)error;
// Persist a parsed import as a brand-new theme (mints a fresh id; never
// overwrites). Returns the new id.
- (NSString *)importParsedTheme:(NSDictionary *)parsed;
// Reject files larger than this BEFORE reading them fully into memory.
+ (NSUInteger)maxImportBytes;
- (NSString *)exportFilenameForName:(NSString *)name;

#pragma mark - Crash kill-switch (spec §18)

- (void)beginLaunchAttempt;     // call early, before runtime activation
- (void)markLaunchStable;       // call once the app reaches a stable point
- (BOOL)runtimeDisabledDueToCrash;
- (void)clearCrashDisable;      // user re-enables from Theme Manager

@end

NS_ASSUME_NONNULL_END

__END_DECLS
