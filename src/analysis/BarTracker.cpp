#include "analysis/BarTracker.h"
#include <algorithm>
#include <cmath>

namespace choreo {

namespace { constexpr float kFps = 100.f; }

BarTracker::BarTracker(const Params& p) : P_(p) {
    minTau_ = int(std::floor(60.f * kFps / P_.maxBpm));
    maxTau_ = int(std::ceil(60.f * kFps / P_.minBpm));
    nTau_ = maxTau_ - minTau_ + 1;
    segIndex_.assign(P_.nMeters * 4 * nTau_, -1);
    int off = 0;
    for (int mi = 0; mi < P_.nMeters; ++mi)
        for (int b = 0; b < P_.meters[mi]; ++b)
            for (int ti = 0; ti < nTau_; ++ti) {
                segIndex_[(mi * 4 + b) * nTau_ + ti] = int(segs_.size());
                segs_.push_back({mi, b, minTau_ + ti, off});
                off += minTau_ + ti;
            }
    alpha_.assign(off, 0.f);
    next_.assign(off, 0.f);
    ends_.assign(segs_.size(), 0.f);
    trans_.assign(nTau_ * nTau_, 0.f);
    for (int i = 0; i < nTau_; ++i) {
        double sum = 0;
        for (int j = 0; j < nTau_; ++j) {
            double r = double(minTau_ + j) / (minTau_ + i);
            double v = std::exp(-P_.transitionLambda * std::fabs(r - 1.0));
            if (v < 1e-7) v = 0;
            trans_[i * nTau_ + j] = float(v);
            sum += v;
        }
        for (int j = 0; j < nTau_; ++j) trans_[i * nTau_ + j] = float(trans_[i * nTau_ + j] / sum);
    }
    prior_.assign(nTau_, 1.f);
    if (P_.priorOctaves > 0)
        for (int i = 0; i < nTau_; ++i) {
            float o = std::log2(60.f * kFps / (minTau_ + i) / P_.priorCenter) / P_.priorOctaves;
            prior_[i] = std::exp(-0.5f * o * o);
        }
    reset();
}

void BarTracker::reset() {
    std::fill(alpha_.begin(), alpha_.end(), 1.f / alpha_.size());
    est_ = Estimate();
    bpmSmooth_ = 0;
}

void BarTracker::soften(float w) {
    const float u = 1.f / alpha_.size();
    for (float& v : alpha_) v = (1.f - w) * v + w * u;
}

const BarTracker::Estimate& BarTracker::push(float beat, float down) {
    const float act = std::clamp(beat, 1e-4f, 1.f - 1e-4f);
    const float q = std::clamp(down / (beat + 1e-3f), 0.f, 1.f); // P(downbeat | beat), per the network
    const float kappa = P_.temperature;
    const float nonBeat = std::pow((1.f - act) / (P_.obsLambda - 1.f), kappa);
    const float w = P_.downW;

    // Mass leaving the last position of every segment.
    for (size_t s = 0; s < segs_.size(); ++s) ends_[s] = alpha_[segs_[s].offset + segs_[s].tau - 1];

    for (size_t s = 0; s < segs_.size(); ++s) {
        const Seg& g = segs_[s];
        const int B = P_.meters[g.meter];
        float* dst = &next_[g.offset];
        const float* src = &alpha_[g.offset];
        // Advance within the beat.
        std::copy(src, src + g.tau - 1, dst + 1);
        // Enter from the end of the previous beat in the bar (any tempo, penalised by change).
        const int prevB = (g.beat + B - 1) % B, tj = g.tau - minTau_;
        double in = 0;
        for (int ti = 0; ti < nTau_; ++ti) {
            float t = trans_[ti * nTau_ + tj];
            if (t > 0) in += ends_[seg(g.meter, prevB, ti)] * t;
        }
        dst[0] = float(in) * prior_[tj];
        // Observation.
        // Beat region: positions 0..h belong to this beat, the last h positions of the segment
        // lead into the next beat (so its bar factor applies there).
        const int h = std::min(P_.regionHalf, g.tau / 4);
        auto barF = [&](int beat) { return beat == 0 ? 1.f - w + w * B * q : 1.f - w + w * B / (B - 1.f) * (1.f - q); };
        const float actB = std::max(act, P_.missFloor);
        const float obsHere = std::pow(actB * barF(g.beat), kappa), obsNext = std::pow(actB * barF((g.beat + 1) % B), kappa);
        for (int p = 0; p <= h; ++p) dst[p] *= obsHere;
        for (int p = h + 1; p < g.tau - h; ++p) dst[p] *= nonBeat;
        for (int p = g.tau - h; p < g.tau; ++p) dst[p] *= obsNext;
    }

    // Normalise, mix in a little uniform mass (so an unrelated new tempo can always grow), find
    // the most likely state, and gather per-tempo / per-bar-position mass.
    double sum = 0;
    for (float v : next_) sum += v;
    const float inv = sum > 0 ? float(1.0 / sum) : 1.f;
    const float u = P_.floor / next_.size();
    int bestSeg = 0, bestPos = 0; float bestV = -1;
    for (size_t s = 0; s < segs_.size(); ++s) {
        float* x = &next_[segs_[s].offset];
        for (int p = 0; p < segs_[s].tau; ++p) {
            x[p] = x[p] * inv * (1.f - P_.floor) + u;
            if (x[p] > bestV) { bestV = x[p]; bestSeg = int(s); bestPos = p; }
        }
    }
    std::swap(alpha_, next_);

    const Seg& g = segs_[bestSeg];
    // Tempo: posterior-weighted around the best period (same meter), so it isn't stuck on the
    // integer-frame grid. Bar confidence: share of mass on the chosen beat-in-bar.
    double tm = 0, tw = 0, barMass = 0, meterMass = 0;
    for (size_t s = 0; s < segs_.size(); ++s) {
        if (segs_[s].meter != g.meter) continue;
        double m = 0;
        const float* x = &alpha_[segs_[s].offset];
        for (int p = 0; p < segs_[s].tau; ++p) m += x[p];
        meterMass += m;
        if (segs_[s].beat == g.beat) barMass += m;
        if (std::abs(segs_[s].tau - g.tau) <= 2) { tm += m * segs_[s].tau; tw += m; }
    }
    float bpm = 60.f * kFps / float(tw > 0 ? tm / tw : g.tau);
    if (bpmSmooth_ <= 0 || std::fabs(bpm - bpmSmooth_) / bpmSmooth_ > 0.04f) bpmSmooth_ = bpm;
    else bpmSmooth_ += 0.05f * (bpm - bpmSmooth_);

    est_.valid = true;
    est_.bpm = bpmSmooth_;
    est_.beatPos = float(bestPos);
    est_.period = float(g.tau);
    est_.beatInBar = g.beat;
    est_.beatsPerBar = P_.meters[g.meter];
    est_.barConfidence = float(meterMass > 0 ? barMass / meterMass : 0);
    return est_;
}

} // namespace choreo
