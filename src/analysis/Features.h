#pragma once
#include "analysis/FFT.h"
#include <functional>
#include <vector>

namespace choreo {

// Spectral features for the learned beat detector. The SAME code produces training data
// (tools/choreo_features) and runtime input, so the network always sees identical features.
//
// - 100 frames per second at any sample rate (fractional hop of sr/100 samples)
// - ~46 ms Hann window (2048 samples at 44.1/48 kHz, 1024 at 22.05 kHz)
// - 64 mel bands, 30 Hz - 11 kHz (GTZAN audio is 22.05 kHz, so nothing above Nyquist)
// - per frame: log-compressed mel magnitudes, then their positive frame-to-frame change
//   => kDim = 128 values per frame
// Frame k covers samples [round(k*sr/100), +window); its centre is at k/100 + window/(2 sr) s.
class MelFeatures {
public:
    static constexpr int kBands = 64;
    static constexpr int kDim = 2 * kBands;
    static constexpr double kFps = 100.0;

    explicit MelFeatures(double sampleRate);

    // Feed samples; calls onFrame(features) for every completed frame (kDim floats).
    void process(const float* x, size_t n, const std::function<void(const float*)>& onFrame);

    // Seconds from a frame's start index (k/100) to its centre: frame time = k/100 + this.
    double centreOffset() const { return window_ / (2.0 * sr_); }
    long framesProduced() const { return frame_; }

private:
    double sr_;
    int window_;
    FFT fft_;
    std::vector<float> hann_, mag_, mel_, prevLog_, out_, tmp_;
    std::vector<std::vector<std::pair<int, float>>> filters_; // per band: (bin, weight)
    std::vector<float> buf_;     // pending input samples
    long long bufStart_ = 0;     // absolute index of buf_[0]
    long frame_ = 0;
    bool first_ = true;
};

} // namespace choreo
