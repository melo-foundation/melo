#include "BlendItem.h"

#include <QSGGeometryNode>
#include <QSGTexture>
#include <QSGTextureProvider>
#include <QSGMaterial>
#include <QSGMaterialShader>
#include <QSet>
#include <cstdio>
#include <cmath>
#include <cstring>
#include <iterator>

namespace {

using GPS = QSGMaterialShader::GraphicsPipelineState;

struct ModeSpec {
    const char* name;
    GPS::BlendFactor src;
    GPS::BlendFactor dst;      // a flat colour covers its whole rectangle
    GPS::BlendOp op;
    // A texture has empty parts where a colour has none. Where the source is
    // a layer, the destination factor must leave uncovered pixels alone; Zero
    // there wipes every pixel the glyphs do not cover to black.
    GPS::BlendFactor texDst;
    // Min and Max cannot be made alpha-aware in one pass — min(0, dst) is 0,
    // so an uncovered pixel goes black however the factors are set. Refused
    // for a texture rather than approximated into something that reads as a
    // rendering fault.
    bool texOk;
};

// Everything below is plumbing to get these rows to the GPU; none of it
// reads the framebuffer.
const ModeSpec kModes[] = {
    {"normal",   GPS::One,              GPS::OneMinusSrcAlpha, GPS::BlendOp::Add,
     GPS::OneMinusSrcAlpha, true},
    {"invert",   GPS::OneMinusDstColor, GPS::Zero,             GPS::BlendOp::Add,
     GPS::OneMinusSrcAlpha, true},
    {"multiply", GPS::DstColor,         GPS::Zero,             GPS::BlendOp::Add,
     GPS::OneMinusSrcAlpha, true},
    {"screen",   GPS::One,              GPS::OneMinusSrcColor, GPS::BlendOp::Add,
     GPS::OneMinusSrcColor, true},
    {"darken",   GPS::One,              GPS::One,              GPS::BlendOp::Min,
     GPS::One, false},
    {"lighten",  GPS::One,              GPS::One,              GPS::BlendOp::Max,
     GPS::One, true},
    {"subtract", GPS::One,              GPS::One,              GPS::BlendOp::ReverseSubtract,
     GPS::One, true},
};

int modeIndex(const QString& m) {
    for (int i = 0; i < int(std::size(kModes)); ++i)
        if (m == QLatin1String(kModes[i].name)) return i;
    return -1;
}

class BlendShader : public QSGMaterialShader {
public:
    BlendShader() {
        setShaderFileName(VertexStage, QStringLiteral(":/melo/shaders/blend.vert.qsb"));
        setShaderFileName(FragmentStage, QStringLiteral(":/melo/shaders/blend.frag.qsb"));
        // Without this the override is never called. updateGraphicsPipelineState
        // is only consulted for shaders that declare they will change it, so
        // omitting the flag renders every mode with the default One /
        // OneMinusSrcAlpha — the source colour, flat, blending with nothing.
        setFlag(UpdatesGraphicsPipelineState, true);
    }
    bool updateUniformData(RenderState& state, QSGMaterial* newMat, QSGMaterial* oldMat) override;
    bool updateGraphicsPipelineState(RenderState& state, GraphicsPipelineState* ps,
                                     QSGMaterial* newMat, QSGMaterial* oldMat) override;
};

class BlendTexShader : public QSGMaterialShader {
public:
    BlendTexShader() {
        setShaderFileName(VertexStage, QStringLiteral(":/melo/shaders/blend_tex.vert.qsb"));
        setShaderFileName(FragmentStage, QStringLiteral(":/melo/shaders/blend_tex.frag.qsb"));
        setFlag(UpdatesGraphicsPipelineState, true);
    }
    bool updateUniformData(RenderState& state, QSGMaterial* newMat, QSGMaterial* oldMat) override;
    void updateSampledImage(RenderState& state, int binding, QSGTexture** texture,
                            QSGMaterial* newMat, QSGMaterial* oldMat) override;
    bool updateGraphicsPipelineState(RenderState& state, GraphicsPipelineState* ps,
                                     QSGMaterial* newMat, QSGMaterial* oldMat) override;
};

class BlendTexMaterial : public QSGMaterial {
public:
    BlendTexMaterial() { setFlag(Blending, true); }
    QSGMaterialType* type() const override { static QSGMaterialType t; return &t; }
    QSGMaterialShader* createShader(QSGRendererInterface::RenderMode) const override {
        return new BlendTexShader;
    }
    int compare(const QSGMaterial* o) const override {
        const auto* m = static_cast<const BlendTexMaterial*>(o);
        if (mode != m->mode) return mode < m->mode ? -1 : 1;
        if (provider != m->provider) return provider < m->provider ? -1 : 1;
        if (maskOnly != m->maskOnly) return maskOnly ? 1 : -1;
        const QRgb a = color.rgba(), b = m->color.rgba();
        return a == b ? 0 : (a < b ? -1 : 1);
    }
    QColor color = Qt::white;
    int mode = 0;
    // The provider, not the texture. A layer's texture is not valid when
    // updatePaintNode runs — asking then hands back one whose size is -1x-1.
    // Qt's own ShaderEffect keeps the provider and fetches in
    // updateSampledImage, which runs during rendering. So does this.
    QSGTextureProvider* provider = nullptr;
    // read the source's alpha as coverage and ignore its colour — see
    // blend_tex.frag for why a glyph layer needs this
    bool maskOnly = false;
    // the item's size in DEVICE pixels, so the sampler can tell 1:1 from scaled
    float devW = 0, devH = 0;
};

class BlendMaterial : public QSGMaterial {
public:
    BlendMaterial() {
        // Without this the renderer is entitled to treat the node as opaque
        // and skip blending entirely, which is the one thing this material is
        // for. It also keeps it out of the opaque batch, where the depth
        // pre-pass would let it cover what it is supposed to blend with.
        setFlag(Blending, true);
    }
    QSGMaterialType* type() const override { static QSGMaterialType t; return &t; }
    QSGMaterialShader* createShader(QSGRendererInterface::RenderMode) const override {
        return new BlendShader;
    }
    int compare(const QSGMaterial* o) const override {
        const auto* m = static_cast<const BlendMaterial*>(o);
        if (mode != m->mode) return mode < m->mode ? -1 : 1;
        const QRgb a = color.rgba(), b = m->color.rgba();
        return a == b ? 0 : (a < b ? -1 : 1);
    }
    QColor color = Qt::white;
    int mode = 0;
};

// The uniform block is identical in both shaders: mat4 at 0, vec4 at 64,
// float at 80.
static void writeBlendUniforms(QSGMaterialShader::RenderState& state, QByteArray* buf,
                               const QColor& c) {
    Q_ASSERT(buf->size() >= 84);
    if (state.isMatrixDirty()) {
        const QMatrix4x4 m = state.combinedMatrix();
        std::memcpy(buf->data(), m.constData(), 64);
    }
    const float rgba[4] = {float(c.redF()), float(c.greenF()),
                           float(c.blueF()), float(c.alphaF())};
    std::memcpy(buf->data() + 64, rgba, 16);
    if (state.isOpacityDirty()) {
        const float o = state.opacity();
        std::memcpy(buf->data() + 80, &o, 4);
    }
}

bool BlendTexShader::updateUniformData(RenderState& state, QSGMaterial* newMat, QSGMaterial*) {
    QByteArray* buf = state.uniformData();
    const auto* mat = static_cast<BlendTexMaterial*>(newMat);
    writeBlendUniforms(state, buf, mat->color);
    // std140: maskOnly is the float after qt_Opacity, at 84
    Q_ASSERT(buf->size() >= 88);
    const float mo = mat->maskOnly ? 1.f : 0.f;
    std::memcpy(buf->data() + 84, &mo, 4);
    return true;
}

void BlendTexShader::updateSampledImage(RenderState& state, int binding, QSGTexture** texture,
                                        QSGMaterial* newMat, QSGMaterial*) {
    if (binding != 1) return;
    QSGTextureProvider* p = static_cast<BlendTexMaterial*>(newMat)->provider;
    QSGTexture* t = p ? p->texture() : nullptr;
    if (t) {
        // The sampler takes the texture's filtering, and one still asking for
        // mipmaps it lacks samples as zero, so set it here, as Qt's
        // ShaderEffect does. Nearest at 1:1, since Linear softens blended text
        // at fractional scale; Linear when the texture is drawn scaled, or it
        // aliases.
        const auto* m = static_cast<BlendTexMaterial*>(newMat);
        const QSize ts = t->textureSize();
        const bool oneToOne = ts.isValid() && m->devW > 0
            && std::abs(ts.width() - m->devW) < 1.0f && std::abs(ts.height() - m->devH) < 1.0f;
        t->setFiltering(oneToOne ? QSGTexture::Nearest : QSGTexture::Linear);
        t->setMipmapFiltering(QSGTexture::None);
        t->setHorizontalWrapMode(QSGTexture::ClampToEdge);
        t->setVerticalWrapMode(QSGTexture::ClampToEdge);
        // It may also still have pending operations; nothing else here flushes them.
        t->commitTextureOperations(state.rhi(), state.resourceUpdateBatch());
    }
    *texture = t;
}

bool BlendTexShader::updateGraphicsPipelineState(RenderState&, GraphicsPipelineState* ps,
                                                 QSGMaterial* newMat, QSGMaterial*) {
    const auto* mat = static_cast<BlendTexMaterial*>(newMat);
    const ModeSpec& sp = kModes[qBound(0, mat->mode, int(std::size(kModes)) - 1)];
    ps->blendEnable = true;
    ps->srcColor = sp.src;
    ps->dstColor = sp.texDst;
    ps->opColor = sp.op;
    ps->separateBlendFactors = true;
    ps->srcAlpha = GPS::One;
    ps->dstAlpha = GPS::OneMinusSrcAlpha;
    ps->opAlpha = GPS::BlendOp::Add;
    return true;
}

bool BlendShader::updateUniformData(RenderState& state, QSGMaterial* newMat, QSGMaterial*) {
    // std140: mat4 at 0 (64 bytes), vec4 at 64 (16), float at 80.
    QByteArray* buf = state.uniformData();
    Q_ASSERT(buf->size() >= 84);
    bool changed = false;
    if (state.isMatrixDirty()) {
        const QMatrix4x4 m = state.combinedMatrix();
        std::memcpy(buf->data(), m.constData(), 64);
        changed = true;
    }
    const auto* mat = static_cast<BlendMaterial*>(newMat);
    // NOT premultiplied. The scene graph's usual materials premultiply because
    // they blend One / OneMinusSrcAlpha; these factors do not all use alpha at
    // all, and premultiplying would darken every mode by its own alpha.
    const float c[4] = {float(mat->color.redF()), float(mat->color.greenF()),
                        float(mat->color.blueF()), float(mat->color.alphaF())};
    std::memcpy(buf->data() + 64, c, 16);
    if (state.isOpacityDirty()) {
        const float o = state.opacity();
        std::memcpy(buf->data() + 80, &o, 4);
        changed = true;
    }
    return true;
}

bool BlendShader::updateGraphicsPipelineState(RenderState&, GraphicsPipelineState* ps,
                                              QSGMaterial* newMat, QSGMaterial*) {
    const auto* mat = static_cast<BlendMaterial*>(newMat);
    const ModeSpec& s = kModes[qBound(0, mat->mode, int(std::size(kModes)) - 1)];
    ps->blendEnable = true;
    ps->srcColor = s.src;
    ps->dstColor = s.dst;
    ps->opColor = s.op;
    // Alpha blends as a normal draw (One / OneMinusSrcAlpha). Keeping the
    // destination alpha drops the colour over transparent regions and leaves
    // colour that later draws composite against the wrong alpha.
    ps->separateBlendFactors = true;
    ps->srcAlpha = GPS::One;
    ps->dstAlpha = GPS::OneMinusSrcAlpha;
    ps->opAlpha = GPS::BlendOp::Add;
    return true;
}

} // namespace

