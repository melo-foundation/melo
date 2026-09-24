#include "SlotMap.h"

#include <QSet>

namespace {
// Twin of SLOT_IDS in sidecar/src/plugins/ui-manifest.ts; keep both identical
// by hand, as with INTERCEPT_ACTIONS and permissions.ts, because two processes
// must agree on the catalog. An id added only here is a manifest melo accepts
// and the sidecar rejects.
const QSet<QString> kSlots = {
    QStringLiteral("playerBar"),  QStringLiteral("titleBar"),
    QStringLiteral("searchBar"),  QStringLiteral("tabBar"),
    QStringLiteral("queuePanel"), QStringLiteral("home"),
    QStringLiteral("library"),    QStringLiteral("search"),
    QStringLiteral("visualizer"), QStringLiteral("background"),
    QStringLiteral("eq"),
};
}

SlotMap::SlotMap(QObject* parent) : QObject(parent), occupancy_(kSlots) {}

// Unsigned for the reason MeloUiArchive's counter is: a plugin can drive this
// by rebinding in a loop, and unsigned wrap is defined.
void SlotMap::bump() { ++generation_; emit changed(); }

QStringList SlotMap::slotIds() const {
    QStringList ids(kSlots.cbegin(), kSlots.cend());
    ids.sort();
    return ids;
}

QString SlotMap::occupant(const QString& slot) const { return occupancy_.occupant(slot); }

void SlotMap::setOccupant(const QString& slot, const QString& pluginId) {
    if (!occupancy_.knows(slot)) return;                 // not a place; say nothing
    if (occupancy_.occupant(slot) == pluginId) return;   // a bind that changes nothing
    occupancy_.set(slot, pluginId);
    bump();
}

void SlotMap::clearOccupants() {
    occupancy_.clear();
    bump();
}

bool SlotMap::isHidden(const QString& slot) const {
    return occupancy_.occupant(slot) == hiddenId();
}

QString SlotMap::qmlFor(const QString& slot) const {
    const QString id = occupancy_.occupant(slot);
    if (id.isEmpty() || id == hiddenId()) return {};
    return offers_.value(id).value(slot);
}

QStringList SlotMap::offersFor(const QString& slot) const {
    if (!occupancy_.knows(slot)) return {};
    QStringList out;
    for (auto it = offers_.cbegin(); it != offers_.cend(); ++it)
        if (it.value().contains(slot)) out << it.key();
    out.sort();
    return out;
}

void SlotMap::setOffers(const QHash<QString, QHash<QString, QString>>& byPlugin) {
    offers_ = byPlugin;
    // The binds are deliberately untouched — see the header. A plugin that just
    // went away keeps its slot, draws nothing meanwhile, and gets it back.
    bump();
}
