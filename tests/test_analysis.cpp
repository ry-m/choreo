// Synthetic beat-tracking tests: render drum patterns with known beat times and check
// that the analyser finds the tempo and lands its beats within ±70 ms (standard F-measure window).
#include "analysis/Analyzer.h"
#include "analysis/FFT.h"
#include <cmath>
#include <cstdio>
#include <random>
#include <vector>

using namespace choreo;

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { ++failures; std::printf("FAIL: " __VA_ARGS__); std::printf("\n"); } } while (0)

struct Track { std::vector<float> audio; std::vector<double> beats; };

// Four-on-the-floor kick, off-beat hats, clap on 2 and 4, a sustained bass/pad, plus noise.
static Track synth(double bpm, double seconds, double sr, double startOffset = 0.37) {
    Track t;
    t.audio.assign(size_t(seconds * sr), 0.f);
    std::mt19937 rng(42);
    std::normal_distribution<float> noise(0.f, 1.f);
    double period = 60.0 / bpm;
    auto addKick = [&](double at) {
        size_t s0 = size_t(at * sr);
        double ph = 0;
        for (size_t i = 0; i < size_t(0.25 * sr) && s0 + i < t.audio.size(); ++i) {
            double tt = i / sr, f = 50 + 120 * std::exp(-tt * 30);
            ph += 2 * M_PI * f / sr;
            t.audio[s0 + i] += 0.8f * float(std::sin(ph) * std::exp(-tt * 9));
        }
    };
    auto addNoise = [&](double at, double len, float amp, double decay, bool highpass) {
        size_t s0 = size_t(at * sr); float prev = 0;
        for (size_t i = 0; i < size_t(len * sr) && s0 + i < t.audio.size(); ++i) {
            float n = noise(rng), v = highpass ? n - prev : n; prev = n;
            t.audio[s0 + i] += amp * v * float(std::exp(-i / sr * decay));
        }
    };
    int beat = 0;
    for (double b = startOffset; b < seconds; b += period, ++beat) {
        t.beats.push_back(b);
        addKick(b);
        addNoise(b + period / 2, 0.05, 0.15f, 60, true);   // off-beat hat
        if (beat % 2 == 1) addNoise(b, 0.15, 0.25f, 25, false); // clap
    }
    for (size_t i = 0; i < t.audio.size(); ++i) {
        double tt = i / sr;
        t.audio[i] += 0.08f * float(std::sin(2 * M_PI * 55 * tt) + 0.5 * std::sin(2 * M_PI * 220 * tt + std::sin(tt)));
        t.audio[i] += 0.01f * noise(rng);
    }
    return t;
}

static double fMeasure(const std::vector<double>& est, const std::vector<double>& ref, double from, double tol = 0.07) {
    std::vector<double> e, r;
    for (double x : est) if (x >= from) e.push_back(x);
    for (double x : ref) if (x >= from) r.push_back(x);
    std::vector<bool> used(r.size(), false);
    int hits = 0;
    for (double x : e)
        for (size_t j = 0; j < r.size(); ++j)
            if (!used[j] && std::fabs(x - r[j]) <= tol) { used[j] = true; ++hits; break; }
    if (e.empty() || r.empty()) return 0;
    double p = double(hits) / e.size(), rc = double(hits) / r.size();
    return p + rc > 0 ? 2 * p * rc / (p + rc) : 0;
}

static void testFFT() {
    FFT fft(1024);
    std::vector<float> x(1024), mag(513);
    for (int i = 0; i < 1024; ++i) x[i] = std::sin(2 * M_PI * 64 * i / 1024.0);
    fft.magnitudes(x.data(), mag.data());
    int peak = 0;
    for (int k = 0; k < 513; ++k) if (mag[k] > mag[peak]) peak = k;
    CHECK(peak == 64, "FFT peak at bin %d, expected 64", peak);
    CHECK(std::fabs(mag[64] - 512) < 1, "FFT magnitude %.2f, expected 512", mag[64]);
}

