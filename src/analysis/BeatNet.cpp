#include "analysis/BeatNet.h"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>

namespace choreo {

void BeatNet::Conv::init(int ci, int co, int kk, int dd) {
    cin = ci; cout = co; k = kk; d = dd;
    w.assign(size_t(co) * ci * kk, 0.f);
    b.assign(co, 0.f);
    hist.assign(size_t((kk - 1) * dd + 1) * ci, 0.f);
    pos = 0;
}

// Causal dilated conv on a stream: y[t] = b + sum_j w[:, :, j] . x[t - (k-1-j) d]
void BeatNet::Conv::step(const float* x, float* y) {
    const int L = (k - 1) * d + 1;
    std::copy(x, x + cin, hist.begin() + size_t(pos) * cin);
    for (int o = 0; o < cout; ++o) {
        float s = b[o];
        const float* wo = w.data() + size_t(o) * cin * k;
        for (int j = 0; j < k; ++j) {
            int back = (k - 1 - j) * d;
            const float* xs = hist.data() + size_t((pos - back + L) % L) * cin;
            for (int c = 0; c < cin; ++c) s += wo[c * k + j] * xs[c];
        }
        y[o] = s;
    }
    pos = (pos + 1) % L;
}

static inline float elu(float x) { return x > 0 ? x : std::expm1(x); }

bool BeatNet::load(const std::string& path) {
    loaded_ = false;
    std::FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) return false;
    int32_t hdr[7];
    bool ok = std::fread(hdr, 4, 7, f) == 7 && hdr[0] == 0x42454154 && hdr[1] == 1;
    if (ok) {
        dim_ = hdr[2]; ch_ = hdr[3];
        int k = hdr[4], nblocks = hdr[5];
        lookahead_ = hdr[6];
        std::vector<int32_t> dil(nblocks);
        ok = std::fread(dil.data(), 4, nblocks, f) == size_t(nblocks);
        auto read = [&](std::vector<float>& v) { ok = ok && std::fread(v.data(), 4, v.size(), f) == v.size(); };
        inp_.init(dim_, ch_, k, 1);
        read(inp_.w); read(inp_.b);
        conv_.resize(nblocks); mix_.resize(nblocks);
        for (int i = 0; i < nblocks; ++i) {
            conv_[i].init(ch_, ch_, k, dil[i]);
            mix_[i].init(ch_, ch_, 1, 1);
            read(conv_[i].w); read(conv_[i].b); read(mix_[i].w); read(mix_[i].b);
        }
        out_.init(ch_, 2, 1, 1);
        read(out_.w); read(out_.b);
    }
    std::fclose(f);
    h_.assign(ch_, 0.f); t_.assign(ch_, 0.f); u_.assign(ch_, 0.f);
    loaded_ = ok;
    return ok;
}

void BeatNet::reset() {
    for (auto* c : {&inp_, &out_}) { std::fill(c->hist.begin(), c->hist.end(), 0.f); c->pos = 0; }
    for (auto& c : conv_) { std::fill(c.hist.begin(), c.hist.end(), 0.f); c.pos = 0; }
    for (auto& c : mix_) { std::fill(c.hist.begin(), c.hist.end(), 0.f); c.pos = 0; }
}

void BeatNet::push(const float* feat, float out[2]) {
    inp_.step(feat, h_.data());
    for (float& v : h_) v = elu(v);
    for (size_t i = 0; i < conv_.size(); ++i) {
        conv_[i].step(h_.data(), t_.data());
        for (float& v : t_) v = elu(v);
        mix_[i].step(t_.data(), u_.data());
        for (int c = 0; c < ch_; ++c) h_[c] += u_[c];
    }
    float logits[2];
    out_.step(h_.data(), logits);
    out[0] = 1.f / (1.f + std::exp(-logits[0]));
    out[1] = 1.f / (1.f + std::exp(-logits[1]));
}

} // namespace choreo
