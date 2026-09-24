#pragma once
#include "../vis/MeloEngineOnly.h"

#include <QImage>
#include <QPainterPath>
#include <QQuickItem>
#include <QRectF>
#include <QRect>
#include <QRegion>
#include <QVector>
#include <QVariant>

// The window's shape: everything outside it is cleared to transparent, and
// only what is inside it takes clicks. A spec is one of:
//
//   { "corners": [c, c, c, c] }   top left, top right, bottom right, bottom
//       left; each { "style": "round" | "cut" | "square", "size": px }
//   { "path": "M0 0 H40 ...", "box": [w, h], "slice": [l, t, r, b] }
//       an SVG path in a w x h box whose fill is the window; the slices keep
//       their distance from the window's edges and the middle stretches
//   { "image": "data:image/png;base64,..." | path, "slice": [l, t, r, b],
//     "scale": s }
//       an image whose alpha is the window, nine-sliced the same way; `scale`
//       is image pixels per window pixel (default 1)
//
// "fit" for a window smaller than the fixed edges: "squeeze" (default) scales
// them down; "crop" keeps their size and takes the pixels from the middle.
//
// Drawn last with Zero / OneMinusSrcAlpha (the shader writes 1 - coverage), so
// there is no full-window layer pass; slices wholly inside are not drawn.
//
// The input region is the same shape via QWindow::setMask: input only on
// Wayland (see MeloUi.h), a clipping bounding shape on X11. WindowController's
// click-through writes the same mask, so both keep the shape on the window as
// "meloShape" and a disabled input as "meloInputOff".
class WindowShapeItem : public QQuickItem {
    Q_OBJECT
    Q_PROPERTY(QVariant spec READ spec WRITE setSpec NOTIFY specChanged)
    // off: nothing is cleared and the window takes clicks everywhere — a
    // maximised window, or a theme with no shape
    Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged)
    // whether this shape is also the window's input region
    Q_PROPERTY(bool input READ input WRITE setInput NOTIFY inputChanged)
    // the shape's box and slices in window pixels, for what draws along it
    Q_PROPERTY(QRectF slices READ slices NOTIFY shapeChanged)
    Q_PROPERTY(QSizeF box READ box NOTIFY shapeChanged)
    // whether there is a shape at all: a spec that parsed, whether or not it
    // is active
    Q_PROPERTY(bool hasShape READ hasShape NOTIFY shapeChanged)
    // the distance field's size in texels
    Q_PROPERTY(QSize fieldSize READ fieldSize NOTIFY shapeChanged)
    // Bumped whenever the shape or the window changes: intrusion() is a
    // question, not a property, and a binding that asks it reads this to know
    // when to ask again.
    Q_PROPERTY(int generation READ generation NOTIFY generationChanged)
    // The ring within `grabRing` inside the shape's edge, as a containmentMask
    // for a whole-window MouseArea; strips along the window rectangle miss a
    // cut edge.
    Q_PROPERTY(QObject* edgeRing READ edgeRing CONSTANT)
    Q_PROPERTY(qreal grabRing READ grabRing WRITE setGrabRing NOTIFY grabRingChanged)
    // ...and its box in logical pixels: the shape's, with the middle drawn out
    // (see rebuild), or the window's own where the field is measured at size
    Q_PROPERTY(QSizeF fieldBox READ fieldBox NOTIFY shapeChanged)
    // What the field is sliced by, which is not always what the picture is:
    // a shape whose middle is not straight is measured at the window's size
    // instead, and then it has no slices at all
    Q_PROPERTY(QRectF fieldSlices READ fieldSlices NOTIFY shapeChanged)
    // 1 when the fixed edges keep their size in a window too small for them
    Q_PROPERTY(bool cropFit READ cropFit NOTIFY shapeChanged)
