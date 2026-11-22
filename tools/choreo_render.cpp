// Offline renderer: drive the analyser, scene director and GPU renderer from an audio file, with no
// window and no sound. Writes PNGs at chosen times, a contact sheet around every director cut, the
// director's event log (for tools/eval_cuts.py), and GPU timings per scene.
//
//   choreo-render song.wav --cuts                  # sheet: each cut at -1 frame, on the cut, +1 beat, +2 beats
//   choreo-render song.wav --at 30,61.5 --size 1280x720
//   choreo-render song.wav --events                # director events + analyser beats/downbeats/sections
//   choreo-render song.wav --bench --size 3024x1964 --scale 0.49   # GPU ms per frame, per scene
#include "Png.h"
#include "Wav.h"
#include "analysis/Analyzer.h"
#include "render/Director.h"
#include "render/Renderer.h"
#include <SDL3/SDL.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <set>
#include <string>
#include <vector>

using namespace choreo;

namespace {

struct FrameRec {
    double time;
    int scene;
    float bpm;
    SceneUniforms u;
    PostLook post;
};

std::vector<double> parseList(const char* s) {
    std::vector<double> v;
    for (const char* p = s; *p;) {
        v.push_back(std::atof(p));
        while (*p && *p != ',') ++p;
        if (*p == ',') ++p;
    }
    return v;
}

double median(std::vector<double> v) { if (v.empty()) return 0; std::sort(v.begin(), v.end()); return v[v.size() / 2]; }
double pct(std::vector<double> v, double q) { if (v.empty()) return 0; std::sort(v.begin(), v.end()); return v[std::min(v.size() - 1, size_t(q * v.size()))]; }

// GPU: an offscreen 8-bit target plus a transfer buffer to read it back.
struct Gpu {
    SDL_GPUDevice* dev = nullptr;
    SDL_GPUTexture* target = nullptr;
    SDL_GPUTransferBuffer* readback = nullptr;
    unsigned w = 0, h = 0;
    Renderer r;

