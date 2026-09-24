#include "BackgroundItem.h"
#include "SpectrumSource.h"

#include <QPainter>
#include <QPainterPath>
#include <QQuickWindow>
#include <QDateTime>
#include <QCoreApplication>
#include <cmath>
#include <algorithm>

SpectrumSource* BackgroundItem::s_spectrum = nullptr;
QTimer* BackgroundItem::s_tick = nullptr;
std::vector<BackgroundItem*> BackgroundItem::s_instances;

namespace {
// mulberry32 — SAME fixed seed as ParticlesItem, so every instance
// generates identical layouts
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
// wall clock quantized to the 33ms tick: both instances render IDENTICAL
// frames even when their timers fire a few ms apart
double absT() { return double(QDateTime::currentMSecsSinceEpoch() / 33) * 0.033; }
double wrap01(double v) { v = std::fmod(v, 1.0); return v < 0 ? v + 1 : v; }
// scaling: sizes follow a GENTLE fourth-root area curve and
// element counts follow sqrt(area) — per-background scaleMode picks which
// (classic = both).
constexpr double kRefArea = 1920.0 * 1080.0;
double sizeScaleFor(const QString& mode, double w, double h) {
    if (mode == QLatin1String("count") || mode == QLatin1String("off")) return 1.0;
    return std::pow((w * h) / kRefArea, 0.25);
}
int countFor(const QString& mode, int base, double w, double h) {
    if (mode == QLatin1String("size") || mode == QLatin1String("off")) return base;
    return std::max(1, int(std::lround(base * std::sqrt((w * h) / kRefArea))));
}
// counts scale with area at draw time: seed a 4x pool ONCE and draw a prefix,
// so resizes never re-layout
constexpr int kPoolMult = 4;
} // namespace

BackgroundItem::BackgroundItem(QQuickItem* parent) : QQuickPaintedItem(parent) {
    setAntialiasing(true);
    s_instances.push_back(this);
    if (!s_tick) {
        s_tick = new QTimer(qApp);
        s_tick->setInterval(33);
        QObject::connect(s_tick, &QTimer::timeout, [] {
            for (auto* it : s_instances)
                if (it->wantsTick()) it->update();
        });
    }
}

BackgroundItem::~BackgroundItem() {
    s_instances.erase(std::remove(s_instances.begin(), s_instances.end(), this),
                      s_instances.end());
    syncSharedTick();
}

bool BackgroundItem::wantsTick() const {
    return animated() && isVisible() && !hold_;
}

void BackgroundItem::syncSharedTick() {
    if (!s_tick) return;
    bool any = false;
    for (auto* it : s_instances) any = any || it->wantsTick();
    if (any && !s_tick->isActive()) s_tick->start();
    else if (!any && s_tick->isActive()) s_tick->stop();
}

double BackgroundItem::opt(const char* k, double d) const {
    const auto v = opts_.value(QLatin1String(k));
    return v.isValid() ? v.toDouble() : d;
}
QString BackgroundItem::optS(const char* k, const char* d) const {
    const auto v = opts_.value(QLatin1String(k));
    return v.isValid() && !v.toString().isEmpty() ? v.toString() : QLatin1String(d);
}
bool BackgroundItem::optB(const char* k, bool d) const {
    const auto v = opts_.value(QLatin1String(k));
    return v.isValid() ? v.toBool() : d;
}
QList<QColor> BackgroundItem::optColors(const char* k, const char* dflt) const {
    QList<QColor> out;
    for (const auto& c : optS(k, dflt).split(',')) {
        const QColor col(c.trimmed());
        if (col.isValid()) out.append(col);
    }
    if (out.isEmpty()) out.append(QColor("#4a9eff"));
    return out;
}

bool BackgroundItem::animated() const {
    static const QStringList kAnimated = {
        "waves", "starfield", "vis-bars", "vis-radial", "vis-oscilloscope"};
    return kAnimated.contains(type_);
}

void BackgroundItem::setConfig(const QVariantMap& c) {
    config_ = c;
    type_ = c.value("type").toString();
    if (qEnvironmentVariableIsSet("MELO_BG_DEBUG"))
        qDebug() << "[bg-debug] setConfig type" << type_ << "opts" << c.value("options").toMap();
    opts_ = c.value("options").toMap();
    reseed();
    syncTimer();
    update();          // repaint immediately (also clears when type left)
    emit configChanged();
}

