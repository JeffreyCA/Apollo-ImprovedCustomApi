#import "CustomAPIViewController.h"
#import "UserDefaultConstants.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import "B64ImageEncodings.h"
#import "Version.h"
#import "DefaultSubreddits.h"
#import "SSZipArchive.h"

// Implementation derived from https://github.com/ryannair05/ApolloAPI/blob/master/CustomAPIViewController.m
// Credits to Ryan Nair (@ryannair05) for the original implementation

@implementation CustomAPIViewController

typedef NS_ENUM(NSInteger, Tag) {
    TagRedditClientId = 0,
    TagImgurClientId,
    TagTrendingSubredditsSource,
    TagRandomSubredditsSource,
    TagRandNsfwSubredditsSource,
    TagTrendingLimit,
};

- (UIImage *)decodeBase64ToImage:(NSString *)strEncodeData {
  NSData *data = [[NSData alloc]initWithBase64EncodedString:strEncodeData options:NSDataBase64DecodingIgnoreUnknownCharacters];
  return [UIImage imageWithData:data];
}

- (UIStackView *)createToggleSwitchWithKey:(NSString *)key labelText:(NSString *)text action:(SEL)action {
    UISwitch *toggleSwitch = [[UISwitch alloc] init];

    toggleSwitch.on = [[NSUserDefaults standardUserDefaults] boolForKey:key];
    [toggleSwitch addTarget:self action:action forControlEvents:UIControlEventValueChanged];

    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.textAlignment = NSTextAlignmentLeft;

    UIStackView *toggleStackView = [[UIStackView alloc] initWithArrangedSubviews:@[label, toggleSwitch]];
    toggleStackView.axis = UILayoutConstraintAxisHorizontal;
    toggleStackView.distribution = UIStackViewDistributionFill;
    toggleStackView.alignment = UIStackViewAlignmentCenter;
    toggleStackView.spacing = 10;

    return toggleStackView;
}

