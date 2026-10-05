#pragma once
#include "VideoFrame.h"
#include <QSGMaterial>
#include <QSGMaterialShader>
#include <cstdint>
#include <memory>

class QQuickWindow;
class QRhi;
class QRhiResourceUpdateBatch;
class QSGTexture;
class VideoPlanesShader;

// The planes of one frame as textures the material samples;
// makeUploadTextures() uploads them from CPU memory.
class VideoTextures {
public:
    virtual ~VideoTextures() = default;
    virtual bool update(const VideoPixels& px, QRhi* rhi, QRhiResourceUpdateBatch* batch) = 0;   // false: cannot take this frame
    virtual QSGTexture* plane(int i) const = 0;
};

std::unique_ptr<VideoTextures> makeUploadTextures(QQuickWindow* window);

// Why this window cannot draw planes, or nullptr when it can.
const char* videoPlanesUnusable(QQuickWindow* window);

// Draws an NV12 or I420 frame: the planes sampled, YUV→RGB in the fragment
// shader. The frame's bytes are read at render time, so the frame is held
// until the next setFrame().
class VideoPlanesMaterial : public QSGMaterial {
public:
    VideoPlanesMaterial(QQuickWindow* window, VideoFormat format);
    QSGMaterialType* type() const override;
    QSGMaterialShader* createShader(QSGRendererInterface::RenderMode) const override;
    int compare(const QSGMaterial* other) const override;
    VideoFormat format() const { return format_; }
    void setFrame(std::shared_ptr<const VideoPixels> frame);

private:
    friend class VideoPlanesShader;
    QQuickWindow* window_;
    VideoFormat format_;
    std::shared_ptr<const VideoPixels> frame_;
    uint64_t serial_ = 0;      // bumped by setFrame
    uint64_t uploaded_ = 0;    // serial of the frame in the textures
    std::unique_ptr<VideoTextures> textures_;
};
