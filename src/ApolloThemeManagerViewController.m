#import "ApolloThemeManagerViewController.h"
#import "ApolloThemeTokens.h"
#import "ApolloThemeStore.h"
#import "ApolloThemeCompiler.h"
#import "ApolloThemeRuntime.h"
#import "ApolloCommon.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// ---------------------------------------------------------------------------
// Small swatch helper
// ---------------------------------------------------------------------------

static UIImage *SwatchImage(UIColor *color, CGFloat side) {
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0.5, 0.5, side - 1, side - 1) cornerRadius:6];
        [(color ?: UIColor.tertiarySystemFillColor) setFill];
        [p fill];
        [[UIColor.separatorColor colorWithAlphaComponent:0.5] setStroke];
        p.lineWidth = 1;
        [p stroke];
    }];
}

// Two-swatch (light/dark) preview image for the theme list.
static UIImage *DualSwatchImage(UIColor *light, UIColor *dark, CGFloat side) {
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *clip = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0.5, 0.5, side - 1, side - 1) cornerRadius:7];
        [clip addClip];
        [(light ?: UIColor.systemBackgroundColor) setFill];
        UIRectFill(CGRectMake(0, 0, side, side));
        UIBezierPath *tri = [UIBezierPath bezierPath];
        [tri moveToPoint:CGPointMake(side, 0)];
        [tri addLineToPoint:CGPointMake(side, side)];
        [tri addLineToPoint:CGPointMake(0, side)];
        [tri closePath];
        [(dark ?: UIColor.secondarySystemBackgroundColor) setFill];
        [tri fill];
        [[UIColor.separatorColor colorWithAlphaComponent:0.6] setStroke];
        clip.lineWidth = 1; [clip stroke];
    }];
}

// ---------------------------------------------------------------------------

@interface ApolloThemeManagerViewController () <UIColorPickerViewControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, copy) NSString *editingThemeID;     // nil = list mode
@property (nonatomic, assign) ApolloThemeMode editingMode; // which appearance the editor shows
@property (nonatomic, copy) NSString *pickingInputKey;     // input key currently in the colour picker
@property (nonatomic, strong) ApolloCompiledTheme *previewCompiled; // cached for editor preview
@end

@implementation ApolloThemeManagerViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (instancetype)initEditorForThemeID:(NSString *)themeID {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) { _editingThemeID = [themeID copy]; _editingMode = ApolloThemeModeLight; }
    return self;
}

- (ApolloThemeStore *)store { return [ApolloThemeStore shared]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    ApolloLog(@"ThemeUI: viewDidLoad mode=%@ themeID=%@", self.editingThemeID ? @"editor" : @"list", self.editingThemeID ?: @"-");
    if (self.editingThemeID) {
        NSDictionary *t = [[self store] themeWithID:self.editingThemeID];
        self.title = t[@"name"] ?: @"Edit Theme";
        [self recompilePreview];
    } else {
        self.title = @"Theme Manager";
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                          target:self action:@selector(newThemeTapped)];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self recompilePreview];
    [self.tableView reloadData];
}

- (void)recompilePreview {
    if (!self.editingThemeID) { self.previewCompiled = nil; return; }
    NSDictionary *t = [[self store] themeWithID:self.editingThemeID];
    self.previewCompiled = [ApolloCompiledTheme compiledThemeWithInput:t[@"input"]
                                                               variant:ApolloThemeVariantFromKey(t[@"variant"])];
}

- (UIColor *)previewColorForToken:(ApolloThemeToken)token {
    uint32_t rgb = [self.previewCompiled rgbForToken:token mode:self.editingMode];
    return ApolloThemeUIColorFromRGB(rgb);
}

// ===========================================================================
// Section layout
// ===========================================================================
// List mode:   0 Enable | 1 Themes | 2 New/Import
// Editor mode: 0 Name | 1 Variant+Mode | 2 Colours | 3 Advanced | 4 Generate
//              5 Preview | 6 Apply

