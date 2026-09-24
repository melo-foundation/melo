#include "WindowShapeItem.h"

#include <QBitmap>
#include <QBuffer>
#include <QFile>
#include <QPainter>
#include <QRunnable>
#include <QTimer>
#include <QSGTextureProvider>
#include <vector>
#include <QQuickWindow>
#include <QSGGeometryNode>
#include <QSGMaterial>
#include <QSGMaterialShader>
#include <QSGTexture>
#include <QUrl>
#include <algorithm>
#include <cmath>
#include <cstring>

namespace {

using GPS = QSGMaterialShader::GraphicsPipelineState;

class ShapeShader : public QSGMaterialShader {
public:
    ShapeShader() {
        setShaderFileName(VertexStage, QStringLiteral(":/melo/shaders/windowshape.vert.qsb"));
        setShaderFileName(FragmentStage, QStringLiteral(":/melo/shaders/windowshape.frag.qsb"));
        // without it the blend below is never asked for — see BlendItem
        setFlag(UpdatesGraphicsPipelineState, true);
    }
    bool updateUniformData(RenderState& state, QSGMaterial*, QSGMaterial*) override;
    void updateSampledImage(RenderState& state, int binding, QSGTexture** texture,
                            QSGMaterial* newMat, QSGMaterial*) override;
    bool updateGraphicsPipelineState(RenderState&, GraphicsPipelineState* ps,
                                     QSGMaterial*, QSGMaterial*) override {
        // Keep the destination by the shape: dst * (1 - srcA), colour and
        // alpha alike, the shader writing srcA = 1 - coverage
        ps->blendEnable = true;
        ps->srcColor = GPS::Zero;
        ps->dstColor = GPS::OneMinusSrcAlpha;
        ps->opColor = GPS::BlendOp::Add;
        ps->separateBlendFactors = true;
        ps->srcAlpha = GPS::Zero;
        ps->dstAlpha = GPS::OneMinusSrcAlpha;
        ps->opAlpha = GPS::BlendOp::Add;
        return true;
    }
};

class ShapeMaterial : public QSGMaterial {
public:
    ShapeMaterial() { setFlag(Blending, true); }
    ~ShapeMaterial() override { delete texture; }
    QSGMaterialType* type() const override { static QSGMaterialType t; return &t; }
    QSGMaterialShader* createShader(QSGRendererInterface::RenderMode) const override {
        return new ShapeShader;
    }
    int compare(const QSGMaterial* o) const override {
        const auto* m = static_cast<const ShapeMaterial*>(o);
        return texture == m->texture ? 0 : (texture < m->texture ? -1 : 1);
    }
    QSGTexture* texture = nullptr;
};

bool ShapeShader::updateUniformData(RenderState& state, QSGMaterial*, QSGMaterial*) {
    // std140: mat4 at 0, qt_Opacity at 64
    QByteArray* buf = state.uniformData();
    Q_ASSERT(buf->size() >= 68);
    if (state.isMatrixDirty()) {
        const QMatrix4x4 m = state.combinedMatrix();
        std::memcpy(buf->data(), m.constData(), 64);
    }
    if (state.isOpacityDirty()) {
        const float o = state.opacity();
        std::memcpy(buf->data() + 64, &o, 4);
    }
    return true;
}

void ShapeShader::updateSampledImage(RenderState& state, int binding, QSGTexture** texture,
                                     QSGMaterial* newMat, QSGMaterial*) {
    if (binding != 1) return;
    QSGTexture* t = static_cast<ShapeMaterial*>(newMat)->texture;
    if (t) {
        // stretched along the edges, so linear; never mipmapped
        t->setFiltering(QSGTexture::Linear);
        t->setMipmapFiltering(QSGTexture::None);
        t->setHorizontalWrapMode(QSGTexture::ClampToEdge);
        t->setVerticalWrapMode(QSGTexture::ClampToEdge);
        t->commitTextureOperations(state.rhi(), state.resourceUpdateBatch());
    }
    *texture = t;
}

} // namespace

class ShapeFieldProvider : public QSGTextureProvider {
public:
    ~ShapeFieldProvider() override { delete tex; }
    QSGTexture* texture() const override { return tex; }
    QSGTexture* tex = nullptr;
    int generation = -1;
};

