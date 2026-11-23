#include "TetoDSP.h"

#include <algorithm>
#include <array>
#include <cmath>

namespace {

int32_t EstimatePeriod(const float* samples, int32_t length, int32_t sampleRate) {
    const int32_t shortest = std::max<int32_t>(12, sampleRate / 500);
    const int32_t window = std::min<int32_t>(length, 8192);
    const int32_t longest = std::min({int32_t{2048}, sampleRate / 65, (window - 1) / 2});
    if (longest <= shortest) {
        return 0;
    }

    const float* middle = samples + (length - window) / 2;
    std::array<float, 2049> scores{};
    int32_t strongest = shortest;
    for (int32_t lag = shortest; lag <= longest; ++lag) {
        float product = 0;
        float leftEnergy = 0;
        float rightEnergy = 0;
        for (int32_t i = 0; i < window - lag; ++i) {
            const float left = middle[i];
            const float right = middle[i + lag];
            product += left * right;
            leftEnergy += left * left;
            rightEnergy += right * right;
        }
        scores[lag] = product / (std::sqrt(leftEnergy * rightEnergy) + 1e-12f);
        if (scores[lag] > scores[strongest]) {
            strongest = lag;
        }
    }

    if (scores[strongest] < 0.62f) {
        return 0;
    }

    // Strong near-matches after the first cycle often occur at octave multiples.
    const float threshold = scores[strongest] - 0.035f;
    for (int32_t lag = shortest + 1; lag < strongest; ++lag) {
        if (scores[lag] >= threshold && scores[lag] >= scores[lag - 1] &&
            scores[lag] > scores[lag + 1]) {
            return lag;
        }
    }
    return strongest;
}

float Interpolate(const float* samples, int32_t length, float position, bool loop) {
    const int32_t left = std::min(static_cast<int32_t>(position), length - 1);
    const int32_t right = left + 1 < length ? left + 1 : (loop ? 0 : left);
    return samples[left] + (samples[right] - samples[left]) * (position - left);
}

} // namespace

extern "C" int32_t teto_render_note(const float* source, int32_t sourceFrames,
    int32_t sampleRate, int32_t fixedFrames, float targetHz,
    float* output, int32_t outputFrames) {
    if (!source || !output || sourceFrames <= 0 || outputFrames <= 0 ||
        sampleRate < 8000 || sampleRate > 192000 || !std::isfinite(targetHz) || targetHz <= 0) {
        return 1;
    }

    const int32_t prefix = std::clamp(fixedFrames, int32_t{0}, std::min(sourceFrames, outputFrames));
    std::copy_n(source, prefix, output);
    const int32_t sustainFrames = outputFrames - prefix;
    const int32_t vowelFrames = sourceFrames - prefix;
    if (sustainFrames > 0) {
        const float* vowel = source + prefix;
        float* sustain = output + prefix;
        const int32_t sourcePeriod = EstimatePeriod(vowel, vowelFrames, sampleRate);
        if (sourcePeriod > 0) {
            const float boundedHz = std::clamp(targetHz, 45.0f, sampleRate * 0.42f);
            const int32_t targetPeriod = static_cast<int32_t>(std::lround(sampleRate / boundedHz));
            // Loop one steady voiced cycle to hold the target pitch across the note.
            const float* cycle = vowel + (vowelFrames - sourcePeriod) / 2;
            for (int32_t i = 0; i < sustainFrames; ++i) {
                const float phase = static_cast<float>(i % targetPeriod) / targetPeriod;
                sustain[i] = Interpolate(cycle, sourcePeriod, phase * sourcePeriod, true);
            }
        } else if (vowelFrames > 0) {
            const float step = static_cast<float>(vowelFrames - 1) / std::max(sustainFrames - 1, 1);
            for (int32_t i = 0; i < sustainFrames; ++i) {
                sustain[i] = Interpolate(vowel, vowelFrames, i * step, false);
            }
        } else {
            std::fill_n(sustain, sustainFrames, 0.0f);
        }

        const int32_t seam = std::min({sampleRate / 200, sustainFrames, prefix});
        for (int32_t i = 0; i < seam; ++i) {
            const float mix = static_cast<float>(i + 1) / (seam + 1);
            sustain[i] = sustain[i] * mix + output[prefix - seam + i] * (1 - mix);
        }
    }

    const int32_t tail = std::min(sampleRate / 150, outputFrames);
    for (int32_t i = 0; i < tail; ++i) {
        output[outputFrames - tail + i] *= static_cast<float>(tail - i - 1) / tail;
    }
    return 0;
}

