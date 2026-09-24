#include "ParticlesItem.h"

#include <QDateTime>
#include <QColor>
#include <QImage>
#include <QPainter>
#include <QQuickWindow>
#include <QSGGeometryNode>
#include <QSGTexture>
#include <QSGTextureMaterial>
#include <QSGVertexColorMaterial>
#include <QTimer>
#include <QCoreApplication>
#include <algorithm>
#include <cmath>

namespace {
// SAME rng/clock as BackgroundItem — the two renderers must stay in step
constexpr quint32 kSeed = 0x1a2b3c4d;
struct Rng {
    quint32 s;
    explicit Rng(quint32 seed) : s(seed) {}
    double next() {
        s += 0x6D2B79F5u;
        quint32 t = s;
        t = (t ^ (t >> 15)) * (t | 1u);
        t ^= t + (t ^ (t >> 7)) * (t | 61u);
        return double((t ^ (t >> 14))) / 4294967296.0;
    }
};
double absT() { return double(QDateTime::currentMSecsSinceEpoch() / 33) * 0.033; }
// scaling (see BackgroundItem.cpp)
constexpr double kRefArea = 1920.0 * 1080.0;
constexpr int kPoolMult = 4;
double sizeScaleFor(const QString& mode, double w, double h) {
    if (mode == QLatin1String("count") || mode == QLatin1String("off")) return 1.0;
    return std::pow((w * h) / kRefArea, 0.25);
}
int countFor(const QString& mode, int base, double w, double h) {
    if (mode == QLatin1String("size") || mode == QLatin1String("off")) return base;
    return std::max(1, int(std::lround(base * std::sqrt((w * h) / kRefArea))));
}

QTimer* s_tick = nullptr;
std::vector<ParticlesItem*> s_instances;

// Dots are textured quads sampling a baked antialiased circle sprite —
// plain quads rendered as SQUARES. The node owns the texture so it dies
// on the render thread with the node.
class DotsNode : public QSGGeometryNode {
public:
    QSGTexture* tex = nullptr;
    QRgb texKey = 0;
    ~DotsNode() override { delete tex; }
};

QImage dotSprite(const QColor& c) {
    QImage img(64, 64, QImage::Format_ARGB32_Premultiplied);
    img.fill(Qt::transparent);
    QPainter p(&img);
    p.setRenderHint(QPainter::Antialiasing, true);
    p.setPen(Qt::NoPen);
    p.setBrush(c);
    p.drawEllipse(QRectF(1, 1, 62, 62));
    return img;
}
} // namespace

ParticlesItem::ParticlesItem(QQuickItem* parent) : QQuickItem(parent) {
    setFlag(ItemHasContents, true);
    s_instances.push_back(this);
    if (!s_tick) {
        s_tick = new QTimer(qApp);
        s_tick->setInterval(33);
        QObject::connect(s_tick, &QTimer::timeout, [] {
            for (auto* it : s_instances)
                if (it->wantsTick()) it->update();
        });
    }
    syncTick();
}

ParticlesItem::~ParticlesItem() {
    s_instances.erase(std::remove(s_instances.begin(), s_instances.end(), this),
                      s_instances.end());
    syncTick();
}


void ParticlesItem::setConfig(const QVariantMap& c) {
    config_ = c;
    active_ = c.value("type").toString() == QLatin1String("particles");
    opts_ = c.value("options").toMap();
    reseed();
    syncTick();
    update();
    emit configChanged();
}

void ParticlesItem::setHold(bool h) {
    if (hold_ == h) return;
    hold_ = h;
    syncTick();
    emit holdChanged();
}

void ParticlesItem::itemChange(ItemChange change, const ItemChangeData& value) {
    QQuickItem::itemChange(change, value);
    if (change == ItemVisibleHasChanged) syncTick();
}

void ParticlesItem::syncTick() {
    if (!s_tick) return;
    bool any = false;
    for (auto* it : s_instances) any = any || it->wantsTick();
    if (any && !s_tick->isActive()) s_tick->start();
    else if (!any && s_tick->isActive()) s_tick->stop();
}

void ParticlesItem::reseed() {
    particles_.clear();
    if (!active_) return;
    Rng rnd(kSeed);
    // 4x pool, prefix drawn per countFor: resizes never re-layout
    const int count = int(opts_.value("count", 80).toDouble()) * kPoolMult;
    for (int i = 0; i < count; i++) {
        const double ang = rnd.next() * M_PI * 2, v = 0.2 + rnd.next() * 0.8;
        particles_.push_back({rnd.next(), rnd.next(), std::cos(ang) * v, std::sin(ang) * v});
    }
}

