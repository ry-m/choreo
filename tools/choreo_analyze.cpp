// Offline analysis of an audio file (MP3/M4A/WAV/... on macOS).
// Usage: choreo-analyze song.mp3 [--beats] [--onsets] [--timeline] [--ref-bpm X]
//   --timeline   one line per second: tempo, confidence, pulse clarity, beat presence
//   --ref-bpm X  score tempo accuracy against a known tempo (see tests/reference/tempos.csv)
//   --from S     only score from S seconds on (e.g. the second song of a joined pair)
//   --phase      beat-phase report: predicted beats vs. detected kick onsets (no ground truth needed)
#include "Wav.h"
#include "analysis/Analyzer.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <string>

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s file [--beats] [--onsets] [--timeline] [--ref-bpm X]\n", argv[0]);
        return 1;
    }
    bool printBeats = false, printOnsets = false, timeline = false, phase = false, printKicks = false;
    double refBpm = 0, scoreFrom = 0;
    for (int i = 2; i < argc; ++i) {
        if (!std::strcmp(argv[i], "--beats")) printBeats = true;
        else if (!std::strcmp(argv[i], "--onsets")) printOnsets = true;
        else if (!std::strcmp(argv[i], "--timeline")) timeline = true;
        else if (!std::strcmp(argv[i], "--phase")) phase = true;
        else if (!std::strcmp(argv[i], "--kicks")) printKicks = true;
        else if (!std::strcmp(argv[i], "--ref-bpm") && i + 1 < argc) refBpm = std::atof(argv[++i]);
        else if (!std::strcmp(argv[i], "--from") && i + 1 < argc) scoreFrom = std::atof(argv[++i]);
    }
    std::vector<float> audio; double sr = 0;
    if (!choreo::loadAudioMono(argv[1], audio, sr)) { std::fprintf(stderr, "failed to read %s\n", argv[1]); return 1; }

    choreo::Analyzer a(sr);
    {
        // Learned beat model: $CHOREO_MODEL, else <exe dir>/../models/beatnet.bin ("none" = off).
        std::string exe = argv[0], dir = exe.substr(0, exe.find_last_of('/') == std::string::npos ? 0 : exe.find_last_of('/'));
        const char* env = std::getenv("CHOREO_MODEL");
        std::string model = env ? env : (dir.empty() ? "." : dir) + "/../models/beatnet.bin";
        if (model != "none") a.loadBeatModel(model);
    }
    a.recordEvents = true;
    const size_t block = 512;
    double nextLine = 1.0, nextSample = 0.0;
    // Tempo scoring, sampled every 0.1 s.
    long samples = 0, present = 0, exact = 0, related = 0;
    double lockAt = -1, lockAt2 = -1;
    for (size_t i = 0; i < audio.size(); i += block) {
        a.process(audio.data() + i, std::min(block, audio.size() - i));
        const auto& s = a.state();
        if (timeline && s.time >= nextLine) {
            std::printf("t=%5.0fs  bpm=%6.2f  conf=%.2f  clarity=%.2f  nov=%.2f  %s\n", s.time, s.bpm, s.tempoConfidence,
                        s.pulseClarity, s.novelty, s.beatPresent ? "BEAT" : "-");
            nextLine += 1.0;
        }
        if (refBpm > 0 && s.time >= scoreFrom && s.time >= nextSample) {
            nextSample += 0.1;
            ++samples;
            if (s.beatPresent) {
                ++present;
                auto near = [&](double target) { return std::fabs(s.bpm - target) / target < 0.04; };
                if (near(refBpm)) ++exact;
                if (near(refBpm) && lockAt < 0) lockAt = s.time - scoreFrom;
                for (double r : {1.0, 2.0, 0.5}) // half/double is acceptable; 3:2 or 4:3 is wrong
                    if (near(refBpm * r)) { ++related; if (lockAt2 < 0) lockAt2 = s.time - scoreFrom; break; }
            }
        }
    }
    std::printf("duration %.1fs  final bpm %.2f  confidence %.2f  beats %zu  onsets %zu\n",
                audio.size() / sr, a.state().bpm, a.state().tempoConfidence, a.beatTimes.size(), a.onsetTimes.size());
    if (refBpm > 0 && present > 0) {
        std::printf("ref %.1f BPM: beat present %.0f%% of the time; while present, correct %.1f%%, "
                    "correct-or-half/double %.1f%%; first correct at %.1fs; final %.1f; first half/double-ok at %.1fs\n",
                    refBpm, 100.0 * present / samples, 100.0 * exact / present, 100.0 * related / present,
                    lockAt, a.state().bpm, lockAt2);
    } else if (refBpm > 0) {
        std::printf("ref %.1f BPM: beat never detected as present\n", refBpm);
    }
    if (phase) {
        // For each predicted beat (after --from and after the first 8 s of a lock), find the nearest
        // kick onset within half a beat. "on" = within ±40 ms; "off-beat" = the nearest kick is
        // closer to the half-beat point, which means we're locked half a beat out.
        std::vector<double> d; int on = 0, offbeat = 0, considered = 0;
        for (size_t i = 0; i < a.beatTimes.size(); ++i) {
            double b = a.beatTimes[i], P = 60.0 / a.beatBpms[i];
            if (b < std::max(scoreFrom, 8.0)) continue;
            double best = 1e9;
            for (double k : a.kickTimes) if (std::fabs(k - b) < std::fabs(best)) best = k - b;
            if (std::fabs(best) > P / 2) continue;
            ++considered;
            if (std::fabs(best) > P / 4) { ++offbeat; continue; }
            d.push_back(best * 1000);
            if (std::fabs(best) <= 0.04) ++on;
        }
        std::sort(d.begin(), d.end());
        double med = d.empty() ? 0 : d[d.size() / 2];
        std::vector<double> dev; for (double x : d) dev.push_back(std::fabs(x - med));
        std::sort(dev.begin(), dev.end());
        std::printf("phase: beats with a nearby kick %d; kick-on-beat %.0f%%; off-beat %.0f%%; median kick-minus-beat %+.1f ms; spread %.1f ms\n",
                    considered, considered ? 100.0 * on / considered : 0, considered ? 100.0 * offbeat / considered : 0,
                    med, dev.empty() ? 0 : dev[dev.size() / 2]);
    }
    if (printBeats) {
        std::printf("#beats\n");
        for (size_t i = 0; i < a.beatTimes.size(); ++i) std::printf("%.4f %.2f\n", a.beatTimes[i], a.beatBpms[i]);
        std::printf("#downbeats\n");
        for (double t : a.downbeatTimes) std::printf("%.4f\n", t);
    }
    if (printKicks) { std::printf("#kicks\n"); for (double t : a.kickTimes) std::printf("%.4f\n", t); }
    if (printOnsets) for (double t : a.onsetTimes) std::printf("%.4f\n", t);
    return 0;
}
