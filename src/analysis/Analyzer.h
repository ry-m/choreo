#pragma once
#include "analysis/BarTracker.h"
#include "analysis/BeatNet.h"
#include "analysis/FFT.h"
#include "analysis/Features.h"
#include "analysis/Sections.h"
#include "analysis/MusicState.h"
#include <deque>
#include <memory>
#include <string>
#include <vector>

namespace choreo {

// Real-time music analyser. Feed it mono samples; it publishes a MusicState per hop.
//
// Pipeline: Hann window -> FFT -> log magnitude -> SuperFlux-style spectral flux
// (full band + kick/snare/hat bands) -> adaptive peak picking (onsets)
// -> ODF autocorrelation with harmonic enhancement + tempo prior (BPM)
// -> comb-template phase search + PLL (beat phase / predicted beats).
class Analyzer {
public:
    static constexpr int kFrameSize = 2048;
    static constexpr int kHop = 512;

    explicit Analyzer(double sampleRate);

    // Load the learned beat/downbeat detector (models/beatnet.bin). When loaded, its beat
    // activation drives tempo and phase instead of the hand-built onset function.
    bool loadBeatModel(const std::string& path);
    bool hasBeatModel() const { return net_.loaded(); }
    // Section-change detector (models/sections.bin); needs the beat model (shares its features).
    bool loadSectionModel(const std::string& path);
    bool hasSectionModel() const { return sections_.loaded(); }

    // Process any number of samples; may run zero or more hops.
    void process(const float* samples, size_t n);

    const MusicState& state() const { return state_; }

    // The state as of audio time t (seconds, same base as state().time). If t is older than the
    // newest analysed hop, it's the snapshot recorded at that moment (exact, including detected
    // hits). If t is newer, it's the newest state with the beat predicted forward. This lets the
    // display show what the listener is hearing right now, whatever the output latency.
    MusicState stateAt(double t) const;
    double hopsPerSecond() const { return fps_; }

    // Offline instrumentation.
    bool recordEvents = false;
    std::vector<double> beatTimes, onsetTimes, kickTimes, changeTimes, downbeatTimes;
    std::vector<float> beatBpms;      // tempo at each recorded beat
    struct SectionEvent { double time; int kind; float prob; }; // kind: 0 change, 1 lift, 2 confirmed, 3 lift confirmed
    std::vector<SectionEvent> sectionEvents;

private:
    void analyzeHop();
    void updateTempo();
    void updateBeatPhase();
    float odfAt(double framesAgo) const; // interpolated ODF history lookup
    float phaseOdfAt(double framesAgo) const;
    float csAt(double framesAgo) const;

    double sr_, fps_;
    FFT fft_;
    std::vector<float> window_, frame_, input_, mag_, logMag_, prevLog_, prevMaxF_;
    size_t inputFill_ = 0;
    long hopIndex_ = 0;

    // Bin ranges
    int binLo_, binHi_, kickHi_, snareLo_, snareHi_, hatLo_, bassHi_, midHi_;

    // Onset detection
    struct Stream {
        std::deque<float> hist;  // recent normalised values for adaptive threshold
        float scale = 1e-3f;     // AGC
        float prev = 0, prev2 = 0;
        long lastOnset = -1000;
        float pulse = 0;
    };
    bool pickPeak(Stream& s, float raw, int minGapHops, float delta);
    Stream all_, kick_, snare_, hat_;

