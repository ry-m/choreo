#include "analysis/Analyzer.h"
#include "app/ClickTrack.h"
#include "app/Settings.h"
#include "audio/Capture.h"
#include "render/Renderer.h"
#include <SDL3/SDL.h>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

using namespace choreo;

namespace {

void printHelp() {
    std::printf(
        "choreo [--mic] [--app BUNDLE_ID] [--fullscreen] [--fps N] [--calibrate] [--tap]\n"
        "  --app com.spotify.client   visualise one app only (add --mute to silence that app)\n"
        "  --calibrate                play a click track; flash on each detected beat (A/V sync)\n"
        "  --tap                      tap SPACE on the beat; prints how far Choreo's beats are from yours\n"
        "keys: F fullscreen, [ / ] visuals 5 ms earlier / later (saved), Esc quit\n");
}

// Tap mode: collect the user's taps (in audio time) and compare them with Choreo's beats.
struct TapTester {
    std::vector<double> taps; // audio time the listener was hearing when they tapped
    size_t reported = 0;

    void report(const Analyzer& a) {
        if (taps.size() < reported + 8) return;
        std::vector<double> off;
        int offbeat = 0;
        for (size_t i = reported; i < taps.size(); ++i) {
            double best = 1e9;
            for (double b : a.beatTimes) if (std::fabs(taps[i] - b) < std::fabs(best)) best = taps[i] - b;
            double P = 60.0 / a.state().bpm;
            if (std::fabs(best) > P * 0.25) ++offbeat; else off.push_back(best * 1000);
        }
        int n = int(taps.size() - reported);
        // The listener's own tempo: median interval between consecutive taps in this batch.
        std::vector<double> iv;
        for (size_t i = reported + 1; i < taps.size(); ++i) iv.push_back(taps[i] - taps[i - 1]);
        std::sort(iv.begin(), iv.end());
        double yourBpm = iv.empty() ? 0 : 60.0 / iv[iv.size() / 2];
        reported = taps.size();
        std::sort(off.begin(), off.end());
        if (off.empty()) {
            std::printf("[tap] last %d taps (you: %.0f BPM): none near Choreo's beats — off-beat or wrong tempo (Choreo %.1f BPM)\n",
                        n, yourBpm, a.state().bpm);
        } else {
            double med = off[off.size() / 2];
            std::printf("[tap] last %d taps (you: %.0f BPM) vs Choreo (%.1f BPM): %s by %.0f ms (median), %d/%d taps off-beat\n",
                        n, yourBpm, a.state().bpm, med >= 0 ? "Choreo EARLY" : "Choreo LATE", std::fabs(med), offbeat, n);
        }
        std::fflush(stdout);
    }
};

} // namespace

