#pragma once
#include <complex>
#include <vector>

namespace choreo {

// In-place iterative radix-2 complex FFT with precomputed twiddles and bit-reversal.
class FFT {
public:
    explicit FFT(int n);
    int size() const { return n_; }
    void forward(std::complex<float>* data) const;
    // Real input of length n -> magnitudes of bins [0, n/2].
    void magnitudes(const float* in, float* mag);

private:
    int n_;
    std::vector<std::complex<float>> twiddle_;
    std::vector<int> rev_;
    std::vector<std::complex<float>> work_;
};

} // namespace choreo
