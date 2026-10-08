#include "UiActivity.h"
#include <QCoreApplication>
#include <QEvent>
#include <QMouseEvent>
#include <QWindow>

UiActivity::UiActivity(QObject* parent) : QObject(parent) {
    qApp->installEventFilter(this);
    timer_.setSingleShot(true);
    timer_.setInterval(3000);
    connect(&timer_, &QTimer::timeout, this, [this] {
        idle_ = true;
        emit idleChanged();
    });
    timer_.start();
}

void UiActivity::setIdleAfterMs(int ms) {
    if (ms == timer_.interval()) return;
    timer_.setInterval(ms);
    timer_.start();
}

void UiActivity::wake() {
    if (idle_) {
        idle_ = false;
        emit idleChanged();
    }
    timer_.start();
}

// A still pointer never receives the hover event a cursorShape change waits for;
// the window's cursor is applied at once.
void UiActivity::setWindowCursorHidden(QObject* window, bool hidden) {
    auto* w = qobject_cast<QWindow*>(window);
    if (!w) return;
    if (hidden) w->setCursor(Qt::BlankCursor); else w->unsetCursor();
}

bool UiActivity::eventFilter(QObject* watched, QEvent* e) {
    switch (e->type()) {
    case QEvent::MouseMove: {
        const QPointF at = static_cast<QMouseEvent*>(e)->globalPosition();
        if (!hasPointer_ || at != lastPointer_) {
            hasPointer_ = true;
            lastPointer_ = at;
            wake();
        }
        break;
    }
    case QEvent::MouseButtonPress:
        // Qt Quick re-sends a press to each item that takes it: the window's is the one press
        if (watched->isWindowType()) {
            emit inputWoke();
            emit windowPressed(watched);
        }
        wake();
        break;
    case QEvent::KeyPress:
    case QEvent::ShortcutOverride:   // Shortcuts eat the KeyPress
        emit inputWoke();
        wake();
        break;
    case QEvent::MouseButtonRelease:
    case QEvent::MouseButtonDblClick:
    case QEvent::Wheel:
    case QEvent::TouchBegin:
    case QEvent::TouchUpdate:
        wake();
        break;
    default:
        break;
    }
    return QObject::eventFilter(watched, e);
}
