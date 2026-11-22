#pragma once
// Minimal PNG writer (RGB8, uncompressed deflate blocks). Big files, no dependencies.
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

namespace choreo {

inline uint32_t pngCrc(const uint8_t* d, size_t n, uint32_t c = 0xffffffffu) {
    static uint32_t table[256] = {};
    if (!table[1]) for (uint32_t i = 0; i < 256; ++i) { uint32_t k = i; for (int j = 0; j < 8; ++j) k = k & 1 ? 0xedb88320u ^ (k >> 1) : k >> 1; table[i] = k; }
    for (size_t i = 0; i < n; ++i) c = table[(c ^ d[i]) & 0xff] ^ (c >> 8);
    return c;
}

// rgb: w*h*3 bytes, rows top to bottom.
inline bool writePng(const std::string& path, const uint8_t* rgb, int w, int h) {
    std::vector<uint8_t> raw;
    raw.reserve(size_t(h) * (w * 3 + 1));
    for (int y = 0; y < h; ++y) { raw.push_back(0); raw.insert(raw.end(), rgb + size_t(y) * w * 3, rgb + size_t(y + 1) * w * 3); }
    std::vector<uint8_t> z = {0x78, 0x01};
    uint32_t a = 1, b = 0;
    for (uint8_t v : raw) { a = (a + v) % 65521; b = (b + a) % 65521; }
    for (size_t off = 0; off < raw.size() || off == 0;) {
        size_t n = std::min<size_t>(65535, raw.size() - off);
        z.push_back(off + n >= raw.size() ? 1 : 0);
        z.push_back(uint8_t(n)); z.push_back(uint8_t(n >> 8)); z.push_back(uint8_t(~n)); z.push_back(uint8_t(~n >> 8));
        z.insert(z.end(), raw.begin() + off, raw.begin() + off + n);
        off += n;
        if (raw.empty()) break;
    }
    uint32_t ad = (b << 16) | a;
    for (int i = 3; i >= 0; --i) z.push_back(uint8_t(ad >> (8 * i)));

    std::FILE* f = std::fopen(path.c_str(), "wb");
    if (!f) return false;
    auto be32 = [&](uint32_t v) { uint8_t x[4] = {uint8_t(v >> 24), uint8_t(v >> 16), uint8_t(v >> 8), uint8_t(v)}; std::fwrite(x, 1, 4, f); };
    auto chunk = [&](const char* type, const std::vector<uint8_t>& data) {
        be32(uint32_t(data.size()));
        std::vector<uint8_t> td(type, type + 4);
        td.insert(td.end(), data.begin(), data.end());
        std::fwrite(td.data(), 1, td.size(), f);
        be32(pngCrc(td.data(), td.size()) ^ 0xffffffffu);
    };
    const uint8_t sig[8] = {137, 80, 78, 71, 13, 10, 26, 10};
    std::fwrite(sig, 1, 8, f);
    std::vector<uint8_t> ihdr = {uint8_t(w >> 24), uint8_t(w >> 16), uint8_t(w >> 8), uint8_t(w),
                                 uint8_t(h >> 24), uint8_t(h >> 16), uint8_t(h >> 8), uint8_t(h), 8, 2, 0, 0, 0};
    chunk("IHDR", ihdr);
    chunk("IDAT", z);
    chunk("IEND", {});
    return std::fclose(f) == 0;
}

} // namespace choreo
