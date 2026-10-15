#include "VideoSurface.h"
#include <algorithm>
#include <cstdio>
#include <QImage>
#include <QQuickWindow>
#include <QSGOpacityNode>
#include <QSGSimpleTextureNode>
#include <QSGTexture>
#ifdef MELO_VIDEO_PLANES
#include "VideoPlanes.h"
#include <QSGGeometryNode>
#endif

VideoFrameSource* VideoSurface::s_source = nullptr;
QList<VideoSurface*> VideoSurface::s_live;
#ifdef MELO_VIDEOSURFACE_TEST
int VideoSurface::paintCount = 0;
#endif

namespace {
QRectF coverRect(const QSizeF& item, const QSize& frame) {
    // PreserveAspectCrop: the source rect, in frame pixels, that fills the item
    if (frame.isEmpty() || item.isEmpty()) return QRectF(QPointF(0, 0), frame);
    const qreal ia = item.width() / item.height(), fa = qreal(frame.width()) / frame.height();
    if (fa > ia) {           // frame wider: crop the sides
        const qreal w = frame.height() * ia;
        return QRectF((frame.width() - w) / 2, 0, w, frame.height());
    }
    const qreal h = frame.width() / ia;
    return QRectF(0, (frame.height() - h) / 2, frame.width(), h);
}

struct Placement { QRectF rect; QRectF source; };   // where the picture goes, and which part of it

// fill: crop the frame to the item. fit: the whole frame, bars around it.
// stretch: the whole frame over the whole item. `mix` moves fit and stretch
// continuously toward fill.
Placement placement(const QRectF& bounds, const QSize& frame, const QString& fit, qreal mix) {
    const QRectF whole(QPointF(0, 0), frame);
    const QRectF cover = coverRect(bounds.size(), frame);
    if (fit == QLatin1String("fill") || mix >= 1 || frame.isEmpty() || bounds.isEmpty())
        return {bounds, fit == QLatin1String("fill") || mix >= 1 ? cover : whole};
    if (fit == QLatin1String("stretch"))
        return {bounds, QRectF(whole.topLeft() + (cover.topLeft() - whole.topLeft()) * mix,
                               whole.size() + (cover.size() - whole.size()) * mix)};
    // the fit rect zoomed about the centre until it covers, then clipped to the item
    const QSizeF fitSz = QSizeF(frame).scaled(bounds.size(), Qt::KeepAspectRatio);
    const qreal coverScale = std::max(bounds.width() / fitSz.width(), bounds.height() / fitSz.height());
    const QSizeF vSz = fitSz * (1 + (coverScale - 1) * mix);
    const QRectF v(bounds.center() - QPointF(vSz.width() / 2, vSz.height() / 2), vSz);
    const QRectF shown = v.intersected(bounds);
    const qreal sx = frame.width() / v.width(), sy = frame.height() / v.height();
    return {shown, QRectF((shown.x() - v.x()) * sx, (shown.y() - v.y()) * sy,
                          shown.width() * sx, shown.height() * sy)};
}

QSGTexture* textureFor(QQuickWindow* win, const VideoPixels& px) {
    // The QImage only points into the frame; the Picture keeps the frame
    // until it shows another, so the texture never outlives it.
    const VideoPlane& p = px.planes[0];
    const QImage img(p.data, p.width, p.height, p.stride, QImage::Format_RGBA8888);
    return win->createTextureFromImage(img, QQuickWindow::TextureIsOpaque);
}

// One drawn frame: a texture node for RGBA (and for every frame on a renderer
// without planes), a geometry node with VideoPlanesMaterial for NV12/I420.
struct Picture {
    QSGNode* parent;
    QSGSimpleTextureNode* tex = nullptr;
#ifdef MELO_VIDEO_PLANES
    QSGGeometryNode* geo = nullptr;
#endif
    std::shared_ptr<const VideoPixels> frame;   // what the node shows; pins its bytes through the render
    std::weak_ptr<const VideoPixels> failed;    // the last frame with no twin, not tried again

    explicit Picture(QSGNode* p) : parent(p) {}
    ~Picture() { clear(); }
    bool empty() const { return !frame; }
    QSize size() const { return frame ? QSize(frame->width, frame->height) : QSize(); }

    void dropTex() { if (tex) { parent->removeChildNode(tex); delete tex; tex = nullptr; } }
#ifdef MELO_VIDEO_PLANES
    void dropGeo() { if (geo) { parent->removeChildNode(geo); delete geo; geo = nullptr; } }
#else
    void dropGeo() {}
#endif
    void clear() { dropTex(); dropGeo(); frame.reset(); }

