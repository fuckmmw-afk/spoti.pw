#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "AISpatialModelStore.h"
#import "AISpatialSeparator.h"
#import "AISpatialLog.h"
#import "AISpatialDiagnostics.h"
#import "AISpatialAccentDetector.h"
#import "AISpatialBuild.h"

static NSString *const kModelPageURL = @"https://huggingface.co/My-Name-Is-Jeff/vitrine-sing";
static IMP gOriginalViewDidAppear;
static IMP gOriginalViewDidLayoutSubviews;
static BOOL gViewDidAppearHooked;
static BOOL gViewDidLayoutHooked;
static __weak UIViewController *gActivePage;
static const void *kAISpatialPageMarker = &kAISpatialPageMarker;
static const void *kAISpatialActionTarget = &kAISpatialActionTarget;
static const void *kAISpatialFooterMarker = &kAISpatialFooterMarker;
static const void *kAISpatialActivationSwitch = &kAISpatialActivationSwitch;
static const void *kAISpatialRootRowMarker = &kAISpatialRootRowMarker;
static const void *kASUIAssociatedKey = &kASUIAssociatedKey;
static const void *kASUIPreset = &kASUIPreset;

@interface AISpatialDiagnosticsViewController : UIViewController
@property(nonatomic,strong) UISegmentedControl *levelControl;
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UILabel *counterLabel;
@property(nonatomic,strong) UIButton *recordButton;
@end

@interface AISpatialAccentViewController : UIViewController
@property(nonatomic,strong) UISwitch *analysisSwitch;
@property(nonatomic,strong) UILabel *summaryLabel;
@property(nonatomic,strong) UIStackView *eventsStack;
@property(nonatomic,strong) NSTimer *refreshTimer;
@end

@interface AISpatialEngineControlsViewController : UIViewController
@property(nonatomic,strong) UISegmentedControl *modeControl;
@property(nonatomic,strong) UISegmentedControl *routeControl;
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) NSTimer *statusTimer;
@end

@interface AISpatialRootMenuRow : UIControl
@end

@implementation AISpatialRootMenuRow {
    UIImageView *_icon;
    UILabel *_title;
    UILabel *_subtitle;
    UIImageView *_chevron;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];
    self.layer.cornerRadius = 12;
    self.clipsToBounds = YES;
    _icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"waveform.path.ecg" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightMedium]]];
    _icon.tintColor = UIColor.whiteColor;
    _icon.backgroundColor = [UIColor colorWithRed:0.34 green:0.28 blue:0.85 alpha:1];
    _icon.layer.cornerRadius = 7;
    _icon.contentMode = UIViewContentModeCenter;
    _title = [UILabel new]; _title.text = @"AI Spatial engine"; _title.textColor = UIColor.whiteColor; _title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _subtitle = [UILabel new]; _subtitle.text = @"Local selective spatial audio"; _subtitle.textColor = [UIColor colorWithWhite:0.68 alpha:1]; _subtitle.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    _chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold]]]; _chevron.tintColor = UIColor.whiteColor; _chevron.contentMode = UIViewContentModeCenter;
    for (UIView *view in @[_icon, _title, _subtitle, _chevron]) [self addSubview:view];
    self.accessibilityLabel = @"AI Spatial engine";
    self.accessibilityHint = @"Open AI Spatial engine settings";
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.bounds.size.height;
    _icon.frame = CGRectMake(12, (h - 32) / 2, 32, 32);
    _title.frame = CGRectMake(56, h / 2 - 19, MAX(0, self.bounds.size.width - 104), 20);
    _subtitle.frame = CGRectMake(56, h / 2 + 2, MAX(0, self.bounds.size.width - 104), 17);
    _chevron.frame = CGRectMake(self.bounds.size.width - 34, (h - 20) / 2, 20, 20);
}
- (void)setHighlighted:(BOOL)highlighted { [super setHighlighted:highlighted]; self.alpha = highlighted ? 0.55 : 1; }
@end

static const void *kAISpatialAccentEventID = &kAISpatialAccentEventID;

static NSString *const kASUIEngine = @"spotifyglass.ai-spatial.engine-enabled";
static NSString *const kASUIMode = @"spotifyglass.ai-spatial.mode";
static NSString *const kASUIIntensity = @"spotifyglass.ai-spatial.intensity";
static NSString *const kASUIWidth = @"spotifyglass.ai-spatial.width";
static NSString *const kASUIDepth = @"spotifyglass.ai-spatial.depth";
static NSString *const kASUIAccentDensity = @"spotifyglass.ai-spatial.accent-rate";
static NSString *const kASUIRoute = @"spotifyglass.ai-spatial.route";
static NSString *const kASUIAccentMotion = @"spotifyglass.ai-spatial.accent-motion";
static NSString *const kASUIWidthEnabled = @"spotifyglass.ai-spatial.stereo-width-enabled";
static NSString *const kASUIDepthEnabled = @"spotifyglass.ai-spatial.depth-enabled";
static NSString *const kASUIReflections = @"spotifyglass.ai-spatial.reflections-enabled";
static NSString *const kASUIHRTF = @"spotifyglass.ai-spatial.hrtf-enabled";
static NSString *const kASUIDeterministic = @"spotifyglass.ai-spatial.deterministic";
static NSString *const kASUISpatialTrace = @"spotifyglass.ai-spatial.spatial-trace";
static NSString *const kASUIFullTrace = @"spotifyglass.ai-spatial.full-trace";

static void ASUIRefreshSpatial(void) {
    void (*refresh)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "AISpatialLiveRefreshConfiguration");
    if (refresh) refresh();
}

