#include <QtTest>
#include <QQuickItem>
#include <QQuickWindow>
#include "FrameHold.h"

// A held window swaps no frame however often it asks, and swaps one on release.
// The mini bar's resize holds the main window this way (Main.qml).
class TestFrameHold : public QObject {
    Q_OBJECT

    struct Rig {
        QQuickWindow win;
        int swaps = 0;
        Rig() {
            win.resize(200, 100);
            connect(&win, &QQuickWindow::frameSwapped, &win, [this] { ++swaps; },
                    Qt::DirectConnection);
            win.show();
        }
        bool drawn() { return QTest::qWaitFor([this] { return swaps > 0; }, 3000); }
    };

private slots:
    void initTestCase() {
        Rig r;
        if (!r.drawn()) QSKIP("no frames on this platform");
    }

    void heldWindowSwapsNothing() {
        Rig r;
        QVERIFY(r.drawn());
        FrameHold hold;
        hold.hold(&r.win, true);
        QVERIFY(hold.isHeld(&r.win));
        const int before = r.swaps;
        for (int i = 0; i < 10; ++i) {
            r.win.contentItem()->setOpacity(i % 2 ? 1.0 : 0.5);   // a dirty scene
            r.win.update();
            QTest::qWait(20);
        }
        QCOMPARE(r.swaps, before);
    }

    void releaseSwapsTheRefusedFrame() {
        Rig r;
        QVERIFY(r.drawn());
        FrameHold hold;
        hold.hold(&r.win, true);
        r.win.contentItem()->setOpacity(0.5);
        QTest::qWait(100);
        const int before = r.swaps;
        hold.hold(&r.win, false);
        QVERIFY(!hold.isHeld(&r.win));
        QVERIFY(QTest::qWaitFor([&] { return r.swaps > before; }, 2000));
    }

    void otherWindowsRenderOn() {
        Rig held, free;
        QVERIFY(held.drawn() && free.drawn());
        FrameHold hold;
        hold.hold(&held.win, true);
        const int before = free.swaps;
        free.win.update();
        QVERIFY(QTest::qWaitFor([&] { return free.swaps > before; }, 2000));
    }

    void destroyedWhileHeld() {
        FrameHold hold;
        auto* w = new QQuickWindow;
        hold.hold(w, true);
        delete w;
        QVERIFY(!hold.isHeld(w));
    }
};

QTEST_MAIN(TestFrameHold)
#include "tst_framehold.moc"
