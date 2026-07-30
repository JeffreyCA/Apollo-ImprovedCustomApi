#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"

// MARK: - Character counter for the "Message Moderators" subject field
//
// Tapping "Message Moderators" at the bottom of a subreddit's moderator list
// opens Apollo's own action sheet (`ActionController`) whose header is a
// `TextEntryView` with a single "Subject" field and one "Continue" action.
//
// Apollo caps that subject at 25 characters: the field's text-changed handler
// flips `ActionController.actionsEnabled` to NO as soon as the subject is empty
// OR longer than 25 (verified in the binary — the handler reached from
// -[SubredditModeratorListViewController tableView:didSelectRowAtIndexPath:]
// tests `String.count > 0x19`). Nothing on screen says so: the only feedback is
// Continue greying out, which reads as "something is broken" rather than "your
// subject is too long".
//
// Fix: hang a right-aligned "n/25" counter inside the subject field. It turns
// red the moment the count passes 25, so the disabled Continue button has a
// visible cause. Reddit's other compose sheets share the TextEntryView class but
// NOT the limit (the new-message sheet allows 100, the modmail "Create
// Conversation" sheet 100), so this hooks the one entry point that produces the
// 25-character sheet rather than decorating every subject field in the app.

static const NSInteger kApolloModSubjectMaxLength = 25;

@interface _TtC6Apollo16ActionController : UIViewController
@end

@interface _TtC6Apollo13TextEntryView : UIView
@end

static char kApolloSubjectCounterLabelKey;   // on the field: the "n/25" label
static char kApolloSubjectCounterClearKey;   // on the field: our stand-in clear button
static char kApolloSubjectCounterModeKey;    // on the field: the clear-button mode we took over

static id ApolloSubjectCounterIvar(id obj, const char *name) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    return iv ? object_getIvar(obj, iv) : nil;
}

// Apollo counts with Swift's `String.count`, i.e. grapheme clusters — an emoji
// is one character there and two or more UTF-16 units in `NSString.length`.
// Count composed character sequences so the counter flips red on exactly the
// keystroke that disables Continue.
static NSInteger ApolloSubjectCounterLength(NSString *text) {
    if (text.length == 0) return 0;
    __block NSInteger count = 0;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(__unused NSString *sub, __unused NSRange r, __unused NSRange e, __unused BOOL *stop) {
        count++;
    }];
    return count;
}

// UIKit gives `rightView` and the built-in clear button the same slot and shows
// only the rightView, so adopting the slot would silently cost the field its
// clear button. We take the mode over instead and lay out our own stand-in
// alongside the counter, keeping the field's behaviour unchanged.
static BOOL ApolloSubjectCounterShouldShowClear(UITextField *field) {
    UITextFieldViewMode mode = (UITextFieldViewMode)[objc_getAssociatedObject(field, &kApolloSubjectCounterModeKey) integerValue];
    if (mode == UITextFieldViewModeNever) return NO;
    if (mode == UITextFieldViewModeAlways) return YES;
    if (field.text.length == 0) return NO;
    return (mode == UITextFieldViewModeWhileEditing) ? field.isEditing : !field.isEditing;
}

static void ApolloSubjectCounterRefresh(UITextField *field) {
    UILabel *label = objc_getAssociatedObject(field, &kApolloSubjectCounterLabelKey);
    if (![label isKindOfClass:[UILabel class]]) return;
    UIView *container = label.superview;
    if (!container) return;
    UIButton *clearButton = objc_getAssociatedObject(field, &kApolloSubjectCounterClearKey);

    NSInteger length = ApolloSubjectCounterLength(field.text);
    BOOL over = length > kApolloModSubjectMaxLength;
    label.text = [NSString stringWithFormat:@"%ld/%ld", (long)length, (long)kApolloModSubjectMaxLength];
    // Red is the error signal here, not an accent — it has to read as "this is
    // why Continue is off" in every theme, so it stays systemRed. The resting
    // colour is derived from the field's own text colour so it sits correctly
    // against whatever theme is painting the sheet.
    UIColor *resting = [(field.textColor ?: [UIColor labelColor]) colorWithAlphaComponent:0.45];
    label.textColor = over ? [UIColor systemRedColor] : resting;
    clearButton.tintColor = resting;
    [label sizeToFit];

    static const CGFloat kClearSide = 19.0;   // matches UIKit's built-in clear button
    static const CGFloat kGap = 6.0;
    static const CGFloat kTrailingInset = 6.0;

    BOOL showClear = clearButton && ApolloSubjectCounterShouldShowClear(field);
    clearButton.hidden = !showClear;

    CGFloat labelWidth = ceil(CGRectGetWidth(label.bounds));
    CGFloat labelHeight = ceil(CGRectGetHeight(label.bounds));
    CGFloat height = MAX(labelHeight, kClearSide);
    CGFloat width = labelWidth + kTrailingInset + (showClear ? kGap + kClearSide : 0.0);

    container.bounds = CGRectMake(0, 0, width, height);
    label.frame = CGRectMake(0, (height - labelHeight) / 2.0, labelWidth, labelHeight);
    clearButton.frame = CGRectMake(labelWidth + kGap, (height - kClearSide) / 2.0, kClearSide, kClearSide);
    [field setNeedsLayout];
}

@interface ApolloSubjectCounterTarget : NSObject
@end

