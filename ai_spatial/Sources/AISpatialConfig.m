#import "AISpatialConfig.h"

NSString *const ASConfigEngineEnabled = @"spotifyglass.ai-spatial.engine-enabled";
NSString *const ASConfigMode = @"spotifyglass.ai-spatial.mode";
#if AS_SPATIAL_BUILD_PHASE >= 6
NSString *const ASConfigBackendMode = @"spotifyglass.ai-spatial.separator-mode";
#else
NSString *const ASConfigBackendMode = @"pw.chroma.ai-spatial.live-mode";
#endif
NSString *const ASConfigIntensity = @"spotifyglass.ai-spatial.intensity";
NSString *const ASConfigWidth = @"spotifyglass.ai-spatial.width";
NSString *const ASConfigDepth = @"spotifyglass.ai-spatial.depth";
NSString *const ASConfigAccentRate = @"spotifyglass.ai-spatial.accent-rate";
NSString *const ASConfigMaxActiveSources = @"spotifyglass.ai-spatial.max-active-sources";
NSString *const ASConfigCenterProtection = @"spotifyglass.ai-spatial.center-protection";
NSString *const ASConfigBassProtection = @"spotifyglass.ai-spatial.bass-protection";
NSString *const ASConfigAntiPhaseLimit = @"spotifyglass.ai-spatial.anti-phase-limit";
NSString *const ASConfigRoute = @"spotifyglass.ai-spatial.route";
NSString *const ASConfigRouteAuto = @"spotifyglass.ai-spatial.route-auto";
NSString *const ASConfigProfile = @"spotifyglass.ai-spatial.profile";
NSString *const ASConfigDiagnosticsLevel = @"spotifyglass.ai-spatial.diagnostics-level";

static void __attribute__((unused)) migrate(NSString *from, NSString *to) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults objectForKey:to] && [defaults objectForKey:from]) {
        [defaults setObject:[defaults objectForKey:from] forKey:to];
    }
}

void ASConfigMigrateAndRegister(void) {
#if AS_SPATIAL_BUILD_PHASE >= 6
    migrate(@"pw.chroma.ai-spatial.enabled", ASConfigEngineEnabled);
    migrate(@"pw.chroma.ai-spatial.live-mode", ASConfigBackendMode);
    migrate(@"pw.chroma.ai-spatial.accent-enabled", @"spotifyglass.ai-spatial.accent-enabled");
    migrate(@"pw.chroma.ai-spatial.route", ASConfigRoute);
    migrate(@"pw.chroma.ai-spatial.profile", ASConfigProfile);
#endif
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        ASConfigEngineEnabled: @NO, ASConfigMode: @0, ASConfigIntensity: @0.55,
        ASConfigWidth: @0.65, ASConfigDepth: @0.40, ASConfigAccentRate: @10,
        ASConfigMaxActiveSources: @3, ASConfigCenterProtection: @0.75,
        ASConfigBassProtection: @0.70, ASConfigAntiPhaseLimit: @0.08,
        ASConfigRoute: @2, ASConfigRouteAuto: @YES, ASConfigProfile: @5, ASConfigDiagnosticsLevel: @0,
        @"spotifyglass.ai-spatial.accent-enabled": @YES
    }];
}

__attribute__((constructor)) static void ASConfigInitialize(void) { ASConfigMigrateAndRegister(); }
