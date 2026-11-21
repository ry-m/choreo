#pragma once
#include "analysis/MusicState.h"
#include <string>

struct SDL_Window;
struct SDL_GPUDevice;
struct SDL_GPUGraphicsPipeline;
struct SDL_GPUTexture;

namespace choreo {

// Must match `Uniforms` in shaders/*.metal (all float4 for alignment).
struct FrameUniforms {
    float resTime[4];  // width, height, time, beatPhase
    float beat[4];     // beatPulse, kick, snare, hat
    float spec[4];     // bass, mid, treble, loudness
    float misc[4];     // energyRatio, brightness, bpm, beatCount
    float motion[4];   // travel, twist, hue, flash
};

class Renderer {
public:
    bool init(SDL_Window* window, const std::string& shaderDir);
    void shutdown();
    // dt: seconds since last frame. Integrates music into smooth motion, then draws.
    void render(const MusicState& m, float dt);

    // Frame-time budget used by dynamic resolution (the app also caps to this rate).
    void setTargetFps(float fps) { targetFps_ = fps; }
    float renderScale() const { return scale_; }
    int renderWidth() const { return rw_; }
    int renderHeight() const { return rh_; }

private:
    bool buildPipeline(const std::string& path);
    bool ensureSceneTexture(unsigned w, unsigned h);
    void adaptResolution(float dt);

    SDL_Window* window_ = nullptr;
    SDL_GPUDevice* device_ = nullptr;
    SDL_GPUGraphicsPipeline* pipeline_ = nullptr;

    // The scene is raymarched into an offscreen texture at a dynamic fraction of the
    // window resolution, then upscaled to the swapchain. This keeps the GPU (which the
    // macOS compositor shares) well below saturation.
    SDL_GPUTexture* scene_ = nullptr;
    unsigned sceneW_ = 0, sceneH_ = 0;
    int rw_ = 0, rh_ = 0;
    float scale_ = 0.5f, maxScale_ = 1.0f;
    float targetFps_ = 60.f, refreshHz_ = 60.f, dtAvg_ = 1.f / 60.f, adaptTimer_ = 0.f, raiseCooldown_ = 0.f;

    // Motion integrators: visuals accumulate music-driven velocity so they never jump.
    float time_ = 0, travel_ = 0, twist_ = 0, hue_ = 0, flash_ = 0;
    int lastBeat_ = 0;
};

} // namespace choreo
