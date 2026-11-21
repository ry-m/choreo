#include "analysis/Features.h"
#include <algorithm>
#include <cmath>

namespace choreo {

namespace {
int windowFor(double sr) { return sr >= 32000 ? 2048 : 1024; }
double hzToMel(double hz) { return 2595.0 * std::log10(1.0 + hz / 700.0); }
double melToHz(double m) { return 700.0 * (std::pow(10.0, m / 2595.0) - 1.0); }
} // namespace

MelFeatures::MelFeatures(double sampleRate)
    : sr_(sampleRate), window_(windowFor(sampleRate)), fft_(windowFor(sampleRate)),
      hann_(window_), mag_(window_ / 2 + 1), mel_(kBands), prevLog_(kBands, 0.f), out_(kDim), tmp_(window_),
      filters_(kBands) {
    for (int i = 0; i < window_; ++i) hann_[i] = 0.5f - 0.5f * std::cos(2.0 * M_PI * i / window_);
    // Triangular mel filters (HTK scale), normalised to unit area so band levels don't depend
    // on bandwidth or FFT size (keeps 22.05 kHz and 44.1 kHz audio comparable).
    const double lo = hzToMel(30.0), hi = hzToMel(11000.0);
    std::vector<double> edges(kBands + 2);
    for (int b = 0; b < kBands + 2; ++b) edges[b] = melToHz(lo + (hi - lo) * b / (kBands + 1));
    const double binHz = sr_ / window_;
    for (int b = 0; b < kBands; ++b) {
        double f0 = edges[b], f1 = edges[b + 1], f2 = edges[b + 2];
        double area = 0;
        std::vector<std::pair<int, float>> f;
        for (int k = 1; k <= window_ / 2; ++k) {
            double hz = k * binHz, w = 0;
            if (hz > f0 && hz < f1) w = (hz - f0) / (f1 - f0);
            else if (hz >= f1 && hz < f2) w = (f2 - hz) / (f2 - f1);
            if (w > 0) { f.push_back({k, float(w)}); area += w; }
        }
        if (f.empty()) { // narrower than one bin at low frequencies: use the nearest bin
            int k = std::max(1, int(std::lround(f1 / binHz)));
            f.push_back({k, 1.f});
            area = 1;
        }
        for (auto& p : f) p.second = float(p.second / area);
        filters_[b] = std::move(f);
    }
}

void MelFeatures::process(const float* x, size_t n, const std::function<void(const float*)>& onFrame) {
    buf_.insert(buf_.end(), x, x + n);
    const float norm = 2.f / (window_ * 0.5f); // full-scale sine -> magnitude ~1
    for (;;) {
        long long start = std::llround(frame_ * sr_ / kFps);
        if (start - bufStart_ + window_ > (long long)buf_.size()) break;
        const float* w = buf_.data() + (start - bufStart_);
        for (int i = 0; i < window_; ++i) tmp_[i] = w[i] * hann_[i];
        fft_.magnitudes(tmp_.data(), mag_.data());
        for (int b = 0; b < kBands; ++b) {
            float m = 0;
            for (auto& p : filters_[b]) m += mag_[p.first] * p.second;
            float l = std::log1p(1000.f * m * norm);
            out_[b] = l;
            out_[kBands + b] = first_ ? 0.f : std::max(0.f, l - prevLog_[b]);
            prevLog_[b] = l;
        }
        first_ = false;
        onFrame(out_.data());
        ++frame_;
        // Drop samples no future frame needs.
        long long nextStart = std::llround(frame_ * sr_ / kFps);
        long long drop = nextStart - bufStart_;
        if (drop > 4096) {
            buf_.erase(buf_.begin(), buf_.begin() + drop);
            bufStart_ += drop;
        }
    }
}

} // namespace choreo
