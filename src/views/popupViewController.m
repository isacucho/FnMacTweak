#import "popupViewController.h"
#import "../globals.h"
#import "../FnAppearance.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface popupViewController ()
@property(nonatomic, strong) UIStackView *stack;
@property(nonatomic, strong) UILabel *folderLabel;
@property(nonatomic, strong) UIButton *menuButton;
@property(nonatomic, strong) UIButton *cursorButton;
@property(nonatomic, strong) UIButton *graphicsButton;
@property(nonatomic, strong) UISwitch *borderlessSwitch;
@property(nonatomic, strong) UISwitch *fpsSwitch;
@property(nonatomic, strong) UISwitch *backgroundSwitch;
@end

@implementation popupViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = UIColor.clearColor;
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    self.stack = [UIStackView new];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = 7;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:self.stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:0],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-12],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [self.stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [self.stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        // Leave room for the native controls' edges inside the scroll viewport.
        [self.stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-12],
        [self.stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-12]
    ]];
    self.borderlessSwitch = [self addSwitch:@"Borderless Windowed" value:isBorderlessModeEnabled action:@selector(borderlessChanged:)];
    self.fpsSwitch = [self addSwitch:@"Unlock Frame Rate" value:fnUnlockFrameRate action:@selector(fpsChanged:)];
    self.backgroundSwitch = [self addSwitch:@"Run When Unfocused" value:fnStayActive action:@selector(backgroundChanged:)];
    self.menuButton = [self addShortcut:@"Settings Shortcut" action:@selector(bindMenu) clear:@selector(clearMenu)];
    self.graphicsButton = [self addShortcut:@"Graphics Panel Shortcut" action:@selector(bindGraphics) clear:@selector(clearGraphics)];
    self.cursorButton = [self addShortcut:@"Lock / Unlock Cursor" action:@selector(bindCursor) clear:@selector(clearCursor)];
    [self addLabel:@"Click a shortcut, then press a key. Esc cancels.\nCursor visibility follows the game automatically." size:11];
    [self addButton:@"Select Fortnite Data Folder" action:@selector(selectFolder)];
    self.folderLabel = [self addLabel:@"" size:11];
    self.folderLabel.numberOfLines = 2;
    self.folderLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self addLabel:@"Restart Fortnite after changing the folder." size:11];
    [self refresh];
}

- (UILabel *)addLabel:(NSString *)text size:(CGFloat)size {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont systemFontOfSize:size];
    label.textColor = UIColor.secondaryLabelColor;
    label.numberOfLines = 0;
    [self.stack addArrangedSubview:label];
    return label;
}

- (UIButton *)makeButton:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    button.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    button.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    button.layer.cornerRadius = 6;
    [button.heightAnchor constraintEqualToConstant:32].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIButton *)addButton:(NSString *)title action:(SEL)action {
    UIButton *button = [self makeButton:title action:action];
    [self.stack addArrangedSubview:button];
    return button;
}

- (UIButton *)addShortcut:(NSString *)title action:(SEL)action clear:(SEL)clear {
    UILabel *label = [UILabel new];
    label.text = title;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    UIButton *button = [self makeButton:@"" action:action];
    button.accessibilityLabel = title;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, button]];
    row.spacing = 6;
    row.alignment = UIStackViewAlignmentCenter;
    [label.widthAnchor constraintEqualToConstant:220].active = YES;
    if (clear) {
        UIButton *reset = [self makeButton:@"×" action:clear];
        reset.accessibilityLabel = [NSString stringWithFormat:@"Clear %@", title];
        [reset.widthAnchor constraintEqualToConstant:24].active = YES;
        [row addArrangedSubview:reset];
    }
    [self.stack addArrangedSubview:row];
    return button;
}

