#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Shared/JamesDSP/JamesDSPPage.h"
#import "Shared/JamesDSP/JamesDSP.h"
#import "AISpatialSettings.h"
#import <dlfcn.h>

static NSString *const kEngine = @"spotifyglass.ai-spatial.engine-enabled";
static NSString *const kMode = @"spotifyglass.ai-spatial.mode";
static NSString *const kIntensity = @"spotifyglass.ai-spatial.intensity";
static NSString *const kWidth = @"spotifyglass.ai-spatial.width";
static NSString *const kDepth = @"spotifyglass.ai-spatial.depth";
static NSString *const kAccentRate = @"spotifyglass.ai-spatial.accent-rate";
static NSString *const kMaxSources = @"spotifyglass.ai-spatial.max-active-sources";
static NSString *const kCenter = @"spotifyglass.ai-spatial.center-protection";
static NSString *const kBass = @"spotifyglass.ai-spatial.bass-protection";
static NSString *const kAntiPhase = @"spotifyglass.ai-spatial.anti-phase-limit";
static NSString *const kRoute = @"spotifyglass.ai-spatial.route";
static NSString *const kRouteAuto = @"spotifyglass.ai-spatial.route-auto";
static NSString *const kProfile = @"spotifyglass.ai-spatial.profile";
static NSString *const kFullTrace = @"spotifyglass.ai-spatial.full-trace";
static NSString *const kSpatialTrace = @"spotifyglass.ai-spatial.spatial-trace";
static NSString *const kAccentEnabled = @"spotifyglass.ai-spatial.accent-enabled";
static NSString *const kAccentMotion = @"spotifyglass.ai-spatial.accent-motion";
static NSString *const kStereoWidthEnabled = @"spotifyglass.ai-spatial.stereo-width-enabled";
static NSString *const kDepthEnabled = @"spotifyglass.ai-spatial.depth-enabled";
static NSString *const kReflectionsEnabled = @"spotifyglass.ai-spatial.reflections-enabled";
static NSString *const kHRTFEnabled = @"spotifyglass.ai-spatial.hrtf-enabled";
static NSString *const kMotionVariety = @"spotifyglass.ai-spatial.motion-variety";
static NSString *const kDeterministic = @"spotifyglass.ai-spatial.deterministic";

static void migrate(NSString *oldKey, NSString *newKey) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults objectForKey:newKey] && [defaults objectForKey:oldKey]) [defaults setObject:[defaults objectForKey:oldKey] forKey:newKey];
}

static void ensureDefaults(void) {
    migrate(@"pw.chroma.ai-spatial.enabled", kEngine);
    migrate(@"pw.chroma.ai-spatial.live-mode", kMode);
    migrate(@"pw.chroma.ai-spatial.accent-enabled", kAccentEnabled);
    migrate(@"pw.chroma.ai-spatial.route", kRoute);
    migrate(@"pw.chroma.ai-spatial.profile", kProfile);
    [NSUserDefaults.standardUserDefaults registerDefaults:@{kEngine:@NO, kMode:@0, kIntensity:@0.55, kWidth:@0.65,
        kDepth:@0.40, kAccentRate:@10, kMaxSources:@3, kCenter:@0.75, kBass:@0.70, kAntiPhase:@0.08,
        kRoute:@2, kRouteAuto:@YES, kProfile:@5, kFullTrace:@NO, kSpatialTrace:@NO, kAccentEnabled:@YES,
        kAccentMotion:@YES, kStereoWidthEnabled:@YES, kDepthEnabled:@YES, kReflectionsEnabled:@YES, kHRTFEnabled:@YES, kMotionVariety:@0.55, kDeterministic:@NO}];
}

__attribute__((constructor)) static void SGAISpatialSettingsInitialize(void) { ensureDefaults(); }

typedef void (*ASSetModeFn)(NSInteger);
typedef NSInteger (*ASGetModeFn)(void);
typedef NSDictionary *(*ASStatusFn)(void);
typedef NSDictionary *(*ASAccentStatusFn)(void);
typedef void (*ASAccentEnabledFn)(BOOL);
typedef void (*ASDiagnosticsLevelFn)(NSInteger);
typedef void (*ASDiagnosticsToggleFn)(void);
typedef void (*ASModelActionFn)(void);
typedef NSDictionary *(*ASModelStatusFn)(void);
typedef void (*ASDiagnosticsExportFn)(BOOL, void (^)(NSArray<NSURL *> *, NSError *));
typedef void (*ASRefreshFn)(void);