enum { LSEnable, LSThemes, LSActions, LSCount };
enum { ESName, ESVariant, ESColors, ESAdvanced, ESGenerate, ESPreview, ESApply, ESCount };

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.editingThemeID ? ESCount : LSCount;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    if (self.editingThemeID) {
        switch (section) {
            case ESName:     return 1;
            case ESVariant:  return 1;  // appearance mode (Light/Dark) only — variant is AI-only
            case ESColors:   return ApolloThemeDefaultInputKeys().count;
            case ESAdvanced: return ApolloThemeAdvancedInputKeys().count;
            case ESGenerate: return 1;
            case ESPreview:  return 4;
            case ESApply:    return 1;
        }
        return 0;
    }
    switch (section) {
        case LSEnable:  return 1;
        case LSThemes:  return MAX((NSInteger)[[self store] allThemes].count, 0);
        case LSActions: return 2; // New, Import
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    if (self.editingThemeID) {
        switch (section) {
            case ESColors:   return @"Colours";
            case ESAdvanced: return @"Advanced (optional)";
            case ESPreview:  return @"Preview";
        }
        return nil;
    }
    if (section == LSThemes) return @"Themes";
    return nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (self.editingThemeID && section == ESAdvanced)
        return @"Leave blank to derive text and separators automatically.";
    if (self.editingThemeID && section == ESApply)
        return @"Applying selects this theme and enables custom theming.";
    if (!self.editingThemeID && section == LSEnable && [[self store] runtimeDisabledDueToCrash])
        return @"Custom themes were disabled after a crash. Re-enabling will retry.";
    return nil;
}

// ===========================================================================
// Cells
// ===========================================================================

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    return self.editingThemeID ? [self editorCellForIndexPath:ip] : [self listCellForIndexPath:ip];
}

#pragma mark - List cells

