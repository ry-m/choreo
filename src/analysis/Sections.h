#pragma once
#include <deque>
#include <string>
#include <vector>

namespace choreo {

// Section-change detector (see tools/ml/sections.py, which trains it and defines the features).
//
// Live: feed every 100 fps MelFeatures frame (pushFrame), and call onBeat at each tracked beat.
// At beat b_{i+1} it summarises the beat that just ended [b_i, b_{i+1}) from 16-band energy
// envelopes, relative to a running average, plus bar position, tempo and repetition against 1/2/4/8
// bars earlier, and steps a small GRU. Each output head says "a section started at beat i+1-d"
// for its delay d (-1: the beat happening now) and kind (any boundary / lift: chorus or drop).
class SectionDetector {
public:
    bool load(const std::string& path);
    bool loaded() const { return H_ > 0; }
    void reset();

    // One MelFeatures frame (first 64 values: log-mel) whose centre is at time t (seconds).
    void pushFrame(const float* feat, double t);
    // A beat starts at time tb; inBarPrev = bar position (0 = downbeat) of the beat that just ended.
    // Returns true when the outputs were updated (needs a previous beat).
    bool onBeat(double tb, int inBarPrev);

    int numOutputs() const { return N_; }
    const std::vector<int>& delays() const { return delays_; }   // per head pair (any, lift)
    const std::vector<float>& outputs() const { return out_; }   // probabilities, 0..1
    const std::vector<float>& thresholds() const { return thr_; }
    const std::vector<float>& lastInput() const { return x_; }   // for tests

    static constexpr int kBands = 16, kMel = 64, kBase = 2 * kBands + 2;
    static constexpr int kIn = kBase + 4 + 1 + 5;
    static constexpr double kEnvFps = 22050.0 / 1024.0;

private:
    // Envelope front end
    std::vector<int> group_;                 // mel band -> section band
    std::deque<std::vector<double>> win_;    // last 9 frames of band power (trailing average)
    std::vector<double> winSum_;
    double prevT_ = 0, t0_ = 0;
    std::vector<double> prevSm_;
    bool havePrev_ = false;
    long envCount_ = 0;                      // envelope frames produced
    std::deque<std::vector<float>> env_, flux_;   // recent envelope frames (log band energy) and onsets
    long envBase_ = 0;                       // index of env_.front()

    // Beat-level state
    bool haveBeat_ = false;
    double lastBeat_ = 0;
    std::vector<float> ema_, absSum_;
    long beats_ = 0;
    std::deque<std::vector<float>> zHist_;   // last 33 scaled rows (for repetition distances)

    // Network: x -> tanh(Linear) -> GRU -> Linear -> sigmoid
    int H_ = 0, N_ = 0;
    std::vector<int> delays_;
    std::vector<float> thr_;
    std::vector<float> inW_, inB_, wih_, whh_, bih_, bhh_, outW_, outB_;
    std::vector<float> h_, x_, out_;
};

} // namespace choreo