static void *asSymbol(const char *name) { return dlsym(RTLD_DEFAULT, name); }
static void refreshBackend(void) { ASRefreshFn fn=(ASRefreshFn)asSymbol("AISpatialLiveRefreshConfiguration"); if(fn) fn(); }
static NSDictionary *liveStatus(void) { ASStatusFn fn=(ASStatusFn)asSymbol("AISpatialLiveStatusSnapshot"); return fn ? fn() : @{}; }
static NSDictionary *accentStatus(void) { ASAccentStatusFn fn=(ASAccentStatusFn)asSymbol("ASAccentDetectorSnapshot"); return fn ? fn() : @{}; }
static NSDictionary *modelStatus(void) { ASModelStatusFn fn=(ASModelStatusFn)asSymbol("AISpatialModelStatusSnapshot"); return fn ? fn() : @{}; }
static BOOL spatialLoaded(void) { return asSymbol("AISpatialLiveSetMode") != NULL; }
static void setBackendMode(NSInteger mode) {
    ASSetModeFn fn=(ASSetModeFn)asSymbol("AISpatialLiveSetMode");
    /* Diagnostic intentionally runs the backend's Shadow path so it cannot
       alter audible PCM; its trace switch remains independent below. */
    if (fn) fn(mode == 3 ? 1 : mode);
}
static void setDiagnosticLevel(void) {
    NSInteger level = [NSUserDefaults.standardUserDefaults boolForKey:kFullTrace] ? 2 : ([NSUserDefaults.standardUserDefaults boolForKey:kSpatialTrace] ? 1 : 0);
    ASDiagnosticsLevelFn fn=(ASDiagnosticsLevelFn)asSymbol("AISpatialDiagnosticsSetLevelIndex"); if (fn) fn(level);
}
static NSString *modeName(void) {
    NSArray *names=@[@"Original",@"Spatial Shadow",@"Spatial Live",@"Diagnostic"];
    NSInteger mode=[NSUserDefaults.standardUserDefaults integerForKey:kMode];
    return mode>=0&&mode<names.count?names[mode]:names.firstObject;
}
static NSString *routeName(void) {
    NSArray *names=@[@"Headphones binaural",@"Speaker stereo",@"Universal Stereo",@"Mono / Safe Fallback"];
    NSInteger route=[NSUserDefaults.standardUserDefaults integerForKey:kRoute];
    return route>=0&&route<names.count?names[route]:names[2];
}
static NSString *profileName(void) {
    NSArray *names=@[@"Headphones",@"Speakers",@"Universal",@"Bluetooth",@"AirPlay",@"Universal Safe"];
    NSInteger profile=[NSUserDefaults.standardUserDefaults integerForKey:kProfile];
    return profile>=0&&profile<names.count?names[profile]:names.lastObject;
}
static NSString *number(double value, NSString *unit) { return [NSString stringWithFormat:@"%.0f%@", value, unit ?: @""]; }
static double getDouble(NSString *key, double fallback) { id value=[NSUserDefaults.standardUserDefaults objectForKey:key]; return value ? [value doubleValue] : fallback; }
static void setDouble(NSString *key, double value) { [NSUserDefaults.standardUserDefaults setDouble:value forKey:key]; }

static void chooseMode(NSInteger mode) {
    [NSUserDefaults.standardUserDefaults setBool:mode != 0 forKey:kEngine];
    setBackendMode(mode);
    /* Backend mode 1 is the non-audible shadow path for Diagnostic; keep the
       user-facing mode value in croma so it survives relaunch and is rendered
       correctly by this page. */
    [NSUserDefaults.standardUserDefaults setInteger:mode forKey:kMode];
    if (mode == 3) setDiagnosticLevel();
}