@implementation ApolloSubjectCounterTarget
- (void)textChanged:(UITextField *)field {
    if ([field isKindOfClass:[UITextField class]]) ApolloSubjectCounterRefresh(field);
}

- (void)clearTapped:(UIButton *)button {
    UITextField *field = (UITextField *)button.superview.superview;
    if (![field isKindOfClass:[UITextField class]]) return;
    if ([field.delegate respondsToSelector:@selector(textFieldShouldClear:)] &&
        ![field.delegate textFieldShouldClear:field]) {
        return;
    }
    field.text = @"";
    // Apollo enables/disables the sheet's "Continue" action from the field's own
    // change callback, so a programmatic clear has to announce itself the same
    // way a keystroke does — otherwise Continue would stay enabled on an empty
    // subject. Both channels are fired because the app's wiring (target/action
    // vs. notification) is a Swift closure we don't own.
    [field sendActionsForControlEvents:UIControlEventEditingChanged];
    [[NSNotificationCenter defaultCenter] postNotificationName:UITextFieldTextDidChangeNotification object:field];
    ApolloSubjectCounterRefresh(field);
}

- (void)editingStateChanged:(UITextField *)field {
    if ([field isKindOfClass:[UITextField class]]) ApolloSubjectCounterRefresh(field);
}
@end

// UIControl does not retain its targets, so the shared one has to outlive every
// sheet it is wired into.
static ApolloSubjectCounterTarget *ApolloSubjectCounterSharedTarget(void) {
    static ApolloSubjectCounterTarget *target;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ target = [ApolloSubjectCounterTarget new]; });
    return target;
}

static void ApolloSubjectCounterAttach(UITextField *field) {
    if (![field isKindOfClass:[UITextField class]]) return;
    if (objc_getAssociatedObject(field, &kApolloSubjectCounterLabelKey)) return;   // already decorated

    UILabel *label = [[UILabel alloc] init];
    CGFloat base = field.font.pointSize > 0 ? field.font.pointSize : 17.0;
    label.font = [UIFont monospacedDigitSystemFontOfSize:MAX(11.0, base - 4.0) weight:UIFontWeightRegular];
    label.textAlignment = NSTextAlignmentRight;
    label.isAccessibilityElement = NO;   // the field's own a11y value already carries the text

    UIButton *clearButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *glyph = [[UIImage systemImageNamed:@"xmark.circle.fill"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    [clearButton setImage:glyph forState:UIControlStateNormal];
    clearButton.accessibilityLabel = @"Clear text";
    [clearButton addTarget:ApolloSubjectCounterSharedTarget()
                    action:@selector(clearTapped:)
          forControlEvents:UIControlEventTouchUpInside];

    UIView *container = [[UIView alloc] initWithFrame:CGRectZero];
    [container addSubview:label];
    [container addSubview:clearButton];

    objc_setAssociatedObject(field, &kApolloSubjectCounterLabelKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(field, &kApolloSubjectCounterClearKey, clearButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(field, &kApolloSubjectCounterModeKey, @(field.clearButtonMode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    field.clearButtonMode = UITextFieldViewModeNever;   // superseded by the one in our container
    field.rightView = container;
    field.rightViewMode = UITextFieldViewModeAlways;
    ApolloSubjectCounterTarget *target = ApolloSubjectCounterSharedTarget();
    [field addTarget:target action:@selector(textChanged:) forControlEvents:UIControlEventEditingChanged];
    [field addTarget:target action:@selector(editingStateChanged:) forControlEvents:UIControlEventEditingDidBegin];
    [field addTarget:target action:@selector(editingStateChanged:) forControlEvents:UIControlEventEditingDidEnd];

    ApolloSubjectCounterRefresh(field);
    ApolloLog(@"[ModmailSubject] attached %ld-character counter to the Message Moderators subject field",
              (long)kApolloModSubjectMaxLength);
}

// Called straight after the moderator list presents its sheet. Everything the
// check needs (`headerView`, its text fields) is populated before
// -presentViewController: runs, so no polling is required.
static void ApolloSubjectCounterDecoratePresentedSheet(UIViewController *presenter) {
    UIViewController *sheet = presenter.navigationController.presentedViewController ?: presenter.presentedViewController;
    if (![sheet isKindOfClass:objc_getClass("_TtC6Apollo16ActionController")]) return;

    id header = ApolloSubjectCounterIvar(sheet, "headerView");
    if (![header isKindOfClass:objc_getClass("_TtC6Apollo13TextEntryView")]) return;

    // The 25-character sheet is the single-field one. The two-field sheets this
    // class also backs (new message, "Create Conversation") allow 100, so bail
    // rather than show a wrong limit.
    UITextField *subjectField = ApolloSubjectCounterIvar(header, "textField1");
    UITextField *secondField = ApolloSubjectCounterIvar(header, "textField2");
    if (![subjectField isKindOfClass:[UITextField class]] || secondField) return;

    NSString *placeholder = subjectField.placeholder;
    if (placeholder.length > 0 && ![placeholder isEqualToString:@"Subject"]) return;

    ApolloSubjectCounterAttach(subjectField);
}

%hook _TtC6Apollo36SubredditModeratorListViewController

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    %orig;
    ApolloSubjectCounterDecoratePresentedSheet((UIViewController *)self);
}

%end

%ctor {
    %init;
}
