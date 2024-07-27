#import "CustomAPIViewController.h"
#import "UserDefaultConstants.h"
#import "B64ImageEncodings.h"

// Implementation derived from https://github.com/ryannair05/ApolloAPI/blob/master/CustomAPIViewController.m
// Credits to Ryan Nair (@ryannair05) for the original implementation

@implementation CustomAPIViewController

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
    UIButtonConfiguration *buttonConfiguration = [UIButtonConfiguration grayButtonConfiguration];
    buttonConfiguration.imagePadding = 15;
    buttonConfiguration.subtitle = subtitle;

    UIImage *image = [self decodeBase64ToImage:b64Image];

    const CGFloat imageSize = 40;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(imageSize, imageSize)];
    UIImage *smallImage = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, imageSize, imageSize) cornerRadius:5.0] addClip];
        [image drawInRect:CGRectMake(0, 0, imageSize, imageSize)];
    }];

    // Create the button with the specified label text, image, and link URL
    UIButton *button = [UIButton buttonWithConfiguration:buttonConfiguration primaryAction:
        [UIAction actionWithTitle:labelText image:smallImage identifier:nil handler:^(UIAction * action) {
            [UIApplication.sharedApplication openURL:linkURL options:@{} completionHandler:nil];
        }]
    ];
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    return button;
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
    
    UITextField *redditTextField = [[UITextField alloc] init];
    redditTextField.tag = 0;
    redditTextField.placeholder = @"Reddit API Key";
    redditTextField.text = sRedditClientId;
    redditTextField.delegate = self;
    redditTextField.clearButtonMode = UITextFieldViewModeWhileEditing;
    [stackView addArrangedSubview:redditTextField];
    
    UITextField *imgurTextField = [[UITextField alloc] init];
    imgurTextField.placeholder = @"Imgur API Key";
    imgurTextField.tag = 1;
    imgurTextField.text = sImgurClientId;
    imgurTextField.delegate = self;
    imgurTextField.clearButtonMode = UITextFieldViewModeWhileEditing;
    [stackView addArrangedSubview:imgurTextField];

    UIButton *websiteButton = [UIButton systemButtonWithPrimaryAction:[UIAction actionWithTitle:@"Reddit API Website" image:nil identifier:nil handler:^(UIAction * action) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://reddit.com/prefs/apps"] options:@{} completionHandler:nil];
    }]];
    websiteButton.titleLabel.font = [UIFont systemFontOfSize:16.0];

    UIButton *imgurButton = [UIButton systemButtonWithPrimaryAction:[UIAction actionWithTitle:@"Imgur API Website" image:nil identifier:nil handler:^(UIAction * action) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://api.imgur.com/oauth2/addclient"] options:@{} completionHandler:nil];
    }]];
    imgurButton.titleLabel.font = [UIFont systemFontOfSize:16.0];

    [stackView addArrangedSubview:websiteButton];
    [stackView addArrangedSubview:imgurButton];

    UIStackView *blockAnnouncementsStackView = [self createToggleSwitchWithKey:UDKeyBlockAnnouncements labelText:@"Block Announcements" action:@selector(blockAnnouncementsSwitchToggled:)];
    [stackView addArrangedSubview:blockAnnouncementsStackView];

    UIStackView *unreadCommentsStackView = [self createToggleSwitchWithKey:UDKeyApolloShowUnreadComments labelText:@"New Comments Highlightifier (Beta)" action:@selector(unreadCommentsSwitchToggled:)];
    [stackView addArrangedSubview:unreadCommentsStackView];

    UIStackView *flexStackView = [self createToggleSwitchWithKey:UDKeyEnableFLEX labelText:@"FLEX Debugging (Needs restart)" action:@selector(flexSwitchToggled:)];
    [stackView addArrangedSubview:flexStackView];

    UITextView *textView = [[UITextView alloc] init];
    textView.editable = NO;
    textView.scrollEnabled = NO;

    NSAttributedStringMarkdownParsingOptions *markdownOptions = [[NSAttributedStringMarkdownParsingOptions alloc] init];
    markdownOptions.interpretedSyntax = NSAttributedStringMarkdownInterpretedSyntaxInlineOnly;

    textView.attributedText = [[NSAttributedString alloc] initWithMarkdownString:
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
        @"4. Enter the **Client ID** (not the client secret) above.\n"

    options:markdownOptions baseURL:nil error:nil];

    // Increase font size
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
    textView.textColor = UIColor.labelColor;

    [textView sizeToFit];
    [stackView addArrangedSubview:textView];

    UILabel *aboutLabel = [[UILabel alloc] init];
    aboutLabel.text = @"About";
    aboutLabel.font = [UIFont boldSystemFontOfSize:18];
    aboutLabel.textAlignment = NSTextAlignmentCenter;
    [stackView addArrangedSubview:aboutLabel];

    NSURL *githubLinkURL = [NSURL URLWithString:@"https://github.com/JeffreyCA/Apollo-ImprovedCustomApi"];
    UIButton *githubButton = [self creditsButton:@"Open source on GitHub" subtitle:@"@JeffreyCA" linkURL:githubLinkURL b64Image:B64Github];
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
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (textField.tag == 0) {
        // Trim textField.text whitespaces
        textField.text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        sRedditClientId = textField.text;
        [[NSUserDefaults standardUserDefaults] setValue:sRedditClientId forKey:UDKeyRedditClientId];
    }
    else if (textField.tag == 1) {
        textField.text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        sImgurClientId = textField.text;
        [[NSUserDefaults standardUserDefaults] setValue:sImgurClientId forKey:UDKeyImgurClientId];
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

@end