    // Shows `px`. False when it cannot be drawn here (a planar frame with no
    // RGBA twin on a renderer without planes); the previous picture stays.
    // Nodes are prepended: the main picture stays under the fade.
    bool show(QQuickWindow* win, const std::shared_ptr<const VideoPixels>& px, bool planar) {
        if (px == frame) return true;
#ifdef MELO_VIDEO_PLANES
        if (planar && px->format != VideoFormat::RGBA) {
            dropTex();
            auto* mat = geo ? static_cast<VideoPlanesMaterial*>(geo->material()) : nullptr;
            if (mat && mat->format() != px->format) { dropGeo(); mat = nullptr; }
            if (!geo) {
                // the material joins the node with its frame set: an empty one samples nothing
                mat = new VideoPlanesMaterial(win, px->format);
                mat->setFrame(px);
                geo = new QSGGeometryNode;
                auto* g = new QSGGeometry(QSGGeometry::defaultAttributes_TexturedPoint2D(), 4);
                g->setDrawingMode(QSGGeometry::DrawTriangleStrip);
                geo->setGeometry(g);
                geo->setFlag(QSGNode::OwnsGeometry, true);
                geo->setMaterial(mat);
                geo->setFlag(QSGNode::OwnsMaterial, true);
                parent->prependChildNode(geo);
            } else {
                mat->setFrame(px);
                geo->markDirty(QSGNode::DirtyMaterial);
            }
            frame = px;
            return true;
        }
#else
        (void)planar;
#endif
        if (failed.lock() == px) return false;
        const auto rgba = rgbaOf(px);
        if (!rgba) { failed = px; return false; }
        dropGeo();
        // A texture node joins the live tree only with its texture set: the
        // software renderer reads it on append.
        const bool fresh = !tex;
        if (fresh) { tex = new QSGSimpleTextureNode; tex->setOwnsTexture(true); }
        tex->setTexture(textureFor(win, *rgba));
        if (fresh) parent->prependChildNode(tex);
        frame = px;
        return true;
    }

    QRectF place(const QRectF& bounds, const QString& fit, qreal mix) {
        const Placement p = placement(bounds, size(), fit, mix);
        if (tex) { tex->setSourceRect(p.source); tex->setRect(p.rect); }
#ifdef MELO_VIDEO_PLANES
        if (geo) {
            const QSize s = size();
            QSGGeometry::updateTexturedRectGeometry(geo->geometry(), p.rect,
                QRectF(p.source.x() / s.width(), p.source.y() / s.height(),
                       p.source.width() / s.width(), p.source.height() / s.height()));
            geo->markDirty(QSGNode::DirtyGeometry);
        }
#endif
        return p.rect;
    }
};

struct Node : QSGNode {
    Picture main{this};
    QSGOpacityNode* fade = nullptr;
    std::unique_ptr<Picture> incoming;   // lives under `fade`
    QString heldTrack;   // the track of the view last drawn
};
}  // namespace

VideoSurface::VideoSurface() {
    setFlag(ItemHasContents);
    tick_.setInterval(16);
    connect(&tick_, &QTimer::timeout, this, &VideoSurface::fetch);
    s_live.append(this);
}

VideoSurface::~VideoSurface() { s_live.removeOne(this); }

// A frozen surface has no tick: the source's change is its one fetch.
void VideoSurface::notifyTrackChange() {
    const auto live = s_live;
    for (VideoSurface* v : live)
        if (v->frozen_ && v->running_ && v->window()) v->fetch();
}

// Scrubbing while paused: the new place's picture arrives a moment after the
// seek, so a frozen surface ticks until it has.
void VideoSurface::notifySeek() {
    const auto live = s_live;
    for (VideoSurface* v : live) {
        if (!v->frozen_ || !v->running_) continue;
        v->thaw_ = QDeadlineTimer(1500);
        v->retick();
    }
}

// Under the basic render loop every update() is a full-window render: only a
// changed picture on a visible surface asks for one.
// The picture never goes blank while shown: an empty view keeps it, unless the
// view belongs to another track; only stopping or hiding otherwise drops it.
void VideoSurface::fetch() {
    if (!s_source) return;
    VideoView next = s_source->videoView();
    if (frozen_ && thaw_.hasExpired() && tick_.isActive()) retick();   // the thaw is over
    // frozen, only another track's view gets through
    if (frozen_ && !thawed() && (next.trackId.isEmpty() || next.trackId == pending_.trackId)) return;
    if (!next.main && hasFrame_) {
        const bool otherTrack = !next.trackId.isEmpty() && !pending_.trackId.isEmpty()
                             && next.trackId != pending_.trackId;
        if (!otherTrack) return;
        dropNode_ = true;
        update();
    }
    pending_ = std::move(next);
    const bool has = pending_.main != nullptr;
    if (has != hasFrame_) { hasFrame_ = has; emit hasFrameChanged(); }
    const bool changed = pending_.main != view_.main || pending_.incoming != view_.incoming
                      || pending_.mix != view_.mix;
    if (changed && isVisible()) update();
}

void VideoSurface::retick() {
    // Not gated on isVisible(): QML shows the surface on hasFrame, which only the tick sets.
    const bool on = running_ && (!frozen_ || thawed()) && window();
    if (on && !tick_.isActive()) tick_.start();
    if (!on) tick_.stop();
}

void VideoSurface::setRunning(bool on) {
    if (running_ == on) return;
    running_ = on; emit runningChanged(); retick();
    if (on) fetch();   // the first paint is the current picture, never a stale one
    else dropPicture();
}