namespace {

class ShapeNode : public QSGGeometryNode {
public:
    ShapeNode() {
        auto* g = new QSGGeometry(QSGGeometry::defaultAttributes_TexturedPoint2D(), 0, 0);
        g->setDrawingMode(QSGGeometry::DrawTriangles);
        setGeometry(g);
        setFlag(OwnsGeometry);
        setMaterial(new ShapeMaterial);
        setFlag(OwnsMaterial);
    }
    ShapeMaterial* mat() const { return static_cast<ShapeMaterial*>(material()); }
    int generation = -1;
};

// ---- SVG path data ----------------------------------------------------------

struct PathLexer {
    const QString& s;
    int i = 0;
    explicit PathLexer(const QString& str) : s(str) {}
    void skip() { while (i < s.size() && (s[i].isSpace() || s[i] == QLatin1Char(','))) ++i; }
    bool atCommand() { skip(); return i < s.size() && s[i].isLetter() && s[i] != QLatin1Char('e') && s[i] != QLatin1Char('E'); }
    bool atNumber() {
        skip();
        if (i >= s.size()) return false;
        const QChar c = s[i];
        return c.isDigit() || c == QLatin1Char('-') || c == QLatin1Char('+') || c == QLatin1Char('.');
    }
    bool number(qreal* out) {
        skip();
        int j = i;
        if (j < s.size() && (s[j] == QLatin1Char('-') || s[j] == QLatin1Char('+'))) ++j;
        bool dot = false, digits = false;
        while (j < s.size()) {
            if (s[j].isDigit()) { digits = true; ++j; }
            else if (s[j] == QLatin1Char('.') && !dot) { dot = true; ++j; }
            else break;
        }
        if (!digits) return false;
        if (j < s.size() && (s[j] == QLatin1Char('e') || s[j] == QLatin1Char('E'))) {
            int k = j + 1;
            if (k < s.size() && (s[k] == QLatin1Char('-') || s[k] == QLatin1Char('+'))) ++k;
            if (k < s.size() && s[k].isDigit()) { j = k; while (j < s.size() && s[j].isDigit()) ++j; }
        }
        bool ok = false;
        *out = s.mid(i, j - i).toDouble(&ok);
        i = j;
        return ok;
    }
    // an arc flag may be written with no separator after it: "a5 5 0 016 6"
    bool flag(bool* out) {
        skip();
        if (i < s.size() && (s[i] == QLatin1Char('0') || s[i] == QLatin1Char('1'))) {
            *out = s[i] == QLatin1Char('1'); ++i; return true;
        }
        return false;
    }
};

// SVG's endpoint arc as short line segments. Implementation notes F.6.5: the
// centre from the endpoints, radii scaled up when they cannot reach.
void arcTo(QPainterPath& p, QPointF from, qreal rx, qreal ry, qreal angleDeg,
           bool large, bool sweep, QPointF to) {
    if (rx == 0 || ry == 0 || from == to) { p.lineTo(to); return; }
    rx = std::abs(rx); ry = std::abs(ry);
    const qreal phi = qDegreesToRadians(angleDeg), c = std::cos(phi), s = std::sin(phi);
    const qreal dx = (from.x() - to.x()) / 2, dy = (from.y() - to.y()) / 2;
    const qreal x1 = c * dx + s * dy, y1 = -s * dx + c * dy;
    qreal lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry);
    if (lambda > 1) { rx *= std::sqrt(lambda); ry *= std::sqrt(lambda); }
    qreal num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1;
    const qreal den = rx * rx * y1 * y1 + ry * ry * x1 * x1;
    qreal k = den > 0 ? std::sqrt(qMax<qreal>(0, num / den)) : 0;
    if (large == sweep) k = -k;
    const qreal cx1 = k * rx * y1 / ry, cy1 = -k * ry * x1 / rx;
    const qreal cx = c * cx1 - s * cy1 + (from.x() + to.x()) / 2;
    const qreal cy = s * cx1 + c * cy1 + (from.y() + to.y()) / 2;
    auto ang = [](qreal ux, qreal uy, qreal vx, qreal vy) {
        return std::atan2(ux * vy - uy * vx, ux * vx + uy * vy);
    };
    const qreal t1 = ang(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry);
    qreal dt = ang((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry);
    if (!sweep && dt > 0) dt -= 2 * M_PI;
    if (sweep && dt < 0) dt += 2 * M_PI;
    const int n = qMax(4, int(std::ceil(std::abs(dt) / qDegreesToRadians(6.0))));
    for (int i = 1; i <= n; ++i) {
        const qreal t = t1 + dt * i / n;
        const qreal ex = rx * std::cos(t), ey = ry * std::sin(t);
        p.lineTo(i == n ? to : QPointF(c * ex - s * ey + cx, s * ex + c * ey + cy));
    }
}

// Squared distance transform, one dimension (Felzenszwalb and Huttenlocher):
// f holds 0 at a site and a large number elsewhere, and leaves as the squared
// distance to the nearest site
void edt1d(std::vector<float>& f, int n, std::vector<float>& d, std::vector<int>& v, std::vector<float>& z) {
    int k = 0;
    v[0] = 0; z[0] = -1e20f; z[1] = 1e20f;
    for (int q = 1; q < n; ++q) {
        float s = ((f[q] + q * q) - (f[v[k]] + v[k] * v[k])) / (2.0f * q - 2.0f * v[k]);
        while (s <= z[k]) {
            --k;
            s = ((f[q] + q * q) - (f[v[k]] + v[k] * v[k])) / (2.0f * q - 2.0f * v[k]);
        }
        ++k; v[k] = q; z[k] = s; z[k + 1] = 1e20f;
    }
    k = 0;
    for (int q = 0; q < n; ++q) {
        while (z[k + 1] < q) ++k;
        d[q] = (q - v[k]) * (q - v[k]) + f[v[k]];
    }
    for (int q = 0; q < n; ++q) f[q] = d[q];
}

std::vector<float> edt2d(const std::vector<bool>& site, int w, int h) {
    const float inf = 1e20f;
    std::vector<float> g(size_t(w) * h);
    for (size_t i = 0; i < g.size(); ++i) g[i] = site[i] ? 0 : inf;
    const int n = qMax(w, h);
    std::vector<float> f(n), d(n), z(n + 1);
    std::vector<int> v(n);
    for (int x = 0; x < w; ++x) {
        for (int y = 0; y < h; ++y) f[y] = g[size_t(y) * w + x];
        edt1d(f, h, d, v, z);
        for (int y = 0; y < h; ++y) g[size_t(y) * w + x] = f[y];
    }
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) f[x] = g[size_t(y) * w + x];
        edt1d(f, w, d, v, z);
        for (int x = 0; x < w; ++x) g[size_t(y) * w + x] = f[x];
    }
    return g;
}

QImage loadImage(const QString& src) {
    QImage img;
    if (src.startsWith(QLatin1String("data:"))) {
        const int comma = src.indexOf(QLatin1Char(','));
        if (comma > 0) img.loadFromData(QByteArray::fromBase64(src.mid(comma + 1).toLatin1()));
    } else {
        const QUrl u(src);
        img.load(u.isLocalFile() ? u.toLocalFile() : src);
    }
    return img;
}

// One axis of the nine slice: where a point of the item lands in the box.
// `s0` and `s1` are the fixed edges, `B` the box, `S` the item. Squeezed, the
// edges scale down to fit; cropped, they keep their size and the middle goes.
struct Axis {
    qreal s0, s1, B, S;
    bool crop;
    qreal k() const { return S < s0 + s1 && s0 + s1 > 0 ? S / (s0 + s1) : 1; }
    qreal split() const { return s0 + s1 > 0 ? S * s0 / (s0 + s1) : S; }
    bool cropping() const { return crop && S < s0 + s1; }
    // the item's point, into the box
    qreal box(qreal x) const {
        if (cropping()) return x < split() ? x : B - (S - x);
        const qreal kk = k();
        if (x <= s0 * kk) return x / qMax(kk, 0.0001);
        if (x >= S - s1 * kk) return B - (S - x) / qMax(kk, 0.0001);
        const qreal mid = B - s0 - s1;
        return mid > 0 ? s0 + (x - s0 * kk) * mid / qMax(S - (s0 + s1) * kk, 0.0001) : s0;
    }
    // ...and the box's point, onto the item
    qreal item(qreal x) const {
        if (cropping()) return x <= split() ? x : S - (B - x);
        const qreal kk = k();
        if (x <= s0) return x * kk;
        if (x >= B - s1) return S - (B - x) * kk;
        const qreal mid = B - s0 - s1;
        return mid > 0 ? s0 * kk + (x - s0) * (S - (s0 + s1) * kk) / mid : s0 * kk;
    }
};