- (UIButton *)creditsButton:(NSString *)labelText subtitle:(NSString *)subtitle linkURL:(NSURL *)linkURL b64Image:(NSString *)b64Image {
    UIImage *image = [self decodeBase64ToImage:b64Image];

    const CGFloat imageSize = 40;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(imageSize, imageSize)];
    UIImage *smallImage = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, imageSize, imageSize) cornerRadius:5.0] addClip];
        [image drawInRect:CGRectMake(0, 0, imageSize, imageSize)];
    }];

    UIButton *button;
    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *buttonConfiguration = [UIButtonConfiguration grayButtonConfiguration];
        buttonConfiguration.imagePadding = 15;
        buttonConfiguration.subtitle = subtitle;

        button = [UIButton buttonWithConfiguration:buttonConfiguration primaryAction:
            [UIAction actionWithTitle:labelText image:smallImage identifier:nil handler:^(UIAction * action) {
                [UIApplication.sharedApplication openURL:linkURL options:@{} completionHandler:nil];
            }]
        ];
        button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    } else {
        // Fallback for iOS 14 and earlier - simple text button
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setTitle:[NSString stringWithFormat:@"%@ - %@", labelText, subtitle] forState:UIControlStateNormal];
        [button addTarget:self action:@selector(openCreditsLink:) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(button, @selector(openCreditsLink:), linkURL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return button;
}

- (void)openCreditsLink:(UIButton *)sender {
    NSURL *linkURL = objc_getAssociatedObject(sender, @selector(openCreditsLink:));
    if (linkURL) {
        [UIApplication.sharedApplication openURL:linkURL options:@{} completionHandler:nil];
    }
}

- (UIStackView *)createLabeledStackViewWithLabelText:(NSString *)labelText placeholder:(NSString *)placeholder text:(NSString *)text tag:(NSInteger)tag isNumerical:(BOOL)isNumerical {
    UIStackView *stackView = [[UIStackView alloc] init];
    stackView.axis = UILayoutConstraintAxisVertical;
    stackView.distribution = UIStackViewDistributionFillProportionally;
    stackView.alignment = UIStackViewAlignmentFill; 
    stackView.spacing = 8;

    UILabel *label = [[UILabel alloc] init];
    label.text = labelText;
    label.font = [UIFont systemFontOfSize:17];

    UITextField *textField = [[UITextField alloc] init];
    textField.placeholder = placeholder;
    textField.text = text;
    textField.tag = tag;
    textField.delegate = self;
    textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    textField.font = [UIFont systemFontOfSize:14];
    if (isNumerical) {
        textField.keyboardType = UIKeyboardTypeNumberPad;
    }

    [stackView addArrangedSubview:label];
    [stackView addArrangedSubview:textField];

    return stackView;
}

- (UIStackView *)createLabeledStackViewWithLabelText:(NSString *)labelText placeholder:(NSString *)placeholder text:(NSString *)text tag:(NSInteger)tag {
    return [self createLabeledStackViewWithLabelText:labelText placeholder:placeholder text:text tag:tag isNumerical:NO];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Custom API";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone primaryAction:[UIAction actionWithHandler:^(UIAction * action) {
        [self dismissViewControllerAnimated:YES completion:nil];
    }]];
    
    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.backgroundColor = [UIColor systemBackgroundColor];
    scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:scrollView];
    
    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    
    UIStackView *stackView = [[UIStackView alloc] init];
    stackView.axis = UILayoutConstraintAxisVertical;
    stackView.spacing = 20;
    stackView.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:stackView];
    
    [NSLayoutConstraint activateConstraints:@[
        [stackView.topAnchor constraintEqualToAnchor:scrollView.topAnchor constant:20],
        [stackView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [stackView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [stackView.bottomAnchor constraintEqualToAnchor:scrollView.bottomAnchor constant:-20],
    ]];

    // Backup / Restore section
    UILabel *backupRestoreLabel = [[UILabel alloc] init];
    backupRestoreLabel.text = @"Backup / Restore";
    backupRestoreLabel.font = [UIFont boldSystemFontOfSize:18];
    backupRestoreLabel.textAlignment = NSTextAlignmentCenter;
    [stackView addArrangedSubview:backupRestoreLabel];

    UIButton *backupButton = [UIButton systemButtonWithPrimaryAction:[UIAction actionWithTitle:@"Backup Settings" image:nil identifier:nil handler:^(UIAction * action) {
        [self backupSettings];
    }]];
    backupButton.titleLabel.font = [UIFont systemFontOfSize:16.0];

    UIButton *restoreButton = [UIButton systemButtonWithPrimaryAction:[UIAction actionWithTitle:@"Restore Settings" image:nil identifier:nil handler:^(UIAction * action) {
        [self restoreSettings];
    }]];
    restoreButton.titleLabel.font = [UIFont systemFontOfSize:16.0];

    UIStackView *backupRestoreStackView = [[UIStackView alloc] initWithArrangedSubviews:@[backupButton, restoreButton]];
    backupRestoreStackView.axis = UILayoutConstraintAxisHorizontal;
    backupRestoreStackView.distribution = UIStackViewDistributionFillEqually;
    backupRestoreStackView.spacing = 10;
    [stackView addArrangedSubview:backupRestoreStackView];

    UILabel *backupNoteLabel = [[UILabel alloc] init];
    backupNoteLabel.text = @"Restore Settings does not restore accounts or affect existing ones. The backup .zip contains an accounts.txt with all account usernames for reference.";
    backupNoteLabel.font = [UIFont systemFontOfSize:13];
    backupNoteLabel.textColor = [UIColor secondaryLabelColor];
    backupNoteLabel.numberOfLines = 0;
    [stackView addArrangedSubview:backupNoteLabel];

    // API Keys section
    UILabel *apiKeysLabel = [[UILabel alloc] init];
    apiKeysLabel.text = @"API Keys";
    apiKeysLabel.font = [UIFont boldSystemFontOfSize:18];
    apiKeysLabel.textAlignment = NSTextAlignmentCenter;
    [stackView addArrangedSubview:apiKeysLabel];

    UIStackView *redditStackView = [self createLabeledStackViewWithLabelText:@"Reddit API Key:" placeholder:@"Reddit API Key" text:sRedditClientId tag:TagRedditClientId];
    [stackView addArrangedSubview:redditStackView];

    UIStackView *imgurStackView = [self createLabeledStackViewWithLabelText:@"Imgur API Key:" placeholder:@"Imgur API Key" text:sImgurClientId tag:TagImgurClientId];
    [stackView addArrangedSubview:imgurStackView];

    UIButton *redditWebsiteButton = [UIButton systemButtonWithPrimaryAction:[UIAction actionWithTitle:@"Reddit API Website" image:nil identifier:nil handler:^(UIAction * action) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://reddit.com/prefs/apps"] options:@{} completionHandler:nil];
    }]];
    redditWebsiteButton.titleLabel.font = [UIFont systemFontOfSize:16.0];

    UIButton *imgurWebsiteButton = [UIButton systemButtonWithPrimaryAction:[UIAction actionWithTitle:@"Imgur API Website" image:nil identifier:nil handler:^(UIAction * action) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://api.imgur.com/oauth2/addclient"] options:@{} completionHandler:nil];
    }]];
    imgurWebsiteButton.titleLabel.font = [UIFont systemFontOfSize:16.0];

    UIStackView *apiWebsiteStackView = [[UIStackView alloc] initWithArrangedSubviews:@[redditWebsiteButton, imgurWebsiteButton]];
    apiWebsiteStackView.axis = UILayoutConstraintAxisHorizontal;
    apiWebsiteStackView.distribution = UIStackViewDistributionFillEqually;
    apiWebsiteStackView.spacing = 10;
    [stackView addArrangedSubview:apiWebsiteStackView];

    UILabel *apiNoteLabel = [[UILabel alloc] init];
    apiNoteLabel.text = @"Since mid-2025, Reddit API access requires manual approval and Imgur does not allow API key creation. Only known workaround is to use existing keys. Scroll down for old instructions for creating API keys.";
    apiNoteLabel.font = [UIFont systemFontOfSize:13];
    apiNoteLabel.textColor = [UIColor secondaryLabelColor];
    apiNoteLabel.numberOfLines = 0;
    [stackView addArrangedSubview:apiNoteLabel];

    // General section
    UILabel *generalLabel = [[UILabel alloc] init];
    generalLabel.text = @"General";
    generalLabel.font = [UIFont boldSystemFontOfSize:18];
    generalLabel.textAlignment = NSTextAlignmentCenter;
    [stackView addArrangedSubview:generalLabel];

    UIStackView *blockAnnouncementsStackView = [self createToggleSwitchWithKey:UDKeyBlockAnnouncements labelText:@"Block Announcements" action:@selector(blockAnnouncementsSwitchToggled:)];
    [stackView addArrangedSubview:blockAnnouncementsStackView];

    UIStackView *unreadCommentsStackView = [self createToggleSwitchWithKey:UDKeyApolloShowUnreadComments labelText:@"New Comments Highlightifier" action:@selector(unreadCommentsSwitchToggled:)];
    [stackView addArrangedSubview:unreadCommentsStackView];

    UIStackView *flexStackView = [self createToggleSwitchWithKey:UDKeyEnableFLEX labelText:@"FLEX Debugging (Needs restart)" action:@selector(flexSwitchToggled:)];
    [stackView addArrangedSubview:flexStackView];

    UIStackView *randNsfwStackView = [self createToggleSwitchWithKey:UDKeyShowRandNsfw labelText:@"RandNSFW button" action:@selector(randNsfwSwitchToggled:)];
    [stackView addArrangedSubview:randNsfwStackView];

    UIStackView *trendingSubredditsLimitStackView = [self createLabeledStackViewWithLabelText:@"Limit trending subreddits to:" placeholder:@"(unlimited)" text:sTrendingSubredditsLimit tag:TagTrendingLimit isNumerical:YES];
    [stackView addArrangedSubview:trendingSubredditsLimitStackView];

    UILabel *subredditSourcesLabel = [[UILabel alloc] init];
    subredditSourcesLabel.text = @"Subreddits";
    subredditSourcesLabel.font = [UIFont boldSystemFontOfSize:18];
    subredditSourcesLabel.textAlignment = NSTextAlignmentCenter;
    [stackView addArrangedSubview:subredditSourcesLabel];

    UIStackView *trendingSourceStackView = [self createLabeledStackViewWithLabelText:@"Trending subreddits source:" placeholder:defaultTrendingSubredditsSource text:sTrendingSubredditsSource tag:TagTrendingSubredditsSource];
    [stackView addArrangedSubview:trendingSourceStackView];

    UIStackView *randomSourceStackView = [self createLabeledStackViewWithLabelText:@"Random subreddits source:" placeholder:defaultRandomSubredditsSource text:sRandomSubredditsSource tag:TagRandomSubredditsSource];
    [stackView addArrangedSubview:randomSourceStackView];

    UIStackView *randNsfwSourceStackView = [self createLabeledStackViewWithLabelText:@"RandNSFW subreddits source:" placeholder:@"(empty)" text:sRandNsfwSubredditsSource tag:TagRandNsfwSubredditsSource];
    [stackView addArrangedSubview:randNsfwSourceStackView];

    UITextView *subredditSourcesNote = [[UITextView alloc] init];
    subredditSourcesNote.editable = NO;
    subredditSourcesNote.scrollEnabled = NO;
    subredditSourcesNote.backgroundColor = [UIColor clearColor];
    subredditSourcesNote.textContainerInset = UIEdgeInsetsZero;
    subredditSourcesNote.textContainer.lineFragmentPadding = 0;
    NSMutableAttributedString *subredditNoteText = [[NSMutableAttributedString alloc] initWithString:@"Configure custom subreddit sources by providing a URL to a plaintext file with line-separated subreddit names (without /r/). "
        attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13], NSForegroundColorAttributeName: [UIColor secondaryLabelColor]}];
    [subredditNoteText appendAttributedString:[[NSAttributedString alloc] initWithString:@"Example file"
        attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13], NSLinkAttributeName: [NSURL URLWithString:@"https://jeffreyca.github.io/subreddits/popular.txt"]}]];
    [subredditNoteText appendAttributedString:[[NSAttributedString alloc] initWithString:@" ("
        attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13], NSForegroundColorAttributeName: [UIColor secondaryLabelColor]}]];
    [subredditNoteText appendAttributedString:[[NSAttributedString alloc] initWithString:@"GitHub repo"
        attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13], NSLinkAttributeName: [NSURL URLWithString:@"https://github.com/JeffreyCA/subreddits"]}]];
    [subredditNoteText appendAttributedString:[[NSAttributedString alloc] initWithString:@")"
        attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13], NSForegroundColorAttributeName: [UIColor secondaryLabelColor]}]];
    subredditSourcesNote.attributedText = subredditNoteText;
    [stackView addArrangedSubview:subredditSourcesNote];

    UILabel *instructionsLabel = [[UILabel alloc] init];
    instructionsLabel.text = @"Instructions";
    instructionsLabel.font = [UIFont boldSystemFontOfSize:18];
    instructionsLabel.textAlignment = NSTextAlignmentCenter;
    [stackView addArrangedSubview:instructionsLabel];

    UITextView *textView = [[UITextView alloc] init];
    textView.editable = NO;
    textView.scrollEnabled = NO;

    if (@available(iOS 15.0, *)) {
        NSString *instructionsText =
            @"**Creating a Reddit API credential:**\n"
            @"*You may need to sign out of all accounts in Apollo*\n\n"
            @"1. Sign into your Reddit account and go to the link above ([reddit.com/prefs/apps](https://reddit.com/prefs/apps))\n"
            @"2. Click the \"`are you a developer? create an app...`\" button\n"
            @"3. Fill in the fields \n\t- Name: *anything* \n\t- Choose \"`Installed App`\" \n\t- Description: *anything*\n\t- About url: *anything* \n\t- Redirect uri: `apollo://reddit-oauth`\n"
            @"4. Click \"`create app`\"\n"
            @"5. After creating the app you'll get a client identifier which will be a bunch of random characters. **Enter the key above**.\n"
            @"\n"
            @"**Creating an Imgur API credential:**\n"
            @"1. Sign into your Imgur account and go to the link above ([api.imgur.com/oauth2/addclient](https://api.imgur.com/oauth2/addclient))\n"
            @"2. Fill in the fields \n\t- Application name: *anything* \n\t- Authorization type: `OAuth 2 auth with a callback URL` \n\t- Authorization callback URL: `https://www.getpostman.com/oauth2/callback`\n\t- Email: *your email* \n\t- Description: *anything*\n"
            @"3. Click \"`submit`\"\n"
            @"4. Enter the **Client ID** (not the client secret) above.";

        NSAttributedStringMarkdownParsingOptions *markdownOptions = [[NSAttributedStringMarkdownParsingOptions alloc] init];
        markdownOptions.interpretedSyntax = NSAttributedStringMarkdownInterpretedSyntaxInlineOnly;
        textView.attributedText = [[NSAttributedString alloc] initWithMarkdownString:instructionsText options:markdownOptions baseURL:nil error:nil];

        // Increase font size for markdown text
        NSMutableAttributedString *attributedText = [textView.attributedText mutableCopy];
        [attributedText enumerateAttribute:NSFontAttributeName inRange:NSMakeRange(0, attributedText.length) options:0 usingBlock:^(id value, NSRange range, BOOL *stop) {
            UIFont *oldFont = (UIFont *)value;

            if (oldFont == nil) {
                UIFont *newFont = [UIFont systemFontOfSize:15];
                [attributedText addAttribute:NSFontAttributeName value:newFont range:range];
            } else {
                UIFont *newFont = [oldFont fontWithSize:15];
                [attributedText addAttribute:NSFontAttributeName value:newFont range:range];
            }
        }];
        textView.attributedText = attributedText;
    } else {
        // Fallback for iOS 14 and earlier - plain text without markdown
        textView.font = [UIFont systemFontOfSize:15];
        textView.text =
            @"Creating a Reddit API credential:\n"
            @"You may need to sign out of all accounts in Apollo\n\n"
            @"1. Sign into your Reddit account and go to the link above (reddit.com/prefs/apps)\n"
            @"2. Click the \"are you a developer? create an app...\" button\n"
            @"3. Fill in the fields \n\t- Name: anything \n\t- Choose \"Installed App\" \n\t- Description: anything\n\t- About url: anything \n\t- Redirect uri: apollo://reddit-oauth\n"
            @"4. Click \"create app\"\n"
            @"5. After creating the app you'll get a client identifier which will be a bunch of random characters. Enter the key above.\n"
            @"\n"
            @"Creating an Imgur API credential:\n"
            @"1. Sign into your Imgur account and go to the link above (api.imgur.com/oauth2/addclient)\n"
            @"2. Fill in the fields \n\t- Application name: anything \n\t- Authorization type: OAuth 2 auth with a callback URL \n\t- Authorization callback URL: https://www.getpostman.com/oauth2/callback\n\t- Email: your email \n\t- Description: anything\n"
            @"3. Click \"submit\"\n"
            @"4. Enter the Client ID (not the client secret) above.";
    }
    textView.textColor = UIColor.labelColor;

    [textView sizeToFit];
    [stackView addArrangedSubview:textView];

    UILabel *aboutLabel = [[UILabel alloc] init];
    aboutLabel.text = @"About";
    aboutLabel.font = [UIFont boldSystemFontOfSize:18];
    aboutLabel.textAlignment = NSTextAlignmentCenter;
    [stackView addArrangedSubview:aboutLabel];

    NSURL *githubLinkURL = [NSURL URLWithString:@"https://github.com/JeffreyCA/Apollo-ImprovedCustomApi"];
    UIButton *githubButton = [self creditsButton:@"Open Source on GitHub" subtitle:@"@JeffreyCA" linkURL:githubLinkURL b64Image:B64Github];
    [stackView addArrangedSubview:githubButton];

    UILabel *creditsLabel = [[UILabel alloc] init];
    creditsLabel.text = @"Credits";
    creditsLabel.font = [UIFont boldSystemFontOfSize:18];
    creditsLabel.textAlignment = NSTextAlignmentCenter;
    [stackView addArrangedSubview:creditsLabel];

    NSURL *customApiLinkURL = [NSURL URLWithString:@"https://github.com/EthanArbuckle/Apollo-CustomApiCredentials"];
    UIButton *customApiButton = [self creditsButton:@"Apollo-CustomApiCredentials" subtitle:@"@EthanArbuckle" linkURL:customApiLinkURL b64Image:B64Ethan];
    [stackView addArrangedSubview:customApiButton];

    NSURL *apolloApiLinkURL = [NSURL URLWithString:@"https://github.com/ryannair05/ApolloAPI"];
    UIButton *apolloApiButton = [self creditsButton:@"ApolloAPI" subtitle:@"@ryannair05" linkURL:apolloApiLinkURL b64Image:B64Ryannair05];
    [stackView addArrangedSubview:apolloApiButton];

    NSURL *apolloPatcherLinkURL = [NSURL URLWithString:@"https://github.com/ichitaso/ApolloPatcher"];
    UIButton *apolloPatcherButton = [self creditsButton:@"ApolloPatcher" subtitle:@"@ichitaso" linkURL:apolloPatcherLinkURL b64Image:B64Ichitaso];
    [stackView addArrangedSubview:apolloPatcherButton];

    UILabel *versionLabel = [[UILabel alloc] init];
    versionLabel.text = @TWEAK_VERSION;
    versionLabel.font = [UIFont systemFontOfSize:14];
    versionLabel.textAlignment = NSTextAlignmentCenter;
    [stackView addArrangedSubview:versionLabel];
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (textField.tag == TagRedditClientId) {
        // Trim textField.text whitespaces
        textField.text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        sRedditClientId = textField.text;
        [[NSUserDefaults standardUserDefaults] setValue:sRedditClientId forKey:UDKeyRedditClientId];
    } else if (textField.tag == TagImgurClientId) {
        textField.text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        sImgurClientId = textField.text;
        [[NSUserDefaults standardUserDefaults] setValue:sImgurClientId forKey:UDKeyImgurClientId];
    } else if (textField.tag == TagTrendingSubredditsSource) {
        textField.text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (textField.text.length == 0) {
            textField.text = defaultTrendingSubredditsSource;
        }
        sTrendingSubredditsSource = textField.text;
        [[NSUserDefaults standardUserDefaults] setValue:sTrendingSubredditsSource forKey:UDKeyTrendingSubredditsSource];
    } else if (textField.tag == TagRandomSubredditsSource) {
        textField.text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (textField.text.length == 0) {
            textField.text = defaultRandomSubredditsSource;
        }
        sRandomSubredditsSource = textField.text;
        [[NSUserDefaults standardUserDefaults] setValue:sRandomSubredditsSource forKey:UDKeyRandomSubredditsSource];
    } else if (textField.tag == TagRandNsfwSubredditsSource) {
        textField.text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        sRandNsfwSubredditsSource = textField.text;
        [[NSUserDefaults standardUserDefaults] setValue:sRandNsfwSubredditsSource forKey:UDKeyRandNsfwSubredditsSource];
    } else if (textField.tag == TagTrendingLimit) {
        textField.text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        sTrendingSubredditsLimit = textField.text;
        [[NSUserDefaults standardUserDefaults] setValue:sTrendingSubredditsLimit forKey:UDKeyTrendingSubredditsLimit];
    }
}

