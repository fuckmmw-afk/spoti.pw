#ifndef AI_SPATIAL_EVENT_EXTRACTION_H
#define AI_SPATIAL_EVENT_EXTRACTION_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* The extractor is deliberately independent of Core ML.  It is the small,
 * deterministic gate between an Accent event and the stem mixer.  A stem is
 * never copied as a rectangular block: every selected sample has a raised
 * cosine envelope and overlapping events are arbitrated by priority. */
typedef struct {
    uint64_t event_id;
    uint64_t stream_epoch;
    uint64_t start_sample;
    uint64_t end_sample;
    uint8_t source;             /* vocal = 0, instrumental = 1 */
    float priority;
    float intensity;
    float attack_seconds;
    float release_seconds;
    float tail_seconds;
    bool selected;
} ASExtractEvent;

typedef struct {
    uint64_t sample;
    uint64_t event_id;
    float weight;
    float priority;
} ASExtractWinner;

float ASExtractEnvelope(uint64_t sample, const ASExtractEvent *event,
                        double sample_rate);
bool ASExtractValidate(const ASExtractEvent *event, double sample_rate,
                       uint64_t current_epoch, uint64_t output_cursor);
size_t ASExtractChooseWinners(const ASExtractEvent *events, size_t count,
                              uint64_t sample, uint8_t source,
                              double sample_rate, ASExtractWinner *winner,
                              size_t capacity);
void ASExtractForeground(const float *input_left, const float *input_right,
                         float *output_left, float *output_right, size_t frames,
                         uint64_t start_sample, const ASExtractEvent *event,
                         double sample_rate);

#endif