- (UITableViewCell *)listCellForIndexPath:(NSIndexPath *)ip {
    ApolloThemeStore *store = [self store];
    if (ip.section == LSEnable) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text = @"Custom Theme";
        NSDictionary *active = [store activeTheme];
        cell.detailTextLabel.text = store.customThemeEnabled ? (active[@"name"] ?: @"On") : @"Off";
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = store.customThemeEnabled;
        [sw addTarget:self action:@selector(enableSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    if (ip.section == LSThemes) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        NSDictionary *theme = [store allThemes][ip.row];
        cell.textLabel.text = theme[@"name"];
        ApolloCompiledTheme *c = [ApolloCompiledTheme compiledThemeWithInput:theme[@"input"]
                                                                     variant:ApolloThemeVariantFromKey(theme[@"variant"])];
        UIColor *l = ApolloThemeUIColorFromRGB([c rgbForToken:ApolloThemeTokenAccent mode:ApolloThemeModeLight]);
        UIColor *d = ApolloThemeUIColorFromRGB([c rgbForToken:ApolloThemeTokenBackground mode:ApolloThemeModeDark]);
        cell.imageView.image = DualSwatchImage(l, d, 29);
        // Whole row opens the editor (disclosure chevron). Active theme shown via
        // a checkmark in the detail text when custom theming is on.
        BOOL active = [theme[@"id"] isEqualToString:store.activeThemeID] && store.customThemeEnabled;
        cell.detailTextLabel.text = active ? @"✓ Active" : nil;
        cell.detailTextLabel.textColor = self.view.tintColor;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    // Actions
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (ip.row == 0) {
        cell.textLabel.text = @"New Theme";
        cell.imageView.image = [UIImage systemImageNamed:@"plus.circle"];
    } else {
        cell.textLabel.text = @"Import Theme…";
        cell.imageView.image = [UIImage systemImageNamed:@"square.and.arrow.down"];
    }
    cell.textLabel.textColor = self.view.tintColor;
    return cell;
}

#pragma mark - Editor cells

- (UITableViewCell *)editorCellForIndexPath:(NSIndexPath *)ip {
    NSDictionary *theme = [[self store] themeWithID:self.editingThemeID];
    NSString *modeKey = ApolloThemeModeKey(self.editingMode);
    NSDictionary *modeInput = theme[@"input"][modeKey];

    switch (ip.section) {
        case ESName: {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
            cell.textLabel.text = @"Name";
            cell.detailTextLabel.text = theme[@"name"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        case ESVariant: {
            // Appearance (Light/Dark) only. The subtle/balanced/bold variant is
            // an AI-generation concept and is not user-editable here.
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.text = @"Appearance";
            UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"Light", @"Dark"]];
            seg.selectedSegmentIndex = self.editingMode;
            [seg addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = seg;
            return cell;
        }
        case ESColors:
        case ESAdvanced: {
            NSArray *keys = (ip.section == ESColors) ? ApolloThemeDefaultInputKeys() : ApolloThemeAdvancedInputKeys();
            NSString *key = keys[ip.row];
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
            cell.textLabel.text = ApolloThemeInputDisplayName(key);
            id raw = modeInput[key];
            uint32_t rgb = 0;
            if ([raw isKindOfClass:[NSString class]] && ApolloThemeParseHex(raw, &rgb)) {
                cell.detailTextLabel.text = [@"#" stringByAppendingString:ApolloThemeHexFromRGB(rgb)];
                cell.imageView.image = SwatchImage(ApolloThemeUIColorFromRGB(rgb), 29);
            } else {
                cell.detailTextLabel.text = @"Auto";
                cell.imageView.image = SwatchImage(nil, 29);
            }
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        case ESGenerate: {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            ApolloThemeMode other = (self.editingMode == ApolloThemeModeLight) ? ApolloThemeModeDark : ApolloThemeModeLight;
            cell.textLabel.text = [NSString stringWithFormat:@"Generate %@ from %@",
                                   ApolloThemeModeKey(other), modeKey];
            cell.textLabel.textColor = self.view.tintColor;
            cell.imageView.image = [UIImage systemImageNamed:@"wand.and.stars"];
            return cell;
        }
        case ESPreview:
            return [self previewCellForRow:ip.row];
        case ESApply: {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            cell.textLabel.text = @"Apply Theme";
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            cell.textLabel.textColor = self.view.tintColor;
            return cell;
        }
    }
    return [[UITableViewCell alloc] init];
}

- (UITableViewCell *)previewCellForRow:(NSInteger)row {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UIColor *card = [self previewColorForToken:ApolloThemeTokenSecondaryBackground];
    UIColor *label = [self previewColorForToken:ApolloThemeTokenLabel];
    UIColor *secondary = [self previewColorForToken:ApolloThemeTokenSecondaryLabel];
    UIColor *accent = [self previewColorForToken:ApolloThemeTokenAccent];
    UIColor *sep = [self previewColorForToken:ApolloThemeTokenSeparator];
    cell.backgroundColor = card;
    cell.textLabel.textColor = label;
    cell.detailTextLabel.textColor = secondary;
    UIView *selBG = [[UIView alloc] init];
    selBG.backgroundColor = [self previewColorForToken:ApolloThemeTokenSelection];
    cell.selectedBackgroundView = selBG;
    switch (row) {
        case 0:
            cell.textLabel.text = @"Post title goes here";
            cell.detailTextLabel.text = @"r/apollo · 3h · 142 points";
            cell.imageView.image = [[UIImage systemImageNamed:@"arrow.up"] imageWithTintColor:accent renderingMode:UIImageRenderingModeAlwaysOriginal];
            break;
        case 1:
            cell.textLabel.text = @"A comment with body text";
            cell.detailTextLabel.text = @"username · reply";
            cell.imageView.image = [[UIImage systemImageNamed:@"bubble.left"] imageWithTintColor:secondary renderingMode:UIImageRenderingModeAlwaysOriginal];
            break;
        case 2:
            cell.textLabel.text = @"Tinted link / button";
            cell.textLabel.textColor = accent;
            cell.detailTextLabel.text = nil;
            cell.imageView.image = [[UIImage systemImageNamed:@"link"] imageWithTintColor:accent renderingMode:UIImageRenderingModeAlwaysOriginal];
            break;
        default:
            cell.textLabel.text = @"Selected / tapped row";
            cell.detailTextLabel.text = nil;
            cell.backgroundColor = [self previewColorForToken:ApolloThemeTokenSelection];
            cell.imageView.image = SwatchImage(sep, 22);
            break;
    }
    return cell;
}

// ===========================================================================
// Selection
// ===========================================================================

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (self.editingThemeID) { [self editorDidSelect:ip]; return; }
    [self listDidSelect:ip];
}

- (void)listDidSelect:(NSIndexPath *)ip {
    if (ip.section == LSThemes) {
        // Whole row opens the editor (where Apply sets it active). No more 'i' button.
        NSDictionary *theme = [[self store] allThemes][ip.row];
        [self openEditorForThemeID:theme[@"id"]];
        return;
    }
    if (ip.section == LSActions) {
        if (ip.row == 0) [self newThemeTapped];
        else [self importTapped];
    }
}

- (void)editorDidSelect:(NSIndexPath *)ip {
    switch (ip.section) {
        case ESName: [self renameTapped]; break;
        case ESColors:
            [self beginPickingInputKey:ApolloThemeDefaultInputKeys()[ip.row]]; break;
        case ESAdvanced:
            [self beginPickingInputKey:ApolloThemeAdvancedInputKeys()[ip.row]]; break;
        case ESGenerate: [self generateOppositeMode]; break;
        case ESApply: [self applyTheme]; break;
    }
}

// ===========================================================================
// List actions
// ===========================================================================

- (void)enableSwitchChanged:(UISwitch *)sw {
    ApolloLog(@"ThemeUI: enable switch -> %@", sw.on ? @"ON" : @"OFF");
    ApolloThemeStore *store = [self store];
    if (sw.on) {
        if ([store runtimeDisabledDueToCrash]) [store clearCrashDisable];
        if ([store allThemes].count == 0) {
            ApolloLog(@"ThemeUI: no themes yet — creating starter before enable");
            [store createThemeNamed:@"My Theme" input:nil variant:ApolloThemeVariantBalanced generation:nil];
        }
        ApolloThemeRuntimeEnable();
    } else {
        ApolloThemeRuntimeDisable();
    }
    [self.tableView reloadData];
    ApolloLog(@"ThemeUI: enable switch handled");
}

- (void)newThemeTapped {
    ApolloLog(@"ThemeUI: New Theme tapped");
    ApolloThemeStore *store = [self store];
    NSString *newID = [store createThemeNamed:@"My Theme" input:nil variant:ApolloThemeVariantBalanced generation:nil];
    [self.tableView reloadData];
    ApolloLog(@"ThemeUI: New Theme created id=%@ — opening editor", newID);
    [self openEditorForThemeID:newID];
}

- (void)openEditorForThemeID:(NSString *)themeID {
    ApolloLog(@"ThemeUI: opening editor for theme %@", themeID);
    ApolloThemeManagerViewController *editor = [[ApolloThemeManagerViewController alloc] initEditorForThemeID:themeID];
    [self.navigationController pushViewController:editor animated:YES];
}

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (self.editingThemeID || ip.section != LSThemes || style != UITableViewCellEditingStyleDelete) return;
    NSDictionary *theme = [[self store] allThemes][ip.row];
    [[self store] deleteTheme:theme[@"id"]];
    [self.tableView reloadData];
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip {
    return !self.editingThemeID && ip.section == LSThemes;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (self.editingThemeID || ip.section != LSThemes) return nil;
    NSDictionary *theme = [[self store] allThemes][ip.row];
    UIContextualAction *dup = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
        title:@"Duplicate" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            [[self store] duplicateTheme:theme[@"id"]];
            [self.tableView reloadData];
            done(YES);
        }];
    UIContextualAction *exp = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
        title:@"Export" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            [self exportTheme:theme]; done(YES);
        }];
    exp.backgroundColor = UIColor.systemBlueColor;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"Delete" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            [[self store] deleteTheme:theme[@"id"]];
            [self.tableView reloadData];
            done(YES);
        }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del, exp, dup]];
}

