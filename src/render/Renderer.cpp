#include "render/Renderer.h"
#include <SDL3/SDL.h>
#include <algorithm>
#include <cmath>
#include <fstream>
#include <sstream>

namespace choreo {

namespace {
constexpr float kMinScale = 0.25f;
// Cap on raymarched pixels regardless of display size. Keeps the GPU at roughly half load
// at 60 fps on Apple silicon, leaving room for the compositor (and quiet fans).
constexpr float kMaxPixels = 1.5e6f;
} // namespace

bool Renderer::init(SDL_Window* window, const std::string& shaderDir) {
    window_ = window;
    device_ = SDL_CreateGPUDevice(SDL_GPU_SHADERFORMAT_MSL, false, nullptr);
    if (!device_) { SDL_Log("SDL_CreateGPUDevice failed: %s", SDL_GetError()); return false; }
    if (!SDL_ClaimWindowForGPUDevice(device_, window_)) { SDL_Log("Claim window failed: %s", SDL_GetError()); return false; }
    SDL_SetGPUSwapchainParameters(device_, window_, SDL_GPU_SWAPCHAINCOMPOSITION_SDR, SDL_GPU_PRESENTMODE_VSYNC);
    SDL_SetGPUAllowedFramesInFlight(device_, 2);

    if (const SDL_DisplayMode* dm = SDL_GetCurrentDisplayMode(SDL_GetDisplayForWindow(window_)))
        if (dm->refresh_rate > 1.f) refreshHz_ = dm->refresh_rate;
    dtAvg_ = 1.f / refreshHz_;
    SDL_Log("GPU driver: %s, display %.0f Hz", SDL_GetGPUDeviceDriver(device_), refreshHz_);
    return buildPipeline(shaderDir + "/tunnel.metal");
}

bool Renderer::buildPipeline(const std::string& path) {
    std::ifstream f(path);
    if (!f) { SDL_Log("Cannot open shader %s", path.c_str()); return false; }
    std::stringstream ss; ss << f.rdbuf();
    std::string src = ss.str();

    SDL_GPUShaderCreateInfo vs{};
    vs.code = reinterpret_cast<const Uint8*>(src.c_str());
    vs.code_size = src.size();
    vs.entrypoint = "vmain";
    vs.format = SDL_GPU_SHADERFORMAT_MSL;
    vs.stage = SDL_GPU_SHADERSTAGE_VERTEX;
    SDL_GPUShaderCreateInfo fs = vs;
    fs.entrypoint = "fmain";
    fs.stage = SDL_GPU_SHADERSTAGE_FRAGMENT;
    fs.num_uniform_buffers = 1;

    SDL_GPUShader* v = SDL_CreateGPUShader(device_, &vs);
    SDL_GPUShader* p = SDL_CreateGPUShader(device_, &fs);
    if (!v || !p) { SDL_Log("Shader compile failed: %s", SDL_GetError()); return false; }

    SDL_GPUColorTargetDescription ct{};
    ct.format = SDL_GetGPUSwapchainTextureFormat(device_, window_);
    SDL_GPUGraphicsPipelineCreateInfo pi{};
    pi.vertex_shader = v;
    pi.fragment_shader = p;
    pi.primitive_type = SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
    pi.target_info.num_color_targets = 1;
    pi.target_info.color_target_descriptions = &ct;
    pipeline_ = SDL_CreateGPUGraphicsPipeline(device_, &pi);
    SDL_ReleaseGPUShader(device_, v);
    SDL_ReleaseGPUShader(device_, p);
    if (!pipeline_) { SDL_Log("Pipeline creation failed: %s", SDL_GetError()); return false; }
    return true;
}

bool Renderer::ensureSceneTexture(unsigned w, unsigned h) {
    if (scene_ && sceneW_ == w && sceneH_ == h) return true;
    if (scene_) SDL_ReleaseGPUTexture(device_, scene_);
    SDL_GPUTextureCreateInfo ti{};
    ti.type = SDL_GPU_TEXTURETYPE_2D;
    ti.format = SDL_GetGPUSwapchainTextureFormat(device_, window_);
    ti.usage = SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | SDL_GPU_TEXTUREUSAGE_SAMPLER;
    ti.width = w;
    ti.height = h;
    ti.layer_count_or_depth = 1;
    ti.num_levels = 1;
    ti.sample_count = SDL_GPU_SAMPLECOUNT_1;
    scene_ = SDL_CreateGPUTexture(device_, &ti);
    sceneW_ = w; sceneH_ = h;
    // Never raymarch more than kMaxPixels, however big the display is.
    maxScale_ = std::min(1.f, std::sqrt(kMaxPixels / float(w * h)));
    scale_ = std::min(scale_, maxScale_);
    return scene_ != nullptr;
}

// Dynamic resolution: keep frame time at the display refresh. Drop quickly when over
// budget, creep back up slowly, and wait a while after a drop to avoid oscillating.
void Renderer::adaptResolution(float dt) {
    dtAvg_ += (dt - dtAvg_) * 0.1f;
    adaptTimer_ += dt;
    raiseCooldown_ = std::max(0.f, raiseCooldown_ - dt);
    if (adaptTimer_ < 0.25f) return;
    adaptTimer_ = 0.f;
    const float budget = 1.f / std::min(targetFps_, refreshHz_);
    if (dtAvg_ > budget * 1.2f) {
        scale_ = std::max(kMinScale, scale_ * 0.85f);
        raiseCooldown_ = 3.f;
    } else if (dtAvg_ < budget * 1.05f && raiseCooldown_ <= 0.f) {
        scale_ = std::min(maxScale_, scale_ * 1.04f);
    }
}

void Renderer::render(const MusicState& m, float dt) {
    dt = std::min(dt, 0.1f);
    time_ += dt;
    adaptResolution(dt);

    // Speed follows energy; kicks give a forward shove. Twist reacts to snares; hue drifts per beat.
    float speed = 1.0f + 3.0f * m.loudness * m.loudness + 2.5f * m.kick + 1.5f * std::max(0.f, m.energyRatio - 1.f);
    travel_ += speed * dt;
    twist_ += (0.15f + 1.2f * m.snare) * dt;
    if (m.beatCount != lastBeat_) {
        lastBeat_ = m.beatCount;
        if (m.beatCount % 16 == 0) hue_ += 0.25f;   // shift palette every 4 bars
        flash_ = 1.f;
    }
    hue_ += 0.01f * dt;
    flash_ *= std::exp(-dt / 0.12f);

    SDL_GPUCommandBuffer* cmd = SDL_AcquireGPUCommandBuffer(device_);
    if (!cmd) return;
    SDL_GPUTexture* swap = nullptr;
    Uint32 w = 0, h = 0;
    if (!SDL_WaitAndAcquireGPUSwapchainTexture(cmd, window_, &swap, &w, &h) || !swap || !ensureSceneTexture(w, h)) {
        SDL_SubmitGPUCommandBuffer(cmd);
        return;
    }
    rw_ = std::max(1, int(w * scale_));
    rh_ = std::max(1, int(h * scale_));

    FrameUniforms u{
        {float(rw_), float(rh_), time_, m.beatPhase},
        {m.beatPulse, m.kick, m.snare, m.hat},
        {m.bass, m.mid, m.treble, m.loudness},
        {m.energyRatio, m.brightness, m.bpm, float(m.beatCount)},
        {travel_, twist_, hue_, flash_},
    };

    // 1) Raymarch into the top-left rw_ x rh_ region of the scene texture.
    SDL_GPUColorTargetInfo target{};
    target.texture = scene_;
    target.load_op = SDL_GPU_LOADOP_DONT_CARE;
    target.store_op = SDL_GPU_STOREOP_STORE;
    SDL_GPURenderPass* pass = SDL_BeginGPURenderPass(cmd, &target, 1, nullptr);
    SDL_GPUViewport vp{0, 0, float(rw_), float(rh_), 0, 1};
    SDL_SetGPUViewport(pass, &vp);
    SDL_BindGPUGraphicsPipeline(pass, pipeline_);
    SDL_PushGPUFragmentUniformData(cmd, 0, &u, sizeof(u));
    SDL_DrawGPUPrimitives(pass, 3, 1, 0, 0);
    SDL_EndGPURenderPass(pass);

    // 2) Upscale to the window with bilinear filtering.
    SDL_GPUBlitInfo blit{};
    blit.source.texture = scene_;
    blit.source.w = Uint32(rw_);
    blit.source.h = Uint32(rh_);
    blit.destination.texture = swap;
    blit.destination.w = w;
    blit.destination.h = h;
    blit.load_op = SDL_GPU_LOADOP_DONT_CARE;
    blit.filter = SDL_GPU_FILTER_LINEAR;
    SDL_BlitGPUTexture(cmd, &blit);
    SDL_SubmitGPUCommandBuffer(cmd);
}

void Renderer::shutdown() {
    if (scene_) SDL_ReleaseGPUTexture(device_, scene_);
    if (pipeline_) SDL_ReleaseGPUGraphicsPipeline(device_, pipeline_);
    if (device_) { SDL_ReleaseWindowFromGPUDevice(device_, window_); SDL_DestroyGPUDevice(device_); }
    scene_ = nullptr; pipeline_ = nullptr; device_ = nullptr;
}

} // namespace choreo