@implementation AISpatialEngineControlsViewController
- (UISwitch *)switchForKey:(NSString *)key title:(NSString *)title stack:(UIStackView *)stack {
    UILabel *label=[UILabel new]; label.text=title; label.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody]; UISwitch *toggle=[UISwitch new]; toggle.on=[NSUserDefaults.standardUserDefaults boolForKey:key]; toggle.accessibilityLabel=title; objc_setAssociatedObject(toggle, kASUIAssociatedKey, key, OBJC_ASSOCIATION_COPY_NONATOMIC); [toggle addTarget:self action:@selector(componentChanged:) forControlEvents:UIControlEventValueChanged]; UIStackView *row=[[UIStackView alloc] initWithArrangedSubviews:@[label,toggle]]; row.axis=UILayoutConstraintAxisHorizontal; row.alignment=UIStackViewAlignmentCenter; row.distribution=UIStackViewDistributionEqualSpacing; [stack addArrangedSubview:row]; return toggle;
}
- (UISlider *)slider:(NSString *)title key:(NSString *)key min:(float)min max:(float)max stack:(UIStackView *)stack {
    UILabel *label=[UILabel new]; label.text=title; label.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody]; UISlider *slider=[UISlider new]; slider.minimumValue=min; slider.maximumValue=max; slider.value=[NSUserDefaults.standardUserDefaults doubleForKey:key]; slider.accessibilityLabel=title; objc_setAssociatedObject(slider, kASUIAssociatedKey, key, OBJC_ASSOCIATION_COPY_NONATOMIC); [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged]; UIStackView *row=[[UIStackView alloc] initWithArrangedSubviews:@[label,slider]]; row.axis=UILayoutConstraintAxisVertical; row.spacing=2; [stack addArrangedSubview:row]; return slider;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.title=@"Spatial Engine"; self.view.backgroundColor=UIColor.systemBackgroundColor; self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close:)];
    UIScrollView *scroll=[UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints=NO; UIStackView *stack=[[UIStackView alloc] initWithFrame:CGRectZero]; stack.axis=UILayoutConstraintAxisVertical; stack.spacing=10; stack.translatesAutoresizingMaskIntoConstraints=NO; [scroll addSubview:stack]; [self.view addSubview:scroll]; UILayoutGuide *g=self.view.safeAreaLayoutGuide; [NSLayoutConstraint activateConstraints:@[[scroll.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:20],[scroll.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-20],[scroll.topAnchor constraintEqualToAnchor:g.topAnchor constant:12],[scroll.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],[stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],[stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],[stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],[stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],[stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]]];
    UILabel *intro=[UILabel new]; intro.numberOfLines=0; intro.textColor=UIColor.secondaryLabelColor; intro.text=@"Selective foreground motion runs locally before the existing JamesDSP path. Original and Shadow are safe starting points."; [stack addArrangedSubview:intro];
    self.statusLabel=[UILabel new]; self.statusLabel.numberOfLines=0; self.statusLabel.font=[UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular]; [stack addArrangedSubview:self.statusLabel];
    UISwitch *engine=[self switchForKey:kASUIEngine title:@"Spatial Engine" stack:stack]; [engine addTarget:self action:@selector(engineChanged:) forControlEvents:UIControlEventValueChanged];
    UILabel *modeLabel=[UILabel new]; modeLabel.text=@"Mode"; [stack addArrangedSubview:modeLabel]; self.modeControl=[[UISegmentedControl alloc] initWithItems:@[@"Original",@"Shadow",@"Live",@"Diagnostic"]]; self.modeControl.selectedSegmentIndex=MIN(MAX([NSUserDefaults.standardUserDefaults integerForKey:kASUIMode],0),3); [self.modeControl addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged]; [stack addArrangedSubview:self.modeControl];
    UILabel *routeLabel=[UILabel new]; routeLabel.text=@"Output Profile"; [stack addArrangedSubview:routeLabel]; self.routeControl=[[UISegmentedControl alloc] initWithItems:@[@"Headphones",@"Speakers",@"Universal",@"Mono"]]; self.routeControl.selectedSegmentIndex=MIN(MAX([NSUserDefaults.standardUserDefaults integerForKey:kASUIRoute],0),3); [self.routeControl addTarget:self action:@selector(routeChanged:) forControlEvents:UIControlEventValueChanged]; [stack addArrangedSubview:self.routeControl];
    [self slider:@"Intensity" key:kASUIIntensity min:0 max:1 stack:stack]; [self slider:@"Stereo Width" key:kASUIWidth min:0 max:1 stack:stack]; [self slider:@"Depth" key:kASUIDepth min:0 max:1 stack:stack]; [self slider:@"Accent Density" key:kASUIAccentDensity min:1 max:10 stack:stack];
    [self switchForKey:kASUIAccentMotion title:@"Accent Motion" stack:stack]; [self switchForKey:kASUIWidthEnabled title:@"Stereo Width Enabled" stack:stack]; [self switchForKey:kASUIDepthEnabled title:@"Depth Enabled" stack:stack]; [self switchForKey:kASUIReflections title:@"Reflections" stack:stack]; [self switchForKey:kASUIHRTF title:@"HRTF" stack:stack]; [self switchForKey:kASUIDeterministic title:@"Deterministic Test Mode" stack:stack];
    UILabel *traceTitle=[UILabel new]; traceTitle.text=@"Diagnostics & Spatial Trace"; traceTitle.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]; [stack addArrangedSubview:traceTitle];
    [self switchForKey:kASUISpatialTrace title:@"Spatial Trace" stack:stack]; [self switchForKey:kASUIFullTrace title:@"Full Trace" stack:stack];
    UIButton *diagnostics=[UIButton buttonWithType:UIButtonTypeSystem]; [diagnostics setTitle:@"Open Diagnostics" forState:UIControlStateNormal]; diagnostics.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading; [diagnostics addTarget:self action:@selector(openDiagnostics:) forControlEvents:UIControlEventTouchUpInside]; [stack addArrangedSubview:diagnostics];
    UILabel *presetTitle=[UILabel new]; presetTitle.text=@"Presets"; [stack addArrangedSubview:presetTitle]; for (NSArray *preset in @[@[@"Extra Wide 3D",@"0.9",@"0.95",@"0.55"],@[@"Natural Spatial",@"0.5",@"0.55",@"0.35"],@[@"Dynamic Accents",@"0.7",@"0.7",@"0.45"],@[@"Headphones 3D",@"0.75",@"0.85",@"0.65"],@[@"Speakers Wide",@"0.55",@"0.55",@"0.35"],@[@"Universal Safe",@"0.3",@"0.35",@"0.2"]]) { UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem]; [b setTitle:preset[0] forState:UIControlStateNormal]; b.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading; objc_setAssociatedObject(b, &kASUIPreset, preset, OBJC_ASSOCIATION_RETAIN_NONATOMIC); [b addTarget:self action:@selector(presetChanged:) forControlEvents:UIControlEventTouchUpInside]; [stack addArrangedSubview:b]; }
    [self updateStatus];
    __weak typeof(self) weakSelf = self;
    self.statusTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *timer) { [weakSelf updateStatus]; }];
}
- (void)dealloc { [self.statusTimer invalidate]; }
- (void)close:(id)sender { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)updateStatus { NSDictionary *s=AISpatialLiveStatusSnapshot(); self.statusLabel.text=[NSString stringWithFormat:@"%@\nRequested: %@\nRenderer: %@\nSpatial enabled: %@\nCallbacks: %@\nEpoch: %@\nStems rendered: %@\nFallback frames: %@\nAccent applied: %@\nBase scene frames: %@\nNonzero output delta: %@\nDelta peak: %@\nDelta RMS: %@\nFallbacks: %@",s[@"mode_name"]?:@"Original",s[@"requested_mode_name"]?:@"Original",s[@"spatial_route"]?:@"unknown",[s[@"spatial_enabled"] boolValue]?@"YES":@"NO",s[@"streaming_callback_blocks"]?:@0,s[@"stream_epoch"]?:@"none",s[@"rendered_stem_frames"]?:@0,s[@"rendered_fallback_frames"]?:@0,s[@"spatial_applied"]?:@0,s[@"spatial_base_applied"]?:@0,s[@"spatial_nonzero_delta_samples"]?:@0,s[@"spatial_delta_peak"]?:@0,s[@"spatial_delta_rms"]?:@0,s[@"fallbacks"]?:@0]; }
- (void)engineChanged:(UISwitch *)sender { [NSUserDefaults.standardUserDefaults setBool:sender.isOn forKey:kASUIEngine]; if(!sender.isOn){[NSUserDefaults.standardUserDefaults setInteger:0 forKey:kASUIMode]; AISpatialLiveSetMode(AISpatialLiveModeOriginal);} ASUIRefreshSpatial(); [self updateStatus]; }
- (void)modeChanged:(UISegmentedControl *)sender { NSInteger mode=sender.selectedSegmentIndex; [NSUserDefaults.standardUserDefaults setInteger:mode forKey:kASUIMode]; [NSUserDefaults.standardUserDefaults setBool:mode!=0 forKey:kASUIEngine]; if(mode==3) mode=1; if(mode!=AISpatialLiveModeOriginal && !AISpatialModelStore.sharedStore.modelIsReady){sender.selectedSegmentIndex=0; [self showMessage:@"Download and verify the model first."]; return;} AISpatialLiveSetMode((AISpatialLiveMode)mode); ASUIRefreshSpatial(); [self updateStatus]; }
- (void)routeChanged:(UISegmentedControl *)sender { [NSUserDefaults.standardUserDefaults setInteger:sender.selectedSegmentIndex forKey:kASUIRoute]; ASUIRefreshSpatial(); }
- (void)componentChanged:(UISwitch *)sender { NSString *key=objc_getAssociatedObject(sender, kASUIAssociatedKey); if(key) [NSUserDefaults.standardUserDefaults setBool:sender.isOn forKey:key]; if([key isEqualToString:kASUISpatialTrace] || [key isEqualToString:kASUIFullTrace]) { NSInteger level=[NSUserDefaults.standardUserDefaults boolForKey:kASUIFullTrace]?2:([NSUserDefaults.standardUserDefaults boolForKey:kASUISpatialTrace]?1:0); void (*setLevel)(NSInteger)=(void (*)(NSInteger))dlsym(RTLD_DEFAULT,"AISpatialDiagnosticsSetLevelIndex"); if(setLevel) setLevel(level); } ASUIRefreshSpatial(); }
- (void)sliderChanged:(UISlider *)sender { NSString *key=objc_getAssociatedObject(sender, kASUIAssociatedKey); if(key) [NSUserDefaults.standardUserDefaults setDouble:sender.value forKey:key]; ASUIRefreshSpatial(); }
- (void)presetChanged:(UIButton *)sender { NSArray *p=objc_getAssociatedObject(sender,&kASUIPreset); if(p.count>=4){[NSUserDefaults.standardUserDefaults setDouble:[p[1] doubleValue] forKey:kASUIIntensity];[NSUserDefaults.standardUserDefaults setDouble:[p[2] doubleValue] forKey:kASUIWidth];[NSUserDefaults.standardUserDefaults setDouble:[p[3] doubleValue] forKey:kASUIDepth];} ASUIRefreshSpatial(); [self updateStatus]; }
- (void)openDiagnostics:(id)sender { AISpatialDiagnosticsViewController *controller=[AISpatialDiagnosticsViewController new]; [self presentViewController:[[UINavigationController alloc] initWithRootViewController:controller] animated:YES completion:nil]; }
- (void)showMessage:(NSString *)message { UIAlertController *a=[UIAlertController alertControllerWithTitle:@"AI Spatial" message:message preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:a animated:YES completion:nil]; }
@end

