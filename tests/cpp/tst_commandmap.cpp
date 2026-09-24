#include <QShortcut>
#include <QtTest>
#include "CommandMap.h"

// Synthesized focus object: same heuristic CommandMap uses (cursorPosition
// Q_PROPERTY). Avoids linking Widgets / driving a real QKeyEvent.
class CursorFocusObject : public QObject {
    Q_OBJECT
    Q_PROPERTY(int cursorPosition READ cursorPosition CONSTANT)
public:
    using QObject::QObject;
    int cursorPosition() const { return 0; }
};

class TstCommandMap : public QObject {
    Q_OBJECT
    static QShortcut* shortcutNamed(CommandMap& m, const QString& id) {
        return m.findChild<QShortcut*>(id);
    }
private slots:
    void defaultOccupantUnset() {
        CommandMap m;
        QCOMPARE(m.commandForGesture(QStringLiteral("playerBar.doubleClick")), QString());
    }
    // PlayerBar.qml double-click produces playerBar.doubleClick. Occupancy
    // here is the gate that rebinding that gesture (e.g. to winamp.toggleGroup)
    // does not still fire toggleCompact.
    void assigningGestureStealsOccupant() {
        CommandMap m;
        m.setGesture(QStringLiteral("playerBar.doubleClick"),
                     QStringLiteral("toggleCompact"));
        m.setGesture(QStringLiteral("playerBar.doubleClick"),
                     QStringLiteral("winamp.toggleGroup"));
        QCOMPARE(m.commandForGesture(QStringLiteral("playerBar.doubleClick")),
                 QStringLiteral("winamp.toggleGroup"));
    }
    void compactEscapeDoesNothingWhenFull() {
        CommandMap m;
        m.setGesture(QStringLiteral("compact.escape"),
                     QStringLiteral("toggleCompact"));
        m.setCompactActive(false);
        QString got;
        QObject::connect(&m, &CommandMap::invoked, [&](const QString& id) { got = id; });
        QVERIFY(!m.invokeGesture(QStringLiteral("compact.escape")));
        QVERIFY(got.isEmpty());
        m.setCompactActive(true);
        QVERIFY(m.invokeGesture(QStringLiteral("compact.escape")));
        QCOMPARE(got, QStringLiteral("toggleCompact"));
    }
    void pluginIdSplitsOnFirstDot() {
        CommandMap m;
        QString plug, cmd;
        m.setPluginInvoker([&](const QString& p, const QString& c) {
            plug = p; cmd = c; return true;
        });
        QVERIFY(m.invoke(QStringLiteral("winamp.toggleGroup")));
        QCOMPARE(plug, QStringLiteral("winamp"));
        QCOMPARE(cmd, QStringLiteral("toggleGroup"));
    }
    void setKeyEmptyRemovesAndInvokeStillWorks() {
        CommandMap m;
        m.setKey(QStringLiteral("playPause"), QStringLiteral("Space"));
        QShortcut* sc = shortcutNamed(m, QStringLiteral("playPause"));
        QVERIFY(sc);
        QCOMPARE(sc->context(), Qt::ApplicationShortcut);
        m.setKey(QStringLiteral("playPause"), QString());
        QVERIFY(!shortcutNamed(m, QStringLiteral("playPause")));
        QString got;
        QObject::connect(&m, &CommandMap::invoked, [&](const QString& id) { got = id; });
        QVERIFY(m.invoke(QStringLiteral("playPause")));
        QCOMPARE(got, QStringLiteral("playPause"));
    }
    void typingDisablesBareKeysNotModified() {
        CommandMap m;
        m.setKey(QStringLiteral("playPause"), QStringLiteral("Space"));
        m.setKey(QStringLiteral("toggleSearch"), QStringLiteral("Ctrl+F"));
        m.setKey(QStringLiteral("uiLock"), QStringLiteral("Ctrl+Shift+L"));
        m.setKey(QStringLiteral("deleteTrack"), QStringLiteral("Shift+Del"));
        QShortcut* play = shortcutNamed(m, QStringLiteral("playPause"));
        QShortcut* search = shortcutNamed(m, QStringLiteral("toggleSearch"));
        QShortcut* lock = shortcutNamed(m, QStringLiteral("uiLock"));
        QShortcut* del = shortcutNamed(m, QStringLiteral("deleteTrack"));
        QVERIFY(play && search && lock && del);
        QVERIFY(play->isEnabled());
        m.setTyping(true);
        QVERIFY(!play->isEnabled());
        QVERIFY(search->isEnabled());
        QVERIFY(lock->isEnabled());
        QVERIFY(del->isEnabled());
        m.setTyping(false);
        QVERIFY(play->isEnabled());
    }
    void toggleSearchBareKeyStaysEnabledWhileTyping() {
        CommandMap m;
        m.setKey(QStringLiteral("toggleSearch"), QStringLiteral("F"));
        QShortcut* sc = shortcutNamed(m, QStringLiteral("toggleSearch"));
        QVERIFY(sc);
        m.setTyping(true);
        QVERIFY(sc->isEnabled());
    }
    void clearKeysRemovesAllShortcuts() {
        CommandMap m;
        m.setKey(QStringLiteral("playPause"), QStringLiteral("Space"));
        m.setKey(QStringLiteral("nextTrack"), QStringLiteral("N"));
        m.clearKeys();
        QCOMPARE(m.findChildren<QShortcut*>().size(), 0);
        QString got;
        QObject::connect(&m, &CommandMap::invoked, [&](const QString& id) { got = id; });
        QVERIFY(m.invoke(QStringLiteral("playPause")));
        QCOMPARE(got, QStringLiteral("playPause"));
    }
    // ApplicationShortcut would otherwise steal SettingsWindow's keyCatcher.
    // Capturing disables a bare key, a modified key, AND toggleSearch (typing-exempt).
    void capturingDisablesBareModifiedAndToggleSearch() {
        CommandMap m;
        m.setKey(QStringLiteral("playPause"), QStringLiteral("Space"));
        m.setKey(QStringLiteral("deleteTrack"), QStringLiteral("Shift+Del"));
        m.setKey(QStringLiteral("toggleSearch"), QStringLiteral("Ctrl+F"));
        QShortcut* play = shortcutNamed(m, QStringLiteral("playPause"));
        QShortcut* del = shortcutNamed(m, QStringLiteral("deleteTrack"));
        QShortcut* search = shortcutNamed(m, QStringLiteral("toggleSearch"));
        QVERIFY(play && del && search);
        QVERIFY(play->isEnabled());
        QVERIFY(del->isEnabled());
        QVERIFY(search->isEnabled());
        m.setCapturing(true);
        QVERIFY(!play->isEnabled());
        QVERIFY(!del->isEnabled());
        QVERIFY(!search->isEnabled());
        m.setTyping(true);
        m.setCapturing(false);
        QVERIFY(!play->isEnabled());
        QVERIFY(del->isEnabled());
        QVERIFY(search->isEnabled());
    }
    // Application-wide keys: a cursorPosition object focused in ANY window
    // (plugin TextInput) must disable bare Space without QML setTyping.
    // toggleSearch / uiLock stay enabled; capturing still wins.
    void focusObjectTypingDisablesBareSpaceNotToggleSearch() {
        CommandMap m;
        m.setKey(QStringLiteral("playPause"), QStringLiteral("Space"));
        m.setKey(QStringLiteral("toggleSearch"), QStringLiteral("Ctrl+F"));
        m.setKey(QStringLiteral("uiLock"), QStringLiteral("Ctrl+Shift+L"));
        QShortcut* play = shortcutNamed(m, QStringLiteral("playPause"));
        QShortcut* search = shortcutNamed(m, QStringLiteral("toggleSearch"));
        QShortcut* lock = shortcutNamed(m, QStringLiteral("uiLock"));
        QVERIFY(play && search && lock);
        QVERIFY(play->isEnabled());
        CursorFocusObject text;
        m.handleFocusObjectChanged(&text);
        QVERIFY(!play->isEnabled());
        QVERIFY(search->isEnabled());
        QVERIFY(lock->isEnabled());
        m.setCapturing(true);
        QVERIFY(!play->isEnabled());
        QVERIFY(!search->isEnabled());
        QVERIFY(!lock->isEnabled());
        m.setCapturing(false);
        QVERIFY(!play->isEnabled());
        QVERIFY(search->isEnabled());
        QObject other;
        m.handleFocusObjectChanged(&other);
        QVERIFY(play->isEnabled());
    }
    // Main.qml's window-local typing can stay true after another window is
    // focused. A non-text focus object must not keep Space disabled.
    void staleSetTypingDoesNotDisableWhenOtherWindowFocused() {
        CommandMap m;
        m.setKey(QStringLiteral("playPause"), QStringLiteral("Space"));
        m.setTyping(true);
        QShortcut* play = shortcutNamed(m, QStringLiteral("playPause"));
        QVERIFY(play);
        QVERIFY(!play->isEnabled());
        QObject other;
        m.handleFocusObjectChanged(&other);
        QVERIFY(play->isEnabled());
    }
};
QTEST_MAIN(TstCommandMap)
#include "tst_commandmap.moc"