int main(int argc, char** argv) {
    bool useMic = false, calibrate = false, tapMode = false, muteApp = false;
    float targetFps = 60.f;
    bool startFullscreen = false;
    std::string appBundle; // e.g. --app com.spotify.client : visualise only that app
    for (int i = 1; i < argc; ++i) {
        if (!std::strcmp(argv[i], "--mic")) useMic = true;
        else if (!std::strcmp(argv[i], "--fullscreen")) startFullscreen = true;
        else if (!std::strcmp(argv[i], "--app") && i + 1 < argc) appBundle = argv[++i];
        else if (!std::strcmp(argv[i], "--fps") && i + 1 < argc) targetFps = std::max(10.f, float(std::atof(argv[++i])));
        else if (!std::strcmp(argv[i], "--calibrate")) calibrate = true;
        else if (!std::strcmp(argv[i], "--tap")) tapMode = true;
        else if (!std::strcmp(argv[i], "--mute")) muteApp = true;
        else if (!std::strcmp(argv[i], "--help") || !std::strcmp(argv[i], "-h")) { printHelp(); return 0; }
    }

    if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO)) { SDL_Log("SDL_Init: %s", SDL_GetError()); return 1; }
    SDL_Window* window = SDL_CreateWindow(calibrate ? "Choreo — calibration" : "Choreo", 1280, 720,
                                          SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY);
    if (!window) { SDL_Log("SDL_CreateWindow: %s", SDL_GetError()); return 1; }

    Settings settings;
    settings.load();

    RingBuffer ring(1 << 17);
    std::unique_ptr<Capture> capture;
    if (!useMic) {
        // Calibration needs system audio (it listens to its own clicks).
        capture = (appBundle.empty() || calibrate) ? createSystemCapture() : createAppCapture(appBundle, muteApp);
        if (capture && !capture->start(&ring)) capture.reset();
        if (!capture) SDL_Log("System audio unavailable, falling back to microphone.");
    }
    if (!capture) {
        capture = createMicCapture();
        if (!capture->start(&ring)) { SDL_Log("No audio input available."); return 1; }
    }
    const double sr = capture->sampleRate();
    SDL_Log("Audio source: %s @ %.0f Hz, output latency %.1f ms, visual delay %+.0f ms",
            capture->name().c_str(), sr, capture->outputLatencySec() * 1000, settings.visualDelayMs);

    ClickTrack clicks(120.0);
    if (calibrate) {
        if (!clicks.start()) return 1;
        SDL_Log("Calibration: a click plays twice a second and the screen flashes on each beat Choreo detects.");
        SDL_Log("Press [ if the flash comes AFTER the click, ] if it comes BEFORE. The setting is saved.");
    }
    if (tapMode) SDL_Log("Tap mode: tap SPACE on every beat (aim for the kick). Results print every 8 taps.");

    Analyzer analyzer(sr);
    analyzer.recordEvents = tapMode;
    Renderer renderer;
    std::string shaderDir = std::string(SDL_GetBasePath()) + "shaders";
    if (!renderer.init(window, shaderDir)) return 1;
    renderer.setTargetFps(targetFps);
    renderer.setCalibrationMode(calibrate);
    const Uint64 framePeriodNs = Uint64(1e9 / targetFps);
    Uint64 nextFrame = SDL_GetTicksNS();

    // Audio time (analyser seconds) that the listener hears at host time `hostNs`.
    auto heardAudioTime = [&](uint64_t hostNs) -> double {
        uint64_t idx, clockNs;
        if (!capture->clock(idx, clockNs)) return analyzer.state().time;
        double captureNs = double(hostNs) - capture->outputLatencySec() * 1e9; // when it was captured
        return (double(idx) + (captureNs - double(clockNs)) * 1e-9 * sr) / sr;
    };

    TapTester tapper;
    std::vector<float> buf(8192);
    Uint64 last = SDL_GetTicksNS(), lastLog = last;
    int framesSinceLog = 0;
    bool running = true, fullscreen = startFullscreen;
    if (fullscreen) SDL_SetWindowFullscreen(window, true);
    while (running) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_EVENT_QUIT) running = false;
            if (e.type == SDL_EVENT_KEY_DOWN && !e.key.repeat) {
                if (e.key.key == SDLK_ESCAPE) running = false;
                if (e.key.key == SDLK_F) { fullscreen = !fullscreen; SDL_SetWindowFullscreen(window, fullscreen); }
                if (e.key.key == SDLK_LEFTBRACKET || e.key.key == SDLK_RIGHTBRACKET) {
                    settings.visualDelayMs += e.key.key == SDLK_LEFTBRACKET ? -5.f : 5.f;
                    settings.save();
                    SDL_Log("visual delay %+.0f ms (saved)", settings.visualDelayMs);
                }
                if (tapMode && e.key.key == SDLK_SPACE) {
                    // Event timestamps are SDL ticks; convert to the capture clock.
                    uint64_t tapNs = nowNs() - (SDL_GetTicksNS() - e.key.timestamp);
                    tapper.taps.push_back(heardAudioTime(tapNs));
                }
            }
        }
        // Frame cap: sleep until the next frame slot (vsync then aligns the present).
        Uint64 t = SDL_GetTicksNS();
        if (t < nextFrame) SDL_DelayPrecise(nextFrame - t);
        nextFrame = std::max(nextFrame + framePeriodNs, SDL_GetTicksNS() - framePeriodNs);

        // Drain all captured audio into the analyser.
        while (size_t n = ring.read(buf.data(), buf.size())) analyzer.process(buf.data(), n);
        if (tapMode) tapper.report(analyzer);

        // Show what the listener will be hearing when this frame reaches the screen: the frame
        // appears about one frame period from now (vsync), and sound reaches the ears
        // outputLatency after capture. Plus the user's own calibration.
        uint64_t displayNs = nowNs() + framePeriodNs + 4'000'000ull;
        double tShow = heardAudioTime(displayNs) - settings.visualDelayMs * 1e-3;
        MusicState shown = analyzer.stateAt(tShow);

        Uint64 now = SDL_GetTicksNS();
        float dt = float(now - last) * 1e-9f;
        last = now;
        renderer.render(shown, dt);
        ++framesSinceLog;

        if (now - lastLog > 2'000'000'000ull) {
            const auto& s = analyzer.state();
            float fps = framesSinceLog / (float(now - lastLog) * 1e-9f);
            SDL_Log("%.0f fps  render %dx%d (%.0f%%)  |  %s  bpm %.1f (conf %.2f, clarity %.2f)  beats %d  |  shown %+.0f ms vs analysis",
                    fps, renderer.renderWidth(), renderer.renderHeight(), renderer.renderScale() * 100.f,
                    s.beatPresent ? "BEAT" : "no beat", s.bpm, s.tempoConfidence, s.pulseClarity, s.beatCount,
                    (tShow - s.time) * 1000);
            lastLog = now;
            framesSinceLog = 0;
        }
    }
    clicks.stop();
    capture->stop();
    renderer.shutdown();
    SDL_DestroyWindow(window);
    SDL_Quit();
    return 0;
}