public:
    explicit WindowShapeItem(QQuickItem* parent = nullptr);
    ~WindowShapeItem() override;
    void componentComplete() override {
        QQuickItem::componentComplete();
        // a plugin's engine gets nothing: no shape, and no say over the mask
        refused_ = !meloEngineOwns(this, "WindowShapeItem");
        if (!refused_) rebuild();
    }

    QVariant spec() const { return spec_; }
    void setSpec(const QVariant& s);
    bool active() const { return active_; }
    void setActive(bool on);
    bool input() const { return input_; }
    void setInput(bool on);
    QRectF slices() const { return QRectF(slice_[0], slice_[1], slice_[2], slice_[3]); }
    QSizeF box() const { return box_; }
    bool hasShape() const { return kind_ != Kind::None; }
    int generation() const { return generation_; }
    QObject* edgeRing() const;
    qreal grabRing() const { return grabRing_; }
    void setGrabRing(qreal px);
    // which way the edge faces at a point, as a unit vector out of the window:
    // what tells a grab which edges it is dragging
    Q_INVOKABLE QPointF edgeNormalAt(qreal x, qreal y) const;
    QSize fieldSize() const { return field_.size(); }
    QSizeF fieldBox() const { return fieldBox_; }
    QRectF fieldSlices() const {
        return exact_ ? QRectF(0, 0, 0, 0) : QRectF(slice_[0], slice_[1], slice_[2], slice_[3]);
    }
    bool cropFit() const { return crop_; }

    // A texture provider: a signed distance field of the shape's box (logical
    // pixels, positive inside), nine-sliced by the same slices. Each texel
    // packs (distance + 32) * 512 into red and green, so sample it NEAREST and
    // interpolate the decoded values.
    bool isTextureProvider() const override { return true; }
    QSGTextureProvider* textureProvider() const override;

    // The shape's outline at a size, in window pixels: what a path or corner
    // shape becomes when the window is w x h. Empty for an image shape.
    QPainterPath outlineAt(qreal w, qreal h) const;
    // How far the shape eats into one edge, over a stretch of the window: the
    // deepest the outline comes in from that edge between `from` and `to`
    // (rows for the left and right edges, columns for the top and bottom), in
    // window pixels. What has to move in to stay out of a cut asks this.
    Q_INVOKABLE qreal intrusion(const QString& edge, qreal from, qreal to) const;
    // The distance the border reads at a point of the window, positive inside:
    // the same nine-slice mapping and the same decoding bordermask.frag does,
    // so a test can ask whether the border and the mask agree on the edge.
    Q_INVOKABLE qreal distanceAt(qreal x, qreal y) const;
    // ...and what the MASK keeps there: the picture through the same nine
    // slices the drawn mesh uses. The two must answer the same question the
    // same way, or the border follows an edge the window does not have.
    Q_INVOKABLE bool maskAt(qreal x, qreal y) const;
    // SVG path data to a QPainterPath: M L H V C S Q T A Z, absolute and
    // relative. Public for tests.
    static QPainterPath parseSvgPath(const QString& d, bool* ok = nullptr);

signals:
    void specChanged();
    void activeChanged();
    void inputChanged();
    void shapeChanged();
    // the window's mask has been written: what follows the shape — the glass
    // behind it — re-applies here
    void shapeApplied();
    void generationChanged();
    void grabRingChanged();

protected:
    QSGNode* updatePaintNode(QSGNode* old, UpdatePaintNodeData*) override;
    void geometryChange(const QRectF& now, const QRectF& before) override;
    void itemChange(ItemChange change, const ItemChangeData& value) override;

private:
    void rebuild();
    void applyMask();
    QRegion regionAt(int w, int h) const;
    void releaseResources() override;

    QVariant spec_;
    bool active_ = true;
    bool refused_ = false;
    bool input_ = true;

    // what rebuild() makes of the spec
    enum class Kind { None, Path, Image };
    Kind kind_ = Kind::None;
    QPainterPath path_;          // in the box, logical pixels
    QSizeF box_;                 // logical pixels
    qreal slice_[4] = {0, 0, 0, 0};
    bool crop_ = false;
    QImage picture_;             // premultiplied white * coverage, device pixels
    qreal pictureDpr_ = 1;       // picture pixels per logical pixel
    bool cellOpaque_[9] = {};    // a slice wholly inside the shape draws nothing
    int generation_ = 0;         // bumped whenever picture_ changes
    // where the shape starts and ends on each row (x) and each column (y), in
    // picture pixels — what intrusion() reads
    QVector<QPoint> rowBounds_, colBounds_;
    QRect bounds_;
    QImage field_;               // the signed distance field, of the drawn-out box
    QSizeF fieldBox_;
    // A shape whose middle is not straight cannot be measured once and
    // stretched: the picture stretches that part and a nine-sliced field does
    // not, and the border then follows an edge the window does not have. Such
    // a shape is measured at the window's size, and again when it changes.
    bool straightMiddle_ = true;
    bool exact_ = false;
    QSize fieldFor_;             // the size the exact field was measured at
    class QTimer* resize_ = nullptr;
    qreal grabRing_ = 6;
    mutable class ShapeEdgeRing* ring_ = nullptr;
    void measureField(const QImage& from, qreal dpr, bool drawOutMiddle);
    void remeasureAtSize();
    // the picture stretched to a size, as the mask draws it
    QImage nineSliced(int w, int h, qreal dpr) const;
    // whether the stretching middle is straight on both axes — a shape whose
    // middle holds a feature cannot be measured once and stretched
    bool middleIsStraight() const;
    mutable class ShapeFieldProvider* provider_ = nullptr;
};
