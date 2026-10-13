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
    bool reflection_enabled;
    bool hrtf_enabled;
} ASSpatialRenderConfig;

typedef struct {
    float history_left[8];
    float history_right[8];
    unsigned cursor;
} ASSpatialHRTFState;

void ASSpatialRenderConfigDefault(ASSpatialRenderConfig *config, ASSpatialRoute route);
void ASSpatialRenderStereo(const ASSpatialRenderConfig *config, ASSpatialPosition position,
                           float source_left, float source_right, float effect_gain,
                           float *left, float *right);
void ASSpatialRenderHeadphones(const ASSpatialRenderConfig *config, ASSpatialPosition position,
                               float source_left, float source_right, float effect_gain,
                               float *left, float *right);
void ASSpatialRenderSpeakers(const ASSpatialRenderConfig *config, ASSpatialPosition position,
                             float source_left, float source_right, float effect_gain,
                             float *left, float *right);
void ASSpatialRenderUniversalStereo(const ASSpatialRenderConfig *config, ASSpatialPosition position,
                                    float source_left, float source_right, float effect_gain,
                                    float *left, float *right);
void ASSpatialRenderMonoSafe(const ASSpatialRenderConfig *config, ASSpatialPosition position,
                             float source_left, float source_right, float effect_gain,
                             float *left, float *right);
void ASSpatialHRTFReset(ASSpatialHRTFState *state);
void ASSpatialHRTFProcess(ASSpatialHRTFState *state, float source_left, float source_right,
                          float azimuth, float distance, float gain,
                          float *left, float *right);

#endif
