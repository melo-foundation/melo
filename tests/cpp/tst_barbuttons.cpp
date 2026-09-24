// What melo puts in its bars beside its own controls. A list, not an Occupancy:
// several plugins may contribute, nothing is displaced, there is no cap, and
// the user can hide any of them.
#include <QtTest>
#include "BarButtons.h"

class TstBarButtons : public QObject {
    Q_OBJECT
    static QVariantMap btn(const QString& plugin, const QString& id,
                           const QString& bar, const QString& label) {
        return {{QStringLiteral("pluginId"), plugin}, {QStringLiteral("id"), id},
                {QStringLiteral("bar"), bar},        {QStringLiteral("label"), label},
                {QStringLiteral("command"), QStringLiteral("cmd")},
                {QStringLiteral("icon"), QStringLiteral("/plugins/") + plugin + "/i.png"}};
    }
    static QVariantList three() {
        return {btn(QStringLiteral("winamp"), QStringLiteral("group"),
                    QStringLiteral("player"), QStringLiteral("Winamp")),
                btn(QStringLiteral("winamp"), QStringLiteral("eq"),
                    QStringLiteral("player"), QStringLiteral("EQ")),
                btn(QStringLiteral("other"), QStringLiteral("pin"),
                    QStringLiteral("title"), QStringLiteral("Pin"))};
    }
private slots:
    void emptyUntilAPluginOffersOne() {
        BarButtons b;
        QCOMPARE(b.forBar(QStringLiteral("player")).size(), 0);
        QCOMPARE(b.all().size(), 0);
    }
    void eachBarGetsItsOwn() {
        BarButtons b;
        b.setButtons(three());
        QCOMPARE(b.forBar(QStringLiteral("player")).size(), 2);
        QCOMPARE(b.forBar(QStringLiteral("title")).size(), 1);
        QCOMPARE(b.forBar(QStringLiteral("sidebar")).size(), 0);
    }
    // DECLARATION ORDER, so a plugin's buttons keep the order its manifest gave
    // them and the bar does not reshuffle when an unrelated plugin is enabled.
    void declarationOrderIsKept() {
        BarButtons b;
        b.setButtons(three());
        const QVariantList player = b.forBar(QStringLiteral("player"));
        QCOMPARE(player.at(0).toMap().value(QStringLiteral("id")).toString(),
                 QStringLiteral("group"));
        QCOMPARE(player.at(1).toMap().value(QStringLiteral("id")).toString(),
                 QStringLiteral("eq"));
    }
    // NO CAP: every button offered is shown.
    void asManyAsAreOffered() {
        BarButtons b;
        QVariantList many;
        for (int i = 0; i < 20; ++i)
            many << btn(QStringLiteral("winamp"), QStringLiteral("b%1").arg(i),
                        QStringLiteral("player"), QStringLiteral("B"));
        b.setButtons(many);
        QCOMPARE(b.forBar(QStringLiteral("player")).size(), 20);
    }
    // Hidden leaves the bar and stays in the list the user hides things from,
    // or there would be no way to put it back.
    void hidingTakesItOutOfTheBarAndNotTheList() {
        BarButtons b;
        b.setButtons(three());
        b.setHidden(QStringLiteral("winamp"), QStringLiteral("eq"), true);
        QCOMPARE(b.forBar(QStringLiteral("player")).size(), 1);
        QCOMPARE(b.all().size(), 3);
        QVERIFY(b.isHidden(QStringLiteral("winamp"), QStringLiteral("eq")));
        QVERIFY(!b.isHidden(QStringLiteral("winamp"), QStringLiteral("group")));
        b.setHidden(QStringLiteral("winamp"), QStringLiteral("eq"), false);
        QCOMPARE(b.forBar(QStringLiteral("player")).size(), 2);
    }
    // Two plugins may use the same button ID. It is unique within a plugin, not
    // across them, so hiding one must not hide the other's.
    void hidingIsPerPlugin() {
        BarButtons b;
        b.setButtons({btn(QStringLiteral("a"), QStringLiteral("x"),
                          QStringLiteral("player"), QStringLiteral("A")),
                      btn(QStringLiteral("b"), QStringLiteral("x"),
                          QStringLiteral("player"), QStringLiteral("B"))});
        b.setHidden(QStringLiteral("a"), QStringLiteral("x"), true);
        const QVariantList left = b.forBar(QStringLiteral("player"));
        QCOMPARE(left.size(), 1);
        QCOMPARE(left.at(0).toMap().value(QStringLiteral("pluginId")).toString(),
                 QStringLiteral("b"));
    }
    // A hide outlives the plugin, like a slot bind: disabling and re-enabling
    // must not quietly put back a button the user took out of the bar.
    void hideSurvivesTheButtonGoingAway() {
        BarButtons b;
        b.setButtons(three());
        b.setHidden(QStringLiteral("winamp"), QStringLiteral("eq"), true);
        b.setButtons({});
        QCOMPARE(b.forBar(QStringLiteral("player")).size(), 0);
        b.setButtons(three());
        QCOMPARE(b.forBar(QStringLiteral("player")).size(), 1);
    }
    void changedFiresForBothHalves() {
        BarButtons b;
        QSignalSpy spy(&b, &BarButtons::changed);
        b.setButtons(three());
        QCOMPARE(spy.count(), 1);
        b.setHidden(QStringLiteral("winamp"), QStringLiteral("eq"), true);
        QCOMPARE(spy.count(), 2);
        b.setHidden(QStringLiteral("winamp"), QStringLiteral("eq"), true);  // no change
        QCOMPARE(spy.count(), 2);
    }
    // The hidden set round-trips as one value, so the shell can put it in the
    // Qt-owned ui bag beside `slots` and `gestures`.
    void hiddenSetRoundTrips() {
        BarButtons b;
        b.setButtons(three());
        b.setHidden(QStringLiteral("winamp"), QStringLiteral("eq"), true);
        const QStringList saved = b.hiddenKeys();
        BarButtons c;
        c.setButtons(three());
        c.setHiddenKeys(saved);
        QCOMPARE(c.forBar(QStringLiteral("player")).size(), 1);
        QVERIFY(c.isHidden(QStringLiteral("winamp"), QStringLiteral("eq")));
    }
};

QTEST_APPLESS_MAIN(TstBarButtons)
#include "tst_barbuttons.moc"