// ===========================================================================
// Editor actions
// ===========================================================================

- (void)modeChanged:(UISegmentedControl *)seg {
    self.editingMode = (ApolloThemeMode)seg.selectedSegmentIndex;
    [self.tableView reloadData];
}

- (void)renameTapped {
    NSDictionary *theme = [[self store] themeWithID:self.editingThemeID];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Rename Theme"
                                                                 message:nil
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.text = theme[@"name"]; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = alert.textFields.firstObject.text;
        [[self store] renameTheme:self.editingThemeID to:name];
        self.title = [[self store] themeWithID:self.editingThemeID][@"name"];
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)beginPickingInputKey:(NSString *)key {
    self.pickingInputKey = key;
    NSDictionary *theme = [[self store] themeWithID:self.editingThemeID];
    id raw = theme[@"input"][ApolloThemeModeKey(self.editingMode)][key];
    uint32_t rgb = 0;
    UIColor *start = ([raw isKindOfClass:[NSString class]] && ApolloThemeParseHex(raw, &rgb))
        ? ApolloThemeUIColorFromRGB(rgb) : UIColor.systemGray3Color;
    UIColorPickerViewController *picker = [[UIColorPickerViewController alloc] init];
    picker.delegate = self;
    picker.selectedColor = start;
    picker.supportsAlpha = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (BOOL)isAdvancedKey:(NSString *)key { return [ApolloThemeAdvancedInputKeys() containsObject:key]; }

- (void)saveColor:(UIColor *)color forCurrentKey:(BOOL)clear {
    if (!self.pickingInputKey) return;
    NSString *hex = (clear || !color) ? nil : ApolloThemeHexFromRGB(ApolloThemeRGBFromUIColor(color));
    [[self store] setInputHex:hex forKey:self.pickingInputKey mode:self.editingMode themeID:self.editingThemeID];
    [self recompilePreview];
    [self maybeLiveReload];
    [self.tableView reloadData];
}

- (void)generateOppositeMode {
    ApolloThemeMode other = (self.editingMode == ApolloThemeModeLight) ? ApolloThemeModeDark : ApolloThemeModeLight;
    [[self store] generateMode:other fromMode:self.editingMode themeID:self.editingThemeID];
    [self recompilePreview];
    [self maybeLiveReload];
    UINotificationFeedbackGenerator *fb = [[UINotificationFeedbackGenerator alloc] init];
    [fb notificationOccurred:UINotificationFeedbackTypeSuccess];
    [self.tableView reloadData];
}

- (void)applyTheme {
    ApolloLog(@"ThemeUI: Apply tapped for theme %@", self.editingThemeID);
    ApolloThemeStore *store = [self store];
    store.activeThemeID = self.editingThemeID;
    if ([store runtimeDisabledDueToCrash]) [store clearCrashDisable];
    ApolloThemeRuntimeEnable();
    [self.navigationController popViewControllerAnimated:YES];
}

// Re-apply live if this theme is the active, enabled one.
- (void)maybeLiveReload {
    ApolloThemeStore *store = [self store];
    if (store.customThemeEnabled && [store.activeThemeID isEqualToString:self.editingThemeID]) {
        ApolloThemeRuntimeReload();
        ApolloThemeRuntimeInvalidate();
    }
}

// ===========================================================================
// UIColorPickerViewControllerDelegate
// ===========================================================================

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)picker {
    [self saveColor:picker.selectedColor forCurrentKey:NO];
    self.pickingInputKey = nil;
}

