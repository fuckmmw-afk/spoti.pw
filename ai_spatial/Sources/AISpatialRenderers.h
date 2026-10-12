#ifndef AI_SPATIAL_RENDERERS_H
#define AI_SPATIAL_RENDERERS_H

#include "AISpatialScene.h"

typedef enum {
    ASSpatialRouteHeadphones = 0,
    ASSpatialRouteSpeakers,
    ASSpatialRouteUniversalStereo,
    ASSpatialRouteMonoSafe,
} ASSpatialRoute;

typedef struct {
    ASSpatialRoute route;
    float intensity;
    float width;
    float depth;
    float center_protection;
    float bass_protection;
    float anti_phase_limit;
    float reflection_gain;
} ASSpatialRenderConfig;

void ASSpatialRenderConfigDefault(ASSpatialRenderConfig *config, ASSpatialRoute route);
void ASSpatialRenderStereo(const ASSpatialRenderConfig *config, ASSpatialPosition position,
                           float source_left, float source_right, float effect_gain,
                           float *left, float *right);

#endif
