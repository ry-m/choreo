#include "analysis/Analyzer.h"
#include "audio/Capture.h"
#include "render/Renderer.h"
#include <SDL3/SDL.h>
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <vector>

using namespace choreo;

int main(int argc, char** argv) {
    bool useMic = false;
    float targetFps = 60.f;
    bool startFullscreen = false;
    std::string appBundle; // e.g. --app com.spotify.client : visualise only that app
    for (int i = 1; i < argc; ++i) {
        if (!std::strcmp(argv[i], "--mic")) useMic = true;
        if (!std::strcmp(argv[i], "--fullscreen")) startFullscreen = true;
        if (!std::strcmp(argv[i], "--app") && i + 1 < argc) appBundle = argv[++i];
        if (!std::strcmp(argv[i], "--fps") && i + 1 < argc) targetFps = std::max(10.f, float(std::atof(argv[++i])));
    }

    if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO)) { SDL_Log("SDL_Init: %s", SDL_GetError()); return 1; }
    SDL_Window* window = SDL_CreateWindow("Choreo", 1280, 720, SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY);
    if (!window) { SDL_Log("SDL_CreateWindow: %s", SDL_GetError()); return 1; }

    RingBuffer ring(1 << 17);
    std::unique_ptr<Capture> capture;
    if (!useMic) {
        capture = appBundle.empty() ? createSystemCapture() : createAppCapture(appBundle, false);
        if (capture && !capture->start(&ring)) capture.reset();
        if (!capture) SDL_Log("System audio unavailable, falling back to microphone.");
    }
    if (!capture) {
        capture = createMicCapture();
        if (!capture->start(&ring)) { SDL_Log("No audio input available."); return 1; }
    }
    SDL_Log("Audio source: %s @ %.0f Hz", capture->name().c_str(), capture->sampleRate());

    Analyzer analyzer(capture->sampleRate());
    Renderer renderer;
    std::string shaderDir = std::string(SDL_GetBasePath()) + "shaders";
    if (!renderer.init(window, shaderDir)) return 1;
    renderer.setTargetFps(targetFps);
    const Uint64 framePeriodNs = Uint64(1e9 / targetFps);
    Uint64 nextFrame = SDL_GetTicksNS();

    std::vector<float> buf(8192);
    Uint64 last = SDL_GetTicksNS(), lastLog = last;
    int framesSinceLog = 0;
    bool running = true, fullscreen = startFullscreen;
    if (fullscreen) SDL_SetWindowFullscreen(window, true);
    while (running) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_EVENT_QUIT) running = false;
            if (e.type == SDL_EVENT_KEY_DOWN) {
                if (e.key.key == SDLK_ESCAPE) running = false;
                if (e.key.key == SDLK_F) { fullscreen = !fullscreen; SDL_SetWindowFullscreen(window, fullscreen); }
            }
        }
        // Frame cap: sleep until the next frame slot (vsync then aligns the present).
        Uint64 t = SDL_GetTicksNS();
        if (t < nextFrame) SDL_DelayPrecise(nextFrame - t);
        nextFrame = std::max(nextFrame + framePeriodNs, SDL_GetTicksNS() - framePeriodNs);

        // Drain all captured audio into the analyser.
        while (size_t n = ring.read(buf.data(), buf.size())) analyzer.process(buf.data(), n);

        Uint64 now = SDL_GetTicksNS();
        float dt = float(now - last) * 1e-9f;
        last = now;
        renderer.render(analyzer.state(), dt);
        ++framesSinceLog;

        if (now - lastLog > 2'000'000'000ull) {
            const auto& s = analyzer.state();
            float fps = framesSinceLog / (float(now - lastLog) * 1e-9f);
            SDL_Log("%.0f fps  render %dx%d (%.0f%%)  |  %s  bpm %.1f (conf %.2f, clarity %.2f)  beats %d  loud %.2f  bass %.2f  energy %.2f",
                    fps, renderer.renderWidth(), renderer.renderHeight(), renderer.renderScale() * 100.f,
                    s.beatPresent ? "BEAT" : "no beat", s.bpm, s.tempoConfidence, s.pulseClarity, s.beatCount, s.loudness, s.bass, s.energyRatio);
            lastLog = now;
            framesSinceLog = 0;
        }
    }
    capture->stop();
    renderer.shutdown();
    SDL_DestroyWindow(window);
    SDL_Quit();
    return 0;
}