- (UISwitch *)addSwitch:(NSString *)title value:(BOOL)value action:(SEL)action {
    UILabel *label = [UILabel new];
    label.text = title;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    UISwitch *toggle = [UISwitch new];
    toggle.on = value;
    toggle.onTintColor = fnAccentColor();
    [toggle setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [toggle setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [toggle addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, toggle]];
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 8;
    row.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
    row.layer.cornerRadius = 12;
    row.layoutMargins = UIEdgeInsetsMake(8, 12, 8, 12);
    row.layoutMarginsRelativeArrangement = YES;
    [label setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [self.stack addArrangedSubview:row];
    return toggle;
}

- (void)refresh {
    [self.menuButton setTitle:fnShortcutTitle(fnMenuShortcut) forState:UIControlStateNormal];
    [self.graphicsButton setTitle:fnShortcutTitle(fnGraphicsShortcut) forState:UIControlStateNormal];
    [self.cursorButton setTitle:fnShortcutTitle(fnCursorShortcut) forState:UIControlStateNormal];
    self.borderlessSwitch.on = isBorderlessModeEnabled;
    self.fpsSwitch.on = fnUnlockFrameRate;
    self.backgroundSwitch.on = fnStayActive;
    self.folderLabel.text = fnDataFolder().path ?: @"No folder selected";
}

- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self refresh]; }
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated]; fnShortcutCapture = nil; [self refresh]; }
- (BOOL)prefersPointerLocked { return NO; }
- (void)closeTapped { fnShowMenu(NO); }
- (void)borderlessChanged:(UISwitch *)sender { [tweakDefaults() setBool:sender.on forKey:kBorderlessWindowKey]; fnSettingsChanged(); }
- (void)fpsChanged:(UISwitch *)sender { [tweakDefaults() setBool:sender.on forKey:kUnlockFrameRateKey]; fnSettingsChanged(); }
- (void)backgroundChanged:(UISwitch *)sender { [tweakDefaults() setBool:sender.on forKey:kStayActiveKey]; fnSettingsChanged(); }

- (void)captureShortcut:(NSInteger)action {
    fnShortcutCapture = nil;
    [self refresh];
    NSArray *buttons = @[self.menuButton, self.graphicsButton, self.cursorButton];
    UIButton *button = buttons[action];
    [button setTitle:@"Press a key… (Escape to cancel)" forState:UIControlStateNormal];
    __weak typeof(self) weakSelf = self;
    fnShortcutCapture = ^(NSDictionary *shortcut) {
        typeof(self) self = weakSelf;
        if (!self) return;
        if (!shortcut) { [self refresh]; return; }
        NSArray *keys = @[kMenuShortcutKey, kGraphicsShortcutKey, kCursorShortcutKey];
        NSArray *shortcuts = @[fnMenuShortcut, fnGraphicsShortcut, fnCursorShortcut];
        for (NSInteger i = 0; i < 3; i++) {
            NSDictionary *other = shortcuts[i];
            if (i != action && other.count && [other[@"code"] isEqual:shortcut[@"code"]] && [other[@"modifiers"] isEqual:shortcut[@"modifiers"]]) {
                [self showMessage:@"That shortcut is already assigned to another action."];
                [self refresh];
                return;
            }
        }
        [tweakDefaults() setObject:shortcut forKey:keys[action]];
        fnSettingsChanged();
        [self refresh];
    };
}
- (void)bindMenu { [self captureShortcut:0]; }
- (void)bindGraphics { [self captureShortcut:1]; }
- (void)bindCursor { [self captureShortcut:2]; }
- (void)clearShortcut:(NSString *)key {
    fnShortcutCapture = nil;
    [tweakDefaults() setObject:@{} forKey:key];
    fnSettingsChanged();
    [self refresh];
}
- (void)clearMenu { [self clearShortcut:kMenuShortcutKey]; }
- (void)clearGraphics { [self clearShortcut:kGraphicsShortcutKey]; }
- (void)clearCursor { [self clearShortcut:kCursorShortcutKey]; }

- (void)showMessage:(NSString *)text {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"FnMacTweak-kbm" message:text preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)selectFolder {
    fnShortcutCapture = nil;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    NSError *error = nil;
    if (!fnSelectDataFolder(url, &error)) [self showMessage:error.localizedDescription ?: @"Unable to save folder access."];
    else [self showMessage:@"Folder saved. Restart Fortnite to use it."];
    [self refresh];
}
@end