void BackgroundItem::setHold(bool h) {
    if (hold_ == h) return;
    hold_ = h;
    syncTimer();
    if (!h) update();  // one repaint at the final size on release
    emit holdChanged();
}

void BackgroundItem::itemChange(ItemChange change, const ItemChangeData& value) {
    if (change == ItemVisibleHasChanged) {
        syncTimer();
        if (value.boolValue) update();
    }
    QQuickPaintedItem::itemChange(change, value);
}

void BackgroundItem::syncTimer() { syncSharedTick(); }

void BackgroundItem::reseed() {
    Rng rnd(kSeed);
    waves_.clear(); stars_.clear(); bars_.clear();
    if (type_ == "waves") {
        const int n = int(opt("layers", 4));
        for (int i = 0; i < n; i++)
            waves_.push_back({1.5 + i * 0.6 + rnd.next() * 0.5,
                              rnd.next() * M_PI * 2,
                              0.8 + i * 0.3 + rnd.next() * 0.4, i});
    } else if (type_ == "starfield") {
        const int count = int(opt("count", 200)) * kPoolMult;
        const double sr = opt("sizeRange", 2);
        const bool colored = optB("colored", false);
        for (int i = 0; i < count; i++) {
            int r = 255, g = 255, b = 255;
            if (colored) {
                if (rnd.next() > 0.5) { r = 220 + int(rnd.next() * 35); g = 180 + int(rnd.next() * 60); b = 150 + int(rnd.next() * 60); }
                else { r = 160 + int(rnd.next() * 60); g = 190 + int(rnd.next() * 50); b = 220 + int(rnd.next() * 35); }
            }
            stars_.push_back({rnd.next(), rnd.next(), opt("size", 0.5) + rnd.next() * sr,
                              rnd.next() * M_PI * 2, 1.5 + rnd.next() * 3, r, g, b});
        }
    }
}

