// Live tempo evaluation through the Spotify desktop app (macOS).
//
// Plays each track listed in a CSV via AppleScript, captures Spotify's audio with a muted
// per-app tap (so nothing comes out of the speakers), and scores Choreo's live analysis
// against the reference BPM. One analyser runs across all tracks, exactly like the app,
// so song changes and re-locking are part of the test.
//
// Usage: choreo-live-eval tracks.csv [--seconds 75] [--out results.csv] [--audible] [--only N]
//                         [--match TEXT] [--record DIR]
//   --match TEXT  only tracks whose title contains TEXT (comma-separated list allowed)
//   --record DIR  also save each captured track as DIR/<title>.wav (local test cache only —
//                 never commit these)
//   --full        record each track for its whole length (from Spotify), up to 10 minutes
//   --skip-existing  skip tracks already recorded in --record DIR (resume an interrupted run)
// Fail-safe: Spotify is paused on any error, on Ctrl-C/kill, and at the end.
// CSV columns: uri,title,artist,bpm,bpm_source   (# lines are comments)
#include "analysis/Analyzer.h"
#include "audio/Capture.h"
#include <algorithm>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

using namespace choreo;

namespace {

struct Track { std::string uri, title, artist, bpmSource; double bpm = 0; };

std::vector<std::string> splitCsv(const std::string& line) {
    std::vector<std::string> out;
    std::string cur; bool quoted = false;
    for (char c : line) {
        if (c == '"') quoted = !quoted;
        else if (c == ',' && !quoted) { out.push_back(cur); cur.clear(); }
        else cur += c;
    }
    out.push_back(cur);
    return out;
}

std::string osascript(const std::string& script) {
    std::string cmd = "osascript -e '" + script + "' 2>/dev/null";
    std::string out;
    if (FILE* p = popen(cmd.c_str(), "r")) {
        char buf[256];
        while (fgets(buf, sizeof buf, p)) out += buf;
        pclose(p);
    }
    while (!out.empty() && (out.back() == '\n' || out.back() == '\r')) out.pop_back();
    return out;
}

// Half/double of the reference is an acceptable reading; 3:2 or 4:3 is a wrong tempo.
bool related(double a, double b) {
    double r = a / b;
    for (double q : {1.0, 2.0, 0.5})
        if (std::fabs(r / q - 1.0) < 0.04) return true;
    return false;
}

void writeWav(const std::string& path, const std::vector<float>& x, double sr) {
    std::FILE* f = std::fopen(path.c_str(), "wb");
    if (!f) return;
    auto u32 = [&](uint32_t v) { std::fwrite(&v, 4, 1, f); };
    auto u16 = [&](uint16_t v) { std::fwrite(&v, 2, 1, f); };
    uint32_t bytes = uint32_t(x.size() * 2);
    std::fwrite("RIFF", 1, 4, f); u32(36 + bytes); std::fwrite("WAVEfmt ", 1, 8, f);
    u32(16); u16(1); u16(1); u32(uint32_t(sr)); u32(uint32_t(sr) * 2); u16(2); u16(16);
    std::fwrite("data", 1, 4, f); u32(bytes);
    for (float v : x) { int16_t s = int16_t(std::lround(std::clamp(v, -1.f, 1.f) * 32767)); std::fwrite(&s, 2, 1, f); }
    std::fclose(f);
}

bool matches(const std::string& title, const std::string& list) {
    if (list.empty()) return true;
    std::stringstream ss(list);
    for (std::string item; std::getline(ss, item, ',');)
        if (!item.empty() && title.find(item) != std::string::npos) return true;
    return false;
}

volatile std::sig_atomic_t gStop = 0;
void onSignal(int) { gStop = 1; }

} // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s tracks.csv [--seconds N] [--out file.csv] [--audible] [--only N]\n", argv[0]);
        return 1;
    }
    double seconds = 75;
    bool audible = false;
    int only = -1;
    std::string outPath, match, recordDir;
    bool full = false, skipExisting = false;
    std::signal(SIGINT, onSignal);
    std::signal(SIGTERM, onSignal);
    std::signal(SIGHUP, onSignal);
    // Never leave Spotify playing out loud if we stop for any reason.
    std::atexit([] { std::system("osascript -e 'tell application \"Spotify\" to pause' >/dev/null 2>&1"); });
    for (int i = 2; i < argc; ++i) {
        if (!std::strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = std::atof(argv[++i]);
        else if (!std::strcmp(argv[i], "--out") && i + 1 < argc) outPath = argv[++i];
        else if (!std::strcmp(argv[i], "--audible")) audible = true;
        else if (!std::strcmp(argv[i], "--only") && i + 1 < argc) only = std::atoi(argv[++i]);
        else if (!std::strcmp(argv[i], "--match") && i + 1 < argc) match = argv[++i];
        else if (!std::strcmp(argv[i], "--record") && i + 1 < argc) recordDir = argv[++i];
        else if (!std::strcmp(argv[i], "--full")) full = true;
        else if (!std::strcmp(argv[i], "--skip-existing")) skipExisting = true;
    }

    std::vector<Track> tracks;
    std::ifstream in(argv[1]);
    for (std::string line; std::getline(in, line);) {
        if (line.empty() || line[0] == '#' || line.rfind("uri,", 0) == 0) continue;
        auto f = splitCsv(line);
        if (f.size() < 4) continue;
        Track t{f[0], f[1], f[2], f.size() > 4 ? f[4] : "", std::atof(f[3].c_str())};
        if (t.bpm > 0) tracks.push_back(t);
    }
    if (tracks.empty()) { std::fprintf(stderr, "no tracks in %s\n", argv[1]); return 1; }

    std::FILE* out = outPath.empty() ? nullptr : std::fopen(outPath.c_str(), "w");
    if (out) std::fprintf(out, "title,artist,ref_bpm,final_bpm,present_pct,correct_pct,related_pct,lock_sec,flips\n");

    RingBuffer ring(1 << 18);
    std::unique_ptr<Analyzer> analyzer;
    std::vector<float> buf(8192);
    double sumCorrect = 0, sumRelated = 0; int scored = 0;

    for (size_t ti = 0; ti < tracks.size(); ++ti) {
        if (only >= 0 && int(ti) != only) continue;
        const Track& t = tracks[ti];
        if (!matches(t.title, match)) continue;
        if (gStop) break;
        std::string safeName = t.title;
        for (char& c : safeName) if (c == '/' || c == ':') c = '_';
        if (skipExisting && !recordDir.empty()) {
            std::FILE* ex = std::fopen((recordDir + "/" + safeName + ".wav").c_str(), "rb");
            if (ex) { std::fclose(ex); continue; }
        }
        osascript("tell application \"Spotify\" to play track \"" + t.uri + "\"");
        // Wait (up to 8 s) until Spotify has actually switched to this track and is playing.
        std::string playing;
        for (int w = 0; w < 40; ++w) {
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
            playing = osascript("tell application \"Spotify\" to (id of current track) & \"|\" & (player state as string)");
            if (playing == t.uri + "|playing") break;
        }
        playing = playing.substr(0, playing.find('|'));
        if (playing != t.uri) {
            std::printf("%-32s SKIP (Spotify is playing %s — ad or unavailable?)\n", t.title.c_str(), playing.c_str());
            continue;
        }

        // A fresh tap per track (Spotify may start new audio helper processes), but one analyser.
        auto cap = createAppCapture("com.spotify.client", !audible);
        if (!cap || !cap->start(&ring)) { std::fprintf(stderr, "could not tap Spotify audio — stopping (Spotify paused)\n"); return 1; }
        double trackSeconds = seconds;
        if (full) {
            double ms = std::atof(osascript("tell application \"Spotify\" to duration of current track").c_str());
            trackSeconds = std::clamp(ms / 1000.0 - 1.0, 20.0, 600.0);
        }
        if (!analyzer) analyzer = std::make_unique<Analyzer>(cap->sampleRate());

        const double t0 = analyzer->state().time;
        long samples = 0, present = 0, exact = 0, rel = 0, flips = 0;
        double lockSec = -1, lastBpm = 0, nextSample = t0;
        auto wallStart = std::chrono::steady_clock::now();
        std::vector<float> recording;
        while (analyzer->state().time - t0 < trackSeconds && !gStop) {
            size_t n = ring.read(buf.data(), buf.size());
            if (n) {
                analyzer->process(buf.data(), n);
                if (!recordDir.empty()) recording.insert(recording.end(), buf.begin(), buf.begin() + n);
            }
            else std::this_thread::sleep_for(std::chrono::milliseconds(5));
            const auto& s = analyzer->state();
            while (s.time >= nextSample) {
                nextSample += 0.1;
                ++samples;
                if (!s.beatPresent) continue;
                ++present;
                bool ok = std::fabs(s.bpm - t.bpm) / t.bpm < 0.04;
                if (ok) { ++exact; if (lockSec < 0) lockSec = s.time - t0; }
                if (related(s.bpm, t.bpm)) ++rel;
                if (lastBpm > 0 && std::fabs(s.bpm - lastBpm) / lastBpm > 0.04) ++flips;
                lastBpm = s.bpm;
            }
            // Guard against stalls (e.g. playback stopped): 3x real time budget.
            if (std::chrono::steady_clock::now() - wallStart > std::chrono::duration<double>(trackSeconds * 1.5 + 10)) {
                std::fprintf(stderr, "%s: playback stalled, moving on\n", t.title.c_str());
                break;
            }
        }
        cap->stop();
        if (!recordDir.empty() && !gStop) writeWav(recordDir + "/" + safeName + ".wav", recording, cap->sampleRate());

        double presentPct = samples ? 100.0 * present / samples : 0;
        double correctPct = present ? 100.0 * exact / present : 0;
        double relatedPct = present ? 100.0 * rel / present : 0;
        std::printf("%-32.32s ref %6.1f  final %6.1f  present %3.0f%%  correct %5.1f%%  related %5.1f%%  lock %5.1fs  flips %ld\n",
                    t.title.c_str(), t.bpm, analyzer->state().bpm, presentPct, correctPct, relatedPct, lockSec, flips);
        std::fflush(stdout);
        if (out) {
            std::fprintf(out, "\"%s\",\"%s\",%.1f,%.2f,%.1f,%.1f,%.1f,%.1f,%ld\n", t.title.c_str(), t.artist.c_str(),
                         t.bpm, analyzer->state().bpm, presentPct, correctPct, relatedPct, lockSec, flips);
            std::fflush(out);
        }
        if (present) { sumCorrect += correctPct; sumRelated += relatedPct; ++scored; }
    }
    osascript("tell application \"Spotify\" to pause");
    if (scored)
        std::printf("\nMEAN over %d tracks: correct %.1f%%, correct-or-related %.1f%%\n", scored, sumCorrect / scored, sumRelated / scored);
    if (out) std::fclose(out);
    return 0;
}
