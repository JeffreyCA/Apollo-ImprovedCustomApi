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

@interface ApolloThemeStore : NSObject

+ (instancetype)shared;

#pragma mark - Enable flag

@property (nonatomic) BOOL customThemeEnabled;

#pragma mark - Themes

// All stored v2 theme dicts, in creation order.
- (NSArray<NSDictionary *> *)allThemes;
- (nullable NSDictionary *)themeWithID:(NSString *)themeID;

@property (nonatomic, copy, nullable) NSString *activeThemeID;
- (nullable NSDictionary *)activeTheme;

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