void BackgroundItem::paint(QPainter* p) {
    const double w = width(), h = height();
    if (w <= 0 || h <= 0) return;
    const QString scaleMode = optS("scaleMode", "classic");
    const double ss = sizeScaleFor(scaleMode, w, h);
    const double T = absT();

    if (type_ == "waves" && !waves_.empty()) {
        const double waveTime = T * opt("speed", 1) * 0.2;
        const double amp = opt("amplitude", 60) * ss;
        const double baseY = h * opt("position", 0.7);
        const auto cols = optColors("colors", "#cc3333,#4a9eff,#4daa5c");
        const int steps = std::max(20, int(w / 30));
        const double dx = w / steps;
        p->setPen(Qt::NoPen);
        for (const auto& L : waves_) {
            QColor c = cols[L.ci % cols.size()];
            c.setAlphaF(0.25);
            const double phase = L.phase + waveTime * L.phaseSpeed;
            QPainterPath path(QPointF(0, h));
            for (int i = 0; i <= steps; i++) {
                const double x = i * dx, t = x / w;
                path.lineTo(x, baseY + std::sin(t * L.freq * M_PI * 2 + phase) * amp
                                     + std::sin(t * L.freq * 0.7 + phase * 1.3) * amp * 0.3);
            }
            path.lineTo(w, h);
            path.closeSubpath();
            p->fillPath(path, c);
        }
    } else if (type_ == "starfield" && !stars_.empty()) {
        const bool twinkle = optB("twinkle", true);
        const double drift = opt("drift", 0.1);
        p->setPen(Qt::NoPen);
        const int nStars = std::min<int>(stars_.size(),
                                         countFor(scaleMode, int(opt("count", 200)), w, h));
        static const bool dbg = qEnvironmentVariableIsSet("MELO_BG_DEBUG");
        if (dbg && (w != dbgW_ || h != dbgH_)) {
            dbgW_ = w; dbgH_ = h;
            qDebug() << "[bg-debug] starfield" << w << "x" << h
                     << "mode" << scaleMode << "ss" << ss << "n" << nStars
                     << "pool" << stars_.size();
        }
        for (int si2 = 0; si2 < nStars; si2++) {
            const auto& s = stars_[si2];
            const double sx = drift > 0 ? wrap01(s.nx + drift * 0.006 * T) : s.nx;
            const double alpha = twinkle
                ? 0.4 + 0.6 * ((std::sin(T * s.rate + s.phase) + 1) * 0.5) : 0.9;
            QColor c(s.r, s.g, s.b);
            c.setAlphaF(alpha);
            p->setBrush(c);
            p->drawEllipse(QPointF(sx * w, s.ny * h), s.size * ss, s.size * ss);
        }
    } else if (type_ == "vis-bars" && s_spectrum) {
        const auto& freq = s_spectrum->binsRaw();
        if (freq.empty()) return;
        const int barCount = std::max(8, std::min(128, int(w / 4)));
        if (int(bars_.size()) != barCount) bars_.assign(barCount, 0.0);
        const int step = std::max(1, int(freq.size()) / barCount);
        const double midY = h / 2;
        const double gap = opt("gap", 2);
        const double barW = std::max(2.0, (w * 0.8 - gap * (barCount - 1)) / barCount);
        const double totalW = barCount * barW + (barCount - 1) * gap;
        const double offX = (w - totalW) / 2;
        const double sens = opt("sensitivity", 1);
        const double hs = opt("hueStart", 0), he = opt("hueEnd", 60);
        p->setPen(Qt::NoPen);
        for (int i = 0; i < barCount; i++) {
            double sum = 0;
            for (int j = 0; j < step; j++) sum += freq[i * step + j];
            const double target = sum / step / 255.0;
            bars_[i] += (target - bars_[i]) * (target > bars_[i] ? 0.6 : 0.15);
            const double val = bars_[i], bh = val * midY * 0.9 * sens;
            if (bh < 1) continue;
            const double x = offX + i * (barW + gap);
            double hue = std::fmod(hs + (double(i) / barCount) * (he - hs), 360.0);
            if (hue < 0) hue += 360;
            p->setBrush(QColor::fromHslF(hue / 360.0,
                                         std::min(1.0, 0.7 + val * 0.3),
                                         std::min(1.0, 0.35 + val * 0.25)));
            p->drawRect(QRectF(x, midY - bh, barW, bh * 2));
        }
    } else if (type_ == "vis-radial" && s_spectrum) {
        const auto& freq = s_spectrum->binsRaw();
        if (freq.empty()) return;
        const int barCount = std::max(8, std::min(128, int(std::min(w, h) / 6)));
        if (int(bars_.size()) != barCount) bars_.assign(barCount, 0.0);
        const int step = std::max(1, int(freq.size()) / barCount);
        const double cx = w / 2, cy = h / 2, minDim = std::min(w, h);
        const double radius = minDim * opt("radius", 0.18);
        const double maxBar = minDim * opt("barLength", 0.3);
        const double sens = opt("sensitivity", 1);
        const bool rainbow = optB("rainbow", false);
        QPen pen;
        pen.setWidthF(opt("lineWidth", 2));
        pen.setCapStyle(Qt::RoundCap);
        for (int i = 0; i < barCount; i++) {
            double sum = 0;
            for (int j = 0; j < step; j++) sum += freq[i * step + j];
            const double target = sum / step / 255.0;
            bars_[i] += (target - bars_[i]) * (target > bars_[i] ? 0.5 : 0.12);
            const double val = bars_[i], bh = val * maxBar * sens;
            if (bh < 1) continue;
            const double ang = (M_PI * 2 / barCount) * i - M_PI / 2;
            double hue = rainbow ? (double(i) / barCount) * 360 : 200 + val * 120;
            hue = std::fmod(hue, 360.0); if (hue < 0) hue += 360;
            pen.setColor(QColor::fromHslF(hue / 360.0, 0.8, std::min(1.0, 0.4 + val * 0.3)));
            p->setPen(pen);
            p->drawLine(QPointF(cx + radius * std::cos(ang), cy + radius * std::sin(ang)),
                        QPointF(cx + (radius + bh) * std::cos(ang), cy + (radius + bh) * std::sin(ang)));
        }
    } else if (type_ == "vis-oscilloscope" && s_spectrum) {
        const auto& wave = s_spectrum->waveRaw();
        if (wave.empty()) return;
        QPen pen(QColor(optS("color", "#4a9eff")));
        pen.setWidthF(opt("lineWidth", 2));
        pen.setJoinStyle(Qt::RoundJoin);
        p->setPen(pen);
        const double sliceW = w / double(wave.size());
        QPolygonF poly;
        poly.reserve(int(wave.size()));
        for (int i = 0; i < int(wave.size()); i++)
            poly << QPointF(i * sliceW, h / 2 + wave[i] * h / 2 * 0.9);
        p->drawPolyline(poly);
    }
}
