#include "Wav.h"
#include <cstdint>
#include <cstring>
#include <fstream>

namespace choreo {

bool loadWavMono(const std::string& path, std::vector<float>& out, double& sampleRate) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    std::vector<char> d((std::istreambuf_iterator<char>(f)), {});
    if (d.size() < 12 || std::memcmp(d.data(), "RIFF", 4) || std::memcmp(d.data() + 8, "WAVE", 4)) return false;
    auto u16 = [&](size_t o) { uint16_t v; std::memcpy(&v, &d[o], 2); return v; };
    auto u32 = [&](size_t o) { uint32_t v; std::memcpy(&v, &d[o], 4); return v; };

    int fmtTag = 0, channels = 0, bits = 0;
    size_t pos = 12, dataOff = 0, dataLen = 0;
    while (pos + 8 <= d.size()) {
        uint32_t len = u32(pos + 4);
        if (!std::memcmp(&d[pos], "fmt ", 4)) {
            fmtTag = u16(pos + 8); channels = u16(pos + 10);
            sampleRate = u32(pos + 12); bits = u16(pos + 22);
            if (fmtTag == 0xFFFE && len >= 40) fmtTag = u16(pos + 32); // WAVE_FORMAT_EXTENSIBLE
        } else if (!std::memcmp(&d[pos], "data", 4)) {
            dataOff = pos + 8; dataLen = std::min<size_t>(len, d.size() - dataOff);
            break;
        }
        pos += 8 + len + (len & 1);
    }
    if (!dataOff || channels <= 0) return false;
    int bps = bits / 8;
    size_t frames = dataLen / (bps * channels);
    out.assign(frames, 0.f);
    for (size_t i = 0; i < frames; ++i) {
        float s = 0;
        for (int c = 0; c < channels; ++c) {
            const char* p = &d[dataOff + (i * channels + c) * bps];
            if (fmtTag == 3 && bits == 32) { float v; std::memcpy(&v, p, 4); s += v; }
            else if (bits == 16) { int16_t v; std::memcpy(&v, p, 2); s += v / 32768.f; }
            else if (bits == 24) { int32_t v = (uint8_t(p[0]) << 8) | (uint8_t(p[1]) << 16) | (int32_t(int8_t(p[2])) << 24); s += (v >> 8) / 8388608.f; }
            else if (bits == 32) { int32_t v; std::memcpy(&v, p, 4); s += v / 2147483648.f; }
            else return false;
        }
        out[i] = s / channels;
    }
    return true;
}

} // namespace choreo
