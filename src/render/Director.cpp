#include "render/Director.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace choreo {

namespace {
// Exponential follower with separate attack and release time constants (seconds).
float follow(float cur, float target, float attack, float release, float dt) {
    float tau = target > cur ? attack : release;
    return cur + (target - cur) * (1.f - std::exp(-dt / std::max(tau, 1e-4f)));
}
float decay(float v, float tau, float dt) { return v * std::exp(-dt / std::max(tau, 1e-4f)); }
float clamp01(float x) { return std::min(1.f, std::max(0.f, x)); }

constexpr int kMinBeatsBetweenCuts = 8;  // the detector itself fires >= 8 beats apart per head
// Quiet stretches: the section detector can stay silent for minutes (or there is no section model).
// After kLongBars without a cut, a plain section change cuts, else the next 8-bar phrase start
// (counted from the last section event) does; by kMaxBars any downbeat does.
constexpr int kLongBars = 24;
constexpr int kMaxBars = 32;
} // namespace

Director::Director() {
    if (const char* e = std::getenv("CHOREO_CUT_PROB")) cutProb = float(std::atof(e));
    std::memcpy(pal_, &kScenes[0].palettes[0], sizeof pal_);
    std::memcpy(palTarget_, pal_, sizeof pal_);
}

uint32_t Director::rand() {
    rng_ ^= rng_ << 13; rng_ ^= rng_ >> 17; rng_ ^= rng_ << 5;
    return rng_;
}

void Director::forceScene(int s) {
    forced_ = s;
    if (s >= 0 && s < kSceneCount) {
        scene_ = s;
        std::memcpy(palTarget_, &kScenes[s].palettes[palIdx_ % 4], sizeof palTarget_);
        std::memcpy(pal_, palTarget_, sizeof pal_);
    }
}

void Director::log(const MusicState& m, const char* kind, const std::string& why, float prob) {
    if (recordEvents) events.push_back({m.time, kind, why, scene_, m.beatCount, m.beatInBar, prob});
}

// "Maybe a big moment now": everything here decays within about a beat, so a false alarm is just a flash.
void Director::hit(const MusicState& m, float strength, const char* why) {
    flash_ = std::max(flash_, strength);
    flashTau_ = 0.55f * beatSec(m);   // still ~16% at the next beat, where a confirmed cut lands
    burstAge_ = 0.f;
    shatter_ = std::max(shatter_, strength);
    camKick_ = std::max(camKick_, strength);
    fovPunch_ = std::max(fovPunch_, strength);
    log(m, "hit", why, m.liftProb);
}

// Hard switch: new scene, palette and camera, all at once on this beat.
void Director::cut(const MusicState& m, const std::string& why) {
    if (forced_ < 0) {
        // The scene used least recently (ties broken at random), never the current one.
        int best = -1;
        for (int k = 0, start = int(rand() % kSceneCount); k < kSceneCount; ++k) {
            int s = (start + k) % kSceneCount;
            if (s == scene_) continue;
            if (best < 0 || lastUse_[s] < lastUse_[best]) best = s;
        }
        if (best >= 0) scene_ = best;
    }
    lastUse_[scene_] = ++cuts_;
    variant_ = int(rand() % 4);
    palIdx_ = int(rand() % 4);
    camPreset_ = int(rand() % 4);
    camEase_ = float(camPreset_);
    variantEase_ = float(variant_);
    seed_ = float(rand() % 1000) / 1000.f;
    std::memcpy(palTarget_, &kScenes[scene_].palettes[palIdx_], sizeof palTarget_);
    std::memcpy(pal_, palTarget_, sizeof pal_);   // instant: the cut is the change
    sceneTime_ = 0.f;
    flash_ = std::max(flash_, 0.8f);
    lastCutBeat_ = m.beatCount;
    barsSinceCut_ = 0;
    log(m, "cut", why, m.liftProb);
}

// Smaller transition inside the same scene: next palette (blended over ~a beat), new camera
// angle (eased), next geometry variant, a modest flash.
void Director::smallChange(const MusicState& m, const char* why) {
    palIdx_ = (palIdx_ + 1 + int(rand() % 2)) % 4;
    std::memcpy(palTarget_, &kScenes[scene_].palettes[palIdx_], sizeof palTarget_);
    palTau_ = 0.35f * beatSec(m);
    camPreset_ = (camPreset_ + 1 + int(rand() % 3)) % 4;
    variant_ = (variant_ + 1) % 4;
    flash_ = std::max(flash_, 0.35f);
    flashTau_ = 0.3f * beatSec(m);
    burstAge_ = 0.f;
    changeBeat_ = m.beatCount;
    log(m, "change", why, m.sectionProb);
}

