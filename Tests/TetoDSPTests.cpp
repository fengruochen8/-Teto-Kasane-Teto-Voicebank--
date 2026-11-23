#include "TetoDSP.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <iostream>
#include <vector>

namespace {

constexpr int kSampleRate = 44'100;
constexpr double kPi = 3.14159265358979323846;

double ToneEnergy(const std::vector<float>& audio, double frequency) {
    double inPhase = 0;
    double quadrature = 0;
    const double step = 2 * kPi * frequency / kSampleRate;
    for (size_t i = kSampleRate / 10; i < audio.size() - kSampleRate / 10; ++i) {
        inPhase += audio[i] * std::cos(i * step);
        quadrature += audio[i] * std::sin(i * step);
    }
    return inPhase * inPhase + quadrature * quadrature;
}

void TestPitchChange() {
    std::vector<float> source(kSampleRate / 3);
    for (size_t i = 0; i < source.size(); ++i) {
        source[i] = 0.35f * std::sin(2 * kPi * 220 * i / kSampleRate);
    }
    constexpr int attack = 117;
    constexpr float target = 440;
    std::vector<float> output(kSampleRate * 2 / 3);
    const auto status = teto_render_note(source.data(), static_cast<int32_t>(source.size()),
        kSampleRate, attack, target, output.data(), static_cast<int32_t>(output.size()));
    assert(status == 0);
    assert(std::equal(source.begin(), source.begin() + attack, output.begin()));
    const double actual = static_cast<double>(kSampleRate) / std::lround(kSampleRate / target);
    assert(ToneEnergy(output, actual) > 16 * ToneEnergy(output, 220));
    assert(ToneEnergy(output, actual) > 1000);
}

void TestShortRecordings() {
    for (const int frames : {8, 9, 32, 64, 255}) {
        std::vector<float> source(frames);
        for (int i = 0; i < frames; ++i) {
            source[i] = 0.14f * std::sin(2 * kPi * 260 * i / kSampleRate);
        }
        for (const int attack : {0, frames / 2, frames - 1, frames}) {
            std::vector<float> output(901);
            const auto status = teto_render_note(source.data(), frames, kSampleRate,
                attack, 523.25f, output.data(), static_cast<int32_t>(output.size()));
            assert(status == 0);
            assert(std::all_of(output.begin(), output.end(), [](float x) { return std::isfinite(x); }));
        }
    }
}

void TestPitchCurveAndRegionRendering() {
    std::vector<float> source(kSampleRate / 3);
    for (size_t i = 0; i < source.size(); ++i) {
        source[i] = 0.35f * std::sin(2 * kPi * 220 * i / kSampleRate);
    }
    constexpr int attack = 117;
    const int32_t period = teto_note_period(source.data(), static_cast<int32_t>(source.size()), kSampleRate, attack);
    assert(period > 0);
    constexpr int duration = 2 * kSampleRate;
    const TetoPitchPoint points[] = {{0, 330}, {kSampleRate * 7 / 10, 330}, {kSampleRate * 12 / 10, 440}};
    std::vector<float> full(duration);
    const auto render = [&](int start, std::vector<float>& buffer) {
        return teto_mix_note_curve(source.data(), static_cast<int32_t>(source.size()), kSampleRate, attack, period,
            points, 3, duration, start, 0.75f, buffer.data(), static_cast<int32_t>(buffer.size()));
    };
    assert(render(0, full) == 0);
    const std::vector<float> early(full.begin(), full.begin() + kSampleRate * 7 / 10);
    const std::vector<float> late(full.begin() + kSampleRate * 13 / 10, full.end());
    assert(ToneEnergy(early, 330) > 20 * ToneEnergy(early, 440));
    assert(ToneEnergy(late, 440) > 20 * ToneEnergy(late, 330));

    constexpr int cropStart = kSampleRate * 9 / 10;
    std::vector<float> region(kSampleRate / 2, 0.125f);
    assert(render(cropStart, region) == 0);
    for (size_t i = 0; i < region.size(); ++i) {
        assert(std::abs(region[i] - (full[cropStart + i] + 0.125f)) < 1e-5f);
    }
    assert(render(duration, region) != 0);
}

} // namespace

int main() {
    TestPitchChange();
    TestShortRecordings();
    TestPitchCurveAndRegionRendering();
    std::cout << "DSP pitch, short-recording, curve and crop tests passed.\n";
}
