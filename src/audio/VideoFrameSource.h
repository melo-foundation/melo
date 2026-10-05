#pragma once
#include "VideoFrame.h"
#include <QString>
#include <memory>

// What a surface draws this frame: the current picture, the incoming one
// during a crossfade, how far the fade has gone, and the track that owns the
// position (empty: unknown).
struct VideoView {
    std::shared_ptr<const VideoPixels> main;
    std::shared_ptr<const VideoPixels> incoming;
    double mix = 0;
    QString trackId;
};

class VideoFrameSource {
public:
    virtual ~VideoFrameSource() = default;
    virtual VideoView videoView() = 0;
};