@implementation AISpatialAccentViewController

- (UIButton *)accentButton:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal]; button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; button.accessibilityLabel = title;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES; return button;
}

- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"Accent Detector"; self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close:)];
    UIScrollView *scroll = [UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints = NO;
    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero]; stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *description = [UILabel new]; description.numberOfLines = 0; description.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]; description.textColor = UIColor.secondaryLabelColor;
    description.text = @"Local hybrid analysis of synchronized vocals and instrumental stems. It creates a sparse event schedule for a future Spatial Engine and never changes Spotify audio.";
    [stack addArrangedSubview:description];
    UIStackView *toggleRow = [[UIStackView alloc] initWithArrangedSubviews:@[[[UILabel alloc] initWithFrame:CGRectZero], [UISwitch new]]]; toggleRow.axis = UILayoutConstraintAxisHorizontal; toggleRow.alignment = UIStackViewAlignmentCenter; toggleRow.distribution = UIStackViewDistributionEqualSpacing;
    UILabel *toggleLabel = toggleRow.arrangedSubviews.firstObject; toggleLabel.text = @"Enable Accent Trace"; toggleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]; self.analysisSwitch = toggleRow.arrangedSubviews.lastObject; self.analysisSwitch.on = ASAccentDetectorIsEnabled(); [self.analysisSwitch addTarget:self action:@selector(toggleAnalysis:) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:toggleRow];
    self.summaryLabel = [UILabel new]; self.summaryLabel.numberOfLines = 0; self.summaryLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular]; [stack addArrangedSubview:self.summaryLabel];
    [stack addArrangedSubview:[self accentButton:@"Export Accent events (JSON, CSV)" action:@selector(exportEvents:)]];
    [stack addArrangedSubview:[self accentButton:@"Record a missed event" action:@selector(recordMissed:)]];
    UILabel *recent = [UILabel new]; recent.text = @"Recent events — tap a review control"; recent.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]; [stack addArrangedSubview:recent];
    self.eventsStack = [[UIStackView alloc] initWithFrame:CGRectZero]; self.eventsStack.axis = UILayoutConstraintAxisVertical; self.eventsStack.spacing = 6; [stack addArrangedSubview:self.eventsStack];
    [scroll addSubview:stack]; [self.view addSubview:scroll]; UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[[scroll.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:20], [scroll.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-20], [scroll.topAnchor constraintEqualToAnchor:guide.topAnchor constant:12], [scroll.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor], [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor], [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor], [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor], [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor], [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]]];
    [self refresh]; self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(__unused NSTimer *timer) { [self refresh]; }];
}
- (void)dealloc { [self.refreshTimer invalidate]; }
- (void)close:(id)sender { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)toggleAnalysis:(UISwitch *)sender { ASAccentDetectorSetEnabled(sender.isOn); [self refresh]; }
- (void)refresh {
    NSDictionary *summary = ASAccentDetectorSnapshot(); self.summaryLabel.text = [NSString stringWithFormat:@"Candidates: %@\nSelected: %@   Rejected: %@\nEpoch: %@   Queue: %@   Dropped blocks: %@\nTypes: %@\nPolicy: %@", summary[@"candidates"], summary[@"selected"], summary[@"rejected"], summary[@"stream_epoch"], summary[@"analysis_queue_depth"], summary[@"dropped_analysis_blocks"], summary[@"type_distribution"], summary[@"policy"][@"selection"]];
    for (UIView *view in self.eventsStack.arrangedSubviews) [self.eventsStack removeArrangedSubview:view], [view removeFromSuperview];
    NSArray *events = ASAccentDetectorRecentEvents(12);
    if (!events.count) { UILabel *empty = [UILabel new]; empty.text = @"No candidates yet. Start Spotify playback with the model ready."; empty.textColor = UIColor.secondaryLabelColor; empty.numberOfLines = 0; [self.eventsStack addArrangedSubview:empty]; return; }
    for (NSDictionary *event in events.reverseObjectEnumerator) {
        UILabel *label = [UILabel new]; label.numberOfLines = 0; label.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular]; label.text = [NSString stringWithFormat:@"%@  %@  %.2fs\n%@  conf %.2f  priority %.2f  %@\n%@", event[@"decision"], event[@"source"], [event[@"start_time_seconds"] doubleValue], event[@"type"], [event[@"classification_confidence"] doubleValue], [event[@"priority"] doubleValue], event[@"decision_reason"], event[@"event_id"]];
        [self.eventsStack addArrangedSubview:label];
        UISegmentedControl *review = [[UISegmentedControl alloc] initWithItems:@[@"Удачное", @"Лишнее", @"Пропущенное"]]; review.selectedSegmentIndex = UISegmentedControlNoSegment; review.accessibilityLabel = [NSString stringWithFormat:@"Review %@", event[@"event_id"]]; objc_setAssociatedObject(review, kAISpatialAccentEventID, event[@"event_id"], OBJC_ASSOCIATION_COPY_NONATOMIC); [review addTarget:self action:@selector(reviewChanged:) forControlEvents:UIControlEventValueChanged]; [self.eventsStack addArrangedSubview:review];
    }
}
- (void)reviewChanged:(UISegmentedControl *)control { NSString *eventID = objc_getAssociatedObject(control, kAISpatialAccentEventID); NSArray *labels = @[@"successful", @"extra", @"missed"]; if (control.selectedSegmentIndex >= 0 && control.selectedSegmentIndex < labels.count) ASAccentDetectorSetManualLabel(eventID, labels[control.selectedSegmentIndex]); }
- (void)exportEvents:(id)sender { NSError *error = nil; NSArray *files = ASAccentDetectorExport(&error); if (!files.count) { UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Accent Detector" message:error.localizedDescription ?: @"No events available." preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:a animated:YES completion:nil]; return; } [self presentViewController:[[UIActivityViewController alloc] initWithActivityItems:files applicationActivities:nil] animated:YES completion:nil]; }
- (void)recordMissed:(id)sender { UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Record missed event" message:@"Enter the approximate sample index or seconds and source." preferredStyle:UIAlertControllerStyleAlert]; [a addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"sample index or time"; }]; [a addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"vocals / instrumental"; }]; [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]]; [a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { ASAccentDetectorRecordManualMissed(a.textFields.firstObject.text, a.textFields.lastObject.text); }]]; [self presentViewController:a animated:YES completion:nil]; }
@end

@implementation AISpatialDiagnosticsViewController

- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    button.accessibilityLabel = title;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44.0].active = YES;
    return button;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Diagnostics";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close:)];
    UIScrollView *scroll = [UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints = NO;
    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero]; stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 8.0; stack.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *intro = [UILabel new]; intro.numberOfLines = 0; intro.textColor = UIColor.secondaryLabelColor; intro.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    intro.text = @"Diagnostics measures the offline AI Spatial file test and, while recording, collects metrics from Spotify's post-render PCM observer. It never changes JamesDSP buffers. Full Trace keeps bounded binary samples only on this iPhone.";
    [stack addArrangedSubview:intro];
    UILabel *levelTitle = [UILabel new]; levelTitle.text = @"Recording level"; levelTitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]; [stack addArrangedSubview:levelTitle];
    self.levelControl = [[UISegmentedControl alloc] initWithItems:@[@"Basic", @"Detailed", @"Full Trace"]]; self.levelControl.selectedSegmentIndex = AISpatialDiagnostics.sharedDiagnostics.level; [self.levelControl addTarget:self action:@selector(levelChanged:) forControlEvents:UIControlEventValueChanged]; [stack addArrangedSubview:self.levelControl];
    self.statusLabel = [UILabel new]; self.statusLabel.numberOfLines = 0; self.statusLabel.font = [UIFont monospacedSystemFontOfSize:13.0 weight:UIFontWeightRegular]; [stack addArrangedSubview:self.statusLabel];
    self.counterLabel = [UILabel new]; self.counterLabel.numberOfLines = 0; self.counterLabel.font = [UIFont monospacedSystemFontOfSize:13.0 weight:UIFontWeightRegular]; [stack addArrangedSubview:self.counterLabel];
    self.recordButton = [self button:@"Start diagnostics" action:@selector(toggleRecording:)]; [stack addArrangedSubview:self.recordButton];
    [stack addArrangedSubview:[self button:@"Export report (log, timeline, metadata)" action:@selector(exportReport:)]];
    [stack addArrangedSubview:[self button:@"Export Full Trace debug ZIP" action:@selector(exportDebug:)]];
    [stack addArrangedSubview:[self button:@"Run Spatial Output Self-Test (A → B → C)" action:@selector(selfTest:)]];
    [stack addArrangedSubview:[self button:@"Clear diagnostics" action:@selector(clearLogs:)]];
    [scroll addSubview:stack]; [self.view addSubview:scroll];
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:20.0], [scroll.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-20.0], [scroll.topAnchor constraintEqualToAnchor:guide.topAnchor constant:12.0], [scroll.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor], [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor], [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor], [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor], [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]
    ]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(diagnosticsChanged:) name:AISpatialDiagnosticsDidChangeNotification object:AISpatialDiagnostics.sharedDiagnostics];
    [self refresh];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)close:(id)sender { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)diagnosticsChanged:(NSNotification *)note { dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; }); }
