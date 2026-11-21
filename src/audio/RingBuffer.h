#pragma once
#include <atomic>
#include <cstddef>
#include <vector>

namespace choreo {

// Lock-free single-producer / single-consumer float ring buffer.
// Producer: real-time audio thread. Consumer: analysis.
class RingBuffer {
public:
    explicit RingBuffer(size_t capacityPow2 = 1 << 16)
        : buf_(capacityPow2), mask_(capacityPow2 - 1) {}

    // Returns number written (drops on overflow rather than blocking the audio thread).
    size_t write(const float* data, size_t n) {
        size_t w = write_.load(std::memory_order_relaxed);
        size_t r = read_.load(std::memory_order_acquire);
        size_t space = buf_.size() - (w - r);
        if (n > space) n = space;
        for (size_t i = 0; i < n; ++i) buf_[(w + i) & mask_] = data[i];
        write_.store(w + n, std::memory_order_release);
        return n;
    }

    size_t read(float* out, size_t n) {
        size_t r = read_.load(std::memory_order_relaxed);
        size_t w = write_.load(std::memory_order_acquire);
        size_t avail = w - r;
        if (n > avail) n = avail;
        for (size_t i = 0; i < n; ++i) out[i] = buf_[(r + i) & mask_];
        read_.store(r + n, std::memory_order_release);
        return n;
    }

    size_t available() const {
        return write_.load(std::memory_order_acquire) - read_.load(std::memory_order_relaxed);
    }

private:
    std::vector<float> buf_;
    size_t mask_;
    alignas(64) std::atomic<size_t> write_{0};
    alignas(64) std::atomic<size_t> read_{0};
};

} // namespace choreo