void Director::update(const MusicState& m, float dt) {
    dt = std::min(std::max(dt, 0.f), 0.1f);
    time_ += dt;
    sceneTime_ += dt;
    const float B = beatSec(m);

    if (!started_) {
        // Adopt the analyser's running counts without treating them as new events.
        started_ = true;
        lastBeat_ = m.beatCount;
        nLift_ = m.sectionLifts; nChange_ = m.sectionChanges; nConf_ = m.sectionConfirms; nLiftConf_ = m.liftConfirms;
        lastUse_[scene_] = ++cuts_;
    }

    // ---- Continuous dynamics -------------------------------------------------------------
    energy_ = follow(energy_, m.loudness, 0.4f, 2.5f, dt);
    loud_ = follow(loud_, m.loudness, 0.05f, 0.3f, dt);
    bass_ = follow(bass_, m.bass, 0.02f, 0.18f, dt);
    mid_ = follow(mid_, m.mid, 0.03f, 0.25f, dt);
    treble_ = follow(treble_, m.treble, 0.02f, 0.2f, dt);
    bright_ = follow(bright_, m.brightness, 1.0f, 1.0f, dt);

    // ---- Beats and bars ------------------------------------------------------------------
    const bool newBeat = m.beatCount > lastBeat_;
    bool downbeat = false;
    if (newBeat) {
        lastBeat_ = m.beatCount;
        downbeat = m.beatInBar == 0;
        if (downbeat) {
            barPulse_ = 1.f;
            ++barsSinceCut_;
            // Flight: the camera leans the other way every bar (phrase-level camera language).
            rollTarget_ = -rollTarget_ + (rollTarget_ == 0 ? 0.25f : 0.f);
        }
    }

    // ---- Section events (counts, so a frame can't miss them) -----------------------------
    const bool lift = m.sectionLifts != nLift_, change = m.sectionChanges != nChange_;
    const bool conf = m.sectionConfirms != nConf_, liftConf = m.liftConfirms != nLiftConf_;
    nLift_ = m.sectionLifts; nChange_ = m.sectionChanges; nConf_ = m.sectionConfirms; nLiftConf_ = m.liftConfirms;
    const int n = m.beatCount;
    const bool canCut = n - lastCutBeat_ >= kMinBeatsBetweenCuts;
    char why[96];

    if (lift) {
        hit(m, 1.f, "lift");
        liftBeat_ = n;
        liftBoost_ = 1.f;
        if (m.liftProb >= cutProb && canCut) {
            std::snprintf(why, sizeof why, "lift p=%.2f", m.liftProb);
            cut(m, why);
        }
    }
    if (liftConf && lastCutBeat_ != n - 1 && lastCutBeat_ != n && canCut) {
        // Lands on the beat after the section's downbeat, while the lift's flash is still up.
        if (liftBeat_ != n - 1) hit(m, 1.f, "late lift");
        liftBoost_ = 1.f;
        cut(m, liftBeat_ == n - 1 ? "lift confirmed" : "lift confirmed (unannounced)");
    }
    if (change && !lift && lastCutBeat_ != n) {
        if (barsSinceCut_ >= kLongBars && canCut) cut(m, "change after a long section");
        else smallChange(m, "change");
    }
    if (conf && !liftConf && changeBeat_ != n - 1 && lastCutBeat_ != n - 1 && lastCutBeat_ != n) {
        if (barsSinceCut_ >= kLongBars && canCut) cut(m, "confirmed after a long section");
        else smallChange(m, "change confirmed");
    }
    // Nothing from the detector for a long time: keep the show moving on a phrase boundary.
    if (downbeat && m.beatPresent && canCut && lastCutBeat_ != n) {
        const int bpb0 = std::max(1, m.beatsPerBar);
        const bool phraseStart = m.beatsSinceSection > 0 && m.beatsSinceSection % (8 * bpb0) == 0;
        if (barsSinceCut_ >= kMaxBars) cut(m, "quiet: 40 bars");
        else if (barsSinceCut_ >= kLongBars && phraseStart) cut(m, "quiet: 8-bar phrase");
    }

    // Phrase accents: every 4 bars from the section start, a small camera move on the downbeat.
    const int bpb = std::max(1, m.beatsPerBar);
    if (downbeat && m.beatsSinceSection > 0 && m.beatsSinceSection % (4 * bpb) == 0 && lastCutBeat_ != n && changeBeat_ != n) {
        camPreset_ = (camPreset_ + 1) % 4;
        barPulse_ = 1.5f;
        log(m, "phrase", "4 bars");
    }

    // ---- Build-up: tension through each 8-bar phrase of the section, more when energy rises --
    const float barsIn = float(m.beatsSinceSection) / bpb + (m.beatPresent ? m.barPhase : 0.f);
    const float phrase = std::fmod(barsIn, 8.f) / 8.f;
    const float rising = clamp01((m.energyRatio - 1.f) * 1.5f);
    const float buildTarget = clamp01(0.55f * phrase * phrase * phrase + 0.6f * rising) * (m.beatPresent ? 1.f : 0.3f);
    build_ = follow(build_, buildTarget, 0.5f, 0.25f, dt);

    // ---- Decays and integrators ------------------------------------------------------------
    flash_ = decay(flash_, flashTau_, dt);
    burstAge_ += dt;
    shatter_ = decay(shatter_, 1.2f * B, dt);
    camKick_ = std::max(decay(camKick_, 0.25f, dt), m.kick * 0.6f);
    fovPunch_ = decay(fovPunch_, 0.6f * B, dt);
    barPulse_ = decay(barPulse_, 0.5f * B, dt);
    liftBoost_ = decay(liftBoost_, 20.f, dt);
    const float intensity = clamp01(std::max(energy_, 0.8f * liftBoost_ + 0.3f * energy_));

    const float speed = 0.5f + 2.2f * energy_ * energy_ + 1.6f * m.kick + 1.2f * build_;
    travel_ += speed * dt;
    spin_ += (0.08f + 0.9f * m.snare + 0.5f * build_) * dt;
    orbit_ += (0.04f + 0.18f * energy_ + 0.35f * build_ + 0.3f * fovPunch_) * dt;
    roll_ = follow(roll_, rollTarget_ * (0.4f + intensity) + 0.25f * m.snare, 0.15f, 0.4f, dt);
    camEase_ = follow(camEase_, float(camPreset_), 0.35f * B, 0.35f * B, dt);
    if (std::fabs(camEase_ - camPreset_) < 1e-3f) camEase_ = float(camPreset_);
    variantEase_ = follow(variantEase_, float(variant_), 0.5f * B, 0.5f * B, dt);
    hue_ += (0.004f + 0.02f * energy_) * dt;

    // Palette: blends toward the target (slowly by default, ~a beat after a small change).
    for (int i = 0; i < 16; ++i) pal_[i] += (palTarget_[i] - pal_[i]) * (1.f - std::exp(-dt / palTau_));
    palTau_ = follow(palTau_, 2.f, 1.f, 1.f, dt);

    // ---- Pack ---------------------------------------------------------------------------------
    const float strobe = clamp01(m.hat * intensity * intensity * 1.3f) * (m.beatPresent ? 1.f : 0.f);
    u_.res[2] = time_; u_.res[3] = sceneTime_;
    u_.rhythm[0] = m.beatPhase; u_.rhythm[1] = m.barPhase; u_.rhythm[2] = m.beatPulse; u_.rhythm[3] = barPulse_;
    u_.hits[0] = m.kick; u_.hits[1] = m.snare; u_.hits[2] = m.hat; u_.hits[3] = m.onset;
    u_.spec[0] = bass_; u_.spec[1] = mid_; u_.spec[2] = treble_; u_.spec[3] = loud_;
    u_.dyn[0] = energy_; u_.dyn[1] = intensity; u_.dyn[2] = build_; u_.dyn[3] = bright_;
    u_.motion[0] = travel_; u_.motion[1] = spin_; u_.motion[2] = orbit_; u_.motion[3] = camKick_;
    u_.cam[0] = camEase_; u_.cam[1] = bass_ * (0.3f + intensity); u_.cam[2] = roll_; u_.cam[3] = fovPunch_;
    u_.fx[0] = flash_; u_.fx[1] = burstAge_; u_.fx[2] = shatter_; u_.fx[3] = strobe;
    u_.look[0] = variantEase_; u_.look[1] = seed_; u_.look[2] = hue_; u_.look[3] = m.beatPresent ? 1.f : 0.f;
    std::memcpy(u_.pal, pal_, sizeof pal_);
    for (int i = 0; i < 4; ++i) u_.pal[i][3] = 0.f;

    const SceneInfo& s = kScenes[scene_];
    // No trails right after a cut: the old scene must not smear into the new one.
    post_.trails = clamp01(s.trails * (0.55f + 0.6f * energy_)) * clamp01(sceneTime_ / 0.15f);
    post_.trailZoom = s.trailZoom * (1.f + 2.5f * m.kick + 2.f * build_);
    post_.trailRot = 0.002f * std::sin(spin_) * (0.5f + build_);
    post_.bloom = s.bloom * (0.75f + 0.5f * intensity + 0.15f * flash_);
    post_.chroma = s.chroma * (0.25f + 1.2f * m.kick * intensity + 0.8f * build_ + 2.f * flash_);
    post_.exposure = s.exposure * (0.8f + 0.35f * energy_);
    post_.flash = flash_;
    post_.grain = 0.035f + 0.03f * treble_;
}

} // namespace choreo