    bool init(const std::string& shaderDir, unsigned W, unsigned H) {
        dev = SDL_CreateGPUDevice(SDL_GPU_SHADERFORMAT_MSL, false, nullptr);
        if (!dev) { std::fprintf(stderr, "SDL_CreateGPUDevice: %s\n", SDL_GetError()); return false; }
        w = W; h = H;
        SDL_GPUTextureCreateInfo ti{};
        ti.type = SDL_GPU_TEXTURETYPE_2D;
        ti.format = SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
        ti.usage = SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | SDL_GPU_TEXTUREUSAGE_SAMPLER;
        ti.width = w; ti.height = h; ti.layer_count_or_depth = 1; ti.num_levels = 1;
        target = SDL_CreateGPUTexture(dev, &ti);
        SDL_GPUTransferBufferCreateInfo bi{};
        bi.usage = SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
        bi.size = w * h * 4;
        readback = SDL_CreateGPUTransferBuffer(dev, &bi);
        return target && readback && r.init(dev, SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM, shaderDir);
    }
    // Renders one frame and waits for it; returns GPU wall time in ms. Optionally reads it back.
    double frame(const FrameRec& f, std::vector<uint8_t>* rgb) {
        SDL_GPUCommandBuffer* cmd = SDL_AcquireGPUCommandBuffer(dev);
        r.render(cmd, target, w, h, f.scene, f.u, f.post);
        if (rgb) {
            SDL_GPUCopyPass* cp = SDL_BeginGPUCopyPass(cmd);
            SDL_GPUTextureRegion src{};
            src.texture = target; src.w = w; src.h = h; src.d = 1;
            SDL_GPUTextureTransferInfo dst{};
            dst.transfer_buffer = readback;
            SDL_DownloadFromGPUTexture(cp, &src, &dst);
            SDL_EndGPUCopyPass(cp);
        }
        auto t0 = std::chrono::steady_clock::now();
        SDL_GPUFence* fence = SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
        SDL_WaitForGPUFences(dev, true, &fence, 1);
        double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        SDL_ReleaseGPUFence(dev, fence);
        if (rgb) {
            const uint8_t* p = static_cast<const uint8_t*>(SDL_MapGPUTransferBuffer(dev, readback, false));
            rgb->resize(size_t(w) * h * 3);
            for (size_t i = 0; i < size_t(w) * h; ++i) for (int c = 0; c < 3; ++c) (*rgb)[i * 3 + c] = p[i * 4 + c];
            SDL_UnmapGPUTransferBuffer(dev, readback);
        }
        return ms;
    }
    void shutdown() {
        r.shutdown();
        if (readback) SDL_ReleaseGPUTransferBuffer(dev, readback);
        if (target) SDL_ReleaseGPUTexture(dev, target);
        if (dev) SDL_DestroyGPUDevice(dev);
    }
};

} // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s audio [--out DIR] [--size WxH] [--scale S] [--fps N] [--at T,T..] [--cuts] "
                             "[--events] [--scene N] [--bench] [--from S] [--to S]\n", argv[0]);
        return 1;
    }
    std::string out = "render";
    unsigned W = 640, H = 360;
    float scale = 1.f, fps = 60.f;
    std::vector<double> at;
    bool cuts = false, events = false, bench = false;
    int pinScene = -1;
    double from = 0, to = 1e9;
    for (int i = 2; i < argc; ++i) {
        auto arg = [&](const char* k) { return !std::strcmp(argv[i], k) && i + 1 < argc; };
        if (arg("--out")) out = argv[++i];
        else if (arg("--size")) std::sscanf(argv[++i], "%ux%u", &W, &H);
        else if (arg("--scale")) scale = float(std::atof(argv[++i]));
        else if (arg("--fps")) fps = float(std::atof(argv[++i]));
        else if (arg("--at")) at = parseList(argv[++i]);
        else if (arg("--scene")) pinScene = std::atoi(argv[++i]);
        else if (arg("--from")) from = std::atof(argv[++i]);
        else if (arg("--to")) to = std::atof(argv[++i]);
        else if (!std::strcmp(argv[i], "--cuts")) cuts = true;
        else if (!std::strcmp(argv[i], "--events")) events = true;
        else if (!std::strcmp(argv[i], "--bench")) bench = true;
    }

    std::vector<float> audio; double sr = 0;
    if (!loadAudioMono(argv[1], audio, sr)) { std::fprintf(stderr, "failed to read %s\n", argv[1]); return 1; }
    std::string exe = argv[0], dir = exe.find_last_of('/') == std::string::npos ? "." : exe.substr(0, exe.find_last_of('/'));

    // ---- Pass 1: analysis + director at the display rate, exactly as the app steps them ----------
    Analyzer a(sr);
    {
        const char* env = std::getenv("CHOREO_MODEL");
        std::string model = env ? env : dir + "/../models/beatnet.bin";
        if (model != "none") a.loadBeatModel(model);
        const char* senv = std::getenv("CHOREO_SECTIONS");
        std::string smodel = senv ? senv : dir + "/../models/sections.bin";
        if (smodel != "none") a.loadSectionModel(smodel);
    }
    a.recordEvents = true;
    Director d;
    d.recordEvents = true;
    if (pinScene >= 0) d.forceScene(pinScene);
    std::vector<FrameRec> frames;
    const double dur = std::min(to, audio.size() / sr);
    size_t pos = 0;
    for (long f = 0;; ++f) {
        double t = f / double(fps);
        if (t > dur) break;
        size_t want = std::min(audio.size(), size_t(t * sr));
        while (pos < want) { size_t n = std::min<size_t>(512, want - pos); a.process(audio.data() + pos, n); pos += n; }
        MusicState s = a.stateAt(t);
        d.setRenderSize(int(W * scale), int(H * scale));
        d.update(s, 1.f / fps);
        frames.push_back({t, d.scene(), s.bpm, d.uniforms(), d.post()});
    }

    int nCuts = 0;
    for (auto& e : d.events) nCuts += !std::strcmp(e.kind, "cut");
    std::fprintf(stderr, "%s: %.1f s, %zu frames, %d cuts, %zu director events\n", argv[1], dur, frames.size(), nCuts, d.events.size());

    if (events) {
        std::printf("#director time kind scene beatCount beatInBar prob why\n");
        for (auto& e : d.events)
            std::printf("%.4f %s %d %d %d %.3f %s\n", e.time, e.kind, e.scene, e.beatCount, e.beatInBar, e.prob, e.why.c_str());
        std::printf("#beats\n");
        for (double t : a.beatTimes) std::printf("%.4f\n", t);
        std::printf("#downbeats\n");
        for (double t : a.downbeatTimes) std::printf("%.4f\n", t);
        std::printf("#sections\n");
        for (auto& e : a.sectionEvents) std::printf("%.4f %d %.3f\n", e.time, e.kind, e.prob);
    }

    // ---- Which frames to render ---------------------------------------------------------------
    auto frameAt = [&](double t) { return std::clamp(long(std::lround(t * fps)), 0L, long(frames.size()) - 1); };
    std::vector<long> shots;                       // frames to save as single PNGs
    std::vector<std::array<long, 4>> sheetRows;    // cut contact sheet
    for (double t : at) shots.push_back(frameAt(t));
    if (cuts) {
        for (auto& e : d.events) {
            if (std::strcmp(e.kind, "cut") || e.time < from) continue;
            long fc = frameAt(e.time);
            long beat = long(std::lround(60.0 / frames[fc].bpm * fps));
            sheetRows.push_back({fc - 1, fc, fc + beat, fc + 2 * beat});
            std::printf("cut %2zu  t=%7.3f  scene %d (%s)  beat %d in bar %d  %s\n", sheetRows.size(), e.time, e.scene,
                        kScenes[e.scene].id, e.beatCount, e.beatInBar, e.why.c_str());
        }
    }
    if (shots.empty() && sheetRows.empty() && !bench) return 0;

    SDL_SetHint(SDL_HINT_MAC_BACKGROUND_APP, "1");  // no Dock icon, no window
    if (!SDL_Init(SDL_INIT_VIDEO)) { std::fprintf(stderr, "SDL_Init: %s\n", SDL_GetError()); return 1; }
    Gpu gpu;
    if (!gpu.init(dir + "/shaders", W, H)) return 1;
    gpu.r.setScale(scale);
    std::filesystem::create_directories(out);

    if (bench) {
        // Each scene for 240 frames from 60 s in (or the middle of a short file), GPU time per frame.
        long start = frameAt(std::min(60.0, dur / 2));
        std::printf("bench %ux%u, scale %.2f -> %dx%d raymarched\n", W, H, scale, int(W * scale), int(H * scale));
        for (int s = 0; s < kSceneCount; ++s) {
            std::vector<double> ms;
            gpu.r.resetHistory();
            for (long f = start; f < std::min<long>(start + 240, frames.size()); ++f) {
                FrameRec fr = frames[f];
                fr.scene = s;
                std::memcpy(fr.u.pal, &kScenes[s].palettes[0], sizeof fr.u.pal);
                double t = gpu.frame(fr, nullptr);
                if (f > start + 10) ms.push_back(t);
            }
            std::printf("  %-8s GPU %.2f ms median, %.2f ms p95, %.2f ms max\n", kScenes[s].id, median(ms), pct(ms, 0.95), pct(ms, 1.0));
        }
    }

    // Render the needed frames in order, with ~0.75 s of warm-up before each so trails are right.
    std::set<long> need;
    for (long f : shots) need.insert(f);
    for (auto& r : sheetRows) for (long f : r) need.insert(std::clamp(f, 0L, long(frames.size()) - 1));
    const long warm = long(fps * 0.75f);
    std::vector<std::vector<uint8_t>> sheet(sheetRows.size() * 4);
    std::vector<double> ms;
    long next = -1;
    for (long f : need) {
        long s0 = std::max(next, f - warm);
        if (s0 != next) gpu.r.resetHistory();
        for (long g = std::max(0L, s0); g <= f; ++g) {
            bool keep = g == f;
            std::vector<uint8_t> rgb;
            ms.push_back(gpu.frame(frames[g], keep ? &rgb : nullptr));
            if (!keep) continue;
            if (std::find(shots.begin(), shots.end(), f) != shots.end()) {
                char name[256];
                std::snprintf(name, sizeof name, "%s/t%07.2f_%s.png", out.c_str(), frames[f].time, kScenes[frames[f].scene].id);
                writePng(name, rgb.data(), int(W), int(H));
                std::printf("wrote %s\n", name);
            }
            for (size_t r = 0; r < sheetRows.size(); ++r)
                for (int c = 0; c < 4; ++c)
                    if (std::clamp(sheetRows[r][c], 0L, long(frames.size()) - 1) == f) sheet[r * 4 + c] = rgb;
        }
        next = f + 1;
    }
    if (!sheetRows.empty()) {
        // Contact sheet: one row per cut; columns = frame before, cut frame, +1 beat, +2 beats.
        // A 4 px white bar marks the cut frame's top edge.
        const int gap = 6, SW = int(W) * 4 + gap * 3, SH = int(H) * int(sheetRows.size()) + gap * int(sheetRows.size() - 1);
        std::vector<uint8_t> img(size_t(SW) * SH * 3, 20);
        for (size_t r = 0; r < sheetRows.size(); ++r)
            for (int c = 0; c < 4; ++c) {
                const auto& tile = sheet[r * 4 + c];
                if (tile.empty()) continue;
                for (unsigned y = 0; y < H; ++y) {
                    uint8_t* dst = &img[(size_t(r * (H + gap) + y) * SW + c * (W + gap)) * 3];
                    std::memcpy(dst, &tile[size_t(y) * W * 3], W * 3);
                    if (c == 1 && y < 4) std::memset(dst, 255, W * 3);
                }
            }
        std::string name = out + "/cuts.png";
        writePng(name, img.data(), SW, SH);
        std::printf("wrote %s (%zu cuts)\n", name.c_str(), sheetRows.size());
    }
    if (!ms.empty())
        std::printf("rendered %zu frames at %ux%u (scale %.2f): GPU %.2f ms median, %.2f ms p95\n", ms.size(), W, H, scale,
                    median(ms), pct(ms, 0.95));
    gpu.shutdown();
    SDL_Quit();
    return 0;
}
