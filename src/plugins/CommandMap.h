#pragma once

#include <QHash>
#include <QObject>
#include <QString>
#include <functional>

class QShortcut;

// One occupant per gesture. compact.escape is not a global Escape: it is a
// no-op while the shell is full. Plugin command ids split on the first dot
// and leave through pluginInvoker_; builtins (no dot) emit invoked for
// Main.qml. Keys install as QShortcut with Qt::ApplicationShortcut.
class CommandMap : public QObject {
    Q_OBJECT
public:
    explicit CommandMap(QObject* parent = nullptr);
    Q_INVOKABLE void setGesture(const QString& gestureId, const QString& commandId);
    Q_INVOKABLE QString commandForGesture(const QString& gestureId) const;
    Q_INVOKABLE void setCompactActive(bool on);
    Q_INVOKABLE bool invoke(const QString& commandId);
    Q_INVOKABLE bool invokeGesture(const QString& gestureId);
    Q_INVOKABLE void setKey(const QString& commandId, const QString& qtSequence);
    Q_INVOKABLE void clearKeys();
    Q_INVOKABLE void setTyping(bool on);
    // SettingsWindow keyCatcher: ApplicationShortcut would steal recorded keys.
    Q_INVOKABLE void setCapturing(bool on);
    // Same path as QGuiApplication::focusObjectChanged. Public so tests can
    // synthesize a cursorPosition object without a real window.
    void handleFocusObjectChanged(QObject* focusObject);
    void setPluginInvoker(std::function<bool(const QString& pluginId, const QString& id)> fn);
signals:
    void invoked(const QString& commandId); // builtins; Main.qml handles
private:
    void applyShortcutEnabled(QShortcut* sc, const QString& commandId) const;
    void syncShortcutEnabled();
    bool effectivelyTyping() const;
    QHash<QString, QString> gestureToCommand_;
    QHash<QString, QShortcut*> shortcuts_;
    bool compactActive_ = false;
    bool typing_ = false;
    bool capturing_ = false;
    bool haveFocusObject_ = false;
    bool focusTyping_ = false;
    std::function<bool(const QString&, const QString&)> pluginInvoker_;
};