qreal num(const QVariant& v, qreal fallback = 0) {
    bool ok = false;
    const qreal d = v.toDouble(&ok);
    return ok ? d : fallback;
}

} // namespace

QPainterPath WindowShapeItem::parseSvgPath(const QString& d, bool* okOut) {
    QPainterPath p;
    // NONZERO, as SVG fills: odd-even turns anywhere a shape overlaps itself
    // into a hole, and a shape squeezed into a window smaller than its fixed
    // edges overlaps itself as a matter of course — the picture and the field
    // then disagree about where the edge is.
    p.setFillRule(Qt::WindingFill);
    PathLexer lx(d);
    QPointF cur, start, lastCtrl;
    QChar cmd, prev;
    bool ok = true;
    while (true) {
        if (lx.atCommand()) cmd = lx.s[lx.i++];
        else if (!lx.atNumber()) break;
        else if (cmd.isNull()) { ok = false; break; }
        const bool rel = cmd.isLower();
        const QPointF base = rel ? cur : QPointF();
        qreal a, b, c2, d2, e, f;
        switch (cmd.toUpper().unicode()) {
        case 'M':
            if (!lx.number(&a) || !lx.number(&b)) { ok = false; break; }
            cur = base + QPointF(a, b); start = cur; p.moveTo(cur);
            cmd = rel ? QLatin1Char('l') : QLatin1Char('L');   // later pairs are lines
            break;
        case 'L':
            if (!lx.number(&a) || !lx.number(&b)) { ok = false; break; }
            cur = base + QPointF(a, b); p.lineTo(cur); break;
        case 'H':
            if (!lx.number(&a)) { ok = false; break; }
            cur.setX(rel ? cur.x() + a : a); p.lineTo(cur); break;
        case 'V':
            if (!lx.number(&a)) { ok = false; break; }
            cur.setY(rel ? cur.y() + a : a); p.lineTo(cur); break;
        case 'C':
            if (!lx.number(&a) || !lx.number(&b) || !lx.number(&c2) || !lx.number(&d2)
                || !lx.number(&e) || !lx.number(&f)) { ok = false; break; }
            lastCtrl = base + QPointF(c2, d2);
            p.cubicTo(base + QPointF(a, b), lastCtrl, base + QPointF(e, f));
            cur = base + QPointF(e, f); break;
        case 'S': {
            if (!lx.number(&c2) || !lx.number(&d2) || !lx.number(&e) || !lx.number(&f)) { ok = false; break; }
            const QChar pu = prev.toUpper();
            const QPointF c1 = (pu == QLatin1Char('C') || pu == QLatin1Char('S')) ? 2 * cur - lastCtrl : cur;
            lastCtrl = base + QPointF(c2, d2);
            p.cubicTo(c1, lastCtrl, base + QPointF(e, f));
            cur = base + QPointF(e, f); break;
        }
        case 'Q':
            if (!lx.number(&a) || !lx.number(&b) || !lx.number(&c2) || !lx.number(&d2)) { ok = false; break; }
            lastCtrl = base + QPointF(a, b);
            p.quadTo(lastCtrl, base + QPointF(c2, d2));
            cur = base + QPointF(c2, d2); break;
        case 'T': {
            if (!lx.number(&a) || !lx.number(&b)) { ok = false; break; }
            const QChar pu = prev.toUpper();
            lastCtrl = (pu == QLatin1Char('Q') || pu == QLatin1Char('T')) ? 2 * cur - lastCtrl : cur;
            p.quadTo(lastCtrl, base + QPointF(a, b));
            cur = base + QPointF(a, b); break;
        }
        case 'A': {
            bool large = false, sweep = false;
            if (!lx.number(&a) || !lx.number(&b) || !lx.number(&c2) || !lx.flag(&large)
                || !lx.flag(&sweep) || !lx.number(&e) || !lx.number(&f)) { ok = false; break; }
            const QPointF to = base + QPointF(e, f);
            arcTo(p, cur, a, b, c2, large, sweep, to);
            cur = to; break;
        }
        case 'Z':
            p.closeSubpath(); cur = start; break;
        default:
            ok = false;
        }
        if (!ok) break;
        prev = cmd;
    }
    if (okOut) *okOut = ok;
    return p;
}

WindowShapeItem::WindowShapeItem(QQuickItem* parent) : QQuickItem(parent) {
    setFlag(ItemHasContents, true);
}

WindowShapeItem::~WindowShapeItem() {
    // with no window left to schedule on, the render side is gone with it
    delete provider_;
}

void WindowShapeItem::setSpec(const QVariant& s) {
    if (s == spec_) return;
    spec_ = s;
    emit specChanged();
    if (isComponentComplete() && !refused_) rebuild();
}

void WindowShapeItem::setActive(bool on) {
    if (on == active_) return;
    active_ = on;
    emit activeChanged();
    update();
    applyMask();
}

void WindowShapeItem::setInput(bool on) {
    if (on == input_) return;
    input_ = on;
    emit inputChanged();
    if (!on) {
        if (QQuickWindow* w = window()) {
            w->setProperty("meloShape", QVariant());
            if (!w->property("meloInputOff").toBool()) w->setMask(QRegion());
        }
    } else {
        applyMask();
    }
}