BlendItem::BlendItem(QQuickItem* parent) : QQuickItem(parent) {
    setFlag(ItemHasContents, true);
}

bool BlendItem::supportsMode(const QString& m) { return modeIndex(m) >= 0; }

void BlendItem::setMaskOnly(bool on) {
    if (on == maskOnly_) return;
    maskOnly_ = on;
    emit maskOnlyChanged();
    update();
}

void BlendItem::setColor(const QColor& c) {
    if (c == color_) return;
    color_ = c;
    update();
    emit colorChanged();
}

void BlendItem::setSource(QQuickItem* item) {
    if (item == source_) return;
    if (source_) disconnect(source_, nullptr, this, nullptr);
    source_ = item;
    // Not textureProvider() here: it is render-thread only, and from a property
    // write it makes a ShaderEffectSource build its layer before the window has
    // an RHI (null QRhi in QSGRhiLayer::setSize). updatePaintNode picks it up.
    if (source_)
        connect(source_, &QQuickItem::destroyed, this, [this] { source_ = nullptr; update(); });
    update();
    emit sourceChanged();
}

void BlendItem::setMode(const QString& m) {
    if (m == mode_) return;
    if (!m.isEmpty() && modeIndex(m) < 0) {
        static QSet<QString> warned;
        if (!warned.contains(m)) {
            warned.insert(m);
            std::fprintf(stderr, "[melo] BlendRect: no blend mode named '%s' — drawing nothing. "
                                 "Known: normal invert multiply screen darken lighten subtract\n",
                         qPrintable(m));
        }
    }
    mode_ = m;
    update();
    emit modeChanged();
}