- (void)unreadCommentsSwitchToggled:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyApolloShowUnreadComments];
}

- (void)blockAnnouncementsSwitchToggled:(UISwitch *)sender {
    sBlockAnnouncements = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sBlockAnnouncements forKey:UDKeyBlockAnnouncements];
}

- (void)flexSwitchToggled:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyEnableFLEX];
}

- (void)randNsfwSwitchToggled:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyShowRandNsfw];
}

#pragma mark - Backup / Restore

static NSString *const kMainPlistFilename = @"preferences.plist";
static NSString *const kGroupPlistFilename = @"group.plist";
static NSString *const kAccountsFilename = @"accounts.txt";
static NSString *const kGroupSuiteName = @"group.com.christianselig.apollo";

// Default: Library/Preferences/com.christianselig.Apollo.plist, depending on bundle ID.
// Contains: most Apollo settings
- (NSString *)mainPreferencesPath {
    NSString *containerPath = NSHomeDirectory();
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    NSString *plistName = [NSString stringWithFormat:@"Library/Preferences/%@.plist", bundleId];
    return [containerPath stringByAppendingPathComponent:plistName];
}

// Should always Library/Preferences/group.com.christianselig.apollo.plist, no matter the bundle ID.
// Contains: theme settings, keyword filters, some account state
- (NSString *)groupPreferencesPath {
    NSString *containerPath = NSHomeDirectory();
    NSString *plistName = [NSString stringWithFormat:@"Library/Preferences/%@.plist", kGroupSuiteName];
    return [containerPath stringByAppendingPathComponent:plistName];
}