// The distance field of a coverage picture in logical pixels: distance to the
// nearest pixel across the edge, less half a pixel. Outside the picture counts
// as outside. `drawOutMiddle` extends the middle 128 px each way for a field
// that will be nine-sliced, so a distance across the stretched middle is never
// shorter than a frame is deep.
void WindowShapeItem::measureField(const QImage& src, qreal dpr, bool drawOutMiddle) {
    const int W0 = src.width(), H0 = src.height();
    if (W0 <= 0 || H0 <= 0) { field_ = QImage(); return; }
    int X1 = 0, X2 = W0, Y1 = 0, Y2 = H0, M = 0;
    if (drawOutMiddle) {
        X1 = qBound(0, int(std::floor(slice_[0] * dpr)), W0);
        X2 = qBound(X1, int(std::ceil((box_.width() - slice_[2]) * dpr)), W0);
        Y1 = qBound(0, int(std::floor(slice_[1] * dpr)), H0);
        Y2 = qBound(Y1, int(std::ceil((box_.height() - slice_[3]) * dpr)), H0);
        M = int(std::ceil(128 * dpr));
    }
    const int EW = drawOutMiddle ? X1 + (X2 > X1 ? M : 0) + (W0 - X2) : W0;
    const int EH = drawOutMiddle ? Y1 + (Y2 > Y1 ? M : 0) + (H0 - Y2) : H0;
    auto srcX = [&](int ox) {
        if (!drawOutMiddle) return ox;
        return ox < X1 ? ox : ox < X1 + M && X2 > X1 ? X1 + qMin(X2 - X1 - 1, (ox - X1) * (X2 - X1) / M)
                                                    : ox - (X2 > X1 ? M : 0) + (X2 - X1);
    };
    auto srcY = [&](int oy) {
        if (!drawOutMiddle) return oy;
        return oy < Y1 ? oy : oy < Y1 + M && Y2 > Y1 ? Y1 + qMin(Y2 - Y1 - 1, (oy - Y1) * (Y2 - Y1) / M)
                                                    : oy - (Y2 > Y1 ? M : 0) + (Y2 - Y1);
    };
    const int pw = EW + 2, ph = EH + 2;
    // the padding round the picture is outside: a site for the inside distance, not one for the outside
    std::vector<bool> in(size_t(pw) * ph, true), out(size_t(pw) * ph, false);
    for (int y = 0; y < EH; ++y) {
        const QRgb* line = reinterpret_cast<const QRgb*>(src.constScanLine(qBound(0, srcY(y), H0 - 1)));
        for (int x = 0; x < EW; ++x) {
            const bool inside = qAlpha(line[qBound(0, srcX(x), W0 - 1)]) >= 128;
            in[size_t(y + 1) * pw + x + 1] = !inside;
            out[size_t(y + 1) * pw + x + 1] = inside;
        }
    }
    const std::vector<float> dIn = edt2d(in, pw, ph), dOut = edt2d(out, pw, ph);
    field_ = QImage(EW, EH, QImage::Format_RGBA8888);
    fieldBox_ = QSizeF(EW / dpr, EH / dpr);
    for (int y = 0; y < EH; ++y) {
        uchar* line = field_.scanLine(y);
        for (int x = 0; x < EW; ++x) {
            const size_t i = size_t(y + 1) * pw + x + 1;
            const float di = std::sqrt(dIn[i]), dO = std::sqrt(dOut[i]);
            const float dev = di > 0 ? di - 0.5f : -(dO - 0.5f);
            const float logical = qBound(-32.0f, dev / float(dpr), 95.99f);
            const int packed = qBound(0, int(std::lround((logical + 32.0f) * 512.0f)), 65535);
            line[4 * x] = uchar(packed >> 8);
            line[4 * x + 1] = uchar(packed & 0xff);
            line[4 * x + 2] = 0;
            line[4 * x + 3] = 255;
        }
    }
    ++generation_;
}

// The picture at a size, stretched through the nine slices exactly as the mask
// draws it — what the region and an exact field are measured from.
QImage WindowShapeItem::nineSliced(int w, int h, qreal dpr) const {
    QImage out(qMax(1, int(std::ceil(w * dpr))), qMax(1, int(std::ceil(h * dpr))),
               QImage::Format_ARGB32_Premultiplied);
    out.fill(Qt::transparent);
    if (picture_.isNull()) return out;
    QPainter pa(&out);
    pa.setRenderHint(QPainter::SmoothPixmapTransform, true);
    pa.scale(dpr, dpr);
    const qreal bw = box_.width(), bh = box_.height(), d = pictureDpr_;
    const Axis ax{slice_[0], slice_[2], bw, qreal(w), crop_};
    const Axis ay{slice_[1], slice_[3], bh, qreal(h), crop_};
    const qreal dx[4] = {0, ax.cropping() ? ax.split() : slice_[0] * ax.k(),
                         ax.cropping() ? ax.split() : w - slice_[2] * ax.k(), qreal(w)};
    const qreal dy[4] = {0, ay.cropping() ? ay.split() : slice_[1] * ay.k(),
                         ay.cropping() ? ay.split() : h - slice_[3] * ay.k(), qreal(h)};
    const qreal sx[4] = {0, ax.box(dx[1]) * d, ax.box(dx[2]) * d, bw * d};
    const qreal sy[4] = {0, ay.box(dy[1]) * d, ay.box(dy[2]) * d, bh * d};
    for (int cy = 0; cy < 3; ++cy)
        for (int cx = 0; cx < 3; ++cx)
            pa.drawImage(QRectF(dx[cx], dy[cy], dx[cx + 1] - dx[cx], dy[cy + 1] - dy[cy]), picture_,
                         QRectF(sx[cx], sy[cy], sx[cx + 1] - sx[cx], sy[cy + 1] - sy[cy]));
    pa.end();
    return out;
}

// Is the stretching middle straight? Every row of the middle band must start
// and end where its neighbours do, and every column likewise: a feature drawn
// there stretches with the window, and a field measured once and nine-sliced
// would not follow it.
bool WindowShapeItem::middleIsStraight() const {
    if (rowBounds_.isEmpty() || colBounds_.isEmpty()) return true;
    const int Y1 = qBound(0, int(std::floor(slice_[1] * pictureDpr_)), rowBounds_.size());
    const int Y2 = qBound(Y1, int(std::ceil((box_.height() - slice_[3]) * pictureDpr_)), rowBounds_.size());
    for (int y = Y1 + 1; y < Y2; ++y)
        if (rowBounds_[y] != rowBounds_[Y1]) return false;
    const int X1 = qBound(0, int(std::floor(slice_[0] * pictureDpr_)), colBounds_.size());
    const int X2 = qBound(X1, int(std::ceil((box_.width() - slice_[2]) * pictureDpr_)), colBounds_.size());
    for (int x = X1 + 1; x < X2; ++x)
        if (colBounds_[x] != colBounds_[X1]) return false;
    return true;
}