static void testTempo(double bpm) {
    const double sr = 48000, secs = 40;
    Track t = synth(bpm, secs, sr);
    Analyzer a(sr);
    a.recordEvents = true;
    for (size_t i = 0; i < t.audio.size(); i += 480) a.process(t.audio.data() + i, std::min<size_t>(480, t.audio.size() - i));
    double f = fMeasure(a.beatTimes, t.beats, 10.0);
    std::printf("  %5.1f BPM -> est %6.2f  conf %.2f  clarity %.2f  F(after 10s) %.3f\n", bpm, a.state().bpm, a.state().tempoConfidence, a.state().pulseClarity, f);
    CHECK(std::fabs(a.state().bpm - bpm) < 1.0, "tempo %.2f vs %.1f", a.state().bpm, bpm);
    CHECK(f > 0.9, "beat F-measure %.3f at %.1f BPM", f, bpm);
}


// A 12 s beatless intro (pad + noise only), then drums at 128 BPM. No beats should fire in the
// intro, and the tracker should lock within a few seconds of the drums arriving.
static void testBeatlessIntro() {
    const double sr = 48000, secs = 40, drumsAt = 12.0;
    Track t = synth(128, secs, sr, drumsAt);
    Analyzer a(sr);
    a.recordEvents = true;
    for (size_t i = 0; i < t.audio.size(); i += 480) a.process(t.audio.data() + i, std::min<size_t>(480, t.audio.size() - i));
    int introBeats = 0;
    for (double b : a.beatTimes) if (b < drumsAt) ++introBeats;
    double f = fMeasure(a.beatTimes, t.beats, drumsAt + 6.0);
    std::printf("  beatless intro: %d beats fired in intro, F(6s after drums) %.3f, est %.2f BPM\n", introBeats, f, a.state().bpm);
    CHECK(introBeats <= 2, "%d beats fired during beatless intro", introBeats);
    CHECK(f > 0.9, "beat F-measure %.3f after beatless intro", f);
    CHECK(std::fabs(a.state().bpm - 128) < 1.0, "tempo %.2f after beatless intro", a.state().bpm);
}

// Pattern synth: one bar of events (position in beats, instrument, amplitude), looped.
enum Inst { KICK, SNARE, HAT, STAB };
struct Ev { double pos; Inst inst; float amp; };

static Track synthPattern(double bpm, double seconds, double sr, const std::vector<Ev>& bar,
                          double start = 0.25, double beatsPerBar = 4, unsigned seed = 7) {
    Track t;
    t.audio.assign(size_t(seconds * sr), 0.f);
    std::mt19937 rng(seed);
    std::normal_distribution<float> noise(0.f, 1.f);
    const double period = 60.0 / bpm;
    auto at = [&](double sec) { return size_t(std::max(0.0, sec) * sr); };
    auto kick = [&](double sec, float amp) {
        size_t s0 = at(sec); double ph = 0;
        for (size_t i = 0; i < size_t(0.25 * sr) && s0 + i < t.audio.size(); ++i) {
            double tt = i / sr; ph += 2 * M_PI * (50 + 120 * std::exp(-tt * 30)) / sr;
            t.audio[s0 + i] += amp * float(std::sin(ph) * std::exp(-tt * 9));
        }
    };
    auto noiseHit = [&](double sec, double len, float amp, double decay, bool hp) {
        size_t s0 = at(sec); float prev = 0;
        for (size_t i = 0; i < size_t(len * sr) && s0 + i < t.audio.size(); ++i) {
            float n = noise(rng), v = hp ? n - prev : n; prev = n;
            t.audio[s0 + i] += amp * v * float(std::exp(-i / sr * decay));
        }
    };
    auto stab = [&](double sec, float amp) { // bright saw chord, like a lead synth hit
        size_t s0 = at(sec);
        for (size_t i = 0; i < size_t(0.18 * sr) && s0 + i < t.audio.size(); ++i) {
            double tt = i / sr, v = 0;
            for (double f : {440.0, 554.4, 659.3})
                for (int h = 1; h <= 8; ++h) v += std::sin(2 * M_PI * f * h * tt) / h;
            t.audio[s0 + i] += amp * 0.25f * float(v * std::exp(-tt * 14));
        }
    };
    for (double b = start; b < seconds; b += period) t.beats.push_back(b);
    for (double barStart = start; barStart < seconds; barStart += beatsPerBar * period)
        for (const Ev& e : bar) {
            double sec = barStart + e.pos * period;
            switch (e.inst) {
                case KICK: kick(sec, e.amp); break;
                case SNARE: noiseHit(sec, 0.15, e.amp, 25, false); break;
                case HAT: noiseHit(sec, 0.03, e.amp, 90, true); break;
                case STAB: stab(sec, e.amp); break;
            }
        }
    for (size_t i = 0; i < t.audio.size(); ++i) t.audio[i] += 0.01f * noise(rng);
    return t;
}

