#include "analysis/FFT.h"
#include <cmath>

namespace choreo {

FFT::FFT(int n) : n_(n), twiddle_(n / 2), rev_(n), work_(n) {
    int bits = 0;
    while ((1 << bits) < n) ++bits;
    for (int i = 0; i < n; ++i) {
        int r = 0;
        for (int b = 0; b < bits; ++b) r |= ((i >> b) & 1) << (bits - 1 - b);
        rev_[i] = r;
    }
    for (int i = 0; i < n / 2; ++i) {
        double a = -2.0 * M_PI * i / n;
        twiddle_[i] = {float(std::cos(a)), float(std::sin(a))};
    }
}

void FFT::forward(std::complex<float>* d) const {
    for (int i = 0; i < n_; ++i)
        if (i < rev_[i]) std::swap(d[i], d[rev_[i]]);
    for (int len = 2; len <= n_; len <<= 1) {
        int half = len >> 1, step = n_ / len;
        for (int i = 0; i < n_; i += len) {
            for (int j = 0; j < half; ++j) {
                auto t = twiddle_[j * step] * d[i + j + half];
                d[i + j + half] = d[i + j] - t;
                d[i + j] += t;
            }
        }
    }
}

void FFT::magnitudes(const float* in, float* mag) {
    for (int i = 0; i < n_; ++i) work_[i] = {in[i], 0.f};
    forward(work_.data());
    for (int i = 0; i <= n_ / 2; ++i) mag[i] = std::abs(work_[i]);
}

} // namespace choreo
