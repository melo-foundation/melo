#pragma once
#include <QHash>
#include <QSet>
#include <QString>
#include <utility>

// At most one occupant per id of a closed catalog; a later grant wins; empty
// means melo's own. Setting an unknown id is a no-op, because ids come from plugin
// manifests and a typo must not invent a place in the shell.
//
// Shared by the intercept actions and the slot map. Does not dispatch: each
// QObject wrapper declares the plugin-reachable surface and decides what an
// occupant means (InterceptMap invokes it behind a re-entrancy guard).
class Occupancy {
public:
    explicit Occupancy(QSet<QString> catalog) : catalog_(std::move(catalog)) {}

    // Exact ids, never folded: `Play` is not `play`. The catalog is a twin of a
    // list on the TypeScript side, and a fold here would accept manifests the
    // validator rejects.
    bool knows(const QString& id) const { return catalog_.contains(id); }

    // An empty occupant VACATES this id and leaves every other one alone. That
    // is the difference between putting one slot back to melo's own chrome and
    // clear(), which drops the lot.
    void set(const QString& id, const QString& occupant);

    QString occupant(const QString& id) const { return occupant_.value(id); }
    void clear() { occupant_.clear(); }

private:
    const QSet<QString> catalog_;
    QHash<QString, QString> occupant_;
};
