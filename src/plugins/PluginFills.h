#pragma once
#include <QObject>
#include <QVariantList>

// The fills plugins ship — a .qsb of their own, drawn by StyledFill through
// the same uniform block as styled.frag — as Theme sees them. Rebuilt from
// the plugin list whenever it changes; additive, like BarButtons.
class PluginFills : public QObject {
    Q_OBJECT
public:
    explicit PluginFills(QObject* parent = nullptr) : QObject(parent) {}
    Q_PROPERTY(uint generation READ generation NOTIFY changed)
    uint generation() const { return generation_; }
    Q_INVOKABLE QVariantList all() const { return fills_; }
    void setFills(const QVariantList& fills) {
        if (fills == fills_) return;
        fills_ = fills; ++generation_; emit changed();
    }
signals:
    void changed();
private:
    QVariantList fills_;
    uint generation_ = 0;
};
