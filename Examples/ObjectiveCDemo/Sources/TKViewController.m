#import "TKViewController.h"

#import "TKDemoTelemetry.h"

@interface TKViewController ()

@property(nonatomic, strong) UISwitch *consentSwitch;
@property(nonatomic, strong) UIButton *captureButton;
@property(nonatomic, strong) UIButton *flushButton;
@property(nonatomic, strong) UITextView *statusView;

@end


@implementation TKViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"TelemetryKit · Objective-C";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    [self configureView];
    [self appendStatus:@"Collection is off. The client starts with pending consent."];
}

- (void)configureView {
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"Objective-C facade demo";
    titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];

    UILabel *detailLabel = [[UILabel alloc] init];
    detailLabel.text =
        @"Collection starts only after this app grants consent. The default endpoint is non-routable.";
    detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    detailLabel.textColor = UIColor.secondaryLabelColor;
    detailLabel.numberOfLines = 0;

    UILabel *consentLabel = [[UILabel alloc] init];
    consentLabel.text = @"Allow demo telemetry";
    [consentLabel setContentHuggingPriority:UILayoutPriorityDefaultLow
                                   forAxis:UILayoutConstraintAxisHorizontal];

    self.consentSwitch = [[UISwitch alloc] init];
    self.consentSwitch.accessibilityIdentifier = @"telemetry.consent";
    [self.consentSwitch addTarget:self
                           action:@selector(consentChanged:)
                 forControlEvents:UIControlEventValueChanged];

    UIStackView *consentRow =
        [[UIStackView alloc] initWithArrangedSubviews:@[consentLabel, self.consentSwitch]];
    consentRow.axis = UILayoutConstraintAxisHorizontal;
    consentRow.alignment = UIStackViewAlignmentCenter;
    consentRow.spacing = 12;

    self.captureButton = [self buttonWithTitle:@"Capture local event"
                                       action:@selector(captureEvent:)];
    self.flushButton = [self buttonWithTitle:@"Flush queue"
                                     action:@selector(flushQueue:)];
    self.captureButton.accessibilityIdentifier = @"telemetry.capture";

    self.statusView = [[UITextView alloc] init];
    self.statusView.accessibilityIdentifier = @"telemetry.status";
    self.statusView.editable = NO;
    self.statusView.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.statusView.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.statusView.layer.cornerRadius = 10;
    self.statusView.textContainerInset = UIEdgeInsetsMake(12, 10, 12, 10);
    [self.statusView.heightAnchor constraintGreaterThanOrEqualToConstant:180].active = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        titleLabel,
        detailLabel,
        consentRow,
        self.captureButton,
        self.flushButton,
        self.statusView
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    [stack setCustomSpacing:24 afterView:detailLabel];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:24],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor
                                                      constant:-16]
    ]];

    [self updateControls];
}

- (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
    configuration.title = title;
    button.configuration = configuration;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)consentChanged:(UISwitch *)sender {
    BOOL enabled = sender.isOn;
    sender.enabled = NO;

    __weak typeof(self) weakSelf = self;
    [[TKDemoTelemetry shared]
        setCollectionEnabled:enabled
                   completion:^(NSError * _Nullable error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil) { return; }

        if (error != nil) {
            [self.consentSwitch setOn:TKDemoTelemetry.shared.isCollectionEnabled animated:YES];
            [self appendStatus:[NSString stringWithFormat:@"Could not change collection: %@",
                                                          error.localizedDescription]];
        } else {
            [self appendStatus:enabled
                ? @"Consent granted; client started."
                : @"Consent denied; client shut down."];
        }
        self.consentSwitch.enabled = YES;
        [self updateControls];
    }];
}

- (void)captureEvent:(UIButton *)sender {
    sender.enabled = NO;
    __weak typeof(self) weakSelf = self;
    [[TKDemoTelemetry shared]
        captureButtonTapWithCompletion:^(NSError * _Nullable error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil) { return; }
        [self appendStatus:error == nil
            ? @"Event accepted by the local pipeline."
            : [NSString stringWithFormat:@"Capture failed: %@", error.localizedDescription]];
        [self updateControls];
    }];
}

- (void)flushQueue:(UIButton *)sender {
    sender.enabled = NO;
    __weak typeof(self) weakSelf = self;
    [[TKDemoTelemetry shared] flushWithCompletion:^(NSError * _Nullable error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil) { return; }
        [self appendStatus:error == nil
            ? @"Flush completed."
            : [NSString stringWithFormat:@"Flush failed: %@", error.localizedDescription]];
        [self updateControls];
    }];
}

- (void)updateControls {
    BOOL enabled = TKDemoTelemetry.shared.isCollectionEnabled;
    self.captureButton.enabled = enabled;
    self.flushButton.enabled = enabled;
}

- (void)appendStatus:(NSString *)message {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.timeStyle = NSDateFormatterMediumStyle;
    NSString *line = [NSString stringWithFormat:@"[%@] %@",
                                                [formatter stringFromDate:NSDate.date],
                                                message];
    self.statusView.text = self.statusView.text.length == 0
        ? line
        : [NSString stringWithFormat:@"%@\n%@", self.statusView.text, line];
    [self.statusView scrollRangeToVisible:NSMakeRange(self.statusView.text.length, 0)];
}

@end