// ===========================================================================
// Import / export
// ===========================================================================

- (void)importTapped {
    UTType *json = UTTypeJSON ?: [UTType typeWithIdentifier:@"public.json"];
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[json]];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    // Reject oversized files BEFORE reading into memory (spec §14.2).
    NSNumber *size = nil;
    [url getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
    if (size && size.unsignedLongLongValue > [ApolloThemeStore maxImportBytes]) {
        if (scoped) [url stopAccessingSecurityScopedResource];
        [self showError:@"That file is too large to be a theme."];
        return;
    }
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (scoped) [url stopAccessingSecurityScopedResource];
    NSString *err = nil;
    NSDictionary *parsed = [[self store] parseImportData:data error:&err];
    if (!parsed) { [self showError:err ?: @"Couldn't read that theme."]; return; }
    [self confirmImport:parsed];
}

- (void)confirmImport:(NSDictionary *)parsed {
    NSString *msg = [NSString stringWithFormat:@"Import \"%@\" (%@) as a new theme?",
                     parsed[@"name"], [parsed[@"variant"] capitalizedString]];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Import Theme"
                                                              message:msg
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Import" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *newID = [[self store] importParsedTheme:parsed];
        [self.tableView reloadData];
        [self openEditorForThemeID:newID];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)exportTheme:(NSDictionary *)theme {
    NSData *data = [[self store] exportDataForTheme:theme];
    if (!data) { [self showError:@"Couldn't export that theme."]; return; }
    NSString *name = [[self store] exportFilenameForName:theme[@"name"]];
    NSURL *tmp = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:name];
    [data writeToURL:tmp atomically:YES];
    UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[tmp] applicationActivities:nil];
    av.popoverPresentationController.sourceView = self.view;
    av.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:av animated:YES completion:nil];
}

- (void)showError:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Theme"
                                                             message:message
                                                      preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