QSGNode* BlendItem::updatePaintNode(QSGNode* old, UpdatePaintNodeData*) {
    const int idx = modeIndex(mode_);
    if (idx < 0 || width() <= 0 || height() <= 0) { delete old; return nullptr; }

    QSGTextureProvider* provider = nullptr;
    if (source_) {
        if (source_->isTextureProvider()) provider = source_->textureProvider();
        // The texture changes as the source repaints; without this a blended
        // Text would keep showing whatever it said when it was first drawn.
        // Connected HERE because this is the render thread — see setSource.
        if (provider && provider != watched_) {
            if (watchConn_) disconnect(watchConn_);
            watched_ = provider;
            watchConn_ = connect(provider, &QSGTextureProvider::textureChanged,
                                 this, [this] { update(); });
        }
        // A source that provides nothing draws nothing, rather than a flat
        // rectangle over the very thing it was asked to blend.
        if (!provider) { delete old; return nullptr; }
        // Not scheduleUpdate(): during node update it sizes the layer before
        // the window has an RHI and crashes in QSGRhiLayer::setSize on the
        // first expose. A hidden source hands over an empty texture either way.
    }
    const bool textured = provider != nullptr;

    if (textured && !kModes[idx].texOk) {
        static QSet<QString> warned;
        if (!warned.contains(mode_)) {
            warned.insert(mode_);
            std::fprintf(stderr, "[melo] BlendRect: '%s' cannot blend a texture — it is a Min/Max "
                                 "blend, and an uncovered pixel would go black rather than being "
                                 "left alone. Drawing nothing.\n", qPrintable(mode_));
        }
        delete old;
        return nullptr;
    }

    // The two paths use different vertex layouts, so a node built for one
    // cannot be reused for the other.
    auto* node = static_cast<QSGGeometryNode*>(old);
    if (node && (dynamic_cast<BlendTexMaterial*>(node->material()) != nullptr) != textured) {
        delete node;
        node = nullptr;
    }
    if (!node) {
        node = new QSGGeometryNode;
        auto* g = new QSGGeometry(textured ? QSGGeometry::defaultAttributes_TexturedPoint2D()
                                           : QSGGeometry::defaultAttributes_Point2D(), 4);
        g->setDrawingMode(QSGGeometry::DrawTriangleStrip);
        node->setGeometry(g);
        node->setFlag(QSGNode::OwnsGeometry, true);
        node->setMaterial(textured ? static_cast<QSGMaterial*>(new BlendTexMaterial)
                                   : static_cast<QSGMaterial*>(new BlendMaterial));
        node->setFlag(QSGNode::OwnsMaterial, true);
    }

    auto* g = node->geometry();
    const float w = float(width()), h = float(height());
    if (textured) {
        // normalizedTextureSubRect(), not 0..1: a layer texture can be padded
        // or atlased, and 0..1 stretches the padding so glyph edges fall
        // between texels. A provider with no texture yet reads as the full rect
        // until the next frame.
        QRectF sub(0, 0, 1, 1);
        if (provider)
            if (QSGTexture* t = provider->texture())
                if (t->textureSize().isValid()) sub = t->normalizedTextureSubRect();
        if (qEnvironmentVariableIsSet("MELO_BLEND_DEBUG")) {
            QSGTexture* t = provider ? provider->texture() : nullptr;
            const qreal dpr = window() ? window()->effectiveDevicePixelRatio() : 1;
            std::fprintf(stderr, "[blend] item %.1fx%.1f (x%.2f = %.1fx%.1f dev)  texture %dx%d  sub %.4f,%.4f %.4fx%.4f\n",
                         double(w), double(h), double(dpr), double(w * dpr), double(h * dpr),
                         t ? t->textureSize().width() : -1, t ? t->textureSize().height() : -1,
                         sub.x(), sub.y(), sub.width(), sub.height());
        }
        const float u0 = float(sub.left()), v0 = float(sub.top());
        const float u1 = float(sub.right()), v1 = float(sub.bottom());
        QSGGeometry::TexturedPoint2D* v = g->vertexDataAsTexturedPoint2D();
        v[0].set(0, 0, u0, v0); v[1].set(w, 0, u1, v0);
        v[2].set(0, h, u0, v1); v[3].set(w, h, u1, v1);
    } else {
        QSGGeometry::Point2D* v = g->vertexDataAsPoint2D();
        v[0].set(0, 0); v[1].set(w, 0); v[2].set(0, h); v[3].set(w, h);
    }
    node->markDirty(QSGNode::DirtyGeometry);

    if (textured) {
        auto* m = static_cast<BlendTexMaterial*>(node->material());
        const qreal dpr = window() ? window()->effectiveDevicePixelRatio() : 1;
        const float devW = float(width() * dpr), devH = float(height() * dpr);
        if (m->color != color_ || m->mode != idx || m->provider != provider
            || m->maskOnly != maskOnly_ || m->devW != devW || m->devH != devH) {
            m->color = color_; m->mode = idx; m->provider = provider; m->maskOnly = maskOnly_;
            m->devW = devW; m->devH = devH;
            node->markDirty(QSGNode::DirtyMaterial);
        }
    } else {
        auto* m = static_cast<BlendMaterial*>(node->material());
        if (m->color != color_ || m->mode != idx) {
            m->color = color_; m->mode = idx;
            node->markDirty(QSGNode::DirtyMaterial);
        }
    }
    return node;
}