QSGNode* ParticlesItem::updatePaintNode(QSGNode* old, UpdatePaintNodeData*) {
    const double w = width(), h = height();
    if (!active_ || particles_.empty() || w <= 0 || h <= 0) {
        delete old;
        return nullptr;
    }

    const QString scaleMode = opts_.value("scaleMode", "classic").toString();
    const double ss = sizeScaleFor(scaleMode, w, h);
    const double T = absT();
    const double speed = opts_.value("speed", 1).toDouble() * 0.2;
    QColor color(opts_.value("color", "#ffffff").toString());
    if (!color.isValid()) color = QColor("#ffffff");
    const double sz = opts_.value("size", 2).toDouble() * ss;
    const bool lines = opts_.value("lines", true).toBool();
    const double ld = opts_.value("lineDistance", 120).toDouble() * ss;

    const int n = std::min<int>(particles_.size(),
        countFor(scaleMode, int(opts_.value("count", 80).toDouble()), w, h));
    // PIXEL-space motion (p += v*speed px/frame @60fps, wrapped at the
    // canvas edges); normalized-space motion would make speed depend on the
    // window size
    std::vector<float> px(n), py(n);
    const double adv = speed * 60.0 * T;
    for (int i = 0; i < n; i++) {
        double x = std::fmod(particles_[i].nx * w + particles_[i].vx * adv, w);
        double y = std::fmod(particles_[i].ny * h + particles_[i].vy * adv, h);
        if (x < 0) x += w;
        if (y < 0) y += h;
        px[i] = float(x);
        py[i] = float(y);
    }

    // collect line pairs first (vertex count must be known up front)
    struct Pair { int i, j; float a; };
    std::vector<Pair> pairs;
    if (lines) {
        const double d2max = ld * ld;
        for (int i = 0; i < n; i++)
            for (int j = i + 1; j < n; j++) {
                const double dx = px[i] - px[j], dy = py[i] - py[j];
                const double d2 = dx * dx + dy * dy;
                if (d2 < d2max)
                    pairs.push_back({i, j, float(1.0 - std::sqrt(d2) / ld)});
            }
    }

    auto* node = static_cast<DotsNode*>(old);
    if (!node) {
        node = new DotsNode;
        auto* mat = new QSGTextureMaterial;
        node->setMaterial(mat);
        node->setFlag(QSGNode::OwnsMaterial);
        node->setFlag(QSGNode::OwnsGeometry);
    }
    // circle sprite texture, regenerated when the color changes
    if (!node->tex || node->texKey != color.rgba()) {
        delete node->tex;
        node->tex = window()->createTextureFromImage(dotSprite(color));
        node->tex->setFiltering(QSGTexture::Linear);
        node->texKey = color.rgba();
        static_cast<QSGTextureMaterial*>(node->material())->setTexture(node->tex);
        node->markDirty(QSGNode::DirtyMaterial);
    }

    const int dotVerts = n * 6;
    auto* g = node->geometry();
    if (!g || g->vertexCount() != dotVerts) {
        g = new QSGGeometry(QSGGeometry::defaultAttributes_TexturedPoint2D(), dotVerts);
        g->setDrawingMode(QSGGeometry::DrawTriangles);
        node->setGeometry(g);
    }
    g->markVertexDataDirty();
    auto* v = g->vertexDataAsTexturedPoint2D();
    const uchar cr = uchar(color.red()), cg = uchar(color.green()), cb = uchar(color.blue());
    const float r = float(std::max(0.5, sz));
    for (int i = 0; i < n; i++) {
        const float x = px[i], y = py[i];
        const float x0 = x - r, y0 = y - r, x1 = x + r, y1 = y + r;
        QSGGeometry::TexturedPoint2D* q = v + i * 6;
        q[0].set(x0, y0, 0, 0);
        q[1].set(x1, y0, 1, 0);
        q[2].set(x0, y1, 0, 1);
        q[3].set(x1, y0, 1, 0);
        q[4].set(x1, y1, 1, 1);
        q[5].set(x0, y1, 0, 1);
    }
    node->markDirty(QSGNode::DirtyGeometry);

    // line child node
    auto* lineNode = static_cast<QSGGeometryNode*>(node->firstChild());
    if (!lineNode) {
        lineNode = new QSGGeometryNode;
        lineNode->setMaterial(new QSGVertexColorMaterial);
        lineNode->setFlag(QSGNode::OwnsMaterial);
        lineNode->setFlag(QSGNode::OwnsGeometry);
        lineNode->setGeometry(new QSGGeometry(QSGGeometry::defaultAttributes_ColoredPoint2D(), 0));
        lineNode->geometry()->setDrawingMode(QSGGeometry::DrawLines);
        node->appendChildNode(lineNode);
    }
    auto* lg = lineNode->geometry();
    const int lineVerts = int(pairs.size()) * 2;
    if (lg->vertexCount() != lineVerts) lg->allocate(lineVerts);
    lg->setLineWidth(1.0f);
    auto* lv = lg->vertexDataAsColoredPoint2D();
    for (size_t k = 0; k < pairs.size(); k++) {
        const Pair& pr = pairs[k];
        // premultiplied vertex color (scene graph convention)
        const float la = pr.a * 0.55f;   // 1px GL line ~ 0.5px AA stroke
        const uchar a = uchar(la * 255);
        const uchar lr = uchar(cr * la), lgc = uchar(cg * la), lb = uchar(cb * la);
        lv[k * 2 + 0].set(px[pr.i], py[pr.i], lr, lgc, lb, a);
        lv[k * 2 + 1].set(px[pr.j], py[pr.j], lr, lgc, lb, a);
    }
    lg->markVertexDataDirty();
    lineNode->markDirty(QSGNode::DirtyGeometry);

    return node;
}
