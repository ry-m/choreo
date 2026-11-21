// Offline analysis of an audio file (MP3/M4A/WAV/... on macOS).
// Usage: choreo-analyze song.mp3 [--beats] [--onsets] [--timeline] [--ref-bpm X]
//   --timeline   one line per second: tempo, confidence, pulse clarity, beat presence
//   --ref-bpm X  score tempo accuracy against a known tempo (see tests/reference/tempos.csv)
//   --from S     only score from S seconds on (e.g. the second song of a joined pair)
#include "Wav.h"
#include "analysis/Analyzer.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <initializer_list>

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s file [--beats] [--onsets] [--timeline] [--ref-bpm X]\n", argv[0]);
        return 1;
    }
    bool printBeats = false, printOnsets = false, timeline = false;
    double refBpm = 0, scoreFrom = 0;
    for (int i = 2; i < argc; ++i) {
        if (!std::strcmp(argv[i], "--beats")) printBeats = true;
        else if (!std::strcmp(argv[i], "--onsets")) printOnsets = true;
        else if (!std::strcmp(argv[i], "--timeline")) timeline = true;
        else if (!std::strcmp(argv[i], "--ref-bpm") && i + 1 < argc) refBpm = std::atof(argv[++i]);
        else if (!std::strcmp(argv[i], "--from") && i + 1 < argc) scoreFrom = std::atof(argv[++i]);
    }
    std::vector<float> audio; double sr = 0;
    if (!choreo::loadAudioMono(argv[1], audio, sr)) { std::fprintf(stderr, "failed to read %s\n", argv[1]); return 1; }

    choreo::Analyzer a(sr);
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
    if (printBeats) for (double t : a.beatTimes) std::printf("%.4f\n", t);
    if (printOnsets) for (double t : a.onsetTimes) std::printf("%.4f\n", t);
    return 0;
}
