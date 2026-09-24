#include "CommandMap.h"

#include <QCoreApplication>
#include <QGuiApplication>
#include <QKeySequence>
#include <QShortcut>
#include <utility>

static bool hasCursorPosition(QObject* obj) {
    return obj && obj->metaObject()->indexOfProperty("cursorPosition") >= 0;
}

CommandMap::CommandMap(QObject* parent) : QObject(parent) {
    if (auto* app = qobject_cast<QGuiApplication*>(QCoreApplication::instance())) {
        QObject::connect(app, &QGuiApplication::focusObjectChanged, this,
                         &CommandMap::handleFocusObjectChanged);
        handleFocusObjectChanged(app->focusObject());
    }
}

void CommandMap::setGesture(const QString& gestureId, const QString& commandId) {
    gestureToCommand_.insert(gestureId, commandId);
}

QString CommandMap::commandForGesture(const QString& gestureId) const {
    return gestureToCommand_.value(gestureId);
}

void CommandMap::setCompactActive(bool on) { compactActive_ = on; }

bool CommandMap::invoke(const QString& commandId) {
    if (commandId.isEmpty())
        return false;
    const int dot = commandId.indexOf(QLatin1Char('.'));
    if (dot < 0) {
        emit invoked(commandId);
        return true;
    }
    if (!pluginInvoker_)
        return false;
    return pluginInvoker_(commandId.left(dot), commandId.mid(dot + 1));
}

bool CommandMap::invokeGesture(const QString& gestureId) {
    if (gestureId == QLatin1String("compact.escape") && !compactActive_)
        return false;
    return invoke(commandForGesture(gestureId));
}

void CommandMap::setPluginInvoker(
    std::function<bool(const QString& pluginId, const QString& id)> fn) {
    pluginInvoker_ = std::move(fn);
}

static bool sequenceHasModifier(const QKeySequence& seq) {
    if (seq.isEmpty())
        return false;
    return seq[0].keyboardModifiers() != Qt::NoModifier;
}

bool CommandMap::effectivelyTyping() const {
    // A live focus object is application-wide (plugin windows included).
    // Main.qml's setTyping is window-local and must not keep ApplicationShortcut
    // dead after another window takes focus.
    if (haveFocusObject_)
        return focusTyping_;
    return typing_;
}

void CommandMap::applyShortcutEnabled(QShortcut* sc, const QString& commandId) const {
    if (!sc)
        return;
    if (capturing_) {
        sc->setEnabled(false);
        return;
    }
    const bool exempt = commandId == QLatin1String("toggleSearch")
                        || commandId == QLatin1String("uiLock");
    sc->setEnabled(!effectivelyTyping() || exempt || sequenceHasModifier(sc->key()));
}

void CommandMap::syncShortcutEnabled() {
    for (auto it = shortcuts_.cbegin(); it != shortcuts_.cend(); ++it)
        applyShortcutEnabled(it.value(), it.key());
}

void CommandMap::handleFocusObjectChanged(QObject* focusObject) {
    haveFocusObject_ = focusObject != nullptr;
    focusTyping_ = hasCursorPosition(focusObject);
    syncShortcutEnabled();
}

void CommandMap::setKey(const QString& commandId, const QString& qtSequence) {
    if (commandId.isEmpty() || qtSequence.isEmpty()) {
        auto it = shortcuts_.find(commandId);
        if (it != shortcuts_.end()) {
            delete it.value();
            shortcuts_.erase(it);
        }
        return;
    }
    QShortcut* sc = shortcuts_.value(commandId);
    if (!sc) {
        sc = new QShortcut(this);
        sc->setObjectName(commandId);
        sc->setContext(Qt::ApplicationShortcut);
        QObject::connect(sc, &QShortcut::activated, this, [this, commandId]() {
            invoke(commandId);
        });
        shortcuts_.insert(commandId, sc);
    }
    sc->setKey(QKeySequence(qtSequence));
    applyShortcutEnabled(sc, commandId);
}

void CommandMap::clearKeys() {
    qDeleteAll(shortcuts_);
    shortcuts_.clear();
}

void CommandMap::setTyping(bool on) {
    typing_ = on;
    syncShortcutEnabled();
}

void CommandMap::setCapturing(bool on) {
    capturing_ = on;
    syncShortcutEnabled();
}