struct RunResult { float bpm; double lockAt; std::vector<double> beats; };

// Feeds audio in 10 ms blocks; lockAt = first time (after `from`) the tempo is within 2% of
// `target` (or half/double if allowOctave) with a beat present, and stays there to the end.
static RunResult run(const std::vector<float>& audio, double sr, double target, double from = 0, bool allowOctave = false) {
    Analyzer a(sr);
    a.recordEvents = true;
    double lockAt = -1;
    for (size_t i = 0; i < audio.size(); i += 480) {
        a.process(audio.data() + i, std::min<size_t>(480, audio.size() - i));
        const auto& s = a.state();
        if (s.time < from) continue;
        auto near = [&](double x) { return std::fabs(s.bpm - x) / x < 0.02; };
        bool ok = s.beatPresent && (near(target) || (allowOctave && (near(target * 2) || near(target / 2))));
        if (ok && lockAt < 0) lockAt = s.time;
        if (!ok) lockAt = -1;
    }
    return {a.state().bpm, lockAt, a.beatTimes};
}

// Syncopated lead stabs every dotted eighth (0.75 beat) over a four-on-the-floor kick: the stab
// periodicity tempts the tracker to 4/3 of the true tempo (seen live on Avicii "Levels").
static void testDottedLead() {
    const double sr = 48000;
    std::vector<Ev> bar = {{0, KICK, 0.45f}, {1, KICK, 0.45f}, {2, KICK, 0.45f}, {3, KICK, 0.45f},
                           {0.5, HAT, 0.05f}, {1.5, HAT, 0.05f}, {2.5, HAT, 0.05f}, {3.5, HAT, 0.05f}};
    // Lead on a dotted-eighth grid that runs across the bar line (4 bars = 21⅓ stabs), so its
    // 0.75-beat periodicity is strong and continuous, as in a long syncopated riff.
    for (double p = 0; p < 4; p += 0.75) bar.push_back({p, STAB, 1.0f});
    Track t = synthPattern(128, 40, sr, bar);
    RunResult r = run(t.audio, sr, 128);
    std::printf("  dotted lead @128: est %.2f BPM, locked at %.1fs\n", r.bpm, r.lockAt);
    CHECK(std::fabs(r.bpm - 128) < 1.5, "dotted lead: tempo %.2f, expected 128 (not 4:3 = 170.7)", r.bpm);
}

