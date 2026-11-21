#include "analysis/Analyzer.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <numeric>
#include <string>

namespace choreo {

namespace {
constexpr float kMinBpm = 60.f, kMaxBpm = 200.f, kBpmStep = 0.5f;
constexpr int kOdfHistory = 1024;   // ~11 s of ODF at ~94 hops/s
constexpr int kTempoEvery = 8;      // re-estimate tempo every N hops
constexpr int kPhaseBeats = 8;      // beats of history used for phase search


int bpmGridSize() { return int((kMaxBpm - kMinBpm) / kBpmStep) + 1; }
float gridBpm(int i) { return kMinBpm + i * kBpmStep; }
float wrapHalf(double x) { return float(x - std::floor(x + 0.5)); } // -> [-0.5, 0.5)
} // namespace

Analyzer::Analyzer(double sampleRate)
    : sr_(sampleRate), fps_(sampleRate / kHop), fft_(kFrameSize),
      window_(kFrameSize), frame_(kFrameSize, 0.f), input_(kHop), mag_(kFrameSize / 2 + 1),
      logMag_(kFrameSize / 2 + 1, 0.f), prevLog_(kFrameSize / 2 + 1, 0.f), prevMaxF_(kFrameSize / 2 + 1, 0.f),
      odf_(kOdfHistory, 0.f), tempoScore_(bpmGridSize(), 0.f), rawScore_(bpmGridSize(), 0.f) {
    for (int i = 0; i < kFrameSize; ++i)
        window_[i] = 0.5f - 0.5f * std::cos(2.0 * M_PI * i / (kFrameSize - 1));
    auto bin = [&](double hz) { return std::clamp(int(std::lround(hz * kFrameSize / sr_)), 1, kFrameSize / 2); };
    binLo_ = bin(30);    binHi_ = bin(16000);
    kickHi_ = bin(150);
    snareLo_ = bin(150); snareHi_ = bin(2500);
    hatLo_ = bin(5000);
    bassHi_ = bin(250);  midHi_ = bin(4000);
    periodHops_ = float(60.0 * fps_ / 120.0);
    // Tuning hooks for offline experiments: CHOREO_HW="w1,w2,w3,w4", CHOREO_PRIOR="center,octaves".
    if (const char* e = std::getenv("CHOREO_HW"))
        std::sscanf(e, "%f,%f,%f,%f", &harmonicW_[0], &harmonicW_[1], &harmonicW_[2], &harmonicW_[3]);
    if (const char* e = std::getenv("CHOREO_PRIOR")) std::sscanf(e, "%f,%f", &priorCenter_, &priorOctaves_);
    if (const char* e = std::getenv("CHOREO_HOLD")) holdRatio_ = float(std::atof(e));
    if (const char* e = std::getenv("CHOREO_HALF")) halfW_ = float(std::atof(e));
    if (const char* e = std::getenv("CHOREO_LOCK")) lockWide_ = std::string(e) == "wide";
    if (const char* e = std::getenv("CHOREO_RECENCY")) recencySec_ = float(std::atof(e));
    if (const char* e = std::getenv("CHOREO_PRESENCE")) std::sscanf(e, "%f,%f,%f", &presentOn_, &presentOff_, &probationSec_);
}

void Analyzer::process(const float* samples, size_t n) {
    while (n > 0) {
        size_t take = std::min(n, size_t(kHop) - inputFill_);
        std::copy(samples, samples + take, input_.begin() + inputFill_);
        inputFill_ += take; samples += take; n -= take;
        if (inputFill_ == size_t(kHop)) {
            std::move(frame_.begin() + kHop, frame_.end(), frame_.begin());
            std::copy(input_.begin(), input_.end(), frame_.end() - kHop);
            inputFill_ = 0;
            analyzeHop();
        }
    }
}

float Analyzer::odfAt(double ago) const {
    // ago = 0 is the newest value.
    if (ago < 0) ago = 0;
    int i0 = int(ago);
    float f = float(ago - i0);
    auto at = [&](int a) {
        if (a >= kOdfHistory) return 0.f;
        return odf_[(odfPos_ + kOdfHistory - 1 - a) % kOdfHistory];
    };
    return at(i0) * (1 - f) + at(i0 + 1) * f;
}

bool Analyzer::pickPeak(Stream& s, float raw, int minGapHops, float delta) {
    // AGC: fast attack, slow release peak envelope.
    s.scale = std::max(raw, s.scale * 0.9993f);
    s.scale = std::max(s.scale, 1e-4f);
    float v = raw / s.scale;

    float mean = s.hist.empty() ? 0.f : std::accumulate(s.hist.begin(), s.hist.end(), 0.f) / s.hist.size();
    // Evaluate the previous value (1 hop lookahead) as a local maximum above an adaptive threshold.
    bool isPeak = s.prev > s.prev2 && s.prev >= v && s.prev > mean * 1.4f + delta &&
                  (hopIndex_ - 1 - s.lastOnset) >= minGapHops;
    if (isPeak) { s.lastOnset = hopIndex_ - 1; s.pulse = 1.f; }

    s.hist.push_back(v);
    if (s.hist.size() > 10) s.hist.pop_front();
    s.prev2 = s.prev;
    s.prev = v;
    return isPeak;
}

void Analyzer::analyzeHop() {
    const float dt = float(1.0 / fps_);
    const int nb = kFrameSize / 2 + 1;

    // --- Spectrum -----------------------------------------------------------------
    float tmp[kFrameSize];
    double sumSq = 0;
    for (int i = 0; i < kFrameSize; ++i) { tmp[i] = frame_[i] * window_[i]; sumSq += frame_[i] * frame_[i]; }
    fft_.magnitudes(tmp, mag_.data());
    const float norm = 4.f / kFrameSize;
    for (int k = 0; k < nb; ++k) logMag_[k] = std::log1p(100.f * mag_[k] * norm);

    // --- SuperFlux: compare against a 3-bin max-filtered previous frame (vibrato-robust) ---
    for (int k = 0; k < nb; ++k)
        prevMaxF_[k] = std::max({prevLog_[std::max(k - 1, 0)], prevLog_[k], prevLog_[std::min(k + 1, nb - 1)]});
    float fAll = 0, fKick = 0, fSnare = 0, fHat = 0;
    for (int k = binLo_; k <= binHi_; ++k) {
        float d = std::max(0.f, logMag_[k] - prevMaxF_[k]);
        fAll += d;
        if (k <= kickHi_) fKick += d;
        else if (k >= snareLo_ && k <= snareHi_) fSnare += d;
        else if (k >= hatLo_) fHat += d;
    }
    std::swap(prevLog_, logMag_);

    // --- Onsets -------------------------------------------------------------------
    const int gap50ms = std::max(1, int(0.05 * fps_)), gap100ms = std::max(1, int(0.1 * fps_));
    bool onsetAll = pickPeak(all_, fAll, gap50ms, 0.08f);
    pickPeak(kick_, fKick, gap100ms, 0.12f);
    pickPeak(snare_, fSnare, gap100ms, 0.12f);
    pickPeak(hat_, fHat, gap50ms, 0.10f);
    if (onsetAll && recordEvents) onsetTimes.push_back(state_.time - dt);

    // Beat-tracking ODF: full-band flux with extra kick emphasis (modern music is kick-led).
    float odf = all_.prev + 0.6f * kick_.prev;
    odf_[odfPos_] = odf;
    odfPos_ = (odfPos_ + 1) % kOdfHistory;

    ++hopIndex_;
    ++validHops_;
    // Time of the analysis frame centre (the ODF describes audio ~half a frame ago).
    state_.time = (double(hopIndex_) * kHop - kFrameSize / 2) / sr_;

    // Song change: a short stretch of near-silence (the gap between tracks) means whatever
    // comes next is new music, so forget the old song's rhythm entirely.
    {
        float frameRms = float(std::sqrt(sumSq / kFrameSize));
        if (frameRms < 1e-3f) ++silentHops_; else silentHops_ = 0; // ~-60 dBFS
        if (silentHops_ == int(0.2 * fps_)) resetRhythm();
    }

    if (hopIndex_ % kTempoEvery == 0 && validHops_ > long(2.5 * fps_)) updateTempo();
    updateBeatPhase();

    // --- Levels & dynamics --------------------------------------------------------
    float eB = 0, eM = 0, eT = 0, cNum = 0, cDen = 0;
    for (int k = 1; k < nb; ++k) {
        float p = mag_[k] * mag_[k];
        if (k <= bassHi_) eB += p; else if (k <= midHi_) eM += p; else eT += p;
        cNum += mag_[k] * k; cDen += mag_[k];
    }
    eB = std::sqrt(eB); eM = std::sqrt(eM); eT = std::sqrt(eT);
    auto agc = [](float v, float& mx) { mx = std::max(v, mx * 0.9995f); mx = std::max(mx, 1e-6f); return v / mx; };
    auto smooth = [&](float cur, float target, float att, float rel) {
        float tau = target > cur ? att : rel;
        return cur + (target - cur) * (1.f - std::exp(-dt / tau));
    };
    state_.bass = smooth(state_.bass, agc(eB, bassMax_), 0.01f, 0.15f);
    state_.mid = smooth(state_.mid, agc(eM, midMax_), 0.01f, 0.12f);
    state_.treble = smooth(state_.treble, agc(eT, trebMax_), 0.005f, 0.08f);

    float rms = float(std::sqrt(sumSq / kFrameSize));
    float db = 20.f * std::log10(rms + 1e-9f);
    state_.loudness = smooth(state_.loudness, std::clamp((db + 60.f) / 60.f, 0.f, 1.f), 0.02f, 0.3f);
    float e = rms * rms;
    shortE_ += (e - shortE_) * (1.f - std::exp(-dt / 0.3f));
    longE_ += (e - longE_) * (1.f - std::exp(-dt / 8.0f));
    state_.energyRatio = shortE_ / (longE_ + 1e-9f);
    float centroidHz = cDen > 0 ? (cNum / cDen) * float(sr_) / kFrameSize : 0.f;
    state_.brightness = smooth(state_.brightness, std::clamp(centroidHz / 6000.f, 0.f, 1.f), 0.05f, 0.2f);

    // --- Pulses -------------------------------------------------------------------
    const float decayFast = std::exp(-dt / 0.10f), decayBeat = std::exp(-dt / 0.18f);
    state_.kick = kick_.pulse;   kick_.pulse *= decayFast;
    state_.snare = snare_.pulse; snare_.pulse *= decayFast;
    state_.hat = hat_.pulse;     hat_.pulse *= std::exp(-dt / 0.05f);
    state_.onset = std::min(1.f, all_.prev);
    if (state_.beat) state_.beatPulse = 1.f; else state_.beatPulse *= decayBeat;
}

void Analyzer::resetRhythm() {
    std::fill(odf_.begin(), odf_.end(), 0.f);
    std::fill(tempoScore_.begin(), tempoScore_.end(), 0.f);
    validHops_ = 0;
    lockedSec_ = pendingSec_ = 0;
    state_.beatPresent = false;
    state_.pulseClarity = 0;
    state_.tempoConfidence = 0;
}

void Analyzer::updateTempo() {
    // Linearise the valid part of the ODF history (only what was heard since the last reset).
    static thread_local std::vector<float> x, acf;
    const int N = int(std::min<long>(validHops_, kOdfHistory));
    x.resize(N);
    for (int i = 0; i < N; ++i) x[i] = odf_[(odfPos_ + kOdfHistory - N + i) % kOdfHistory];
    // Remove slow trends with a local mean (~1.4 s window) instead of a global one: a swelling
    // pad or riser otherwise correlates with itself at every lag and looks "periodic".
    {
        static thread_local std::vector<double> prefix;
        prefix.assign(N + 1, 0.0);
        for (int i = 0; i < N; ++i) prefix[i + 1] = prefix[i] + x[i];
        const int half = 64;
        for (int i = 0; i < N; ++i) {
            int lo = std::max(0, i - half), hi = std::min(N, i + half + 1);
            x[i] -= float((prefix[hi] - prefix[lo]) / (hi - lo));
        }
    }
    // Light [1 2 1] smoothing widens onset peaks so periods that fall between whole hops
    // still line up in the autocorrelation.
    {
        float prev = x[0];
        for (int i = 1; i + 1 < N; ++i) {
            float cur = x[i];
            x[i] = 0.25f * prev + 0.5f * cur + 0.25f * x[i + 1];
            prev = cur;
        }
    }

    // Recency-weighted autocorrelation: recent audio counts most (time constant ~recencySec_),
    // so a new song or tempo change takes over within seconds. Each lag is normalised by its
    // own weight sum, so long lags aren't penalised.
    const int maxLag = std::min(N - 64, int(std::ceil(4 * 60.0 * fps_ / kMinBpm)) + 2);
    if (maxLag < 32) return;
    static thread_local std::vector<float> w;
    w.resize(N);
    const double tau = recencySec_ * fps_;
    for (int i = 0; i < N; ++i) w[i] = float(std::exp(-(N - 1 - i) / tau));
    acf.assign(maxLag + 1, 0.f);
    for (int l = 0; l <= maxLag; ++l) {
        double s = 0, ws = 0;
        for (int i = l; i < N; ++i) { double ww = double(w[i]) * w[i - l]; s += ww * x[i] * x[i - l]; ws += ww; }
        acf[l] = float(s / (ws + 1e-12));
    }
    if (acf[0] <= 1e-9f) return;
    const float acf0 = acf[0];
    for (auto& v : acf) v /= acf0;
    auto acfAt = [&](double lag) {
        int i = int(lag); float f = float(lag - i);
        if (i + 1 > maxLag) return 0.f;
        return acf[i] * (1 - f) + acf[i + 1] * f;
    };

    // Score each candidate tempo: harmonic sum of ACF at multiples of the period, times a log-Gaussian prior.
    const int n = bpmGridSize();
    const float wSum = harmonicW_[0] + harmonicW_[1] + harmonicW_[2] + harmonicW_[3];
    float rawPeak = 0;
    for (int i = 0; i < n; ++i) {
        float bpm = gridBpm(i);
        double lag = 60.0 * fps_ / bpm;
        float s = 0;
        for (int m = 1; m <= 4; ++m) s += std::max(0.f, acfAt(lag * m)) * harmonicW_[m - 1];
        rawPeak = std::max(rawPeak, s / wSum);
        // Subdivision evidence: a true beat almost always has strong half-beats (off-beat hats,
        // 8th notes, DnB 16ths). A 3:4 or 2:3 impostor's half-period falls between real events.
        s += halfW_ * std::max(0.f, acfAt(lag * 0.5));
        float o = std::log2(bpm / priorCenter_) / priorOctaves_;
        rawScore_[i] = s * std::exp(-0.5f * o * o);
    }

    // Pulse clarity: how strongly periodic the onsets are at the best tempo (no prior), 0..1.
    // Beat presence uses hysteresis so it doesn't flicker at the threshold.
    state_.pulseClarity += (std::clamp(rawPeak, 0.f, 1.f) - state_.pulseClarity) * 0.2f;
    bool freshLock = false;
    if (!state_.beatPresent && state_.pulseClarity > presentOn_) {
        state_.beatPresent = true;
        freshLock = true;
        lockedSec_ = 0;
    } else if (state_.beatPresent && state_.pulseClarity < presentOff_) {
        state_.beatPresent = false;
    }
    const float stepSec = float(kTempoEvery / fps_);
    if (state_.beatPresent) lockedSec_ += stepSec;

    // A fresh lock forgets the evidence gathered before the beat arrived (e.g. an ambient intro).
    int best = 0;
    for (int i = 0; i < n; ++i) {
        tempoScore_[i] = freshLock ? rawScore_[i] : 0.85f * tempoScore_[i] + 0.15f * rawScore_[i];
        if (tempoScore_[i] > tempoScore_[best]) best = i;
    }

    // Parabolic refinement of the peak.
    float refined = gridBpm(best);
    if (best > 0 && best < n - 1) {
        float a = tempoScore_[best - 1], b = tempoScore_[best], c = tempoScore_[best + 1];
        float den = a - 2 * b + c;
        if (std::fabs(den) > 1e-9f) refined += 0.5f * (a - c) / den * kBpmStep;
    }

    // Tempo decision.
    //  - small changes: follow smoothly
    //  - during probation (first seconds of a lock): follow the best candidate freely
    //  - once locked: a metrically related tempo (2:1, 3:2, ...) is the same pulse at another
    //    level, so hold; an unrelated tempo must win clearly and persistently (a real tempo change)
    float cur = state_.bpm;
    int curIdx = std::clamp(int(std::lround((cur - kMinBpm) / kBpmStep)), 0, n - 1);
    auto related = [this](float a, float b) {
        float r = a / b;
        static const float octave[] = {2.f, 0.5f};
        static const float wide[] = {2.f, 0.5f, 1.5f, 2.f / 3, 3.f, 1.f / 3, 4.f / 3, 0.75f};
        const float* qs = lockWide_ ? wide : octave;
        const int nq = lockWide_ ? 8 : 2;
        for (int k = 0; k < nq; ++k)
            if (std::fabs(r / qs[k] - 1.f) < 0.03f) return true;
        return false;
    };
    if (freshLock || (!state_.beatPresent && state_.tempoConfidence < 0.05f)) {
        state_.bpm = refined;
        pendingSec_ = 0;
    } else if (std::fabs(refined - cur) / cur < 0.04f) {
        state_.bpm = cur + 0.25f * (refined - cur);
        pendingSec_ = 0;
    } else if (lockedSec_ < probationSec_) {
        if (tempoScore_[best] > 1.05f * tempoScore_[curIdx]) state_.bpm = refined;
    } else if (related(refined, cur) && tempoScore_[curIdx] > holdRatio_ * tempoScore_[best]) {
        pendingSec_ = 0; // same pulse at another level, and the current level is still well supported: hold
    } else if (tempoScore_[best] > 1.15f * tempoScore_[curIdx]) {
        if (std::fabs(refined - pendingBpm_) / pendingBpm_ > 0.04f) { pendingBpm_ = refined; pendingSec_ = 0; }
        pendingSec_ += stepSec;
        if (pendingSec_ > 2.f) { state_.bpm = refined; pendingSec_ = 0; lockedSec_ = 0; }
    } else {
        pendingSec_ = 0;
    }
    periodHops_ = float(60.0 * fps_ / state_.bpm);

    float avg = std::accumulate(tempoScore_.begin(), tempoScore_.end(), 0.f) / n;
    state_.tempoConfidence = std::clamp((tempoScore_[best] - avg) / (tempoScore_[best] + 1e-6f), 0.f, 1.f);
}

void Analyzer::updateBeatPhase() {
    const double P = periodHops_;
    phase_ += 1.0 / P;

    // Phase search: which offset (hops since last beat) best aligns a decaying comb with the ODF?
    if (hopIndex_ % 2 == 0 && hopIndex_ > long(2 * fps_)) {
        double bestO = 0; float bestC = -1, sumC = 0; int count = 0;
        for (double o = 0; o < P; o += 0.5) {
            float c = 0, w = 1;
            for (int k = 0; k < kPhaseBeats; ++k, w *= 0.85f) c += w * odfAt(o + k * P);
            if (c > bestC) { bestC = c; bestO = o; }
            sumC += c; ++count;
        }
        float meanC = sumC / count;
        float contrast = (bestC - meanC) / (bestC + 1e-6f);
        if (contrast > 0.15f) {
            // If the newest beat was bestO hops ago, the current phase should be bestO / P.
            float err = wrapHalf(bestO / P - phase_);
            float gain = state_.tempoConfidence > 0.3f ? 0.10f : 0.25f;
            phase_ += gain * err;
        }
    }

    state_.beat = false;
    if (phase_ >= 1.0) {
        phase_ -= std::floor(phase_);
        if (state_.beatPresent && hopIndex_ - lastBeatHop_ >= long(0.5 * P)) {
            state_.beat = true;
            ++state_.beatCount;
            lastBeatHop_ = hopIndex_;
            if (recordEvents) beatTimes.push_back(state_.time - phase_ * P / fps_);
        }
    } else if (phase_ < 0) {
        phase_ += 1.0;
    }

    // Publish a phase that is latency-compensated to "now": the analysed frame centre is
    // kFrameSize/2 samples behind the newest audio.
    double lookahead = (kFrameSize / 2.0) / sr_ * state_.bpm / 60.0;
    double p = phase_ + lookahead;
    state_.beatPhase = float(p - std::floor(p));
}

} // namespace choreo