static void applyPreset(NSInteger index) {
    NSArray<NSDictionary *> *presets=@[
        @{kIntensity:@0.9,kWidth:@0.95,kDepth:@0.55,kAccentRate:@10,kMaxSources:@3,kCenter:@0.6,kBass:@0.7,kAntiPhase:@0.08,kRoute:@2},
        @{kIntensity:@0.5,kWidth:@0.55,kDepth:@0.35,kAccentRate:@6,kMaxSources:@2,kCenter:@0.85,kBass:@0.85,kAntiPhase:@0.05,kRoute:@2},
        @{kIntensity:@0.7,kWidth:@0.7,kDepth:@0.45,kAccentRate:@10,kMaxSources:@3,kCenter:@0.75,kBass:@0.75,kAntiPhase:@0.08,kRoute:@2},
        @{kIntensity:@0.75,kWidth:@0.85,kDepth:@0.65,kAccentRate:@8,kMaxSources:@3,kCenter:@0.7,kBass:@0.75,kAntiPhase:@0.10,kRoute:@0},
        @{kIntensity:@0.55,kWidth:@0.55,kDepth:@0.35,kAccentRate:@6,kMaxSources:@2,kCenter:@0.9,kBass:@0.9,kAntiPhase:@0.04,kRoute:@1},
        @{kIntensity:@0.3,kWidth:@0.35,kDepth:@0.2,kAccentRate:@4,kMaxSources:@1,kCenter:@0.95,kBass:@0.95,kAntiPhase:@0.02,kRoute:@2}
    ];
    if (index<0 || index>=presets.count) return;
    [presets[index] enumerateKeysAndObjectsUsingBlock:^(NSString *key,id value,BOOL *stop){ [NSUserDefaults.standardUserDefaults setObject:value forKey:key]; }];
    [NSUserDefaults.standardUserDefaults setInteger:index forKey:kProfile];
}

static void showFiles(NSArray<NSURL *> *files, NSError *error) {
    UIViewController *top=SGTopController();
    if (!files.count) { UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"AI Spatial Engine" message:error.localizedDescription ?: @"No diagnostics are available yet." preferredStyle:UIAlertControllerStyleAlert]; [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; [top presentViewController:alert animated:YES completion:nil]; return; }
    [top presentViewController:[[UIActivityViewController alloc] initWithActivityItems:files applicationActivities:nil] animated:YES completion:nil];
}

NSString *SGAISpatialSummary(void) {
    if (!spatialLoaded()) return @"Unavailable";
    NSDictionary *live=liveStatus();
    NSString *state=live[@"state"] ?: @"ready";
    return [NSString stringWithFormat:@"%@ · %@ · %@", modeName(), routeName(), state];
}

