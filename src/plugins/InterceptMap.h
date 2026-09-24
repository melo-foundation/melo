#pragma once

#include "Occupancy.h"

#include <QObject>
#include <QString>
#include <functional>

class InterceptMap : public QObject {
    Q_OBJECT
public:
    explicit InterceptMap(QObject* parent = nullptr);
    Q_INVOKABLE void setOccupant(const QString& action, const QString& pluginId);
    Q_INVOKABLE QString occupant(const QString& action) const;
    Q_INVOKABLE void clearOccupants();
    // true = plugin handled (caller must not run builtin)
    Q_INVOKABLE bool offer(const QString& action);
    void setPluginInvoker(std::function<bool(const QString& pluginId,
                                             const QString& action)> fn);
private:
    // The catalog and the one-occupant rule; see Occupancy.h. What is left here
    // is what intercepts mean by an occupant — that it gets called, and that it
    // cannot be called from inside its own call.
    Occupancy occupancy_;
    bool offering_ = false;
    std::function<bool(const QString&, const QString&)> pluginInvoker_;
};