- (void)refresh {
    AISpatialDiagnostics *diagnostics = AISpatialDiagnostics.sharedDiagnostics; NSDictionary *snapshot = diagnostics.snapshot;
    AISpatialModelStore *model = AISpatialModelStore.sharedStore;
    NSDictionary *live = AISpatialLiveStatusSnapshot();
    NSDictionary *selfTest = AISpatialLiveSelfTestStatusSnapshot();
    self.statusLabel.text = [NSString stringWithFormat:@"State: %@\nLevel: %@\nSession: %@\nModel: %@\nModel status: %@\nLive mode: %@\nLive state: %@\nSelf-test: %@ (%@)", snapshot[@"state"], snapshot[@"level"], snapshot[@"session_id"], model.modelIsReady ? @"ready" : @"not ready", model.statusText ?: @"unavailable", live[@"mode_name"] ?: @"Original", live[@"state"] ?: @"unavailable", selfTest[@"phase"] ?: @"Idle", selfTest[@"actual_renderer"] ?: @"unavailable"];
    self.counterLabel.text = [NSString stringWithFormat:@"Processed windows: %@\nSkipped windows: %@\nLive callbacks: %@ blocks / %@ frames (duplicates %@)\nLive processed/skipped: %@ / %@\nStems rendered/fallback frames: %@ / %@\nSpatial enabled: %@\nSpatial base frames: %@\nAccent applied: %@\nNonzero output delta: %@\nDelta peak/RMS: %@ / %@\nInference queue: %lu\nLive queue: %@\nLive latency target: %@ s\nLive underruns/overflows/fallbacks: %@ / %@ / %@\nDropped diagnostic events: %@\nDropped PCM capture blocks: %@\nWriter queue: %@ events / %@ bytes\nLog bytes: %@\nDebug bytes: %@\nWarnings: %@  Errors: %@\nMemory: measured when a timeline row is emitted", snapshot[@"processed_windows"], snapshot[@"skipped_windows"], live[@"streaming_callback_blocks"] ?: @0, live[@"streaming_callback_frames"] ?: @0, live[@"duplicate_callback_blocks"] ?: @0, live[@"processed_windows"] ?: @0, live[@"skipped_windows"] ?: @0, live[@"rendered_stem_frames"] ?: @0, live[@"rendered_fallback_frames"] ?: @0, [live[@"spatial_enabled"] boolValue] ? @"YES" : @"NO", live[@"spatial_base_applied"] ?: @0, live[@"spatial_applied"] ?: @0, live[@"spatial_nonzero_delta_samples"] ?: @0, live[@"spatial_delta_peak"] ?: @0, live[@"spatial_delta_rms"] ?: @0, (unsigned long)model.inferenceQueueDepth, live[@"queue_depth"] ?: @0, live[@"latency_target_seconds"] ?: @0, live[@"underruns"] ?: @0, live[@"overflows"] ?: @0, live[@"fallbacks"] ?: @0, snapshot[@"dropped_events"], snapshot[@"dropped_capture_blocks"], snapshot[@"writer_queue_depth"], snapshot[@"writer_queue_bytes"], snapshot[@"log_bytes"], snapshot[@"debug_bytes"], snapshot[@"warnings"], snapshot[@"errors"]];
    [self.recordButton setTitle:diagnostics.recording ? @"Stop diagnostics" : @"Start diagnostics" forState:UIControlStateNormal];
    self.levelControl.selectedSegmentIndex = diagnostics.level;
}
- (void)levelChanged:(UISegmentedControl *)control { [AISpatialDiagnostics.sharedDiagnostics setLevel:(AISpatialDiagnosticsLevel)control.selectedSegmentIndex]; [self refresh]; }
- (void)toggleRecording:(id)sender { if (AISpatialDiagnostics.sharedDiagnostics.recording) [AISpatialDiagnostics.sharedDiagnostics stopRecording]; else [AISpatialDiagnostics.sharedDiagnostics startRecording]; [self refresh]; }
- (void)selfTest:(id)sender {
    NSDictionary *status = AISpatialLiveSelfTestStatusSnapshot();
    NSString *phase = status[@"phase"] ?: @"Idle";
    if (![phase isEqualToString:@"Idle"]) { AISpatialLiveStopSpatialSelfTest(); [self refresh]; return; }
    AISpatialLiveStartSpatialSelfTest();
    [self refresh];
}
- (void)shareFiles:(NSArray<NSURL *> *)files fromError:(NSError *)error {
    if (error || !files.count) { UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Diagnostics" message:error.localizedDescription ?: @"No diagnostic report is available." preferredStyle:UIAlertControllerStyleAlert]; [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:alert animated:YES completion:nil]; return; }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:files applicationActivities:nil]; [self presentViewController:share animated:YES completion:nil];
}
- (void)exportReport:(id)sender { [AISpatialDiagnostics.sharedDiagnostics exportReportIncludingDebug:NO completion:^(NSArray<NSURL *> *files, NSError *error) { [self shareFiles:files fromError:error]; }]; }
- (void)exportDebug:(id)sender { [AISpatialDiagnostics.sharedDiagnostics exportReportIncludingDebug:YES completion:^(NSArray<NSURL *> *files, NSError *error) { [self shareFiles:files fromError:error]; }]; }
- (void)clearLogs:(id)sender { [AISpatialDiagnostics.sharedDiagnostics clearLogs]; [self refresh]; }
@end

@interface AISpatialActionTarget : NSObject <UIDocumentPickerDelegate>
@property(nonatomic, weak) UIViewController *page;
@end

static NSString *AISpatialLower(NSString *value) { return value.lowercaseString ?: @""; }
static BOOL AISpatialEquals(NSString *value, NSString *expected) { return [AISpatialLower(value) isEqualToString:AISpatialLower(expected)]; }
static BOOL AISpatialContains(NSString *value, NSString *part) { return [AISpatialLower(value) containsString:AISpatialLower(part)]; }
static NSString *AISpatialLiveModeName(AISpatialLiveMode mode) {
    switch (mode) {
        case AISpatialLiveModeShadow: return @"AI Shadow";
        case AISpatialLiveModeLive: return @"AI Live";
        case AISpatialLiveModeVocalsOnly: return @"Vocals Only (test)";
        case AISpatialLiveModeInstrumentalOnly: return @"Instrumental Only (test)";
        case AISpatialLiveModeOriginal:
        default: return @"Original";
    }
}

static void AISpatialWalk(UIView *view, void (^visitor)(UIView *view)) {
    if (!view || !visitor) return;
    visitor(view);
    for (UIView *child in view.subviews.copy) AISpatialWalk(child, visitor);
}

static UITableView *AISpatialTable(UIViewController *controller) {
    if ([controller isKindOfClass:UITableViewController.class]) return [(UITableViewController *)controller tableView];
    __block UITableView *result;
    AISpatialWalk(controller.view, ^(UIView *view) {
        if (!result && [view isKindOfClass:UITableView.class]) result = (UITableView *)view;
    });
    return result;
}

static UITableViewCell *AISpatialCellForView(UIView *view) {
    UIView *current = view;
    while (current) {
        if ([current isKindOfClass:UITableViewCell.class]) return (UITableViewCell *)current;
        current = current.superview;
    }
    return nil;
}

static NSArray<UILabel *> *AISpatialLabelsInView(UIView *root) {
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    AISpatialWalk(root, ^(UIView *view) {
        if ([view isKindOfClass:UILabel.class]) [labels addObject:(UILabel *)view];
    });
    return labels;
}

static BOOL AISpatialLooksLikeSingPage(UIViewController *controller) {
    if (objc_getAssociatedObject(controller, kAISpatialPageMarker)) return YES;
    NSString *title = controller.navigationItem.title ?: controller.title;
    if (AISpatialEquals(title, @"Sing")) return YES;
    __block BOOL hasVoiceModel = NO;
    __block BOOL hasDownloadRow = NO;
    AISpatialWalk(controller.view, ^(UIView *view) {
        if (![view isKindOfClass:UILabel.class]) return;
        NSString *text = ((UILabel *)view).text;
        hasVoiceModel |= AISpatialContains(text, @"Voice model");
        hasDownloadRow |= AISpatialContains(text, @"Download voice model");
    });
    return hasVoiceModel && hasDownloadRow;
}

static NSString *AISpatialDisplayStatus(void) {
    AISpatialModelStore *store = AISpatialModelStore.sharedStore;
    // The store can publish its final notification just before a recreated
    // Spotify cell is laid out. Prefer the verified runtime flag so a native
    // cell cannot briefly overwrite the ready state with "Not downloaded".
    if (store.modelIsReady) return @"Ready for offline separation";
    switch (store.status) {
        case AISpatialModelStatusDownloading: return [NSString stringWithFormat:@"Downloading %.0f%%", store.progress * 100.0];
        case AISpatialModelStatusVerifying: return [NSString stringWithFormat:@"Checking files %.0f%%", store.progress * 100.0];
        case AISpatialModelStatusInstalling: return @"Checking Core ML compatibility";
        case AISpatialModelStatusInitializing: return @"Initializing Neural Engine";
        case AISpatialModelStatusReady: return @"Ready for offline separation";
        case AISpatialModelStatusCanceled: return @"Download canceled";
        case AISpatialModelStatusFailed: return @"Download failed";
        case AISpatialModelStatusNotInstalled:
        default: return @"Not downloaded";
    }
}

@interface AISpatialActionTarget ()
- (void)showMessage:(NSString *)message;
- (void)openControls:(id)sender;
@end

@implementation AISpatialActionTarget

- (void)openControls:(id)sender {
    UIViewController *page=self.page; if (!page) return;
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:[AISpatialEngineControlsViewController new]];
    navigation.modalPresentationStyle=UIModalPresentationPageSheet;
    [page presentViewController:navigation animated:YES completion:nil];
}