- (void)backupSettings {
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[[NSUserDefaults alloc] initWithSuiteName:kGroupSuiteName] synchronize];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *mainPlistPath = [self mainPreferencesPath];
    NSString *groupPlistPath = [self groupPreferencesPath];

    if (![fileManager fileExistsAtPath:mainPlistPath]) {
        [self showAlertWithTitle:@"Backup Failed" message:@"Could not find Apollo preferences file."];
        return;
    }

    NSString *tempDir = NSTemporaryDirectory();
    NSString *backupDir = [tempDir stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];

    NSError *error = nil;
    if (![fileManager createDirectoryAtPath:backupDir withIntermediateDirectories:YES attributes:nil error:&error]) {
        [self showAlertWithTitle:@"Backup Failed" message:@"Could not create temporary directory."];
        return;
    }

    NSString *mainDestPath = [backupDir stringByAppendingPathComponent:kMainPlistFilename];
    if (![fileManager copyItemAtPath:mainPlistPath toPath:mainDestPath error:&error]) {
        [self showAlertWithTitle:@"Backup Failed" message:@"Could not copy preferences file."];
        return;
    }

    if ([fileManager fileExistsAtPath:groupPlistPath]) {
        NSString *groupDestPath = [backupDir stringByAppendingPathComponent:kGroupPlistFilename];
        [fileManager copyItemAtPath:groupPlistPath toPath:groupDestPath error:nil];

        // Extract account usernames from group plist
        NSDictionary *groupPrefs = [NSDictionary dictionaryWithContentsOfFile:groupPlistPath];
        NSDictionary *accountDetails = groupPrefs[@"LoggedInAccountDetails"];
        if (accountDetails && [accountDetails isKindOfClass:[NSDictionary class]] && accountDetails.count > 0) {
            NSArray *usernames = [accountDetails allValues];
            NSString *accountsContent = [usernames componentsJoinedByString:@"\n"];
            NSString *accountsPath = [backupDir stringByAppendingPathComponent:kAccountsFilename];
            [accountsContent writeToFile:accountsPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }

    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    dateFormatter.dateFormat = @"yyyy-MM-dd_HHmmss";
    NSString *timestamp = [dateFormatter stringFromDate:[NSDate date]];
    NSString *zipFilename = [NSString stringWithFormat:@"Apollo_Backup_%@.zip", timestamp];
    NSString *zipPath = [tempDir stringByAppendingPathComponent:zipFilename];

    BOOL success = [SSZipArchive createZipFileAtPath:zipPath withContentsOfDirectory:backupDir];
    [fileManager removeItemAtPath:backupDir error:nil];

    if (!success) {
        [self showAlertWithTitle:@"Backup Failed" message:@"Could not create backup archive."];
        return;
    }

    _isRestoreOperation = NO;
    NSURL *zipURL = [NSURL fileURLWithPath:zipPath];
    UIDocumentPickerViewController *documentPicker = [[UIDocumentPickerViewController alloc] initForExportingURLs:@[zipURL] asCopy:YES];
    documentPicker.delegate = self;
    documentPicker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:documentPicker animated:YES completion:nil];
}