UIViewController *SGAISpatialEnginePage(void) {
    ensureDefaults();
    NSArray *modes=@[@"Original",@"Spatial Shadow",@"Spatial Live",@"Diagnostic"];
    NSArray *routes=@[@"Headphones binaural",@"Speaker stereo",@"Universal Stereo",@"Mono / Safe Fallback"];
    NSArray *profiles=@[@"Headphones",@"Speakers",@"Universal",@"Bluetooth",@"AirPlay",@"Universal Safe"];
    NSArray *presets=@[@"Extra Wide",@"Natural Spatial",@"Dynamic Accents",@"Headphones 3D",@"Speakers Wide",@"Universal Safe"];
    SGModRow *engine=SGOptionRow(@"Enable Spatial Engine", @"Original remains unchanged until a spatial mode is selected", kEngine);
    engine.changed=^(BOOL on){ if(!on) chooseMode(0); else if([NSUserDefaults.standardUserDefaults integerForKey:kMode]==0) chooseMode(1); };
    SGModRow *mode=SGChoiceRow(@"Mode", nil, kMode, modes, 0); mode.chosen=^(NSInteger i){ chooseMode(i); };
    SGModRow *route=SGChoiceRow(@"Output renderer", @"A Bluetooth A2DP route is not assumed to be headphones", kRoute, routes, 2);
    SGModRow *routeAuto=SGSwitchRow(@"Automatic route detection", @"Unknown outputs use Mono / Safe Fallback", kRouteAuto);
    routeAuto.changed=^(BOOL on){ [NSUserDefaults.standardUserDefaults setBool:on forKey:kRouteAuto]; refreshBackend(); };
    route.chosen=^(NSInteger i){ [NSUserDefaults.standardUserDefaults setInteger:i forKey:kRoute]; refreshBackend(); };
    SGModRow *profile=SGChoiceRow(@"Route profile", nil, kProfile, profiles, 5); profile.chosen=^(NSInteger i){ [NSUserDefaults.standardUserDefaults setInteger:i forKey:kProfile]; refreshBackend(); };
    SGModRow *status=SGStatRow(@"Engine status", ^NSString *{ return SGAISpatialSummary(); });
    SGModRow *backend=SGStatRow(@"Current route", ^NSString *{ NSDictionary *s=liveStatus(); NSNumber *r=s[@"spatial_route"]; NSArray *names=@[@"Headphones binaural",@"Speaker stereo",@"Universal Stereo",@"Mono / Safe Fallback"]; return r && r.integerValue>=0 && r.integerValue<names.count ? names[r.integerValue] : routeName(); });
    SGModRow *warning=SGStatRow(@"Warnings / fallback", ^NSString *{ NSDictionary *s=liveStatus(); return s[@"state"] ?: (spatialLoaded()?@"none":@"AI Spatial tweak not loaded"); });
    SGModRow *separator=SGOptionRow(@"AI Separator", @"The Core ML model remains downloaded by the user into the app container", @"spotifyglass.ai-spatial.separator-enabled");
    SGModRow *accent=SGOptionRow(@"AI Accent Detector", @"Sparse vocal and instrumental event schedule", kAccentEnabled);
    accent.changed=^(BOOL on){ ASAccentEnabledFn fn=(ASAccentEnabledFn)asSymbol("ASAccentDetectorSetEnabled"); if(fn)fn(on); };
    SGModRow *model=SGStatActionRow(@"Model", nil, ^NSString *{ NSDictionary *s=modelStatus(); if(!s.count)return @"Unavailable"; if([s[@"ready"] boolValue])return @"Ready"; return s[@"status_text"] ?: @"Not installed"; }, ^{ ASModelActionFn fn=(ASModelActionFn)asSymbol("AISpatialModelStartDownload"); if(fn)fn(); });
    SGModRow *intensity=SGSliderRow(@"3D intensity", nil, 0, 1, .05, ^double{return getDouble(kIntensity,.55);}, ^(double v){setDouble(kIntensity,v); refreshBackend();}, ^NSString*(double v){return [NSString stringWithFormat:@"%.0f%%",v*100];});
    SGModRow *width=SGSliderRow(@"Scene width", nil, 0, 1, .05, ^double{return getDouble(kWidth,.65);}, ^(double v){setDouble(kWidth,v); refreshBackend();}, ^NSString*(double v){return [NSString stringWithFormat:@"%.0f%%",v*100];});
    SGModRow *depth=SGSliderRow(@"Scene depth", nil, 0, 1, .05, ^double{return getDouble(kDepth,.4);}, ^(double v){setDouble(kDepth,v); refreshBackend();}, ^NSString*(double v){return [NSString stringWithFormat:@"%.0f%%",v*100];});
    SGModRow *accentMotion=SGOptionRow(@"Accent Motion", @"Enable selective event gestures", kAccentMotion); accentMotion.changed=^(BOOL on){refreshBackend();};
    SGModRow *stereoWidth=SGOptionRow(@"Stereo Width", @"Keep the stable base scene width", kStereoWidthEnabled); stereoWidth.changed=^(BOOL on){refreshBackend();};
    SGModRow *depthEnabled=SGOptionRow(@"Depth", @"Enable distance and approach cues", kDepthEnabled); depthEnabled.changed=^(BOOL on){refreshBackend();};
    SGModRow *reflections=SGOptionRow(@"Reflections", @"Short early reflections and tails", kReflectionsEnabled); reflections.changed=^(BOOL on){refreshBackend();};
    SGModRow *hrtf=SGOptionRow(@"HRTF", @"Headphone binaural processing", kHRTFEnabled); hrtf.changed=^(BOOL on){refreshBackend();};
    SGModRow *variety=SGSliderRow(@"Motion Variety", @"How often accents use larger gestures", 0, 1, .05, ^double{return getDouble(kMotionVariety,.55);}, ^(double v){setDouble(kMotionVariety,v); refreshBackend();}, ^NSString*(double v){return [NSString stringWithFormat:@"%.0f%%",v*100];});
    SGModRow *rate=SGSliderRow(@"Accent Density", @"Upper bound per rolling minute", 1, 10, 1, ^double{return getDouble(kAccentRate,10);}, ^(double v){setDouble(kAccentRate,v);}, ^NSString*(double v){return number(v,@"/min");});
    SGModRow *active=SGSliderRow(@"Maximum active sources", nil, 1, 4, 1, ^double{return getDouble(kMaxSources,3);}, ^(double v){setDouble(kMaxSources,v);}, ^NSString*(double v){return number(v,@"");});
    SGModRow *center=SGSliderRow(@"Preserve Vocal Center", nil, 0, 1, .05, ^double{return getDouble(kCenter,.75);}, ^(double v){setDouble(kCenter,v); refreshBackend();}, ^NSString*(double v){return [NSString stringWithFormat:@"%.0f%%",v*100];});
    SGModRow *bass=SGSliderRow(@"Preserve Bass", nil, 0, 1, .05, ^double{return getDouble(kBass,.7);}, ^(double v){setDouble(kBass,v); refreshBackend();}, ^NSString*(double v){return [NSString stringWithFormat:@"%.0f%%",v*100];});
    SGModRow *anti=SGSliderRow(@"Limit anti-phase", nil, 0, .25, .01, ^double{return getDouble(kAntiPhase,.08);}, ^(double v){setDouble(kAntiPhase,v); refreshBackend();}, ^NSString*(double v){return [NSString stringWithFormat:@"%.0f%%",v*100];});
    NSMutableArray *presetRows=[NSMutableArray array]; for(NSUInteger i=0;i<presets.count;i++){ NSInteger index=i; [presetRows addObject:SGActionRow(presets[i], nil, ^{applyPreset(index);})]; }
    SGModRow *full=SGOptionRow(@"Full Trace", @"Bounded diagnostic capture; never enabled by a preset", kFullTrace); full.changed=^(BOOL on){setDiagnosticLevel(); ASDiagnosticsLevelFn fn=(ASDiagnosticsLevelFn)asSymbol("AISpatialDiagnosticsSetLevelIndex"); if(fn)fn(on?2:([NSUserDefaults.standardUserDefaults boolForKey:kSpatialTrace]?1:0));};
    SGModRow *spatial=SGOptionRow(@"Spatial Trace", @"Event decisions and applied effects", kSpatialTrace); spatial.changed=^(BOOL on){setDiagnosticLevel();};
    SGModRow *deterministic=SGOptionRow(@"Deterministic Test Mode", @"Repeatable event IDs and motion choices for offline replay", kDeterministic);
    SGModRow *record=SGActionRow(@"Start / stop diagnostics", nil, ^{ NSDictionary *s=nil; ASDiagnosticsToggleFn start=(ASDiagnosticsToggleFn)asSymbol("AISpatialDiagnosticsStart"); ASDiagnosticsToggleFn stop=(ASDiagnosticsToggleFn)asSymbol("AISpatialDiagnosticsStop"); ASStatusFn statusFn=(ASStatusFn)asSymbol("AISpatialDiagnosticsStatusSnapshot"); s=statusFn?statusFn():@{}; if([s[@"recording"] boolValue]){if(stop)stop();}else{if(start)start();} });
    SGModRow *export=SGActionRow(@"Export diagnostics", @"JSONL, summary, CSV and diagnostics log", ^{ASDiagnosticsExportFn fn=(ASDiagnosticsExportFn)asSymbol("AISpatialDiagnosticsExport"); if(fn)fn([NSUserDefaults.standardUserDefaults boolForKey:kFullTrace], ^(NSArray *files,NSError *error){dispatch_async(dispatch_get_main_queue(),^{showFiles(files,error);});});});
    SGModRow *accentSummary=SGStatRow(@"Accent queue", ^NSString *{NSDictionary *s=accentStatus(); return s.count?[NSString stringWithFormat:@"%@ selected · %@ ms avg",s[@"selected"],s[@"processing_avg_ms"]]:@"Unavailable";});
    SGModRow *dsp=SGStatRow(@"JamesDSP", ^NSString *{return SGDSPSummary();});
    SGModRow *dspPage=SGPageRow(@"JamesDSP controls", ^UIViewController *{return SGDSPSettingsPage();});
    return [[SGModPage alloc] initWithTitle:@"AI Spatial Engine" intro:@"One control surface for Separator, Accent Detector, Spatial Engine, route profiles, JamesDSP status and diagnostics. Original is the safe default; spatial localization varies with the output device." sections:@[
        SGSection(@"Status", @[SGWithSymbol(status,@"waveform.path.ecg"),backend,profile,warning]),
        SGSection(@"Engine", @[engine,mode,intensity,width,depth,variety,accentMotion,stereoWidth,depthEnabled,reflections,hrtf,active,center,bass,anti]),
        SGSection(@"Audio Route", @[routeAuto,route,profile]),
        SGSection(@"AI Processing", @[separator,accent,rate,accentSummary,model]),
        SGSection(@"JamesDSP", @[dsp,dspPage]),
        SGSection(@"Presets", presetRows),
        SGSection(@"Diagnostics", @[full,spatial,deterministic,record,export]),
    ] footer:@"Spatial events are selective accents. Two stems cannot guarantee independent lead and adlib separation; failures return to synchronized Original PCM."];
}
