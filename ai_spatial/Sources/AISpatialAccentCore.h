#ifndef AI_SPATIAL_ACCENT_CORE_H
#define AI_SPATIAL_ACCENT_CORE_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

typedef enum {
    ASAccentSourceVocal = 0,
    ASAccentSourceInstrumental = 1,
} ASAccentSource;

typedef enum {
    ASAccentVocalPhraseStart = 0,
    ASAccentVocalAttack,
    ASAccentVocalSyllableEnding,
    ASAccentVocalShout,
    ASAccentVocalAdlib,
    ASAccentVocalPauseContrast,
    ASAccentInstrumentalAttack,
    ASAccentInstrumentalSynthInsert,
    ASAccentInstrumentalPercussionContrast,
    ASAccentInstrumentalSoundEffect,
    ASAccentInstrumentalPauseTexture,
} ASAccentType;

typedef struct {
    uint64_t sample;
    float rms;
    float peak;
    float flux;
    float high_frequency;
} ASAccentFrame;

typedef struct {
    uint64_t start_sample;
    uint64_t end_sample;
    uint8_t source;
    uint8_t type;
    float confidence;
    float expressiveness;
    float priority;
    bool selected;
    char reason[96];
} ASAccentCoreEvent;

typedef struct {
    uint64_t last_selected_sample;
    uint64_t previous_selected_sample;
    float previous_selected_score;
    uint64_t repeat_interval;
    unsigned repeat_count;
    uint64_t density_window_start;
    unsigned density_count;
    uint64_t density_samples[10];
    bool has_selected;
    float previous_rms;
    bool has_previous;
} ASAccentCoreContext;

void ASAccentCoreReset(ASAccentCoreContext *context);
size_t ASAccentCoreAnalyze(const ASAccentFrame *frames, size_t count,
                           double sample_rate, uint32_t hop_samples,
                           ASAccentSource source, uint64_t available_sample,
                           uint64_t latency_samples, ASAccentCoreContext *context,
                           ASAccentCoreEvent *events, size_t capacity);

const char *ASAccentTypeName(ASAccentType type);

#endif
