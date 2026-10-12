#ifndef AI_SPATIAL_CONFIG_H
#define AI_SPATIAL_CONFIG_H

#import <Foundation/Foundation.h>
#include "AISpatialBuild.h"

FOUNDATION_EXPORT NSString *const ASConfigEngineEnabled;
FOUNDATION_EXPORT NSString *const ASConfigMode;
FOUNDATION_EXPORT NSString *const ASConfigBackendMode;
FOUNDATION_EXPORT NSString *const ASConfigIntensity;
FOUNDATION_EXPORT NSString *const ASConfigWidth;
FOUNDATION_EXPORT NSString *const ASConfigDepth;
FOUNDATION_EXPORT NSString *const ASConfigAccentRate;
FOUNDATION_EXPORT NSString *const ASConfigMaxActiveSources;
FOUNDATION_EXPORT NSString *const ASConfigCenterProtection;
FOUNDATION_EXPORT NSString *const ASConfigBassProtection;
FOUNDATION_EXPORT NSString *const ASConfigAntiPhaseLimit;
FOUNDATION_EXPORT NSString *const ASConfigRoute;
FOUNDATION_EXPORT NSString *const ASConfigRouteAuto;
FOUNDATION_EXPORT NSString *const ASConfigProfile;
FOUNDATION_EXPORT NSString *const ASConfigDiagnosticsLevel;

void ASConfigMigrateAndRegister(void);

#endif