- (void)download:(id)sender {
    AISpatialModelStore *store = AISpatialModelStore.sharedStore;
    if (store.status == AISpatialModelStatusDownloading || store.status == AISpatialModelStatusVerifying ||
        store.status == AISpatialModelStatusInstalling || store.status == AISpatialModelStatusInitializing) {
        [store cancelDownload];
    } else if (store.status == AISpatialModelStatusFailed || store.status == AISpatialModelStatusCanceled) {
        [store retryDownload];
    } else {
        [store startDownload];
    }
    AISpatialLog(@"existing Sing row mapped to AI Spatial model action");
}

- (void)openModelPage:(id)sender {
    NSURL *url = [NSURL URLWithString:kModelPageURL];
    if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

- (void)toggleActivation:(UIButton *)sender {
    UISwitch *control = objc_getAssociatedObject(sender, kAISpatialActivationSwitch);
    UIViewController *page = self.page;
    if (!control) return;
    if (!AISpatialModelStore.sharedStore.modelIsReady) {
        control.on = NO;
        if (page) [self showMessage:@"Download and verify the AI Spatial model first."];
        return;
    }
    control.on = !control.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:control.isOn forKey:@"pw.chroma.ai-spatial.enabled"];
    if (!control.isOn) {
        AISpatialLiveSetMode(AISpatialLiveModeOriginal);
    } else if (AISpatialLiveGetMode() == AISpatialLiveModeOriginal) {
        AISpatialLiveSetMode(AISpatialLiveModeShadow);
    }
    AISpatialLog(@"AI Spatial activation changed: enabled=%@", control.isOn ? @"YES" : @"NO");
}

