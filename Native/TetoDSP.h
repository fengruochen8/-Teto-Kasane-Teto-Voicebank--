#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Renders one mono UTAU-style sample. The fixed prefix is copied as a
// consonant, while the remaining vowel is pitch-shifted and extended or
// shortened to fill the caller supplied output buffer.
//
// Returns zero on success. A nonzero value means that a required argument is
// invalid.
int32_t teto_render_note(const float* source, int32_t sourceFrames,
    int32_t sampleRate, int32_t fixedFrames, float targetHz,
    float* output, int32_t outputFrames);

typedef struct TetoPitchPoint {
    int32_t frame;
    float hz;
} TetoPitchPoint;

// Analyze a cropped recording once for every consonant length used with it.
int32_t teto_note_period(const float* source, int32_t sourceFrames, int32_t sampleRate, int32_t fixedFrames);

// Add a possibly cropped portion of one rendered syllable to the destination.
// Pitch points use frame offsets from the start of the complete syllable.
int32_t teto_mix_note_curve(const float* source, int32_t sourceFrames, int32_t sampleRate,
    int32_t fixedFrames, int32_t sourcePeriod, const TetoPitchPoint* points, int32_t pointCount,
    int32_t noteFrames, int32_t cropStart, float gain, float* mix, int32_t mixFrames);

#ifdef __cplusplus
}
#endif
