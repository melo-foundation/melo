#pragma once
#include "VideoFrame.h"
#include <atomic>
#include <deque>
#include <mutex>
#include <optional>

// Filled and drained by VideoDeck::frameAt(). The rule is "the newest frame at
// or under the audio position"; everything older is released.
class VideoFrameRing {
public:
    explicit VideoFrameRing(std::size_t cap = 8) : cap_(cap) {}

    void push(VideoFrame f) {
        std::lock_guard<std::mutex> lk(m_);
        if (f.gen < gen_.load()) return;          // decoded before a seek's flush
        if (frames_.size() >= cap_) frames_.pop_front();
        frames_.push_back(std::move(f));
    }

    std::optional<VideoFrame> take(double position, double lead = 0.02) {
        std::lock_guard<std::mutex> lk(m_);
        const uint64_t gen = gen_.load();
        std::optional<VideoFrame> best;
        std::size_t drop = 0;
        for (std::size_t i = 0; i < frames_.size(); ++i) {
            const VideoFrame& f = frames_[i];
            if (f.gen < gen) { drop = i + 1; continue; }
            if (f.pts <= position + lead) { best = f; drop = i + 1; }
            else break;
        }
        frames_.erase(frames_.begin(), frames_.begin() + long(drop));
        return best;
    }

    // pts of the newest frame held, or nullopt: the deck pulls more only while
    // this is at or under the position it needs
    std::optional<double> newestPts() const {
        std::lock_guard<std::mutex> lk(m_);
        if (frames_.empty()) return std::nullopt;
        return frames_.back().pts;
    }

    void bumpGeneration() { ++gen_; std::lock_guard<std::mutex> lk(m_); frames_.clear(); }
    uint64_t generation() const { return gen_.load(); }

private:
    mutable std::mutex m_;
    std::deque<VideoFrame> frames_;
    std::atomic<uint64_t> gen_{0};
    std::size_t cap_;
};
