#pragma once
#include <vector>

namespace choreo {

// Causal bar-pointer tracker (online HMM filtering, after Whiteley et al. 2006 / Krebs et al. 2015
// / Böck et al. 2016). It follows tempo, position within the beat, beat within the bar and meter
// jointly, scored against the learned beat and downbeat activations, one 100 fps frame at a time.
//
// State: meter m (3 or 4 beats per bar) x beat in bar b x beat period tau (frames) x position p.
// Each frame p advances by one; at the end of a beat the tracker moves to the next beat in the bar
// and may change tempo (probability falls off exponentially with the relative change).
// Observation: frames within a few frames of each beat should carry beat activation (the bar's
// first beat should also carry downbeat activation); all other frames should not.
class BarTracker {
public:
    struct Params {
        float minBpm = 60.f, maxBpm = 200.f;
        float transitionLambda = 100.f; // tempo-change stiffness (madmom's default)
        float obsLambda = 8.f;          // non-beat frames score (1 - act) / (obsLambda - 1)
        int regionHalf = 3;             // beat region = beat +- this many frames, at every tempo
                                        // (a tau-proportional region favours slow tempos when the
                                        // network's peaks are a few frames wide)
        float downW = 0.5f;             // 0 = ignore downbeat activation, 1 = trust it fully
        float floor = 1e-6f;            // per-frame mixing with uniform: lets a new song take over
        float temperature = 0.5f;       // observation exponent (<1: evidence accumulates more gently,
                                        // so a hypothesis survives a few weak or missing beats)
        float missFloor = 0.05f;         // beat-region likelihood never drops below this: a beat that
                                        // isn't heard (sparse / half-time section) costs little, so
                                        // the current metrical level survives it
        float priorCenter = 128.f;      // log-Gaussian tempo prior, applied once per beat
        float priorOctaves = 0.f;       // its width; 0 = no prior
        int meters[2] = {3, 4};
        int nMeters = 2;
    };

    struct Estimate {
        bool valid = false;
        float bpm = 120.f;         // smoothed around the most likely tempo
        float beatPos = 0;         // frames since the most recent beat (most likely state)
        float period = 50;         // frames per beat (most likely state)
        int beatInBar = 0;         // 0 = downbeat
        int beatsPerBar = 4;
        float barConfidence = 0;   // posterior share of the chosen bar position (0..1)
    };

    BarTracker() : BarTracker(Params()) {}
    explicit BarTracker(const Params& p);
    void reset();
    // Feed one frame of activations (beat, downbeat; 0..1). Returns the estimate after it.
    const Estimate& push(float beat, float down);
    const Estimate& estimate() const { return est_; }

private:
    struct Seg { int meter, beat, tau; int offset; }; // contiguous run of tau positions
    Params P_;
    int minTau_, maxTau_, nTau_;
    std::vector<Seg> segs_;
    std::vector<int> segIndex_;      // [meterIdx][beat][tauIdx] -> segment index
    std::vector<float> alpha_, next_;
    std::vector<float> trans_;       // [tauIdx][tauIdx'] tempo transition probabilities
    std::vector<float> ends_;        // scratch: mass leaving the end of each segment
    std::vector<float> prior_;       // [tauIdx] per-beat tempo prior
    Estimate est_;
    float bpmSmooth_ = 0;
    int seg(int mi, int b, int ti) const { return segIndex_[(mi * 4 + b) * nTau_ + ti]; }
};

} // namespace choreo
