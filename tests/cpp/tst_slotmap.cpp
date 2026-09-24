// Which QML draws each of melo's named places. SlotMap is Occupancy plus a
// plugin's offers (manifest ui.slots) and three bind answers the shell must
// tell apart: `""` (melo's chrome), `hidden` (nothing) or a plugin id.
#include <QtTest>
#include "SlotMap.h"

class TstSlotMap : public QObject {
    Q_OBJECT
    static QHash<QString, QHash<QString, QString>> offers() {
        return {{QStringLiteral("winamp"),
                 {{QStringLiteral("eq"), QStringLiteral("ui/EqPanel.qml")}}},
                {QStringLiteral("other"),
                 {{QStringLiteral("eq"), QStringLiteral("ui/Other.qml")},
                  {QStringLiteral("visualizer"), QStringLiteral("ui/Vis.qml")}}}};
    }
private slots:
    void catalogIsTheShellsPlaces() {
        SlotMap m;
        const QStringList ids = m.slotIds();
        QVERIFY(ids.contains(QStringLiteral("eq")));
        QVERIFY(ids.contains(QStringLiteral("playerBar")));
        QVERIFY(ids.contains(QStringLiteral("background")));
        QVERIFY(!ids.contains(QStringLiteral("eqq")));
        // Sorted-and-stable, because a picker built from it must not reshuffle
        // its rows every time the plugin list changes.
        QStringList sorted = ids;
        sorted.sort();
        QCOMPARE(ids, sorted);
    }
    void unboundIsMelosOwn() {
        SlotMap m;
        QCOMPARE(m.occupant(QStringLiteral("eq")), QString());
        QCOMPARE(m.qmlFor(QStringLiteral("eq")), QString());
    }
    void bindingAPluginGivesItsQml() {
        SlotMap m;
        m.setOffers(offers());
        m.setOccupant(QStringLiteral("eq"), QStringLiteral("winamp"));
        QCOMPARE(m.occupant(QStringLiteral("eq")), QStringLiteral("winamp"));
        QCOMPARE(m.qmlFor(QStringLiteral("eq")), QStringLiteral("ui/EqPanel.qml"));
    }
    void laterBindWins() {
        SlotMap m;
        m.setOffers(offers());
        m.setOccupant(QStringLiteral("eq"), QStringLiteral("winamp"));
        m.setOccupant(QStringLiteral("eq"), QStringLiteral("other"));
        QCOMPARE(m.qmlFor(QStringLiteral("eq")), QStringLiteral("ui/Other.qml"));
    }
    // Builtin is a bind, not a clear. Putting one slot back to melo's chrome
    // must not drop what the user chose for every other slot.
    void bindingBuiltinLeavesTheOthers() {
        SlotMap m;
        m.setOffers(offers());
        m.setOccupant(QStringLiteral("eq"), QStringLiteral("winamp"));
        m.setOccupant(QStringLiteral("visualizer"), QStringLiteral("other"));
        m.setOccupant(QStringLiteral("eq"), QString());
        QCOMPARE(m.occupant(QStringLiteral("eq")), QString());
        QCOMPARE(m.occupant(QStringLiteral("visualizer")), QStringLiteral("other"));
    }
    // Hidden is not builtin. Both draw no plugin; only one draws melo.
    void hiddenIsItsOwnAnswer() {
        SlotMap m;
        m.setOffers(offers());
        m.setOccupant(QStringLiteral("eq"), SlotMap::hiddenId());
        QCOMPARE(m.occupant(QStringLiteral("eq")), SlotMap::hiddenId());
        QCOMPARE(m.qmlFor(QStringLiteral("eq")), QString());
        QVERIFY(m.isHidden(QStringLiteral("eq")));
        QVERIFY(!m.isHidden(QStringLiteral("visualizer")));
    }
    // A bind outlives the plugin being available. Disabling a plugin must not
    // silently forget which slot the user gave it — melo draws its own chrome
    // meanwhile and the choice comes back when the plugin does.
    void bindSurvivesAnOfferGoingAway() {
        SlotMap m;
        m.setOffers(offers());
        m.setOccupant(QStringLiteral("eq"), QStringLiteral("winamp"));
        m.setOffers({});                                  // plugin disabled
        QCOMPARE(m.occupant(QStringLiteral("eq")), QStringLiteral("winamp"));
        QCOMPARE(m.qmlFor(QStringLiteral("eq")), QString());
        m.setOffers(offers());                            // and back
        QCOMPARE(m.qmlFor(QStringLiteral("eq")), QStringLiteral("ui/EqPanel.qml"));
    }
    void aPluginThatDoesNotOfferThisSlotDrawsNothing() {
        SlotMap m;
        m.setOffers(offers());
        m.setOccupant(QStringLiteral("visualizer"), QStringLiteral("winamp"));
        QCOMPARE(m.qmlFor(QStringLiteral("visualizer")), QString());
    }
    void outsideTheCatalogIsNotAPlace() {
        SlotMap m;
        m.setOffers(offers());
        m.setOccupant(QStringLiteral("eqq"), QStringLiteral("winamp"));
        QCOMPARE(m.occupant(QStringLiteral("eqq")), QString());
        QCOMPARE(m.qmlFor(QStringLiteral("eqq")), QString());
    }
    // What the picker lists for one slot, and it is the OFFERS, not every
    // plugin — a plugin that never mentioned this place is not a choice for it.
    void offersForOneSlot() {
        SlotMap m;
        m.setOffers(offers());
        QStringList eq = m.offersFor(QStringLiteral("eq"));
        eq.sort();
        QCOMPARE(eq, (QStringList{QStringLiteral("other"), QStringLiteral("winamp")}));
        QCOMPARE(m.offersFor(QStringLiteral("visualizer")),
                 (QStringList{QStringLiteral("other")}));
        QCOMPARE(m.offersFor(QStringLiteral("playerBar")), QStringList());
    }
    void changedFiresOnBindAndOnOffers() {
        SlotMap m;
        QSignalSpy spy(&m, &SlotMap::changed);
        m.setOffers(offers());
        QCOMPARE(spy.count(), 1);
        m.setOccupant(QStringLiteral("eq"), QStringLiteral("winamp"));
        QCOMPARE(spy.count(), 2);
        // A bind that changes nothing is not a change.
        m.setOccupant(QStringLiteral("eq"), QStringLiteral("winamp"));
        QCOMPARE(spy.count(), 2);
        // Neither is one the catalog does not have.
        m.setOccupant(QStringLiteral("eqq"), QStringLiteral("winamp"));
        QCOMPARE(spy.count(), 2);
    }
};

QTEST_APPLESS_MAIN(TstSlotMap)
#include "tst_slotmap.moc"
