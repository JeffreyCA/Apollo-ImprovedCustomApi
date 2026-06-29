#import "ApolloThemeBuilder.h"

static UIColor *PreviewColor(NSDictionary<NSString *, NSString *> *colors,
                             NSString *role,
                             NSString *mode) {
    return ApolloThemeBuilderColorFromHex(ApolloThemeBuilderHexFromColors(colors, role, mode))
        ?: UIColor.systemGrayColor;
}

UIView *ApolloThemeBuilderPreviewView(NSDictionary<NSString *, NSString *> *colors,
                                      BOOL darkMode,
                                      CGFloat width) {
    if (width <= 0) width = 320;
    NSString *mode = darkMode ? @"dark" : @"light";

    UIColor *page      = PreviewColor(colors, kApolloThemeRoleSecondaryBG, mode);
    UIColor *card      = PreviewColor(colors, kApolloThemeRolePrimaryBG, mode);
    UIColor *accent    = PreviewColor(colors, kApolloThemeRoleAccent, mode);
    UIColor *separator = PreviewColor(colors, kApolloThemeRoleSeparator, mode);
    UIColor *bar       = PreviewColor(colors, kApolloThemeRoleBar, mode);
    UIColor *tertiary  = PreviewColor(colors, kApolloThemeRoleTertiaryBG, mode);
    UIColor *gray      = PreviewColor(colors, kApolloThemeRoleGray, mode);
    UIColor *primaryText = darkMode ? UIColor.whiteColor : [UIColor colorWithWhite:0.1 alpha:1.0];

    CGFloat inset = 14;
    CGFloat screenW = width;
    CGFloat screenH = 246;
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, screenH)];
    container.backgroundColor = UIColor.clearColor;

    UIView *screen = [[UIView alloc] initWithFrame:CGRectMake(0, 0, screenW, screenH)];
    screen.backgroundColor = page;
    screen.layer.cornerRadius = 14;
    screen.layer.borderWidth = 1;
    screen.layer.borderColor = separator.CGColor;
    screen.clipsToBounds = YES;
    [container addSubview:screen];

    UIView *chrome = [[UIView alloc] initWithFrame:CGRectMake(0, 0, screenW, 40)];
    chrome.backgroundColor = bar;
    [screen addSubview:chrome];

    UILabel *caption = [[UILabel alloc] initWithFrame:CGRectMake(inset, 12, screenW - 2 * inset, 16)];
    caption.text = [NSString stringWithFormat:@"%@ preview", darkMode ? @"Dark" : @"Light"];
    caption.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    caption.textColor = gray;
    [chrome addSubview:caption];

    CGFloat cardX = inset, cardY = 58, cardW = screenW - 2 * inset, cardH = 162;
    UIView *postCard = [[UIView alloc] initWithFrame:CGRectMake(cardX, cardY, cardW, cardH)];
    postCard.backgroundColor = card;
    postCard.layer.cornerRadius = 10;
    postCard.layer.borderWidth = 1;
    postCard.layer.borderColor = separator.CGColor;
    postCard.clipsToBounds = YES;
    [screen addSubview:postCard];

    UIView *avatar = [[UIView alloc] initWithFrame:CGRectMake(inset, 16, 34, 34)];
    avatar.backgroundColor = accent;
    avatar.layer.cornerRadius = 17;
    [postCard addSubview:avatar];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(inset + 44, 15, cardW - inset * 2 - 44, 18)];
    sub.text = @"r/apolloapp";
    sub.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    sub.textColor = accent;
    [postCard addSubview:sub];

    UILabel *meta = [[UILabel alloc] initWithFrame:CGRectMake(inset + 44, 34, cardW - inset * 2 - 44, 16)];
    meta.text = @"u/christianselig · 2h";
    meta.font = [UIFont systemFontOfSize:13];
    meta.textColor = gray;
    [postCard addSubview:meta];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(inset, 68, cardW - inset * 2, 24)];
    title.text = @"Your custom theme, live as you build it";
    title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    title.textColor = primaryText;
    title.numberOfLines = 1;
    title.adjustsFontSizeToFitWidth = YES;
    title.minimumScaleFactor = 0.82;
    [postCard addSubview:title];

    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(inset, 104, cardW - inset * 2, 1)];
    line.backgroundColor = separator;
    [postCard addSubview:line];

    UILabel *vote = [[UILabel alloc] initWithFrame:CGRectMake(inset, 120, 92, 26)];
    vote.text = @"▲ 1.2k";
    vote.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    vote.textColor = UIColor.whiteColor;
    vote.textAlignment = NSTextAlignmentCenter;
    vote.backgroundColor = accent;
    vote.layer.cornerRadius = 13;
    vote.clipsToBounds = YES;
    [postCard addSubview:vote];

    UILabel *comments = [[UILabel alloc] initWithFrame:CGRectMake(inset + 104, 120, 92, 26)];
    comments.text = @"💬 42";
    comments.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    comments.textColor = primaryText;
    comments.textAlignment = NSTextAlignmentCenter;
    comments.backgroundColor = tertiary;
    comments.layer.cornerRadius = 13;
    comments.clipsToBounds = YES;
    [postCard addSubview:comments];

    return container;
}
