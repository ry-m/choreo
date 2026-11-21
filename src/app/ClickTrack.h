#pragma once
#include <SDL3/SDL.h>
#include <cmath>

namespace choreo {

// Plays a steady click track through the default output, for A/V calibration. Choreo then
// hears its own clicks through system capture, so the flash on screen goes through the whole
// pipeline (capture -> analysis -> prediction -> display) exactly like real music does.
class ClickTrack {
public:
    explicit ClickTrack(double bpm = 120.0) : bpm_(bpm) {}
    ~ClickTrack() { stop(); }

    bool start() {
        SDL_AudioSpec spec{SDL_AUDIO_F32, 1, kRate};
        stream_ = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, &ClickTrack::fill, this);
        if (!stream_) { SDL_Log("Click track: %s", SDL_GetError()); return false; }
        SDL_ResumeAudioStreamDevice(stream_);
        return true;
    }
    void stop() {
        if (stream_) SDL_DestroyAudioStream(stream_);
        stream_ = nullptr;
    }

private:
    static constexpr int kRate = 48000;

    static void SDLCALL fill(void* user, SDL_AudioStream* s, int additional, int) {
        auto* self = static_cast<ClickTrack*>(user);
        float buf[1024];
        int need = additional / int(sizeof(float));
        const double period = 60.0 / self->bpm_ * kRate;
        while (need > 0) {
            int n = need < 1024 ? need : 1024;
            for (int i = 0; i < n; ++i) {
                double pos = std::fmod(double(self->sample_ + i), period); // samples since the click
                double t = pos / kRate;
                // Kick-like thump (so the low band fires) plus a bright tick (sharp onset).
                double thump = std::sin(2 * M_PI * (55 + 90 * std::exp(-t * 40)) * t) * std::exp(-t * 25);
                double tick = t < 0.004 ? std::sin(2 * M_PI * 2000 * t) * (1 - t / 0.004) : 0;
                buf[i] = float(0.5 * thump + 0.3 * tick);
            }
            self->sample_ += n;
            SDL_PutAudioStreamData(s, buf, n * int(sizeof(float)));
            need -= n;
        }
    }

    double bpm_;
    long long sample_ = 0;
    SDL_AudioStream* stream_ = nullptr;
};

} // namespace choreo