// The field at the window's own size, for a shape the nine slices cannot
// describe: the outline drawn at this size, measured, and the shader told it
// has no slices — what the mask draws and what the border follows are then the
// same edge, whatever the middle does.
void WindowShapeItem::remeasureAtSize() {
    const int w = int(width()), h = int(height());
    if (!exact_ || kind_ == Kind::None || w <= 0 || h <= 0) return;
    if (fieldFor_ == QSize(w, h)) return;
    const qreal dpr = window() ? window()->effectiveDevicePixelRatio() : 1.0;
    QImage at(qMax(1, int(std::ceil(w * dpr))), qMax(1, int(std::ceil(h * dpr))),
              QImage::Format_ARGB32_Premultiplied);
    at.fill(Qt::transparent);
    QPainter pa(&at);
    pa.setRenderHint(QPainter::Antialiasing, true);
    pa.scale(dpr, dpr);
    if (kind_ == Kind::Path) pa.fillPath(outlineAt(w, h), Qt::white);
    else pa.drawImage(QRectF(0, 0, w, h), nineSliced(w, h, 1.0));
    pa.end();
    fieldFor_ = QSize(w, h);
    measureField(at, dpr, false);
    fieldBox_ = QSizeF(w, h);
    emit shapeChanged();
    update();
}

void WindowShapeItem::rebuild() {
    kind_ = Kind::None;
    path_ = QPainterPath();
    picture_ = QImage();
    field_ = QImage();
    rowBounds_.clear(); colBounds_.clear(); bounds_ = QRect();
    std::fill(std::begin(slice_), std::end(slice_), 0);
    std::fill(std::begin(cellOpaque_), std::end(cellOpaque_), false);
    const QVariantMap m = spec_.toMap();
    crop_ = m.value(QStringLiteral("fit")).toString() == QLatin1String("crop");
    const qreal dpr = window() ? window()->effectiveDevicePixelRatio() : 1.0;
    auto slicesFrom = [&](const QVariant& v) {
        const QVariantList l = v.toList();
        for (int i = 0; i < 4 && i < l.size(); ++i) slice_[i] = qMax<qreal>(0, num(l[i]));
    };

    if (m.contains(QStringLiteral("corners"))) {
        const QVariantList cs = m.value(QStringLiteral("corners")).toList();
        QString style[4];
        qreal size[4] = {0, 0, 0, 0};
        for (int i = 0; i < 4; ++i) {
            const QVariantMap c = cs.value(i).toMap();
            style[i] = c.value(QStringLiteral("style"), QStringLiteral("round")).toString();
            size[i] = qMax<qreal>(0, num(c.value(QStringLiteral("size"))));
            if (style[i] == QLatin1String("square")) size[i] = 0;
        }
        if (size[0] + size[1] + size[2] + size[3] > 0) {
            // corners at their own size, and a two-pixel middle that stretches
            const qreal l = qMax(size[0], size[3]), r = qMax(size[1], size[2]);
            const qreal t = qMax(size[0], size[1]), b = qMax(size[3], size[2]);
            box_ = QSizeF(l + r + 2, t + b + 2);
            slice_[0] = l; slice_[1] = t; slice_[2] = r; slice_[3] = b;
            const qreal W = box_.width(), H = box_.height();
            QPainterPath p;
            auto corner = [&](int i, QPointF at, qreal startDeg) {
                const qreal s = size[i];
                // the corner point, and the two points s along its edges
                if (s <= 0) { p.lineTo(at); return; }
                if (style[i] == QLatin1String("cut")) {
                    // from the edge before to the edge after, going clockwise
                    const QPointF a = at + QPointF(i == 0 ? 0 : i == 1 ? -s : i == 2 ? 0 : s,
                                                   i == 0 ? s : i == 1 ? 0 : i == 2 ? -s : 0);
                    const QPointF c = at + QPointF(i == 0 ? s : i == 1 ? 0 : i == 2 ? -s : 0,
                                                   i == 0 ? 0 : i == 1 ? s : i == 2 ? 0 : -s);
                    p.lineTo(a); p.lineTo(c);
                    return;
                }
                const QRectF box(i == 0 || i == 3 ? at.x() : at.x() - 2 * s,
                                 i == 0 || i == 1 ? at.y() : at.y() - 2 * s, 2 * s, 2 * s);
                p.arcTo(box, startDeg, -90);
            };
            p.moveTo(size[0], 0);
            corner(1, QPointF(W, 0), 90);
            corner(2, QPointF(W, H), 0);
            corner(3, QPointF(0, H), 270);
            corner(0, QPointF(0, 0), 180);
            p.closeSubpath();
            p.setFillRule(Qt::WindingFill);
            path_ = p;
            kind_ = Kind::Path;
        }
    } else if (m.contains(QStringLiteral("path"))) {
        bool ok = false;
        const QPainterPath p = parseSvgPath(m.value(QStringLiteral("path")).toString(), &ok);
        const QVariantList b = m.value(QStringLiteral("box")).toList();
        box_ = b.size() >= 2 ? QSizeF(num(b[0]), num(b[1])) : p.boundingRect().size();
        if (ok && !p.isEmpty() && box_.width() > 0 && box_.height() > 0) {
            path_ = p;
            slicesFrom(m.value(QStringLiteral("slice")));
            kind_ = Kind::Path;
        } else {
            qWarning("[windowshape] the path does not parse, or has no box; the window keeps its rectangle");
        }
    } else if (m.contains(QStringLiteral("image"))) {
        QImage img = loadImage(m.value(QStringLiteral("image")).toString());
        const qreal scale = qMax<qreal>(0.01, num(m.value(QStringLiteral("scale")), 1));
        if (!img.isNull()) {
            picture_ = img.convertToFormat(QImage::Format_ARGB32_Premultiplied);
            // coverage only: white at the image's alpha
            for (int y = 0; y < picture_.height(); ++y) {
                QRgb* line = reinterpret_cast<QRgb*>(picture_.scanLine(y));
                for (int x = 0; x < picture_.width(); ++x) {
                    const int a = qAlpha(line[x]);
                    line[x] = qRgba(a, a, a, a);
                }
            }
            pictureDpr_ = scale;
            box_ = QSizeF(picture_.width() / scale, picture_.height() / scale);
            slicesFrom(m.value(QStringLiteral("slice")));
            kind_ = Kind::Image;
        } else {
            qWarning("[windowshape] the image does not load; the window keeps its rectangle");
        }
    }

    if (kind_ == Kind::Path) {
        const QSize px(qMax(1, int(std::ceil(box_.width() * dpr))), qMax(1, int(std::ceil(box_.height() * dpr))));
        picture_ = QImage(px, QImage::Format_ARGB32_Premultiplied);
        picture_.fill(Qt::transparent);
        QPainter pa(&picture_);
        pa.setRenderHint(QPainter::Antialiasing, true);
        pa.scale(px.width() / box_.width(), px.height() / box_.height());
        pa.fillPath(path_, Qt::white);
        pa.end();
        pictureDpr_ = px.width() / box_.width();
    }

    if (kind_ != Kind::None) {
        // Where the shape starts and ends on every row and every column, for
        // intrusion(): what has to move in to stay out of a cut reads these.
        rowBounds_.clear(); colBounds_.clear();
        rowBounds_.reserve(picture_.height()); colBounds_.reserve(picture_.width());
        QVector<int> colLo(picture_.width(), picture_.width() + 1), colHi(picture_.width(), -1);
        for (int y = 0; y < picture_.height(); ++y) {
            const QRgb* line = reinterpret_cast<const QRgb*>(picture_.constScanLine(y));
            int lo = picture_.width() + 1, hi = -1;
            for (int x = 0; x < picture_.width(); ++x) {
                if (qAlpha(line[x]) < 128) continue;
                lo = qMin(lo, x); hi = qMax(hi, x);
                colLo[x] = qMin(colLo[x], y); colHi[x] = qMax(colHi[x], y);
            }
            rowBounds_.append(QPoint(lo, hi));
        }
        for (int x = 0; x < picture_.width(); ++x) colBounds_.append(QPoint(colLo[x], colHi[x]));
        bounds_ = QRect(0, 0, picture_.width(), picture_.height());

        // clamp the slices into the box first: the field is cut by them
        slice_[0] = qMin(slice_[0], box_.width()); slice_[2] = qMin(slice_[2], box_.width() - slice_[0]);
        slice_[1] = qMin(slice_[1], box_.height()); slice_[3] = qMin(slice_[3], box_.height() - slice_[1]);

        // the field: nine-sliced where the middle is straight, and measured at
        // the window's size where it is not (see measureField / remeasureAtSize)
        straightMiddle_ = middleIsStraight();
        exact_ = !straightMiddle_;
        if (!exact_) measureField(picture_, pictureDpr_, true);
        else { fieldFor_ = QSize(); remeasureAtSize(); }

        // the slices wholly inside the shape
        const int xs[4] = {0, int(std::floor(slice_[0] * pictureDpr_)),
                           int(std::ceil((box_.width() - slice_[2]) * pictureDpr_)), picture_.width()};
        const int ys[4] = {0, int(std::floor(slice_[1] * pictureDpr_)),
                           int(std::ceil((box_.height() - slice_[3]) * pictureDpr_)), picture_.height()};
        for (int cy = 0; cy < 3; ++cy)
            for (int cx = 0; cx < 3; ++cx) {
                bool opaque = true;
                for (int y = ys[cy]; opaque && y < ys[cy + 1]; ++y) {
                    const QRgb* line = reinterpret_cast<const QRgb*>(picture_.constScanLine(y));
                    for (int x = xs[cx]; x < xs[cx + 1]; ++x)
                        if (qAlpha(line[x]) < 255) { opaque = false; break; }
                }
                cellOpaque_[cy * 3 + cx] = opaque;
            }
    }
    ++generation_;
    emit shapeChanged();
    update();
    applyMask();
}

