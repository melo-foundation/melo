#include <QtTest>
#include "InterceptMap.h"

class TstInterceptMap : public QObject {
    Q_OBJECT
private slots:
    void defaultOccupantIsBuiltin() {
        InterceptMap m;
        QCOMPARE(m.occupant(QStringLiteral("play")), QString());
        QVERIFY(!m.offer(QStringLiteral("play")));
    }
    void laterGrantWins() {
        InterceptMap m;
        m.setOccupant(QStringLiteral("play"), QStringLiteral("alpha"));
        m.setOccupant(QStringLiteral("play"), QStringLiteral("beta"));
        QCOMPARE(m.occupant(QStringLiteral("play")), QStringLiteral("beta"));
        QCOMPARE(m.occupant(QStringLiteral("pause")), QString());
    }
    void offerInvokesOccupant() {
        InterceptMap m;
        m.setOccupant(QStringLiteral("play"), QStringLiteral("hello-intercept"));
        QString plug, act;
        m.setPluginInvoker([&](const QString& p, const QString& a) {
            plug = p; act = a; return true;
        });
        QVERIFY(m.offer(QStringLiteral("play")));
        QCOMPARE(plug, QStringLiteral("hello-intercept"));
        QCOMPARE(act, QStringLiteral("play"));
    }
    void offerFailOpenWhenInvokerFalse() {
        InterceptMap m;
        m.setOccupant(QStringLiteral("next"), QStringLiteral("hello-intercept"));
        m.setPluginInvoker([](const QString&, const QString&) { return false; });
        QVERIFY(!m.offer(QStringLiteral("next")));
    }
    void unknownActionIsNoop() {
        InterceptMap m;
        m.setOccupant(QStringLiteral("queue.add"), QStringLiteral("x"));
        QCOMPARE(m.occupant(QStringLiteral("queue.add")), QString());
        QVERIFY(!m.offer(QStringLiteral("queue.add")));
    }
    void catalogIncludesToggleCompact() {
        InterceptMap m;
        m.setOccupant(QStringLiteral("toggleCompact"), QStringLiteral("x"));
        QCOMPARE(m.occupant(QStringLiteral("toggleCompact")), QStringLiteral("x"));
    }
    // Melo's own chrome is takeable too. Every button in the player bar and
    // title bar is a command, and each of those commands offers here before it
    // acts — so a granted plugin answers the EQ button instead of melo.
    void catalogIncludesTheChromeActions() {
        InterceptMap m;
        for (const QString& a : {QStringLiteral("toggleQueue"),
                                 QStringLiteral("toggleEq"),
                                 QStringLiteral("toggleVisualizer"),
                                 QStringLiteral("toggleSearch"),
                                 QStringLiteral("openSettings"),
                                 QStringLiteral("togglePin")}) {
            m.setOccupant(a, QStringLiteral("x"));
            QCOMPARE(m.occupant(a), QStringLiteral("x"));
        }
    }
    void nestedOfferReturnsFalse() {
        InterceptMap m;
        m.setOccupant(QStringLiteral("play"), QStringLiteral("x"));
        bool nested = true;
        m.setPluginInvoker([&](const QString&, const QString&) {
            nested = m.offer(QStringLiteral("play"));
            return true;
        });
        QVERIFY(m.offer(QStringLiteral("play")));
        QVERIFY(!nested);
    }
    void clearOccupantsRestoresBuiltin() {
        InterceptMap m;
        m.setOccupant(QStringLiteral("play"), QStringLiteral("x"));
        m.clearOccupants();
        QCOMPARE(m.occupant(QStringLiteral("play")), QString());
    }
};

QTEST_APPLESS_MAIN(TstInterceptMap)
#include "tst_interceptmap.moc"
