#pragma once
#include "MeloEngineOnly.h"
#include <QQuickPaintedItem>
#include <QVariantMap>
#include <QTimer>
#include <QColor>
#include <vector>

class SpectrumSource;

// Procedural theme backgrounds (waves, starfield, vis-*). QQuickPaintedItem,
// not Canvas: Canvas can run paints that never display until a node rebuild,
// so the full-window and mini-bar instances freeze on different frames.
// Layouts seed from a fixed mulberry32 stream and animation is a function of the
// wall clock quantized to 33ms, so both instances draw identical frames.
class BackgroundItem : public QQuickPaintedItem {
    Q_OBJECT
public:
    // Melo's own QML only — see MeloEngineOnly.h. `import Melo 1.0` resolves in
    // a plugin's engine because the type registry is process-global, so the
    // type has to refuse itself rather than rely on an import path that cannot
    // gate it.
    void componentComplete() override {
        QQuickPaintedItem::componentComplete();
        meloEngineOwns(this, "BackgroundItem");
    }
    Q_PROPERTY(QVariantMap config READ config WRITE setConfig NOTIFY configChanged)
    Q_PROPERTY(bool hold READ hold WRITE setHold NOTIFY holdChanged)
public:
    explicit BackgroundItem(QQuickItem* parent = nullptr);
    ~BackgroundItem() override;

    QVariantMap config() const { return config_; }
    void setConfig(const QVariantMap& c);
    bool hold() const { return hold_; }
    void setHold(bool h);

    static void setSpectrum(SpectrumSource* s) { s_spectrum = s; }

    void paint(QPainter* p) override;

signals:
    void configChanged();
    void holdChanged();

protected:
    void itemChange(ItemChange change, const ItemChangeData& value) override;

private:
    void reseed();
    void syncTimer();
    bool animated() const;
    // per-type option helpers
    double opt(const char* k, double d) const;
    QString optS(const char* k, const char* d) const;
    bool optB(const char* k, bool d) const;
    QList<QColor> optColors(const char* k, const char* dflt) const;

    QVariantMap config_;
    QVariantMap opts_;
    QString type_;
    bool hold_ = false;
    double dbgW_ = -1, dbgH_ = -1;
    bool wantsTick() const;

    static SpectrumSource* s_spectrum;
    // ONE shared ticker drives every instance in the same event-loop turn:
    // per-instance timers run at independent phases, so the two windows would
    // submit frames from different 33ms buckets and the full and mini
    // backgrounds drift apart.
    static QTimer* s_tick;
    static std::vector<BackgroundItem*> s_instances;
    static void syncSharedTick();

    // seeded layouts (normalized coordinates)
    struct WaveLayer { double freq, phase, phaseSpeed; int ci; };
    struct Star { double nx, ny, size, phase, rate; int r, g, b; };
    std::vector<WaveLayer> waves_;
    std::vector<Star> stars_;
    std::vector<double> bars_;   // vis smoothing state (converges in ~0.5s)
};
