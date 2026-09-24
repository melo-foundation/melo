#pragma once
#include <QObject>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QVariantList>

// Buttons plugins add to melo's bars beside melo's own controls. A list, not an
// Occupancy: any number of plugins contribute and none displaces a melo control.
// A button shows as soon as its plugin is enabled with ui granted.
//
// A hide is keyed by plugin and button id (ids are unique only within a plugin)
// and outlives the plugin, so re-enabling it does not restore a hidden button.
class BarButtons : public QObject {
    Q_OBJECT
public:
    explicit BarButtons(QObject* parent = nullptr) : QObject(parent) {}

    // Methods, not properties, so QML needs something that moves when the
    // answers might have. Same reason SlotMap and MeloUiArchive carry one.
    Q_PROPERTY(uint generation READ generation NOTIFY changed)
    uint generation() const { return generation_; }

    // In declaration order, hidden ones left out. Order is kept so a plugin's
    // buttons stay as its manifest wrote them and the bar does not reshuffle
    // when an unrelated plugin is enabled.
    Q_INVOKABLE QVariantList forBar(const QString& bar) const;
    // Every button including the hidden, which is what the hide list shows —
    // otherwise there would be no way to put one back.
    Q_INVOKABLE QVariantList all() const { return buttons_; }

    Q_INVOKABLE bool isHidden(const QString& pluginId, const QString& id) const;
    Q_INVOKABLE void setHidden(const QString& pluginId, const QString& id, bool on);

    // The hidden set as one value, for the Qt-owned `ui` settings bag beside
    // `slots` and `gestures`.
    Q_INVOKABLE QStringList hiddenKeys() const;
    Q_INVOKABLE void setHiddenKeys(const QStringList& keys);

    // Replaced wholesale on every plugin-list change, as the offers in SlotMap
    // are: the shell receives the whole list each time, so a delta here would be
    // a second thing to keep in step.
    void setButtons(const QVariantList& buttons);

signals:
    void changed();

private:
    static QString keyOf(const QString& pluginId, const QString& id);
    void bump() { ++generation_; emit changed(); }
    QVariantList buttons_;
    QSet<QString> hidden_;
    uint generation_ = 0;
};
