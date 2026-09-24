#pragma once
#include "MeloEngineOnly.h"
#include <QQuickItem>
#include <QVariantMap>
#include <vector>

// GPU geometry for the "particles" background: QPainter would rasterize the
// lines into a full-window texture and re-upload it every tick. Same seed and
// clock as BackgroundItem, so the full and mini instances match.
class ParticlesItem : public QQuickItem {
    Q_OBJECT
public:
    // Melo's own QML only — see MeloEngineOnly.h. `import Melo 1.0` resolves in
    // a plugin's engine because the type registry is process-global, so the
    // type has to refuse itself rather than rely on an import path that cannot
    // gate it.
    void componentComplete() override {
        QQuickItem::componentComplete();
        meloEngineOwns(this, "ParticlesItem");
    }
    Q_PROPERTY(QVariantMap config READ config WRITE setConfig NOTIFY configChanged)
    Q_PROPERTY(bool hold READ hold WRITE setHold NOTIFY holdChanged)
public:
    explicit ParticlesItem(QQuickItem* parent = nullptr);
    // Leaves s_instances: the shared 33ms tick walks it and would dereference
    // a destroyed item.
    ~ParticlesItem() override;

    QVariantMap config() const { return config_; }
    void setConfig(const QVariantMap& c);
    bool hold() const { return hold_; }
    void setHold(bool h);
    bool wantsTick() const { return active_ && isVisible() && !hold_; }

signals:
    void configChanged();
    void holdChanged();

protected:
    QSGNode* updatePaintNode(QSGNode* old, UpdatePaintNodeData*) override;
    void itemChange(ItemChange change, const ItemChangeData& value) override;

private:
    void reseed();
    void syncTick();

    struct P { double nx, ny, vx, vy; };
    QVariantMap config_;
    QVariantMap opts_;
    bool active_ = false;   // type == "particles"
    bool hold_ = false;
    std::vector<P> particles_;
};
