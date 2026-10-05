#include "VideoPlanes.h"
#include "VideoColorMatrix.h"
#include <QMatrix4x4>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QSGTexture>
#include <rhi/qrhi.h>
#include <cstring>

namespace {

// One QSGTexture per plane, rebuilt when a plane's size or format moves.
class UploadTextures : public VideoTextures {
public:
    explicit UploadTextures(QQuickWindow* w) : window_(w) {}

    bool update(const VideoPixels& px, QRhi* rhi, QRhiResourceUpdateBatch* batch) override {
        count_ = px.planeCount;
        for (int p = 0; p < count_; ++p) {
            const VideoPlane& pl = px.planes[p];
            const QRhiTexture::Format fmt =
                (px.format == VideoFormat::NV12 && p == 1) ? QRhiTexture::RG8 : QRhiTexture::R8;
            const QSize size(pl.width, pl.height);
            QRhiTexture* rt = tex_[p] ? tex_[p]->rhiTexture() : nullptr;
            if (!rt || rt->pixelSize() != size || rt->format() != fmt) {
                tex_[p].reset();
                rt = rhi->newTexture(fmt, size, 1);
                if (!rt->create()) { delete rt; return false; }
                tex_[p].reset(window_->createTextureFromRhiTexture(rt));   // the wrapper owns rt
                if (!tex_[p]) { delete rt; return false; }
                tex_[p]->setFiltering(QSGTexture::Linear);
                tex_[p]->setHorizontalWrapMode(QSGTexture::ClampToEdge);
                tex_[p]->setVerticalWrapMode(QSGTexture::ClampToEdge);
            }
            // No copy: the material pins the frame until the next sync, past this frame's endFrame().
            QRhiTextureSubresourceUploadDescription sub(QByteArray::fromRawData(
                reinterpret_cast<const char*>(pl.data), pl.stride * pl.height));
            sub.setDataStride(quint32(pl.stride));
            batch->uploadTexture(rt, QRhiTextureUploadDescription(QRhiTextureUploadEntry(0, 0, sub)));
        }
        return true;
    }

    QSGTexture* plane(int i) const override { return i >= 0 && i < count_ ? tex_[i].get() : nullptr; }

private:
    QQuickWindow* window_;
    std::unique_ptr<QSGTexture> tex_[3];
    int count_ = 0;
};

}  // namespace

std::unique_ptr<VideoTextures> makeUploadTextures(QQuickWindow* window) {
    return std::make_unique<UploadTextures>(window);
}

const char* videoPlanesUnusable(QQuickWindow* w) {
    if (!w) return "no window";
    if (w->rendererInterface()->graphicsApi() == QSGRendererInterface::Software) return "software scene graph";
    QRhi* rhi = w->rhi();
    if (!rhi) return "no rhi";
    if (!rhi->isTextureFormatSupported(QRhiTexture::R8)) return "no R8 textures";
    if (!rhi->isTextureFormatSupported(QRhiTexture::RG8)) return "no RG8 textures";
    if (!rhi->isFeatureSupported(QRhi::ImageDataStride)) return "no row stride on upload";
    return nullptr;
}

class VideoPlanesShader : public QSGMaterialShader {
public:
    explicit VideoPlanesShader(VideoFormat f) {
        setShaderFileName(VertexStage, QStringLiteral(":/melo/shaders/videoplanes.vert.qsb"));
        setShaderFileName(FragmentStage, f == VideoFormat::NV12
            ? QStringLiteral(":/melo/shaders/videoplanes_nv12.frag.qsb")
            : QStringLiteral(":/melo/shaders/videoplanes_i420.frag.qsb"));
    }

    // The upload happens once a frame, where the render state hands out the update batch.
    bool updateUniformData(RenderState& state, QSGMaterial* newMat, QSGMaterial*) override {
        auto* m = static_cast<VideoPlanesMaterial*>(newMat);
        if (m->frame_ && m->uploaded_ != m->serial_) {
            if (!m->textures_) m->textures_ = makeUploadTextures(m->window_);
            if (m->textures_->update(*m->frame_, state.rhi(), state.resourceUpdateBatch()))
                m->uploaded_ = m->serial_;
        }
        // std140: mat4 at 0, mat4 at 64, float at 128
        QByteArray* buf = state.uniformData();
        Q_ASSERT(buf->size() >= 132);
        if (state.isMatrixDirty())
            std::memcpy(buf->data(), state.combinedMatrix().constData(), 64);
        if (m->frame_) {
            // videoColorMatrix is row-major; QMatrix4x4(const float*) reads row-major and
            // constData() is column-major, the layout a GLSL mat4 uniform takes.
            const QMatrix4x4 cm(videoColorMatrix(m->frame_->color).data());
            std::memcpy(buf->data() + 64, cm.constData(), 64);
        }
        if (state.isOpacityDirty()) {
            const float o = state.opacity();
            std::memcpy(buf->data() + 128, &o, 4);
        }
        return true;
    }

    void updateSampledImage(RenderState&, int binding, QSGTexture** texture,
                            QSGMaterial* newMat, QSGMaterial*) override {
        auto* m = static_cast<VideoPlanesMaterial*>(newMat);
        *texture = m->textures_ ? m->textures_->plane(binding - 1) : nullptr;
    }
};

VideoPlanesMaterial::VideoPlanesMaterial(QQuickWindow* window, VideoFormat format)
    : window_(window), format_(format) {}

QSGMaterialType* VideoPlanesMaterial::type() const {
    static QSGMaterialType nv12, i420;
    return format_ == VideoFormat::NV12 ? &nv12 : &i420;
}

QSGMaterialShader* VideoPlanesMaterial::createShader(QSGRendererInterface::RenderMode) const {
    return new VideoPlanesShader(format_);
}

// Two pictures never share a batch: each has its own textures.
int VideoPlanesMaterial::compare(const QSGMaterial* other) const {
    return this == other ? 0 : (this < other ? -1 : 1);
}

void VideoPlanesMaterial::setFrame(std::shared_ptr<const VideoPixels> frame) {
    if (frame == frame_) return;
    frame_ = std::move(frame);
    ++serial_;
}
