#pragma once
#include "analysis/FFT.h"
#include "analysis/MusicState.h"
#include <deque>
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

    // Process any number of samples; may run zero or more hops.
    void process(const float* samples, size_t n);

    const MusicState& state() const { return state_; }
    double hopsPerSecond() const { return fps_; }

    // Offline instrumentation.
    bool recordEvents = false;
    std::vector<double> beatTimes, onsetTimes;

private:
    void analyzeHop();
    void updateTempo();
    void updateBeatPhase();
    float odfAt(double framesAgo) const; // interpolated ODF history lookup

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
    size_t odfPos_ = 0;
    std::vector<float> tempoScore_;   // smoothed score per BPM grid entry
    float periodHops_;                // beat period in hops (fractional)
    float harmonicW_[4] = {1.f, 0.5f, 1.f / 3, 0.25f}; // weight of ACF at 1x..4x the period
    float priorCenter_ = 128.f, priorOctaves_ = 0.5f;  // log-Gaussian tempo prior
    std::vector<float> rawScore_;     // this update's (unsmoothed) score per BPM grid entry
    float presentOn_ = 0.25f, presentOff_ = 0.16f;    // pulse-clarity hysteresis for beatPresent
    float probationSec_ = 8.f;        // after a fresh lock, metrical level may still change
    float lockedSec_ = 0, pendingSec_ = 0, pendingBpm_ = 120.f;
    float recencySec_ = 5.f;
    float halfW_ = 1.f;               // weight of half-beat (subdivision) evidence in the tempo score
    float holdRatio_ = 0.6f;          // hold a related level only while it keeps this share of the best score
    bool lockWide_ = true;            // metrical lock also holds 3:2 / 4:3 (else only 2:1)          // time constant of the recency-weighted autocorrelation
    long validHops_ = 0;              // hops of ODF since the last rhythm reset
    int silentHops_ = 0;              // consecutive near-silent hops
    void resetRhythm();               // forget tempo/beat state (song change)

    // Beat tracking
    double phase_ = 0;
    long lastBeatHop_ = -1000;

    // Dynamics
    float shortE_ = 0, longE_ = 0;
    float bassMax_ = 1e-6f, midMax_ = 1e-6f, trebMax_ = 1e-6f;

    MusicState state_;
};

} // namespace choreo
