#include <QtTest>
#include <QGuiApplication>
#include <QMouseEvent>
#include <QWindow>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include "UiActivity.h"

// Any input anywhere in the app is activity; silence for idleAfterMs is idle.
class TstUiActivity : public QObject {
    Q_OBJECT
private slots:
    void idleAfterSilenceAndAwakeOnInput() {
        UiActivity a;
        a.setIdleAfterMs(150);
        QCOMPARE(a.idle(), false);
        QTRY_COMPARE_WITH_TIMEOUT(a.idle(), true, 2000);
        QWindow w; w.resize(10, 10); w.show();
        QSignalSpy spy(&a, &UiActivity::idleChanged);
        QMouseEvent move(QEvent::MouseMove, QPointF(2, 2), QPointF(2, 2), Qt::NoButton, Qt::NoButton, Qt::NoModifier);
        QGuiApplication::sendEvent(&w, &move);
        QCOMPARE(a.idle(), false);
        QCOMPARE(spy.count(), 1);
        QTRY_COMPARE_WITH_TIMEOUT(a.idle(), true, 2000);
        QKeyEvent key(QEvent::KeyPress, Qt::Key_Space, Qt::NoModifier);
        QGuiApplication::sendEvent(&w, &key);
        QCOMPARE(a.idle(), false);
    }
    // Qt Quick re-sends a hover at the resting pointer every 100 ms while
    // anything animates: that, and a move to where the pointer already is,
    // is not input.
    void restingPointerStaysIdle() {
        UiActivity a;
        a.setIdleAfterMs(150);
        QWindow w; w.resize(10, 10); w.show();
        QMouseEvent move(QEvent::MouseMove, QPointF(3, 3), QPointF(3, 3), Qt::NoButton, Qt::NoButton, Qt::NoModifier);
        QGuiApplication::sendEvent(&w, &move);
        QTRY_COMPARE_WITH_TIMEOUT(a.idle(), true, 2000);
        QHoverEvent hover(QEvent::HoverMove, QPointF(3, 3), QPointF(3, 3), QPointF(3, 3));
        QGuiApplication::sendEvent(&w, &hover);
        QCOMPARE(a.idle(), true);
        QMouseEvent same(QEvent::MouseMove, QPointF(3, 3), QPointF(3, 3), Qt::NoButton, Qt::NoButton, Qt::NoModifier);
        QGuiApplication::sendEvent(&w, &same);
        QCOMPARE(a.idle(), true);
        QMouseEvent moved(QEvent::MouseMove, QPointF(4, 3), QPointF(4, 3), Qt::NoButton, Qt::NoButton, Qt::NoModifier);
        QGuiApplication::sendEvent(&w, &moved);
        QCOMPARE(a.idle(), false);
    }
    // Escape reaches a Shortcut as a ShortcutOverride and never as a KeyPress.
    void shortcutKeyWakes() {
        UiActivity a;
        a.setIdleAfterMs(150);
        QTRY_COMPARE_WITH_TIMEOUT(a.idle(), true, 2000);
        QWindow w; w.resize(10, 10); w.show();
        QKeyEvent esc(QEvent::ShortcutOverride, Qt::Key_Escape, Qt::NoModifier);
        QGuiApplication::sendEvent(&w, &esc);
        QCOMPARE(a.idle(), false);
    }
    // inputWoke fires on a key or a button press; a pointer move or a wheel only wakes the clock.
    void inputWokeOnPressAndKeyOnly() {
        UiActivity a;
        QWindow w; w.resize(10, 10); w.show();
        QSignalSpy spy(&a, &UiActivity::inputWoke);
        QMouseEvent move(QEvent::MouseMove, QPointF(5, 5), QPointF(5, 5), Qt::NoButton, Qt::NoButton, Qt::NoModifier);
        QGuiApplication::sendEvent(&w, &move);
        QWheelEvent wheel(QPointF(5, 5), QPointF(5, 5), QPoint(), QPoint(0, 120), Qt::NoButton, Qt::NoModifier, Qt::NoScrollPhase, false);
        QGuiApplication::sendEvent(&w, &wheel);
        QCOMPARE(spy.count(), 0);
        QMouseEvent press(QEvent::MouseButtonPress, QPointF(5, 5), QPointF(5, 5), Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
        QGuiApplication::sendEvent(&w, &press);
        QCOMPARE(spy.count(), 1);
        QKeyEvent key(QEvent::KeyPress, Qt::Key_Space, Qt::NoModifier);
        QGuiApplication::sendEvent(&w, &key);
        QCOMPARE(spy.count(), 2);
        QKeyEvent esc(QEvent::ShortcutOverride, Qt::Key_Escape, Qt::NoModifier);
        QGuiApplication::sendEvent(&w, &esc);
        QCOMPARE(spy.count(), 3);
    }
    // Qt Quick re-sends a press to every item that takes the button: one press is one inputWoke.
    void inputWokeOncePerPressInQuick() {
        UiActivity a;
        QQmlEngine engine;
        QQmlComponent c(&engine);
        c.setData("import QtQuick\n"
                  "Item { anchors.fill: parent; TapHandler {}\n"
                  "  Item { anchors.fill: parent; TapHandler {} } }", QUrl());
        QQuickWindow w; w.resize(40, 40);
        std::unique_ptr<QQuickItem> root(qobject_cast<QQuickItem*>(c.create()));
        QVERIFY2(root, qPrintable(c.errorString()));
        root->setParentItem(w.contentItem());
        w.show();
        QVERIFY(QTest::qWaitForWindowExposed(&w));
        QSignalSpy spy(&a, &UiActivity::inputWoke);
        QTest::mousePress(&w, Qt::LeftButton, Qt::NoModifier, QPoint(20, 20));
        QCOMPARE(spy.count(), 1);
        QTest::mouseRelease(&w, Qt::LeftButton, Qt::NoModifier, QPoint(20, 20));
    }
    // The window's cursor blanks at once and comes back on unhide; a null window is ignored.
    void windowCursorHides() {
        UiActivity a;
        QQuickWindow w; w.resize(20, 20); w.show();
        QVERIFY(QTest::qWaitForWindowExposed(&w));
        a.setWindowCursorHidden(&w, true);
        QCOMPARE(w.cursor().shape(), Qt::BlankCursor);
        a.setWindowCursorHidden(&w, true);
        QCOMPARE(w.cursor().shape(), Qt::BlankCursor);
        a.setWindowCursorHidden(&w, false);
        QCOMPARE(w.cursor().shape(), Qt::ArrowCursor);
        a.setWindowCursorHidden(&w, false);
        QCOMPARE(w.cursor().shape(), Qt::ArrowCursor);
        a.setWindowCursorHidden(nullptr, true);
        QCOMPARE(w.cursor().shape(), Qt::ArrowCursor);
    }
};
QTEST_MAIN(TstUiActivity)
#include "tst_uiactivity.moc"
