#pragma once
// SDL_GPU render graph: scene (raymarched, HDR, dynamic resolution) -> feedback/trails -> bloom
// (soft-threshold prefilter, 5-level down/up chain) -> final composite (chromatic aberration, flash,
// ACES tonemap, vignette, grain/dither) into any 8-bit target: the swapchain live, or an offscreen
// texture for the offline renderer. Shaders are MSL compiled at runtime: shaders/common.metal is
// prepended to every scene_<id>.metal, post.metal holds the post passes.
#include "render/Director.h"
#include <string>
#include <vector>

struct SDL_GPUDevice;
struct SDL_GPUGraphicsPipeline;
struct SDL_GPUTexture;
struct SDL_GPUSampler;
struct SDL_GPUCommandBuffer;
struct SDL_GPUTransferBuffer;

namespace choreo {

class Renderer {
public:
    // outFormat: format of the textures passed to render() (an SDL_GPUTextureFormat).
    bool init(SDL_GPUDevice* device, int outFormat, const std::string& shaderDir);
    bool reloadShaders();  // hot reload; keeps the old pipelines if anything fails to compile
    void shutdown();

    // Records every pass into cmd; the final image goes to `target` (w x h).
    void render(SDL_GPUCommandBuffer* cmd, SDL_GPUTexture* target, unsigned w, unsigned h, int scene,
                const SceneUniforms& u, const PostLook& post);
    // Upload history rows (Director::newRows) into the ring texture; `firstIndex` is the running
    // count of the first row (Director::rowsWritten() - rows.size()). Call before render() in the same cmd.
    void uploadHistory(SDL_GPUCommandBuffer* cmd, const HistoryRow* rows, int count, long firstIndex);
    // Calibration display (A/V sync): plain flash on each beat plus a beat-phase bar, no post.
    void renderCalibration(SDL_GPUCommandBuffer* cmd, SDL_GPUTexture* target, unsigned w, unsigned h,
                           float beatPhase, float bpm);

    // Dynamic resolution: call once per frame with the measured frame time.
    void adaptResolution(float dt, float targetFps, float refreshHz);
    void setScale(float s) { scale_ = s; fixedScale_ = true; }
    void resetHistory() { historyValid_ = false; }  // next frame starts without trails (after a seek)
    // Cap on raymarched pixels regardless of display size (keeps the GPU at roughly half load).
    void setMaxPixels(float px) { maxPixels_ = px; }
    float renderScale() const { return scale_; }
    int renderWidth() const { return rw_; }
    int renderHeight() const { return rh_; }

private:
    SDL_GPUGraphicsPipeline* makePipeline(const std::string& src, const char* entry, int format,
                                          int samplers, const std::string& what);
    bool buildAll(std::vector<SDL_GPUGraphicsPipeline*>& scenes, std::vector<SDL_GPUGraphicsPipeline*>& post);
    bool ensureTargets(unsigned w, unsigned h);
    void releaseTargets();

    SDL_GPUDevice* device_ = nullptr;
    int outFormat_ = 0;
    std::string shaderDir_;
    std::vector<SDL_GPUGraphicsPipeline*> scenes_;  // one per kScenes entry
    // post_: feedback, prefilter, down, up, final, calibrate
    std::vector<SDL_GPUGraphicsPipeline*> post_;
    SDL_GPUSampler* linear_ = nullptr;
    SDL_GPUSampler* ring_ = nullptr;           // linear, clamp in x, repeat in y (history ring)
    SDL_GPUTexture* history_tex_ = nullptr;    // kHistCols x kHistRows RGBA16F
    SDL_GPUTransferBuffer* histUpload_ = nullptr;
    SDL_GPUTexture* noise_ = nullptr;          // kNoiseSize^3 RGBA8 tileable noise volume (texture 1 of every scene)
    SDL_GPUSampler* wrap_ = nullptr;           // linear, repeat in all axes
    bool makeNoise();

    static constexpr int kBloomLevels = 5;
    SDL_GPUTexture* scene_ = nullptr;
    SDL_GPUTexture* history_[2] = {};
    SDL_GPUTexture* down_[kBloomLevels] = {};
    SDL_GPUTexture* up_[kBloomLevels] = {};
    unsigned outW_ = 0, outH_ = 0, texW_ = 0, texH_ = 0;
    unsigned levelW_[kBloomLevels] = {}, levelH_[kBloomLevels] = {};
    int cur_ = 0;
    bool historyValid_ = false;

    int rw_ = 0, rh_ = 0;
    float scale_ = 0.6f, maxScale_ = 1.f, maxPixels_ = 1.5e6f;
    bool fixedScale_ = false;
    float dtAvg_ = 1.f / 60.f, adaptTimer_ = 0.f, raiseCooldown_ = 0.f;
};

} // namespace choreo
