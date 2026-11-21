#pragma once
#include "audio/RingBuffer.h"
#include <memory>
#include <string>

namespace choreo {

// An audio source that pushes mono float samples into a ring buffer.
class Capture {
public:
    virtual ~Capture() = default;
    virtual bool start(RingBuffer* out) = 0;
    virtual void stop() = 0;
    virtual double sampleRate() const = 0;
    virtual std::string name() const = 0;
};

// System audio ("what you hear"). Returns nullptr if unsupported/denied.
std::unique_ptr<Capture> createSystemCapture();
// Audio from one app only (bundle ID prefix, e.g. "com.spotify.client"). With mute, the
// app's audio is captured but not played to the speakers. nullptr if unsupported.
std::unique_ptr<Capture> createAppCapture(const std::string& bundlePrefix, bool mute);
// Default recording device (microphone / line-in) via SDL.
std::unique_ptr<Capture> createMicCapture();

} // namespace choreo