- (void)restoreSettings {
    _isRestoreOperation = YES;
    UIDocumentPickerViewController *documentPicker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeZIP] asCopy:YES];
    documentPicker.delegate = self;
    documentPicker.modalPresentationStyle = UIModalPresentationFormSheet;
    documentPicker.allowsMultipleSelection = NO;
    [self presentViewController:documentPicker animated:YES completion:nil];
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) {
        return;
    }

    if (!_isRestoreOperation) {
        NSString *filename = urls.firstObject.lastPathComponent;
        NSString *message = [NSString stringWithFormat:@"Settings saved as: %@", filename];
        [self showAlertWithTitle:@"Backup Complete" message:message];
        return;
    }

    NSURL *selectedURL = urls.firstObject;
    [self confirmRestoreWithURL:selectedURL];
}

- (void)confirmRestoreWithURL:(NSURL *)zipURL {
    UIAlertController *confirmAlert = [UIAlertController alertControllerWithTitle:@"Confirm Restore"
        message:@"This will replace all existing settings with the backup. This cannot be undone."
        preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    UIAlertAction *restoreAction = [UIAlertAction actionWithTitle:@"Restore" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self restoreFromZipURL:zipURL];
    }];

    [confirmAlert addAction:cancelAction];
    [confirmAlert addAction:restoreAction];
    [self presentViewController:confirmAlert animated:YES completion:nil];
}

