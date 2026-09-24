#pragma once
#include "Occupancy.h"

#include <QHash>
#include <QObject>
#include <QString>
#include <QStringList>

// Which QML draws each of melo's named places. A plugin only offers to fill a
// slot; the user picks one occupant per slot, as in Occupancy.
//
//   ""        melo's own chrome; what an unbound slot means.
//   "hidden"  nothing at all, which the shell must tell apart from "".
//   <plugin>  that plugin's QML for this slot, if it still offers one.
//
// Offers and binds are separate maps because a bind outlives the offer:
// disabling a plugin empties qmlFor(), and re-enabling restores the choice.
class SlotMap : public QObject {
    Q_OBJECT
public:
    explicit SlotMap(QObject* parent = nullptr);

    // occupant() and qmlFor() are methods, so a binding that calls one has
    // nothing to re-evaluate on. generation moves whenever their answers might
    // have, as MeloUiArchive's `generation` does; a binding that mentions it
    // re-runs.
    Q_PROPERTY(uint generation READ generation NOTIFY changed)
    uint generation() const { return generation_; }

    // The sentinel, as a property so QML never has to spell it.
    Q_PROPERTY(QString hiddenId READ hiddenId CONSTANT)

    // The sentinel for "draw nothing here". A plugin id can never collide with
    // it: captionSafe ids cannot contain a colon.
    static QString hiddenId() { return QStringLiteral("melo:hidden"); }

    // The catalog, sorted, so a picker built from it keeps its row order when
    // the plugin list changes underneath.
    Q_INVOKABLE QStringList slotIds() const;

    Q_INVOKABLE QString occupant(const QString& slot) const;
    // "" puts the slot back to melo's chrome and leaves every other slot alone;
    // clearing them all is clearOccupants(). See Occupancy::set.
    Q_INVOKABLE void setOccupant(const QString& slot, const QString& pluginId);
    Q_INVOKABLE void clearOccupants();

    Q_INVOKABLE bool isHidden(const QString& slot) const;
    // The occupant's QML for this slot, or empty for builtin, hidden, a plugin
    // that is not offering, and a slot outside the catalog.
    Q_INVOKABLE QString qmlFor(const QString& slot) const;
    // The plugin ids offering this slot — what the picker lists beside melo's
    // own. A plugin that never mentioned this place is not a choice for it.
    Q_INVOKABLE QStringList offersFor(const QString& slot) const;

    // Replaced wholesale: the shell receives the whole plugin list on every
    // change, so a delta here would be a second thing to keep in step.
    void setOffers(const QHash<QString, QHash<QString, QString>>& byPlugin);

signals:
    void changed();

private:
    void bump();                                       // generation + changed()
    Occupancy occupancy_;
    QHash<QString, QHash<QString, QString>> offers_;   // plugin id -> slot -> qml
    uint generation_ = 0;
};
