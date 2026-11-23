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

#ifdef __cplusplus
}
#endif
