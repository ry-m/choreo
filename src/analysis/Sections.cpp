#include "analysis/Sections.h"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>

namespace choreo {

namespace {
constexpr int kEmaBeats = 32;
constexpr int kRepBars[4] = {1, 2, 4, 8};
inline float sigmoid(float v) { return 1.f / (1.f + std::exp(-v)); }
} // namespace

bool SectionDetector::load(const std::string& path) {
    std::FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) return false;
    int32_t hdr[5];
    bool ok = std::fread(hdr, 4, 5, f) == 5 && hdr[0] == 0x53454354 && hdr[1] == 1 && hdr[2] == kIn;
    if (ok) {
        H_ = hdr[3]; N_ = hdr[4];
        std::vector<int32_t> d(N_ / 2);
        ok = std::fread(d.data(), 4, d.size(), f) == d.size();
        delays_.assign(d.begin(), d.end());
        thr_.resize(N_);
        ok = ok && std::fread(thr_.data(), 4, N_, f) == size_t(N_);
        auto rd = [&](std::vector<float>& v, size_t n) { v.resize(n); return std::fread(v.data(), 4, n, f) == n; };
        ok = ok && rd(inW_, size_t(H_) * kIn) && rd(inB_, H_) && rd(wih_, size_t(3 * H_) * H_) && rd(whh_, size_t(3 * H_) * H_) &&
             rd(bih_, 3 * H_) && rd(bhh_, 3 * H_) && rd(outW_, size_t(N_) * H_) && rd(outB_, N_);
    }
    std::fclose(f);
    if (!ok) { H_ = N_ = 0; return false; }

    // Mel band centres (HTK, 64 bands, 30 Hz - 11 kHz, as MelFeatures) -> 16 log-spaced groups (80 Hz - 11 kHz).
    auto h2m = [](double hz) { return 2595.0 * std::log10(1.0 + hz / 700.0); };
    auto m2h = [](double m) { return 700.0 * (std::pow(10.0, m / 2595.0) - 1.0); };
    double edges[kBands + 1];
    for (int i = 0; i <= kBands; ++i) edges[i] = 80.0 * std::pow(11000.0 / 80.0, double(i) / kBands);
    group_.resize(kMel);
    const double lo = h2m(30.0), hi = h2m(11000.0);
    for (int b = 0; b < kMel; ++b) {
        double c = m2h(lo + (hi - lo) * (b + 1) / (kMel + 1));
        int g = int(std::lower_bound(edges, edges + kBands + 1, c) - edges) - 1;
        group_[b] = std::clamp(g, 0, kBands - 1);
    }
    reset();
    return true;
}

void SectionDetector::reset() {
    win_.clear();
    winSum_.assign(kMel, 0.0);
    prevSm_.assign(kMel, 0.0);
    havePrev_ = false;
    envCount_ = 0; envBase_ = 0;
    env_.clear(); flux_.clear();
    haveBeat_ = false;
    ema_.clear(); absSum_.assign(kBase, 0.f);
    beats_ = 0;
    zHist_.clear();
    h_.assign(H_, 0.f);
    out_.assign(N_, 0.f);
    x_.assign(kIn, 0.f);
}

void SectionDetector::pushFrame(const float* feat, double t) {
    if (!loaded()) return;
    // Band power from log-mel, trailing 9-frame average.
    std::vector<double> p(kMel);
    for (int b = 0; b < kMel; ++b) { double m = std::expm1(std::max(0.f, feat[b])); p[b] = m * m; }
    win_.push_back(p);
    for (int b = 0; b < kMel; ++b) winSum_[b] += p[b];
    if (win_.size() > 9) { for (int b = 0; b < kMel; ++b) winSum_[b] -= win_.front()[b]; win_.pop_front(); }
    std::vector<double> sm(kMel);
    for (int b = 0; b < kMel; ++b) sm[b] = winSum_[b] / double(win_.size());
    if (!havePrev_) t0_ = t;
    // Emit envelope frames at t0 + k / kEnvFps up to t, interpolating from the previous frame.
    for (;;) {
        double tk = t0_ + envCount_ / kEnvFps;
        if (tk > t + 1e-9) break;
        double w = (havePrev_ && t > prevT_) ? (tk - prevT_) / (t - prevT_) : 1.0;
        w = std::clamp(w, 0.0, 1.0);
        double E[kBands] = {0};
        for (int b = 0; b < kMel; ++b) E[group_[b]] += havePrev_ ? prevSm_[b] + w * (sm[b] - prevSm_[b]) : sm[b];
        std::vector<float> e(kBands), d(kBands, 0.f);
        for (int g = 0; g < kBands; ++g) e[g] = float(std::log(E[g] + 1e-8));
        if (!env_.empty())
            for (int g = 0; g < kBands; ++g) d[g] = std::max(0.f, e[g] - env_.back()[g]);
        env_.push_back(std::move(e)); flux_.push_back(std::move(d));
        ++envCount_;
        while (env_.size() > 600) { env_.pop_front(); flux_.pop_front(); ++envBase_; }   // ~28 s
    }
    prevSm_ = sm; prevT_ = t; havePrev_ = true;
}