QPainterPath WindowShapeItem::outlineAt(qreal w, qreal h) const {
    if (kind_ != Kind::Path) return QPainterPath();
    const Axis ax{slice_[0], slice_[2], box_.width(), w, crop_};
    const Axis ay{slice_[1], slice_[3], box_.height(), h, crop_};
    // Cut every edge at the slices first: stretching is per slice, so an edge
    // crossing into the middle bends there, and moving only its ends would put
    // the border off the window's real edge.
    const qreal cuts[4] = {slice_[0], box_.width() - slice_[2], slice_[1], box_.height() - slice_[3]};
    QPainterPath out;
    out.setFillRule(Qt::WindingFill);
    const QList<QPolygonF> polys = path_.toSubpathPolygons();
    for (const QPolygonF& poly : polys) {
        if (poly.size() < 2) continue;
        QPolygonF mapped;
        for (int i = 0; i < poly.size(); ++i) {
            const QPointF a = poly[i];
            const QPointF b = poly[(i + 1) % poly.size()];
            mapped << QPointF(ax.item(a.x()), ay.item(a.y()));
            // where this edge crosses a slice line, in order along it
            QList<qreal> ts;
            for (int c = 0; c < 4; ++c) {
                const bool vertical = c < 2;
                const qreal from = vertical ? a.x() : a.y(), to = vertical ? b.x() : b.y();
                if (qFuzzyCompare(from, to)) continue;
                const qreal t = (cuts[c] - from) / (to - from);
                if (t > 0.0001 && t < 0.9999) ts << t;
            }
            std::sort(ts.begin(), ts.end());
            for (qreal t : ts) {
                const QPointF at = a + (b - a) * t;
                mapped << QPointF(ax.item(at.x()), ay.item(at.y()));
            }
        }
        out.addPolygon(mapped);
        out.closeSubpath();
    }
    return out;
}