namespace {

class PitchEnvelope {
public:
    PitchEnvelope(const TetoPitchPoint* points, int32_t count, int32_t sampleRate)
        : points_(points), count_(count), sampleRate_(sampleRate) {}

    void advanceTo(int32_t frame) {
        while (position_ < frame) {
            const auto& left = points_[index_];
            const double low = std::clamp<double>(left.hz, 8, sampleRate_ * 0.42);
            int32_t end = frame;
            double slope = 0;
            if (index_ + 1 < count_) {
                const auto& right = points_[index_ + 1];
                end = std::min(frame, right.frame);
                const double high = std::clamp<double>(right.hz, 8, sampleRate_ * 0.42);
                slope = (high - low) / (right.frame - left.frame);
            }
            const double length = end - position_;
            const double initial = low + slope * (position_ - left.frame);
            phase_ += (initial * length + slope * length * (length - 1) / 2) / sampleRate_;
            phase_ -= std::floor(phase_);
            position_ = end;
            if (index_ + 1 < count_ && end == points_[index_ + 1].frame) { ++index_; }
        }
    }

    float phase() const { return static_cast<float>(phase_); }

private:
    const TetoPitchPoint* points_;
    int32_t count_;
    int32_t sampleRate_;
    int32_t index_ = 0;
    int32_t position_ = 0;
    double phase_ = 0;
};

} // namespace

extern "C" int32_t teto_note_period(const float* source, int32_t sourceFrames, int32_t sampleRate, int32_t fixedFrames) {
    if (!source || fixedFrames < 0 || fixedFrames >= sourceFrames || sampleRate < 8000 || sampleRate > 192000) { return 0; }
    return EstimatePeriod(source + fixedFrames, sourceFrames - fixedFrames, sampleRate);
}

extern "C" int32_t teto_mix_note_curve(const float* source, int32_t sourceFrames, int32_t sampleRate,
    int32_t fixedFrames, int32_t sourcePeriod, const TetoPitchPoint* points, int32_t pointCount,
    int32_t noteFrames, int32_t cropStart, float gain, float* mix, int32_t mixFrames) {
    if (!source || !mix || !points || pointCount < 1 || points[0].frame != 0 ||
        sampleRate < 8000 || sampleRate > 192000 || sourceFrames <= 0 || noteFrames <= 0 ||
        fixedFrames < 0 || fixedFrames > std::min(sourceFrames, noteFrames) ||
        sourcePeriod < 0 || sourcePeriod > sourceFrames - fixedFrames ||
        cropStart < 0 || cropStart >= noteFrames || mixFrames <= 0 || mixFrames > noteFrames - cropStart ||
        !std::isfinite(gain)) {
        return 1;
    }
    for (int32_t i = 0; i < pointCount; ++i) {
        if (!std::isfinite(points[i].hz) || points[i].hz <= 0 || points[i].frame >= noteFrames ||
            (i > 0 && points[i].frame <= points[i - 1].frame)) { return 1; }
    }

    const int32_t vowelFrames = sourceFrames - fixedFrames;
    const int32_t sustainFrames = noteFrames - fixedFrames;
    const int32_t seam = std::min({sampleRate / 200, sustainFrames, fixedFrames});
    const int32_t onset = sampleRate / 500;
    const int32_t tail = std::min(sampleRate / 150, noteFrames);
    const float* vowel = source + fixedFrames;
    const float* cycle = vowel + (vowelFrames - sourcePeriod) / 2;
    const float unvoicedStep = static_cast<float>(std::max(0, vowelFrames - 1)) / std::max(1, sustainFrames - 1);
    PitchEnvelope pitch(points, pointCount, sampleRate);

    for (int32_t i = 0; i < mixFrames; ++i) {
        const int32_t frame = cropStart + i;
        float value = 0;
        if (frame < fixedFrames) {
            value = source[frame];
        } else {
            const int32_t position = frame - fixedFrames;
            if (sourcePeriod > 0) {
                pitch.advanceTo(frame);
                value = Interpolate(cycle, sourcePeriod, pitch.phase() * sourcePeriod, true);
            } else if (vowelFrames > 0) {
                value = Interpolate(vowel, vowelFrames, std::min<float>(vowelFrames - 1, position * unvoicedStep), false);
            }
            if (position < seam) {
                const float blend = static_cast<float>(position + 1) / (seam + 1);
                value = value * blend + source[fixedFrames - seam + position] * (1 - blend);
            }
        }
        const float fadeIn = std::min(1.0f, static_cast<float>(frame) / onset);
        const float fadeOut = std::min(1.0f, static_cast<float>(noteFrames - frame - 1) / tail);
        mix[i] += value * gain * fadeIn * fadeOut;
    }
    return 0;
}