- (void)selectLiveMode:(id)sender {
    UIViewController *page = self.page;
    if (!page) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"AI Spatial playback mode" message:@"AI Live adds the measured model buffering delay. Shadow runs the model while Spotify keeps the original sound." preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSNumber *> *modes = @[@(AISpatialLiveModeOriginal), @(AISpatialLiveModeShadow), @(AISpatialLiveModeLive), @(AISpatialLiveModeVocalsOnly), @(AISpatialLiveModeInstrumentalOnly)];
    for (NSNumber *number in modes) {
        AISpatialLiveMode mode = (AISpatialLiveMode)number.integerValue;
        [sheet addAction:[UIAlertAction actionWithTitle:AISpatialLiveModeName(mode) style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            if (mode != AISpatialLiveModeOriginal && !AISpatialModelStore.sharedStore.modelIsReady) {
                [self showMessage:@"Download and verify the AI Spatial model before selecting an AI playback mode."];
                return;
            }
            AISpatialLiveSetMode(mode);
            [[NSUserDefaults standardUserDefaults] setBool:mode != AISpatialLiveModeOriginal forKey:@"pw.chroma.ai-spatial.enabled"];
            [self showMessage:[NSString stringWithFormat:@"Mode: %@\nStatus: %@", AISpatialLiveModeName(mode), AISpatialLiveStatusSnapshot()[@"state"] ?: @"unavailable"]];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = (UIView *)sender;
    sheet.popoverPresentationController.sourceRect = [(UIView *)sender bounds];
    [page presentViewController:sheet animated:YES completion:nil];
}

- (void)deleteModel:(id)sender {
    UIViewController *page = self.page;
    if (!page) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete model?" message:@"The model can be downloaded again later." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [AISpatialModelStore.sharedStore deleteModel];
    }]];
    [page presentViewController:alert animated:YES completion:nil];
}

- (void)testSeparation:(id)sender {
    UIViewController *page = self.page;
    if (!page) return;
    if (!AISpatialModelStore.sharedStore.modelIsReady) {
        [self showMessage:@"Download and verify the model first."];
        return;
    }
    // Import instead of opening a security-scoped provider URL.  Spotify's
    // process can otherwise reject an MP3 after the Files picker dismisses.
    NSArray<NSString *> *documentTypes = @[
        UTTypeMP3.identifier,
        UTTypeMPEG4Audio.identifier,
        UTTypeAudio.identifier
    ];
    NSMutableArray<UTType *> *contentTypes = [NSMutableArray array];
    for (NSString *identifier in documentTypes) {
        UTType *type = [UTType typeWithIdentifier:identifier];
        if (type) [contentTypes addObject:type];
    }
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:contentTypes asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    AISpatialLog(@"test picker opened; accepted types=mp3,m4a,wav,audio");
    [page presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    UIViewController *page = self.page;
    if (!url || !page) return;
    BOOL accessed = [url startAccessingSecurityScopedResource];
    NSError *copyError = nil;
    NSString *extension = url.pathExtension.lowercaseString.length ? url.pathExtension.lowercaseString : @"audio";
    NSString *name = [NSString stringWithFormat:@"ai-spatial-input-%@.%@", @((long long)(NSDate.date.timeIntervalSince1970 * 1000.0)), extension];
    NSURL *stagedURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    [[NSFileManager defaultManager] removeItemAtURL:stagedURL error:nil];
    if (![[NSFileManager defaultManager] copyItemAtURL:url toURL:stagedURL error:&copyError]) {
        if (accessed) [url stopAccessingSecurityScopedResource];
        AISpatialLog(@"test input copy failed: source=%@ extension=%@ error=%@", url.path, extension, copyError.localizedDescription);
        [self showMessage:copyError.localizedDescription ?: @"Не удалось импортировать аудиофайл в AI Spatial."];
        return;
    }
    if (accessed) [url stopAccessingSecurityScopedResource];
    AISpatialLog(@"test input imported: source=%@ staged=%@ extension=%@", url.path, stagedURL.path, extension);
    [[AISpatialSeparator sharedSeparator] runTestWithAudioURL:stagedURL completion:^(NSURL *vocalsURL, NSURL *instrumentalURL, NSError *error) {
        [[NSFileManager defaultManager] removeItemAtURL:stagedURL error:nil];
        NSString *message = error ? error.localizedDescription : [NSString stringWithFormat:@"Done.\nVocals: %@\nInstrumental: %@", vocalsURL.path, instrumentalURL.path];
        AISpatialLog(@"test picker completed: success=%@ error=%@", error ? @"NO" : @"YES", error.localizedDescription);
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AI Spatial" message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [page presentViewController:alert animated:YES completion:nil];
    }];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    AISpatialLog(@"test picker cancelled");
}

- (void)exportLogs:(id)sender {
    UIViewController *page = self.page;
    if (!page) return;
    [AISpatialDiagnostics.sharedDiagnostics exportReportIncludingDebug:NO completion:^(NSArray<NSURL *> *files, NSError *error) {
        if (error || !files.count) { [self showMessage:error.localizedDescription ?: @"Сначала запустите диагностический тест."]; return; }
        UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:files applicationActivities:nil];
        [page presentViewController:share animated:YES completion:nil];
    }];
}

- (void)openDiagnostics:(id)sender {
    UIViewController *page = self.page;
    if (!page) return;
    AISpatialDiagnosticsViewController *controller = [AISpatialDiagnosticsViewController new];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:controller];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    [page presentViewController:navigation animated:YES completion:nil];
}

- (void)openAccentDetector:(id)sender {
    UIViewController *page = self.page; if (!page) return;
    AISpatialAccentViewController *controller = [AISpatialAccentViewController new];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:controller]; navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    [page presentViewController:navigation animated:YES completion:nil];
}

