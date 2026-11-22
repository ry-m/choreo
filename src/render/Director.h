#pragma once
// Scene director: turns MusicState into what the GPU draws. It owns the current scene, palette and
// camera, blends everything continuously within a section, and changes things on the beat when the
// music changes (the visual contract in docs/ROADMAP.md, M3 status):
//   sectionLift                      -> instant hit (flash, burst, camera kick, glass shatter); harmless if wrong
//   sectionLift with liftProb >= cut -> hard switch (scene, palette, camera) on that downbeat, under the flash
//   sectionLiftConfirmed             -> hard switch one beat later (still under the lift's flash) if not already cut
//   sectionChange / sectionConfirmed -> smaller transition: next palette in the family, new camera angle, variant
//   barPhase / downbeat / beatsSinceSection -> phrase motion, 4-bar accents, build-up tension
//   no cut for 24+ bars                -> cut on a plain section change or the next 8-bar phrase start (32 bars max)
// Pure CPU code with no GPU dependency, so the offline renderer and tests can drive it.
#include "analysis/MusicState.h"
#include "render/Scenes.h"
#include <algorithm>
#include <cstdint>
#include <string>
#include <vector>

namespace choreo {

// Must match `Frame` in shaders/common.metal (float4 members only, for alignment).
struct SceneUniforms {
    float res[4];    // render width, height, time (s), time since the scene started (s)
    float rhythm[4]; // beatPhase, barPhase, beatPulse, barPulse (1 on a downbeat, decays over a beat)
    float hits[4];   // kick, snare, hat, onset
    float spec[4];   // bass, mid, treble, loudness (lightly smoothed)
    float dyn[4];    // energy (slow loudness), intensity (section level), build (0..1 tension), brightness
    float motion[4]; // travel (distance), spin (angle), orbit (angle), camKick (impulse)
    float cam[4];    // camera preset (eased, fractional while moving), shake, roll, fov punch
    float fx[4];     // flash, burst age (s since the last hit; large = none), shatter, strobe
    float look[4];   // variant (eased), seed, hue drift, beat present (0/1)
    float pal[4][4]; // cosine palette a, b, c, d (xyz)
};

// Post-processing controls for this frame.
struct PostLook {
    float trails = 0.4f, trailZoom = 0.f, trailRot = 0.f;
    float bloom = 1.f, chroma = 0.5f, exposure = 1.f, flash = 0.f, grain = 0.04f;
};

class Director {
public:
    Director();
    // Call once per displayed frame with the state the listener is hearing now (Analyzer::stateAt).
    void update(const MusicState& m, float dt);

    int scene() const { return scene_; }
    const SceneUniforms& uniforms() const { return u_; }
    const PostLook& post() const { return post_; }
    void setRenderSize(int w, int h) { u_.res[0] = float(w); u_.res[1] = float(h); }

    // Pin one scene (bench / screenshots); -1 = director's choice.
    void forceScene(int s);
    float cutProb = 0.9f; // liftProb at or above which a lift cuts immediately (CHOREO_CUT_PROB)

    // Offline instrumentation: everything the director did, in audio time.
    struct Event {
        double time;      // audio time of the frame where it happened
        const char* kind; // "cut", "hit", "change", "phrase"
        std::string why;
        int scene, beatCount, beatInBar;
        float prob;
    };
    bool recordEvents = false;
    std::vector<Event> events;

private:
    void hit(const MusicState& m, float strength, const char* why);
    void cut(const MusicState& m, const std::string& why);
    void smallChange(const MusicState& m, const char* why);
    void log(const MusicState& m, const char* kind, const std::string& why, float prob = 0);
    uint32_t rand();
    float beatSec(const MusicState& m) const { return 60.f / std::max(40.f, m.bpm); }

    SceneUniforms u_{};
    PostLook post_;
    uint32_t rng_ = 0x9e3779b9u;
    bool started_ = false;
    int scene_ = 0, forced_ = -1, variant_ = 0, palIdx_ = 0, camPreset_ = 0;
    int lastUse_[kSceneCount] = {};
    int cuts_ = 0;

    // Event bookkeeping (in beats, via MusicState::beatCount).
    int lastBeat_ = 0, lastCutBeat_ = -1000, liftBeat_ = -1000, changeBeat_ = -1000, barsSinceCut_ = 0;
    int nLift_ = 0, nChange_ = 0, nConf_ = 0, nLiftConf_ = 0;

    // Continuous state.
    float time_ = 0, sceneTime_ = 0;
    float energy_ = 0, bass_ = 0, mid_ = 0, treble_ = 0, loud_ = 0, bright_ = 0, liftBoost_ = 0, build_ = 0;
    float barPulse_ = 0, flash_ = 0, flashTau_ = 0.2f, burstAge_ = 100.f, shatter_ = 0, camKick_ = 0, fovPunch_ = 0;
    float travel_ = 0, spin_ = 0, orbit_ = 0, roll_ = 0, rollTarget_ = 0;
    float camEase_ = 0, variantEase_ = 0, hue_ = 0, seed_ = 0;
    float pal_[16] = {}, palTarget_[16] = {}, palTau_ = 2.f;
};

} // namespace choreo