- (void)restoreFromZipURL:(NSURL *)zipURL {
    [zipURL startAccessingSecurityScopedResource];

    NSString *tempDir = NSTemporaryDirectory();
    NSString *extractDir = [tempDir stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];

    NSError *error = nil;
    BOOL success = [SSZipArchive unzipFileAtPath:zipURL.path toDestination:extractDir overwrite:YES password:nil error:&error];
    [zipURL stopAccessingSecurityScopedResource];

    if (!success) {
        [self showAlertWithTitle:@"Restore Failed" message:@"Could not extract backup archive."];
        return;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *mainPlistBackupPath = [extractDir stringByAppendingPathComponent:kMainPlistFilename];

    if (![fileManager fileExistsAtPath:mainPlistBackupPath]) {
        [fileManager removeItemAtPath:extractDir error:nil];
        [self showAlertWithTitle:@"Invalid Backup" message:@"The selected file is not a valid Apollo backup archive."];
        return;
    }

    NSDictionary *mainPrefs = [NSDictionary dictionaryWithContentsOfFile:mainPlistBackupPath];
    if (!mainPrefs) {
        [fileManager removeItemAtPath:extractDir error:nil];
        [self showAlertWithTitle:@"Invalid Backup" message:@"The preferences file in the backup is corrupted or invalid."];
        return;
    }

    // Restore main preferences, skipping analytics/tracking keys
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:bundleId];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (NSString *key in mainPrefs) {
        if ([key isEqualToString:@"BugsnagUserUserId"] || [key hasPrefix:@"com.Statsig."]) {
            continue;
        }
        [defaults setObject:mainPrefs[key] forKey:key];
    }
    [defaults synchronize];

    // Sync in-memory globals with restored values
    sRedditClientId = [defaults stringForKey:UDKeyRedditClientId];
    sImgurClientId = [defaults stringForKey:UDKeyImgurClientId];
    sBlockAnnouncements = [defaults boolForKey:UDKeyBlockAnnouncements];
    sTrendingSubredditsSource = [defaults stringForKey:UDKeyTrendingSubredditsSource];
    sRandomSubredditsSource = [defaults stringForKey:UDKeyRandomSubredditsSource];
    sRandNsfwSubredditsSource = [defaults stringForKey:UDKeyRandNsfwSubredditsSource];
    sTrendingSubredditsLimit = [defaults stringForKey:UDKeyTrendingSubredditsLimit];

    // Restore group preferences, preserving account state from current install
    NSString *groupPlistBackupPath = [extractDir stringByAppendingPathComponent:kGroupPlistFilename];
    if ([fileManager fileExistsAtPath:groupPlistBackupPath]) {
        NSDictionary *groupPrefs = [NSDictionary dictionaryWithContentsOfFile:groupPlistBackupPath];
        if (groupPrefs) {
            NSUserDefaults *groupDefaults = [[NSUserDefaults alloc] initWithSuiteName:kGroupSuiteName];

            for (NSString *key in groupPrefs) {
                if ([key isEqualToString:@"LoggedInAccountDetails"] ||
                    [key isEqualToString:@"CurrentRedditAccountIndex"] ||
                    [key isEqualToString:@"RedditAccounts2"] ||
                    [key isEqualToString:@"RedditApplicationOnlyAccount2"]) {
                    continue;
                }
                [groupDefaults setObject:groupPrefs[key] forKey:key];
            }
            [groupDefaults synchronize];
        }
    }

    [fileManager removeItemAtPath:extractDir error:nil];
    [self showRestoreCompleteAlert];
}

- (void)showRestoreCompleteAlert {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Restore Complete"
        message:@"Settings successfully restored. Apollo needs to restart to apply changes."
        preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *quitAction = [UIAlertAction actionWithTitle:@"Close App" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        exit(0);
    }];

    [alert addAction:quitAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:message
        preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:okAction];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