bool SectionDetector::onBeat(double tb, int inBarPrev) {
    if (!loaded()) return false;
    if (!haveBeat_ || envCount_ == 0) { haveBeat_ = true; lastBeat_ = tb; return false; }
    const long T = envCount_;
    long a = std::min(T - 1, std::max(0L, long(std::nearbyint((lastBeat_ - t0_) * kEnvFps))));
    long b = std::min(T, std::max(a + 1, long(std::nearbyint((tb - t0_) * kEnvFps))));
    a = std::max(a, envBase_); b = std::max(b, a + 1);
    // Beat summary row.
    std::vector<float> r(kBase, 0.f);
    double allE = 0, maxFlux = 0;
    const long n = b - a;
    for (long k = a; k < b; ++k) {
        const auto& e = env_[k - envBase_];
        const auto& d = flux_[k - envBase_];
        double fs = 0;
        for (int g = 0; g < kBands; ++g) { r[g] += e[g]; r[kBands + g] += d[g]; allE += e[g]; fs += d[g]; }
        maxFlux = std::max(maxFlux, fs);
    }
    for (int g = 0; g < 2 * kBands; ++g) r[g] /= float(n);
    r[2 * kBands] = float(allE / (n * kBands));
    r[2 * kBands + 1] = float(maxFlux);

    // Relative to the running average; repetition distances on causally scaled rows.
    if (ema_.empty()) ema_ = r;
    std::vector<float> rel(kBase), z(kBase);
    const float k = 2.f / (kEmaBeats + 1);
    for (int j = 0; j < kBase; ++j) { rel[j] = r[j] - ema_[j]; ema_[j] += k * (r[j] - ema_[j]); }
    ++beats_;
    for (int j = 0; j < kBase; ++j) { absSum_[j] += std::fabs(rel[j]); z[j] = rel[j] / (absSum_[j] / beats_ + 1e-3f); }
    auto dist = [&](const std::vector<float>& u, const std::vector<float>& v) {
        double s = 0;
        for (int j = 0; j < kBase; ++j) s += double(u[j] - v[j]) * (u[j] - v[j]);
        return float(std::sqrt(s / kBase));
    };
    float rep[5];
    for (int q = 0; q < 4; ++q) {
        size_t back = size_t(4 * kRepBars[q]);
        rep[q] = zHist_.size() >= back ? dist(z, zHist_[zHist_.size() - back]) : 1.f;
    }
    if (!zHist_.empty()) {
        std::vector<float> mean(kBase, 0.f);
        size_t m = std::min<size_t>(16, zHist_.size());
        for (size_t q = zHist_.size() - m; q < zHist_.size(); ++q)
            for (int j = 0; j < kBase; ++j) mean[j] += zHist_[q][j] / float(m);
        rep[4] = dist(z, mean);
    } else {
        rep[4] = 1.f;
    }
    zHist_.push_back(z);
    if (zHist_.size() > 33) zHist_.pop_front();

    // Input vector: rel, bar position one-hot, tempo, repetition.
    int o = 0;
    for (int j = 0; j < kBase; ++j) x_[o++] = rel[j];
    for (int j = 0; j < 4; ++j) x_[o++] = (((inBarPrev % 4) + 4) % 4) == j ? 1.f : 0.f;
    x_[o++] = float(std::log2(60.0 / std::max(tb - lastBeat_, 0.2) / 120.0));
    for (int j = 0; j < 5; ++j) x_[o++] = rep[j];
    lastBeat_ = tb;

    // Network step.
    std::vector<float> u(H_);
    for (int i = 0; i < H_; ++i) {
        float s = inB_[i];
        for (int j = 0; j < kIn; ++j) s += inW_[size_t(i) * kIn + j] * x_[j];
        u[i] = std::tanh(s);
    }
    std::vector<float> gi(3 * H_), gh(3 * H_);
    for (int i = 0; i < 3 * H_; ++i) {
        float s1 = bih_[i], s2 = bhh_[i];
        for (int j = 0; j < H_; ++j) { s1 += wih_[size_t(i) * H_ + j] * u[j]; s2 += whh_[size_t(i) * H_ + j] * h_[j]; }
        gi[i] = s1; gh[i] = s2;
    }
    for (int i = 0; i < H_; ++i) {   // PyTorch gate order: reset, update, new
        float rg = sigmoid(gi[i] + gh[i]);
        float zg = sigmoid(gi[H_ + i] + gh[H_ + i]);
        float ng = std::tanh(gi[2 * H_ + i] + rg * gh[2 * H_ + i]);
        h_[i] = (1.f - zg) * ng + zg * h_[i];
    }
    for (int q = 0; q < N_; ++q) {
        float s = outB_[q];
        for (int j = 0; j < H_; ++j) s += outW_[size_t(q) * H_ + j] * h_[j];
        out_[q] = sigmoid(s);
    }
    return true;
}

} // namespace choreo
