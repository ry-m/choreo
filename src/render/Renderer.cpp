#include "render/Renderer.h"
#include <SDL3/SDL.h>
#include <algorithm>
#include <cmath>
#include <fstream>
#include <cstring>
#include <initializer_list>
#include <sstream>

namespace choreo {

namespace {
constexpr float kMinScale = 0.25f;
constexpr SDL_GPUTextureFormat kHdr = SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT;
enum Post { kFeedback, kPrefilter, kDown, kUp, kFinal, kCalibrate, kPostCount };
const char* kPostEntry[kPostCount] = {"fs_feedback", "fs_prefilter", "fs_down", "fs_up", "fs_final", "fs_calibrate"};
const int kPostSamplers[kPostCount] = {2, 1, 1, 2, 2, 0};

// Must match `PostU` in shaders/post.metal.
struct PostUniforms {
    float src0[4]; // uv scale of input 0 (active region / texture size), texel size of input 0
    float src1[4];
    float p0[4], p1[4], p2[4];
};

bool readFile(const std::string& path, std::string& out) {
    std::ifstream f(path);
    if (!f) { SDL_Log("Cannot open shader %s", path.c_str()); return false; }
    std::stringstream ss; ss << f.rdbuf();
    out = ss.str();
    return true;
}

void region(float* dst, unsigned activeW, unsigned activeH, unsigned texW, unsigned texH) {
    dst[0] = float(activeW) / float(texW); dst[1] = float(activeH) / float(texH);
    dst[2] = 1.f / float(texW); dst[3] = 1.f / float(texH);
}
} // namespace

bool Renderer::init(SDL_GPUDevice* device, int outFormat, const std::string& shaderDir) {
    device_ = device;
    outFormat_ = outFormat;
    shaderDir_ = shaderDir;
    SDL_GPUSamplerCreateInfo si{};
    si.min_filter = si.mag_filter = SDL_GPU_FILTER_LINEAR;
    si.mipmap_mode = SDL_GPU_SAMPLERMIPMAPMODE_NEAREST;
    si.address_mode_u = si.address_mode_v = si.address_mode_w = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    linear_ = SDL_CreateGPUSampler(device_, &si);
    si.address_mode_v = SDL_GPU_SAMPLERADDRESSMODE_REPEAT;
    ring_ = SDL_CreateGPUSampler(device_, &si);

    SDL_GPUTextureCreateInfo ti{};
    ti.type = SDL_GPU_TEXTURETYPE_2D;
    ti.format = kHdr;
    ti.usage = SDL_GPU_TEXTUREUSAGE_SAMPLER;
    ti.width = kHistCols; ti.height = kHistRows;
    ti.layer_count_or_depth = 1; ti.num_levels = 1;
    history_tex_ = SDL_CreateGPUTexture(device_, &ti);
    SDL_GPUTransferBufferCreateInfo bi{};
    bi.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
    bi.size = kHistCols * kHistRows * 4 * sizeof(_Float16);
    histUpload_ = SDL_CreateGPUTransferBuffer(device_, &bi);
    if (!history_tex_ || !histUpload_ || !ring_) { SDL_Log("History texture: %s", SDL_GetError()); return false; }
    // Start from silence (texture contents are undefined until written).
    std::vector<HistoryRow> zero(kHistRows);
    std::memset(zero.data(), 0, zero.size() * sizeof(HistoryRow));
    if (SDL_GPUCommandBuffer* cmd = SDL_AcquireGPUCommandBuffer(device_)) {
        uploadHistory(cmd, zero.data(), kHistRows, 0);
        SDL_SubmitGPUCommandBuffer(cmd);
    }
    return linear_ && buildAll(scenes_, post_);
}

SDL_GPUGraphicsPipeline* Renderer::makePipeline(const std::string& src, const char* entry, int format, int samplers,
                                                const std::string& what) {
    SDL_GPUShaderCreateInfo vs{};
    vs.code = reinterpret_cast<const Uint8*>(src.c_str());
    vs.code_size = src.size();
    vs.entrypoint = "vmain";
    vs.format = SDL_GPU_SHADERFORMAT_MSL;
    vs.stage = SDL_GPU_SHADERSTAGE_VERTEX;
    SDL_GPUShaderCreateInfo fs = vs;
    fs.entrypoint = entry;
    fs.stage = SDL_GPU_SHADERSTAGE_FRAGMENT;
    fs.num_uniform_buffers = 1;
    fs.num_samplers = Uint32(samplers);
    SDL_GPUShader* v = SDL_CreateGPUShader(device_, &vs);
    SDL_GPUShader* p = v ? SDL_CreateGPUShader(device_, &fs) : nullptr;
    if (!v || !p) {
        SDL_Log("Shader compile failed (%s): %s", what.c_str(), SDL_GetError());
        if (v) SDL_ReleaseGPUShader(device_, v);
        return nullptr;
    }
    SDL_GPUColorTargetDescription ct{};
    ct.format = SDL_GPUTextureFormat(format);
    SDL_GPUGraphicsPipelineCreateInfo pi{};
    pi.vertex_shader = v;
    pi.fragment_shader = p;
    pi.primitive_type = SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
    pi.target_info.num_color_targets = 1;
    pi.target_info.color_target_descriptions = &ct;
    SDL_GPUGraphicsPipeline* pipe = SDL_CreateGPUGraphicsPipeline(device_, &pi);
    SDL_ReleaseGPUShader(device_, v);
    SDL_ReleaseGPUShader(device_, p);
    if (!pipe) SDL_Log("Pipeline creation failed (%s): %s", what.c_str(), SDL_GetError());
    return pipe;
}

bool Renderer::buildAll(std::vector<SDL_GPUGraphicsPipeline*>& scenes, std::vector<SDL_GPUGraphicsPipeline*>& post) {
    std::string common, src;
    if (!readFile(shaderDir_ + "/common.metal", common)) return false;
    bool ok = true;
    for (int i = 0; i < kSceneCount && ok; ++i) {
        std::string file = shaderDir_ + "/scene_" + kScenes[i].id + ".metal";
        ok = readFile(file, src);
        SDL_GPUGraphicsPipeline* p = ok ? makePipeline(common + src, "fmain", kHdr, 1, file) : nullptr;
        scenes.push_back(p);
        ok = p != nullptr;
    }
    if (ok && readFile(shaderDir_ + "/post.metal", src)) {
        for (int i = 0; i < kPostCount && ok; ++i) {
            int fmt = (i == kFinal || i == kCalibrate) ? outFormat_ : int(kHdr);
            SDL_GPUGraphicsPipeline* p = makePipeline(common + src, kPostEntry[i], fmt, kPostSamplers[i], kPostEntry[i]);
            post.push_back(p);
            ok = p != nullptr;
        }
    } else {
        ok = false;
    }
    if (!ok) {
        for (auto* p : scenes) if (p) SDL_ReleaseGPUGraphicsPipeline(device_, p);
        for (auto* p : post) if (p) SDL_ReleaseGPUGraphicsPipeline(device_, p);
        scenes.clear(); post.clear();
    }
    return ok;
}

bool Renderer::reloadShaders() {
    std::vector<SDL_GPUGraphicsPipeline*> s, p;
    if (!buildAll(s, p)) { SDL_Log("Shader reload failed; keeping the previous shaders"); return false; }
    SDL_WaitForGPUIdle(device_);
    for (auto* x : scenes_) SDL_ReleaseGPUGraphicsPipeline(device_, x);
    for (auto* x : post_) SDL_ReleaseGPUGraphicsPipeline(device_, x);
    scenes_ = s; post_ = p;
    SDL_Log("Shaders reloaded");
    return true;
}

void Renderer::releaseTargets() {
    auto rel = [&](SDL_GPUTexture*& t) { if (t) SDL_ReleaseGPUTexture(device_, t); t = nullptr; };
    rel(scene_); rel(history_[0]); rel(history_[1]);
    for (int i = 0; i < kBloomLevels; ++i) { rel(down_[i]); rel(up_[i]); }
}

bool Renderer::ensureTargets(unsigned w, unsigned h) {
    if (scene_ && outW_ == w && outH_ == h) return true;
    releaseTargets();
    outW_ = w; outH_ = h;
    // Never raymarch more than maxPixels_, however big the display is.
    maxScale_ = std::min(1.f, std::sqrt(maxPixels_ / float(w * h)));
    if (!fixedScale_) scale_ = std::min(scale_, maxScale_);
    texW_ = std::max(1u, unsigned(std::ceil(w * std::max(maxScale_, fixedScale_ ? scale_ : 0.f))));
    texH_ = std::max(1u, unsigned(std::ceil(h * std::max(maxScale_, fixedScale_ ? scale_ : 0.f))));
    auto make = [&](unsigned tw, unsigned th) {
        SDL_GPUTextureCreateInfo ti{};
        ti.type = SDL_GPU_TEXTURETYPE_2D;
        ti.format = kHdr;
        ti.usage = SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | SDL_GPU_TEXTUREUSAGE_SAMPLER;
        ti.width = tw; ti.height = th;
        ti.layer_count_or_depth = 1;
        ti.num_levels = 1;
        ti.sample_count = SDL_GPU_SAMPLECOUNT_1;
        return SDL_CreateGPUTexture(device_, &ti);
    };
    scene_ = make(texW_, texH_);
    history_[0] = make(texW_, texH_);
    history_[1] = make(texW_, texH_);
    bool ok = scene_ && history_[0] && history_[1];
    for (int i = 0; i < kBloomLevels; ++i) {
        levelW_[i] = std::max(1u, texW_ >> (i + 1));
        levelH_[i] = std::max(1u, texH_ >> (i + 1));
        down_[i] = make(levelW_[i], levelH_[i]);
        up_[i] = make(levelW_[i], levelH_[i]);
        ok = ok && down_[i] && up_[i];
    }
    historyValid_ = false;
    if (!ok) SDL_Log("Render target allocation failed: %s", SDL_GetError());
    return ok;
}

// Dynamic resolution: keep frame time at the display refresh. Drop quickly when over budget,
// creep back up slowly, and wait a while after a drop to avoid oscillating.
void Renderer::adaptResolution(float dt, float targetFps, float refreshHz) {
    if (fixedScale_) return;
    dt = std::min(dt, 0.1f);
    dtAvg_ += (dt - dtAvg_) * 0.1f;
    adaptTimer_ += dt;
    raiseCooldown_ = std::max(0.f, raiseCooldown_ - dt);
    if (adaptTimer_ < 0.25f) return;
    adaptTimer_ = 0.f;
    const float budget = 1.f / std::min(targetFps, refreshHz);
    if (dtAvg_ > budget * 1.2f) {
        scale_ = std::max(kMinScale, scale_ * 0.85f);
        raiseCooldown_ = 3.f;
    } else if (dtAvg_ < budget * 1.05f && raiseCooldown_ <= 0.f) {
        scale_ = std::min(maxScale_, scale_ * 1.04f);
    }
}

void Renderer::render(SDL_GPUCommandBuffer* cmd, SDL_GPUTexture* target, unsigned w, unsigned h, int scene,
                      const SceneUniforms& uIn, const PostLook& look) {
    if (scenes_.empty() || !ensureTargets(w, h)) return;
    scene = std::clamp(scene, 0, kSceneCount - 1);
    rw_ = std::clamp(int(std::lround(w * scale_)), 1, int(texW_));
    rh_ = std::clamp(int(std::lround(h * scale_)), 1, int(texH_));
    SceneUniforms u = uIn;
    u.res[0] = float(rw_); u.res[1] = float(rh_);

    auto pass = [&](SDL_GPUTexture* dst, unsigned vw, unsigned vh, SDL_GPUGraphicsPipeline* pipe,
                    std::initializer_list<SDL_GPUTexture*> srcs, const void* ubo, Uint32 size, bool clear = false,
                    SDL_GPUSampler* sampler = nullptr) {
        SDL_GPUColorTargetInfo t{};
        t.texture = dst;
        t.load_op = clear ? SDL_GPU_LOADOP_CLEAR : SDL_GPU_LOADOP_DONT_CARE;
        t.store_op = SDL_GPU_STOREOP_STORE;
        SDL_GPURenderPass* rp = SDL_BeginGPURenderPass(cmd, &t, 1, nullptr);
        if (!pipe) { SDL_EndGPURenderPass(rp); return; }
        SDL_GPUViewport vp{0, 0, float(vw), float(vh), 0, 1};
        SDL_SetGPUViewport(rp, &vp);
        SDL_BindGPUGraphicsPipeline(rp, pipe);
        SDL_GPUTextureSamplerBinding b[2]{};
        Uint32 nb = 0;
        for (SDL_GPUTexture* s : srcs) { b[nb].texture = s; b[nb].sampler = sampler ? sampler : linear_; ++nb; }
        if (nb) SDL_BindGPUFragmentSamplers(rp, 0, b, nb);
        SDL_PushGPUFragmentUniformData(cmd, 0, ubo, size);
        SDL_DrawGPUPrimitives(rp, 3, 1, 0, 0);
        SDL_EndGPURenderPass(rp);
    };

    if (!historyValid_) {
        // Trails need a defined previous frame (garbage could be NaN, which survives a zero weight).
        for (SDL_GPUTexture* t : history_) pass(t, texW_, texH_, nullptr, {}, nullptr, 0, true);
        historyValid_ = true;
    }
    const int prev = cur_;
    cur_ ^= 1;

    // 1) Scene, raymarched in HDR into the top-left rw x rh of the scene texture.
    pass(scene_, rw_, rh_, scenes_[scene], {history_tex_}, &u, sizeof u, false, ring_);

    // 2) Feedback: blend the warped previous frame into the new one.
    PostUniforms pu{};
    region(pu.src0, rw_, rh_, texW_, texH_);
    region(pu.src1, rw_, rh_, texW_, texH_);
    pu.p0[0] = look.trails; pu.p0[1] = look.trailZoom; pu.p0[2] = look.trailRot; pu.p0[3] = float(rw_) / float(rh_);
    pass(history_[cur_], rw_, rh_, post_[kFeedback], {scene_, history_[prev]}, &pu, sizeof pu);

    // 3) Bloom: prefilter to half resolution, then down to 1/32, then back up (tent filter).
    unsigned lw[kBloomLevels], lh[kBloomLevels];
    for (int i = 0; i < kBloomLevels; ++i) { lw[i] = std::max(1, rw_ >> (i + 1)); lh[i] = std::max(1, rh_ >> (i + 1)); }
    pu = {};
    region(pu.src0, rw_, rh_, texW_, texH_);
    pu.p0[0] = 0.9f; pu.p0[1] = 0.6f;  // threshold, soft knee
    pass(down_[0], lw[0], lh[0], post_[kPrefilter], {history_[cur_]}, &pu, sizeof pu);
    for (int i = 1; i < kBloomLevels; ++i) {
        pu = {};
        region(pu.src0, lw[i - 1], lh[i - 1], levelW_[i - 1], levelH_[i - 1]);
        pass(down_[i], lw[i], lh[i], post_[kDown], {down_[i - 1]}, &pu, sizeof pu);
    }
    SDL_GPUTexture* upper = down_[kBloomLevels - 1];
    for (int i = kBloomLevels - 2; i >= 0; --i) {
        pu = {};
        region(pu.src0, lw[i], lh[i], levelW_[i], levelH_[i]);
        region(pu.src1, lw[i + 1], lh[i + 1], levelW_[i + 1], levelH_[i + 1]);
        pu.p0[0] = 1.0f;  // weight of the coarser level
        pass(up_[i], lw[i], lh[i], post_[kUp], {down_[i], upper}, &pu, sizeof pu);
        upper = up_[i];
    }

    // 4) Final composite at full output resolution.
    pu = {};
    region(pu.src0, rw_, rh_, texW_, texH_);
    region(pu.src1, lw[0], lh[0], levelW_[0], levelH_[0]);
    pu.p0[0] = look.bloom; pu.p0[1] = look.chroma; pu.p0[2] = look.exposure; pu.p0[3] = look.flash;
    pu.p1[0] = look.grain; pu.p1[1] = u.res[2]; pu.p1[2] = float(w); pu.p1[3] = float(h);
    pass(target, w, h, post_[kFinal], {history_[cur_], upper}, &pu, sizeof pu);
}

void Renderer::uploadHistory(SDL_GPUCommandBuffer* cmd, const HistoryRow* rows, int count, long firstIndex) {
    if (count <= 0 || !histUpload_) return;
    if (count > kHistRows) { rows += count - kHistRows; firstIndex += count - kHistRows; count = kHistRows; }
    auto* dst = static_cast<_Float16*>(SDL_MapGPUTransferBuffer(device_, histUpload_, true));
    if (!dst) return;
    for (int r = 0; r < count; ++r)
        for (int c = 0; c < kHistCols; ++c)
            for (int k = 0; k < 4; ++k) dst[(size_t(r) * kHistCols + c) * 4 + k] = _Float16(rows[r].px[c][k]);
    SDL_UnmapGPUTransferBuffer(device_, histUpload_);
    SDL_GPUCopyPass* cp = SDL_BeginGPUCopyPass(cmd);
    // Rows go to ring positions (firstIndex + r) % kHistRows: at most two contiguous runs.
    int done = 0;
    while (done < count) {
        int row = int((firstIndex + done) % kHistRows);
        int run = std::min(count - done, kHistRows - row);
        SDL_GPUTextureTransferInfo src{};
        src.transfer_buffer = histUpload_;
        src.offset = Uint32(size_t(done) * kHistCols * 4 * sizeof(_Float16));
        SDL_GPUTextureRegion reg{};
        reg.texture = history_tex_;
        reg.y = Uint32(row); reg.w = kHistCols; reg.h = Uint32(run); reg.d = 1;
        SDL_UploadToGPUTexture(cp, &src, &reg, false);
        done += run;
    }
    SDL_EndGPUCopyPass(cp);
}

void Renderer::renderCalibration(SDL_GPUCommandBuffer* cmd, SDL_GPUTexture* target, unsigned w, unsigned h,
                                 float beatPhase, float bpm) {
    if (post_.empty()) return;
    PostUniforms pu{};
    pu.p0[0] = beatPhase; pu.p0[1] = bpm;
    SDL_GPUColorTargetInfo t{};
    t.texture = target;
    t.load_op = SDL_GPU_LOADOP_DONT_CARE;
    t.store_op = SDL_GPU_STOREOP_STORE;
    SDL_GPURenderPass* rp = SDL_BeginGPURenderPass(cmd, &t, 1, nullptr);
    SDL_GPUViewport vp{0, 0, float(w), float(h), 0, 1};
    SDL_SetGPUViewport(rp, &vp);
    SDL_BindGPUGraphicsPipeline(rp, post_[kCalibrate]);
    SDL_PushGPUFragmentUniformData(cmd, 0, &pu, sizeof pu);
    SDL_DrawGPUPrimitives(rp, 3, 1, 0, 0);
    SDL_EndGPURenderPass(rp);
}

void Renderer::shutdown() {
    if (!device_) return;
    releaseTargets();
    for (auto* p : scenes_) SDL_ReleaseGPUGraphicsPipeline(device_, p);
    for (auto* p : post_) SDL_ReleaseGPUGraphicsPipeline(device_, p);
    scenes_.clear(); post_.clear();
    if (linear_) SDL_ReleaseGPUSampler(device_, linear_);
    if (ring_) SDL_ReleaseGPUSampler(device_, ring_);
    if (history_tex_) SDL_ReleaseGPUTexture(device_, history_tex_);
    if (histUpload_) SDL_ReleaseGPUTransferBuffer(device_, histUpload_);
    linear_ = ring_ = nullptr; history_tex_ = nullptr; histUpload_ = nullptr;
    device_ = nullptr;
}

} // namespace choreo
