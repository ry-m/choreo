// Checks that the streaming C++ BeatNet reproduces PyTorch's outputs exactly.
// Usage: test_beatnet MODEL.bin TESTVEC.bin   (test vector from tools/ml/export_testvec.py)
#include "analysis/BeatNet.h"
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

int main(int argc, char** argv) {
    if (argc < 3) { std::printf("usage: %s model.bin testvec.bin\n", argv[0]); return 1; }
    choreo::BeatNet net;
    if (!net.load(argv[1])) { std::printf("FAIL: cannot load %s\n", argv[1]); return 1; }
    std::FILE* f = std::fopen(argv[2], "rb");
    if (!f) { std::printf("FAIL: cannot open %s\n", argv[2]); return 1; }
    int32_t T, D;
    std::fread(&T, 4, 1, f); std::fread(&D, 4, 1, f);
    std::vector<float> x(size_t(T) * D), y(size_t(T) * 2);
    std::fread(x.data(), 4, x.size(), f); std::fread(y.data(), 4, y.size(), f);
    std::fclose(f);
    double maxErr = 0;
    for (int t = 0; t < T; ++t) {
        float out[2];
        net.push(&x[size_t(t) * D], out);
        for (int j = 0; j < 2; ++j) maxErr = std::max(maxErr, double(std::fabs(out[j] - y[size_t(t) * 2 + j])));
    }
    std::printf("BeatNet vs PyTorch over %d frames: max |error| = %.2e\n", T, maxErr);
    if (maxErr > 1e-4) { std::printf("FAIL\n"); return 1; }
    std::printf("PASS\n");
    return 0;
}