// Drum & bass breakbeat at 174: kick on 1 and the "and" of 3, snares on 2 and 4, 8th hats.
// Half-time (87) is acceptable; 2/3 (116, seen live on Pendulum/Wilkinson) is not.
static void testDnB() {
    const double sr = 48000;
    // Reese-style bass hits on the kick pattern dominate; hats are quiet, snares moderate.
    std::vector<Ev> bar = {{0, KICK, 0.9f}, {2.5, KICK, 0.9f}, {0, STAB, 0.6f}, {1.5, STAB, 0.6f}, {2.5, STAB, 0.6f},
                           {1, SNARE, 0.3f}, {3, SNARE, 0.3f}};
    for (double p = 0; p < 4; p += 0.5) bar.push_back({p, HAT, 0.04f});
    Track t = synthPattern(174, 40, sr, bar);
    RunResult r = run(t.audio, sr, 174, 0, true);
    std::printf("  DnB @174: est %.2f BPM, locked at %.1fs\n", r.bpm, r.lockAt);
    CHECK(std::fabs(r.bpm - 174) < 2 || std::fabs(r.bpm - 87) < 1, "DnB: tempo %.2f, expected 174 (or 87)", r.bpm);
}

// Song change: 30 s at 128, then (optionally) 0.6 s of silence, then 30 s at 100. The tracker
// must re-lock on the new song quickly, like Spotify moving to the next track.
// Hard cut from a 171 BPM song to a 128 BPM one (ratio ~4:3), as Spotify went from
// "Blinding Lights" to "Levels": the old tempo must not be held as a "related" level.
static void testSongChangeRelated() {
    const double sr = 48000;
    std::vector<Ev> four = {{0, KICK, 0.8f}, {1, KICK, 0.8f}, {2, KICK, 0.8f}, {3, KICK, 0.8f},
                            {1, SNARE, 0.25f}, {3, SNARE, 0.25f}};
    for (double p = 0.5; p < 4; p += 1) four.push_back({p, HAT, 0.1f});
    Track a = synthPattern(171, 30, sr, four, 0.25, 4, 3);
    Track b = synthPattern(128, 30, sr, four, 0.1, 4, 4);
    std::vector<float> audio = a.audio;
    double bStart = audio.size() / sr;
    audio.insert(audio.end(), b.audio.begin(), b.audio.end());
    RunResult r = run(audio, sr, 128, bStart);
    double lock = r.lockAt < 0 ? -1 : r.lockAt - bStart;
    std::printf("  song change 171->128 (hard cut): est %.2f BPM, re-locked %.1fs after new song\n", r.bpm, lock);
    CHECK(lock >= 0 && lock < 8.0, "171->128 song change: re-lock took %.1fs (final %.2f)", lock, r.bpm);
}

static void testSongChange(bool gap) {
    const double sr = 48000;
    std::vector<Ev> four = {{0, KICK, 0.8f}, {1, KICK, 0.8f}, {2, KICK, 0.8f}, {3, KICK, 0.8f},
                            {1, SNARE, 0.25f}, {3, SNARE, 0.25f}};
    for (double p = 0.5; p < 4; p += 1) four.push_back({p, HAT, 0.1f});
    Track a = synthPattern(128, 30, sr, four, 0.25, 4, 1);
    Track b = synthPattern(100, 30, sr, four, 0.1, 4, 2);
    std::vector<float> audio = a.audio;
    if (gap) audio.insert(audio.end(), size_t(0.6 * sr), 0.f);
    double bStart = audio.size() / sr;
    audio.insert(audio.end(), b.audio.begin(), b.audio.end());
    RunResult r = run(audio, sr, 100, bStart);
    double lock = r.lockAt < 0 ? -1 : r.lockAt - bStart;
    std::printf("  song change %s: est %.2f BPM, re-locked %.1fs after new song\n", gap ? "(0.6s gap)" : "(hard cut)", r.bpm, lock);
    CHECK(lock >= 0 && lock < (gap ? 5.0 : 8.0), "song change %s: re-lock took %.1fs", gap ? "with gap" : "hard cut", lock);
}

int main() {
    testFFT();
    for (double bpm : {100.0, 124.0, 128.0, 140.0}) testTempo(bpm);
    testBeatlessIntro();
    testDottedLead();
    testDnB();
    testSongChange(true);
    testSongChange(false);
    testSongChangeRelated();
    std::printf(failures ? "%d failure(s)\n" : "all tests passed\n", failures);
    return failures ? 1 : 0;
}
