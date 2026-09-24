// Occupancy: one occupant per named thing, later grant wins, empty means
// builtin, an id outside the catalog is not a thing. Shared by InterceptMap and
// the slot map so the two cannot drift. It does not dispatch; the re-entrancy
// guard stays in InterceptMap's offer(), where a plugin can call back into the
// host.
#include <QtTest>
#include "Occupancy.h"

class TstOccupancy : public QObject {
    Q_OBJECT
    static Occupancy actions() {
        return Occupancy({QStringLiteral("play"), QStringLiteral("pause"),
                          QStringLiteral("toggleCompact")});
    }
private slots:
    void unoccupiedIsEmpty() {
        Occupancy o = actions();
        QCOMPARE(o.occupant(QStringLiteral("play")), QString());
    }
    void laterWins() {
        Occupancy o = actions();
        o.set(QStringLiteral("play"), QStringLiteral("alpha"));
        o.set(QStringLiteral("play"), QStringLiteral("beta"));
        QCOMPARE(o.occupant(QStringLiteral("play")), QStringLiteral("beta"));
        QCOMPARE(o.occupant(QStringLiteral("pause")), QString());
    }
    void outsideTheCatalogIsNotAThing() {
        Occupancy o = actions();
        QVERIFY(!o.knows(QStringLiteral("queue.add")));
        o.set(QStringLiteral("queue.add"), QStringLiteral("x"));
        QCOMPARE(o.occupant(QStringLiteral("queue.add")), QString());
    }
    void clearRestoresEveryBuiltin() {
        Occupancy o = actions();
        o.set(QStringLiteral("play"), QStringLiteral("x"));
        o.set(QStringLiteral("toggleCompact"), QStringLiteral("y"));
        o.clear();
        QCOMPARE(o.occupant(QStringLiteral("play")), QString());
        QCOMPARE(o.occupant(QStringLiteral("toggleCompact")), QString());
    }
    // A slot can be put back to builtin, which is a set and not a clear —
    // clear() would drop every other slot's binding with it. Intercepts never
    // ask for this (InterceptMap keeps its own guard against an empty plugin
    // id), so it is specified here rather than discovered later.
    void settingNothingVacates() {
        Occupancy o = actions();
        o.set(QStringLiteral("play"), QStringLiteral("x"));
        o.set(QStringLiteral("pause"), QStringLiteral("y"));
        o.set(QStringLiteral("play"), QString());
        QCOMPARE(o.occupant(QStringLiteral("play")), QString());
        QCOMPARE(o.occupant(QStringLiteral("pause")), QStringLiteral("y"));
    }
    void catalogIsClosedAtConstruction() {
        Occupancy o = actions();
        QVERIFY(o.knows(QStringLiteral("toggleCompact")));
        QVERIFY(!o.knows(QStringLiteral("Play")));   // ids are exact, not folded
    }
};

QTEST_APPLESS_MAIN(TstOccupancy)
#include "tst_occupancy.moc"