- (void)showMessage:(NSString *)message {
    UIViewController *page = self.page;
    if (!page) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AI Spatial" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [page presentViewController:alert animated:YES completion:nil];
}

@end

static AISpatialActionTarget *AISpatialTargetForButton(UIView *view, UIViewController *page) {
    AISpatialActionTarget *target = objc_getAssociatedObject(view, kAISpatialActionTarget);
    if (!target) {
        target = [AISpatialActionTarget new];
        objc_setAssociatedObject(view, kAISpatialActionTarget, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    target.page = page;
    return target;
}

static void AISpatialMapDownloadRow(UIViewController *page, UILabel *label) {
    UITableViewCell *cell = AISpatialCellForView(label);
    UIView *container = cell ? cell.contentView : label.superview;
    if (!container) return;
    NSString *newText = @"Download AI Spatial model";
    if (![label.text isEqualToString:newText]) label.text = newText;
    if (objc_getAssociatedObject(container, kAISpatialActionTarget)) return;
    UIButton *overlay = [UIButton buttonWithType:UIButtonTypeCustom];
    overlay.frame = container.bounds;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = UIColor.clearColor;
    overlay.accessibilityLabel = newText;
    AISpatialActionTarget *target = AISpatialTargetForButton(overlay, page);
    [overlay addTarget:target action:@selector(download:) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:overlay];
    objc_setAssociatedObject(container, kAISpatialActionTarget, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void AISpatialMapActivationRow(UIViewController *page, UILabel *label) {
    UITableViewCell *cell = AISpatialCellForView(label);
    UIView *container = cell ? cell.contentView : label.superview;
    if (!container || objc_getAssociatedObject(container, kAISpatialActivationSwitch)) return;
    __block UISwitch *control;
    AISpatialWalk(container, ^(UIView *view) {
        if (!control && [view isKindOfClass:UISwitch.class]) control = (UISwitch *)view;
    });
    if (!control) return;
    control.on = [[NSUserDefaults standardUserDefaults] boolForKey:@"pw.chroma.ai-spatial.enabled"];
    UIButton *overlay = [UIButton buttonWithType:UIButtonTypeCustom];
    overlay.frame = container.bounds;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = UIColor.clearColor;
    overlay.accessibilityLabel = @"AI Spatial";
    AISpatialActionTarget *target = AISpatialTargetForButton(overlay, page);
    objc_setAssociatedObject(overlay, kAISpatialActivationSwitch, control, OBJC_ASSOCIATION_ASSIGN);
    [overlay addTarget:target action:@selector(toggleActivation:) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:overlay];
    objc_setAssociatedObject(container, kAISpatialActivationSwitch, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void AISpatialRewriteText(UIViewController *page) {
    AISpatialWalk(page.view, ^(UIView *view) {
        if (![view isKindOfClass:UILabel.class]) return;
        UILabel *label = (UILabel *)view;
        NSString *text = label.text ?: @"";
        if (AISpatialEquals(text, @"Sing")) {
            AISpatialMapActivationRow(page, label);
            if (![label.text isEqualToString:@"AI Spatial"]) label.text = @"AI Spatial";
        }
        else if (AISpatialEquals(text, @"Sing along")) label.text = @"AI Spatial";
        else if (AISpatialEquals(text, @"Voice model")) label.text = @"AI Spatial model";
        else if (AISpatialEquals(text, @"Download voice model")) AISpatialMapDownloadRow(page, label);
        else if (AISpatialEquals(text, @"Remove voice model")) label.text = @"Remove AI Spatial model";
        else if (AISpatialContains(text, @"Turns the song's vocals down") || AISpatialContains(text, @"Sing separates a song")) {
            label.text = @"AI Spatial separates vocals and instruments locally on this iPhone after the model is installed. It does not attach to Spotify playback or JamesDSP.";
        }
    });
}

static BOOL AISpatialLooksLikeRootMenu(UIViewController *controller) {
    if (!controller || AISpatialLooksLikeSingPage(controller) || !AISpatialTable(controller)) return NO;
    __block BOOL hasSing = NO, hasAudioEffects = NO, hasMod = NO, hasAI = NO;
    AISpatialWalk(controller.view, ^(UIView *view) {
        if (![view isKindOfClass:UILabel.class]) return;
        NSString *text = ((UILabel *)view).text ?: @"";
        hasSing |= AISpatialEquals(text, @"Sing");
        hasAudioEffects |= AISpatialEquals(text, @"Audio effects");
        hasMod |= AISpatialEquals(text, @"Mod");
        hasAI |= AISpatialEquals(text, @"AI Spatial engine") || AISpatialEquals(text, @"AI Spatial Engine");
    });
    return hasSing && hasAudioEffects && hasMod && !hasAI;
}

static void AISpatialInstallRootMenuRow(UIViewController *controller) {
    if (!AISpatialLooksLikeRootMenu(controller)) return;
    UITableView *table = AISpatialTable(controller);
    if (!table || objc_getAssociatedObject(table, kAISpatialRootRowMarker)) return;
    AISpatialRootMenuRow *row = [[AISpatialRootMenuRow alloc] initWithFrame:CGRectZero];
    AISpatialActionTarget *target = [AISpatialActionTarget new];
    target.page = controller;
    [row addTarget:target action:@selector(openControls:) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(row, kAISpatialActionTarget, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *oldFooter = table.tableFooterView;
    CGFloat oldHeight = oldFooter ? MAX(CGRectGetHeight(oldFooter.bounds), 1) : 0;
    CGFloat width = MAX(CGRectGetWidth(table.bounds), 320);
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, oldHeight + 76)];
    footer.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    row.frame = CGRectMake(16, 8, width - 32, 56);
    row.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [footer addSubview:row];
    if (oldFooter) {
        oldFooter.frame = CGRectMake(0, 76, width, oldHeight);
        oldFooter.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [footer addSubview:oldFooter];
    }
    table.tableFooterView = footer;
    objc_setAssociatedObject(table, kAISpatialRootRowMarker, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    AISpatialLog(@"AI Spatial root settings row installed without changing Sing");
}

static void AISpatialUpdateModelCell(UIViewController *page) {
    NSString *status = AISpatialDisplayStatus();
    AISpatialWalk(page.view, ^(UIView *view) {
        if (![view isKindOfClass:UITableViewCell.class]) return;
        UITableViewCell *cell = (UITableViewCell *)view;
        NSArray<UILabel *> *labels = AISpatialLabelsInView(cell);
        BOOL isModelCell = NO;
        for (UILabel *label in labels) {
            if (AISpatialEquals(label.text, @"AI Spatial model") || AISpatialEquals(label.text, @"Voice model")) {
                isModelCell = YES;
                break;
            }
        }
        if (!isModelCell || labels.count < 2) return;
        UILabel *value = labels.lastObject;
        if (![value.text isEqualToString:status]) value.text = status;
        value.accessibilityValue = status;
    });
}

static UIButton *AISpatialFooterButton(NSString *title, AISpatialActionTarget *target, SEL action, CGRect frame) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = frame;
    button.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    button.accessibilityLabel = title;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(button, kAISpatialActionTarget, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return button;
}

static void AISpatialInstallFooter(UIViewController *page) {
    UITableView *table = AISpatialTable(page);
    if (!table) {
        if (objc_getAssociatedObject(page, kAISpatialFooterMarker)) return;
        AISpatialActionTarget *target = [AISpatialActionTarget new];
        target.page = page;
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
            AISpatialFooterButton(@"Open model page", target, @selector(openModelPage:), CGRectZero),
            AISpatialFooterButton(@"Test first 30 seconds", target, @selector(testSeparation:), CGRectZero),
            AISpatialFooterButton(@"Select Original / Shadow / Live mode", target, @selector(selectLiveMode:), CGRectZero),
            AISpatialFooterButton(@"Spatial Engine settings", target, @selector(openControls:), CGRectZero),
            AISpatialFooterButton(@"Diagnostics", target, @selector(openDiagnostics:), CGRectZero),
            AISpatialFooterButton(@"Accent Detector", target, @selector(openAccentDetector:), CGRectZero),
            AISpatialFooterButton(@"Export diagnostics", target, @selector(exportLogs:), CGRectZero),
            AISpatialFooterButton(@"Delete AI Spatial model", target, @selector(deleteModel:), CGRectZero)
        ]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 2.0;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [page.view addSubview:stack];
        UILayoutGuide *guide = page.view.safeAreaLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:page.view.leadingAnchor constant:20.0],
            [stack.trailingAnchor constraintEqualToAnchor:page.view.trailingAnchor constant:-20.0],
            [stack.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-8.0],
        ]];
        objc_setAssociatedObject(stack, kAISpatialActionTarget, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(page, kAISpatialFooterMarker, stack, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (objc_getAssociatedObject(table, kAISpatialFooterMarker)) return;
    UIView *oldFooter = table.tableFooterView;
    CGFloat oldHeight = oldFooter ? MAX(CGRectGetHeight(oldFooter.bounds), 1.0) : 0.0;
    CGFloat extraHeight = 8.0 * 50.0 + 12.0;
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, table.bounds.size.width, oldHeight + extraHeight)];
    footer.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    if (oldFooter) {
        oldFooter.frame = CGRectMake(0, 0, footer.bounds.size.width, oldHeight);
        oldFooter.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [footer addSubview:oldFooter];
    }
    AISpatialActionTarget *target = [AISpatialActionTarget new];
    target.page = page;
    CGFloat y = oldHeight + 4.0;
    CGFloat width = MAX(CGRectGetWidth(footer.bounds) - 40.0, 100.0);
    [footer addSubview:AISpatialFooterButton(@"Open model page", target, @selector(openModelPage:), CGRectMake(20, y, width, 44))]; y += 50.0;
    [footer addSubview:AISpatialFooterButton(@"Test first 30 seconds", target, @selector(testSeparation:), CGRectMake(20, y, width, 44))]; y += 50.0;
    [footer addSubview:AISpatialFooterButton(@"Select Original / Shadow / Live mode", target, @selector(selectLiveMode:), CGRectMake(20, y, width, 44))]; y += 50.0;
    [footer addSubview:AISpatialFooterButton(@"Spatial Engine settings", target, @selector(openControls:), CGRectMake(20, y, width, 44))]; y += 50.0;
    [footer addSubview:AISpatialFooterButton(@"Diagnostics", target, @selector(openDiagnostics:), CGRectMake(20, y, width, 44))]; y += 50.0;
    [footer addSubview:AISpatialFooterButton(@"Accent Detector", target, @selector(openAccentDetector:), CGRectMake(20, y, width, 44))]; y += 50.0;
    [footer addSubview:AISpatialFooterButton(@"Export diagnostics", target, @selector(exportLogs:), CGRectMake(20, y, width, 44))]; y += 50.0;
    [footer addSubview:AISpatialFooterButton(@"Delete AI Spatial model", target, @selector(deleteModel:), CGRectMake(20, y, width, 44))];
    objc_setAssociatedObject(footer, kAISpatialActionTarget, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    table.tableFooterView = footer;
    objc_setAssociatedObject(table, kAISpatialFooterMarker, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void AISpatialRefreshPage(UIViewController *controller) {
    if (!controller || !AISpatialLooksLikeSingPage(controller)) return;
    if (!objc_getAssociatedObject(controller, kAISpatialPageMarker)) {
        objc_setAssociatedObject(controller, kAISpatialPageMarker, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        gActivePage = controller;
        AISpatialLog(@"existing Sing page adapted in place as AI Spatial (%@)", NSStringFromClass(controller.class));
    }
    if (![controller.title isEqualToString:@"AI Spatial"]) controller.title = @"AI Spatial";
    if (![controller.navigationItem.title isEqualToString:@"AI Spatial"]) controller.navigationItem.title = @"AI Spatial";
    AISpatialRewriteText(controller);
    AISpatialUpdateModelCell(controller);
    AISpatialInstallFooter(controller);
}

static void AISpatialScheduleRefresh(UIViewController *controller) {
    for (NSNumber *delay in @[@0.05, @0.25, @0.75, @1.5, @3.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            AISpatialRefreshPage(controller);
        });
    }
}

static void AISpatialViewDidAppear(id self, SEL selector, BOOL animated) {
    if (gOriginalViewDidAppear) ((void (*)(id, SEL, BOOL))gOriginalViewDidAppear)(self, selector, animated);
    AISpatialScheduleRefresh((UIViewController *)self);
}

static void AISpatialViewDidLayoutSubviews(id self, SEL selector) {
    if (gOriginalViewDidLayoutSubviews) ((void (*)(id, SEL))gOriginalViewDidLayoutSubviews)(self, selector);
    UIViewController *controller = (UIViewController *)self;
    AISpatialInstallRootMenuRow(controller);
    if (controller == gActivePage || objc_getAssociatedObject(controller, kAISpatialPageMarker) ||
        AISpatialEquals(controller.navigationItem.title, @"AI Spatial")) {
        AISpatialRefreshPage(controller);
    }
}

static void __attribute__((unused)) AISpatialInstallLifecycleHook(void) {
    if (gViewDidAppearHooked) return;
    Method method = class_getInstanceMethod(UIViewController.class, @selector(viewDidAppear:));
    if (!method) return;
    gOriginalViewDidAppear = method_getImplementation(method);
    method_setImplementation(method, (IMP)AISpatialViewDidAppear);
    gViewDidAppearHooked = YES;
    AISpatialLog(@"hooked UIViewController.viewDidAppear: for in-place Sing UI adaptation");
}

static void __attribute__((unused)) AISpatialInstallLayoutHook(void) {
    if (gViewDidLayoutHooked) return;
    Method method = class_getInstanceMethod(UIViewController.class, @selector(viewDidLayoutSubviews));
    if (!method) return;
    gOriginalViewDidLayoutSubviews = method_getImplementation(method);
    method_setImplementation(method, (IMP)AISpatialViewDidLayoutSubviews);
    gViewDidLayoutHooked = YES;
    AISpatialLog(@"hooked UIViewController.viewDidLayoutSubviews: for persistent AI Spatial labels");
}

__attribute__((constructor)) static void AISpatialInitialize(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        AISpatialInstallLayoutHook();
        /* The feature page belongs to the main croma Mod Settings tree.
           This dylib never hooks, renames, or replaces Spotify's Sing page. */
        AISpatialLog(@"AI Spatial initialized; controls are owned by croma -> AI Spatial engine; model remains remote-only");
    });
}