qreal WindowShapeItem::intrusion(const QString& edge, qreal from, qreal to) const {
    const int w = int(width()), h = int(height());
    if (!active_ || kind_ == Kind::None || w <= 0 || h <= 0 || bounds_.isEmpty()) return 0;
    const bool vertical = edge == QLatin1String("left") || edge == QLatin1String("right");
    const bool atEnd = edge == QLatin1String("right") || edge == QLatin1String("bottom");
    // the scan is of the shape's box; the stretch asked about is the window's
    const Axis ax{slice_[0], slice_[2], box_.width(), qreal(w), crop_};
    const Axis ay{slice_[1], slice_[3], box_.height(), qreal(h), crop_};
    const Axis& along = vertical ? ay : ax;       // the axis the stretch runs along
    const Axis& into = vertical ? ax : ay;        // ...and the one it eats into
    const QVector<QPoint>& rows = vertical ? rowBounds_ : colBounds_;
    if (rows.isEmpty()) return 0;
    const qreal lo = along.box(qBound<qreal>(0, qMin(from, to), along.S));
    const qreal hi = along.box(qBound<qreal>(0, qMax(from, to), along.S));
    qreal worst = 0;
    const qreal span = vertical ? box_.width() : box_.height();
    for (int i = 0; i < rows.size(); ++i) {
        const qreal at = (i + 0.5) / pictureDpr_;
        if (at < lo || at > hi) continue;
        const QPoint& b = rows[i];
        if (b.x() > b.y()) continue;             // nothing of the shape on this line
        const qreal edgeIn = atEnd ? span - (b.y() + 1) / pictureDpr_ : b.x() / pictureDpr_;
        worst = qMax(worst, edgeIn);
    }
    // back into window pixels: a fixed edge keeps its size, a stretched one does not
    return atEnd ? into.S - into.item(span - worst) : into.item(worst);
}

bool WindowShapeItem::maskAt(qreal x, qreal y) const {
    if (picture_.isNull() || box_.isEmpty()) return true;
    const Axis ax{slice_[0], slice_[2], box_.width(), width(), crop_};
    const Axis ay{slice_[1], slice_[3], box_.height(), height(), crop_};
    const int px = qBound(0, int(ax.box(x) * pictureDpr_), picture_.width() - 1);
    const int py = qBound(0, int(ay.box(y) * pictureDpr_), picture_.height() - 1);
    return qAlpha(reinterpret_cast<const QRgb*>(picture_.constScanLine(py))[px]) >= 128;
}

// What the grab ring contains: a point within grabRing inside the shape's
// edge. QQuickItem::containmentMask asks this of every press and every hover,
// so it is two field reads and nothing else.
class ShapeEdgeRing : public QObject {
    Q_OBJECT
public:
    explicit ShapeEdgeRing(WindowShapeItem* item) : QObject(item), item_(item) {}
    Q_INVOKABLE bool contains(const QPointF& p) const {
        if (!item_->hasShape() || !item_->active()) {
            // no shape: the window's own rectangle, its edge as wide as the ring
            const qreal r = item_->grabRing();
            return p.x() < r || p.y() < r || p.x() > item_->width() - r || p.y() > item_->height() - r;
        }
        const qreal d = item_->distanceAt(p.x(), p.y());
        return d >= 0 && d <= item_->grabRing();
    }
private:
    WindowShapeItem* item_;
};

QObject* WindowShapeItem::edgeRing() const {
    if (!ring_) ring_ = new ShapeEdgeRing(const_cast<WindowShapeItem*>(this));
    return ring_;
}

void WindowShapeItem::setGrabRing(qreal px) {
    if (qFuzzyCompare(px, grabRing_)) return;
    grabRing_ = qMax<qreal>(0, px);
    emit grabRingChanged();
}

QPointF WindowShapeItem::edgeNormalAt(qreal x, qreal y) const {
    if (!hasShape()) {
        // the rectangle's own: whichever sides the point is nearest
        const qreal r = qMax<qreal>(1, grabRing_);
        QPointF n(0, 0);
        if (x < r) n.setX(-1); else if (x > width() - r) n.setX(1);
        if (y < r) n.setY(-1); else if (y > height() - r) n.setY(1);
        return n;
    }
    const qreal dx = distanceAt(x + 1, y) - distanceAt(x - 1, y);
    const qreal dy = distanceAt(x, y + 1) - distanceAt(x, y - 1);
    const qreal len = std::hypot(dx, dy);
    return len > 0.0001 ? QPointF(-dx / len, -dy / len) : QPointF(0, 0);
}

qreal WindowShapeItem::distanceAt(qreal x, qreal y) const {
    if (field_.isNull() || fieldBox_.isEmpty()) return 0;
    const QRectF fs = fieldSlices();
    const Axis ax{fs.x(), fs.width(), fieldBox_.width(), width(), crop_};
    const Axis ay{fs.y(), fs.height(), fieldBox_.height(), height(), crop_};
    // the middle by offset, as the shader does it
    auto axisBox = [](const Axis& a, qreal p) {
        if (a.cropping()) return a.box(p);
        const qreal k = a.k(), mid = a.B - a.s0 - a.s1;
        if (p < a.s0 * k) return p / qMax(k, 0.0001);
        if (p > a.S - a.s1 * k) return a.B - (a.S - p) / qMax(k, 0.0001);
        const qreal lo = p - a.s0 * k, hi = a.S - a.s1 * k - p;
        return lo <= hi ? a.s0 + qMin(lo, mid / 2) : a.B - a.s1 - qMin(hi, mid / 2);
    };
    const qreal bx = axisBox(ax, x), by = axisBox(ay, y);
    const qreal tx = bx / fieldBox_.width() * field_.width() - 0.5;
    const qreal ty = by / fieldBox_.height() * field_.height() - 0.5;
    auto texel = [&](int i, int j) {
        // RGBA8888 is red, green, blue, alpha in that order in memory; QRgb is
        // not, and reading it as one swaps the two bytes the distance is in
        const uchar* line = field_.constScanLine(qBound(0, j, field_.height() - 1));
        const int at = 4 * qBound(0, i, field_.width() - 1);
        return (line[at] * 256.0 + line[at + 1]) / 512.0 - 32.0;
    };
    const int i = int(std::floor(tx)), j = int(std::floor(ty));
    const qreal fx = tx - i, fy = ty - j;
    const qreal a = texel(i, j) * (1 - fx) + texel(i + 1, j) * fx;
    const qreal b = texel(i, j + 1) * (1 - fx) + texel(i + 1, j + 1) * fx;
    return a * (1 - fy) + b * fy;
}

