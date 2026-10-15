#pragma once
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>

enum class VideoFormat { RGBA, NV12, I420 };
enum class VideoMatrix { BT601, BT709, BT2020 };

// How the planes' YUV maps to RGB: the stream's matrix, and whether black is 0 or 16.
struct VideoColor {
    VideoMatrix matrix = VideoMatrix::BT709;
    bool fullRange = false;
};

// One plane as the decoder laid it out. `width`/`height` are this plane's
// texels (an NV12 chroma texel is one UV pair), `stride` is bytes.
struct VideoPlane {
    const unsigned char* data = nullptr;
    int width = 0;
    int height = 0;
    int stride = 0;
};

// One decoded frame. RGBA: planes[0]. NV12: Y, UV. I420: Y, U, V. `keepAlive`
// holds whatever the planes point into (a mapped GstSample in melo, a vector
// in tests). A planar frame carries `makeRgba` for a renderer without planar
// textures; rgbaOf() makes the twin once and keeps it in the frame.
struct VideoPixels {
    VideoFormat format = VideoFormat::RGBA;
    int width = 0;
    int height = 0;
    int planeCount = 1;
    VideoPlane planes[3];
    VideoColor color;
    double pts = 0;            // seconds into the track, as its frame's
    std::shared_ptr<void> keepAlive;
    std::function<std::shared_ptr<const VideoPixels>()> makeRgba;
    mutable std::mutex twinMutex;
    mutable std::shared_ptr<const VideoPixels> twin;
};

struct VideoFrame {
    double pts = 0;            // seconds into the track
    uint64_t gen = 0;          // seek generation it was decoded in
    std::shared_ptr<const VideoPixels> px;
};

// The frame itself when it is RGBA, else its twin; null for a planar frame with no maker.
inline std::shared_ptr<const VideoPixels> rgbaOf(const std::shared_ptr<const VideoPixels>& px) {
    if (!px || px->format == VideoFormat::RGBA) return px;
    std::lock_guard<std::mutex> lk(px->twinMutex);
    if (!px->twin && px->makeRgba) px->twin = px->makeRgba();
    return px->twin;
}
