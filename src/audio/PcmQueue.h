#pragma once
#include <mutex>
#include <deque>
#include <vector>
#include <cstddef>

// Hand-off from the GStreamer streaming thread (push) to the GL thread (drain).
// Bounded; drops oldest when the consumer stalls (e.g. window occluded on Wayland).
class PcmQueue {
public:
    void push(const float* data, std::size_t floatCount) {
        std::lock_guard<std::mutex> lk(m_);
        chunks_.emplace_back(data, data + floatCount);
        while (chunks_.size() > kMaxChunks) chunks_.pop_front();
    }

    // Calls feed(ptr, floatCount) for the newest few queued chunks, then
    // empties the queue. feed runs on the caller's (GL) thread; projectM PCM is
    // only touched here. Older chunks are dropped: after a stall (view hidden,
    // preset shaders compiling) the backlog would overrun projectM's PCM ring
    // and drive the beat detector off already-heard audio, a visible lurch.
    template <class F>
    void drain(F&& feed) {
        std::deque<std::vector<float>> local;
        {
            std::lock_guard<std::mutex> lk(m_);
            local.swap(chunks_);
        }
        while (local.size() > kMaxFeed) local.pop_front();
        for (auto& c : local) feed(c.data(), c.size());
    }

private:
    static constexpr std::size_t kMaxChunks = 32;
    // projectM's PCM ring is 2048 frames per channel; chunks are 10ms (480
    // frames), so anything past four is written and immediately overwritten.
    static constexpr std::size_t kMaxFeed = 4;
    std::mutex m_;
    std::deque<std::vector<float>> chunks_;
};
