#include "InterceptMap.h"
#include <QSet>

namespace {
// Twin of sidecar/src/plugins/permissions.ts INTERCEPT_ACTIONS. Keep both lists
// identical; do not DRY at runtime.
const QSet<QString> kActions = {
    QStringLiteral("play"),
    QStringLiteral("pause"),
    QStringLiteral("stop"),
    QStringLiteral("next"),
    QStringLiteral("prev"),
    QStringLiteral("toggleCompact"),
    // melo's own chrome. Each is a command, and each command offers before it
    // acts — see the switch in Main.qml.
    QStringLiteral("toggleQueue"),
    QStringLiteral("toggleEq"),
    QStringLiteral("toggleVisualizer"),
    QStringLiteral("toggleSearch"),
    QStringLiteral("openSettings"),
    QStringLiteral("togglePin"),
};
}

InterceptMap::InterceptMap(QObject* parent) : QObject(parent), occupancy_(kActions) {}

void InterceptMap::setOccupant(const QString& action, const QString& pluginId) {
    // An empty plugin id is ignored. Occupancy::set treats empty as "put this
    // id back to builtin", which a slot picker needs; no intercept caller
    // means that, and a blank must not become a way to un-grant.
    if (pluginId.isEmpty()) return;
    occupancy_.set(action, pluginId);
}

QString InterceptMap::occupant(const QString& action) const {
    return occupancy_.occupant(action);
}

void InterceptMap::clearOccupants() { occupancy_.clear(); }

bool InterceptMap::offer(const QString& action) {
    if (offering_) return false;
    if (!occupancy_.knows(action)) return false;
    const QString id = occupancy_.occupant(action);
    if (id.isEmpty() || !pluginInvoker_) return false;
    offering_ = true;
    const bool ok = pluginInvoker_(id, action);
    offering_ = false;
    return ok;
}

void InterceptMap::setPluginInvoker(std::function<bool(const QString&, const QString&)> fn) {
    pluginInvoker_ = std::move(fn);
}
