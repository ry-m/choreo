#pragma once
#include "audio/RingBuffer.h"
#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#if defined(__APPLE__)
#include <time.h>
#else
#include <chrono>
#endif

namespace choreo {

// Monotonic clock shared by capture timestamps and the render loop (ns).
inline uint64_t nowNs() {
#if defined(__APPLE__)
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); // same base as Core Audio host time
#else
    return uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
#endif
}

// An audio source that pushes mono float samples into a ring buffer.
// It also publishes a clock pairing: "sample number N (counting from start) was captured at
// host time T", so the app can work out when any analysed sample was actually heard.
class Capture {
public:
    virtual ~Capture() = default;
    virtual bool start(RingBuffer* out) = 0;
    virtual void stop() = 0;
    virtual double sampleRate() const = 0;
    virtual std::string name() const = 0;
    // Seconds between a sample being captured and it reaching the listener's ears
    // (output device + stream latency + safety offset). 0 if unknown (e.g. microphone).
    virtual double outputLatencySec() const { return 0.0; }

    // Latest clock pairing; returns false until audio has arrived.
    bool clock(uint64_t& sampleIndex, uint64_t& hostNs) const {
        hostNs = clockNs_.load(std::memory_order_acquire);
        sampleIndex = clockIndex_.load(std::memory_order_acquire);
        return hostNs != 0;
    }

protected:
    // Called by the audio thread before writing a buffer whose first sample was captured at hostNs.
    void publishClock(uint64_t hostNs) {
        clockIndex_.store(written_, std::memory_order_release);
        clockNs_.store(hostNs, std::memory_order_release);
    }
    // Write samples and keep the running sample count in step (dropped samples aren't counted).
    void push(RingBuffer* out, const float* x, size_t n) { written_ += out->write(x, n); }

private:
    uint64_t written_ = 0;                  // audio thread only
    std::atomic<uint64_t> clockIndex_{0}, clockNs_{0};
};

// System audio ("what you hear"). Returns nullptr if unsupported/denied.
std::unique_ptr<Capture> createSystemCapture();
// Audio from one app only (bundle ID prefix, e.g. "com.spotify.client"). With mute, the
// app's audio is captured but not played to the speakers. nullptr if unsupported.
std::unique_ptr<Capture> createAppCapture(const std::string& bundlePrefix, bool mute);
// Default recording device (microphone / line-in) via SDL.
std::unique_ptr<Capture> createMicCapture();

} // namespace choreo
