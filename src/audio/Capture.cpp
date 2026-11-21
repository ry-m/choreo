#include "audio/Capture.h"
#include <SDL3/SDL.h>
#include <vector>

namespace choreo {

namespace {

class SDLMicCapture final : public Capture {
public:
    bool start(RingBuffer* out) override {
        out_ = out;
        SDL_AudioSpec spec{SDL_AUDIO_F32, 1, 48000};
        stream_ = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_RECORDING, &spec, &SDLMicCapture::callback, this);
        if (!stream_) {
            SDL_Log("Mic capture failed: %s", SDL_GetError());
            return false;
        }
        SDL_ResumeAudioStreamDevice(stream_);
        return true;
    }
    void stop() override {
        if (stream_) SDL_DestroyAudioStream(stream_);
        stream_ = nullptr;
    }
    ~SDLMicCapture() override { stop(); }
    double sampleRate() const override { return 48000.0; }
    std::string name() const override { return "Microphone (default input)"; }

private:
    static void SDLCALL callback(void* user, SDL_AudioStream* s, int additional, int) {
        auto* self = static_cast<SDLMicCapture*>(user);
        int avail = SDL_GetAudioStreamAvailable(s);
        if (avail <= 0) return;
        (void)additional;
        self->tmp_.resize(avail / sizeof(float));
        int got = SDL_GetAudioStreamData(s, self->tmp_.data(), avail);
        if (got > 0) self->out_->write(self->tmp_.data(), got / sizeof(float));
    }
    SDL_AudioStream* stream_ = nullptr;
    RingBuffer* out_ = nullptr;
    std::vector<float> tmp_;
};

} // namespace

std::unique_ptr<Capture> createMicCapture() { return std::make_unique<SDLMicCapture>(); }

#if !defined(__APPLE__)
std::unique_ptr<Capture> createSystemCapture() { return nullptr; } // TODO: WASAPI loopback / PipeWire
std::unique_ptr<Capture> createAppCapture(const std::string&, bool) { return nullptr; }
#endif

} // namespace choreo
