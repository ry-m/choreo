// Checks that the C++ section detector reproduces tools/ml/sections.py on a real song.
// usage: test_sections models/sections.bin models/sections_testvec.bin
#include "analysis/Sections.h"
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

int main(int argc, char** argv) {
    if (argc < 3) { std::fprintf(stderr, "usage: %s sections.bin testvec.bin\n", argv[0]); return 1; }
    choreo::SectionDetector det;
    if (!det.load(argv[1])) { std::printf("FAIL: could not load %s\n", argv[1]); return 1; }
    std::FILE* f = std::fopen(argv[2], "rb");
    if (!f) { std::printf("FAIL: no test vector\n"); return 1; }
    int32_t T, D; float off;
    std::fread(&T, 4, 1, f); std::fread(&D, 4, 1, f); std::fread(&off, 4, 1, f);
    std::vector<float> x(size_t(T) * D); std::fread(x.data(), 4, x.size(), f);
    int32_t nb; std::fread(&nb, 4, 1, f);
    std::vector<double> beats(nb); std::fread(beats.data(), 8, nb, f);
    std::vector<int32_t> pos(nb); std::fread(pos.data(), 4, nb, f);
    int32_t rows, N; std::fread(&rows, 4, 1, f); std::fread(&N, 4, 1, f);
    std::vector<float> want(size_t(rows) * N), wantIn(size_t(rows) * choreo::SectionDetector::kIn);
    std::fread(want.data(), 4, want.size(), f); std::fread(wantIn.data(), 4, wantIn.size(), f);
    std::fclose(f);

    // Feed frames ahead of each beat (offline: every frame up to the beat is available).
    long next = 0;
    double maxErr = 0, maxInErr = 0; int r = 0;
    for (int i = 0; i < nb; ++i) {
        while (next < T && off + next / 100.0 <= beats[i] + 0.2) { det.pushFrame(&x[size_t(next) * D], off + next / 100.0); ++next; }
        if (det.onBeat(beats[i], i > 0 ? pos[i - 1] : 0)) {
            for (int q = 0; q < N; ++q) maxErr = std::max(maxErr, double(std::fabs(det.outputs()[q] - want[size_t(r) * N + q])));
            for (int q = 0; q < choreo::SectionDetector::kIn; ++q)
                maxInErr = std::max(maxInErr, double(std::fabs(det.lastInput()[q] - wantIn[size_t(r) * choreo::SectionDetector::kIn + q])));
            ++r;
        }
    }
    std::printf("SectionDetector vs PyTorch over %d beats: max |input error| %.2e, max |output error| %.2e\n", r, maxInErr, maxErr);
    bool ok = r == rows && maxErr < 1e-3;
    std::printf("%s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
