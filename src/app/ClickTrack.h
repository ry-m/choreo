#pragma once
#include <SDL3/SDL.h>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>
#if defined(__APPLE__)
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
extern char** environ;
#endif

namespace choreo {

// Plays a steady click track for A/V calibration. Choreo then hears its own clicks through
// system capture, so the flash on screen goes through the whole pipeline (capture -> analysis
// -> prediction -> display) exactly like real music does.
//
// The click is played by a separate process (macOS `afplay`), because a process tap does not
// capture audio from the app that created it.
class ClickTrack {
public:
    explicit ClickTrack(double bpm = 120.0) : bpm_(bpm) {}
    ~ClickTrack() { stop(); }

    bool start() {
#if defined(__APPLE__)
        char* dir = SDL_GetPrefPath("Choreo", "Choreo");
        path_ = std::string(dir ? dir : "") + "calibration_click.wav";
        SDL_free(dir);
        if (!writeWav(path_)) { SDL_Log("Click track: cannot write %s", path_.c_str()); return false; }
        const char* args[] = {"/usr/bin/afplay", path_.c_str(), nullptr};
        if (posix_spawn(&pid_, args[0], nullptr, nullptr, const_cast<char* const*>(args), environ) != 0) {
            SDL_Log("Click track: cannot start afplay");
            pid_ = 0;
            return false;
        }
        return true;
#else
        SDL_Log("Click track: not implemented on this platform yet");
        return false;
#endif
    }
    void stop() {
#if defined(__APPLE__)
        if (pid_ > 0) { kill(pid_, SIGTERM); waitpid(pid_, nullptr, 0); }
        pid_ = 0;
#endif
    }

private:
    // 3 minutes of clicks: a kick-like thump (so the low band fires) plus a bright tick.
    bool writeWav(const std::string& path) const {
        const int rate = 48000;
        const size_t n = size_t(rate) * 180;
        const double period = 60.0 / bpm_ * rate;
        std::vector<int16_t> pcm(n);
        for (size_t i = 0; i < n; ++i) {
            double t = std::fmod(double(i), period) / rate;
            double thump = std::sin(2 * M_PI * (55 + 90 * std::exp(-t * 40)) * t) * std::exp(-t * 25);
            double tick = t < 0.004 ? std::sin(2 * M_PI * 2000 * t) * (1 - t / 0.004) : 0;
            pcm[i] = int16_t(std::lround((0.5 * thump + 0.3 * tick) * 32767));
        }
        std::FILE* f = std::fopen(path.c_str(), "wb");
        if (!f) return false;
        auto u32 = [&](uint32_t v) { std::fwrite(&v, 4, 1, f); };
        auto u16 = [&](uint16_t v) { std::fwrite(&v, 2, 1, f); };
        uint32_t bytes = uint32_t(n * 2);
        std::fwrite("RIFF", 1, 4, f); u32(36 + bytes); std::fwrite("WAVEfmt ", 1, 8, f);
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16);
        std::fwrite("data", 1, 4, f); u32(bytes);
        std::fwrite(pcm.data(), 2, n, f);
        std::fclose(f);
        return true;
    }

    double bpm_;
    std::string path_;
#if defined(__APPLE__)
    pid_t pid_ = 0;
#endif
};

} // namespace choreo