void VideoSurface::dropPicture() {
    pending_ = {};
    dropNode_ = true;
    if (hasFrame_) { hasFrame_ = false; emit hasFrameChanged(); }
    update();
}

void VideoSurface::setFrozen(bool on) {
    if (frozen_ == on) return;
    frozen_ = on; emit frozenChanged(); retick();
    if (!on) update();   // a frozen surface had no tick to resume the paint
}

void VideoSurface::setFit(const QString& fit) {
    if (fit == fit_ || (fit != QLatin1String("fill") && fit != QLatin1String("fit")
                        && fit != QLatin1String("stretch"))) return;
    fit_ = fit; emit fitChanged(); update();
}

void VideoSurface::setFillMix(qreal mix) {
    mix = std::clamp(mix, 0.0, 1.0);
    if (qFuzzyCompare(mix + 1, fillMix_ + 1)) return;
    fillMix_ = mix; emit fillMixChanged(); update();
}

// Set during the scene-graph sync; QML hears of it after the frame.
void VideoSurface::setContentRect(const QRectF& r) {
    if (r == contentRect_) return;
    contentRect_ = r;
    QMetaObject::invokeMethod(this, &VideoSurface::contentRectChanged, Qt::QueuedConnection);
}

void VideoSurface::itemChange(ItemChange change, const ItemChangeData& value) {
    QQuickItem::itemChange(change, value);
    if (change == ItemVisibleHasChanged || change == ItemSceneChange) retick();
    if (change == ItemVisibleHasChanged && value.boolValue) update();   // changes skipped while hidden
    if (change == ItemVisibleHasChanged && !value.boolValue) dropPicture();
}

void VideoSurface::geometryChange(const QRectF& newGeometry, const QRectF& oldGeometry) {
    QQuickItem::geometryChange(newGeometry, oldGeometry);
    // A frozen surface has no tick; the crop must still follow the new size.
    if (newGeometry.size() != oldGeometry.size()) update();
}

QSGNode* VideoSurface::updatePaintNode(QSGNode* old, UpdatePaintNodeData*) {
#ifdef MELO_VIDEOSURFACE_TEST
    ++paintCount;
#endif
#ifdef MELO_VIDEO_PLANES
    if (window() != planarWindow_) {
        planarWindow_ = window();
        const char* why = videoPlanesUnusable(window());
        planar_ = !why;
        if (why) std::fprintf(stderr, "[video] textures: RGBA (%s)\n", why);
        else std::fprintf(stderr, "[video] textures: planes\n");
    }
#endif
    auto* node = static_cast<Node*>(old);
    if (dropNode_) {
        dropNode_ = false;
        delete node; node = nullptr;
        view_ = {}; setContentRect({});
    }
    // a frozen picture of another track is never held
    if (node && frozen_ && !pending_.trackId.isEmpty() && pending_.trackId != node->heldTrack) {
        delete node; node = nullptr;
        view_ = {}; setContentRect({});
    }
    const QRectF bounds = boundingRect();
    if (node && ((frozen_ && !thawed()) || !pending_.main)) {
        // Frozen (and no seek's thaw) or between frames: the held picture still covers the bounds.
        setContentRect(node->main.place(bounds, fit_, fillMix_));
        if (node->incoming && !node->incoming->empty()) node->incoming->place(bounds, fit_, fillMix_);
        return node;
    }
    if (!pending_.main) { view_ = {}; setContentRect({}); return nullptr; }
    if (!node) node = new Node;
    if (!node->main.show(window(), pending_.main, planar_)) {
        // a frame this renderer cannot draw: the previous picture stays, and the
        // frame counts as seen so the tick does not repaint for it
        view_ = pending_;
        if (node->main.empty()) { delete node; setContentRect({}); return nullptr; }
        setContentRect(node->main.place(bounds, fit_, fillMix_));
        if (node->incoming && !node->incoming->empty()) node->incoming->place(bounds, fit_, fillMix_);
        return node;
    }
    setContentRect(node->main.place(bounds, fit_, fillMix_));

    const bool dissolving = pending_.incoming && pending_.mix > 0;
    if (dissolving) {
        // the fade joins the tree only once its picture is set: the software
        // renderer reads it on append
        const bool fresh = !node->fade;
        if (fresh) {
            node->fade = new QSGOpacityNode;
            node->incoming = std::make_unique<Picture>(node->fade);
        }
        if (node->incoming->show(window(), pending_.incoming, planar_)) {
            node->incoming->place(bounds, fit_, fillMix_);
            node->fade->setOpacity(std::min(1.0, pending_.mix));
            if (fresh) node->appendChildNode(node->fade);
        } else if (fresh) {
            node->incoming.reset();
            delete node->fade; node->fade = nullptr;
        }
    } else if (node->fade) {
        node->incoming.reset();          // takes its node out of `fade` first
        node->removeChildNode(node->fade);
        delete node->fade;
        node->fade = nullptr;
    }
    node->heldTrack = pending_.trackId;
    view_ = pending_;
    return node;
}
