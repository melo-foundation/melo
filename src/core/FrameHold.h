#pragma once
#include <QEvent>
#include <QGuiApplication>
#include <QObject>
#include <QQuickWindow>
#include <QSet>
#include <QWindow>

// Held windows render nothing: every update request is refused, and one frame
// is asked for on release. PluginWindowHost holds windows through a grip
// resize the same way.
class FrameHold : public QObject {
public:
    using QObject::QObject;

    void hold(QWindow* w, bool on) {
        if (!w || on == held_.contains(w)) return;
        if (on) {
            held_.insert(w);
            w->installEventFilter(this);
            connect(w, &QObject::destroyed, this, [this, w] { held_.remove(w); });
            return;
        }
        held_.remove(w);
        w->removeEventFilter(this);
        disconnect(w, &QObject::destroyed, this, nullptr);
        // update(), not requestUpdate(): the basic loop swaps only a window it
        // has marked pending
        if (auto* q = qobject_cast<QQuickWindow*>(w)) q->update();
        else w->requestUpdate();
    }
    bool isHeld(const QWindow* w) const { return held_.contains(const_cast<QWindow*>(w)); }

protected:
    bool eventFilter(QObject* watched, QEvent* event) override {
        if (event->type() == QEvent::UpdateRequest && held_.contains(watched)) return true;
        return QObject::eventFilter(watched, event);
    }

private:
    QSet<QObject*> held_;
};

// Every window in the process but one renders nothing while it is on. On the basic
// render loop another window's frame between the compositor's configure and the
// resized window's answer makes the compositor stretch the resized window's stale
// buffer. Application-wide, so windows made later (menus, tips, plugins) are held too.
class AppHold : public QObject {
public:
    using QObject::QObject;

    void holdAllBut(QWindow* keep) {
        if (keep == keep_ && on_) return;
        keep_ = keep;
        if (!on_) { qApp->installEventFilter(this); on_ = true; }
    }
    void release() {
        if (!on_) return;
        on_ = false;
        keep_ = nullptr;
        qApp->removeEventFilter(this);
        // the frames that were refused; update(), as FrameHold says, for the basic loop
        for (QWindow* w : QGuiApplication::topLevelWindows()) {
            if (!w->isVisible()) continue;
            if (auto* q = qobject_cast<QQuickWindow*>(w)) q->update();
            else w->requestUpdate();
        }
    }

protected:
    bool eventFilter(QObject* watched, QEvent* event) override {
        if (event->type() == QEvent::UpdateRequest && watched != keep_ && qobject_cast<QWindow*>(watched))
            return true;
        return QObject::eventFilter(watched, event);
    }

private:
    QWindow* keep_ = nullptr;
    bool on_ = false;
};
