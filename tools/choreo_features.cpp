// Feature export for training the learned beat detector.
// Usage: choreo-features in.wav out.bin [--speed S] [--gain dB]
//   --speed S  play the audio S times faster before extracting (tempo + pitch change, like a
//              turntable); annotation times must be divided by S
//   --gain dB  scale the audio level (robustness to loudness)
// Output: int32 frames, int32 dim, float32 centreOffsetSeconds, then frames*dim float32.
#include "Wav.h"
#include "analysis/Features.h"
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

int main(int argc, char** argv) {
    if (argc < 3) { std::fprintf(stderr, "usage: %s in.wav out.bin [--speed S] [--gain dB]\n", argv[0]); return 1; }
    double speed = 1.0, gainDb = 0.0;
    for (int i = 3; i < argc; ++i) {
        if (!std::strcmp(argv[i], "--speed") && i + 1 < argc) speed = std::atof(argv[++i]);
        else if (!std::strcmp(argv[i], "--gain") && i + 1 < argc) gainDb = std::atof(argv[++i]);
    }
    std::vector<float> x; double sr = 0;
    if (!choreo::loadAudioMono(argv[1], x, sr)) { std::fprintf(stderr, "cannot read %s\n", argv[1]); return 1; }

    // Speed change by Catmull-Rom resampling: output sample j reads input position j * speed.
    if (std::fabs(speed - 1.0) > 1e-6) {
        size_t n = size_t((x.size() - 3) / speed);
        std::vector<float> y(n);
        for (size_t j = 0; j < n; ++j) {
            double p = j * speed;
            size_t i = size_t(p);
            float t = float(p - i);
            float p0 = x[i ? i - 1 : 0], p1 = x[i], p2 = x[i + 1], p3 = x[i + 2];
            y[j] = p1 + 0.5f * t * (p2 - p0 + t * (2 * p0 - 5 * p1 + 4 * p2 - p3 + t * (3 * (p1 - p2) + p3 - p0)));
        }
        x.swap(y);
    }
    const float g = float(std::pow(10.0, gainDb / 20.0));
    for (float& v : x) v *= g;

    choreo::MelFeatures fx(sr);
    std::vector<float> out;
    fx.process(x.data(), x.size(), [&](const float* f) { out.insert(out.end(), f, f + choreo::MelFeatures::kDim); });

    std::FILE* f = std::fopen(argv[2], "wb");
    if (!f) return 1;
    int32_t frames = int32_t(out.size() / choreo::MelFeatures::kDim), dim = choreo::MelFeatures::kDim;
    float off = float(fx.centreOffset());
    std::fwrite(&frames, 4, 1, f); std::fwrite(&dim, 4, 1, f); std::fwrite(&off, 4, 1, f);
    std::fwrite(out.data(), 4, out.size(), f);
    std::fclose(f);
    return 0;
}
