#ifndef AI_SPATIAL_SCENE_H
#define AI_SPATIAL_SCENE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define AS_SPATIAL_MAX_SCENE_SOURCES 8u

typedef enum {
    ASSpatialStemVocal = 0,
    ASSpatialStemInstrumental = 1,
} ASSpatialStem;

typedef enum {
    ASSpatialMotionFlyby = 0,
    ASSpatialMotionArc,
    ASSpatialMotionDepth,
    ASSpatialMotionBloom,
    ASSpatialMotionSubtleShift,
    ASSpatialMotionReflection,
} ASSpatialMotionType;

typedef struct {
    float x; /* left/right, -1…1 */
    float y; /* front/back, -1 front */
    float z; /* height, -1…1 */
} ASSpatialPosition;

typedef struct {
    ASSpatialMotionType type;
    float intensity;
    float direction;
    float duration_seconds;
    float tail_seconds;
    /* Optional authored endpoints.  When has_positions is false the motion
     * uses the source position and the type-specific gesture below. */
    ASSpatialPosition start_position;
    ASSpatialPosition end_position;
    bool has_positions;
} ASSpatialMotion;

typedef struct {
    uint64_t source_id;
    ASSpatialStem stem;
    ASSpatialPosition position;
    float distance;
    float size;
    float gain;
} ASSpatialSource;

typedef struct {
    uint64_t event_id;
    uint64_t stream_epoch;
    uint64_t start_sample;
    uint64_t end_sample;
    ASSpatialStem stem;
    float priority;
    float intensity;
    ASSpatialMotion motion;
    bool selected;
} ASSpatialEventPlan;

typedef struct {
    double sample_rate;
    uint64_t next_source_id;
    size_t source_count;
    ASSpatialSource sources[AS_SPATIAL_MAX_SCENE_SOURCES];
} ASSpatialScene;

void ASSpatialSceneInit(ASSpatialScene *scene, double sample_rate);
bool ASSpatialSceneAddSource(ASSpatialScene *scene, ASSpatialStem stem,
                             ASSpatialPosition position, float distance,
                             float size, float gain, uint64_t *source_id);
bool ASSpatialScenePlanEvent(const ASSpatialScene *scene, const ASSpatialEventPlan *event,
                             ASSpatialEventPlan *planned);
ASSpatialPosition ASSpatialMotionPosition(const ASSpatialSource *source,
                                          const ASSpatialMotion *motion,
                                          double seconds);
float ASSpatialMotionDuration(const ASSpatialMotion *motion, float event_duration,
                              float max_tail_seconds);
float ASSpatialEnvelope(double seconds, float duration_seconds, float fade_seconds,
                        float intensity);

#endif