QRegion WindowShapeItem::regionAt(int w, int h) const {
    if (w <= 0 || h <= 0) return QRegion();
    if (kind_ == Kind::Path)
        return QRegion(outlineAt(w, h).toFillPolygon().toPolygon(), Qt::WindingFill);
    if (kind_ == Kind::Image) {
        const QImage full = nineSliced(w, h, 1.0);
        return QRegion(QBitmap::fromImage(full.createAlphaMask(Qt::ThresholdAlphaDither)));
    }
    return QRegion();
}

void WindowShapeItem::applyMask() {
    QQuickWindow* w = window();
    if (!w || !input_ || !isComponentComplete() || refused_) return;
    const QRegion r = active_ && kind_ != Kind::None ? regionAt(int(width()), int(height())) : QRegion();
    w->setProperty("meloShape", QVariant::fromValue(r));
    // a window made click-through keeps that until it is given input back
    if (!w->property("meloInputOff").toBool()) w->setMask(r);
    ++generation_;
    emit generationChanged();
    emit shapeApplied();
}

void WindowShapeItem::geometryChange(const QRectF& now, const QRectF& before) {
    QQuickItem::geometryChange(now, before);
    if (now.size() == before.size()) return;
    update();
    applyMask();
    // A field measured at size is measured again when the size settles, not on
    // every step of a drag: it is a distance transform of the whole window.
    if (exact_) {
        if (!resize_) {
            resize_ = new QTimer(this);
            resize_->setSingleShot(true);
            resize_->setInterval(70);
            connect(resize_, &QTimer::timeout, this, [this] { remeasureAtSize(); });
        }
        resize_->start();
    }
}

void WindowShapeItem::itemChange(ItemChange change, const ItemChangeData& value) {
    QQuickItem::itemChange(change, value);
    if (change == ItemSceneChange || change == ItemDevicePixelRatioHasChanged) {
        if (isComponentComplete()) rebuild();
    }
}

QSGTextureProvider* WindowShapeItem::textureProvider() const {
    if (!provider_) {
        provider_ = new ShapeFieldProvider;
        // the field is filled in on the next paint
        const_cast<WindowShapeItem*>(this)->update();
    }
    return provider_;
}

void WindowShapeItem::releaseResources() {
    if (provider_ && window()) {
        // the texture belongs to the render side and is deleted there
        class Cleanup : public QRunnable {
        public:
            explicit Cleanup(ShapeFieldProvider* p) : p_(p) {}
            void run() override { delete p_; }
            ShapeFieldProvider* p_;
        };
        window()->scheduleRenderJob(new Cleanup(provider_), QQuickWindow::AfterSynchronizingStage);
        provider_ = nullptr;
    }
}

QSGNode* WindowShapeItem::updatePaintNode(QSGNode* old, UpdatePaintNodeData*) {
    const qreal w = width(), h = height();
    // The field, for readers along the edge, whether or not the mask draws
    if (provider_ && provider_->generation != generation_) {
        delete provider_->tex;
        provider_->tex = field_.isNull() ? nullptr
            : window()->createTextureFromImage(field_, QQuickWindow::TextureHasAlphaChannel);
        if (provider_->tex) {
            provider_->tex->setFiltering(QSGTexture::Nearest);
            provider_->tex->setMipmapFiltering(QSGTexture::None);
            provider_->tex->setHorizontalWrapMode(QSGTexture::ClampToEdge);
            provider_->tex->setVerticalWrapMode(QSGTexture::ClampToEdge);
        }
        provider_->generation = generation_;
        emit provider_->textureChanged();
    }
    if (!active_ || kind_ == Kind::None || picture_.isNull() || w <= 0 || h <= 0) {
        delete old;
        return nullptr;
    }
    auto* node = static_cast<ShapeNode*>(old);
    if (!node) node = new ShapeNode;
    if (node->generation != generation_) {
        delete node->mat()->texture;
        node->mat()->texture = window()->createTextureFromImage(picture_, QQuickWindow::TextureHasAlphaChannel);
        node->generation = generation_;
        node->markDirty(QSGNode::DirtyMaterial);
    }

    // The nine slices, less the ones wholly inside the shape
    const qreal bw = box_.width(), bh = box_.height();
    const Axis ax{slice_[0], slice_[2], bw, w, crop_};
    const Axis ay{slice_[1], slice_[3], bh, h, crop_};
    const qreal xs[2] = {ax.cropping() ? ax.split() : slice_[0] * ax.k(),
                         ax.cropping() ? ax.split() : w - slice_[2] * ax.k()};
    const qreal ys[2] = {ay.cropping() ? ay.split() : slice_[1] * ay.k(),
                         ay.cropping() ? ay.split() : h - slice_[3] * ay.k()};
    const float X[4] = {0, float(xs[0]), float(xs[1]), float(w)};
    const float Y[4] = {0, float(ys[0]), float(ys[1]), float(h)};
    const float U[4] = {0, float(ax.box(xs[0]) / bw), float(ax.box(xs[1]) / bw), 1};
    const float V[4] = {0, float(ay.box(ys[0]) / bh), float(ay.box(ys[1]) / bh), 1};
    int cells = 0;
    for (bool o : cellOpaque_) cells += o ? 0 : 1;
    QSGGeometry* g = node->geometry();
    g->allocate(cells * 6);
    QSGGeometry::TexturedPoint2D* v = g->vertexDataAsTexturedPoint2D();
    int k = 0;
    for (int cy = 0; cy < 3; ++cy)
        for (int cx = 0; cx < 3; ++cx) {
            if (cellOpaque_[cy * 3 + cx]) continue;
            if (X[cx + 1] <= X[cx] || Y[cy + 1] <= Y[cy]) {
                for (int i = 0; i < 6; ++i) v[k++].set(0, 0, 0, 0);
                continue;
            }
            const float x0 = X[cx], x1 = X[cx + 1], y0 = Y[cy], y1 = Y[cy + 1];
            const float u0 = U[cx], u1 = U[cx + 1], v0 = V[cy], v1 = V[cy + 1];
            v[k++].set(x0, y0, u0, v0); v[k++].set(x1, y0, u1, v0); v[k++].set(x0, y1, u0, v1);
            v[k++].set(x1, y0, u1, v0); v[k++].set(x1, y1, u1, v1); v[k++].set(x0, y1, u0, v1);
        }
    node->markDirty(QSGNode::DirtyGeometry);
    return node;
}

#include "WindowShapeItem.moc"