    // Tempo
    std::vector<float> odf_;          // circular history of the ODF
    std::vector<float> phaseOdf_;     // circular history of the phase-alignment ODF
    float phaseW_[4] = {1.f, 0.6f, 0.4f, 0.f}; // phase ODF = these x (full band, kick, snare, hat)
    float phaseGainLocked_ = 0.25f, phaseGainSearch_ = 0.40f; // PLL correction gains
    std::vector<float> cs_;           // cumulative beat score history
    float csAlpha_ = 0.9f, csEta_ = 5.f; // cumulative score: memory, and tightness around the period
    int csBeats_ = 3;                 // >0: phase search runs on the cumulative score over this many beats
    bool computeAcf(const std::vector<float>& hist, int N, std::vector<float>& acf, int& maxLag) const;
    size_t odfPos_ = 0;
    std::vector<float> tempoScore_;   // smoothed score per BPM grid entry
    float periodHops_;                // beat period in hops (fractional)
    float harmonicW_[4] = {1.f, 0.5f, 1.f / 3, 0.5f};  // weight of ACF at 1x..4x the period (4x = one bar)
    float priorCenter_ = 128.f, priorOctaves_ = 0.5f;  // log-Gaussian tempo prior
    std::vector<float> rawScore_;     // this update's (unsmoothed) score per BPM grid entry
    float presentOn_ = 0.25f, presentOff_ = 0.16f;    // pulse-clarity hysteresis for beatPresent
    float probationSec_ = 8.f;        // after a fresh lock, metrical level may still change
    float lockedSec_ = 0, pendingSec_ = 0, pendingBpm_ = 120.f;
    float recencySec_ = 5.f;
    float twoBarW_ = 0.f;             // weight of ACF at 8x the period (two bars)
    float warmupSec_ = 1.5f;          // seconds of ODF needed before the first tempo estimate
    float halfW_ = 1.f;               // weight of half-beat (subdivision) evidence in the tempo score
    float odfW_[3] = {0.6f, 0.f, 0.f};  // beat ODF = full-band flux + these x (kick, snare, hat) streams
    float holdRatio_ = 0.6f;
    float relatedSwitchSec_ = 4.f;    // how long a related level must win before we switch to it          // hold a related level only while it keeps this share of the best score
    bool lockWide_ = true;            // metrical lock also holds 3:2 / 4:3 (else only 2:1)          // time constant of the recency-weighted autocorrelation
    long validHops_ = 0;              // hops of ODF since the last rhythm reset
    int silentHops_ = 0;              // consecutive near-silent hops
    void resetRhythm();               // forget tempo/beat state (song change after silence)
    void softReset();                 // drop rhythm history but keep the beat (hard-cut song change)
    std::vector<int> novEdges_;
    std::vector<float> novShort_, novLong_;
    long hopsSinceChange_ = 0;
    float noveltyThresh_ = 1.5f;      // timbre-novelty level that triggers softReset (song cuts: 1.6-2.9)

    // Beat tracking
    double phase_ = 0;
    long lastBeatHop_ = -1000;

    // Dynamics
    float shortE_ = 0, longE_ = 0;
    float bassMax_ = 1e-6f, midMax_ = 1e-6f, trebMax_ = 1e-6f;

    // Learned detector
    static constexpr int kNnHistory = 512;
    std::unique_ptr<MelFeatures> features_;
    BeatNet net_;
    std::vector<float> nnBeat_, nnDown_;
    long nnFrames_ = 0;
    double nnLagSec_ = 0;
    float nnW_ = -1.f;                 // blend: 1 = network only, 0 = hand-built ODF only (-1 = unset)
    float nnScale_ = 1.f;
    float eventThresh_ = 0.4f, eventGain_ = 0.f; // peak-based phase correction (gain 0 = off)
    float actPrev_ = 0, actPrev2_ = 0;
    float nnAt(const std::vector<float>& ring, double t) const;

    // Bar-pointer tracker on the network activations (replaces ACF tempo + phase search + PLL
    // for tempo/phase/bars when a model is loaded; CHOREO_TRACKER=old selects the old path).
    std::unique_ptr<BarTracker> bar_;
    BarTracker::Estimate barEst_;
    double barLastBeat_ = -1e9;       // time (s) of the most recent beat per the tracker
    double barOffsetSec_ = 0;         // timing correction applied to tracker beats
    // Reported metrical level: output tempo = levelMult_ x tracker tempo (0.5, 1 or 2). It keeps
    // the reported tempo continuous when the tracker's evidence slides to half/double (e.g. a
    // half-time breakdown) and folds tempos outside the preferred range [lo, hi] into it.
    float levelMult_ = 1.f, prevMapBpm_ = 0, levelPendingSec_ = 0;
    float levelLo_ = 0.f, levelHi_ = 1e9f, levelFoldSec_ = 2.f; // folding off by default: it trades annotated-level accuracy for web-BPM conventions
    int levelCont_ = 0;
    float prevPhase_ = 0;
    void updateFromBarTracker();

    // Section-change detector, stepped once per tracked beat.
    SectionDetector sections_;
    int prevBeatInBar_ = 0;
    long lastSection_ = -1000, lastLift_ = -1000, lastConf_ = -1000, lastLiftConf_ = -1000;
    bool secAnyBeat_ = false;         // fire on any beat (else only on downbeats)
    int secRefractory_ = 8;           // beats between events of the same kind
    void updateSections(double beatTime, int inBar);

    MusicState state_;
    std::vector<MusicState> history_;  // ring of recent per-hop states (~5 s)
    size_t historyPos_ = 0, historyCount_ = 0;
};

} // namespace choreo
